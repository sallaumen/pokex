defmodule Pokex.Pokedex.Index do
  @moduledoc """
  The Poké Alliance's `/api/pokemon` payload → one entry per species.

  Pure: it takes ALREADY-DECODED JSON so the whole shape can be pinned against
  a real slice in a fixture, with no network in the test.

  The index — not `/api/pages` — is the base's source of truth. Of the 914
  species-looking paths the wiki lists, four are not species at all
  (`gen/2/flower`, `gen/2/lava_hole`, `gen/2/spider_egg`, `gen/4/model`) and
  the index leaves them out.
  """

  @doc """
  One entry per species: `%{path, name, number, generation, variant, level,
  tier, role, elements, image}`.

  `tier` is the DISPLAY tier — 27 species read `1` in `tier` and `ULTIMATE`
  in `displayTier`, and ULTIMATE is what the wiki's own filter offers. An
  absent tier or role comes back nil.
  """
  def parse(%{"pokemon" => list}) when is_list(list), do: Enum.map(list, &entry/1)
  def parse(_unrecognized), do: []

  @doc "Element name → the icon path the API serves it at, for the sprite pass."
  def element_icons(%{"pokemon" => list}) when is_list(list) do
    for species <- list, element <- species["elements"] || [], into: %{} do
      {capitalize(element["name"]), element["icon"]}
    end
  end

  def element_icons(_unrecognized), do: %{}

  defp entry(map) do
    %{
      path: map["path"],
      name: map["name"],
      number: to_integer(map["number"]),
      generation: to_integer(map["generation"]),
      variant: map["variant"],
      level: to_integer(map["level"]),
      tier: present(map["displayTier"]),
      role: present(map["role"]),
      elements: Enum.map(map["elements"] || [], &capitalize(&1["name"])),
      image: map["image"]
    }
  end

  # The API writes numbers both ways — `"001"` for the pokédex number, a bare
  # integer for the level.
  defp to_integer(value) when is_integer(value), do: value

  defp to_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, _rest} -> number
      :error -> nil
    end
  end

  defp to_integer(_absent), do: nil

  # A tierless species carries JSON null; "None" is the spelling the page uses
  # for the same absence.
  defp present(value) when is_binary(value) and value not in ["", "None"], do: value
  defp present(value) when is_integer(value), do: Integer.to_string(value)
  defp present(_absent), do: nil

  defp capitalize(nil), do: nil
  defp capitalize(name), do: String.capitalize(name)
end
