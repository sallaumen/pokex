defmodule Pokex.Rig do
  @moduledoc """
  Hands and eyes of the bot. The only layer allowed to touch the OS.
  Coordinates are macOS screen POINTS, origin at top-left.
  """

  @type point :: {integer, integer}
  @type region :: {integer, integer, integer, integer}

  @callback press(String.t()) :: :ok | {:error, term}
  # `opts[:halt?]` (0-arity fun) is the burst's FENCE: checked before EACH key, true = the
  # remaining keys do not fire and the answer is `{:halted, fired}`. A key is never cancelled
  # midway; the fence only decides the NEXT one.
  @callback press_many([String.t()], keyword) ::
              :ok | {:halted, [String.t()]} | {:error, term}
  @callback key_down(String.t()) :: :ok | {:error, term}
  @callback key_up(String.t()) :: :ok | {:error, term}
  # Expected time for a hold/release command to LAND in the game — consumers
  # (the mini-game pilot) extrapolate the bar over it. The implementation knows
  # which backend is live (native CGEvents vs scripted osascript); callers
  # must not reach around the port to ask.
  @callback hold_latency_ms() :: non_neg_integer
  @callback click(:left | :right, point) :: :ok | {:error, term}
  @callback move(point) :: :ok | {:error, term}
  @callback tap(String.t()) :: :ok | {:error, term}
  @callback focus_click(point) :: :ok | {:error, term}
  @callback capture_sequence(point) :: :ok | {:error, term}
  @callback capture(region, filename :: String.t()) :: {:ok, String.t()} | {:error, term}
  @callback capture_screen() :: {:ok, String.t()} | {:error, term}
  # The screen size in POINTS, straight from the window server — the only source
  @callback cursor_position() :: {:ok, point} | {:error, term}

  @doc """
  How many middle clicks the session has seen, and where the cursor is.

  A COUNTER, not an event tap: nothing is intercepted, no extra permission is
  asked for, and a click too fast to catch by polling the button state still
  shows up here. The recorder watches it for a jump — the marker Lucas makes
  with his own hand when he parks his pokémon (2026-08-11).
  """
  @callback middle_watch() ::
              {:ok, %{count: integer, point: point, at: integer | nil}} | {:error, term}

  @doc """
  The presses HE made on `codes` since the last call, oldest first.

  Same contract as `middle_watch/0`: polled, never tapped. What it buys is the
  recording knowing what he was DOING — "shift+3 é pq eu já terminei de matar
  tudo, shift+1 é por que vou matar monstro" (2026-08-11) — plus the skills in
  between and how long he took to fire them.
  """
  @callback key_watch([non_neg_integer]) ::
              {:ok, [%{code: non_neg_integer, shift?: boolean, at: integer}]} | {:error, term}

  def impl, do: Application.get_env(:pokex, :rig, Pokex.Rig.Mac)
end
