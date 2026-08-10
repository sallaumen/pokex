defmodule Pokex.Bots.Cavebot.Hands do
  @moduledoc """
  The hands of a HUMAN-clicked step: an UNGATED key press, run inside the
  caller's game-front block.

  Same shape as `Body.arrow_step/3`, so the walk logic cannot tell them apart —
  and the fleet's gated hands stay the only ones the HUNT ever uses. The gate's
  corner flag is proven by the Guardian, which only polls while the fleet is
  up, so a gated press with the bot stopped can never happen; that refusal
  (`:input_gate_closed`) is what the rehearsal used to answer with.

  A module of its own, not nested inside `WalkTest`: a module nested BELOW the
  code that names it resolves to a top-level `Hands` that does not exist, and
  the caller dies with an UndefinedFunctionError — silently, inside a Task,
  leaving a button spinning forever (2026-08-10).
  """

  alias Pokex.Bots.Body

  @spec arrow_step(integer, integer, keyword) :: {:ok, String.t()} | {:error, term}
  def arrow_step(0, 0, _opts), do: {:error, :no_direction}

  def arrow_step(dx, dy, _opts) do
    key = key_for(dx, dy)

    case Body.perform([{:tap, key}]) do
      :ok -> {:ok, key}
      error -> error
    end
  end

  defp key_for(dx, dy) when abs(dx) >= abs(dy), do: if(dx > 0, do: "right", else: "left")
  defp key_for(_dx, dy), do: if(dy > 0, do: "down", else: "up")
end
