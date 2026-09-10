defmodule Pokex.Bots.Cavebot.RouteActionTest do
  @moduledoc """
  What a waypoint carries besides its place.

  It used to carry a JOB too — "mobar daqui" … "até aqui" — and the hunt read
  those marks to decide whether a monster on screen was worth stopping for.
  That decision moved to the brain, which counts what is actually around him,
  so the waypoint is a PLACE and a list of STOPS and nothing else.
  """
  use ExUnit.Case, async: true

  alias Pokex.Bots.Cavebot.Route

  defp route_of(coords) do
    Enum.reduce(coords, Route.new("r"), fn {x, y}, route ->
      {:ok, route} = Route.append(route, {x, y, 7})
      route
    end)
  end

  defp square, do: route_of([{0, 0}, {4, 0}, {4, 4}, {0, 4}])

  describe "what the hunt does when it stops there" do
    test "a recorded waypoint does nothing beyond arriving" do
      assert [%{stops: []} | _rest] = square().waypoints
    end

    test "set_stop/4 turns one on, and only on that waypoint" do
      route = Route.set_stop(square(), 2, :wait, true)

      assert Enum.map(route.waypoints, & &1.stops) == [[], [], [:wait], []]
      assert Route.set_stop(route, 2, :wait, false).waypoints |> Enum.all?(&(&1.stops == []))
    end

    # The order is the RUNNING order, not the clicking order: the revive is
    # instant and resets the bar, and the plain wait is the last resort.
    test "stops are kept in the order they run, however they were marked" do
      route =
        square()
        |> Route.set_stop(1, :wait, true)
        |> Route.set_stop(1, :cooldown_revive, true)

      assert Route.stops_at(route.waypoints, 1) == [:cooldown_revive, :wait]
    end

    test "turning one on twice does not double it" do
      route = square() |> Route.set_stop(1, :wait, true) |> Route.set_stop(1, :wait, true)

      assert Route.stops_at(route.waypoints, 1) == [:wait]
    end

    # `:sweep` is in the second list on purpose: it WAS a stop until
    # 2026-08-28, and a route saved back then still names it.
    test "an index nobody has, or an action nobody knows, changes nothing" do
      route = square()

      assert Route.set_stop(route, 9, :wait, true) == route
      assert Route.set_stop(route, 1, :teleport, true) == route
      assert Route.set_stop(route, 1, :sweep, true) == route
    end

    test "a waypoint can wait AND revive — they do not compete" do
      route =
        square()
        |> Route.set_stop(3, :wait, true)
        |> Route.set_stop(3, :cooldown_revive, true)

      assert %{stops: [:cooldown_revive, :wait]} = Enum.at(route.waypoints, 3)
    end

    test "stops_at/2 answers for the waypoint the hunt just reached" do
      waypoints = Route.set_stop(square(), 2, :wait, true).waypoints

      assert Route.stops_at(waypoints, 2) == [:wait]
      assert Route.stops_at(waypoints, 1) == []
      assert Route.stops_at(waypoints, 99) == []
    end
  end

  # A waypoint written before these fields existed carries neither key.
  describe "a waypoint recorded before these fields existed" do
    test "set_stop/4 survives a waypoint missing even the key it toggles" do
      route = square()
      route = %{route | waypoints: Enum.map(route.waypoints, &Map.delete(&1, :stops))}
      route = Route.set_stop(route, 0, :wait, true)

      assert Route.stops_at(route.waypoints, 0) == [:wait]
    end
  end
end
