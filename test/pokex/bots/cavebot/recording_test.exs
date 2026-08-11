defmodule Pokex.Bots.Cavebot.RecordingTest do
  @moduledoc """
  Reading what he was DOING from how long he stood still.

  "Aqui ele só marcou ponto rápido, então ele só tá andando, e aqui ele ficou
  um tempão nesse ponto, então ele tá matando bichos nesse ponto, capturando
  nesse ponto" (Lucas, 2026-08-11). A recorded route used to be a list of
  places; the clock turns it into a list of INTENTIONS, and the hunt can obey
  intentions.
  """
  use ExUnit.Case, async: true

  alias Pokex.Bots.Cavebot.{Recording, Route}

  @fight_ms 12_000

  defp route_of(dwells) do
    Enum.reduce(Enum.with_index(dwells), Route.new("r"), fn {dwell, index}, route ->
      {:ok, route} = Route.append(route, {index * 5, 0, 7})
      if dwell, do: Route.set_dwell(route, index, dwell), else: route
    end)
  end

  defp marks(route), do: Enum.map(route.waypoints, &{&1.action, &1.stops})

  describe "a long stop is a kill spot" do
    test "standing there long enough marks the end of a gathering and a sweep" do
      route = route_of([200, 300, 30_000])

      assert marks(Recording.infer(route, 2, @fight_ms)) == [
               {:lure_start, []},
               {:walk, []},
               {:lure_end, [:sweep]}
             ]
    end

    test "a quick mark is just walking, and changes nothing" do
      route = route_of([200, 300, 400])

      assert marks(Recording.infer(route, 2, @fight_ms)) == [
               {:walk, []},
               {:walk, []},
               {:walk, []}
             ]
    end

    test "exactly at the threshold counts — the number he tuned is the number" do
      route = route_of([100, @fight_ms])

      assert {:lure_end, [:sweep]} = List.last(marks(Recording.infer(route, 1, @fight_ms)))
    end
  end

  # His loop: kill at a spot, walk gathering the next pile, kill again. So the
  # stretch BETWEEN two kill spots is the mob stretch — no guessing needed,
  # the route says it.
  describe "the stretch between two kill spots is the gathering" do
    # Inferred stop by stop, the way the recorder actually calls it: the first
    # kill spot is already marked by the time the second one happens.
    test "the gathering starts right after the previous kill spot" do
      route =
        [100, 30_000, 100, 100, 30_000]
        |> route_of()
        |> Recording.infer(1, @fight_ms)
        |> Recording.infer(4, @fight_ms)

      # the walk INTO the first kill spot is a gathering too — the route
      # begins where the first pile starts being collected
      assert marks(route) == [
               {:lure_start, []},
               {:lure_end, [:sweep]},
               {:lure_start, []},
               {:walk, []},
               {:lure_end, [:sweep]}
             ]
    end

    test "with no earlier kill spot it starts at the first waypoint" do
      route = route_of([100, 100, 30_000])

      assert [{:lure_start, []} | _rest] = marks(Recording.infer(route, 2, @fight_ms))
    end

    # A kill spot immediately after another one has nothing in between: two
    # piles at the same corner, not a walk. Marking a zero-length stretch
    # would leave a lure_start ON the kill spot.
    test "two kill spots in a row do not invent a gathering between them" do
      inferred =
        [100, 30_000, 30_000]
        |> route_of()
        |> Recording.infer(1, @fight_ms)
        |> Recording.infer(2, @fight_ms)

      # both are kill spots, and NOTHING was marked as a gathering between
      # them — there is no walk in between to gather on
      assert Enum.at(marks(inferred), 1) == {:lure_end, [:sweep]}
      assert Enum.at(marks(inferred), 2) == {:lure_end, [:sweep]}

      starts = for {wp, i} <- Enum.with_index(inferred.waypoints), wp.action == :lure_start, do: i
      assert starts == [0]
    end
  end

  describe "what it refuses to touch" do
    test "an index nobody has changes nothing" do
      route = route_of([100, 100])

      assert Recording.infer(route, 9, @fight_ms) == route
    end

    test "a waypoint he marked BY HAND is left alone" do
      route = route_of([100, 100, 30_000]) |> Route.set_action(2, :walk)
      inferred = Recording.infer(route, 2, @fight_ms, hand_marked: [2])

      assert Enum.at(marks(inferred), 2) == {:walk, []}
    end
  end

  # "eu mesmo errei alguns combos ali" (Lucas, 2026-08-11): his first real mob
  # route came back with two "até aqui" in a row and a warning nobody could
  # act on. The marks are HIS; only their pairing was wrong.
  describe "tidying the marks" do
    defp actions(route), do: Enum.map(route.waypoints, & &1.action)

    defp with_kills(count, kills) do
      Enum.reduce(kills, route_of(List.duplicate(100, count)), fn index, route ->
        Route.set_stop(route, index, :sweep, true)
      end)
    end

    test "every kill spot gets exactly ONE gathering leading into it" do
      {tidy, note} = Recording.tidy(with_kills(6, [2, 5]))

      assert actions(tidy) == [:lure_start, :walk, :lure_end, :lure_start, :walk, :lure_end]
      assert note =~ "arrumei"
    end

    test "two kill spots in a row keep both, and invent no gathering between" do
      {tidy, _note} = Recording.tidy(with_kills(4, [1, 2]))

      assert actions(tidy) == [:lure_start, :lure_end, :lure_end, :walk]
    end

    test "a route with no kill spot has nothing to gather for" do
      {tidy, note} = Recording.tidy(with_kills(4, []))

      assert actions(tidy) == [:walk, :walk, :walk, :walk]
      assert note =~ "já estavam certas"
    end

    test "the leftover 'até aqui' with no pair is gone afterwards" do
      route = route_of([100, 100, 100]) |> Route.set_action(2, :lure_end)
      {tidy, _note} = Recording.tidy(route)

      assert Route.lure_issue(tidy) == nil
    end
  end

  # His real combos came back as 1,1,3,3,3,4,4,4,4,4,5,5,5 — he mashes the key
  # while it is on cooldown. The intention underneath is 1,3,4,5.
  describe "what he MEANT to press" do
    test "consecutive repeats collapse into one" do
      assert Recording.combo_intent(~w(1 1 3 3 3 4 4 4 4 4 5 5 5)) == ~w(1 3 4 5)
    end

    # Coming BACK to a skill after others is a decision, not mashing: his
    # longest recorded combo ends 8,8,2,3,4 after a first 3 and 4.
    test "a skill pressed again LATER stays" do
      assert Recording.combo_intent(~w(3 3 4 4 5 3)) == ~w(3 4 5 3)
    end

    test "nothing pressed is nothing meant" do
      assert Recording.combo_intent([]) == []
    end
  end

  describe "saying what it did" do
    test "the note names the stop and the marks" do
      route = route_of([100, 100, 34_000])
      {_route, note} = Recording.infer_with_note(route, 2, @fight_ms)

      assert note =~ "34s parado"
      assert note =~ "até aqui"
      assert note =~ "varrer"
      assert note =~ ~s("mobar daqui" no waypoint 1)
    end

    test "a short stop says nothing at all" do
      route = route_of([100, 100, 400])

      assert {_route, nil} = Recording.infer_with_note(route, 2, @fight_ms)
    end
  end
end
