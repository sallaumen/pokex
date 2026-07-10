defmodule Pokex.Perception.Interpret.CorpsesTest do
  use ExUnit.Case, async: true

  alias Pokex.Perception.Interpret.Corpses
  alias Pokex.{Calibration, Settings}
  alias Pokex.Vision.Frame

  # 64x64 frame = 4x4 grid of 16px cells at scale 1.0.
  defp calib do
    %Calibration{
      scale: 1.0,
      screen_w: 1000,
      screen_h: 700,
      water_point: {1, 1},
      glow_region: {0, 0, 8, 8},
      battle_region: {900, 0, 80, 400},
      arena_region: {100, 200, 64, 64},
      neutral_point: {500, 500}
    }
  end

  defp settings(overrides \\ %{}) do
    Map.merge(Settings.defaults(), Map.merge(%{corpse_warmup_frames: 3}, overrides))
  end

  # A frame painted by fun.(x, y) -> {r, g, b}.
  defp frame(paint) do
    rgba =
      for y <- 0..63, x <- 0..63, into: <<>> do
        {r, g, b} = paint.(x, y)
        <<r, g, b, 255>>
      end

    %Frame{width: 64, height: 64, rgba: rgba}
  end

  defp ground(_x, _y), do: {100, 90, 60}

  # Paint a 16x16 "corpse" whose top-left is the given cell (cx, cy).
  defp with_corpse(cx, cy) do
    fn x, y ->
      if div(x, 16) in [cx, cx + 1] and div(y, 16) == cy, do: {230, 40, 40}, else: ground(x, y)
    end
  end

  defp warm_up(settings) do
    {_obs, st} = Corpses.interpret(frame(&ground/2), calib(), settings, nil)

    Enum.reduce(1..2, st, fn _i, acc ->
      {obs, next} = Corpses.interpret(frame(&ground/2), calib(), settings, acc)
      refute obs.scanning? and obs.corpses != []
      next
    end)
  end

  test "warmup publishes scanning?: false, then flips to scanning" do
    s = settings()
    {obs, st} = Corpses.interpret(frame(&ground/2), calib(), s, nil)
    assert obs == %{scanning?: false, corpses: []}

    {_obs, st} = Corpses.interpret(frame(&ground/2), calib(), s, st)
    {obs, _st} = Corpses.interpret(frame(&ground/2), calib(), s, st)
    assert obs.scanning?
  end

  test "a new static blob becomes a corpse only after the stationary frames, in screen points" do
    s = settings()
    st = warm_up(s)

    # frame 1 with the blob: tracked but not yet confirmed (stationary_frames: 2)
    {obs, st} = Corpses.interpret(frame(with_corpse(1, 1)), calib(), s, st)
    assert obs.corpses == []

    # frame 2, same place: confirmed. Blob spans cells {1,1},{2,1} → center ~x=32..48,y=24
    {obs, _st} = Corpses.interpret(frame(with_corpse(1, 1)), calib(), s, st)
    assert [{sx, sy}] = obs.corpses
    # screen point = arena_region origin {100, 200} + frame px (scale 1.0)
    assert sx in 130..148
    assert sy in 220..232
  end

  test "a blob that moves every frame never becomes a corpse" do
    s = settings()
    st = warm_up(s)

    {obs, st} = Corpses.interpret(frame(with_corpse(0, 0)), calib(), s, st)
    assert obs.corpses == []
    {obs, st} = Corpses.interpret(frame(with_corpse(2, 2)), calib(), s, st)
    assert obs.corpses == []
    {obs, _st} = Corpses.interpret(frame(with_corpse(0, 2)), calib(), s, st)
    assert obs.corpses == []
  end

  test "cells that flicker during warmup are masked and never produce corpses" do
    s = settings()

    # 'water' in the bottom row of cells flickers during warmup
    water = fn phase ->
      fn x, y ->
        if div(y, 16) == 3 and rem(x + phase, 2) == 0, do: {30, 60, 200}, else: ground(x, y)
      end
    end

    {_obs, st} = Corpses.interpret(frame(water.(0)), calib(), s, nil)
    {_obs, st} = Corpses.interpret(frame(water.(1)), calib(), s, st)
    {_obs, st} = Corpses.interpret(frame(water.(0)), calib(), s, st)

    # a "corpse" painted INSIDE the masked water row is invisible…
    still_water = fn x, y ->
      if div(y, 16) == 3 and div(x, 16) in [1, 2], do: {230, 40, 40}, else: water.(0).(x, y)
    end

    {obs, st} = Corpses.interpret(frame(still_water), calib(), s, st)
    {obs2, _st} = Corpses.interpret(frame(still_water), calib(), s, st)
    assert obs.corpses == []
    assert obs2.corpses == []
  end

  test "a blob smaller than corpse_min_cells is noise" do
    # min 2 cells; paint a single-cell blob
    s = settings()
    st = warm_up(s)

    one_cell = fn x, y ->
      if div(x, 16) == 1 and div(y, 16) == 1, do: {230, 40, 40}, else: ground(x, y)
    end

    {_obs, st} = Corpses.interpret(frame(one_cell), calib(), s, st)
    {obs, _st} = Corpses.interpret(frame(one_cell), calib(), s, st)
    # a 16px cell has 16 samples all changed → hot, but 1 cell < corpse_min_cells 2
    assert obs.corpses == []
  end
end
