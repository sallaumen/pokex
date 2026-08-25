defmodule Pokex.Pokedex do
  @moduledoc """
  The local Pokédex: every species (and its Shiny variant) fetched from the
  wiki's API by `mix pokedex.sync`, loaded once from priv/pokedex/pokedex.json
  and served from :persistent_term — pure reads, no process.

  This is the queryable base Lucas asked for (search by level, element,
  weakness, generation, tier) AND the shiny-detector's reference set (each
  entry carries its sprite, shinies included). Re-syncing rewrites the JSON;
  the app picks it up on the next restart.

  The four effectiveness buckets are NOT in the file: the wiki publishes no
  effectiveness at all, so `Pokex.Pokedex.TypeChart` derives them from each
  entry's elements at load time. The file holds only what the wiki said.
  """

  alias Pokex.Pokedex.TypeChart

  @doc "Every species entry (shiny variants included, `shiny_of` set on them)."
  def species, do: data().species

  @doc "When the dataset was last synced (ISO8601), or nil."
  def synced_at, do: data().synced_at

  def get(name), do: Enum.find(species(), &(&1.name == name))

  @doc "Every species name — the lexicon a screen reading is closed against."
  def names, do: Enum.map(species(), & &1.name)

  @doc """
  The same species in the other skin: `variant_of(bulbasaur, "shiny")`.

  Asked by NUMBER and variant, which is the pairing the wiki actually
  publishes — the PokeXGames base carried a `shiny_name` string on the normal
  form, and the Poké Alliance has no such field.
  """
  def variant_of(%{number: number}, variant) when is_integer(number) and is_binary(variant),
    do: Enum.find(species(), &(&1.number == number and &1.variant == variant))

  def variant_of(_numberless, _variant), do: nil

  @doc """
  The entry's page on the wiki — where every field here came from, and the
  escape hatch whenever the harvest still looks thin (Lucas asked for the
  original wiki link on every pokémon). Built from the entry's OWN path, so
  the link points at the page we actually read.
  """
  def wiki_url(%{path: path}) when is_binary(path) and path != "",
    do: Application.get_env(:pokex, :wiki_base) <> "/" <> path

  def wiki_url(_pathless), do: nil

  @doc "Every generation in the dataset (for the filter chips)."
  def generations, do: species() |> Enum.map(& &1.generation) |> distinct_sorted()

  @doc "Every tier in the dataset, ordered the way the wiki's own filter orders them."
  def tiers, do: species() |> Enum.map(& &1.tier) |> distinct() |> Enum.sort_by(&tier_rank/1)

  @doc "Every role in the dataset (PVE/PVP)."
  def roles, do: species() |> Enum.map(& &1.role) |> distinct_sorted()

  defp distinct(values), do: values |> Enum.reject(&is_nil/1) |> Enum.uniq()
  defp distinct_sorted(values), do: values |> distinct() |> Enum.sort()

  # The wiki's own filter order: ULTIMATE, tiers 1-7, then the named ones.
  @tier_order ~w(ULTIMATE 1 2 3 4 5 6 7) ++ ["Super Rare", "Legendary", "Mythic", "Ultra Rare"]

  defp tier_rank(tier) do
    case Enum.find_index(@tier_order, &(&1 == tier)) do
      nil -> length(@tier_order)
      index -> index
    end
  end

  @doc """
  Filtered species search. Filters compose (all must match):

    * `:name` — case-insensitive substring
    * `:elements` — species has ANY of these elements (list; the old singular
      `:element` binary still works, for bookmarked URLs)
    * `:weak_to` — ANY of these elements hits the species hard (list, or the
      old singular binary)
    * `:generations` — species belongs to ANY of these generations (list of integers)
    * `:tiers` — species sits in ANY of these tiers (list; "ULTIMATE", "6", "Legendary"…)
    * `:roles` — species is marked for ANY of these roles (list; "PVE"/"PVP")
    * `:variant` — `"normal"` or `"shiny"` (absent/"" means both)
    * `:min_level` / `:max_level` — inclusive bounds (species without a level drop)

  Sorting (`:sort` + `:desc`): `:number` (default), `:name`, `:level`,
  `:element`, `:weak_to`, `:shiny`, `:tier` or `:generation`. Missing values
  always sink to the bottom, in BOTH directions — a level-less entry is never
  the "highest level", and a tier-less one is never the strongest.
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
  defp sort_key(entry, :tier), do: entry.tier && tier_rank(entry.tier)
  defp sort_key(entry, :generation), do: entry.generation
  # shiny variants first (or last, flipped): the base form's own name groups
  # each pair together, so a Shiny sits beside its base either way
  defp sort_key(entry, :shiny), do: {entry.shiny_of == nil, entry.shiny_of || entry.name}
  defp sort_key(entry, _number_or_unknown), do: entry.number || 9_999

  @doc """
  Hunt suggestions for the team: `%{targets, threats}`.

  TARGETS — base species at least one member hits super-effectively (a member
  element inside the target's weak_to), ranked by a transparent score:
  +2 per weakness hit, -2 per member element the target RESISTS, +1 when a
  Shiny variant exists (upside!). Each row names the best member and carries
  the reasons, so the ranking is auditable on screen.

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
      |> Enum.filter(&(&1.variant == "normal" and &1.name not in member_names))

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
        shiny? = variant_of(target, "shiny") != nil

        %{
          entry: target,
          member: member.name,
          hits: hits,
          resisted: resisted,
          shiny?: shiny?,
          score: base_score + if(shiny?, do: 1, else: 0)
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

  @doc "The eighteen elements, for the filter chips — the chart's list, not the dataset's."
  def elements, do: TypeChart.elements()

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

  defp filter_matches?(entry, {:generations, list}) when is_list(list) and list != [] do
    entry.generation in list
  end

  defp filter_matches?(entry, {:tiers, list}) when is_list(list) and list != [] do
    entry.tier in list
  end

  defp filter_matches?(entry, {:roles, list}) when is_list(list) and list != [] do
    entry.role in list
  end

  defp filter_matches?(entry, {:variant, variant}) when is_binary(variant) and variant != "" do
    entry.variant == variant
  end

  defp filter_matches?(entry, {:min_level, min}) when is_integer(min) do
    is_integer(entry.level) and entry.level >= min
  end

  defp filter_matches?(entry, {:max_level, max}) when is_integer(max) do
    is_integer(entry.level) and entry.level <= max
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
        species: Enum.map(json["species"] || [], &species_entry/1),
        synced_at: json["scraped_at"]
      }
    else
      _missing_or_corrupt -> %{species: [], synced_at: nil}
    end
  end

  # The four effectiveness buckets are DERIVED here, not read: the wiki
  # publishes no effectiveness at all, so pokedex.json holds only what the
  # wiki said and `TypeChart` answers the rest. Correcting a chart cell is an
  # edit, not a re-sync of 910 pages.
  defp species_entry(map) do
    elements = map["elements"] || []

    %{
      name: map["name"],
      number: map["number"],
      generation: map["generation"],
      variant: map["variant"],
      shiny_of: map["shiny_of"],
      level: map["level"],
      tier: map["tier"],
      role: map["role"],
      hp: map["hp"],
      experience: map["experience"],
      elements: elements,
      habilidades: map["habilidades"] || [],
      description: map["description"],
      moves: map["moves"] && Enum.map(map["moves"], &move_entry/1),
      evolves_to: Enum.map(map["evolves_to"] || [], &evolution_entry/1),
      evolves_from: Enum.map(map["evolves_from"] || [], &evolution_entry/1),
      sprite: map["sprite"],
      path: map["path"],
      weak_to: TypeChart.weak_to(elements),
      resists: TypeChart.resists(elements),
      neutral: TypeChart.neutral(elements),
      immune: TypeChart.immune(elements),
      effectiveness: TypeChart.effectiveness(elements),
      scraped_at: map["scraped_at"],
      # our own clock (see Pokex.Pokedex.Upsert): when this entry ENTERED the
      # base and when its content last actually changed
      first_seen_at: map["first_seen_at"],
      changed_at: map["changed_at"]
    }
  end

  defp move_entry(map) do
    %{
      slot: map["slot"],
      name: map["name"],
      cooldown_s: map["cooldown_s"],
      element: map["element"]
    }
  end

  defp evolution_entry(map) do
    %{name: map["name"], level: map["level"], items: map["items"] || []}
  end
end
