defmodule Pokex.Bots.Cavebot.RouteTest do
  use ExUnit.Case, async: true
  alias Pokex.Bots.Cavebot.Route

  # The floor used to be PINNED here: the first waypoint fixed it and anything
  # else was {:error, :floor_mismatch}. Stairs made that wrong (2026-08-10) —
  # see route_floors_test for the rule that replaced it. The route's own `z`
  # outlived the pin as a label nobody read, and went on 2026-08-28.
  test "append records the waypoint on whatever floor it was walked on" do
    r = Route.new("cavena", "cavena-dg")
    assert {:ok, r} = Route.append(r, {100, 200, 7})
    assert {:ok, r} = Route.append(r, {101, 200, 7})
    assert length(r.waypoints) == 2

    assert {:ok, r} = Route.append(r, {101, 201, 6})
    assert Route.floors(r) == [6, 7]
  end

  test "validate requires waypoints" do
    assert {:error, :empty} = Route.validate(Route.new("x"))
    {:ok, r} = Route.append(Route.new("x"), {1, 1, 3})
    assert Route.validate(r) == :ok
  end

  # Both found in his real "Meganium and Venoss" (2026-08-15): twenty pairs the
  # hunt cannot walk between, and one staircase that goes up and comes right
  # back down onto the tile it left.
  describe "what a route asks that cannot be walked" do
    defp route_of(points) do
      Enum.reduce(points, Route.new("meganium"), fn {x, y, z}, route ->
        {:ok, r} = Route.append(route, {x, y, z})
        r
      end)
    end

    test "corners closer than the tolerance are named by index" do
      route = route_of([{2305, 30_014, 5}, {2304, 30_014, 5}, {2300, 30_014, 5}])

      assert Route.unwalkable_pairs(route, 1) == [0]
      assert Route.unwalkable_pairs(route, 0) == []
    end

    test "the diagonal neighbour counts, because the arrival check counts it" do
      route = route_of([{10, 10, 5}, {11, 11, 5}])

      assert Route.unwalkable_pairs(route, 1) == [0]
    end

    test "the same tile on ANOTHER floor is a staircase, not a repeat" do
      route = route_of([{10, 10, 5}, {10, 10, 6}])

      assert Route.unwalkable_pairs(route, 1) == []
    end

    test "up and straight back down onto the same tile is a round trip" do
      route =
        route_of([{2310, 30_021, 5}, {2310, 30_023, 6}, {2310, 30_021, 5}, {2308, 30_017, 5}])

      assert Route.stair_round_trips(route) == [0]
    end

    test "a climb that goes somewhere else is not a round trip" do
      route = route_of([{2310, 30_021, 5}, {2310, 30_023, 6}, {2315, 30_030, 5}])

      assert Route.stair_round_trips(route) == []
    end
  end
end
