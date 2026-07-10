defmodule Pokex.Diagnostics.ReportTest do
  use ExUnit.Case, async: false
  alias Pokex.Diagnostics.Report
  alias Pokex.Calibration

  @calib %Calibration{
    scale: 2.0,
    screen_w: 1000,
    screen_h: 700,
    water_point: {400, 300},
    glow_region: {368, 268, 64, 64},
    battle_region: {700, 100, 260, 200},
    arena_region: {200, 100, 400, 400},
    neutral_point: {420, 350},
    suggested_glow_threshold: 45.0
  }

  @settings %{
    # tiny fixtures: 8×8 glow = 64 teal px, so the bite threshold sits below that.
    glow_threshold: 10,
    # no search expansion, so the echoed glow region is exactly the calibrated 64×64.
    glow_search_margin: 0,
    line_present_min_px: 100,
    battle_row_height: 20,
    battle_max_rows: 3,
    target_locked_min_pixels: 350,
    wild_min_red_pixels: 12,
    skill_keys: ["1", "2"]
  }

  setup %{tmp_dir: tmp} do
    # PNG fixtures the Fake rig will hand back, one per captured region (in the
    # exact order Report captures them): glow, battle body, battle strip, arena,
    # scale probe; then the full screen.
    glow =
      Pokex.PngFixtures.write!(
        Path.join(tmp, "glow.png"),
        for y <- 0..15 do
          for x <- 0..15 do
            if x in 5..10 and y in 5..10, do: {210, 55, 30, 255}, else: {0, 180, 200, 255}
          end
        end
      )

    battle = png!(tmp, "battle.png", 20, 12, {0, 200, 0})
    strip = png!(tmp, "strip.png", 8, 12, {255, 0, 0})
    arena = png!(tmp, "arena.png", 12, 12, {0, 0, 0})
    probe = png!(tmp, "probe.png", 50, 50, {0, 0, 0})
    screen = png!(tmp, "screen.png", 60, 40, {0, 0, 0})

    {:ok, _} =
      Pokex.Rig.Fake.start_link(%{
        capture: [{:ok, glow}, {:ok, battle}, {:ok, strip}, {:ok, arena}, {:ok, probe}],
        capture_screen: [{:ok, screen}]
      })

    %{exports: Path.join(tmp, "exports")}
  end

  @tag :tmp_dir
  test "captures every region with its Vision metrics and a matrix", %{exports: exports} do
    assert {:ok, report, path} =
             Report.capture(
               rig: Pokex.Rig.Fake,
               calib: @calib,
               settings: @settings,
               exports_dir: exports,
               now: 1_700_000_000_000
             )

    # Calibration echoed as JSON-friendly lists (no tuples leak).
    assert report.calibration.battle_region == [700, 100, 260, 200]
    assert report.calibration.battle_body == [700, 100, 230, 200]
    assert report.captured_at_ms == 1_700_000_000_000

    # Glow: the teal fixture reads as a bite over the threshold.
    glow = report.regions.glow
    assert glow.region == [368, 268, 64, 64]
    assert glow.metrics.bubble_count > 0
    assert glow.metrics.bite? == true

    # Battle body: the all-green fixture is a present creature, no lock.
    battle = report.regions.battle_body
    assert battle.metrics.has_creature? == true
    assert battle.metrics.locked_row == nil
    assert length(battle.metrics.red_row_counts) == 3
    assert battle.matrix.cols > 0
    assert is_list(battle.matrix.ascii)

    # Battle strip: the bright-red fixture trips the wild pokeball detector.
    assert report.regions.battle_strip.metrics.wild_present? == true

    # Arena: black fixture → no hostile name.
    assert report.regions.arena.metrics.find_hostile == nil

    # Skill bar: not calibrated in this fixture → flagged, no capture attempted.
    assert report.regions.skill_bar == %{calibrated?: false}

    # Screen: dimensions + scale probe.
    assert report.screen.pixels == [60, 40]
    assert report.screen.r_scale == 0.5

    assert File.regular?(path)
  end

  @tag :tmp_dir
  test "writes both a timestamped file and latest.json, JSON-encodable", %{exports: exports} do
    assert {:ok, report, path} =
             Report.capture(
               rig: Pokex.Rig.Fake,
               calib: @calib,
               settings: @settings,
               exports_dir: exports,
               now: 1_700_000_000_000
             )

    assert Path.basename(path) == "diagnostics-1700000000000.json"
    assert File.regular?(Path.join(exports, "latest.json"))

    # Round-trips through JSON with no tuple leaks.
    decoded = path |> File.read!() |> JSON.decode!()
    assert decoded["calibration"]["battle_region"] == [700, 100, 260, 200]
    assert decoded["regions"]["glow"]["metrics"]["bite?"] == true

    # The in-memory report is the same shape that was written.
    assert JSON.encode!(report) == File.read!(path)
  end

  defp png!(dir, name, w, h, rgba) do
    path = Path.join(dir, name)
    Pokex.PngFixtures.write!(path, uniform_rows(w, h, rgba))
    path
  end

  defp uniform_rows(w, h, {r, g, b}) do
    row = for _ <- 1..w, do: {r, g, b, 255}
    for _ <- 1..h, do: row
  end
end
