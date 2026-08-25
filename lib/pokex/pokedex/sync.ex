defmodule Pokex.Pokedex.Sync do
  @moduledoc """
  The one sync pipeline, shared by `mix pokedex.sync` (terminal) and the
  /pokedex "Sincronizar" button (UI): the Poké Alliance index, one page per
  species, sprites into priv/static/images/pokedex/, and an UPSERT into
  priv/pokedex/pokedex.json.

  `run/2` is synchronous and reports through the injected `progress` callback
  (the mix task prints, the UI broadcasts). `start/1` is the UI entry: ONE
  async sync at a time (registered name), progress + completion broadcast on
  the "pokedex_sync" PubSub topic, and the in-memory dataset reloaded on done
  — no server restart needed.

  ## No gap pass

  The PokeXGames pipeline ended every run re-scraping entries with no moveset,
  because its regexes missed headings and left 202 of 866 entries silently
  empty. The PA serves one machine-generated template, where an absent moves
  table is the truth about that species (Groudon has none). A page that fails
  to FETCH simply does not update its entry — the upsert keeps the old one —
  and the count comes back in the summary as `failed`.

  Network-bound and polite (delay between fetches) — safe to run alongside the
  bots; sprite downloads skip files that already exist.
  """

  alias Pokex.Pokedex
  alias Pokex.Pokedex.{Api, Index, PageParser, Upsert}

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
  `:limit`, `:delay_ms` (default 120), `:skip_sprites`. Returns
  `{:ok, %{updated, base, shinies, failed}}`.
  """
  def run(opts, progress) when is_function(progress, 1) do
    delay = opts[:delay_ms] || 120

    progress.("índice de espécies…")
    {:ok, raw_index} = Api.index()
    index = Index.parse(raw_index)
    progress.("#{length(index)} espécies no índice")

    targets = narrow_to_only(index, opts[:only], progress)
    targets = if opts[:limit], do: Enum.take(targets, opts[:limit]), else: targets
    total = length(targets)
    scraped_at = DateTime.utc_now() |> DateTime.to_iso8601()

    results =
      targets
      |> Enum.with_index(1)
      |> Enum.map(fn {target, i} ->
        if rem(i, 25) == 0 or i == total, do: progress.("#{i}/#{total} #{target.name}")
        Process.sleep(delay)
        harvest(target, opts, scraped_at, progress)
      end)

    species = Enum.reject(results, &is_nil/1)
    failed = total - length(species)

    merged = if opts[:fresh], do: species, else: Upsert.merge(existing_species(), species)
    merged = link_shinies(merged)
    save_element_icons(raw_index, opts, progress)

    File.mkdir_p!(out_dir())

    json = %{scraped_at: scraped_at, base: Api.base(), species: merged}
    File.write!(Path.join(out_dir(), "pokedex.json"), JSON.encode!(json))

    {:ok,
     %{
       updated: length(species),
       base: length(merged),
       shinies: Enum.count(merged, &shiny_entry?/1),
       failed: failed
     }}
  end

  # One species: the index row carries identity and stats, the page carries the
  # prose, the moves and the evolutions. A page that fails leaves the entry
  # alone rather than writing a half-entry over a good one.
  defp harvest(target, opts, scraped_at, progress) do
    with {:ok, html} <- Api.page(target.path),
         {:ok, page} <- PageParser.parse(html) do
      to_entry(target, page, opts, scraped_at)
    else
      _fetch_or_parse_error ->
        progress.("! falhou: #{target.name} (#{target.path})")
        nil
    end
  end

  defp to_entry(target, page, opts, scraped_at) do
    %{
      name: target.name,
      number: target.number,
      generation: target.generation,
      variant: target.variant,
      # filled by link_shinies/1 once the whole harvest is in hand
      shiny_of: nil,
      # the index's level is the one the wiki filters by; the page repeats it
      level: target.level || page.level,
      tier: target.tier || page.tier,
      role: target.role || page.role,
      hp: page.hp,
      experience: page.experience,
      elements: target.elements,
      habilidades: page.habilidades,
      description: page.description,
      moves: page.moves,
      evolves_to: page.evolves_to,
      evolves_from: page.evolves_from,
      sprite: download_sprite(target.image, opts),
      path: target.path,
      scraped_at: scraped_at
    }
  end

  # A shiny points at the normal form sharing its number. Done AFTER the merge
  # so a `--only "Shiny Rattata"` run still links against the base on disk.
  defp link_shinies(species) do
    normals =
      for entry <- species,
          field(entry, "variant") == "normal",
          into: %{},
          do: {field(entry, "number"), field(entry, "name")}

    Enum.map(species, fn entry ->
      if field(entry, "variant") == "shiny" do
        put_field(entry, "shiny_of", Map.get(normals, field(entry, "number")))
      else
        entry
      end
    end)
  end

  # The wiki's own type icons, one small PNG per element, cached under
  # priv/static/images/pokedex/elements/ so the UI can show them instead of
  # plain words. Best-effort: a failed download leaves the coloured text chip.
  defp save_element_icons(raw_index, opts, progress) do
    if opts[:skip_sprites] do
      :ok
    else
      icons = Index.element_icons(raw_index)
      dir = Path.join(sprites_dir(), "elements")
      File.mkdir_p!(dir)

      Enum.each(icons, fn {element, url} ->
        fetch_asset(url, Path.join(dir, String.downcase(element) <> ".png"))
      end)

      progress.("ícones de elemento: #{map_size(icons)}")
    end
  end

  # Public only for the test. skip_sprites must mean "don't FETCH", never
  # "forget": a --fresh --skip-sprites run once nulled the sprite of every
  # entry in the base and 824 paths had to be restored by hand. What is
  # already on disk stays claimed either way.
  @doc false
  def download_sprite(nil, _opts), do: nil

  def download_sprite(url, opts) do
    file = Path.basename(url)
    dest = Path.join(sprites_dir(), file)

    unless opts[:skip_sprites] do
      File.mkdir_p!(sprites_dir())
      fetch_asset(url, dest)
    end

    if File.exists?(dest), do: "images/pokedex/" <> file
  end

  # What is on disk is never fetched again — the sync is resumable.
  defp fetch_asset(url, dest) do
    if File.exists?(dest) do
      :skip
    else
      case Api.asset(url) do
        {:ok, body} -> File.write!(dest, body)
        _error -> :skip
      end
    end
  end

  # --only "Seadra,Horsea": sync just these; unknown names are reported, never
  # silently dropped.
  defp narrow_to_only(targets, only, _progress) when only in [nil, ""], do: targets

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

  defp broadcast(event),
    do: Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:pokedex_sync, event})

  defp shiny_entry?(entry), do: field(entry, "variant") == "shiny"

  defp field(entry, key) when is_map(entry),
    do: Map.get(entry, key) || Map.get(entry, String.to_existing_atom(key))

  defp put_field(entry, key, value) do
    if Map.has_key?(entry, key),
      do: Map.put(entry, key, value),
      else: Map.put(entry, String.to_existing_atom(key), value)
  end

  # Relative to the repo root — where both `mix pokedex.sync` and the dev
  # server run from (dev-only tooling; priv/ is symlinked into _build).
  defp out_dir, do: "priv/pokedex"

  defp sprites_dir,
    do: Application.get_env(:pokex, :pokedex_sprites_dir, "priv/static/images/pokedex")
end
