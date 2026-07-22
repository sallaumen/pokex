defmodule Pokex.Pokedex.Team do
  @moduledoc """
  Lucas's OWN Pokémon (~/.pokex/team.json), now in two lists: the active
  TEAM he hunts with and the BANK ("o que não está no meu time, mas eu tenho
  no banco guardado"). Each entry carries an optional LEVEL, and the file
  also stores his character level + the hunt-window margin — what makes the
  /time suggestions match his real strength instead of recommending lv-5
  targets at lv 88.

  Names must exist in the scraped Pokédex (Shiny variants allowed — owning
  one is real). Same storage philosophy as Settings/Calibration profiles:
  a tiny JSON under the Pokex home, no process. Files written by the v1
  module (a bare list of names) load transparently as a level-less team.
  """

  alias Pokex.{Home, Pokedex}

  # The in-game hotkey slots a team member can answer to: C+2..C+6 on screen.
  @slots 2..6//1 |> Enum.to_list()

  @default_margin 15

  @doc "The active team, in insertion order: [%{name, level}] (level nil = not set)."
  def members, do: read().members

  @doc "The bank (owned but not hunting): same shape as members/0."
  def bank, do: read().bank

  @doc "Just the team's names — what hunt_suggestions consumes."
  def member_names, do: Enum.map(members(), & &1.name)

  @doc "Lucas's character level (nil until he sets it on /time)."
  def player_level, do: read().player_level

  @doc "The hunt-window margin (±levels around player_level). Default #{@default_margin}."
  def level_margin, do: read().level_margin

  @doc """
  Adds a Pokédex-known name to `:team` or `:bank` (idempotent across BOTH
  lists — a name lives in one place). {:ok, data} | {:error, :unknown}.
  """
  def add(name, where \\ :team) when where in [:team, :bank] do
    case Pokedex.get(name) do
      nil ->
        {:error, :unknown}

      _entry ->
        data = read()
        target = if where == :team, do: data.members, else: data.bank

        if Enum.any?(target, &(&1.name == name)) do
          # already there — keep its position AND its level
          {:ok, data}
        else
          # relocating from the other list keeps the level too
          entry =
            Enum.find(
              data.members ++ data.bank,
              %{name: name, level: nil, slot: nil},
              &(&1.name == name)
            )

          data = drop(data, name)

          data =
            case where do
              :team -> %{data | members: data.members ++ [entry]}
              :bank -> %{data | bank: data.bank ++ [entry]}
            end

          {:ok, persist(data)}
        end
    end
  end

  @doc "Removes a name from wherever it lives (idempotent)."
  def remove(name), do: persist(drop(read(), name))

  @doc "Moves a name to the OTHER list, keeping its level. No-op if absent."
  def move(name, where) when where in [:team, :bank] do
    data = read()

    case Enum.find(data.members ++ data.bank, &(&1.name == name)) do
      nil ->
        data

      entry ->
        data = drop(data, name)

        persist(
          case where do
            :team -> %{data | members: data.members ++ [entry]}
            :bank -> %{data | bank: data.bank ++ [entry]}
          end
        )
    end
  end

  @doc ~S'The key that swaps a slot in: C+2 on screen is "ctrl+2" to the Rig.'
  def swap_key(slot) when slot in @slots, do: "ctrl+#{slot}"

  @doc """
  Which slot best answers `enemy_name`, given the team as it is RIGHT NOW.

  `live_rows` comes from the `:team` feed — `[%{slot, name}]` — because the
  C+N order changes as Lucas plays and a configured slot would send out
  whoever happens to be sitting there now. nil when nobody on screen has an
  advantage: a combo that cannot pick a counter must not run.
  """
  def best_counter(enemy_name, live_rows) do
    with %{} = enemy <- Pokedex.get(enemy_name) do
      live_rows
      |> Enum.filter(
        &(is_map(&1) and is_binary(Map.get(&1, :name)) and is_integer(Map.get(&1, :slot)))
      )
      |> Enum.map(fn row -> {row.slot, advantage(row.name, enemy)} end)
      |> Enum.filter(fn {_slot, score} -> score > 0 end)
      |> Enum.max_by(fn {_slot, score} -> score end, fn -> nil end)
      |> case do
        nil -> nil
        {slot, _score} -> slot
      end
    else
      _unknown -> nil
    end
  end

  # Same shape as the hunt scoring: hits are worth what resistances take away.
  defp advantage(member_name, enemy) do
    case Pokedex.get(member_name) do
      nil ->
        0

      member ->
        hits = Enum.count(member.elements, &(&1 in enemy.weak_to))
        resisted = Enum.count(member.elements, &(&1 in enemy.resists))
        2 * hits - 2 * resisted
    end
  end

  @doc "Sets an entry's level wherever it lives (nil clears). No-op if absent."
  def set_level(name, level) when is_integer(level) or is_nil(level) do
    data = read()

    update = fn list ->
      Enum.map(list, fn
        %{name: ^name} = entry -> %{entry | level: level}
        entry -> entry
      end)
    end

    persist(%{data | members: update.(data.members), bank: update.(data.bank)})
  end

  @doc "Sets Lucas's character level (nil clears)."
  def set_player_level(level) when is_integer(level) or is_nil(level),
    do: persist(%{read() | player_level: level})

  @doc "Sets the hunt-window margin."
  def set_level_margin(margin) when is_integer(margin) and margin > 0,
    do: persist(%{read() | level_margin: margin})

  # -- storage -----------------------------------------------------------------

  defp read do
    with {:ok, bin} <- File.read(file()),
         {:ok, json} <- JSON.decode(bin) do
      %{
        members: entries(json["members"]),
        bank: entries(json["bank"]),
        player_level: int_or_nil(json["player_level"]),
        level_margin: int_or_nil(json["level_margin"]) || @default_margin
      }
    else
      _missing_or_corrupt ->
        %{members: [], bank: [], player_level: nil, level_margin: @default_margin}
    end
  end

  # v1 stored bare name strings; v2 added "level"; v3 adds "slot" — all load.
  defp entries(list) when is_list(list) do
    list
    |> Enum.map(fn
      name when is_binary(name) ->
        %{name: name, level: nil, slot: nil}

      %{"name" => name} = map when is_binary(name) ->
        %{name: name, level: int_or_nil(map["level"]), slot: slot_or_nil(map["slot"])}

      _corrupt ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp entries(_absent), do: []

  defp int_or_nil(value) when is_integer(value), do: value
  defp int_or_nil(_other), do: nil

  defp slot_or_nil(value) when value in 2..6, do: value
  defp slot_or_nil(_other), do: nil

  defp drop(data, name) do
    %{
      data
      | members: Enum.reject(data.members, &(&1.name == name)),
        bank: Enum.reject(data.bank, &(&1.name == name))
    }
  end

  defp persist(data) do
    File.mkdir_p!(Home.dir())

    File.write!(
      file(),
      JSON.encode!(%{
        members: data.members,
        bank: data.bank,
        player_level: data.player_level,
        level_margin: data.level_margin
      })
    )

    data
  end

  defp file, do: Path.join(Home.dir(), "team.json")
end
