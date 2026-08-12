defmodule Pokex.Bots.Cavebot.RouteActionTest do
  @moduledoc """
  A waypoint stopped being only a place: it can carry a JOB. "Mobar daqui" and
  "até aqui" (Lucas, 2026-08-10) mark a stretch of the route that is walked
  gathering mobs instead of fighting them.

  The route is a LOOP, so the stretch is read around the cycle — which is the
  whole reason this lives in a pure function with its own tests instead of
  inside a `for` in the template.
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

  defp lure_legs(%Route{waypoints: waypoints}) do
    waypoints
    |> Enum.with_index()
    |> Enum.filter(fn {_wp, index} -> Route.lure_leg?(waypoints, index) end)
    |> Enum.map(fn {_wp, index} -> index end)
  end

  describe "the job a waypoint carries" do
    test "a recorded waypoint just walks" do
      assert [%{action: :walk} | _rest] = square().waypoints
    end

    test "set_action/3 writes the job, and only on that waypoint" do
      route = Route.set_action(square(), 1, :lure_start)

      assert Enum.map(route.waypoints, & &1.action) == [:walk, :lure_start, :walk, :walk]
    end

    test "an unknown job, or an index nobody has, leaves the route untouched" do
      route = square()

      assert Route.set_action(route, 1, :teleport) == route
      assert Route.set_action(route, 9, :lure_start) == route
    end
  end

  describe "which legs are walked luring" do
    # The leg LEAVING a waypoint is the one that carries its job: arriving at
    # "mobar daqui" is what starts the gathering, and arriving at "até aqui"
    # is what ends it — so the leg out of the end waypoint is a normal leg.
    test "the stretch runs from the start waypoint up to the end waypoint" do
      route =
        square()
        |> Route.set_action(1, :lure_start)
        |> Route.set_action(3, :lure_end)

      assert lure_legs(route) == [1, 2]
    end

    test "a plain route lures nowhere" do
      assert lure_legs(square()) == []
    end

    test "the stretch wraps around the loop, because the route IS a loop" do
      route =
        square()
        |> Route.set_action(3, :lure_start)
        |> Route.set_action(1, :lure_end)

      # 3 → 0 (the closing leg) → 1, and then back to normal
      assert lure_legs(route) == [0, 3]
    end

    test "two stretches in one route are two stretches" do
      route =
        route_of([{0, 0}, {1, 0}, {2, 0}, {3, 0}, {4, 0}, {5, 0}])
        |> Route.set_action(0, :lure_start)
        |> Route.set_action(1, :lure_end)
        |> Route.set_action(3, :lure_start)
        |> Route.set_action(4, :lure_end)

      assert lure_legs(route) == [0, 3]
    end

    # An unfinished mark is a real footgun for the hunt that will obey it: with
    # no end, the gathering never stops and the character walks the whole route
    # refusing to fight. The drawing shows it (everything blue) and the editor
    # says it in words — see lure_issue/1.
    test "a start with no end lures the whole loop" do
      route = Route.set_action(square(), 2, :lure_start)

      assert lure_legs(route) == [0, 1, 2, 3]
    end
  end

  # "depois que matar tudo, fazer aquela varredura de captura antes de andar"
  # (Lucas, 2026-08-10). Sweeping is a SECOND axis, not another job: the
  # waypoint where the gathered pile dies is exactly the one worth sweeping,
  # and it is already carrying "até aqui".
  describe "what the hunt does when it stops there" do
    test "a recorded waypoint does nothing beyond arriving" do
      assert [%{stops: []} | _rest] = square().waypoints
    end

    test "set_stop/4 turns one on, and only on that waypoint" do
      route = Route.set_stop(square(), 2, :sweep, true)

      assert Enum.map(route.waypoints, & &1.stops) == [[], [], [:sweep], []]
      assert Route.set_stop(route, 2, :sweep, false).waypoints |> Enum.all?(&(&1.stops == []))
    end

    # The order is the RUNNING order, not the clicking order: the revive is
    # instant and resets the bar, the sweep spends time usefully, and the
    # plain wait is the last resort.
    test "stops are kept in the order they run, however they were marked" do
      route =
        square()
        |> Route.set_stop(1, :wait, true)
        |> Route.set_stop(1, :sweep, true)
        |> Route.set_stop(1, :cooldown_revive, true)

      assert Route.stops_at(route.waypoints, 1) == [:cooldown_revive, :sweep, :wait]
    end

    test "turning one on twice does not double it" do
      route = square() |> Route.set_stop(1, :sweep, true) |> Route.set_stop(1, :sweep, true)

      assert Route.stops_at(route.waypoints, 1) == [:sweep]
    end

    test "an index nobody has, or an action nobody knows, changes nothing" do
      route = square()

      assert Route.set_stop(route, 9, :sweep, true) == route
      assert Route.set_stop(route, 1, :teleport, true) == route
    end

    test "a waypoint can gather AND sweep AND revive — they do not compete" do
      route =
        square()
        |> Route.set_action(3, :lure_end)
        |> Route.set_stop(3, :sweep, true)
        |> Route.set_stop(3, :cooldown_revive, true)

      assert %{action: :lure_end, stops: [:cooldown_revive, :sweep]} = Enum.at(route.waypoints, 3)
    end

    test "stops_at/2 answers for the waypoint the hunt just reached" do
      waypoints = Route.set_stop(square(), 2, :sweep, true).waypoints

      assert Route.stops_at(waypoints, 2) == [:sweep]
      assert Route.stops_at(waypoints, 1) == []
      assert Route.stops_at(waypoints, 99) == []
    end
  end

  describe "an unfinished mark says so" do
    test "a paired stretch is quiet" do
      route =
        square()
        |> Route.set_action(1, :lure_start)
        |> Route.set_action(3, :lure_end)

      assert Route.lure_issue(route) == nil
      assert Route.lure_issue(square()) == nil
    end

    test "a start with no end at all is the one that breaks the hunt" do
      assert Route.lure_issue(Route.set_action(square(), 1, :lure_start)) == :start_without_end
    end

    # An extra "até aqui" costs nothing: it just marks another kill spot,
    # which is exactly what it is. Crying wolf about it taught him to ignore
    # the warning that DOES matter.
    test "an end with no start is not a problem" do
      assert Route.lure_issue(Route.set_action(square(), 1, :lure_end)) == nil
    end

    test "two gatherings closing on one end are both closed" do
      route =
        square()
        |> Route.set_action(0, :lure_start)
        |> Route.set_action(1, :lure_start)
        |> Route.set_action(2, :lure_end)

      assert Route.lure_issue(route) == nil
    end
  end

  describe "skills — the waypoint's third axis" do
    setup do
      {:ok, route} = Route.append(Route.new("meganium"), {10, 10, 5})
      {:ok, route} = Route.append(route, {12, 10, 5})
      %{route: route}
    end

    test "is born carrying none", %{route: route} do
      assert Route.skills_at(route.waypoints, 0) == []
    end

    test "turns a category on and off", %{route: route} do
      route = Route.set_skill(route, 0, :buffs, true)
      assert Route.skills_at(route.waypoints, 0) == [:buffs]

      route = Route.set_skill(route, 0, :buffs, false)
      assert Route.skills_at(route.waypoints, 0) == []
    end

    # The order is the canonical one, not the clicking one: two routes with the
    # same skills have to produce the same key sequence.
    test "keeps the canonical order, not the clicking order", %{route: route} do
      route =
        route
        |> Route.set_skill(0, :single, true)
        |> Route.set_skill(0, :buffs, true)

      assert Route.skills_at(route.waypoints, 0) == [:buffs, :single]
    end

    test "turning one on twice does not double it", %{route: route} do
      route = route |> Route.set_skill(0, :buffs, true) |> Route.set_skill(0, :buffs, true)
      assert Route.skills_at(route.waypoints, 0) == [:buffs]
    end

    test "does not leak into the neighbouring waypoint", %{route: route} do
      route = Route.set_skill(route, 0, :buffs, true)
      assert Route.skills_at(route.waypoints, 1) == []
    end

    # Same rule as set_stop: a control that cannot act is a no-op, never an error.
    test "an index nobody has, or a category nobody knows, changes nothing", %{route: route} do
      assert Route.set_skill(route, 99, :buffs, true) == route
      assert Route.set_skill(route, 0, :nadar, true) == route
      assert Route.skills_at(route.waypoints, 99) == []
    end
  end

  describe "gather_wait/3 — the huddle ruler" do
    setup do
      {:ok, route} = Route.append(Route.new("meganium"), {10, 10, 5})
      %{route: route, wp: hd(route.waypoints)}
    end

    test "with nothing written down, the global number rules", %{route: route, wp: wp} do
      assert Route.gather_wait(route, wp, 4_000) == 4_000
    end

    test "the route's own ruler beats the global one", %{route: route, wp: wp} do
      route = Route.set_gather_wait(route, 1_800)
      assert Route.gather_wait(route, wp, 4_000) == 1_800
    end

    test "the waypoint beats the route's ruler", %{route: route} do
      route = route |> Route.set_gather_wait(1_800) |> Route.set_gather_wait(0, 600)
      assert Route.gather_wait(route, hd(route.waypoints), 4_000) == 600
    end

    # Zero is a legitimate answer — "wait for nothing here" — and must not fall
    # through to the next level.
    test "zero is obeyed, it is not absence", %{route: route} do
      route = route |> Route.set_gather_wait(1_800) |> Route.set_gather_wait(0, 0)
      assert Route.gather_wait(route, hd(route.waypoints), 4_000) == 0
    end

    test "erasing hands the answer back to the level above", %{route: route} do
      route =
        route
        |> Route.set_gather_wait(1_800)
        |> Route.set_gather_wait(0, 600)
        |> Route.set_gather_wait(0, nil)

      assert Route.gather_wait(route, hd(route.waypoints), 4_000) == 1_800
    end

    # What his hands measured stays stored and stays NOT in charge.
    test "the measured gather_ms does not enter the sum", %{route: route} do
      route = Route.set_timing(route, 0, gather_ms: 4_534)
      assert Route.gather_wait(route, hd(route.waypoints), 1_000) == 1_000
    end
  end
end
