defmodule Pokex.Bots.Cavebot.HandsRead do
  @moduledoc """
  Reading, from his own keyboard, what he was doing at a waypoint.

  "Quando eu aperto Shift+3 é pq eu já terminei de matar tudo, quando eu aperto
  shift+1 é por que vou matar monstro" (Lucas, 2026-08-11). Those two presses
  are the boundaries of a fight, told by the hand that fights it — no
  inference, no threshold, no guess. Between them are the skills he actually
  used, and the pause before the first one is the huddle he waits out while
  the pile closes in.

  Pure: it takes the presses the Rig drained and the state carried between
  drains, and answers what changed. What to DO with that is the page's.
  """

  alias Pokex.Rig.Mac.Commands

  @typedoc "What his hands said, between two drains."
  @type reading :: %{
          fight_started?: boolean,
          gathering_started?: boolean,
          fight_ms: non_neg_integer | nil,
          combo: [String.t()],
          gather_ms: non_neg_integer | nil
        }

  @typedoc "Carried between drains — nothing here survives a recording."
  @type state :: %{
          fight_at: integer | nil,
          parked_at: integer | nil,
          first_skill?: boolean
        }

  @doc "The state a fresh recording starts from."
  @spec new() :: state
  def new, do: %{fight_at: nil, parked_at: nil, first_skill?: false}

  @doc """
  Marks the moment he parked the pokémon (his middle click), which is where
  the huddle starts being counted.
  """
  @spec parked(state, integer) :: state
  def parked(state, at), do: %{state | parked_at: at, first_skill?: false}

  @doc """
  Folds one drain of presses into `{state, reading}`.

  Every key is named the way the game names it ("1", "3", …); `shift?` is what
  separates a skill from a MODE change, because shift+1 and 1 are the same key
  to the keyboard and opposite things to him.
  """
  @spec read(state, [map]) :: {state, reading}
  def read(state, events) do
    Enum.reduce(events, {state, blank()}, fn event, {state, reading} ->
      step(state, reading, key_for(event), event)
    end)
  end

  defp blank,
    do: %{
      fight_started?: false,
      gathering_started?: false,
      fight_ms: nil,
      combo: [],
      gather_ms: nil
    }

  # shift+1: "vou matar monstro" — the fight starts here.
  defp step(state, reading, "1", %{shift?: true, at: at}),
    do: {%{state | fight_at: at}, %{reading | fight_started?: true}}

  # shift+3: "já terminei de matar tudo" — the fight's length is known, and he
  # is back in the game's defence mode, which is the one a gathering is walked
  # in ("o shift+3 é o modo mobando", 2026-08-11). It says the second thing
  # even with no fight open: pressing it IS going back to gathering.
  defp step(%{fight_at: nil} = state, reading, "3", %{shift?: true}),
    do: {state, %{reading | gathering_started?: true}}

  defp step(state, reading, "3", %{shift?: true, at: at}) do
    {%{state | fight_at: nil},
     %{reading | fight_ms: max(at - state.fight_at, 0), gathering_started?: true}}
  end

  # any other modified press is somebody else's business
  defp step(state, reading, _key, %{shift?: true}), do: {state, reading}

  defp step(state, reading, nil, _event), do: {state, reading}

  # a bare skill key: the combo, and the first one closes the huddle
  defp step(state, reading, key, %{at: at}) do
    reading = %{reading | combo: reading.combo ++ [key]}

    if state.parked_at && not state.first_skill? do
      {%{state | first_skill?: true}, %{reading | gather_ms: max(at - state.parked_at, 0)}}
    else
      {state, reading}
    end
  end

  @doc "The keycodes worth watching: the whole hotbar, which is also shift+1/shift+3."
  @spec codes() :: [non_neg_integer]
  def codes do
    ~w(1 2 3 4 5 6 7 8 9 0)
    |> Enum.map(&Commands.keycode/1)
    |> Enum.flat_map(fn
      {:ok, code} -> [code]
      :error -> []
    end)
  end

  defp key_for(%{code: code}) do
    Enum.find(~w(1 2 3 4 5 6 7 8 9 0), fn key ->
      match?({:ok, ^code}, Commands.keycode(key))
    end)
  end
end
