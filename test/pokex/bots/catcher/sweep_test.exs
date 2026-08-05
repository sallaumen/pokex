defmodule Pokex.Bots.Catcher.SweepTest do
  @moduledoc """
  The blind sweep's geometry: which tiles get a ball, and in what order.

  No vision here on purpose. The sweep exists because recognition MISSES
  (2026-08-05, Lucas: "atualmente eu tô vendo ele perder muito pokémon"), so
  its target list may not depend on anything the detector believes.
  """
  # async: false — the radius/side/tile knobs are global Settings (the stash restores them).
  use ExUnit.Case, async: false

  alias Pokex.Bots.Catcher.Sweep
  alias Pokex.{Calibration, Settings, SettingsStash}

  @tile 88

  setup do
    SettingsStash.stash!(tile_px: @tile, sweep_radius_tiles: 1, sweep_side: "square")
    :ok
  end

  defp calib(extra \\ %{}) do
    struct!(
      %Calibration{scale: 1.0, screen_w: 3440, screen_h: 1440, player_point: {1688, 697}},
      extra
    )
  end

  describe "points/1" do
    test "a square sweep of radius 1 is the eight tiles around the character" do
      Settings.put(:sweep_radius_tiles, 1)
      Settings.put(:sweep_side, "square")

      {:ok, points} = Sweep.points(calib())

      assert length(points) == 8
      refute {1688, 697} in points, "the character's own tile is never a target"

      assert Enum.sort(points) == [
               {1600, 609},
               {1600, 697},
               {1600, 785},
               {1688, 609},
               {1688, 785},
               {1776, 609},
               {1776, 697},
               {1776, 785}
             ]
    end

    test "the nearest ring is thrown first" do
      Settings.put(:sweep_radius_tiles, 3)
      Settings.put(:sweep_side, "square")

      {:ok, points} = Sweep.points(calib())

      rings =
        Enum.map(points, fn {x, y} ->
          max(abs(div(x - 1688, @tile)), abs(div(y - 697, @tile)))
        end)

      assert rings == Enum.sort(rings), "a far tile was thrown before a near one"
      assert List.first(rings) == 1
      assert List.last(rings) == 3
    end

    # His spot has the SEA to the left: balls thrown that way are pure waste.
    test "the right sweep keeps the character's own column and drops everything left of it" do
      Settings.put(:sweep_radius_tiles, 2)
      Settings.put(:sweep_side, "right")

      {:ok, points} = Sweep.points(calib())

      assert Enum.all?(points, fn {x, _y} -> x >= 1688 end)
      assert {1688, 609} in points, "the column in line with the character is covered"
      # 3 columns × 5 rows, minus the character's own tile
      assert length(points) == 14
    end

    test "the left sweep is the mirror of the right one" do
      Settings.put(:sweep_radius_tiles, 2)
      Settings.put(:sweep_side, "left")

      {:ok, points} = Sweep.points(calib())

      assert Enum.all?(points, fn {x, _y} -> x <= 1688 end)
      assert length(points) == 14
    end

    # The active Pokémon stands on a tile of its own. A ball there is a ball at
    # his own team — the same reasoning SpotScan's forbidden zones already use.
    test "the tile where his own Pokémon stands is never a target" do
      Settings.put(:sweep_radius_tiles, 2)
      Settings.put(:sweep_side, "square")

      {:ok, points} = Sweep.points(calib(%{pokemon_spot_point: {1776, 697}}))

      refute {1776, 697} in points
      assert length(points) == 23
    end

    test "tiles that fall off the screen are dropped, not clamped onto the edge" do
      Settings.put(:sweep_radius_tiles, 3)
      Settings.put(:sweep_side, "square")

      {:ok, points} = Sweep.points(calib(%{player_point: {60, 60}}))

      assert Enum.all?(points, fn {x, y} -> x >= 0 and y >= 0 end)
      # a clamped grid would pile several tiles onto the same edge pixel
      assert length(Enum.uniq(points)) == length(points)
    end

    test "without screen dimensions there is nothing to clamp against — an honest error" do
      assert Sweep.points(%Calibration{scale: 1.0, player_point: {100, 100}}) ==
               {:error, :no_screen}
    end
  end

  describe "tile_count/2" do
    test "counts what the panel promises before the first ball flies" do
      assert Sweep.tile_count(1, "square") == 8
      assert Sweep.tile_count(2, "square") == 24
      assert Sweep.tile_count(4, "square") == 80
      assert Sweep.tile_count(2, "right") == 14
      assert Sweep.tile_count(4, "left") == 44
    end
  end
end
