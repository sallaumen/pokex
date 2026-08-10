defmodule Pokex.Bots.MiniGame.PlayerTest do
  @moduledoc """
  Where the playing strip ENDS, and what happens when it ends too early.

  Field trace 2026-08-10: the strip stopped at the detector's `bar.y2 + 10`
  while the real track kept going. Everything past that line was invisible —
  the fish sat at the bottom end for 26 ticks (`no_fish`), the capsule that
  fell there was never seen (`blue_px` 0 in all 54 samples), the
  `no_capsule_streak` hit its ceiling and the worker declared the game OVER
  while the overlay was still on screen. The other workers came back and fished
  on top of it.
  """
  use ExUnit.Case, async: true

  alias Pokex.Bots.MiniGame.{Detector, Player}
  alias Pokex.Calibration

  # His real numbers: region marked by hand at (1673, 549) 68×643, the detector
  # electing a bar that ends at y2 458 — 175 points short of the mark.
  @region {1673, 549, 68, 643}
  @reading %Detector{present?: true, bar: %{x: 46, width: 14, y1: 128, y2: 458}}

  defp armed(calib, region \\ @region),
    do: Player.new() |> Player.arm(calib, region, @reading)

  test "a HAND-MARKED region is taken whole — the hand framed the track" do
    calib = %Calibration{scale: 1.0, mini_game_region: @region}

    assert %{strip: {_x, 549, _w, 643}} = armed(calib)
  end

  test "a DERIVED region still gets its tail cut — that is where the rock is" do
    # no mini_game_region: the box comes from the character anchors (#151) and
    # drags ~235 rows of dark scenery below the bar, which steals the Track's
    # election and blinded the pilot on 96% of the ticks (trace 2026-08-05)
    calib = %Calibration{scale: 1.0, mini_game_region: nil}

    assert %{strip: {_x, 549, _w, 468}} = armed(calib)
  end

  test "the strip stays centred on the bar either way" do
    hand = armed(%Calibration{scale: 1.0, mini_game_region: @region})
    derived = armed(%Calibration{scale: 1.0, mini_game_region: nil})

    # 1673 + 46 = 1719, half-width 40
    assert {1679, _, 80, _} = hand.strip
    assert elem(hand.strip, 0) == elem(derived.strip, 0)
    assert elem(hand.strip, 2) == elem(derived.strip, 2)
  end

  test "a fresh player has nothing to complain about" do
    refute Player.clipped?(Player.new())
  end
end
