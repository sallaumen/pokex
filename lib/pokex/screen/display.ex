defmodule Pokex.Screen.Display do
  @moduledoc """
  Where the filmed display sits on the desktop, and the translation between the
  two point spaces this bot lives in.

  Everything the eye reads is LOCAL to the display the capture backend films:
  the helper crops inside that display's own frame, so its top-left is `{0, 0}`
  and every calibrated region and point is written in those coordinates.

  Everything the hand does is GLOBAL: `cliclick` and CGEvent address one desktop
  spanning every monitor, with the MAIN display's top-left at `{0, 0}`.

  The two spaces coincide only while the game is on the main display — which the
  house asserted out loud until 2026-09-14, when Lucas moved the game to the
  built-in screen (global origin `{3440, 1007}`) and the bot went on filming and
  clicking the ultrawide. This module holds the vector between them.

  `origin/0` answers `{0, 0}` until the backend proves otherwise, so a
  single-monitor setup, the simulator and the whole test suite behave exactly as
  they did before. Absent proof is the OLD behaviour, never a guess.
  """

  @key {__MODULE__, :region}

  @typedoc "A point in screen points."
  @type point :: {integer, integer}

  @typedoc "A rectangle in screen points: `{x, y, w, h}`."
  @type region :: {integer, integer, integer, integer}

  @doc """
  The filmed display's full area in GLOBAL screen points, or `:unknown` when the
  capture backend has not named one.
  """
  @spec region() :: region | :unknown
  def region, do: :persistent_term.get(@key, :unknown)

  @doc """
  The filmed display's top-left in GLOBAL screen points — `{0, 0}` with no proof.
  """
  @spec origin() :: point
  def origin do
    case region() do
      {x, y, _w, _h} -> {x, y}
      :unknown -> {0, 0}
    end
  end

  @doc """
  Records the filmed display. Written by the capture broker only: it is the one
  that knows which monitor is being filmed.
  """
  @spec put(region) :: :ok
  def put({x, y, w, h} = area)
      when is_integer(x) and is_integer(y) and is_integer(w) and is_integer(h) do
    # :persistent_term.put/2 triggers a global GC scan, so only write a change.
    if region() != area, do: :persistent_term.put(@key, area)
    :ok
  end

  @doc "Back to no proof — the main display assumed, as before there was a name."
  @spec forget() :: :ok
  def forget do
    :persistent_term.erase(@key)
    :ok
  end

  @doc "A point the eye gave us, in the coordinates the mouse understands."
  @spec to_global(point) :: point
  def to_global({x, y}) do
    {ox, oy} = origin()
    {x + ox, y + oy}
  end

  @doc "A point the mouse gave us, in the coordinates the eye understands."
  @spec to_local(point) :: point
  def to_local({x, y}) do
    {ox, oy} = origin()
    {x - ox, y - oy}
  end

  @doc "A calibrated region as a GLOBAL rectangle — what `screencapture -R` wants."
  @spec to_global_region(region) :: region
  def to_global_region({x, y, w, h}) do
    {gx, gy} = to_global({x, y})
    {gx, gy, w, h}
  end

  @doc """
  Is the filmed display the main one?

  `screencapture -m` is a measured speedup AND a fence: with the game elsewhere
  it films the wrong monitor. So does a bare `screencapture` with no region
  (measured 2026-09-14: one file, 3440×1440, the main display) — which is why
  the full-screen fallback needs `region/0` and not just this answer.
  """
  @spec main?() :: boolean
  def main?, do: origin() == {0, 0}
end
