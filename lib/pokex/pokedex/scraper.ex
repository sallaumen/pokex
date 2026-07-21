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
           # field abilities (Surf, Fly, Ride, Headbutt…) — travel/utility info
           habilidades: field(html, "Habilidades") |> split_list(),
           materia: field(html, "Materia"),
           evolution_stones: field(html, "Pedra de Evolução") |> split_list(),
           description: description(html),
           weak_to: effectiveness(html, "Muito Efetivo"),
           resists: effectiveness(html, "Muito Inefetivo"),
           neutral: effectiveness(html, "Normal"),
           evolutions: evolutions(html),
           moves: moves(html),
           sprite_url: sprite,
           shiny: shiny_version(html),
           edited_at: parse_edited_at(html)
         }}
    end
  end

  @doc """
  The Movimentos table → one map per slot (M1..M8 + P for the passive):
  `%{slot, name, cooldown_s, element, tags, level}`. Measured on the real
  pages: each slot is a `<th rowspan="2">` block whose first row carries
  "Name (15s)", the mechanic-tag icons (Arquivo: links — Damage, Buff,
  Blind, Target, Passive…) and the move's OWN element (a non-Arquivo link);
  the second row carries "Level N" (absent on passives).
  """
  def moves(html) do
    case section(html, "Movimentos") do
      nil ->
        []

      table ->
        table
        |> String.split("<th rowspan=\"2\">")
        |> Enum.drop(1)
        |> Enum.map(&move_block/1)
        |> Enum.reject(&is_nil/1)
    end
  end

  defp move_block(block) do
    with [_, slot] <- Regex.run(~r/\A\s*([A-Z]\d*)\s*$/m, block),
         [_, raw_name] <- Regex.run(~r/<td align="left">([^<]+)/, block) do
      raw_name = String.trim(raw_name)

      {name, cooldown} =
        case Regex.run(~r/\A(.*?)\s*\((\d+)s\)\z/, raw_name) do
          [_, name, seconds] -> {name, String.to_integer(seconds)}
          nil -> {raw_name, nil}
        end

      %{
        slot: slot,
        name: name,
        cooldown_s: cooldown,
        element: move_element(block),
        tags: move_tags(block),
        level:
          case Regex.run(~r/<td align="left">Level\s*(\d+)/, block) do
            [_, level] -> String.to_integer(level)
            nil -> nil
          end
      }
    else
      _unparsable -> nil
    end
  end

  # mechanic tags ride Arquivo: image links ("Damage", "Buff", "Passive"…)
  defp move_tags(block) do
    ~r/Arquivo:[^"]+" class="image" title="([^"]+)"/
    |> Regex.scan(block)
    |> Enum.map(fn [_, tag] -> tag end)
  end

  # the move's own element is the ONE non-Arquivo page link in the block
  defp move_element(block) do
    case Regex.run(~r{<a href="/index\.php/(?!Arquivo)[^"]+" title="([^"]+)"><img}, block) do
      [_, element] -> element
      nil -> nil
    end
  end

  # the flavor text under the "Descrição:" heading
  defp description(html) do
    case Regex.run(~r{id="Descrição:"[^>]*>.*?</h2>\s*<p>(.*?)</p>}s, html) do
      [_, text] -> text |> strip_tags() |> String.trim()
      nil -> nil
    end
  end

  # everything between a section heading and the next <h2> (nil when absent)
  defp section(html, heading) do
    case Regex.run(~r{id="#{heading}"[^>]*>.*?</h2>(.*?)(<h2|\z)}s, html) do
      [_, body, _] -> body
      nil -> nil
    end
  end

  @months %{
    "janeiro" => 1,
    "fevereiro" => 2,
    "março" => 3,
    "abril" => 4,
    "maio" => 5,
    "junho" => 6,
    "julho" => 7,
    "agosto" => 8,
    "setembro" => 9,
    "outubro" => 10,
    "novembro" => 11,
    "dezembro" => 12
  }

  @doc """
  The page's last-edit date from the MediaWiki footer ("modificada pela última
  vez em 6 de fevereiro de 2026") as "YYYY-MM-DD" — the filterable freshness
  signal (a recently edited page usually means new/changed PXG content).
  """
  def parse_edited_at(html) do
    with [_, day, month_name, year] <-
           Regex.run(~r/modificada pela última vez em (\d{1,2}) de (\p{L}+) de (\d{4})/u, html),
         month when month != nil <- @months[String.downcase(month_name)] do
      :io_lib.format("~s-~2..0B-~2..0B", [year, month, String.to_integer(day)])
      |> IO.iodata_to_binary()
    else
      _absent_or_odd -> nil
    end
  end

  @doc """
  Upsert: fresh entries REPLACE existing ones by name; everything else stays —
  a partial `--only` run refreshes just its targets. Handles the key-style
  mix (existing entries come from JSON with string keys, fresh ones are atoms).

  NOVELTY STAMPS (Lucas: "um Pokémon novo! esse aqui é novo, sabe?"): each
  merged entry carries `first_seen_at` (the sync that first brought it into
  the base) and `changed_at` (the last sync where its CONTENT actually moved
  — level, elements, moves, effectiveness…). Both are OUR clock, deliberately
  distinct from `edited_at` (the wiki's own edit date): a re-scrape that finds
  the same data does not touch changed_at, so "o que mudou desde a última
  sincronização" stays honest.
  """
  def upsert(existing, fresh) do
    by_name = Map.new(existing, &{entry_name(&1), &1})
    fresh_names = MapSet.new(fresh, & &1.name)

    stamped = Enum.map(fresh, &stamp_novelty(&1, Map.get(by_name, &1.name)))

    Enum.reject(existing, &MapSet.member?(fresh_names, entry_name(&1))) ++ stamped
  end

  # Volatile/bookkeeping keys never count as a content change.
  @novelty_keys ~w(scraped_at first_seen_at changed_at)

  # A fresh entry without scraped_at (hand-built by an odd caller) simply gets
  # no stamps — never a crash; the page treats a nil stamp as "no opinion".
  defp stamp_novelty(fresh, previous) do
    case Map.get(fresh, :scraped_at) do
      nil ->
        fresh

      now ->
        changed_at =
          cond do
            previous == nil -> now
            content(fresh) == content(previous) -> get_field(previous, "changed_at") || now
            true -> now
          end

        Map.merge(fresh, %{
          first_seen_at: (previous && get_field(previous, "first_seen_at")) || now,
          changed_at: changed_at
        })
    end
  end

  # Compare on STRING keys with the bookkeeping fields dropped: existing
  # entries come from JSON (string keys, JSON-shaped values), fresh ones are
  # atom-keyed structs-as-maps — round-tripping the fresh one through JSON
  # makes the two directly comparable.
  defp content(entry) do
    entry
    |> JSON.encode!()
    |> JSON.decode!()
    |> Map.drop(@novelty_keys)
  end

  defp get_field(entry, key) when is_map(entry),
    do: Map.get(entry, key) || Map.get(entry, String.to_existing_atom(key))

  defp entry_name(%{name: name}), do: name
  defp entry_name(%{"name" => name}), do: name
  defp entry_name(_entry), do: nil

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
    |> String.replace("/", ", ")
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
