defmodule Pokex.Bots.Cavebot.RouteTest do
  use ExUnit.Case, async: true
  alias Pokex.Bots.Cavebot.Route

  # The floor used to be PINNED here: the first waypoint fixed it and anything
  # else was {:error, :floor_mismatch}. Stairs made that wrong (2026-08-10) —
  # see route_floors_test for the rule that replaced it.
  test "append records the waypoint and remembers the floor it STARTED on" do
    r = Route.new("cavena", "cavena-dg")
    assert {:ok, r} = Route.append(r, {100, 200, 7})
    assert r.z == 7
    assert {:ok, r} = Route.append(r, {101, 200, 7})
    assert length(r.waypoints) == 2

    assert {:ok, r} = Route.append(r, {101, 201, 6})
    assert r.z == 7
    assert Route.floors(r) == [6, 7]
  end

  test "validate requires waypoints" do
    assert {:error, :empty} = Route.validate(Route.new("x"))
    {:ok, r} = Route.append(Route.new("x"), {1, 1, 3})
    assert Route.validate(r) == :ok
  end
end
