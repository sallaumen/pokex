defmodule Pokex.Pokedex.Clans do
  @moduledoc """
  The PXG clan of a species, DERIVED from the wiki's "Materia" field — no new
  scraping and no hand-marking 866 entries: "Naturia Enhanced ou Malefic
  Enhanced" already names the clan(s); the tier suffix is noise here.

  Measured on the full 2026-07-22 base (866 entries, 178 distinct materia
  strings): every one decomposes into the 10 clans below × an optional tier
  (Enhanced/Superior/Mastered), joined by "ou" — plus three wiki quirks this
  module absorbs: the English "or" (4 pages), one "e", and the "Oreboun" typo.
  """

  @clans ~w(Volcanic Seavell Orebound Wingeon Raibolt Gardestrike Naturia Malefic Psycraft Ironhard)

  @typos %{"Oreboun" => "Orebound"}

  @doc "The 10 PXG clans, canonical order — the filter UI's option list."
  def all, do: @clans

  @doc """
  Clan name(s) inside a materia string, deduped, page order kept. An unknown
  word is dropped, never invented; nil/"" parse to [].
  """
  def parse(nil), do: []

  def parse(materia) when is_binary(materia) do
    materia
    |> String.split(~r/\s+(?:ou|or|e)\s+/i)
    |> Enum.flat_map(fn part ->
      first = part |> String.trim() |> String.split() |> List.first()
      clan = Map.get(@typos, first, first)
      if clan in @clans, do: [clan], else: []
    end)
    |> Enum.uniq()
  end
end
