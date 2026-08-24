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
      neutral_point: {860, 470}
    }

    config = Config.build(calib, Pokex.Settings.defaults())

    assert config.water_point == {800, 400}
    assert config.neutral_point == {860, 470}
    assert config.battle_first_row == {1466, 151}
    assert config.player_point == {500, 350}
    assert config.rod_key == "shift+v"
    assert config.skill_keys == ["1", "2", "3"]
    assert config.combat_skill_burst_size == 3
    assert config.combat_skill_tap_count == 1
    assert config.combat_skill_gap_ms == 35
    assert config.combat_skill_jitter_ms == 20
    assert config.watch_timeout_ms == 30_000
    assert config.target_lost_streak == 2
    assert config.tile_px == Pokex.Settings.defaults()[:tile_px]
    refute Map.has_key?(config, :fallback_points)

    # rows spaced by battle_row_height (30 pts, measured on the client he plays):
    # first row at y=151 (120 + battle_first_row_y 31), then +30 each.
    assert config.battle_rows == [
             {1466, 151},
             {1466, 181},
             {1466, 211},
             {1466, 241},
             {1466, 271},
             {1466, 301}
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
      neutral_point: {860, 470}
    }

    # a partial map — no battle_max_rows / battle_row_height / tile_px
    config = Config.build(calib, %{skill_keys: ["1"]})

    assert length(config.battle_rows) == 6
    assert config.player_point == {500, 350}
  end
end
