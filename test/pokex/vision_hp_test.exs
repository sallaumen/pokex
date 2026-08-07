defmodule Pokex.VisionHpTest do
  @moduledoc """
  The phantom revive of 2026-08-07, in one file.

  On a single monitor the browser sits in front of the game, so the HP strip
  captures that window instead of the bar. Every DARK pixel counted as "the
  bar's empty track", so a uniformly dark frame read as a perfectly recognised
  bar at 0% — and the survival combo fired on a Pokémon at full health.
  """
  use ExUnit.Case, async: true

  alias Pokex.Vision

  defp frame(pixels) do
    w = length(hd(pixels))
    h = length(pixels)
    rgba = for row <- pixels, {r, g, b} <- row, into: <<>>, do: <<r, g, b, 255>>
    %Pokex.Vision.Frame{width: w, height: h, rgba: rgba, scale: 1.0}
  end

  defp fill(w, h, colour), do: List.duplicate(List.duplicate(colour, w), h)

  @dark {26, 26, 26}
  @green {80, 160, 70}
  @white {240, 240, 240}

  test "a uniformly dark strip is a COVERED WINDOW, never an empty bar" do
    covered = frame(fill(40, 10, @dark))

    refute Vision.hp_region_plausible?(covered)
    # and the reason is the brightness floor, not the known-pixel count:
    # everything dark still counts as "known track"
    assert Vision.hp_region_plausible?(covered, min_bright_pct: 0)
  end

  test "a real bar is plausible — full, and empty with its white numbers" do
    # mostly coloured fill with the white number text over it
    full = frame(fill(40, 8, @green) ++ fill(40, 2, @white))
    assert Vision.hp_region_plausible?(full)

    # 0 HP: no fill left, but the track edges and the "0/13520" text remain
    empty = frame(fill(30, 7, @dark) ++ fill(30, 3, @white))
    assert Vision.hp_region_plausible?(empty)
    assert Vision.hp_fill_pct(empty) == 0
  end

  test "the floor is measured, not guessed" do
    # his screen: real bar 68.5% bright, covered frame 0.1% — 10% sits between
    # them with room on both sides
    almost_dark = frame(fill(100, 10, @dark) ++ fill(100, 1, @white))
    refute Vision.hp_region_plausible?(almost_dark)

    lit = frame(fill(10, 10, @white) ++ fill(90, 10, @dark))
    assert Vision.hp_region_plausible?(lit)
  end
end
