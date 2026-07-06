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
    assert config.fallback_points == [{800, 400}, {768, 400}, {832, 400}, {800, 368}, {800, 432}]
    assert config.skill_keys == ["1", "2", "3"]
    assert config.watch_timeout_ms == 30_000
    assert config.hostile_scan_every == 2
  end
end
