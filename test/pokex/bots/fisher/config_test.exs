defmodule Pokex.Bots.Fisher.ConfigTest do
  use ExUnit.Case, async: true
  alias Pokex.Bots.Fisher.Config
  alias Pokex.Calibration

  test "builds the flat logic config from calibration and settings" do
    calib = %Calibration{
      scale: 2.0,
      screen_w: 1000,
      screen_h: 700,
      water_point: {800, 400},
      glow_region: {768, 368, 64, 64},
      battle_region: {1380, 120, 260, 220},
      arena_region: {560, 260, 560, 420},
      neutral_point: {860, 470}
    }

    config = Config.build(calib, Pokex.Settings.defaults())

    assert config.water_point == {800, 400}
    assert config.neutral_point == {860, 470}
    assert config.battle_first_row == {1466, 138}
    assert config.player_point == {840, 470}
    assert config.skill_keys == ["1", "2", "3"]
    assert config.watch_timeout_ms == 30_000
    assert config.hostile_scan_every == 2
    assert config.target_verify_attempts == 3
    assert config.tile_px == 88
    assert config.walk_step_ms == 400
    assert config.loot_presses == 2
    assert config.max_walk_tiles == 7
    refute Map.has_key?(config, :fallback_points)

    # rows spaced by battle_row_height (52 pts, the measured real row spacing):
    # first row at y=138 (120 + first_row_offset 18), then +52 each.
    assert config.battle_rows == [
             {1466, 138},
             {1466, 190},
             {1466, 242},
             {1466, 294},
             {1466, 346},
             {1466, 398}
           ]
  end

  test "tolerates a settings map missing newer keys (stale process, no nil crash)" do
    calib = %Calibration{
      scale: 2.0,
      screen_w: 1000,
      screen_h: 700,
      water_point: {800, 400},
      glow_region: {768, 368, 64, 64},
      battle_region: {1380, 120, 260, 220},
      arena_region: {560, 260, 560, 420},
      neutral_point: {860, 470}
    }

    # a partial map — no battle_max_rows / battle_row_height / tile_px
    config = Config.build(calib, %{skill_keys: ["1"]})

    assert length(config.battle_rows) == 6
    assert config.player_point == {840, 470}
  end
end
