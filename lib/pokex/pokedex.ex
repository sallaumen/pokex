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

  @doc "Every element seen in the dataset (for filter selects)."
  def elements do
    species()
    |> Enum.flat_map(&(&1.elements ++ &1.weak_to))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "True when the scraped dataset is present (the page hints at the mix task when not)."
  def loaded?, do: species() != []

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
      weak_to: map["weak_to"] || [],
      resists: map["resists"] || [],
      evolutions:
        Enum.map(map["evolutions"] || [], fn evo ->
          %{name: evo["name"], level: evo["level"]}
        end),
      sprite: map["sprite"],
      shiny_of: map["shiny_of"],
      shiny_name: map["shiny_name"]
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
