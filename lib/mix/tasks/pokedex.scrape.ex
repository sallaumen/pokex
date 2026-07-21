defmodule Mix.Tasks.Pokedex.Scrape do
  @shortdoc "Scrapes the PXG wiki into priv/pokedex/pokedex.json (+ sprites)"

  @moduledoc """
  Builds the local Pokédex from wiki.pokexgames.com: the species index, every
  species page (Shiny variants followed via "Outras Versões"), the Fishing
  page's lure tables, and the sprites (normal + shiny) into
  priv/static/images/pokedex/.

  Deliberately does NOT boot the :pokex app (only :req) — running a scrape
  must never start the bot's workers against the real mouse/screen.

      mix pokedex.scrape                # full run (~10-20min, be nice to the wiki)
      mix pokedex.scrape --limit 20     # first N species (pipeline check)
      mix pokedex.scrape --delay-ms 400 # slower pace
      mix pokedex.scrape --skip-sprites # JSON only
  """

  use Mix.Task

  alias Pokex.Pokedex.Scraper

  @base "https://wiki.pokexgames.com"
  @requirements ["app.config"]

  @impl true
  def run(args) do
    {opts, _argv, _errors} =
      OptionParser.parse(args,
        strict: [limit: :integer, delay_ms: :integer, skip_sprites: :boolean]
      )

    delay = opts[:delay_ms] || 200
    {:ok, _apps} = Application.ensure_all_started(:req)

    Mix.shell().info("índice de espécies…")
    index = fetch!("/index.php/Pok%C3%A9mon") |> Scraper.parse_index()
    Mix.shell().info("#{length(index)} espécies no índice")

    Mix.shell().info("tabelas de iscas…")
    lures = fetch!("/index.php/Fishing") |> Scraper.parse_lures()
    Mix.shell().info("#{length(lures)} iscas")

    targets = index ++ lure_extras(index, lures)
    targets = if opts[:limit], do: Enum.take(targets, opts[:limit]), else: targets
    total = length(targets)

    species =
      targets
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {target, i} ->
        if rem(i, 25) == 0 or i == total,
          do: Mix.shell().info("#{i}/#{total} #{target.name}")

        Process.sleep(delay)
        scrape_species(target, delay, opts)
      end)

    File.mkdir_p!(out_dir())

    json = %{
      scraped_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      base: @base,
      species: species,
      lures: lures
    }

    File.write!(Path.join(out_dir(), "pokedex.json"), JSON.encode!(json))
    shinies = Enum.count(species, & &1.shiny_of)

    Mix.shell().info(
      "pronto: #{length(species)} entradas (#{shinies} shinies) em #{out_dir()}/pokedex.json"
    )
  end

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

  defp scrape_species(target, delay, opts) do
    with {:ok, html} <- fetch(target.page),
         {:ok, parsed} <- Scraper.parse_species(html) do
      [to_entry(parsed, nil, opts) | scrape_shiny(parsed, delay, opts)]
    else
      _fetch_or_parse_error ->
        Mix.shell().info("  ! falhou: #{target.name} (#{target.page})")
        []
    end
  end

  defp scrape_shiny(%{shiny: nil}, _delay, _opts), do: []

  defp scrape_shiny(%{shiny: shiny} = base, delay, opts) do
    Process.sleep(delay)

    with {:ok, html} <- fetch(shiny.page),
         {:ok, parsed} <- Scraper.parse_species(html) do
      [to_entry(parsed, base.name, opts)]
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
            weak_to: base.weak_to,
            resists: base.resists,
            evolutions: [],
            sprite: sprite,
            shiny_of: base.name,
            shiny_name: nil
          }
        ]
    end
  end

  defp to_entry(parsed, shiny_of, opts) do
    %{
      name: parsed.name,
      number: parsed.number,
      level: parsed.level,
      elements: parsed.elements,
      boost: parsed.boost,
      weak_to: parsed.weak_to,
      resists: parsed.resists,
      evolutions: parsed.evolutions,
      sprite: download_sprite(parsed.sprite_url, parsed.name, opts),
      shiny_of: shiny_of,
      shiny_name: parsed.shiny && parsed.shiny.name
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

  defp out_dir, do: "priv/pokedex"
  defp sprites_dir, do: "priv/static/images/pokedex"
end
