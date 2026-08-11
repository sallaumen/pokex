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
    capture_wait_ms: 20_000,
    sweep_grace_ms: 1500,
    stop_wait_ms: 5_000,
    gather_wait_ms: 4_000
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

  test "a z change to a floor the route never visits blocks" do
    l = Logic.new(route(), @cfg)
    assert {_l, {:block, :floor_changed}} = Logic.step(l, world({10, 10, 6}), 0)
  end

  # "to fazendo justamente uma rota com 2 andares, com escadas" (Lucas,
  # 2026-08-10). Stairs are ordinary; a hole is not.
  describe "a route with stairs" do
    defp stairs_route do
      {:ok, r} = Route.append(Route.new("escada"), {0, 0, 7})
      {:ok, r} = Route.append(r, {5, 0, 7})
      {:ok, r} = Route.append(r, {5, 0, 6})
      {:ok, r} = Route.append(r, {9, 0, 6})
      r
    end

    test "walking on a floor the route knows is business as usual" do
      {l, :run_combat} = Logic.step(Logic.new(stairs_route(), @cfg), world({1, 0, 6}), 0)
      {l, {:walk, _dx, _dy}} = Logic.step(l, world({1, 0, 6}), 10)

      assert l.state == :walking
    end

    test "a floor NOBODY marked still blocks — the hole this guard was for" do
      l = Logic.new(stairs_route(), @cfg)

      assert {_l, {:block, :floor_changed}} = Logic.step(l, world({5, 0, 4}), 0)
    end

    test "the route is entered at the nearest corner ON THIS FLOOR" do
      # From {2, 3, 6} the closest corner in plain tiles is waypoint 1
      # ({0, 0, 7}, 5 tiles) — one FLOOR away, so unreachable by walking. The
      # closest one actually on this floor is waypoint 3 ({5, 0, 6}, 6 tiles).
      {l, :run_combat} = Logic.step(Logic.new(stairs_route(), @cfg), world({2, 3, 6}), 0)
      {l, _action} = Logic.step(l, world({2, 3, 6}), 10)

      assert l.wp_index == 2
    end

    # The tile at the top of the stairs shares x/y with the one at their foot:
    # without the floor in the arrival check the hunt ticks the climb off
    # without ever climbing, and walks the upper floor's route from below.
    test "standing BELOW the target is not arriving at it" do
      l = %{Logic.new(stairs_route(), @cfg) | combat_running?: true, homed?: true, wp_index: 2}

      {l, action} = Logic.step(l, world({5, 0, 7}), 10)
      assert l.wp_index == 2
      assert action != :none

      # and the same tile one floor up IS the arrival
      {l, :none} = Logic.step(l, world({5, 0, 6}), 20)
      assert l.wp_index == 3
    end
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
      # screen clears AND Combat disengages (an engaged clear may not run the
      # debounce — own describe): back to walking after the dwell
      {l, :none} = Logic.step(l, world({10, 10, 7}, 0, :hunting), 1_000)
      {l, _} = Logic.step(l, world({10, 10, 7}, 0, :hunting), 2_000)
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

  # "ele vai andar sem atacar ninguém" (Lucas, 2026-08-10): between "mobar
  # daqui" and "até aqui" the hunt walks THROUGH the mobs, gathering them,
  # instead of stopping to fight each one.
  describe "walking a mob stretch" do
    defp lure_route do
      {:ok, r} = Route.append(Route.new("r"), {0, 0, 7})
      {:ok, r} = Route.append(r, {10, 0, 7})
      {:ok, r} = Route.append(r, {10, 10, 7})
      {:ok, r} = Route.append(r, {0, 10, 7})

      # gather from waypoint 2 (index 1) until waypoint 4 (index 3)
      r |> Route.set_action(1, :lure_start) |> Route.set_action(3, :lure_end)
    end

    defp walking_toward(index) do
      %{Logic.new(lure_route(), @cfg) | combat_running?: true, wp_index: index, homed?: true}
    end

    test "the leg the hunt is ON is what counts, not the waypoint it left" do
      # heading to index 1 = the leg 0 → 1, before the mark: a normal leg
      refute Logic.luring?(walking_toward(1))

      # heading to 2 and to 3 = the legs 1 → 2 → 3: inside the stretch
      assert Logic.luring?(walking_toward(2))
      assert Logic.luring?(walking_toward(3))

      # heading back to 0 = the leg 3 → 0, out the other side of "até aqui"
      refute Logic.luring?(walking_toward(0))
    end

    test "enemies on screen do NOT stop a mob leg — that is the whole point" do
      logic = walking_toward(2)

      {logic, {:walk, _dx, _dy}} = Logic.step(logic, world({5, 0, 7}, 4), 10)
      assert logic.state == :walking
    end

    test "an engaged Combat does not hold the road either, while gathering" do
      logic = walking_toward(2)

      {logic, {:walk, _dx, _dy}} = Logic.step(logic, world({5, 0, 7}, 0, :fighting), 10)
      assert logic.state == :walking
    end

    test "past 'até aqui' the pile is fought like any other" do
      logic = walking_toward(0)

      {logic, :none} = Logic.step(logic, world({0, 10, 7}, 4), 10)
      assert logic.state == :fighting
    end

    # Entering the route at the nearest corner (#199) can drop the character
    # INSIDE a mob stretch — restart the hunt while standing among the
    # Venusaur and that is exactly what happens. It was reasoned to be
    # harmless and never proven; here is the proof, because "I thought about
    # it" is not a test.
    test "restarting inside a stretch gathers from where it entered" do
      logic = %{Logic.new(lure_route(), @cfg) | combat_running?: true}

      # {9, 3} enters at waypoint index 1 — the "mobar daqui" itself, still
      # ahead: the leg being walked is the plain one that leads INTO the mark
      {logic, {:walk, _dx, _dy}} = Logic.step(logic, world({9, 3, 7}), 10)
      assert logic.wp_index == 1
      refute Logic.luring?(logic)

      # and from the arrival on, it gathers — enemies BEFORE the mark are
      # fought like anywhere else, so the arrival tick is a clear one
      {logic, :none} = Logic.step(logic, world({10, 0, 7}), 20)
      assert logic.wp_index == 2
      assert Logic.luring?(logic)
    end

    test "restarting PAST the start mark gathers immediately, enemies and all" do
      # {13, 8} enters at index 2, which sits INSIDE the marked stretch. The
      # posture must come from the leg it entered on — before this, the
      # decision was made on the un-homed index 0 and a crowd on screen
      # stopped the hunt dead in the middle of the gathering.
      logic = %{Logic.new(lure_route(), @cfg) | combat_running?: true}

      {logic, {:walk, _dx, _dy}} = Logic.step(logic, world({13, 8, 7}, 2), 10)
      assert logic.wp_index == 2
      assert Logic.luring?(logic)
      assert logic.state == :walking
    end

    test "a route with no marks never lures" do
      logic = %{Logic.new(route(), @cfg) | combat_running?: true, homed?: true}

      refute Logic.luring?(logic)
      {logic, :none} = Logic.step(logic, world({5, 10, 7}, 1), 10)
      assert logic.state == :fighting
    end

    # Arriving at "até aqui" is what ends the gathering — the hunt must not be
    # left luring while it stands in the middle of everything it collected.
    test "arriving at 'até aqui' ends the stretch on the same tick" do
      logic = walking_toward(3)
      assert Logic.luring?(logic)

      {logic, :none} = Logic.step(logic, world({0, 10, 7}, 3), 10)
      assert logic.wp_index == 0
      refute Logic.luring?(logic)
    end
  end

  # "depois que matar tudo, fazer aquela varredura de captura antes de andar e
  # continuar a rota" (Lucas, 2026-08-10).
  describe "sweeping where the pile died" do
    defp stop_route(stops) do
      {:ok, r} = Route.append(Route.new("r"), {10, 10, 7})
      {:ok, r} = Route.append(r, {20, 10, 7})
      Enum.reduce(stops, r, &Route.set_stop(&2, 0, &1, true))
    end

    defp swept_route, do: stop_route([:sweep])

    defp after_kill_at(index, route) do
      %{
        Logic.new(route, @cfg)
        | state: :post_fight,
          combat_running?: true,
          homed?: true,
          wp_index: index,
          since: %{dwell: 0}
      }
    end

    defp swept_world(pending, changed_at) do
      %{
        pos: {10, 10, 7},
        enemies: 0,
        combat_state: :hunting,
        capture_pending: 0,
        capture_changed_at: nil,
        sweep_pending: pending,
        sweep_changed_at: changed_at
      }
    end

    test "the hunt asks for ONE sweep at a marked waypoint, then waits" do
      logic = after_kill_at(1, swept_route())

      assert {logic, {:sweep, nil}} = Logic.step(logic, swept_world(0, nil), 10)
      assert logic.state == :post_fight

      # and never asks twice for the same stop
      assert {logic, :none} = Logic.step(logic, swept_world(8, 20), 20)
      assert logic.state == :post_fight
    end

    test "an unmarked waypoint sweeps nothing and leaves on the dwell" do
      {:ok, plain} = Route.append(Route.new("r"), {10, 10, 7})
      logic = after_kill_at(0, plain)

      assert {logic, :none} = Logic.step(logic, swept_world(0, nil), 10)
      assert {logic, :none} = Logic.step(logic, swept_world(0, nil), 1_300)
      assert logic.state == :walking
    end

    test "the route waits while the sweep is WORKING, and leaves when it stops" do
      logic = after_kill_at(1, swept_route())
      {logic, {:sweep, _}} = Logic.step(logic, swept_world(0, nil), 0)

      # queue moving: hold, however long the dwell says
      {logic, :none} = Logic.step(logic, swept_world(8, 2_000), 2_100)
      assert logic.state == :post_fight

      {logic, :none} = Logic.step(logic, swept_world(3, 9_000), 9_100)
      assert logic.state == :post_fight

      # queue empty: the stop is over
      {logic, :none} = Logic.step(logic, swept_world(0, 9_000), 10_000)
      assert logic.state == :walking
    end

    # The grace exists for the first tick only: the Catcher has not built the
    # queue yet, and an empty queue at that instant is not a finished sweep.
    test "an empty queue right after the request is not a finished sweep" do
      logic = after_kill_at(1, swept_route())
      {logic, {:sweep, _}} = Logic.step(logic, swept_world(0, nil), 0)

      {logic, :none} = Logic.step(logic, swept_world(0, nil), 1_400)
      assert logic.state == :post_fight

      {logic, :none} = Logic.step(logic, swept_world(0, nil), 1_600)
      assert logic.state == :walking
    end

    # Same rule as every other wait in this machine: a queue that is not
    # MOVING is a queue nobody is working, and it must never hold the road.
    test "a frozen queue releases the hunt at the cap" do
      logic = after_kill_at(1, swept_route())
      {logic, {:sweep, _}} = Logic.step(logic, swept_world(0, nil), 0)

      {logic, :none} = Logic.step(logic, swept_world(9, 1_000), 2_000)
      assert logic.state == :post_fight

      {logic, :none} = Logic.step(logic, swept_world(9, 1_000), 22_000)
      assert logic.state == :walking
    end

    test "the next stop may sweep again — the latch is per stop, not per hunt" do
      logic = after_kill_at(1, swept_route())
      {logic, {:sweep, _}} = Logic.step(logic, swept_world(0, nil), 0)
      {logic, :none} = Logic.step(logic, swept_world(0, nil), 2_000)
      assert logic.state == :walking
      assert logic.stops_done == []
    end
  end

  # "Cooldown Ressurect ... Q -> Shift + Q na foto do pokemon -> Q, para
  # reviver, o que faz com que ele recupere os cooldowns" (Lucas, 2026-08-10).
  describe "what else the hunt does at a stop" do
    test "the revive goes out once, and the route resumes right after" do
      logic = after_kill_at(1, stop_route([:cooldown_revive]))

      assert {logic, :cooldown_revive} = Logic.step(logic, swept_world(0, nil), 10)
      assert {logic, :none} = Logic.step(logic, swept_world(0, nil), 20)
      assert {logic, :none} = Logic.step(logic, swept_world(0, nil), 1_300)
      assert logic.state == :walking
    end

    test "the plain wait stands still for stop_wait_ms, then leaves" do
      logic = after_kill_at(1, stop_route([:wait]))

      assert {logic, :none} = Logic.step(logic, swept_world(0, nil), 0)
      assert {logic, :none} = Logic.step(logic, swept_world(0, nil), 4_000)
      assert logic.state == :post_fight

      assert {logic, :none} = Logic.step(logic, swept_world(0, nil), 5_100)
      assert logic.state == :walking
    end

    # Marked together, they run in the canonical order — never two in one tick,
    # because each one owns the Body while it lasts.
    test "all three run in order, one per tick, and only then does it walk" do
      logic = after_kill_at(1, stop_route([:wait, :sweep, :cooldown_revive]))

      assert {logic, :cooldown_revive} = Logic.step(logic, swept_world(0, nil), 0)
      assert {logic, {:sweep, nil}} = Logic.step(logic, swept_world(0, nil), 10)

      # the sweep holds the road while its queue moves
      {logic, :none} = Logic.step(logic, swept_world(6, 100), 200)
      assert logic.state == :post_fight

      # queue drained: the wait is next, and it is a wait
      {logic, :none} = Logic.step(logic, swept_world(0, 100), 2_000)
      assert logic.state == :post_fight

      {logic, :none} = Logic.step(logic, swept_world(0, 100), 2_100)
      assert logic.state == :post_fight

      {logic, :none} = Logic.step(logic, swept_world(0, 100), 7_200)
      assert logic.state == :walking
    end

    # A mob walking in during the stop is a FIGHT, not an interruption to
    # push through: reviving recalls the pokémon, and doing that while
    # something is hitting it is the worst moment there is.
    test "an enemy arriving mid-stop sends the hunt back to fighting" do
      logic = after_kill_at(1, stop_route([:cooldown_revive, :sweep]))

      {logic, :cooldown_revive} = Logic.step(logic, swept_world(0, nil), 0)

      world = %{swept_world(0, nil) | enemies: 2}
      {logic, :none} = Logic.step(logic, world, 100)
      assert logic.state == :fighting

      # and an ENGAGED combat holds it there too, whatever the count says
      logic = after_kill_at(1, stop_route([:sweep]))
      world = %{swept_world(0, nil) | combat_state: :fighting}
      {logic, :none} = Logic.step(logic, world, 100)
      assert logic.state == :fighting
    end

    test "what already ran is not run again when the new fight ends" do
      logic = after_kill_at(1, stop_route([:cooldown_revive, :sweep]))
      {logic, :cooldown_revive} = Logic.step(logic, swept_world(0, nil), 0)

      # interrupted, fought, cleared again
      {logic, :none} = Logic.step(logic, %{swept_world(0, nil) | enemies: 1}, 100)
      {logic, :none} = Logic.step(logic, swept_world(0, nil), 200)
      {logic, :none} = Logic.step(logic, swept_world(0, nil), 1_100)
      assert logic.state == :post_fight

      # the sweep still owed goes out; the revive does NOT happen twice
      assert {logic, {:sweep, _}} = Logic.step(logic, swept_world(0, nil), 1_200)
      assert logic.stops_done == [:sweep, :cooldown_revive]
    end

    # "esses corpos de pokémons não estão ao redor do meu personagem" (Lucas,
    # 2026-08-11): he parks the pokémon with a middle click and the pile dies
    # around IT. Sweeping around the character throws every ball at bare
    # ground.
    test "the sweep is centred where the pokémon was parked" do
      route = Route.set_park_point(stop_route([:sweep]), 0, {2490, 417})
      logic = after_kill_at(1, route)

      assert {_logic, {:sweep, {2490, 417}}} = Logic.step(logic, swept_world(0, nil), 10)
    end

    test "with no parked point the sweep falls back to the character" do
      logic = after_kill_at(1, stop_route([:sweep]))

      assert {_logic, {:sweep, nil}} = Logic.step(logic, swept_world(0, nil), 10)
    end

    test "a waypoint with no stops leaves on the dwell, as it always did" do
      logic = after_kill_at(1, stop_route([]))

      {logic, :none} = Logic.step(logic, swept_world(0, nil), 10)
      {logic, :none} = Logic.step(logic, swept_world(0, nil), 1_300)
      assert logic.state == :walking
    end
  end

  # "quando termino de mobar, eu geralmente dá quatro segundos até todos os
  # bichos se agruparem ao redor do meu para daí eu voltar a mobar e matar todo
  # mundo" (Lucas, 2026-08-11). The pile is BEHIND him when he stops; hitting
  # the first one to arrive wastes the whole point of gathering.
  describe "letting the pile close in" do
    defp gather_route do
      {:ok, r} = Route.append(Route.new("r"), {0, 0, 7})
      {:ok, r} = Route.append(r, {10, 0, 7})
      {:ok, r} = Route.append(r, {10, 10, 7})
      r |> Route.set_action(0, :lure_start) |> Route.set_action(1, :lure_end)
    end

    defp arriving_at_end do
      %{
        Logic.new(gather_route(), @cfg)
        | combat_running?: true,
          homed?: true,
          wp_index: 1,
          last_pos: {9, 0, 7}
      }
    end

    test "arriving at 'até aqui' keeps holding fire while they gather" do
      logic = arriving_at_end()

      {logic, :none} = Logic.step(logic, world({10, 0, 7}, 4), 1_000)
      assert logic.wp_index == 2
      assert Logic.gathering?(logic, 1_000)

      # still holding two seconds later — they are still walking in
      assert Logic.gathering?(logic, 3_000)

      # …and free at four
      refute Logic.gathering?(logic, 5_100)
    end

    test "the hunt does not walk away during the huddle" do
      logic = arriving_at_end()
      {logic, :none} = Logic.step(logic, world({10, 0, 7}, 4), 1_000)

      # enemies on screen and the gathering window still open: it stands
      {logic, :none} = Logic.step(logic, world({10, 0, 7}, 4), 2_000)
      assert logic.state == :fighting
    end

    # "quatro segundos" was his estimate; the recording measures the real one
    # by watching him park the pokémon and counting to his first skill.
    test "a pause he was MEASURED taking wins over the configured one" do
      route = Route.set_timing(gather_route(), 1, gather_ms: 9_000)

      logic = %{
        Logic.new(route, @cfg)
        | combat_running?: true,
          homed?: true,
          wp_index: 1,
          last_pos: {9, 0, 7}
      }

      {logic, :none} = Logic.step(logic, world({10, 0, 7}, 4), 1_000)

      # the configured 4s is long past and it is STILL holding
      assert Logic.gathering?(logic, 7_000)
      refute Logic.gathering?(logic, 10_100)
    end

    test "a plain waypoint has no huddle to wait for" do
      logic = %{
        Logic.new(route(), @cfg)
        | combat_running?: true,
          homed?: true,
          wp_index: 1,
          last_pos: {9, 10, 7}
      }

      {logic, _action} = Logic.step(logic, world({10, 10, 7}), 1_000)
      refute Logic.gathering?(logic, 1_100)
    end
  end

  # 2026-08-10: a stale scenery presumption swallowed the only real enemy —
  # `enemies` (rows minus presumed scenery) read 0 while Combat held a live
  # lock, the clear debounce ran out, and the hunt strolled off mid-fight.
  # The count can lie; a held lock cannot: :tabbing/:fighting hold the road.
  describe "the fightable count can lie; an engaged Combat cannot" do
    test "walking with zero fightable rows but Combat engaged → fighting" do
      {l, :run_combat} = Logic.step(Logic.new(route(), @cfg), world({10, 10, 7}, 0, :fighting), 0)
      {l, :none} = Logic.step(l, world({10, 10, 7}, 0, :fighting), 10)
      assert l.state == :fighting
    end

    test ":tabbing counts as engaged — target acquisition holds the road too" do
      {l, :run_combat} = Logic.step(Logic.new(route(), @cfg), world({10, 10, 7}, 0, :tabbing), 0)
      {l, :none} = Logic.step(l, world({10, 10, 7}, 0, :tabbing), 10)
      assert l.state == :fighting
    end

    test "the clear debounce never starts while Combat is engaged" do
      l = %{Logic.new(route(), @cfg) | state: :fighting, combat_running?: true}

      {l, :none} = Logic.step(l, world({10, 10, 7}, 0, :fighting), 0)
      {l, :none} = Logic.step(l, world({10, 10, 7}, 0, :fighting), 900)
      assert l.state == :fighting

      # disengaged: NOW the debounce runs, and from zero
      {l, :none} = Logic.step(l, world({10, 10, 7}, 0, :hunting), 1_000)
      {l, :none} = Logic.step(l, world({10, 10, 7}, 0, :hunting), 1_700)
      assert l.state == :fighting

      {l, :none} = Logic.step(l, world({10, 10, 7}, 0, :hunting), 1_900)
      assert l.state == :post_fight
    end

    # engagement must never become a freeze: a Combat wedged in :fighting with
    # nothing changing on screen still hits the stall valve
    test "engaged forever with zero rows still stalls at the fight timeout" do
      l = %{Logic.new(route(), @cfg) | state: :fighting, combat_running?: true}

      {l, :none} = Logic.step(l, world({10, 10, 7}, 0, :fighting), 0)
      {l, :none} = Logic.step(l, world({10, 10, 7}, 0, :fighting), 20_010)
      assert l.state == :fight_stalled
    end
  end
end
