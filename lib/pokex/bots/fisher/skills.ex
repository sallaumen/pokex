defmodule Pokex.Bots.Fisher.Skills do
  @moduledoc """
  Chooses the next combat skill to press and PACES the presses to the game's
  global cast cooldown.

  The game accepts only one skill per cast window — fire faster and the rest are
  swallowed (measured: spamming every skill at once lands just one), which is why
  the old "press a different skill every 150ms tick" barely landed anything and
  the pokemon died on auto-attack alone. So we press ONE skill per window, walking
  the priority order (strongest first) and looping.

  Pure: given the rotation state, `now` (ms), and the cast cooldown, `decide/3`
  returns `{state, {:press, key}}` on a firing tick or `{state, :wait}` while the
  window hasn't elapsed yet.

  This module is the seam for the smarter phases:
    * Phase 2 — read the skill-bar image to skip skills that are truly on cooldown
      and fire the highest-priority READY one (the human "spam until it fires,
      then the next" behavior, made exact).
    * Phase 3 — gate proximity / area skills on the target distance.
  Both slot into `decide/3` without the driver (Logic) changing shape.
  """

  @type t :: %__MODULE__{
          order: [String.t()],
          idx: non_neg_integer(),
          last_cast_at: integer() | nil
        }
  defstruct order: [], idx: 0, last_cast_at: nil

  @doc "A fresh rotation for a new target, given the priority-ordered skill keys."
  @spec new([String.t()]) :: t()
  def new(order) when is_list(order), do: %__MODULE__{order: order}

  @doc """
  The next skill press, paced to `cast_ms` (the global cooldown between any two
  skills). Fires immediately on the first call (no prior cast this fight) and then
  at most once per `cast_ms`. A nil/non-integer `cast_ms` means "no pacing" — fire
  on every call.
  """
  @spec decide(t(), integer(), integer() | nil) :: {t(), {:press, String.t()} | :wait}
  def decide(%__MODULE__{order: []} = state, _now, _cast_ms), do: {state, :wait}

  def decide(%__MODULE__{last_cast_at: last} = state, now, cast_ms)
      when is_integer(last) and is_integer(cast_ms) and now - last < cast_ms,
      do: {state, :wait}

  def decide(%__MODULE__{order: order, idx: idx} = state, now, _cast_ms) do
    key = Enum.at(order, rem(idx, length(order)))
    {%{state | idx: idx + 1, last_cast_at: now}, {:press, key}}
  end
end
