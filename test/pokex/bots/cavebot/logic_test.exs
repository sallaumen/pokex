defmodule Pokex.Bots.Cavebot.LogicTest do
  use ExUnit.Case, async: true
  alias Pokex.Bots.Cavebot.{Logic, Route}

  @cfg %{
    arrival_tolerance: 1,
    walk_timeout_ms: 3000,
    stuck_max_retries: 4,
    clear_debounce_ms: 800,
    fight_timeout_ms: 20_000,
    post_kill_dwell_ms: 1200
  }

  defp route do
    {:ok, r} = Route.append(elem(Route.append(Route.new("r"), {10, 10, 7}), 1), {20, 10, 7})
    r
  end

  defp world(pos, enemies \\ 0, combat \\ :hunting),
    do: %{pos: pos, enemies: enemies, combat_state: combat}

  test "the first step turns combat on" do
    l = Logic.new(route(), @cfg)
    assert {l, :run_combat} = Logic.step(l, world({0, 0, 7}), 0)
    assert l.combat_running?
  end

  test "walks toward the waypoint and advances on arrival" do
    {l, :run_combat} = Logic.step(Logic.new(route(), @cfg), world({5, 10, 7}), 0)
    assert {l, {:walk, dx, dy}} = Logic.step(l, world({5, 10, 7}), 10)
    assert {dx, dy} == {5, 0}
    assert {l, _} = Logic.step(l, world({10, 10, 7}), 20)
    assert l.wp_index == 1
  end

  test "an enemy appearing moves to fighting with no new command" do
    {l, _} = Logic.step(Logic.new(route(), @cfg), world({10, 10, 7}, 2), 0)
    assert {l, :none} = Logic.step(l, world({10, 10, 7}, 2), 10)
    assert l.state == :fighting
  end

  test "a clear fight sustained through the debounce resumes walking after the dwell" do
    l = %{Logic.new(route(), @cfg) | state: :fighting, combat_running?: true}
    {l, :none} = Logic.step(l, world({10, 10, 7}, 0), 0)
    {l, _} = Logic.step(l, world({10, 10, 7}, 0), 900)
    assert l.state == :post_fight
    {l, _} = Logic.step(l, world({10, 10, 7}, 0), 900 + 1300)
    assert l.state == :walking
  end

  test "a z change blocks" do
    l = Logic.new(route(), @cfg)
    assert {_l, {:block, :floor_changed}} = Logic.step(l, world({10, 10, 6}), 0)
  end

  test "standing still becomes stuck and, retries exhausted, blocks" do
    {l, :run_combat} = Logic.step(Logic.new(route(), @cfg), world({5, 10, 7}), 0)
    {l, {:walk, 5, 0}} = Logic.step(l, world({5, 10, 7}), 10)

    {l, {:walk, 5, 0}} = Logic.step(l, world({5, 10, 7}), 2000)
    assert l.state == :walking

    {l, {:walk, 5, 0}} = Logic.step(l, world({5, 10, 7}), 3010)
    assert l.state == :stuck
    assert l.retries == 0

    l =
      Enum.reduce(1..4, l, fn i, acc ->
        {acc, {:walk, 5, 0}} = Logic.step(acc, world({5, 10, 7}), 3010 + i * 100)
        assert acc.retries == i
        acc
      end)

    assert {l, {:block, :stuck}} = Logic.step(l, world({5, 10, 7}), 4000)
    assert l.state == :blocked

    assert {_l, :none} = Logic.step(l, world({5, 10, 7}), 4100)
  end

  test "stuck: position changing again resumes walking and resets retries" do
    {l, :run_combat} = Logic.step(Logic.new(route(), @cfg), world({5, 10, 7}), 0)
    {l, {:walk, 5, 0}} = Logic.step(l, world({5, 10, 7}), 10)
    {l, {:walk, 5, 0}} = Logic.step(l, world({5, 10, 7}), 3010)
    assert l.state == :stuck

    {l, {:walk, 5, 0}} = Logic.step(l, world({5, 10, 7}), 3100)
    assert l.retries == 1

    {l, {:walk, 4, 0}} = Logic.step(l, world({6, 10, 7}), 3200)
    assert l.state == :walking
    assert l.retries == 0
  end

  test "fighting past fight_timeout becomes fight_stalled and then blocks" do
    l = %{Logic.new(route(), @cfg) | state: :fighting, combat_running?: true}

    {l, :none} = Logic.step(l, world({10, 10, 7}, 2), 0)
    assert l.state == :fighting

    {l, :none} = Logic.step(l, world({10, 10, 7}, 2), 19_000)
    assert l.state == :fighting

    {l, :none} = Logic.step(l, world({10, 10, 7}, 2), 20_000)
    assert l.state == :fight_stalled
    assert l.retries == 0

    l =
      Enum.reduce(1..4, l, fn i, acc ->
        {acc, {:nudge, 1, 0}} = Logic.step(acc, world({10, 10, 7}, 2), 20_000 + i * 100)
        assert acc.retries == i
        acc
      end)

    assert {l, {:block, :fight_stalled}} = Logic.step(l, world({10, 10, 7}, 2), 21_000)
    assert l.state == :blocked
  end

  test "a z change during the fight also blocks (any state)" do
    l = %{Logic.new(route(), @cfg) | state: :fighting, combat_running?: true}
    assert {l, {:block, :floor_changed}} = Logic.step(l, world({10, 10, 5}, 3), 0)
    assert l.state == :blocked

    assert {_l, :none} = Logic.step(l, world({10, 10, 4}, 3), 10)
  end

  test "walking with an unknown position holds instead of walking blind" do
    {l, :run_combat} = Logic.step(Logic.new(route(), @cfg), world({5, 10, 7}), 0)
    assert {l, :none} = Logic.step(l, world(nil), 10)
    assert l.state == :walking
  end

  test "without a position, blindness is marked and grows; the position returning clears it" do
    {l, :run_combat} = Logic.step(Logic.new(route(), @cfg), world({5, 10, 7}), 0)
    assert Logic.blind_ms(l, 10) == nil

    {l, :none} = Logic.step(l, world(nil), 100)
    assert Logic.blind_ms(l, 100) == 0

    {l, :none} = Logic.step(l, world(nil), 2_500)
    assert Logic.blind_ms(l, 2_500) == 2_400
    assert l.state == :walking

    {l, {:walk, 5, 0}} = Logic.step(l, world({5, 10, 7}), 2_600)
    assert Logic.blind_ms(l, 2_600) == nil
  end

  test "blind while stuck is also marked, and never becomes a block" do
    {l, :run_combat} = Logic.step(Logic.new(route(), @cfg), world({5, 10, 7}), 0)
    {l, {:walk, 5, 0}} = Logic.step(l, world({5, 10, 7}), 10)
    {l, {:walk, 5, 0}} = Logic.step(l, world({5, 10, 7}), 3010)
    assert l.state == :stuck

    l =
      Enum.reduce(1..10, l, fn i, acc ->
        {acc, :none} = Logic.step(acc, world(nil), 3010 + i * 100)
        assert acc.state == :stuck
        assert acc.retries == 0
        acc
      end)

    assert Logic.blind_ms(l, 4_110) == 1_000
  end

  test "a clear interrupted by a new enemy resets the debounce" do
    l = %{Logic.new(route(), @cfg) | state: :fighting, combat_running?: true}
    {l, :none} = Logic.step(l, world({10, 10, 7}, 0), 0)
    {l, :none} = Logic.step(l, world({10, 10, 7}, 1), 400)
    assert l.state == :fighting
    {l, :none} = Logic.step(l, world({10, 10, 7}, 0), 500)
    {l, :none} = Logic.step(l, world({10, 10, 7}, 0), 1200)
    assert l.state == :fighting
    {l, :none} = Logic.step(l, world({10, 10, 7}, 0), 1400)
    assert l.state == :post_fight
  end

  # {:nudge, 0, 0} became a click on the minimap center — the tile the player already
  # occupies. No nudge at all: it burned the retries and blocked without ever trying.
  test "the nudge is never (0,0) — from any position, with or without a reading" do
    stalled = %{
      Logic.new(route(), @cfg)
      | state: :fight_stalled,
        combat_running?: true
    }

    positions = [
      {10, 10, 7},
      {5, 10, 7},
      {30, 10, 7},
      {10, 4, 7},
      {10, 44, 7},
      {3, 3, 7},
      nil
    ]

    for pos <- positions do
      assert {_l, {:nudge, dx, dy}} = Logic.step(stalled, world(pos, 2), 0)
      assert {dx, dy} != {0, 0}
      assert abs(dx) <= 1 and abs(dy) <= 1
    end
  end

  test "the nudge points at the current waypoint, one tile at a time" do
    stalled = %{Logic.new(route(), @cfg) | state: :fight_stalled, combat_running?: true}

    assert {_l, {:nudge, 1, 0}} = Logic.step(stalled, world({5, 10, 7}, 2), 0)
    assert {_l, {:nudge, -1, 0}} = Logic.step(stalled, world({40, 10, 7}, 2), 0)
    assert {_l, {:nudge, 1, 1}} = Logic.step(stalled, world({2, 2, 7}, 2), 0)
    assert {_l, {:nudge, -1, -1}} = Logic.step(stalled, world({99, 99, 7}, 2), 0)
  end

  test "wp_index wraps around at the end of the route" do
    {l, :run_combat} = Logic.step(Logic.new(route(), @cfg), world({0, 0, 7}), 0)
    {l, _} = Logic.step(l, world({10, 10, 7}), 10)
    assert l.wp_index == 1
    {l, _} = Logic.step(l, world({20, 10, 7}), 20)
    assert l.wp_index == 0
  end
end
