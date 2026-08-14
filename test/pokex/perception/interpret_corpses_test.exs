defmodule Pokex.Perception.Interpret.CorpsesTest do
  # async: false — CorpseLibrary lives in the global home (:home_dir) with a
  # :persistent_term cache; each test points it at its own tmp via put_env.
  use ExUnit.Case, async: false

  alias Pokex.Bots.Catcher.CorpseLibrary
  alias Pokex.Bots.Catcher.SpotScan
  alias Pokex.Calibration
  alias Pokex.Perception.Interpret.Corpses
  alias Pokex.Settings
  alias Pokex.Vision.Frame

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Pokex.TestHome.restore() end)
    :ok
  end

  # 64x64 frame = 4x4 grid of 16px cells at scale 1.0.
  defp calib do
    %Calibration{
      scale: 1.0,
      screen_w: 1000,
      screen_h: 700,
      water_point: {1, 1},
      glow_region: {0, 0, 8, 8},
      battle_region: {900, 0, 80, 400},
      neutral_point: {500, 500}
    }
  end

  # The frames come from the search square around the character, so the screen
  # points are that square's origin plus the pixel — derived, never hardcoded,
  # so a change of radius does not silently invalidate the expectation.
  defp add({ax, ay}, {bx, by}), do: {ax + bx, ay + by}

  defp origin do
    {:ok, {x, y, _w, _h}} = SpotScan.region(calib())
    {x, y}
  end

  defp settings(overrides \\ %{}) do
    Map.merge(Settings.defaults(), Map.merge(%{corpse_warmup_frames: 3}, overrides))
  end

  defp frame(paint), do: Pokex.FrameFixtures.of(64, 64, paint)

  defp ground(_x, _y), do: {100, 90, 60}

  # Paint a 16x16 "corpse" whose top-left is the given cell (cx, cy).
  defp with_corpse(cx, cy) do
    fn x, y ->
      if div(x, 16) in [cx, cx + 1] and div(y, 16) == cy, do: {230, 40, 40}, else: ground(x, y)
    end
  end

  # The library IS the targeting: without a taught corpse nothing becomes a
  # target, so detection tests teach the red-on-ground the frames paint.
  defp teach_red!(name \\ "Corsola") do
    crop = Frame.crop(frame(with_corpse(1, 1)), {4, 0, 56, 56})
    {:ok, _n} = CorpseLibrary.add(name, crop)
    :ok
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
    assert obs == %{scanning?: false, corpses: [], known: %{}}

    {_obs, st} = Corpses.interpret(frame(&ground/2), calib(), s, st)
    {obs, _st} = Corpses.interpret(frame(&ground/2), calib(), s, st)
    assert obs.scanning?
  end

  # blob spans cells {1,1},{2,1}, center near frame {40,24}; screen point = arena origin {100,200} + frame px
  test "a new static blob becomes a corpse only after the stationary frames, in screen points" do
    teach_red!()
    s = settings()
    st = warm_up(s)

    {obs, st} = Corpses.interpret(frame(with_corpse(1, 1)), calib(), s, st)
    assert obs.corpses == []

    {obs, _st} = Corpses.interpret(frame(with_corpse(1, 1)), calib(), s, st)
    assert [{sx, sy}] = obs.corpses
    {ox, oy} = origin()
    assert (sx - ox) in 30..48
    assert (sy - oy) in 20..32
  end

  test "a confirmed target carries its name and score in :known" do
    teach_red!("Corsola")
    s = settings()
    st = warm_up(s)

    {_obs, st} = Corpses.interpret(frame(with_corpse(1, 1)), calib(), s, st)
    {obs, _st} = Corpses.interpret(frame(with_corpse(1, 1)), calib(), s, st)

    assert [point] = obs.corpses
    assert %{name: "Corsola", score: score} = obs.known[point]
    assert score >= Settings.get(:corpse_match_min_similarity)
  end

  # measured: shared ground alone scores ~84% on the histogram (threshold 0.72),
  # so the mismatching blob must be large (48x32, ground ~51%) to prove the miss
  test "a blob that does not match the library never becomes a target" do
    teach_red!()
    s = settings()
    st = warm_up(s)

    green = fn x, y ->
      if div(x, 16) in [1, 2, 3] and div(y, 16) in [1, 2], do: {40, 230, 40}, else: ground(x, y)
    end

    {obs, st} = Corpses.interpret(frame(green), calib(), s, st)
    assert obs.corpses == []
    {obs, _st} = Corpses.interpret(frame(green), calib(), s, st)
    assert obs.corpses == []
    assert obs.known == %{}
  end

  test "an empty library yields no targets no matter how still the blob is" do
    s = settings()
    st = warm_up(s)

    {obs, st} = Corpses.interpret(frame(with_corpse(1, 1)), calib(), s, st)
    assert obs.corpses == []
    {obs, _st} = Corpses.interpret(frame(with_corpse(1, 1)), calib(), s, st)
    assert obs.corpses == []
  end

  test "a blob that moves every frame never becomes a corpse" do
    teach_red!()
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
    teach_red!()
    s = settings()

    water = fn phase ->
      fn x, y ->
        if div(y, 16) == 3 and rem(x + phase, 2) == 0, do: {30, 60, 200}, else: ground(x, y)
      end
    end

    {_obs, st} = Corpses.interpret(frame(water.(0)), calib(), s, nil)
    {_obs, st} = Corpses.interpret(frame(water.(1)), calib(), s, st)
    {_obs, st} = Corpses.interpret(frame(water.(0)), calib(), s, st)

    still_water = fn x, y ->
      if div(y, 16) == 3 and div(x, 16) in [1, 2], do: {230, 40, 40}, else: water.(0).(x, y)
    end

    {obs, st} = Corpses.interpret(frame(still_water), calib(), s, st)
    {obs2, _st} = Corpses.interpret(frame(still_water), calib(), s, st)
    assert obs.corpses == []
    assert obs2.corpses == []
  end

  # the new blob's center sits exactly corpse_stationary_tolerance_px (24) from
  # the mature track and must start its own count instead of borrowing maturity
  test "a new blob near a mature track does not inherit its maturity" do
    teach_red!()
    s = settings()
    st = warm_up(s)

    x_only = with_corpse(0, 0)

    {obs, st} = Corpses.interpret(frame(x_only), calib(), s, st)
    assert obs.corpses == []

    {obs, st} = Corpses.interpret(frame(x_only), calib(), s, st)
    assert obs.corpses == [add(origin(), {16, 8})]

    x_and_y = fn x, y ->
      if div(x, 16) == 2 and div(y, 16) in [1, 2], do: {230, 40, 40}, else: x_only.(x, y)
    end

    {obs, _st} = Corpses.interpret(frame(x_and_y), calib(), s, st)
    assert obs.corpses == [add(origin(), {16, 8})]
  end

  # a buggy "max over all tracks within tolerance" let BOTH new blobs inherit the
  # vacated track's count; a correct 1:1 assignment confirms at most one
  test "two brand-new blobs competing for one vacated mature track: at most one inherits it" do
    teach_red!()
    s = settings()
    st = warm_up(s)

    x_only = with_corpse(0, 0)
    {_obs, st} = Corpses.interpret(frame(x_only), calib(), s, st)
    {obs, st} = Corpses.interpret(frame(x_only), calib(), s, st)
    assert obs.corpses == [add(origin(), {16, 8})]

    two_new = fn x, y ->
      cond do
        div(x, 16) == 0 and div(y, 16) in [0, 1] -> {230, 40, 40}
        div(x, 16) == 2 and div(y, 16) in [1, 2] -> {230, 40, 40}
        true -> ground(x, y)
      end
    end

    {obs, _st} = Corpses.interpret(frame(two_new), calib(), s, st)
    assert length(obs.corpses) == 1
  end

  test "a blob smaller than corpse_min_cells is noise" do
    teach_red!()
    s = settings()
    st = warm_up(s)

    one_cell = fn x, y ->
      if div(x, 16) == 1 and div(y, 16) == 1, do: {230, 40, 40}, else: ground(x, y)
    end

    {_obs, st} = Corpses.interpret(frame(one_cell), calib(), s, st)
    {obs, _st} = Corpses.interpret(frame(one_cell), calib(), s, st)
    assert obs.corpses == []
  end
end
