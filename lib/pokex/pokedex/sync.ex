defmodule Pokex.Pokedex.Sync do
  @moduledoc """
  The one scraping pipeline, shared by `mix pokedex.scrape` (terminal) and the
  /pokedex "Sincronizar" button (UI): wiki index + lure tables + species pages
  (Shiny variants followed), sprites into priv/static/images/pokedex/, and an
  UPSERT into priv/pokedex/pokedex.json.

  `run/2` is synchronous and reports through the injected `progress` callback
  (the mix task prints, the UI broadcasts). `start/1` is the UI entry: ONE
  async sync at a time (registered name), progress + completion broadcast on
  the "pokedex_sync" PubSub topic, and the in-memory dataset reloaded on done
  — no server restart needed.

  Network-bound and polite (delay between fetches) — safe to run alongside
  the bots; sprite downloads skip files that already exist.
  """

  alias Pokex.Pokedex
  alias Pokex.Pokedex.Scraper

  @base "https://wiki.pokexgames.com"
  @topic "pokedex_sync"
  @process_name :pokedex_sync

  def topic, do: @topic

  @doc "True while a UI-started sync is in flight."
  def running?, do: Process.whereis(@process_name) != nil

  @doc """
  Starts ONE async sync (`:ok` | `{:error, :already_running}`). Progress,
  completion and failure are broadcast on `topic/0`; on completion the
  Pokédex dataset is reloaded in place.
  """
  def start(opts \\ []) do
    if running?() do
      {:error, :already_running}
    else
      {:ok, _pid} =
        Task.start(fn ->
          # atomic take-the-slot: a concurrent second click raises here and
          # dies silently — the first sync keeps running untouched
          try do
            Process.register(self(), @process_name)
          rescue
            ArgumentError -> exit(:normal)
          end

          try do
            {:ok, summary} = run(opts, &broadcast({:progress, &1}))
            Pokedex.reload()
            broadcast({:done, summary})
          catch
            kind, reason -> broadcast({:failed, Exception.format(kind, reason, [])})
          end
        end)

      :ok
    end
  end

  @doc """
  The synchronous pipeline. Options: `:only` ("Seadra,Horsea"), `:fresh`,
  `:limit`, `:delay_ms` (default 200), `:skip_sprites`. Returns
  `{:ok, %{updated, base, shinies, filled}}`.

  Every run ends with a GAP PASS: any entry still missing the harvest (moves
  == nil — an older dataset, a partial `--only` run, a fetch that failed, a
  shiny built from the link fallback) is scraped again by name until the base
  is whole. Lucas: "quero que a sincronização geral sempre já pegue os dados
  faltando, como ataques e talz, mesmo que sejam muitos".
  """
  def run(opts, progress) when is_function(progress, 1) do
    delay = opts[:delay_ms] || 200

    progress.("índice de espécies…")
    index = fetch!("/index.php/Pok%C3%A9mon") |> Scraper.parse_index()
    progress.("#{length(index)} espécies no índice; tabelas de iscas…")
    lures = fetch!("/index.php/Fishing") |> Scraper.parse_lures()

    targets = index ++ lure_extras(index, lures)
    targets = narrow_to_only(targets, opts[:only], progress)
    targets = if opts[:limit], do: Enum.take(targets, opts[:limit]), else: targets
    total = length(targets)
    scraped_at = DateTime.utc_now() |> DateTime.to_iso8601()

    species =
      targets
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {target, i} ->
        if rem(i, 25) == 0 or i == total, do: progress.("#{i}/#{total} #{target.name}")
        Process.sleep(delay)
        scrape_species(target, delay, opts, scraped_at, progress)
      end)

    merged = if opts[:fresh], do: species, else: Scraper.upsert(existing_species(), species)
    {merged, filled} = fill_gaps(merged, delay, opts, scraped_at, progress)
    save_element_icons(opts, progress)

    File.mkdir_p!(out_dir())

    json = %{scraped_at: scraped_at, base: @base, species: merged, lures: lures}
    File.write!(Path.join(out_dir(), "pokedex.json"), JSON.encode!(json))

    {:ok,
     %{
       updated: length(species),
       base: length(merged),
       shinies: Enum.count(merged, &shiny_entry?/1),
       filled: filled
     }}
  end

  # The game's own type icons (one small PNG per element), harvested from any
  # species page and cached under priv/static/images/pokedex/elements/ so the
  # UI can show them instead of plain words. Best-effort: a failed download
  # just leaves the coloured text chip in place.
  defp save_element_icons(opts, progress) do
    if opts[:skip_sprites] do
      :ok
    else
      with {:ok, html} <- fetch("/index.php/Sceptile"),
           icons when map_size(icons) > 0 <- Scraper.element_icons(html) do
        dir = Path.join(sprites_dir(), "elements")
        File.mkdir_p!(dir)

        Enum.each(icons, fn {element, url} ->
          path = Path.join(dir, String.downcase(element) <> ".png")

          unless File.exists?(path) do
            case Req.get(@base <> url, retry: :transient, max_retries: 2) do
              {:ok, %{status: 200, body: body}} when is_binary(body) -> File.write!(path, body)
              _error -> :skip
            end
          end
        end)

        progress.("ícones de elemento: #{map_size(icons)}")
      else
        _unavailable -> :ok
      end
    end
  end

  @doc """
  Entries with no moveset that this run did NOT just fetch — what the gap pass
  targets.

  An empty `moves` used to count as complete ("the wiki simply has no table
  there"), which was wrong: 202 of 866 entries were empty because the parser
  missed the page's heading spelling, and the pass that exists to fix gaps never
  looked at them. Two states, two rules:

    * `nil` — never harvested (an old dataset, a shiny kept from the link
      fallback because its page failed): always a gap, retried even inside the
      run that created it, exactly as before.
    * `[]` — the page WAS parsed and had no table: a gap only if this run did
      not just fetch it, so a full sync never pays for a second round-trip
      while a partial one (`--only`, `--limit`) still heals the rest of the base.
  """
  def incomplete(entries, scraped_at \\ nil) do
    Enum.filter(entries, fn entry ->
      case field(entry, "moves") do
        nil -> true
        [] -> scraped_at == nil or field(entry, "scraped_at") != scraped_at
        _harvested -> false
      end
    end)
  end

  # The gap pass. Scrapes by NAME (the wiki page always mirrors it), keeps the
  # entry's own name and shiny_of so a variant stays a variant, and runs at the
  # same polite delay. A page that stays unparsable is simply retried next run
  # — never a silent half-entry.
  defp fill_gaps(merged, delay, opts, scraped_at, progress) do
    gaps = incomplete(merged, scraped_at)
    total = length(gaps)

    if total == 0 do
      {merged, 0}
    else
      progress.("completando #{total} entradas sem movimentos…")

      fresh =
        gaps
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {entry, i} ->
          if rem(i, 25) == 0 or i == total,
            do: progress.("completando #{i}/#{total} #{field(entry, "name")}")

          Process.sleep(delay)
          scrape_by_name(entry, opts, scraped_at)
        end)

      {Scraper.upsert(merged, fresh), length(fresh)}
    end
  end

  defp scrape_by_name(entry, opts, scraped_at) do
    name = field(entry, "name")
    page = "/index.php/" <> URI.encode(String.replace(name, " ", "_"))

    with true <- is_binary(name),
         {:ok, html} <- fetch(page),
         {:ok, parsed} <- Scraper.parse_species(html) do
      # the page we asked for IS this entry — keep its identity even if the
      # wiki's own "Nome:" field disagrees (redirects, odd forms)
      [to_entry(%{parsed | name: name}, field(entry, "shiny_of"), opts, scraped_at)]
    else
      _unavailable -> []
    end
  end

  defp field(entry, key) when is_map(entry),
    do: Map.get(entry, key) || Map.get(entry, String.to_existing_atom(key))

  defp broadcast(event),
    do: Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:pokedex_sync, event})

  defp shiny_entry?(%{shiny_of: shiny_of}), do: shiny_of != nil
  defp shiny_entry?(%{"shiny_of" => shiny_of}), do: shiny_of != nil
  defp shiny_entry?(_entry), do: false

  # Lure tables reference forms the index doesn't list (Mini/Big/Giant Magikarp
  # etc.) — scrape those too so every lure entry resolves. Shiny names resolve
  # through their base species' "Outras Versões", never directly.
  defp lure_extras(index, lures) do
    known = MapSet.new(index, & &1.name)

    lures
    |> Enum.flat_map(& &1.tiers)
    |> Enum.flat_map(& &1.pokemon)
    |> Enum.uniq()
    |> Enum.reject(&(MapSet.member?(known, &1) or String.starts_with?(&1, "Shiny ")))
    |> Enum.map(fn name ->
      %{
        number: nil,
        name: name,
        page: "/index.php/" <> URI.encode(String.replace(name, " ", "_"))
      }
    end)
  end

  # --only "Seadra,Horsea": scrape just these targets (their Shiny variants
  # follow automatically); unknown names are reported, never silently dropped.
  defp narrow_to_only(targets, nil, _progress), do: targets
  defp narrow_to_only(targets, "", _progress), do: targets

  defp narrow_to_only(targets, only, progress) do
    wanted = only |> String.split(",") |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    narrowed = Enum.filter(targets, &(String.downcase(&1.name) in wanted))

    missing = wanted -- Enum.map(narrowed, &String.downcase(&1.name))
    if missing != [], do: progress.("! não achei no índice: #{Enum.join(missing, ", ")}")

    narrowed
  end

  defp existing_species do
    with {:ok, bin} <- File.read(Path.join(out_dir(), "pokedex.json")),
         {:ok, %{"species" => species}} when is_list(species) <- JSON.decode(bin) do
      species
    else
      _missing_or_corrupt -> []
    end
  end

  defp scrape_species(target, delay, opts, scraped_at, progress) do
    with {:ok, html} <- fetch(target.page),
         {:ok, parsed} <- Scraper.parse_species(html) do
      [
        to_entry(parsed, nil, opts, scraped_at)
        | scrape_shiny(parsed, delay, opts, scraped_at)
      ]
    else
      _fetch_or_parse_error ->
        progress.("! falhou: #{target.name} (#{target.page})")
        []
    end
  end

  defp scrape_shiny(%{shiny: nil}, _delay, _opts, _scraped_at), do: []

  defp scrape_shiny(%{shiny: shiny} = base, delay, opts, scraped_at) do
    Process.sleep(delay)

    with {:ok, html} <- fetch(shiny.page),
         {:ok, parsed} <- Scraper.parse_species(html) do
      [to_entry(parsed, base.name, opts, scraped_at)]
    else
      # shiny page missing/odd: keep a minimal entry from the link itself so the
      # variant still exists (name + sprite), stats nil
      _error ->
        sprite = download_sprite(shiny.sprite_url, shiny.name, opts)

        [
          %{
            name: shiny.name,
            number: base.number,
            level: nil,
            elements: base.elements,
            boost: nil,
            habilidades: base.habilidades,
            materia: nil,
            evolution_stones: [],
            description: nil,
            weak_to: base.weak_to,
            resists: base.resists,
            neutral: base.neutral,
            immune: base.immune,
            effectiveness: base.effectiveness,
            evolutions: [],
            moves: nil,
            moves_pvp: nil,
            sprite: sprite,
            shiny_of: base.name,
            shiny_name: nil,
            edited_at: nil,
            scraped_at: scraped_at
          }
        ]
    end
  end

  defp to_entry(parsed, shiny_of, opts, scraped_at) do
    %{
      name: parsed.name,
      number: parsed.number,
      level: parsed.level,
      elements: parsed.elements,
      boost: parsed.boost,
      habilidades: parsed.habilidades,
      materia: parsed.materia,
      evolution_stones: parsed.evolution_stones,
      description: parsed.description,
      weak_to: parsed.weak_to,
      resists: parsed.resists,
      neutral: parsed.neutral,
      immune: parsed.immune,
      effectiveness: parsed.effectiveness,
      evolutions: parsed.evolutions,
      moves: parsed.moves,
      moves_pvp: parsed.moves_pvp,
      sprite: download_sprite(parsed.sprite_url, parsed.name, opts),
      shiny_of: shiny_of,
      shiny_name: parsed.shiny && parsed.shiny.name,
      edited_at: parsed.edited_at,
      scraped_at: scraped_at
    }
  end

  # -- sprites -----------------------------------------------------------------

  defp download_sprite(nil, _name, _opts), do: nil

  defp download_sprite(url, name, opts) do
    if opts[:skip_sprites] do
      nil
    else
      file = slug(name) <> Path.extname(url)
      dest = Path.join(sprites_dir(), file)
      File.mkdir_p!(sprites_dir())

      unless File.exists?(dest) do
        case Req.get(@base <> url, retry: :transient, max_retries: 2) do
          {:ok, %{status: 200, body: body}} when is_binary(body) -> File.write!(dest, body)
          _error -> :skip
        end
      end

      if File.exists?(dest), do: "images/pokedex/" <> file
    end
  end

  defp slug(name), do: name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-")

  # -- IO ----------------------------------------------------------------------

  defp fetch(path) do
    case Req.get(@base <> path, retry: :transient, max_retries: 2) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      other -> {:error, other}
    end
  end

  defp fetch!(path) do
    {:ok, body} = fetch(path)
    body
  end

  # Relative to the repo root — where both `mix pokedex.scrape` and the dev
  # server run from (dev-only tooling; priv/ is symlinked into _build).
  defp out_dir, do: "priv/pokedex"
  defp sprites_dir, do: "priv/static/images/pokedex"
end
