defmodule Pokex.ScreenScaleTest do
  @moduledoc """
  The ruler that lets one bot work on two screens.

  Every pixel-denominated seed was measured once, on the 3440×1440 ultrawide,
  and none of them survived the move to the MacBook — that is what
  "nada funciona em 1 monitor só" was made of (Lucas, 2026-08-06).
  """
  use ExUnit.Case, async: true

  alias Pokex.{Calibration, ScreenScale, Settings}

  defp calib(width, count),
    do: %Calibration{skill_bar_region: {10, 20, width, 34}, skill_bar_count: count}

  describe "measure/1" do
    test "the ruler is the GAME, never the display" do
      # his ultrawide profile: 430 points over 8 slots = the reference itself
      assert {:ok, ratio} = ScreenScale.measure(calib(430, 8))
      assert ScreenScale.matches_reference?(ratio)

      # the MacBook: 325 points over 9 slots = 36.1 per slot
      assert {:ok, small} = ScreenScale.measure(calib(325, 9))
      assert_in_delta small, 0.671, 0.005

      # the DISPLAY ratio between those two screens is 1512/3440 = 0.44 — half
      # of what the game actually did. Deriving from the display would be wrong
      # by 50%, which is the whole reason this module measures the skill bar.
      refute_in_delta small, 1512 / 3440, 0.1
    end

    test "without a calibrated skill bar there is no ruler, and it says so" do
      assert ScreenScale.measure(%Calibration{}) == :unknown
      assert ScreenScale.measure(calib(325, 0)) == :unknown
    end
  end

  describe "proposals/2" do
    # `get:` is passed in EVERY case on purpose: this suite is async, and
    # reading the global Settings here would race with any test that writes
    # them (the calibration page applies all 18 in one click).
    defp seeded, do: [get: &Map.fetch!(Settings.defaults(), &1)]

    # A length scales with the ruler; a pixel COUNT is an area and scales with
    # the ruler squared. At 0.67 the difference is not cosmetic: a threshold
    # scaled linearly would still be 50% too high and no bite would register.
    test "a length scales with the ratio and a pixel count with its square" do
      seeds = Settings.defaults()
      current = fn key -> Map.fetch!(seeds, key) end

      by_key =
        0.5
        |> ScreenScale.proposals(get: current)
        |> Map.new(&{&1.key, &1})

      assert by_key[:tile_px].to == round(seeds.tile_px * 0.5)
      assert by_key[:tile_px].family == :linear

      assert by_key[:glow_threshold].to == seeds.glow_threshold * 0.25
      assert by_key[:glow_threshold].family == :area
    end

    test "nothing counted in TILES is rescaled — a tile is a game unit already" do
      keys = 0.5 |> ScreenScale.proposals(seeded()) |> Enum.map(& &1.key)

      refute :corpse_scan_radius_tiles in keys
      refute :sweep_radius_tiles in keys
      refute :cavebot_arrival_tolerance_tiles in keys
    end

    test "colours and percentages are not rescaled either — a smaller screen keeps them" do
      keys = 0.5 |> ScreenScale.proposals(seeded()) |> Enum.map(& &1.key)

      refute :corpse_diff_threshold in keys
      refute :minimap_coord_ink in keys
      refute :skill_ready_min_saturation in keys
    end

    # The trap this design exists to avoid: deriving from the value IN FORCE
    # would scale an already-scaled number every time he pressed the button.
    test "proposals come from the SEED, so applying twice lands on the same number" do
      seeds = Settings.defaults()
      once = ScreenScale.proposals(0.67, get: fn key -> Map.fetch!(seeds, key) end)
      applied = Map.new(once, &{&1.key, &1.to})

      twice = ScreenScale.proposals(0.67, get: fn key -> applied[key] || seeds[key] end)

      assert twice == [], "a second pass moved values that were already rescaled"
    end

    test "a hand-tuned override is shown being replaced, not silently kept" do
      seeds = Settings.defaults()
      # his ultrawide-era tuning, which belongs to the other screen
      get = fn
        :glow_threshold -> 1300.0
        key -> Map.fetch!(seeds, key)
      end

      proposal =
        0.67 |> ScreenScale.proposals(get: get) |> Enum.find(&(&1.key == :glow_threshold))

      assert proposal.from == 1300.0
      # from the SEED (1100), not from his 1300 — the tuning belonged to the
      # other screen, so carrying it forward would carry the bug forward
      assert_in_delta proposal.to, seeds.glow_threshold * 0.67 * 0.67, 1.0
    end

    test "a rescaled threshold never reaches zero — that would match every frame" do
      tiny = ScreenScale.proposals(0.01, seeded())

      assert Enum.all?(tiny, fn %{to: to} -> to >= 1 end)
    end

    test "the same screen proposes nothing" do
      assert ScreenScale.proposals(1.0, seeded()) == []
      assert ScreenScale.matches_reference?(1.0)
      refute ScreenScale.matches_reference?(0.67)
    end
  end
end
