defmodule Pokex.Rig do
  @moduledoc """
  Hands and eyes of the bot. The only layer allowed to touch the OS.
  Coordinates are macOS screen POINTS, origin at top-left.
  """

  @type point :: {integer, integer}
  @type region :: {integer, integer, integer, integer}

  @callback press(String.t()) :: :ok | {:error, term}
  @callback press_many([String.t()], keyword) :: :ok | {:error, term}
  @callback key_down(String.t()) :: :ok | {:error, term}
  @callback key_up(String.t()) :: :ok | {:error, term}
  # Expected time for a hold/release command to LAND in the game — consumers
  # (the mini-game pilot) extrapolate the bar over it. The implementation knows
  # which backend is live (native CGEvents vs scripted osascript); callers
  # must not reach around the port to ask.
  @callback hold_latency_ms() :: non_neg_integer
  @callback click(:left | :right, point) :: :ok | {:error, term}
  @callback move(point) :: :ok | {:error, term}
  @callback hover(point) :: :ok | {:error, term}
  @callback tap(String.t()) :: :ok | {:error, term}
  @callback capture_sequence(point) :: :ok | {:error, term}
  @callback capture(region, filename :: String.t()) :: {:ok, String.t()} | {:error, term}
  @callback capture_screen() :: {:ok, String.t()} | {:error, term}
  # The screen size in POINTS, straight from the window server — the only source
  @callback cursor_position() :: {:ok, point} | {:error, term}

  def impl, do: Application.get_env(:pokex, :rig, Pokex.Rig.Mac)
end
