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
  test "glow fires on frame-to-frame variation (the bubbles animate)", %{tmp_dir: tmp} do
    baseline = Pokex.PngFixtures.write!(Path.join(tmp, "base.png"), rows(8, 8, {0, 60, 120}))
    calm = Pokex.PngFixtures.write!(Path.join(tmp, "calm.png"), rows(8, 8, {0, 60, 120}))
    bubbly = Pokex.PngFixtures.write!(Path.join(tmp, "bubbly.png"), rows(8, 8, {200, 220, 255}))

    # two DIFFERENT captures in a row → high variation → a bite
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, calm}, {:ok, bubbly}]})

    assert {:ok, %{glow: true, cursor: {500, 500}}} =
             Sensors.Real.observe(
               [:cursor, :glow],
               calib(tmp, baseline),
               Pokex.Settings.defaults()
             )
  end

  @tag :tmp_dir
  test "glow stays false on calm water (two identical captures)", %{tmp_dir: tmp} do
    baseline = Pokex.PngFixtures.write!(Path.join(tmp, "base.png"), rows(8, 8, {0, 60, 120}))
    calm = Pokex.PngFixtures.write!(Path.join(tmp, "calm.png"), rows(8, 8, {0, 60, 120}))

    # a single element sticks → both captures identical → zero variation
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, calm}]})

    assert {:ok, %{glow: false}} =
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
  test "propagates rig errors", %{tmp_dir: tmp} do
    baseline = Pokex.PngFixtures.write!(Path.join(tmp, "base.png"), rows(8, 8, {0, 60, 120}))
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:error, :denied}]})

    assert {:error, {:glow, :denied}} =
             Sensors.Real.observe([:glow], calib(tmp, baseline), Pokex.Settings.defaults())
  end
end
