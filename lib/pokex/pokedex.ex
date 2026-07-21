defmodule Pokex.Pokedex do
  @moduledoc """
  The local Pokédex: every species (and its Shiny variant) scraped from the
  PXG wiki by `mix pokedex.scrape`, loaded once from priv/pokedex/pokedex.json
  and served from :persistent_term — pure reads, no process.

  This is the queryable base Lucas asked for ("pesquisar por level, elemento,
  fraqueza") AND the future shiny-detector's reference set (each entry carries
  its sprite, shinies included). Re-scraping rewrites the JSON; the app picks
  it up on the next restart.
  """

  @doc "Every species entry (shiny variants included, `shiny_of` set on them)."
  def species, do: data().species

  @doc "Every fishing lure with its level tiers."
  def lures, do: data().lures

  def get(name), do: Enum.find(species(), &(&1.name == name))

  @doc """
  Filtered species search. Filters compose (all must match):

    * `:name` — case-insensitive substring
    * `:element` — species has this element
    * `:weak_to` — this element hits the species hard (Muito Efetivo)
    * `:min_level` / `:max_level` — inclusive bounds (species without a level drop)
    * `:only_shiny` — only Shiny variants
    * `:edited_after` — wiki page edited on/after this "YYYY-MM-DD" (entries
      without a known edit date drop when this filter is on)
  """
  def search(filters) when is_map(filters) do
    species()
    |> Enum.filter(&matches?(&1, filters))
    |> Enum.sort_by(&{&1.number || 9_999, &1.name})
  end

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

  THREATS — species whose own elements hit a member's weaknesses ("quem bate
  forte em MIM"), one row per species with every endangered member, ranked by
  how many members it endangers, then by level.

  LEVEL WINDOW (Lucas: "você está recomendando pokémons de level muito
  baixo"): pass `:player_level` (+ optional `:level_margin`, default 15) and
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

  defp matches?(entry, filters) do
    Enum.all?(filters, fn
      {:name, text} when is_binary(text) and text != "" ->
        String.contains?(String.downcase(entry.name), String.downcase(text))

      {:element, element} when is_binary(element) and element != "" ->
        element in entry.elements

      {:weak_to, element} when is_binary(element) and element != "" ->
        element in entry.weak_to

      {:min_level, min} when is_integer(min) ->
        is_integer(entry.level) and entry.level >= min

      {:max_level, max} when is_integer(max) ->
        is_integer(entry.level) and entry.level <= max

      {:only_shiny, true} ->
        entry.shiny_of != nil

      # ISO dates compare correctly as strings
      {:edited_after, date} when is_binary(date) and date != "" ->
        is_binary(entry.edited_at) and entry.edited_at >= date

      _off ->
        true
    end)
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
        lures: Enum.map(json["lures"] || [], &lure_entry/1)
      }
    else
      _missing_or_corrupt -> %{species: [], lures: []}
    end
  end

  defp species_entry(map) do
    %{
      name: map["name"],
      number: map["number"],
      level: map["level"],
      # scrapes prior to the dual-type fix stored "Grass / Poison" as one item
      elements: Enum.flat_map(map["elements"] || [], &String.split(&1, ~r{\s*/\s*}, trim: true)),
      boost: map["boost"],
      habilidades: map["habilidades"] || [],
      materia: map["materia"],
      evolution_stones: map["evolution_stones"] || [],
      description: map["description"],
      weak_to: map["weak_to"] || [],
      resists: map["resists"] || [],
      neutral: map["neutral"] || [],
      evolutions:
        Enum.map(map["evolutions"] || [], fn evo ->
          %{name: evo["name"], level: evo["level"]}
        end),
      # nil = entry predates the moves scrape (the page hints at re-sync);
      # [] = scraped and the page truly has no table
      moves: map["moves"] && Enum.map(map["moves"], &move_entry/1),
      sprite: map["sprite"],
      shiny_of: map["shiny_of"],
      shiny_name: map["shiny_name"],
      edited_at: map["edited_at"],
      scraped_at: map["scraped_at"]
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
