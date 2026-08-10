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

  These are HUMAN hands, not the fleet's: the button is clicked in the browser,
  so the game is brought forward, the calibrated neutral point is clicked (macOS
  hands the keyboard on a CLICK, not on `set frontmost`) and the arrows go out
  UNGATED — the safety gate's corner flag is proven by the Guardian, which only
  polls while the fleet is up, so with the bot stopped a gated press can never
  happen. That is exactly the refusal this test used to answer with
  (`:input_gate_closed`, 2026-08-10) instead of walking.

  Everything it needs is injected, so the whole thing is testable without a
  game: `body` (anything with `arrow_step/3`), `read` (a function returning
  the current position), `sleep`, `front` and `focus`.
  """

  alias Pokex.Bots.Body
  alias Pokex.{Calibration, GameFocus, World}

  @default_steps 3
  # Long enough for the client to finish a step and redraw the coordinate —
  # the same beat the calibration's walking photo waits out.
  @default_gap_ms 400
  @focus_settle_ms 250

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
    body = Keyword.get(opts, :body, Hands)
    read = Keyword.get(opts, :read, &default_read/0)
    sleep = Keyword.get(opts, :sleep, &Process.sleep/1)
    steps = Keyword.get(opts, :steps, @default_steps)
    gap = Keyword.get(opts, :gap_ms, @default_gap_ms)
    front = Keyword.get(opts, :front, &GameFocus.with_game_front/1)
    focus = Keyword.get(opts, :focus, &default_focus/0)

    case read.() do
      nil ->
        {:error, :no_position}

      from ->
        front.(fn ->
          focus.()
          walk(%{body: body, read: read, sleep: sleep, gap: gap}, from, target, steps)
        end)
    end
  end

  # The click that hands the keyboard over, on the one point calibrated as safe
  # (his own tile: click-to-walk there lands where he already stands).
  defp default_focus do
    with {:ok, calib} <- Calibration.load(),
         point when is_tuple(point) <- calib.neutral_point || calib.player_point do
      Body.perform([{:focus_click, point}, {:wait, @focus_settle_ms}])
    else
      _no_point -> :ok
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

  defmodule Hands do
    @moduledoc """
    The `arrow_step/3` of a human-clicked test: an UNGATED key press, already
    inside the caller's game-front block. Same shape as `Body.arrow_step/3`, so
    the walk logic cannot tell them apart — and the fleet's gated hands stay
    the only ones the HUNT ever uses.
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
end
