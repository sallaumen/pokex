defmodule Pokex.Bots.Cavebot.RouteStairsTest do
  @moduledoc """
  Taking a staircase is ONE key that moves TWO tiles — the step and the tile
  past it — and changes floor. "se fui de um ponto X para um ponto Y à minha
  esquerda, a coordenada Y vai subir em 2 pontos, 1 bloco da escada e 1 bloco
  de depois da escada, com 1 passo só" (Lucas, 2026-08-12). He marks the corner
  right before and right after, so the pair describes the whole staircase and
  the step itself is the midpoint.
  """
  # async: false because "his real routes" puts :home_dir in the Application
  # env, which is global. Every other test file that moves :home_dir is
  # async: false for the same reason, and `layout_test.exs` carries the scar of
  # the exception: "CI fell back to a nonexistent ~/.pokex and read nil".
  use ExUnit.Case, async: false

  alias Pokex.Bots.Cavebot.{Route, Store}

  defp legs(coords) do
    Enum.reduce(coords, Route.new("r"), fn {x, y, z}, route ->
      {:ok, route} = Route.append(route, {x, y, z})
      route
    end).waypoints
  end

  describe "stair_leg/2 — the signature he described" do
    test "two tiles on one axis with a floor change is a stair, and gives the direction" do
      wps = legs([{2368, 30_030, 5}, {2368, 30_028, 6}])

      assert Route.stair_leg(wps, 0) == {:stair, 0, -1}
    end

    test "the way back down is the same leg, mirrored" do
      wps = legs([{2368, 30_028, 6}, {2368, 30_030, 5}])

      assert Route.stair_leg(wps, 0) == {:stair, 0, 1}
    end

    test "it reads on the x axis too" do
      wps = legs([{100, 50, 3}, {102, 50, 4}])

      assert Route.stair_leg(wps, 0) == {:stair, 1, 0}
    end

    # The route is a LOOP, so the closing leg is a real leg — his Azumaril
    # takes its stairs there.
    test "the closing leg of the loop counts" do
      wps = legs([{10, 10, 2}, {14, 10, 2}, {10, 12, 2}])
      wps = List.replace_at(wps, 0, %{Enum.at(wps, 0) | z: 3, x: 10, y: 10})

      assert Route.stair_leg(wps, 2) == {:stair, 0, -1}
    end

    test "same floor is never a stair, however far apart" do
      assert Route.stair_leg(legs([{10, 10, 5}, {10, 12, 5}]), 0) == nil
    end

    # These are the seven legs of his real routes where the marking has extra
    # walking folded in. They fall through to the ring search on purpose.
    test "a floor change that is not exactly two-and-zero is not a stair" do
      assert Route.stair_leg(legs([{10, 10, 5}, {10, 13, 6}]), 0) == nil
      assert Route.stair_leg(legs([{10, 10, 5}, {10, 14, 6}]), 0) == nil
      assert Route.stair_leg(legs([{10, 10, 5}, {9, 12, 6}]), 0) == nil
      assert Route.stair_leg(legs([{10, 10, 5}, {12, 13, 6}]), 0) == nil
      assert Route.stair_leg(legs([{10, 10, 5}, {12, 12, 6}]), 0) == nil
    end

    # A different reason for rejection than the test above: these DO sum to two,
    # so only the second half of the guard turns them away. A diagonal is one
    # key too, but it moves one tile on each axis instead of two on one — no
    # staircase in the game does that. None of his real routes happens to
    # contain a diagonal floor change, so no fixture can prove this half; all
    # four signs are that proof, since one sign alone would still pass a guard
    # that only rejected a single quadrant.
    test "a diagonal floor change is not a staircase, in any of the four quadrants" do
      assert Route.stair_leg(legs([{10, 10, 5}, {11, 11, 6}]), 0) == nil
      assert Route.stair_leg(legs([{10, 10, 5}, {11, 9, 6}]), 0) == nil
      assert Route.stair_leg(legs([{10, 10, 5}, {9, 11, 6}]), 0) == nil
      assert Route.stair_leg(legs([{10, 10, 5}, {9, 9, 6}]), 0) == nil
    end

    test "an index nobody has is not a stair" do
      assert Route.stair_leg(legs([{10, 10, 5}]), 9) == nil
      assert Route.stair_leg([], 0) == nil
    end
  end

  describe "stair_step/2 — where the step itself is" do
    test "the step is the midpoint of the pair" do
      wps = legs([{2368, 30_030, 5}, {2368, 30_028, 6}])

      assert Route.stair_step(wps, 0) == {2368, 30_029}
    end

    test "the x axis has a midpoint too, walking backwards along it" do
      wps = legs([{102, 50, 4}, {100, 50, 3}])

      assert Route.stair_step(wps, 0) == {101, 50}
    end

    test "a leg that is not a stair has no step to name" do
      assert Route.stair_step(legs([{10, 10, 5}, {10, 13, 6}]), 0) == nil
    end

    # Not decoration: the midpoint divides by the number of waypoints, and an
    # empty route would divide by zero if the stair question were not asked
    # first. An index nobody has answers nil here too, exactly as it does in
    # `stair_leg/2`.
    test "an index nobody has has no step either" do
      assert Route.stair_step(legs([{10, 10, 5}]), 9) == nil
      assert Route.stair_step([], 0) == nil
    end
  end

  # The real thing. These three files are his own routes, frozen.
  describe "his real routes" do
    setup %{tmp_dir: tmp} do
      Application.put_env(:pokex, :home_dir, tmp)
      on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)
      :ok
    end

    defp waypoints(fixture, tmp) do
      File.cp!("test/support/fixtures/#{fixture}", Path.join(tmp, "routes.json"))
      [route] = Store.all()
      route.waypoints
    end

    defp stair_legs(fixture, tmp) do
      route = %{waypoints: waypoints(fixture, tmp)}

      for index <- 0..(length(route.waypoints) - 1)//1,
          leg = Route.stair_leg(route.waypoints, index),
          leg != nil,
          do: {index, leg}
    end

    @tag :tmp_dir
    test "Meganium 1 has exactly the two clean stair legs", %{tmp_dir: tmp} do
      assert stair_legs("rota_meganium.json", tmp) == [{6, {:stair, 0, -1}}, {60, {:stair, 0, 1}}]
    end

    @tag :tmp_dir
    test "Xatu easy has four clean ones, and the four dirty ones stay out", %{tmp_dir: tmp} do
      assert stair_legs("rota_xatu.json", tmp) == [
               {21, {:stair, 0, -1}},
               {24, {:stair, 0, -1}},
               {26, {:stair, 0, 1}},
               {48, {:stair, 0, -1}}
             ]
    end

    @tag :tmp_dir
    test "Azumaril easy has only its closing leg", %{tmp_dir: tmp} do
      assert stair_legs("rota_azumaril.json", tmp) == [{47, {:stair, 0, 1}}]
    end

    # Read off `rota_meganium.json` by hand, not off the code: waypoint 6 is
    # {2368, 30_030, 5} and waypoint 7 is {2368, 30_028, 6}, so the staircase
    # he walks over is the tile between them — same x, y 30_029.
    @tag :tmp_dir
    test "the Meganium step is the tile between the two corners he marked", %{tmp_dir: tmp} do
      assert Route.stair_step(waypoints("rota_meganium.json", tmp), 6) == {2368, 30_029}
    end
  end
end
