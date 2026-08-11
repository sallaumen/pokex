defmodule Pokex.Bots.Cavebot.RealRouteTest do
  @moduledoc """
  His actual recorded route, walked end to end.

  Every other test in this folder feeds the machine shapes I invented, and
  twice today reality had a shape I had not: the dwell that never arrives
  because the coordinate stops being drawn, the two routes armed at once. So
  this one drives the REAL file — 45 waypoints across two floors, five park
  points, five sweeps, five recorded combos — and asks the only question that
  matters before he runs it: does the hunt get all the way round?

  The fixture is a copy of `~/.pokex/routes.json`'s "Azumaril easy", taken
  2026-08-11. It is data, not a mock: when the recorder changes shape, this
  test keeps walking the OLD shape, which is exactly what his saved routes
  will do.
  """
  use ExUnit.Case, async: false

  alias Pokex.Bots.Cavebot.{Logic, Route, Store}

  @moduletag :tmp_dir

  @cfg %{
    stair_probe_ms: 450,
    stair_max_probes: 32,
    arrival_tolerance: 1,
    walk_timeout_ms: 3_000,
    stuck_max_retries: 4,
    clear_debounce_ms: 800,
    fight_timeout_ms: 20_000,
    post_kill_dwell_ms: 1_200,
    blind_kick_ms: 1_200,
    capture_wait_ms: 20_000,
    sweep_grace_ms: 1_500,
    stop_wait_ms: 5_000,
    gather_wait_ms: 4_000,
    gather_wait_min_ms: 500,
    gather_wait_max_ms: 8_000
  }

  setup %{tmp_dir: tmp} do
    File.cp!("test/support/fixtures/rota_real.json", Path.join(tmp, "routes.json"))
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)
    :ok
  end

  defp real_route do
    [route] = Store.all()
    route
  end

  # Walks the character one tile toward whatever the machine is asking for,
  # ticking as it goes — the cheapest possible stand-in for the game, and
  # enough to prove the machine keeps making progress on real data.
  defp walk_lap(logic, pos, steps) do
    Enum.reduce_while(1..steps, {logic, pos, []}, fn step, {logic, pos, seen} ->
      now = step * 200
      {logic, action} = Logic.step(logic, world(pos, logic), now)

      case action do
        {:block, reason} ->
          {:halt, {:blocked, reason, logic.wp_index}}

        _other ->
          {:cont, {logic, advance(pos, logic), [logic.wp_index | seen]}}
      end
    end)
  end

  defp world(pos, logic) do
    %{
      pos: pos,
      enemies: 0,
      combat_state: :hunting,
      capture_pending: 0,
      capture_changed_at: nil,
      sweep_pending: 0,
      sweep_changed_at: nil,
      logic: logic
    }
  end

  # One tile closer to the current target, floor included: stepping onto the
  # stairs is what changes z, and the machine refuses to "arrive" from below.
  defp advance({x, y, z}, logic) do
    wp = Enum.at(logic.route.waypoints, logic.wp_index)

    cond do
      wp == nil -> {x, y, z}
      x != wp.x -> {x + sign(wp.x - x), y, z}
      y != wp.y -> {x, y + sign(wp.y - y), z}
      true -> {x, y, wp.z}
    end
  end

  # The same walk against a HARSHER world: the character only changes floor by
  # stepping on a real staircase tile, and the one on the way down from
  # waypoint 14 sits one tile WEST of the corner the recording kept — exactly
  # the "escada fininha" his route could not take (2026-08-11). Nothing else
  # moves him between floors.
  # `seen` is what the machine claimed AND where the character stood when it
  # claimed it: `{waypoint it just left, position at that moment}`. A skipped
  # corner and a reached one are indistinguishable by index alone — that is
  # exactly how his hunt "advanced" two waypoints of floor 2 from floor 1.
  defp walk_lap_with_stairs(logic, pos, steps, stairs) do
    Enum.reduce_while(1..steps, {logic, pos, []}, fn step, {logic, pos, seen} ->
      now = step * 500
      was = logic.wp_index
      {logic, action} = Logic.step(logic, world(pos, logic), now)
      seen = if logic.wp_index == was, do: seen, else: [{was, pos} | seen]

      case action do
        {:block, reason} -> {:halt, {:blocked, reason, logic.wp_index, pos}}
        _other -> {:cont, {logic, step_world(pos, logic, action, stairs), seen}}
      end
    end)
  end

  # The character moves ONE tile toward whatever was asked; the floor changes
  # only when the tile he lands on is a staircase.
  defp step_world({x, y, z} = pos, logic, action, stairs) do
    {dx, dy} =
      case action do
        {:walk, ax, ay} -> {sign(ax), sign(ay)}
        {:nudge, ax, ay} -> {sign(ax), sign(ay)}
        _standing_still -> {0, 0}
      end

    landed = {x + dx, y + dy, z}

    cond do
      {dx, dy} == {0, 0} -> pos
      blocked?(landed, logic) -> pos
      true -> Map.get(stairs, landed, landed)
    end
  end

  # Everything more than a tile off the straight line between the corner he
  # left and the one he is heading for is scenery — the walls beside a thin
  # staircase, which is what makes the search a search.
  defp blocked?({x, y, z}, logic) do
    count = length(logic.route.waypoints)
    wp = Enum.at(logic.route.waypoints, logic.wp_index)
    from = Enum.at(logic.route.waypoints, Integer.mod(logic.wp_index - 1, count))

    z == from.z and z == wp.z and
      (x < min(wp.x, from.x) - 1 or x > max(wp.x, from.x) + 1 or
         y < min(wp.y, from.y) - 1 or y > max(wp.y, from.y) + 1)
  end

  defp sign(0), do: 0
  defp sign(n) when n > 0, do: 1
  defp sign(_n), do: -1

  test "his real route loads with everything his hands put in it" do
    route = real_route()

    assert length(route.waypoints) == 45
    assert Route.floors(route) == [1, 2]
    assert Enum.count(route.waypoints, & &1.park_point) == 5
    assert Enum.count(route.waypoints, &(:sweep in &1.stops)) == 5
    assert Enum.any?(route.waypoints, &(&1.action == :lure_start))
    assert Enum.any?(route.waypoints, &(&1.action == :lure_end))
  end

  # The whole point: a lap, on his data, without blocking.
  test "the hunt walks a full lap of it and comes back to the start" do
    route = real_route()
    first = hd(route.waypoints)
    logic = %{Logic.new(route, @cfg) | combat_running?: true, homed?: true}

    result = walk_lap(logic, {first.x, first.y, first.z}, 4_000)

    assert {logic, _pos, seen} = result, "a caçada bloqueou: #{inspect(result)}"

    # every waypoint was the target at some point — no corner skipped, none
    # visited twice in a row because it never advanced
    assert Enum.uniq(seen) |> length() == 45
    assert logic.state in [:walking, :post_fight]
  end

  test "it climbs and comes back down without ever blocking on a floor" do
    route = real_route()
    upstairs = Enum.find(route.waypoints, &(&1.z == 2))
    logic = %{Logic.new(route, @cfg) | combat_running?: true, homed?: true}

    result = walk_lap(logic, {upstairs.x, upstairs.y, upstairs.z}, 4_000)

    refute match?({:blocked, _reason, _index}, result)
  end

  # The measurement his own recording made at waypoint 3 is 12 seconds, three
  # times the others. Obeyed, the hunt would stand there holding fire while
  # the pile eats it — so the route itself is the regression test.
  test "the twelve-second measurement in his route is NOT obeyed" do
    route = real_route()
    wild = Enum.find(route.waypoints, &((&1[:gather_ms] || 0) > @cfg.gather_wait_max_ms))

    assert wild, "a rota real não tem mais a medição absurda — atualize a fixture"

    index = Enum.find_index(route.waypoints, &(&1 == wild))

    logic = %{
      Logic.new(route, @cfg)
      | combat_running?: true,
        homed?: true,
        wp_index: index,
        last_pos: {wild.x - 1, wild.y, wild.z}
    }

    {logic, _action} = Logic.step(logic, world({wild.x, wild.y, wild.z}, logic), 1_000)

    # the configured 4s, not the measured 12s
    assert Logic.gathering?(logic, 4_500)
    refute Logic.gathering?(logic, 5_200)
  end

  # THE staircase of 2026-08-11: waypoint 15 of his route is on floor 2, and
  # the step down from waypoint 14 is not on the tile the recording kept.
  describe "his four staircases, each one tile off the recorded corner" do
    # Every leg of the route that changes floor, with its step ONE TILE WEST of
    # the corner the recording kept — the "escada fininha" shape: walking to
    # the recorded tile is not taking the stairs.
    defp offset_stairs(route) do
      waypoints = route.waypoints
      count = length(waypoints)

      for index <- 0..(count - 1),
          from = Enum.at(waypoints, index),
          to = Enum.at(waypoints, rem(index + 1, count)),
          from.z != to.z,
          into: %{},
          do: {{to.x - 1, to.y, from.z}, {to.x, to.y, to.z}}
    end

    test "a full lap still happens: the hunt finds every step" do
      route = real_route()
      first = hd(route.waypoints)
      logic = %{Logic.new(route, @cfg) | combat_running?: true, homed?: true}

      result =
        walk_lap_with_stairs(
          logic,
          {first.x, first.y, first.z},
          3_000,
          offset_stairs(route)
        )

      assert {logic, _pos, seen} = result, "a caçada bloqueou: #{inspect(result)}"
      assert length(Enum.uniq(Enum.map(seen, &elem(&1, 0)))) == 45
      assert logic.state in [:walking, :post_fight, :stairs]

      # …and every one of them was REACHED, floor included: the corner it left
      # behind is a corner the character was actually standing on.
      wrong =
        Enum.reject(seen, fn {index, {_x, _y, z}} ->
          Enum.at(route.waypoints, index).z == z
        end)

      assert wrong == [], "waypoints dados como feitos de outro andar: #{inspect(wrong)}"
    end

    test "with no step to find it stops with a name — it does NOT walk on" do
      route = real_route()
      waypoints = route.waypoints
      index = Enum.find_index(waypoints, &(&1.z != hd(waypoints).z))
      from = Enum.at(waypoints, index - 1)
      logic = %{Logic.new(route, @cfg) | combat_running?: true, homed?: true, wp_index: index}

      result = walk_lap_with_stairs(logic, {from.x, from.y, from.z}, 200, %{})

      assert {:blocked, :stairs, ^index, {_x, _y, z}} = result
      assert z == from.z, "parou, mas já estava no outro andar"
    end
  end

  # A floor the route never visits is still the emergency it always was —
  # proven here against the real one, not a two-waypoint toy.
  test "a floor his route never visits still blocks" do
    logic = %{Logic.new(real_route(), @cfg) | combat_running?: true, homed?: true}

    assert {_logic, {:block, :floor_changed}} = Logic.step(logic, world({100, 100, 7}, logic), 0)
  end
end
