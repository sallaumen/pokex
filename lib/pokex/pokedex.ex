defmodule Pokex.Pokedex do
  @moduledoc """
  The local Pokédex: every species (and its Shiny variant) scraped from the
  PokeTibia wiki by `mix pokedex.scrape`, loaded once from priv/pokedex/pokedex.json
  and served from :persistent_term — pure reads, no process.

  This is the queryable base Lucas asked for (search by level, element,
  weakness) AND the future shiny-detector's reference set (each entry carries
  its sprite, shinies included). Re-scraping rewrites the JSON; the app picks
  it up on the next restart.
  """

  alias Pokex.Pokedex.Clans

  @doc "Every species entry (shiny variants included, `shiny_of` set on them)."
  def species, do: data().species

  @doc "Every fishing lure with its level tiers."
  def lures, do: data().lures

  @doc "When the dataset was last synced (ISO8601), or nil — anchors the novelty badges."
  def synced_at, do: data().synced_at

  @novelty_days 7

  @doc "The novelty window in days (the wiki-edit recency that counts as NEW)."
  def novelty_days, do: @novelty_days

  @doc """
  How many days ago the WIKI last edited this entry's page, or nil when
  unknown. This — not our own sync bookkeeping — is what "novidade" means:
  it recycles itself as time passes, and a first-ever sync doesn't paint the
  whole base as new (per Lucas: new means new ON THE WIKI in the last seven
  days, not new to this local base).
  """
  def wiki_age_days(entry, today \\ nil) do
    today = today || Date.utc_today()

    with date when is_binary(date) <- entry.edited_at,
         {:ok, edited} <- Date.from_iso8601(date) do
      Date.diff(today, edited)
    else
      _unknown -> nil
    end
  end

  @doc "Fresh on the WIKI: edited within `novelty_days` (nil when older/unknown)."
  def novelty(entry, today \\ nil) do
    case wiki_age_days(entry, today) do
      days when is_integer(days) and days >= 0 and days <= @novelty_days -> {:wiki, days}
      _older_or_unknown -> nil
    end
  end

  def get(name), do: Enum.find(species(), &(&1.name == name))

  @doc "Every species name — the lexicon a screen reading is closed against."
  def names, do: Enum.map(species(), & &1.name)

  # The origin lives in config (`:wiki_base`) — the one place the specific
  # server is named, so the rest of this codebase can say PokeTibia.
  defp wiki_base, do: Application.get_env(:pokex, :wiki_base) <> "/index.php/"

  @doc """
  The entry's page on the PokeTibia wiki — where every field here came from, and
  the escape hatch whenever the harvest still looks thin (Lucas asked for the
  original wiki link on every pokémon). Derived from the name exactly like
  the scraper derives it, so the link points at the page we actually read.
  """
  def wiki_url(%{name: name}) when is_binary(name) and name != "",
    do: wiki_base() <> URI.encode(String.replace(name, " ", "_"))

  def wiki_url(_nameless), do: nil

  @doc """
  Filtered species search. Filters compose (all must match):

    * `:name` — case-insensitive substring
    * `:elements` — species has ANY of these elements (list; the old singular
      `:element` binary still works, for bookmarked URLs)
    * `:weak_to` — ANY of these elements hits the species hard (list, or the
      old singular binary)
    * `:clans` — species belongs to ANY of these PokeTibia clans (derived from materia)
    * `:min_level` / `:max_level` — inclusive bounds (species without a level drop)
    * `:only_shiny` — only Shiny variants
    * `:edited_after` — wiki page edited on/after this "YYYY-MM-DD" (entries
      without a known edit date drop when this filter is on)
    * `:only_novelty` — only entries the LAST sync brought in or changed

  Sorting (`:sort` + `:desc`): `:number` (default), `:name`, `:level`,
  `:element`, `:weak_to`, `:shiny`, `:edited` (the WIKI's own edit date —
  which pokémon the wiki touched last) or `:changed` (OUR last content
  change). Missing values always sink to the bottom, in BOTH directions —
  a level-less entry is never the "highest level".
  """
  def search(filters) when is_map(filters) do
    {sort, desc?, filters} = pop_sort(filters)

    species()
    |> Enum.filter(&matches?(&1, filters))
    |> sort_entries(sort, desc?)
  end

  @page_size 100

  @doc """
  One page of `search/1`, by CURSOR (keyset), for the infinite scroll:
  `%{entries, cursor, total}` — `cursor` is nil when the last page came back.

  Keyset, not offset: the dataset is replaced wholesale by a sync, and an
  offset would then skip or repeat entries mid-scroll. The cursor is the last
  row's ORDERING KEY with a stable tiebreaker appended (the playbook's rule —
  "append a stable tiebreaker so pages don't overlap"): here `{bucket, key,
  name}`, where `name` is unique and `bucket` keeps the missing-value rows
  pinned to the bottom in both directions. Resuming compares against that key
  rather than looking the row up, so a page still resolves correctly when the
  row it pointed at disappeared between pages.

  `total` is free here (the base lives in memory), so unlike a SQL COUNT it
  needs no opt-in.
  """
  def page(filters, cursor \\ nil, limit \\ @page_size) when is_map(filters) do
    {sort, desc?, filters} = pop_sort(filters)

    ordered =
      species()
      |> Enum.filter(&matches?(&1, filters))
      |> sort_entries(sort, desc?)

    rest =
      case cursor do
        nil ->
          ordered

        cursor ->
          Enum.drop_while(ordered, &(not after_cursor?(cursor_key(&1, sort), cursor, desc?)))
      end

    entries = Enum.take(rest, limit)

    %{
      entries: entries,
      cursor:
        if(entries != [] and length(rest) > limit,
          do: cursor_key(List.last(entries), sort)
        ),
      total: length(ordered)
    }
  end

  @doc "The default page size of `page/3`."
  def page_size, do: @page_size

  defp pop_sort(filters) do
    {sort, filters} = Map.pop(filters, :sort)
    {desc?, filters} = Map.pop(filters, :desc)
    {sort, desc?, filters}
  end

  defp sort_entries(entries, sort, desc?) do
    {missing, present} = Enum.split_with(entries, &missing_key?(sort_key(&1, sort)))

    Enum.sort_by(present, &{sort_key(&1, sort), &1.name}, direction(desc?)) ++
      Enum.sort_by(missing, &{&1.number || 9_999, &1.name})
  end

  defp missing_key?(key), do: key in [nil, "", []]

  # {bucket, key, name}: bucket 1 (missing) always sorts last, and `name`
  # breaks ties so two lv-50 species can never straddle a page boundary.
  defp cursor_key(entry, sort) do
    case sort_key(entry, sort) do
      key when key in [nil, "", []] -> {1, entry.number || 9_999, entry.name}
      key -> {0, key, entry.name}
    end
  end

  # Strictly after the cursor, in the SAME order the page was sorted in.
  defp after_cursor?({bucket, key, name}, {c_bucket, c_key, c_name}, desc?) do
    cond do
      bucket != c_bucket -> bucket > c_bucket
      # the missing bucket is always ascending by number/name
      bucket == 1 -> {key, name} > {c_key, c_name}
      desc? -> {key, name} < {c_key, c_name}
      true -> {key, name} > {c_key, c_name}
    end
  end

  defp direction(true), do: :desc
  defp direction(_asc), do: :asc

  defp sort_key(entry, :name), do: entry.name
  defp sort_key(entry, :level), do: entry.level
  defp sort_key(entry, :element), do: List.first(entry.elements)
  defp sort_key(entry, :weak_to), do: List.first(entry.weak_to)
  defp sort_key(entry, :edited), do: entry.edited_at
  defp sort_key(entry, :changed), do: entry.changed_at || entry.first_seen_at
  # shiny variants first (or last, flipped): the base form's own name groups
  # each pair together, so a Shiny sits beside its base either way
  defp sort_key(entry, :shiny), do: {entry.shiny_of == nil, entry.shiny_of || entry.name}
  defp sort_key(entry, _number_or_unknown), do: entry.number || 9_999

  @doc "The Shiny variants a lure can hook, with the fishing level of each tier."
  def shinies_for_lure(lure_name) do
    case Enum.find(lures(), &(&1.name == lure_name)) do
      nil ->
        []

      lure ->
        for tier <- lure.tiers,
            name <- tier.pokemon,
            String.starts_with?(name, "Shiny "),
            do: %{name: name, fishing_level: tier.fishing_level}
    end
  end

  @doc "Which lures can hook `name`, as [%{lure, fishing_level}] (all tiers)."
  def lures_for(name) do
    for lure <- lures(), tier <- lure.tiers, name in tier.pokemon do
      %{lure: lure.name, fishing_level: tier.fishing_level}
    end
  end

  @doc """
  Hunt suggestions for the team: `%{targets, threats}`.

  TARGETS — base species at least one member hits super-effectively (a member
  element inside the target's weak_to), ranked by a transparent score:
  +2 per weakness hit, -2 per member element the target RESISTS, +1 when a
  Shiny variant exists (upside!), +1 when fishable. Each row names the best
  member and carries the reasons, so the ranking is auditable on screen.

  THREATS — species whose own elements hit a member's weaknesses (who hits
  ME hard), one row per species with every endangered member, ranked by
  how many members it endangers, then by level.

  LEVEL WINDOW (Lucas: the old suggestions ran far below his level): pass
  `:player_level` (+ optional `:level_margin`, default 15) and
  targets are drawn from species within player_level ± margin — the hunts
  that are actually worth his time. When NOTHING lives in the window (lv 200
  with no lv-200 species), the pool falls back to the species BELOW his
  level, ranked closest-first, so the answer stays useful instead of empty.
  The returned `:window` says which mode answered:
  `{:window, lo, hi}` | `{:below, player_level}` | `:all`.

  Remaining `filters` narrow the pool with the same options as `search/1`.
  """
  def hunt_suggestions(member_names, filters \\ %{}) do
    {player_level, filters} = Map.pop(filters, :player_level)
    {margin, filters} = Map.pop(filters, :level_margin)

    members = member_names |> Enum.map(&get/1) |> Enum.reject(&is_nil/1)

    candidates =
      search(filters)
      |> Enum.filter(&(&1.shiny_of == nil and &1.name not in member_names))

    {pool, window} = level_pool(candidates, player_level, margin)

    %{
      window: window,
      targets:
        pool
        |> Enum.map(&target_row(&1, members))
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(&{-&1.score, proximity(&1.entry, player_level), &1.entry.number || 9_999}),
      threats:
        candidates
        |> Enum.map(&threat_row(&1, members))
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(&{-length(&1.members), -(&1.entry.level || 0)})
    }
  end

  # No player level → everything competes (the old behavior). With one, only
  # species with a KNOWN level can be judged; the window keeps the hunt near
  # his strength, and an empty window degrades to closest-below, never to [].
  defp level_pool(candidates, nil, _margin), do: {candidates, :all}

  defp level_pool(candidates, player_level, margin) do
    margin = margin || 15
    leveled = Enum.filter(candidates, &is_integer(&1.level))
    {lo, hi} = {player_level - margin, player_level + margin}
    windowed = Enum.filter(leveled, &(&1.level >= lo and &1.level <= hi))

    cond do
      windowed != [] ->
        {windowed, {:window, max(lo, 1), hi}}

      (below = Enum.filter(leveled, &(&1.level <= player_level))) != [] ->
        {below, {:below, player_level}}

      true ->
        {leveled, :all}
    end
  end

  defp proximity(_entry, nil), do: 0
  defp proximity(entry, player_level), do: abs((entry.level || 0) - player_level)

  defp target_row(target, members) do
    scored =
      for member <- members,
          hits = Enum.filter(member.elements, &(&1 in target.weak_to)),
          hits != [] do
        resisted = Enum.filter(member.elements, &(&1 in target.resists))
        {2 * length(hits) - 2 * length(resisted), member, hits, resisted}
      end

    case Enum.max_by(scored, &elem(&1, 0), fn -> nil end) do
      nil ->
        nil

      {base_score, member, hits, resisted} ->
        lures = lures_for(target.name)
        shiny? = target.shiny_name != nil

        %{
          entry: target,
          member: member.name,
          hits: hits,
          resisted: resisted,
          shiny?: shiny?,
          lures: lures,
          score: base_score + if(shiny?, do: 1, else: 0) + if(lures != [], do: 1, else: 0)
        }
    end
  end

  defp threat_row(target, members) do
    endangered =
      for member <- members,
          via = Enum.filter(target.elements, &(&1 in member.weak_to)),
          via != [],
          do: {member.name, via}

    case endangered do
      [] ->
        nil

      list ->
        %{
          entry: target,
          members: Enum.map(list, &elem(&1, 0)),
          via: list |> Enum.flat_map(&elem(&1, 1)) |> Enum.uniq()
        }
    end
  end

  @doc "Every element seen in the dataset (for filter selects)."
  def elements do
    species()
    |> Enum.flat_map(&(&1.elements ++ &1.weak_to))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "True when the scraped dataset is present (the page hints at the mix task when not)."
  def loaded?, do: species() != []

  @doc "Re-reads the JSON (after a sync) and replaces the cached dataset in place."
  def reload do
    path = data_path()
    :persistent_term.put({__MODULE__, path}, load(path))
    :ok
  end

  # -- filtering ---------------------------------------------------------------

  defp matches?(entry, filters), do: Enum.all?(filters, &filter_matches?(entry, &1))

  defp filter_matches?(entry, {:name, text}) when is_binary(text) and text != "" do
    String.contains?(String.downcase(entry.name), String.downcase(text))
  end

  defp filter_matches?(entry, {:element, element}) when is_binary(element) and element != "" do
    element in entry.elements
  end

  defp filter_matches?(entry, {:weak_to, element}) when is_binary(element) and element != "" do
    element in entry.weak_to
  end

  # Multi-value groups (the non-exclusive filters): the entry matches when it
  # has ANY of the selected values — "all grass AND all poison" is ONE group
  # with two values, not two exclusive searches.

  defp filter_matches?(entry, {:elements, list}) when is_list(list) and list != [] do
    Enum.any?(list, &(&1 in entry.elements))
  end

  defp filter_matches?(entry, {:weak_to, list}) when is_list(list) and list != [] do
    Enum.any?(list, &(&1 in entry.weak_to))
  end

  defp filter_matches?(entry, {:clans, list}) when is_list(list) and list != [] do
    Enum.any?(list, &(&1 in entry.clans))
  end

  defp filter_matches?(entry, {:min_level, min}) when is_integer(min) do
    is_integer(entry.level) and entry.level >= min
  end

  defp filter_matches?(entry, {:max_level, max}) when is_integer(max) do
    is_integer(entry.level) and entry.level <= max
  end

  defp filter_matches?(entry, {:only_shiny, true}) do
    entry.shiny_of != nil

    # ISO dates compare correctly as strings
  end

  defp filter_matches?(entry, {:edited_after, date}) when is_binary(date) and date != "" do
    is_binary(entry.edited_at) and entry.edited_at >= date
  end

  defp filter_matches?(entry, {:only_novelty, true}) do
    novelty(entry) != nil
  end

  defp filter_matches?(_entry, _ignored_filter) do
    true
  end

  # -- loading -----------------------------------------------------------------

  defp data do
    path = data_path()
    key = {__MODULE__, path}

    case :persistent_term.get(key, :missing) do
      :missing ->
        loaded = load(path)
        :persistent_term.put(key, loaded)
        loaded

      loaded ->
        loaded
    end
  end

  defp data_path do
    Application.get_env(:pokex, :pokedex_path) ||
      Application.app_dir(:pokex, "priv/pokedex/pokedex.json")
  end

  defp load(path) do
    with {:ok, bin} <- File.read(path),
         {:ok, json} <- JSON.decode(bin) do
      %{
        species: (json["species"] || []) |> Enum.map(&species_entry/1) |> inherit_clans(),
        lures: Enum.map(json["lures"] || [], &lure_entry/1),
        synced_at: json["scraped_at"]
      }
    else
      _missing_or_corrupt -> %{species: [], lures: [], synced_at: nil}
    end
  end

  # The wiki writes a dual type five different ways — "Grass / Poison",
  # "Normal e Psychic", "Dragon &amp; Flying", "Ice. Poison", "flying and bug"
  # — and sometimes in lowercase. Unsplit, 30 entries carried a single bogus
  # element: filtering by Flying simply MISSED Rayquaza, and the filter's own
  # option list showed 40 phantom "elements". Normalising here (not in the
  # scraper) heals the base already on disk, with no re-sync.
  # No PokeTibia element name has a space, so whitespace is a separator too — that is
  # what rescues "Ice Poison", written with no separator at all.
  @element_separators ~r{\s*(?:/|&amp;|&|,|\.|\be\b|\band\b)\s*|\s+}

  # One-off wiki misspellings, each measured at 1-5 occurrences in the whole
  # base (against Crystal's 865, which is a REAL PokeTibia type, not a typo).
  @element_aliases %{
    "Gound" => "Ground",
    "Groud" => "Ground",
    "Earth" => "Ground",
    "Posion" => "Poison",
    "Fly" => "Flying",
    "Metal" => "Steel"
  }

  defp normalize_elements(list) do
    (list || [])
    |> Enum.flat_map(&String.split(&1, @element_separators, trim: true))
    |> Enum.map(fn element ->
      element = element |> String.trim() |> String.capitalize()
      Map.get(@element_aliases, element, element)
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  # 18 of the 80 materia-less entries are Shiny variants whose base form HAS
  # one — same creature, same clan, so inherit it instead of showing "no clan".
  defp inherit_clans(species) do
    by_name = Map.new(species, &{&1.name, &1})

    Enum.map(species, fn
      %{clans: [], shiny_of: base_name} = entry when is_binary(base_name) ->
        case by_name[base_name] do
          %{clans: clans} -> %{entry | clans: clans}
          nil -> entry
        end

      entry ->
        entry
    end)
  end

  defp species_entry(map) do
    %{
      name: map["name"],
      number: map["number"],
      level: map["level"],
      elements: normalize_elements(map["elements"]),
      boost: map["boost"],
      habilidades: map["habilidades"] || [],
      materia: map["materia"],
      # PokeTibia clan(s), derived from materia at load time — filterable, with no
      # hand-marking of 866 entries; a shiny without materia inherits from its
      # base form (see inherit_clans/1)
      clans: Clans.parse(map["materia"]),
      evolution_stones: map["evolution_stones"] || [],
      description: map["description"],
      # effectiveness lines are element lists too — same five spellings, same
      # normalisation, or "fraco contra Flying" misses "Flying e Rock"
      weak_to: normalize_elements(map["weak_to"]),
      resists: normalize_elements(map["resists"]),
      neutral: normalize_elements(map["neutral"]),
      # elements that do NOTHING to it ("Nulo"/"Imune") — absent from older
      # scrapes, which simply never read that line
      immune: normalize_elements(map["immune"]),
      # the tiers as the page words them ("Efetivo" vs "Muito Efetivo"), so the
      # detail page can show two strengths instead of one flattened list
      effectiveness:
        Enum.map(map["effectiveness"] || [], fn tier ->
          %{
            label: tier["label"],
            kind: tier["kind"],
            elements: normalize_elements(tier["elements"])
          }
        end),
      evolutions:
        Enum.map(map["evolutions"] || [], fn evo ->
          %{name: evo["name"], level: evo["level"]}
        end),
      # nil = entry predates the moves scrape (the page hints at re-sync);
      # [] = scraped and the page truly has no table
      moves: map["moves"] && Enum.map(map["moves"], &move_entry/1),
      # the PVP moveset — same slots, different cooldowns; kept apart so the
      # hunting (PVE) numbers are never mixed with it
      moves_pvp: map["moves_pvp"] && Enum.map(map["moves_pvp"], &move_entry/1),
      sprite: map["sprite"],
      shiny_of: map["shiny_of"],
      shiny_name: map["shiny_name"],
      edited_at: map["edited_at"],
      scraped_at: map["scraped_at"],
      # our own clock (see Scraper.upsert): when this entry ENTERED the base
      # and when its content last actually changed — the novelty signals
      first_seen_at: map["first_seen_at"],
      changed_at: map["changed_at"]
    }
  end

  defp move_entry(map) do
    %{
      slot: map["slot"],
      name: map["name"],
      cooldown_s: map["cooldown_s"],
      element: map["element"],
      tags: map["tags"] || [],
      level: map["level"]
    }
  end

  defp lure_entry(map) do
    %{
      name: map["name"],
      tiers:
        Enum.map(map["tiers"] || [], fn tier ->
          %{fishing_level: tier["fishing_level"], pokemon: tier["pokemon"] || []}
        end)
    }
  end
end
