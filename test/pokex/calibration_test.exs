defmodule Pokex.CalibrationTest do
  # async: false — the profile tests write GLOBAL Settings (the numbers a
  # profile carries), and an async write races every other reader of them.
  use ExUnit.Case, async: false
  alias Pokex.Calibration
  alias Pokex.Settings

  defp sample do
    %Calibration{
      scale: 2.0,
      screen_w: 1728,
      screen_h: 1117,
      water_point: {812, 402},
      glow_region: {780, 370, 64, 64},
      battle_region: {1380, 120, 260, 220},
      neutral_point: {864, 470}
    }
  end

  @tag :tmp_dir
  test "save/load round-trip", %{tmp_dir: tmp} do
    path = Path.join(tmp, "calibration.json")
    refute Calibration.exists?(path)
    :ok = Calibration.save(sample(), path)
    assert Calibration.exists?(path)
    assert {:ok, loaded} = Calibration.load(path)

    # :layout is not a file field — load/1 attaches the auto-located HUD in
    # force so a feed's capture region and its interpreter's offsets come from
    # one resolution. The round-trip is about what the FILE carries.
    assert %{loaded | layout: nil} == sample()
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
  test "player_point round-trips and beats the screen-centre fallback", %{tmp_dir: tmp} do
    path = Path.join(tmp, "calibration.json")

    Calibration.save(%{sample() | player_point: {700, 500}}, path)
    assert {:ok, loaded} = Calibration.load(path)
    assert loaded.player_point == {700, 500}
    assert Calibration.player_point(loaded) == {700, 500}

    # an old file (no player_point key) still loads and falls back to the middle
    # of the SCREEN — where an MMO keeps the character. The old fallback was the
    # centre of the hand-marked arena, measured 268px above the real character.
    Calibration.save(sample(), path)
    assert {:ok, old} = Calibration.load(path)
    assert old.player_point == nil
    assert Calibration.player_point(old) == {864, 558}
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

  @tag :tmp_dir
  test "pokemon_spot_point round-trips, nil for older files", %{tmp_dir: tmp} do
    path = Path.join(tmp, "calibration.json")

    Calibration.save(%{sample() | pokemon_spot_point: {450, 380}}, path)
    assert {:ok, loaded} = Calibration.load(path)
    assert loaded.pokemon_spot_point == {450, 380}

    Calibration.save(sample(), path)
    assert {:ok, old} = Calibration.load(path)
    assert old.pokemon_spot_point == nil
  end

  @tag :tmp_dir
  test "escape_point round-trips, nil for older files", %{tmp_dir: tmp} do
    path = Path.join(tmp, "calibration.json")

    Calibration.save(%{sample() | escape_point: {620, 240}}, path)
    assert {:ok, loaded} = Calibration.load(path)
    assert loaded.escape_point == {620, 240}

    Calibration.save(sample(), path)
    assert {:ok, old} = Calibration.load(path)
    assert old.escape_point == nil
  end

  @tag :tmp_dir
  test "profiles: save/list/apply/delete round-trip", %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

    assert Calibration.list_profiles() == []

    Calibration.save(sample())
    assert {:ok, "dois-monitores"} = Calibration.save_profile("Dois Monitores!")

    assert [profile] = Calibration.list_profiles()
    assert profile.name == "dois-monitores"
    assert profile.screen_w == 1728
    assert is_integer(profile.saved_at)

    # overwrite the active calibration, then the profile brings it back
    Calibration.save(%{sample() | screen_w: 999})
    assert {:ok, restored, _numbers} = Calibration.apply_profile("dois-monitores")
    assert restored.screen_w == 1728
    assert {:ok, active} = Calibration.load()
    assert active.screen_w == 1728

    assert :ok = Calibration.delete_profile("dois-monitores")
    assert Calibration.list_profiles() == []

    # invalid names never touch the filesystem
    assert {:error, :invalid_name} = Calibration.save_profile("///")
  end

  @tag :tmp_dir
  # The regions alone were never enough: every threshold and box size is measured
  # in pixels of ONE screen, so a profile that restored only the marks brought
  # back a calibration the numbers no longer fitted (Lucas on the small screen,
  # 2026-08-06). Switching monitors has to bring both.
  test "a profile carries the numbers that belong to its screen", %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    tile = Settings.get(:tile_px)
    glow = Settings.get(:glow_threshold)

    on_exit(fn ->
      Application.delete_env(:pokex, :home_dir)
      Settings.put(:tile_px, tile)
      Settings.put(:glow_threshold, glow)
    end)

    Calibration.save(sample())
    Settings.put(:tile_px, 88)
    Settings.put(:glow_threshold, 1100)
    assert {:ok, "ultrawide"} = Calibration.save_profile("ultrawide")

    # move to the small screen: the numbers get rescaled for it
    Settings.put(:tile_px, 59)
    Settings.put(:glow_threshold, 496)

    assert {:ok, _calib, applied} = Calibration.apply_profile("ultrawide")
    assert applied > 0
    assert Settings.get(:tile_px) == 88
    assert Settings.get(:glow_threshold) == 1100

    # and deleting takes the sidecar with it
    assert :ok = Calibration.delete_profile("ultrawide")
    assert Calibration.profile_settings("ultrawide") == %{}
  end

  @tag :tmp_dir
  # A profile saved before the numbers were carried still has to apply — its
  # MARKS are good. The count is what tells him the numbers did not come.
  test "a profile without numbers applies its marks and reports zero", %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

    Calibration.save(sample())
    assert {:ok, "antigo"} = Calibration.save_profile("antigo")
    File.rm!(Path.join([tmp, "calibrations", "antigo.settings.json"]))

    assert {:ok, calib, 0} = Calibration.apply_profile("antigo")
    assert calib.screen_w == 1728
    # and the sidecar never shows up as a profile of its own
    assert [%{name: "antigo"}] = Calibration.list_profiles()
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
    # the client keeps the player centred in the viewport
    assert Calibration.player_point(calib) == {864, 558}
    # pixel (100, 50) inside a region with scale 2 → +50,+25 points from its corner
    assert Calibration.frame_to_screen(calib, {560, 260, 560, 420}, {100, 50}) == {610, 285}
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
