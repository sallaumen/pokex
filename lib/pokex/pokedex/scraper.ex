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
  what "which are weak to grass" queries want) and "Muito Inefetivo" what
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
        tiers = effectiveness_tiers(html)

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
           weak_to: tier_elements(tiers, :weak),
           resists: tier_elements(tiers, :resists),
           neutral: tier_elements(tiers, :neutral),
           immune: tier_elements(tiers, :immune),
           effectiveness: tiers,
           evolutions: evolutions(html),
           moves: moves(html),
           moves_pvp: moves(html, :pvp),
           element_icons: element_icons(html),
           sprite_url: sprite,
           shiny: shiny_version(html),
           edited_at: parse_edited_at(html)
         }}
    end
  end

  @doc """
  The moves of one arena → a map per slot (M1..M8 + P for the passive):
  `%{slot, name, cooldown_s, element, tags, level}`.

  PXG pages carry TWO movesets under "Movimentos" — `Moveset PVE` (hunting,
  what this bot cares about) and `Moveset PVP` — with the SAME slot names and
  DIFFERENT cooldowns (unsplit they showed as one in-order, duplicated list).
  `arena` picks one: `:pve` (default, falls back to the whole Movimentos
  section on older single-table pages) or `:pvp` (empty when absent).

  Measured on the real pages: each slot is a `<th rowspan="2">` block whose
  first row carries "Name (15s)" — sometimes wrapped in `<b>` — the
  mechanic-tag icons (Arquivo: links) and the move's OWN element (a
  non-Arquivo link); the second row carries "Level N" (absent on passives).
  """
  def moves(html, arena \\ :pve) do
    case moves_section(html, arena) do
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

  # The wiki names this heading three different ways depending on when the page
  # was written — "Moveset_PVE" (Sceptile), "Movimentos_PvE" (Venusaur),
  # "Movimentos_PVE" (Florges) — so match the shape, case-insensitively, not one
  # literal. PVE lives under its own heading when the page has both; older pages
  # keep a single unsectioned table, which IS the PVE moveset for our purposes.
  defp moves_section(html, :pve),
    do: section(html, "(?:Moveset|Movimentos)_PVE") || section(html, "Movimentos")

  defp moves_section(html, :pvp), do: section(html, "(?:Moveset|Movimentos)_PVP")

  @doc """
  Element → wiki icon URL, harvested from the move rows (`<img alt="Grass"
  src="/images/c/c5/Grass.png" width="24">`). The sync downloads these once
  so the UI can show the game's OWN type icons instead of plain text.
  """
  def element_icons(html) do
    ~r/<img alt="([A-Za-z]+)" src="(\/images\/[^"]+)" decoding="async" width="24"/
    |> Regex.scan(html)
    |> Map.new(fn [_, element, url] -> {element, url} end)
  end

  defp move_block(block) do
    with [_, slot] <- Regex.run(~r/\A\s*([A-Z]\d*)\s*$/m, block),
         [_, cell] <- Regex.run(~r{<td align="left">(.*?)</td>}s, block) do
      # the cell may wrap the name in <b> (highlighted moves) — strip tags, or
      # the old regex fell through to the NEXT cell and named the move "Level 80"
      raw_name = cell |> strip_tags() |> String.trim()

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
          case Regex.run(~r/Level\s*(\d+)/, strip_tags(block)) do
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

  defp description(html) do
    case Regex.run(~r{id="Descrição:"[^>]*>.*?</h2>\s*<p>(.*?)</p>}s, html) do
      [_, text] -> text |> strip_tags() |> String.trim()
      nil -> nil
    end
  end

  # Everything between a heading and the next one (nil when absent OR empty —
  # an h2 whose whole body is h3 subsections has nothing of its own). Accepts h2
  # AND h3 because the movesets are h3 subsections of the h2 "Movimentos" — an
  # h2-only matcher silently returned nothing for them. Case-insensitive: the
  # same heading appears as PVE and PvE across page generations.
  defp section(html, heading) do
    case Regex.run(~r{id="#{heading}"[^>]*>.*?</h[23]>(.*?)(<h[23]|\z)}si, html) do
      [_, body, _] -> if String.trim(body) == "", do: nil, else: body
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

  NOVELTY STAMPS: each merged entry carries `first_seen_at` (the sync that
  first brought it into the base) and `changed_at` (the last sync where its
  CONTENT actually moved — level, elements, moves, effectiveness…). Both are
  OUR clock, deliberately distinct from `edited_at` (the wiki's own edit
  date): a re-scrape that finds the same data does not touch changed_at, so
  "what changed since the last sync" stays honest.
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
    |> String.replace(" and ", ", ")
    |> String.replace("/", ", ")
    |> String.split(",", trim: true)
    # the trailing "." rides the LAST item and the page may leave a space after
    # it ("… and Fairy. ") — trim each item, then the dot, or "Fairy." shipped
    |> Enum.map(&(&1 |> String.trim() |> String.trim_trailing(".") |> String.trim()))
    |> Enum.reject(&(&1 in ["", "None"]))
  end

  @doc """
  The "Efetividades" lines as written on the page: `[%{label, kind, elements}]`
  in page order.

  Measured across a 40-page sample (2026-07-21) the wiki uses SEVEN labels for
  four meanings, and no page carries all of them: "Muito Efetivo" (23 pages),
  "Efetivo" (21), "Super Efetivo" (2), "Muito Inefetivo" (30), "Inefetivo" (21),
  "Nulo" (15), "Imune" (1) — plus lowercase spellings. Matching one literal
  ("Muito Efetivo") left 345 of 866 species with NO weakness at all, Venusaur
  included. So classify by shape: anything "…inefetivo" resists, anything else
  "…efetivo" is a weakness, "Nulo"/"Imune" is immunity.

  The label is kept verbatim so the UI can show the tier the page actually
  claims instead of flattening two different strengths into one word.
  """
  def effectiveness_tiers(html) do
    ~r"<b>([^<:]{2,20}):</b>\s*([^<]+)"
    |> Regex.scan(html)
    |> Enum.flat_map(fn [_, label, value] ->
      label = String.trim(label)

      case tier_kind(label) do
        nil -> []
        kind -> [%{label: label, kind: kind, elements: split_list(value)}]
      end
    end)
  end

  defp tier_kind(label) do
    down = String.downcase(label)

    cond do
      String.contains?(down, "inefetivo") -> :resists
      String.contains?(down, "efetivo") -> :weak
      down in ["nulo", "imune"] -> :immune
      down == "normal" -> :neutral
      true -> nil
    end
  end

  # Two tiers of the same kind (Inefetivo + Muito Inefetivo) merge, page order
  # kept — the detail page shows the tiers apart, the filters want one list.
  defp tier_elements(tiers, kind) do
    tiers
    |> Enum.filter(&(&1.kind == kind))
    |> Enum.flat_map(& &1.elements)
    |> Enum.uniq()
  end

  # "precisa de Level 40" and "precisa de level 80" both occur — sometimes on
  # the SAME page (Venusaur), which silently dropped the final evolution.
  defp evolutions(html) do
    ~r/<b>([^<]+)<\/b>\s*precisa de level\s*(\d+)/i
    |> Regex.scan(html)
    |> Enum.map(fn [_, name, level] ->
      %{name: String.trim(name), level: String.to_integer(level)}
    end)
  end

  # The FIRST content image is the species' own sprite ("117_-_Seadra.gif" /
  # "117-Seadra.png" / "671.Florges.png") — the dex number rides its filename,
  # and the separator drifts with the page's generation.
  defp main_sprite(html) do
    case Regex.run(~r/src="(\/images\/[^"]+\/0*(\d+)[-_.][^"]+)"/, html) do
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
