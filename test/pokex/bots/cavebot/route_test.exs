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

  # "Talvez até uma distância do meu personagem, algo assim mais fácil de eu
  # poder medir" (Lucas, 2026-08-11): the park spot said in tiles instead of in
  # screen points, which is the only form that survives the window moving.
  describe "where the pokémon is parked" do
    defp kill_spot do
      {:ok, r} = Route.append(Route.new("cavena"), {100, 200, 7})
      Route.set_action(r, 0, :lure_end)
    end

    test "his recorded click is a point; his correction is a distance" do
      recorded = Route.set_park_point(kill_spot(), 0, {2490, 417})
      assert Route.park_spot(hd(recorded.waypoints)) == {:point, {2490, 417}}

      corrected = Route.set_park_tiles(recorded, 0, {6, -2})
      assert Route.park_spot(hd(corrected.waypoints)) == {:tiles, {6, -2}}
    end

    # Two answers to one question: the newer one is the whole answer, and a
    # waypoint carrying both would need a rule nobody can see.
    test "correcting the distance forgets the recorded point" do
      route =
        kill_spot()
        |> Route.set_park_point(0, {2490, 417})
        |> Route.set_park_tiles(0, {6, -2})

      assert hd(route.waypoints).park_point == nil
    end

    test "clearing it takes the waypoint back to having no spot" do
      route = kill_spot() |> Route.set_park_tiles(0, {6, -2}) |> Route.set_park_tiles(0, nil)

      assert Route.park_spot(hd(route.waypoints)) == nil
    end

    test "the hunt's default only speaks where the waypoint says nothing" do
      plain = hd(kill_spot().waypoints)
      assert Route.park_spot(plain, {-3, 1}) == {:tiles, {-3, 1}}

      # …and 0,0 is "on top of me", which means don't send it anywhere
      assert Route.park_spot(plain, {0, 0}) == nil

      own = hd(Route.set_park_tiles(kill_spot(), 0, {6, -2}).waypoints)
      assert Route.park_spot(own, {-3, 1}) == {:tiles, {6, -2}}
    end
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
      route = route_of([{2305, 30014, 5}, {2304, 30014, 5}, {2300, 30014, 5}])

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
      route = route_of([{2310, 30021, 5}, {2310, 30023, 6}, {2310, 30021, 5}, {2308, 30017, 5}])

      assert Route.stair_round_trips(route) == [0]
    end

    test "a climb that goes somewhere else is not a round trip" do
      route = route_of([{2310, 30021, 5}, {2310, 30023, 6}, {2315, 30030, 5}])

      assert Route.stair_round_trips(route) == []
    end
  end
end
