defmodule Pokex.Bots.Cavebot.MobadaRouteTest do
  @moduledoc """
  The route he recorded on 2026-08-11 to redo the Marill loop, exactly as it
  came off his hands — and what "otimizar" has to make of it.

  He said it came out strange, and it did: seventeen kill spots in 48
  waypoints, including a run of EIGHT in ten seconds and another of FIVE. They
  are not eight piles, they are eight middle clicks in one fight — he moves the
  pokémon around while it kills, and every click used to open a kill spot of
  its own, with its own sweep and its own revive.
  """
  use ExUnit.Case, async: false

  alias Pokex.Bots.Cavebot.{Recording, Route, Store}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    File.cp!("test/support/fixtures/rota_mobada.json", Path.join(tmp, "routes.json"))
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)
    :ok
  end

  defp recorded do
    [route] = Store.all()
    route
  end

  defp kill_spots(%Route{waypoints: waypoints}) do
    for {wp, index} <- Enum.with_index(waypoints),
        wp.action == :lure_end or :sweep in wp.stops or wp.park_point != nil,
        do: index
  end

  test "his recording really does carry runs of kill spots" do
    route = recorded()

    assert length(route.waypoints) == 48
    assert kill_spots(route) == [1, 7, 10, 12, 13, 14, 15, 16, 17, 18, 19, 33, 34, 35, 36, 37, 45]
  end

  describe "otimizar" do
    test "a run of clicks becomes ONE kill spot — the last, where the pile died" do
      {tidied, note} = Recording.tidy(recorded())

      # 12..19 was one fight; 33..37 another. What survives is the last of each
      assert kill_spots(tidied) == [1, 7, 10, 19, 37, 45]
      assert note =~ "juntei"

      # …and the survivor is the one his hands taught: the combo and the huddle
      # were recorded on it
      survivor = Enum.at(tidied.waypoints, 19)
      assert survivor.action == :lure_end
      assert survivor.park_point == {1215, 275}
      assert survivor.combo != []
      assert survivor.gather_ms
    end

    test "the WALK is untouched — only the marks change" do
      route = recorded()
      {tidied, _note} = Recording.tidy(route)

      places = fn %Route{waypoints: wps} -> Enum.map(wps, &{&1.x, &1.y, &1.z}) end

      assert places.(tidied) == places.(route)
    end

    test "every gathering now ends somewhere" do
      {tidied, _note} = Recording.tidy(recorded())

      assert Route.lure_issue(tidied) == nil

      # every "mobar daqui" has an "até aqui" after it, and no two kill spots
      # sit next to each other with no walk to gather on
      starts = for {wp, i} <- Enum.with_index(tidied.waypoints), wp.action == :lure_start, do: i
      ends = for {wp, i} <- Enum.with_index(tidied.waypoints), wp.action == :lure_end, do: i

      assert length(starts) == length(ends)
      assert Enum.all?(starts, fn start -> Enum.any?(ends, &(&1 > start)) end)
    end

    test "running it twice changes nothing the second time" do
      {once, _note} = Recording.tidy(recorded())
      {twice, note} = Recording.tidy(once)

      assert twice == once
      assert note =~ "já estavam certas"
    end
  end

  # "o Shift+1 é o modo de combate, quando uso ele quer dizer que sai do modo
  # mobado… dá pra usar isso pro save dos mapas!" (Lucas, 2026-08-11)
  describe "shift+1 marks the map" do
    test "it makes the waypoint a kill spot, with a gathering leading in" do
      {:ok, route} = Route.append(Route.new("cavena"), {100, 100, 7})
      {:ok, route} = Route.append(route, {110, 100, 7})
      {:ok, route} = Route.append(route, {120, 100, 7})

      {route, note} = Recording.mark_fight_start(route, 2)

      assert Enum.at(route.waypoints, 2).action == :lure_end
      assert :sweep in Enum.at(route.waypoints, 2).stops
      assert Enum.at(route.waypoints, 0).action == :lure_start
      assert note =~ "shift+1"
    end

    test "pressed twice in the same fight it marks once, quietly" do
      {:ok, route} = Route.append(Route.new("cavena"), {100, 100, 7})
      {:ok, route} = Route.append(route, {101, 100, 7})

      {route, _note} = Recording.mark_fight_start(route, 0)
      {route, note} = Recording.mark_fight_start(route, 1)

      assert kill_spots(route) == [0]
      assert note == nil
    end

    # The click that parks the pokémon lands in the middle of the same fight:
    # it moves the spot's point instead of opening a second one.
    test "the middle click after it belongs to the same spot" do
      {:ok, route} = Route.append(Route.new("cavena"), {100, 100, 7})
      {:ok, route} = Route.append(route, {102, 100, 7})

      {route, _note} = Recording.mark_fight_start(route, 0)
      {route, _note} = Recording.mark_park(route, 1, {1300, 650})

      assert kill_spots(route) == [0]
      assert Enum.at(route.waypoints, 0).park_point == {1300, 650}
    end
  end

  # "o shift+3 é o modo mobando" — the other half of the pair.
  describe "shift+3 says where the gathering starts again" do
    defp three_corners do
      {:ok, route} = Route.append(Route.new("cavena"), {100, 100, 7})
      {:ok, route} = Route.append(route, {110, 100, 7})
      {:ok, route} = Route.append(route, {120, 100, 7})
      route
    end

    # Pressed two corners past the kill spot: those two are where he kept
    # fighting, and only his hand knows it.
    test "a plain corner becomes 'mobar daqui'" do
      {route, _note} = Recording.mark_fight_start(three_corners(), 0)
      {route, note} = Recording.mark_gathering_start(route, 2)

      assert Enum.at(route.waypoints, 2).action == :lure_start
      assert note =~ "shift+3"
    end

    # Where he presses it most of the time: standing on the pile he just
    # killed. Marking here would erase the "até aqui" he just made.
    test "on the spot he just closed it says nothing" do
      {route, _note} = Recording.mark_fight_start(three_corners(), 2)
      {same, note} = Recording.mark_gathering_start(route, 2)

      assert same == route
      assert note == nil
      assert Enum.at(same.waypoints, 2).action == :lure_end
    end

    # And the inference stops guessing once he has said it: a "mobar daqui" of
    # his own inside the stretch is not doubled by one right after the spot.
    test "his mark wins over the inferred one" do
      {:ok, route} = Route.append(three_corners(), {130, 100, 7})
      {route, _note} = Recording.mark_fight_start(route, 0)
      {route, _note} = Recording.mark_gathering_start(route, 2)
      {route, _note} = Recording.mark_fight_start(route, 3)

      actions = Enum.map(route.waypoints, & &1.action)
      assert actions == [:lure_end, :walk, :lure_start, :lure_end]
    end
  end

  # The recorder itself, so the mess does not come back on the next recording.
  describe "the middle clicks of one fight" do
    test "a click next to a kill spot MOVES the pokémon instead of marking again" do
      {:ok, route} = Route.append(Route.new("cavena"), {100, 100, 7})
      {:ok, route} = Route.append(route, {101, 100, 7})

      {route, _note} = Recording.mark_park(route, 0, {1200, 600})
      {route, note} = Recording.mark_park(route, 1, {1300, 650})

      assert kill_spots(route) == [0]
      assert Enum.at(route.waypoints, 0).park_point == {1300, 650}
      assert note =~ "mesma matança"
    end

    test "a click far from the last one opens a new kill spot, as always" do
      {:ok, route} = Route.append(Route.new("cavena"), {100, 100, 7})
      {:ok, route} = Route.append(route, {104, 100, 7})
      {:ok, route} = Route.append(route, {120, 100, 7})

      {route, _note} = Recording.mark_park(route, 0, {1200, 600})
      {route, note} = Recording.mark_park(route, 2, {1300, 650})

      assert kill_spots(route) == [0, 2]
      assert note =~ "até aqui"
    end
  end
end
