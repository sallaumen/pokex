defmodule Pokex.Perception.Interpret.Minimap do
  @moduledoc """
  Where we are — read, not inferred.

  PokeTibia prints the player's position as text at the top of the minimap
  ("(337, 46107, 4)"), which is why this bot will never need to understand the
  map picture to walk it.

  Two sanity gates keep a garbled frame from teleporting the world model: the
  floor must be plausible, and a jump larger than `@max_jump` tiles against the
  last good read is rejected. The rejection is not sticky — a genuine teleport
  (stairs, boat) re-baselines as soon as a second read agrees with the first.
  """

  alias Pokex.{Calibration, Layout, Settings}
  alias Pokex.Calibration.CoordBandSearch
  alias Pokex.Vision.Glyphs

  @max_floor 15
  # A character walks; it does not teleport. 8 tiles per second is generous
  # (haste, diagonals) and still an order of magnitude below the jumps a
  # MISREAD produces: Lucas's hunt (2026-08-10) read an x that flipped ~24
  # tiles between consecutive frames, and the hunt believed every one of them —
  # counting waypoints as "reached" one second apart while the character stood
  # against a wall.
  @tiles_per_second 8
  # The floor under the allowance: at the feed's cadence a real step must
  # always fit, and a clock that reports no elapsed time must not freeze the
  # reader.
  @min_jump 3
  # A failed read is usually just "label not on screen" (standing still, no
  # hover) — scanning the whole crop on every 500ms tick would burn CPU for
  # nothing. First miss hunts immediately (a walking bot must not stay blind),
  # then every 6th.
  @search_every 6
  @fresh_state %{last: nil, pending: nil, band: nil, ink: nil, misses: 0, at: nil}

  def interpret(frame, calib, settings, state \\ nil) do
    state = Map.merge(@fresh_state, state || %{})
    {read, state} = read_position(frame, calib, settings, state)
    accept(read, state)
  end

  # The frame is the crop of minimap_capture_region — the SAME union the feed
  # captures — so every band is relative to that origin. The label MOVES with
  # the widget's visual state (measured 2026-08-10): walking draws it at the
  # widget's top-left, a hovering mouse slides the control bar in and pushes it
  # ~40pt down. A band marked in one state misses in the other, so a miss on
  # the last-good and saved bands HUNTS for the band on the crop itself
  # (throttled), and a find sticks in the state for the next read.
  defp read_position(frame, %Calibration{} = calib, settings, state) do
    case Calibration.minimap_capture_region(calib) do
      {ox, oy, _w, _h} ->
        opts = coord_opts(calib, settings)
        saved = relative_band(Calibration.minimap_coord_region(calib), ox, oy)

        # the ink floor the hunt settled on wins: over bright terrain the
        # taught floor welds the map to the strokes and reads nothing
        read_opts = Keyword.put(opts, :ink, state.ink || opts[:ink])

        case try_bands(frame, [state.band, saved], read_opts) do
          {:ok, band, pos} -> {pos, %{state | band: band, misses: 0}}
          :miss -> hunt_band(frame, calib, {ox, oy}, opts, state)
        end

      nil ->
        {nil, state}
    end
  end

  defp read_position(_frame, _no_calib, _settings, state), do: {nil, state}

  defp relative_band({x, y, w, h}, ox, oy), do: {x - ox, y - oy, w, h}
  defp relative_band(nil, _ox, _oy), do: nil

  defp try_bands(frame, bands, opts) do
    bands
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.find_value(:miss, fn band ->
      case Glyphs.read_coord(frame, band, opts) do
        {_x, _y, _z} = pos -> {:ok, band, pos}
        nil -> nil
      end
    end)
  end

  defp hunt_band(frame, calib, {ox, oy}, opts, state) do
    misses = state.misses + 1

    with true <- rem(misses - 1, @search_every) == 0,
         {mx, my, mw, mh} <- Calibration.minimap_region(calib),
         {:ok, band, pos, ink} <-
           CoordBandSearch.search(frame, {mx - ox, my - oy, mw, mh}, frame_scale(frame), opts) do
      {pos, %{state | band: band, ink: ink, misses: 0}}
    else
      _not_found -> {nil, %{state | misses: misses}}
    end
  end

  defp frame_scale(frame), do: Map.get(frame, :scale) || 1.0

  # The strip's ink floor is TUNABLE (minimap_coord_ink): the global default
  # (120) let the map's lit ground compete with the digits. The layout
  # region's declared opts still apply underneath — merge, never replace.
  defp coord_opts(calib, settings) do
    layout_opts = if calib.layout, do: Layout.region_opts(calib.layout, :minimap_coord), else: []
    Keyword.merge(layout_opts, ink: Settings.value(settings, :minimap_coord_ink))
  end

  @doc """
  The sanity gates, as a pure step: a read plus the last-good state gives the
  position to publish and the next state. Public because this is the part with
  real logic — the pixels around it are just `Glyphs.read_coord/2`.
  """
  def accept(read, state, now \\ nil)

  def accept(nil, state, _now), do: {%{pos: nil}, %{state | pending: nil}}

  def accept({_x, _y, z} = pos, state, _now) when z < 0 or z > @max_floor,
    do: {%{pos: nil}, %{state | pending: pos}}

  def accept(pos, %{last: nil} = state, now),
    do: {%{pos: pos}, accepted(state, pos, stamp(now))}

  def accept(pos, %{last: last} = state, now) do
    now = stamp(now)
    reach = reach(state, now)

    cond do
      near?(pos, last, reach) ->
        {%{pos: pos}, accepted(state, pos, now)}

      # a second read agreeing with the first is a real move (stairs, boat),
      # not a glitch — re-baseline instead of rejecting forever
      state.pending && near?(pos, state.pending, reach) ->
        {%{pos: pos}, accepted(state, pos, now)}

      true ->
        {%{pos: last}, %{state | pending: pos}}
    end
  end

  # Map.merge, not the update syntax: a state shaped before the clock existed
  # (a feed mid-upgrade, a caller's own map) must not raise on a missing key.
  defp accepted(state, pos, now), do: Map.merge(state, %{last: pos, pending: nil, at: now})

  # How far the character COULD have walked since the last accepted read.
  defp reach(state, now) do
    elapsed = if state[:at], do: max(now - state.at, 0), else: 0
    max(round(elapsed * @tiles_per_second / 1000), @min_jump)
  end

  defp stamp(nil), do: System.monotonic_time(:millisecond)
  defp stamp(now), do: now

  defp near?({x1, y1, z1}, {x2, y2, z2}, reach),
    do: z1 == z2 and abs(x1 - x2) <= reach and abs(y1 - y2) <= reach
end
