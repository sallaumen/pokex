defmodule Pokex.Bots.Cavebot.WalkTest do
  @moduledoc """
  "Anda três passos e me diz o que aconteceu" — the hunt's smallest possible
  rehearsal.

  Arming a whole hunt to find out whether the character moves is an expensive
  question with a slow answer: combat starts, the route runs, and a failure
  arrives minutes later wearing somebody else's name. This walks a few tiles
  toward a target and reports which of the three links broke:

    * the keys never reached the game (`:did_not_move` — focus, gate, wine),
    * the position is not being read (`:no_position` — the minimap),
    * or both work and the character moved (`{:ok, _}`).

  Everything it needs is injected, so the whole thing is testable without a
  game: `body` (anything with `arrow_step/3`), `read` (a function returning
  the current position) and `sleep`.
  """

  alias Pokex.Bots.Body
  alias Pokex.World

  @default_steps 3
  # Long enough for the client to finish a step and redraw the coordinate —
  # the same beat the calibration's walking photo waits out.
  @default_gap_ms 400

  @type result :: %{
          from: {integer, integer, integer},
          to: {integer, integer, integer},
          tiles: non_neg_integer,
          presses: [String.t()]
        }

  @doc """
  Walks toward `target` (a waypoint) and reports what happened.

  `{:error, :no_position}` — the coordinate is not being read, so nothing can
  be confirmed and nothing is pressed: walking blind is what this test exists
  to avoid. `{:error, {:refused, reason}}` — the Body refused out loud (a shut
  gate). `{:error, :did_not_move}` — the presses went out and the character is
  exactly where it was: the keys are not reaching the game.
  """
  @spec run(%{x: integer, y: integer} | nil, keyword) :: {:ok, result} | {:error, term}
  def run(target, opts \\ []) do
    body = Keyword.get(opts, :body, Body)
    read = Keyword.get(opts, :read, &default_read/0)
    sleep = Keyword.get(opts, :sleep, &Process.sleep/1)
    steps = Keyword.get(opts, :steps, @default_steps)
    gap = Keyword.get(opts, :gap_ms, @default_gap_ms)

    case read.() do
      nil -> {:error, :no_position}
      from -> walk(%{body: body, read: read, sleep: sleep, gap: gap}, from, target, steps)
    end
  end

  defp walk(ctx, from, target, steps) do
    case press_each(ctx, from, target, steps, []) do
      {:error, reason} -> {:error, reason}
      {:ok, presses} -> verdict(ctx, from, presses)
    end
  end

  # One press per step, re-reading the position between them so the direction
  # follows the character instead of the plan.
  defp press_each(_ctx, _from, _target, 0, presses), do: {:ok, Enum.reverse(presses)}

  defp press_each(ctx, from, target, steps, presses) do
    {dx, dy} = delta(from, target)

    case ctx.body.arrow_step(dx, dy, []) do
      {:ok, key} ->
        ctx.sleep.(ctx.gap)
        press_each(ctx, ctx.read.() || from, target, steps - 1, [key | presses])

      {:error, reason} ->
        {:error, {:refused, reason}}
    end
  end

  # With no target the test still has to move SOMEWHERE: east and back is the
  # smallest honest round trip.
  defp delta({x, y, _z}, %{x: tx, y: ty}) when tx != x or ty != y, do: {tx - x, ty - y}
  defp delta(_from, _target), do: {1, 0}

  defp verdict(ctx, from, presses) do
    case ctx.read.() do
      nil ->
        {:error, :no_position}

      ^from ->
        {:error, :did_not_move}

      {x, y, _z} = to ->
        {fx, fy, _fz} = from
        {:ok, %{from: from, to: to, tiles: abs(x - fx) + abs(y - fy), presses: presses}}
    end
  end

  defp default_read, do: World.snapshot().pos
end
