defmodule Pokex.Bots.Fisher.Sensors.RealTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.Fisher.Sensors
  alias Pokex.Calibration

  defp rows(w, h, {r, g, b}), do: List.duplicate(List.duplicate({r, g, b, 255}, w), h)

  defp calib(tmp, baseline_path) do
    %Calibration{
      scale: 2.0,
      screen_w: 1000,
      screen_h: 700,
      water_point: {400, 300},
      glow_region: {368, 268, 64, 64},
      battle_region: {700, 100, 260, 200},
      arena_region: {560, 260, 100, 100},
      neutral_point: {420, 350},
      glow_baselines: [baseline_path],
      battle_baseline: Path.join(tmp, "none.png"),
      suggested_glow_threshold: 15.0
    }
  end

  @tag :tmp_dir
  test "glow returns the raw cyan bubble count (driver applies the threshold)", %{tmp_dir: tmp} do
    baseline = Pokex.PngFixtures.write!(Path.join(tmp, "base.png"), rows(8, 8, {0, 60, 120}))
    # 24x24 = 576 cyan pixels
    bubbly = Pokex.PngFixtures.write!(Path.join(tmp, "bubbly.png"), rows(24, 24, {100, 200, 220}))

    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, bubbly}]})

    assert {:ok, %{glow: 576, cursor: {500, 500}}} =
             Sensors.Real.observe(
               [:cursor, :glow],
               calib(tmp, baseline),
               Pokex.Settings.defaults()
             )
  end

  @tag :tmp_dir
  test "glow reads ~0 on calm (dark-blue, low-green) water", %{tmp_dir: tmp} do
    baseline = Pokex.PngFixtures.write!(Path.join(tmp, "base.png"), rows(8, 8, {0, 60, 120}))
    # dark blue water: green is too low to count as a cyan bubble
    calm = Pokex.PngFixtures.write!(Path.join(tmp, "calm.png"), rows(16, 16, {30, 80, 150}))

    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, calm}]})

    assert {:ok, %{glow: 0}} =
             Sensors.Real.observe([:glow], calib(tmp, baseline), Pokex.Settings.defaults())
  end

  @tag :tmp_dir
  test "hostile observation converts frame pixels to screen points", %{tmp_dir: tmp} do
    baseline = Pokex.PngFixtures.write!(Path.join(tmp, "base.png"), rows(8, 8, {0, 60, 120}))

    arena_rows =
      for y <- 0..99 do
        for x <- 0..99 do
          if x in 44..55 and y in 28..31, do: {255, 30, 30, 255}, else: {20, 80, 40, 255}
        end
      end

    arena = Pokex.PngFixtures.write!(Path.join(tmp, "arena.png"), arena_rows)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, arena}]})

    assert {:ok, %{hostile: {585, 275}}} =
             Sensors.Real.observe([:hostile], calib(tmp, baseline), Pokex.Settings.defaults())
  end

  @tag :tmp_dir
  test "wild observation reads the battle strip", %{tmp_dir: tmp} do
    baseline = Pokex.PngFixtures.write!(Path.join(tmp, "base.png"), rows(8, 8, {0, 60, 120}))

    strip_rows =
      for y <- 0..99 do
        for x <- 0..29 do
          if x in 10..17 and y in 20..23, do: {230, 40, 40, 255}, else: {30, 30, 30, 255}
        end
      end

    strip = Pokex.PngFixtures.write!(Path.join(tmp, "strip.png"), strip_rows)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, strip}]})

    assert {:ok, %{wild: true}} =
             Sensors.Real.observe([:wild], calib(tmp, baseline), Pokex.Settings.defaults())
  end

  @tag :tmp_dir
  test "wild detection falls back to default min_count when settings omit the key", %{
    tmp_dir: tmp
  } do
    baseline = Pokex.PngFixtures.write!(Path.join(tmp, "base.png"), rows(8, 8, {0, 60, 120}))

    strip_rows =
      for y <- 0..99 do
        for x <- 0..29 do
          if x in 10..17 and y in 20..23, do: {230, 40, 40, 255}, else: {30, 30, 30, 255}
        end
      end

    strip = Pokex.PngFixtures.write!(Path.join(tmp, "strip.png"), strip_rows)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, strip}]})

    assert {:ok, %{wild: true}} =
             Sensors.Real.observe([:wild], calib(tmp, baseline), %{})
  end

  @tag :tmp_dir
  test "battle_lock reads per-row red bands (points × scale)", %{tmp_dir: tmp} do
    baseline = Pokex.PngFixtures.write!(Path.join(tmp, "base.png"), rows(8, 8, {0, 60, 120}))

    # battle_body of the calib is {700,100,230,200}; at scale 2.0 the frame is
    # 460×400. battle_row_height 52 → band = 104; the top is CENTERED on the click
    # point, so top = 18*2 - 104/2 = -16, and band 1 spans frame-y [88,192). Paint
    # the ring's red squarely inside band 1.
    body_rows =
      for y <- 0..399 do
        for x <- 0..459 do
          if x in 0..200 and y in 100..180, do: {230, 40, 40, 255}, else: {20, 20, 20, 255}
        end
      end

    body = Pokex.PngFixtures.write!(Path.join(tmp, "body.png"), body_rows)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, body}]})

    assert {:ok, %{battle_lock: counts}} =
             Sensors.Real.observe([:battle_lock], calib(tmp, baseline), Pokex.Settings.defaults())

    assert length(counts) == 6
    assert Enum.at(counts, 1) > 0
    assert Enum.at(counts, 0) == 0
    assert Enum.at(counts, 2) == 0
    assert Enum.all?(Enum.drop(counts, 2), &(&1 == 0))
  end

  @tag :tmp_dir
  test "battle_lock falls back to default band/rows when settings omit the keys", %{tmp_dir: tmp} do
    baseline = Pokex.PngFixtures.write!(Path.join(tmp, "base.png"), rows(8, 8, {0, 60, 120}))
    body = Pokex.PngFixtures.write!(Path.join(tmp, "body.png"), rows(20, 20, {20, 20, 20}))
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, body}]})

    # empty settings → band/rows fall back to defaults 30/6, list length still 6
    assert {:ok, %{battle_lock: counts}} =
             Sensors.Real.observe([:battle_lock], calib(tmp, baseline), %{})

    assert length(counts) == 6
    assert Enum.all?(counts, &(&1 == 0))
  end

  @tag :tmp_dir
  test "propagates rig errors", %{tmp_dir: tmp} do
    baseline = Pokex.PngFixtures.write!(Path.join(tmp, "base.png"), rows(8, 8, {0, 60, 120}))
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:error, :denied}]})

    assert {:error, {:glow, :denied}} =
             Sensors.Real.observe([:glow], calib(tmp, baseline), Pokex.Settings.defaults())
  end
end
