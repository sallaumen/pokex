defmodule Pokex.Pokedex.Team do
  @moduledoc """
  Lucas's OWN team (~/.pokex/team.json): the list of Pokémon he actually
  hunts with — the subject of `Pokex.Pokedex.hunt_suggestions/2` ("who takes
  extra damage from MY team?" / "who hits MY team hard?").

  Names must exist in the scraped Pokédex (Shiny variants allowed — owning
  one is real). Same storage philosophy as Settings/Calibration profiles:
  a tiny JSON under the Pokex home, overrides only, no process.
  """

  alias Pokex.{Home, Pokedex}

  @doc "The saved member names, in insertion order ([] when never saved/corrupt)."
  def members do
    with {:ok, bin} <- File.read(file()),
         {:ok, %{"members" => members}} when is_list(members) <- JSON.decode(bin) do
      Enum.filter(members, &is_binary/1)
    else
      _missing_or_corrupt -> []
    end
  end

  @doc "Adds a Pokédex-known name (idempotent). {:ok, members} | {:error, :unknown}."
  def add(name) do
    case Pokedex.get(name) do
      nil ->
        {:error, :unknown}

      _entry ->
        updated = Enum.uniq(members() ++ [name])
        persist(updated)
        {:ok, updated}
    end
  end

  @doc "Removes a member (idempotent). Returns the updated list."
  def remove(name) do
    updated = members() -- [name]
    persist(updated)
    updated
  end

  defp persist(list) do
    File.mkdir_p!(Home.dir())
    File.write!(file(), JSON.encode!(%{members: list}))
  end

  defp file, do: Path.join(Home.dir(), "team.json")
end
