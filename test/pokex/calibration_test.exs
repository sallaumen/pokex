defmodule Pokex.CalibrationTest do
  use ExUnit.Case, async: true
  alias Pokex.Calibration

  defp sample do
    %Calibration{
      scale: 2.0,
      screen_w: 1728,
      screen_h: 1117,
      water_point: {812, 402},
      glow_region: {780, 370, 64, 64},
      battle_region: {1380, 120, 260, 220},
      arena_region: {560, 260, 560, 420},
      neutral_point: {864, 470},
      glow_baselines: ["/tmp/glow_0.png"],
      battle_baseline: "/tmp/battle.png",
      suggested_glow_threshold: 18.5
    }
  end

  @tag :tmp_dir
  test "save/load round-trip", %{tmp_dir: tmp} do
    path = Path.join(tmp, "calibration.json")
    refute Calibration.exists?(path)
    :ok = Calibration.save(sample(), path)
    assert Calibration.exists?(path)
    assert {:ok, loaded} = Calibration.load(path)
    assert loaded == sample()
  end

  test "derived regions and conversion" do
    calib = sample()
    assert Calibration.battle_strip(calib) == {1610, 120, 30, 220}
    # body = battle region minus the rightmost pokeball column (30px)
    assert Calibration.battle_body(calib) == {1380, 120, 230, 220}
    assert Calibration.battle_strip({1380, 120, 260, 220}) == {1610, 120, 30, 220}
    assert Calibration.battle_first_row(calib) == {1466, 138}
    # the per-row band origin comes from the same source of truth as battle_first_row
    assert Calibration.first_row_offset() == 18
    # the client keeps the player centered in the arena viewport
    assert Calibration.player_point(calib) == {840, 470}
    # pixel (100, 50) dentro da arena com scale 2 → +50,+25 points do canto
    assert Calibration.frame_to_screen(calib, calib.arena_region, {100, 50}) == {610, 285}
    # a wild row 100px down the strip → name column, scaled: {1380+86, 120+50}
    assert Calibration.battle_row_point(calib, 100) == {1466, 170}
  end
end
