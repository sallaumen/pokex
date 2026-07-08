defmodule Pokex.Bots.Loot.LogicTest do
  use ExUnit.Case, async: true
  alias Pokex.Bots.Loot.Logic

  def config do
    %{
      player_point: {600, 300},
      tile_px: 50,
      walk_step_ms: 5,
      loot_presses: 2,
      max_walk_tiles: 7,
      wait_loot_ms: 400,
      wait_after_capture_ms: 2000,
      auto_capture: true,
      fight_timeout_ms: 90_000,
      max_consecutive_failures: 3
    }
  end

  def obs, do: %{cursor: {500, 500}}

  test "known corpse: walk adjacent, space-loot, capture, walk back to origin, idle" do
    # corpse floating name at {700,350}; the body is one tile below → {700,400}. player
    # {600,300}, tile 50 → dx=2, dy=2 → stop ADJACENT (one short per axis) = ["right","down"],
    # capture offset {1,1}.
    {l, []} = Logic.start(Logic.new(config()), {700, 350}, 0)
    assert l.state == :walking_to_loot
    assert l.walk_plan == ["right", "down"]
    assert l.loot_offset == {1, 1}
    assert Logic.busy?(l)

    {l, [{:press, "right"}]} = Logic.step(l, obs(), 100)
    assert l.waiting_until == 105

    {l, [{:press, "down"}]} = Logic.step(l, obs(), 200)
    assert l.walk_taken == ["down", "right"]

    {l, []} = Logic.step(l, obs(), 300)
    assert l.state == :looting

    {l, [{:press, "space"}]} = Logic.step(l, obs(), 400)
    assert l.waiting_until == 800

    {l, [{:press, "space"}]} = Logic.step(l, obs(), 900)
    {l, []} = Logic.step(l, obs(), 1400)
    assert l.state == :capturing
    assert l.counters.loots == 1

    {l, [{:capture_sequence, {650, 350}}]} = Logic.step(l, obs(), 1900)
    assert l.state == :walking_back
    # exact reverse of walk_taken via opposites → nets back to the origin tile
    assert l.walk_plan == ["up", "left"]
    assert l.counters.captures == 1

    {l, [{:press, "up"}]} = Logic.step(l, obs(), 4000)
    {l, [{:press, "left"}]} = Logic.step(l, obs(), 4100)
    {l, []} = Logic.step(l, obs(), 4200)
    assert l.state == :idle
    refute Logic.busy?(l)
  end

  test "unknown corpse (nil): loot in place, capture one tile below, no walking" do
    {l, []} = Logic.start(Logic.new(config()), nil, 0)
    assert l.state == :looting
    assert l.walk_plan == []

    {l, [{:press, "space"}]} = Logic.step(l, obs(), 100)
    {l, [{:press, "space"}]} = Logic.step(l, obs(), 600)
    {l, []} = Logic.step(l, obs(), 1100)
    assert l.state == :capturing

    {l, [{:capture_sequence, {600, 350}}]} = Logic.step(l, obs(), 1600)
    assert l.state == :walking_back
    assert l.walk_plan == []

    {l, []} = Logic.step(l, obs(), 3700)
    assert l.state == :idle
  end

  test "corpse farther than max_walk_tiles is treated as unknown (loot in place)" do
    {l, []} = Logic.start(Logic.new(config()), {1200, 300}, 0)
    assert l.state == :looting
    assert l.walk_plan == []
    assert l.loot_offset == nil
  end

  test "auto_capture disabled throws no pokeball" do
    cfg = Map.put(config(), :auto_capture, false)
    logic = %Logic{state: :capturing, config: cfg, loot_offset: {0, 1}}

    {l, actions} = Logic.step(logic, obs(), 100)
    assert l.state == :walking_back
    assert [{:log, _}] = actions
    refute Enum.any?(actions, &match?({:capture_sequence, _}, &1))
    assert l.counters.captures == 0
  end
end
