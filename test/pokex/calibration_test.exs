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

  @tag :tmp_dir
  test "save/load round-trips skill bar geometry/count, nil for older files", %{tmp_dir: tmp} do
    path = Path.join(tmp, "calibration.json")

    Calibration.save(%{sample() | skill_bar_region: {10, 20, 300, 60}, skill_bar_count: 8}, path)
    assert {:ok, loaded} = Calibration.load(path)
    assert loaded.skill_bar_region == {10, 20, 300, 60}
    assert loaded.skill_bar_count == 8

    # an old file (no skill_bar_region key) loads as nil, not a crash
    Calibration.save(sample(), path)
    assert {:ok, old} = Calibration.load(path)
    assert old.skill_bar_region == nil
    assert old.skill_bar_count == nil
  end

  @tag :tmp_dir
  test "skill_slot_refs round-trip (with nil holes), nil for older files", %{tmp_dir: tmp} do
    path = Path.join(tmp, "calibration.json")
    refs = [{230, 120, 190}, nil, {40, 200, 60}]

    Calibration.save(%{sample() | skill_slot_refs: refs}, path)
    assert {:ok, loaded} = Calibration.load(path)
    assert loaded.skill_slot_refs == refs

    Calibration.save(sample(), path)
    assert {:ok, old} = Calibration.load(path)
    assert old.skill_slot_refs == nil
  end

  @tag :tmp_dir
  test "player_point round-trips and beats the arena-center fallback", %{tmp_dir: tmp} do
    path = Path.join(tmp, "calibration.json")

    Calibration.save(%{sample() | player_point: {700, 500}}, path)
    assert {:ok, loaded} = Calibration.load(path)
    assert loaded.player_point == {700, 500}
    assert Calibration.player_point(loaded) == {700, 500}

    # an old file (no player_point key) still loads and falls back to the center
    Calibration.save(sample(), path)
    assert {:ok, old} = Calibration.load(path)
    assert old.player_point == nil
    assert Calibration.player_point(old) == {840, 470}
  end

  @tag :tmp_dir
  test "mini_game_region round-trips, nil for older files", %{tmp_dir: tmp} do
    path = Path.join(tmp, "calibration.json")

    Calibration.save(%{sample() | mini_game_region: {1180, 300, 90, 620}}, path)
    assert {:ok, loaded} = Calibration.load(path)
    assert loaded.mini_game_region == {1180, 300, 90, 620}

    # an old file (no mini_game_region key) still loads as nil, not a crash
    Calibration.save(sample(), path)
    assert {:ok, old} = Calibration.load(path)
    assert old.mini_game_region == nil
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

  test "glow_search_region expands the bait read and clamps to the screen" do
    calib = sample()
    assert Calibration.glow_search_region(calib, 64) == {716, 306, 192, 192}

    near_edge = %{calib | glow_region: {10, 20, 64, 64}}
    assert Calibration.glow_search_region(near_edge, 64) == {0, 0, 138, 148}

    far_edge = %{calib | glow_region: {1700, 1100, 64, 64}}
    assert Calibration.glow_search_region(far_edge, 64) == {1636, 1036, 92, 81}
  end

  test "row_band_geometry centers the band on the click point" do
    # scale 2, row_height 30 → band = 60; centered on the click at
    # first_row_offset (18pt → 36px), so top = 36 - 30 = 6. This is the exact
    # {top, band} the lock sensor feeds Vision.red_row_counts.
    assert Calibration.row_band_geometry(2.0, 30) == {6, 60}
    # scale 1 → band 30, top = 18 - 15 = 3
    assert Calibration.row_band_geometry(1.0, 30) == {3, 30}
    # band never collapses below 1px even at a tiny row height
    assert Calibration.row_band_geometry(1.0, 0) == {18, 1}
  end

  test "battle_row_bands returns one screen-point rect per row, over the battle body" do
    calib = sample()
    # battle_body = {1380, 120, 230, 220}; scale 2, row_height 30, 3 rows.
    # {top, band} = {6, 60}; band i frame-y top = 6 + i*60, ÷scale → screen-y,
    # +body_y (120). Height = 60/2 = 30 pt. x/width = body x/width (points).
    bands = Calibration.battle_row_bands(calib, 30, 3)
    assert length(bands) == 3
    assert Enum.at(bands, 0) == {1380, 120 + 6 / 2, 230, 30.0}
    assert Enum.at(bands, 1) == {1380, 120 + 66 / 2, 230, 30.0}
    assert Enum.at(bands, 2) == {1380, 120 + 126 / 2, 230, 30.0}

    # a raw battle_region + scale gives the same geometry (for previewing a draft
    # mid-calibration, before a %Calibration{} exists)
    assert Calibration.battle_row_bands({1380, 120, 260, 220}, 2.0, 30, 3) == bands
  end
end
