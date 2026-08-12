defmodule Pokex.Bots.Cavebot.MeganiumRouteTest do
  @moduledoc """
  The route he recorded on 2026-08-12 and said he was going to use for real.

  It is here because no invented test had imagined the shape it has: half of
  its fights close one or two tiles PAST the "até aqui". He kills the pile,
  takes a step, and only then presses the shift+3 that closes the fight — so
  the lesson (`fight_ms`, `gather_ms`, combo) landed on the tile he happened to
  be standing on, and the hunt reads it only from the kill spot.
  """
  use ExUnit.Case, async: false

  alias Pokex.Bots.Cavebot.{Recording, Store}

  @moduletag :tmp_dir

  @kill_spots [4, 14, 23, 30, 38, 51, 57, 66]
  @orphan_fights %{5 => 4, 15 => 14, 39 => 38, 59 => 57}
  # the corners where he presses his AURA while walking: a combo with no fight
  @aura_corners [1, 9, 22, 35]

  setup %{tmp_dir: tmp} do
    File.cp!("test/support/fixtures/rota_meganium.json", Path.join(tmp, "routes.json"))
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

    [route] = Store.all()
    %{route: route}
  end

  test "his recording has 8 kill spots and only 4 with the lesson in place", %{route: route} do
    kills = for {wp, i} <- Enum.with_index(route.waypoints), wp.action == :lure_end, do: i
    assert kills == @kill_spots

    with_lesson = for {wp, i} <- Enum.with_index(route.waypoints), wp.fight_ms, do: i
    assert Enum.filter(with_lesson, &(&1 in @kill_spots)) == [23, 30, 51, 66]
  end

  test "otimizar gives the 8 lessons back to the 8 kill spots", %{route: route} do
    {tidied, _note} = Recording.tidy(route)

    for kill <- @kill_spots do
      wp = Enum.at(tidied.waypoints, kill)
      assert wp.fight_ms, "o ponto de matança #{kill} ficou sem a lição da luta"
      assert wp.combo != [], "o ponto de matança #{kill} ficou sem combo"
    end

    for {orphan, _kill} <- @orphan_fights do
      wp = Enum.at(tidied.waypoints, orphan)
      assert wp.fight_ms == nil, "o waypoint #{orphan} continuou com a lição"
      assert wp.combo == []
    end
  end

  test "the lesson goes to the RIGHT kill spot, huddle and all", %{route: route} do
    {tidied, _note} = Recording.tidy(route)

    # waypoint 5 measured 11310ms of fight and 1851ms of huddle; they belong to 4
    assert Enum.at(tidied.waypoints, 4).fight_ms == 11_310
    assert Enum.at(tidied.waypoints, 4).gather_ms == 1_851
    assert Enum.at(tidied.waypoints, 14).fight_ms == 14_469
    assert Enum.at(tidied.waypoints, 38).fight_ms == 12_213
    assert Enum.at(tidied.waypoints, 57).fight_ms == 8_528
  end

  # The aura he presses WHILE WALKING is not a fight lesson and must not be
  # gathered into a kill spot — it is the whole signal this feature exists to
  # read.
  test "the combo pressed on the walk stays where it is", %{route: route} do
    {tidied, _note} = Recording.tidy(route)

    for corner <- @aura_corners do
      wp = Enum.at(tidied.waypoints, corner)
      assert wp.combo != [], "a aura do waypoint #{corner} foi movida"
      assert wp.fight_ms == nil
    end
  end

  test "otimizar moves no corner out of place", %{route: route} do
    {tidied, _note} = Recording.tidy(route)

    assert Enum.map(tidied.waypoints, &{&1.x, &1.y, &1.z}) ==
             Enum.map(route.waypoints, &{&1.x, &1.y, &1.z})
  end

  # Running it twice must not keep shuffling: whoever is already in place stays.
  test "otimizar is idempotent", %{route: route} do
    {once, _} = Recording.tidy(route)
    {twice, _} = Recording.tidy(once)

    assert twice.waypoints == once.waypoints
  end
end
