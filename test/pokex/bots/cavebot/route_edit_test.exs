defmodule Pokex.Bots.Cavebot.RouteEditTest do
  @moduledoc """
  Editing a recorded route. Until now the only edit was DELETION: a corner
  marked in the wrong order, or one missing in the middle, meant walking the
  whole route again.
  """
  use ExUnit.Case, async: true

  alias Pokex.Bots.Cavebot.Route

  defp route_of(coords) do
    Enum.reduce(coords, Route.new("r"), fn {x, y}, route ->
      {:ok, route} = Route.append(route, {x, y, 7})
      route
    end)
  end

  defp coords(%Route{waypoints: waypoints}), do: Enum.map(waypoints, &{&1.x, &1.y})

  test "move/3 swaps a waypoint with its neighbour, both ways" do
    route = route_of([{1, 1}, {2, 2}, {3, 3}])

    assert coords(Route.move(route, 1, :up)) == [{2, 2}, {1, 1}, {3, 3}]
    assert coords(Route.move(route, 1, :down)) == [{1, 1}, {3, 3}, {2, 2}]
  end

  test "a move off either end leaves the route untouched — the button is a no-op" do
    route = route_of([{1, 1}, {2, 2}])

    assert Route.move(route, 0, :up) == route
    assert Route.move(route, 1, :down) == route
    assert Route.move(route, 9, :up) == route
  end

  test "insert_at/3 pushes the rest down, on this floor or another" do
    route = route_of([{1, 1}, {3, 3}])

    assert {:ok, inserted} = Route.insert_at(route, 1, {2, 2, 7})
    assert coords(inserted) == [{1, 1}, {2, 2}, {3, 3}]

    # the missing corner may be up the stairs — see route_floors_test
    assert {:ok, upstairs} = Route.insert_at(route, 1, {2, 2, 8})
    assert Route.floors(upstairs) == [7, 8]
  end

  test "an insert past the end lands at the end, never dropped" do
    route = route_of([{1, 1}])

    assert {:ok, inserted} = Route.insert_at(route, 9, {2, 2, 7})
    assert coords(inserted) == [{1, 1}, {2, 2}]
  end

  test "clear/1 empties the waypoints AND the floor" do
    cleared = Route.clear(route_of([{1, 1}, {2, 2}]))

    assert cleared.waypoints == []
    assert cleared.z == nil
    assert cleared.name == "r"
  end
end
