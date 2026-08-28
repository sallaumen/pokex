defmodule Pokex.Bots.Cavebot.RouteFloorsTest do
  @moduledoc """
  A route may climb stairs.

  Single-floor was a real invariant with a real reason — a character that
  changes floor unexpectedly (a hole, a teleport) is somewhere the route does
  not describe, and walking on would be walking blind. But it also refused the
  first honest thing Lucas tried to record with it: a hunt with stairs
  (2026-08-10, "mudou de andar — parei a gravação").

  The reason survives, narrowed: the floors the ROUTE KNOWS are expected, and
  any other floor is still the emergency it always was.
  """
  use ExUnit.Case, async: true

  alias Pokex.Bots.Cavebot.Route

  defp route_of(coords) do
    Enum.reduce(coords, Route.new("escada"), fn {x, y, z}, route ->
      {:ok, route} = Route.append(route, {x, y, z})
      route
    end)
  end

  describe "recording across floors" do
    test "a waypoint on another floor is APPENDED, not refused" do
      route = route_of([{0, 0, 7}, {5, 0, 7}, {5, 0, 6}, {9, 0, 6}])

      assert Enum.map(route.waypoints, & &1.z) == [7, 7, 6, 6]
    end

    test "floors/1 is the set of floors it visits, in order" do
      assert Route.floors(route_of([{0, 0, 7}, {5, 0, 6}, {9, 0, 7}])) == [6, 7]
      assert Route.floors(route_of([{0, 0, 7}])) == [7]
      assert Route.floors(Route.new("vazia")) == []
    end

    test "a route still needs at least one waypoint" do
      assert Route.validate(Route.new("vazia")) == {:error, :empty}
      assert Route.validate(route_of([{0, 0, 7}, {5, 0, 6}])) == :ok
    end

    test "clear/1 empties the route, and with it every floor it knew" do
      cleared = Route.clear(route_of([{0, 0, 7}, {5, 0, 6}]))

      assert cleared.waypoints == []
      assert Route.floors(cleared) == []
    end
  end

  describe "which leg climbs" do
    test "a leg between floors is marked; the others are not" do
      waypoints = route_of([{0, 0, 7}, {5, 0, 7}, {5, 0, 6}, {9, 0, 6}]).waypoints

      refute Route.floor_change(waypoints, 0)
      assert Route.floor_change(waypoints, 1) == 6
      refute Route.floor_change(waypoints, 2)
    end

    test "the closing leg counts: a loop that goes up must come back down" do
      waypoints = route_of([{0, 0, 7}, {5, 0, 6}]).waypoints

      # leg 1 → 0 closes the loop, back down to 7
      assert Route.floor_change(waypoints, 1) == 7
    end

    test "a single-floor route changes floor nowhere" do
      waypoints = route_of([{0, 0, 7}, {5, 0, 7}, {9, 9, 7}]).waypoints

      assert Enum.all?(0..2, &(Route.floor_change(waypoints, &1) == nil))
    end
  end
end
