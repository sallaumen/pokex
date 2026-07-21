defmodule Pokex.Pokedex.Scraper do
  @moduledoc """
  Pure HTML → data parsers for the PXG wiki (wiki.pokexgames.com).

  The wiki's markup is machine-generated and extremely regular (`<b>Campo:</b>
  valor<br />` fields, `wikitable` lure tables with captions), so targeted
  regexes beat a full HTML parser here — no new dependency, and the REAL page
  fixtures in test/fixtures/pokedex pin the format so a wiki change breaks
  loudly in tests, not silently in data.

  Semantics measured on the real pages (2026-07-20): under "Efetividades",
  "Muito Efetivo" lists what hits the Pokémon HARD (its weaknesses — exactly
  what "quais têm fraqueza de planta" queries want) and "Muito Inefetivo" what
  it resists.
  """

  @doc ~S'One entry per species table row: `%{number, name, page}` (deduped, index order).'
  def parse_index(html) do
    ~r/#(\d+)\s*<\/td>\s*<td><a href="(\/index\.php\/[^"]+)" title="([^"]+)">/
    |> Regex.scan(html)
    |> Enum.map(fn [_, number, page, name] ->
      %{number: String.to_integer(number), name: name, page: page}
    end)
    |> Enum.uniq_by(& &1.name)
  end

  @doc """
  The species page → attribute map. Absent optional sections come back nil/[]
  (older/short pages); a page without a "Nome:" field is {:error, :unrecognized}.
  """
  def parse_species(html) do
    case field(html, "Nome") do
      nil ->
        {:error, :unrecognized}

      name ->
        {number, sprite} = main_sprite(html)

        {:ok,
         %{
           name: name,
           number: number,
           level: field(html, "Level") |> parse_int(),
           elements: field(html, "Elemento") |> split_list(),
           boost: field(html, "Boost"),
           weak_to: effectiveness(html, "Muito Efetivo"),
           resists: effectiveness(html, "Muito Inefetivo"),
           evolutions: evolutions(html),
           sprite_url: sprite,
           shiny: shiny_version(html)
         }}
    end
  end

  @doc ~S'The Fishing page → every lure: `%{name, tiers: [%{fishing_level, pokemon: [names]}]}`.'
  def parse_lures(html) do
    ~r/<table class="wikitable"[^>]*>\s*<caption>(.*?)<\/caption>(.*?)<\/table>/s
    |> Regex.scan(html)
    |> Enum.map(fn [_, caption, body] ->
      %{name: strip_tags(caption), tiers: lure_tiers(body)}
    end)
    |> Enum.reject(&(&1.tiers == []))
  end

  # -- species helpers ---------------------------------------------------------

  defp field(html, label) do
    case Regex.run(~r/<b>#{label}:<\/b>\s*([^<]+)</, html) do
      [_, value] -> value |> String.trim() |> String.trim_trailing(".")
      nil -> nil
    end
  end

  defp parse_int(nil), do: nil

  defp parse_int(value) do
    case Integer.parse(String.trim(value)) do
      {int, _rest} -> int
      :error -> nil
    end
  end

  # "Fire, Water, Ice and Steel." → ["Fire", "Water", "Ice", "Steel"]
  defp split_list(nil), do: []

  defp split_list(text) do
    text
    |> String.trim_trailing(".")
    |> String.replace(" and ", ", ")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 in ["", "None"]))
  end

  defp effectiveness(html, label) do
    case Regex.run(~r/<b>#{label}:<\/b>\s*([^<]+)</, html) do
      [_, value] -> split_list(value)
      nil -> []
    end
  end

  defp evolutions(html) do
    ~r/<b>([^<]+)<\/b>\s*precisa de Level\s*(\d+)/
    |> Regex.scan(html)
    |> Enum.map(fn [_, name, level] ->
      %{name: String.trim(name), level: String.to_integer(level)}
    end)
  end

  # The FIRST content image is the species' own sprite ("117_-_Seadra.gif" /
  # "117-Seadra.png") — the dex number rides its filename.
  defp main_sprite(html) do
    case Regex.run(~r/src="(\/images\/[^"]+\/0*(\d+)[-_][^"]+)"/, html) do
      [_, sprite, number] -> {String.to_integer(number), sprite}
      nil -> {nil, nil}
    end
  end

  defp shiny_version(html) do
    case Regex.run(
           ~r/<a href="(\/index\.php\/Shiny_[^"]+)" title="([^"]+)"><img[^>]+src="(\/images\/[^"]+)"/,
           html
         ) do
      [_, page, name, sprite] -> %{name: name, page: page, sprite_url: sprite}
      nil -> nil
    end
  end

  # -- lure helpers ------------------------------------------------------------

  defp lure_tiers(table_body) do
    ~r/<td[^>]*><b>(\d+)<\/b>\s*<\/td>\s*<td[^>]*>(.*?)<\/td>/s
    |> Regex.scan(table_body)
    |> Enum.map(fn [_, level, cell] ->
      %{fishing_level: String.to_integer(level), pokemon: cell_species(cell)}
    end)
  end

  defp cell_species(cell) do
    ~r/<a href="\/index\.php\/[^"]+" title="([^"]+)">/
    |> Regex.scan(cell)
    |> Enum.map(fn [_, name] -> name end)
    |> Enum.uniq()
  end

  defp strip_tags(html), do: html |> String.replace(~r/<[^>]+>/, "") |> String.trim()
end
