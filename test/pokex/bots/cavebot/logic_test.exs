defmodule Pokex.Bots.Cavebot.LogicTest do
  use ExUnit.Case, async: true
  alias Pokex.Bots.Cavebot.{Logic, Route}

  @cfg %{
    arrival_tolerance: 1,
    walk_timeout_ms: 3000,
    stuck_max_retries: 4,
    clear_debounce_ms: 800,
    fight_timeout_ms: 20_000,
    post_kill_dwell_ms: 1200,
    blind_kick_ms: 1200,
    capture_wait_ms: 20_000
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

  test "standing still becomes stuck; retries exhausted SKIPS the corner, and a lap blocks" do
    {l, :run_combat} = Logic.step(Logic.new(route(), @cfg), world({5, 10, 7}), 0)
    {l, {:walk, 5, 0}} = Logic.step(l, world({5, 10, 7}), 10)

    {l, {:walk, 5, 0}} = Logic.step(l, world({5, 10, 7}), 2000)
    assert l.state == :walking

    {l, {:walk, 5, 0}} = Logic.step(l, world({5, 10, 7}), 3010)
    assert l.state == :stuck
    assert l.retries == 0

    l =
      Enum.reduce(1..4, l, fn i, acc ->
        {acc, {:walk, _dx, _dy}} = Logic.step(acc, world({5, 10, 7}), 3010 + i * 100)
        assert acc.retries == i
        acc
      end)

    # a corner walled on every side is not the end of a LOOP: try the next one
    assert {l, :none} = Logic.step(l, world({5, 10, 7}), 4000)
    assert l.state == :walking
    assert l.wp_index == 1
    assert l.skips == 1

    # …and a full lap of unreachable corners IS the end
    # still standing on the same tile (a skip clears last_pos, and a resumed
    # walk is exactly what SHOULD happen when the character moves)
    l = %{l | state: :stuck, retries: 99, last_pos: {5, 10, 7}}
    assert {l, {:block, :stuck}} = Logic.step(l, world({5, 10, 7}), 5000)
    assert l.state == :blocked

    assert {_l, :none} = Logic.step(l, world({5, 10, 7}), 5100)
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

    # past blind_kick_ms the hold becomes a KICK (movement restores sight),
    # but the blindness stays marked and the state never blocks
    {l, {:nudge, 1, 0}} = Logic.step(l, world(nil), 2_500)
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

  # The client only renders the coordinate while the position CHANGES (or
  # under a hovering mouse): a standing blind bot would stay blind forever.
  # One kicked step toward the waypoint brings the reading back.
  describe "blind kick" do
    test "blind while walking: holds first, kicks ONE nudge after blind_kick_ms" do
      logic = %{Logic.new(route(), @cfg) | combat_running?: true, last_pos: {8, 10, 7}}

      # fresh blindness: hold
      {logic, :none} = Logic.step(logic, world(nil), 1000)
      {logic, :none} = Logic.step(logic, world(nil), 1400)

      # past the interval: one kick toward wp 1 (east of last_pos)
      assert {logic, {:nudge, 1, 0}} = Logic.step(logic, world(nil), 2300)

      # throttled: no second kick inside the interval
      {logic, :none} = Logic.step(logic, world(nil), 2600)

      # and a second kick once another interval passes
      assert {_logic, {:nudge, 1, 0}} = Logic.step(logic, world(nil), 3600)
    end

    test "without any last position the kick still moves (east by convention)" do
      logic = %{Logic.new(route(), @cfg) | combat_running?: true}

      {logic, :none} = Logic.step(logic, world(nil), 1000)
      assert {_logic, {:nudge, 1, 0}} = Logic.step(logic, world(nil), 2300)
    end

    test "sight resets the kick throttle along with the blindness clock" do
      logic = %{Logic.new(route(), @cfg) | combat_running?: true, last_pos: {8, 10, 7}}

      {logic, :none} = Logic.step(logic, world(nil), 1000)
      assert {logic, {:nudge, 1, 0}} = Logic.step(logic, world(nil), 2300)

      # a read arrives: walking resumes, blindness and kick marks cleared
      assert {logic, {:walk, _dx, _dy}} = Logic.step(logic, world({8, 10, 7}), 2400)
      assert Logic.blind_ms(logic, 2500) == nil

      # blindness restarts from zero: no instant kick
      {logic, :none} = Logic.step(logic, world(nil), 2600)
      {_logic, :none} = Logic.step(logic, world(nil), 3000)
    end
  end

  # Arrow walking does not pathfind (the minimap click used to): pressing the
  # same direction into a wall burns the retries and blocks the hunt at the
  # first corner. A stuck retry slides along the wall instead.
  describe "unsticking against a wall" do
    test "odd retries drop the stuck axis and push the other one" do
      # wp 1 is {10, 10}; standing at {5, 8} the straight line is (5, 2) —
      # dominant x. Walled on x, the slide must push y.
      {l, :run_combat} = Logic.step(Logic.new(route(), @cfg), world({5, 8, 7}), 0)
      {l, {:walk, 5, 2}} = Logic.step(l, world({5, 8, 7}), 10)

      # no progress for walk_timeout_ms: stuck, and the first retry slides
      {l, {:walk, 5, 2}} = Logic.step(l, world({5, 8, 7}), 3_020)
      assert l.state == :stuck

      assert {l, {:walk, 0, 2}} = Logic.step(l, world({5, 8, 7}), 3_100)
      # even retry: straight line again (the obstacle may have walked off)
      assert {l, {:walk, 5, 2}} = Logic.step(l, world({5, 8, 7}), 3_200)
      assert {_l, {:walk, 0, 2}} = Logic.step(l, world({5, 8, 7}), 3_300)
    end

    test "a single-axis leg has nothing to slide onto and keeps pushing" do
      # standing at {5, 10}, wp 1 is {10, 10}: pure x, dy == 0
      {l, :run_combat} = Logic.step(Logic.new(route(), @cfg), world({5, 10, 7}), 0)
      {l, {:walk, 5, 0}} = Logic.step(l, world({5, 10, 7}), 10)
      {l, {:walk, 5, 0}} = Logic.step(l, world({5, 10, 7}), 3_020)

      assert {_l, {:walk, 5, 0}} = Logic.step(l, world({5, 10, 7}), 3_100)
    end

    test "moving again resumes the route with the retries reset" do
      {l, :run_combat} = Logic.step(Logic.new(route(), @cfg), world({5, 8, 7}), 0)
      {l, {:walk, 5, 2}} = Logic.step(l, world({5, 8, 7}), 10)
      {l, {:walk, 5, 2}} = Logic.step(l, world({5, 8, 7}), 3_020)
      {l, {:walk, 0, 2}} = Logic.step(l, world({5, 8, 7}), 3_100)

      # the slide worked: one tile south
      assert {l, {:walk, 5, 1}} = Logic.step(l, world({5, 9, 7}), 3_200)
      assert l.state == :walking
      assert l.retries == 0
    end
  end

  # The corpse belongs to the CAPTURE: a sweep is seconds of Body time against
  # a 1.2s dwell, so resuming on the clock alone walked the hunt away
  # mid-catch and made both workers fight over the same hands.
  describe "post-fight, waiting for the capture" do
    defp fighting_logic do
      %{Logic.new(route(), @cfg) | state: :fighting, combat_running?: true}
    end

    # the queue's LAST CHANGE is what says the capture is working; a queue
    # frozen at 2 is work nobody is going to do (the sweep, deferred)
    defp world_with_capture(pending, changed_at \\ 0) do
      %{
        pos: {10, 10, 7},
        enemies: 0,
        combat_state: :hunting,
        capture_pending: pending,
        capture_changed_at: if(pending > 0, do: changed_at)
      }
    end

    test "the dwell does not end while the Catcher still has corpses queued" do
      {l, :none} = Logic.step(fighting_logic(), world_with_capture(2), 0)
      {l, _} = Logic.step(l, world_with_capture(2), 900)
      assert l.state == :post_fight

      # long past the dwell, and the queue keeps MOVING: the capture owns the floor
      {l, :none} = Logic.step(l, world_with_capture(2, 4_900), 5_000)
      assert l.state == :post_fight

      # queue drained: the route resumes on the next tick
      {l, _} = Logic.step(l, world_with_capture(0), 5_100)
      assert l.state == :walking
    end

    test "a FROZEN queue never freezes the hunt: waiting needs progress" do
      {l, :none} = Logic.step(fighting_logic(), world_with_capture(1), 0)
      {l, _} = Logic.step(l, world_with_capture(1), 900)
      assert l.state == :post_fight

      # the queue has not moved since 0 — past the wait, the route goes on
      {l, _} = Logic.step(l, world_with_capture(1, 0), 900 + 20_001)
      assert l.state == :walking
    end

    test "with no capture pending the dwell behaves exactly as before" do
      {l, :none} = Logic.step(fighting_logic(), world_with_capture(0), 0)
      {l, _} = Logic.step(l, world_with_capture(0), 900)
      assert l.state == :post_fight

      {l, _} = Logic.step(l, world_with_capture(0), 900 + 1_300)
      assert l.state == :walking
    end
  end

  # Lucas's first real hunt (2026-08-10) died here: combat killed its target,
  # said "caçando o próximo", the spot had more pokémon — and 20 seconds of
  # honest work were declared "a luta não termina". The timeout measures a
  # fight going NOWHERE, not a fight taking long.
  describe "a fight that is progressing is not a stalled fight" do
    defp fighting do
      %{Logic.new(route(), @cfg) | state: :fighting, combat_running?: true}
    end

    defp battling(count), do: %{pos: {10, 10, 7}, enemies: count, combat_state: :fighting}

    test "a changing enemy count restarts the clock — kills ARE progress" do
      {l, :none} = Logic.step(fighting(), battling(3), 0)
      {l, :none} = Logic.step(l, battling(3), 10_000)

      # one died at 19s: the fight is working, the clock restarts
      {l, :none} = Logic.step(l, battling(2), 19_000)
      assert l.state == :fighting

      # 19s later the old clock would have blocked twice over
      {l, :none} = Logic.step(l, battling(2), 30_000)
      assert l.state == :fighting

      # and a new arrival counts as progress just the same
      {l, :none} = Logic.step(l, battling(3), 38_000)
      assert l.state == :fighting
    end

    test "a screen frozen through the whole timeout still stalls" do
      {l, :none} = Logic.step(fighting(), battling(1), 0)
      {l, :none} = Logic.step(l, battling(1), 10_000)
      {l, :none} = Logic.step(l, battling(1), 20_001)

      assert l.state == :fight_stalled
    end

    test "the count is remembered across the clear, so the next fight starts fresh" do
      {l, :none} = Logic.step(fighting(), battling(2), 0)
      # screen clears and the dwell runs out: back to walking
      {l, :none} = Logic.step(l, battling(0), 1_000)
      {l, _} = Logic.step(l, battling(0), 2_000)
      assert l.state == :post_fight
      assert l.last_enemies == 0
    end
  end

  # "voltou pro começo e travou numa parede" (Lucas, 2026-08-10): a restart
  # mid-route sent the character back to waypoint 1, across the map, through
  # walls arrow keys cannot path around. A hunt begins at the CLOSEST corner.
  describe "entering the route" do
    test "the first sighting picks the nearest waypoint, not the first" do
      {l, :run_combat} = Logic.step(Logic.new(route(), @cfg), world({17, 10, 7}), 0)
      {l, {:walk, dx, dy}} = Logic.step(l, world({17, 10, 7}), 10)

      # wp 2 is {20, 10}: three tiles away, against seven for wp 1
      assert l.wp_index == 1
      assert {dx, dy} == {3, 0}
    end

    test "homing happens once — walking on does not re-enter the route" do
      {l, :run_combat} = Logic.step(Logic.new(route(), @cfg), world({10, 10, 7}), 0)
      {l, :none} = Logic.step(l, world({10, 10, 7}), 10)
      assert l.wp_index == 1

      # now standing next to wp 1 again: without the latch it would re-home
      {l, {:walk, _dx, _dy}} = Logic.step(l, world({9, 10, 7}), 500)
      assert l.wp_index == 1
    end
  end
end
