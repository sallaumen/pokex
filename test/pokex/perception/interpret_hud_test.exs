defmodule Pokex.Perception.InterpretHudTest do
  # async: false — the layout fact is global
  use ExUnit.Case, async: false

  alias Pokex.{Calibration, Layout}
  alias Pokex.Perception.Interpret.{Hud, Minimap, Team}
  alias Pokex.Perception.WorldState
  alias Pokex.ScreenFixtures
  alias Pokex.Vision.Frame

  setup do
    on_exit(fn -> WorldState.forget(:layout) end)
    {:ok, fix} = Layout.locate(ScreenFixtures.frame!("ultrawide_3440x1440_full"))
    publish(fix)
    # exactly what the Feed hands an interpreter: the calibration of that tick,
    # carrying the layout that was used to CAPTURE the frame
    %{fix: fix, calib: %Calibration{scale: 1.0, layout: fix}}
  end

  # The feeds see their own cropped region, exactly as Capture hands it over.
  defp region_frame(fix, name) do
    {x, y, w, h} = Layout.region(name, fix)
    Frame.crop(ScreenFixtures.frame!("ultrawide_3440x1440_full"), {x, y, w, h})
  end

  defp publish(fix) do
    WorldState.put(
      :layout,
      %{
        "profile" => fix.profile,
        "anchors" => Map.new(fix.anchors, fn {k, {x, y}} -> {Atom.to_string(k), [x, y]} end),
        "regions" =>
          Map.new(fix.regions, fn {k, {x, y, w, h}} -> {Atom.to_string(k), [x, y, w, h]} end),
        "region_opts" =>
          Map.new(fix.region_opts, fn {k, o} -> {Atom.to_string(k), Keyword.get(o, :ink)} end),
        "located_at" => DateTime.to_iso8601(DateTime.utc_now())
      },
      System.monotonic_time(:millisecond)
    )
  end

  describe "the :hud feed" do
    test "reads the character's numbers and every watched stock off the real bar", %{
      fix: fix,
      calib: calib
    } do
      obs = Hud.interpret(region_frame(fix, :hud_bottom), calib, %{})

      assert obs.level == 90
      assert obs.food == 1525
      assert obs.fishing == 96
      assert obs.slots == %{f1: 322, f2: 36, e: 7, s_q: 43}
    end

    test "an uncalibrated system yields nils, never invented numbers" do
      blind = %Calibration{scale: 1.0, layout: nil}
      obs = Hud.interpret(Pokex.FrameFixtures.of(10, 10, fn _x, _y -> {0, 0, 0} end), blind, %{})

      assert obs == Hud.empty()
    end
  end

  describe "the :team feed" do
    test "reads the active pokémon's HP in digits", %{fix: fix, calib: calib} do
      obs = Team.interpret(region_frame(fix, :team_column), calib, %{})

      assert obs.pokemon_hp == {5559, 6410}
    end

    test "measures all five C+N rows; the damaged one reads lower", %{fix: fix, calib: calib} do
      obs = Team.interpret(region_frame(fix, :team_column), calib, %{})

      assert length(obs.rows) == 5
      assert Enum.map(obs.rows, & &1.slot) == [2, 3, 4, 5, 6]
      assert Enum.all?(obs.rows, & &1.present?)

      # measured: row C+2's green fill stops 8px short of the others
      [first | rest] = obs.rows
      assert first.hp_pct < 1.0
      assert Enum.all?(rest, &(&1.hp_pct > first.hp_pct))
    end

    test "parse_hp only accepts the real shape" do
      assert Team.parse_hp("5559/6410") == {5559, 6410}
      assert Team.parse_hp("5559 / 6410") == nil
      assert Team.parse_hp("????/6410") == nil
    end
  end

  describe "the :minimap feed" do
    test "reads the printed position — the cavebot never needs to see the map", %{
      fix: fix,
      calib: calib
    } do
      {obs, _state} = Minimap.interpret(region_frame(fix, :minimap), calib, %{})

      assert obs.pos == {337, 46107, 4}
    end

    test "an unreadable frame yields nil, not a stale lie", %{calib: calib} do
      {obs, _state} =
        Minimap.interpret(Pokex.FrameFixtures.of(60, 40, fn _x, _y -> {0, 0, 0} end), calib, %{})

      assert obs.pos == nil
    end
  end

  describe "the minimap's sanity gates (pure)" do
    @home {337, 46107, 4}
    @fresh %{last: nil, pending: nil}

    test "the first read baselines" do
      assert {%{pos: @home}, %{last: @home}} = Minimap.accept(@home, @fresh)
    end

    test "a normal step through is accepted" do
      step = {340, 46109, 4}
      assert {%{pos: ^step}, %{last: ^step}} = Minimap.accept(step, %{last: @home, pending: nil})
    end

    test "an impossible floor is refused outright" do
      assert {%{pos: nil}, _state} = Minimap.accept({337, 46107, 99}, @fresh)
    end

    test "a wild jump is refused ONCE, then accepted when the next read agrees" do
      far = {900, 46107, 4}

      # one garbled frame must not teleport the world model
      assert {%{pos: @home}, state} = Minimap.accept(far, %{last: @home, pending: nil})

      # ...but stairs and boats are real: a second agreeing read re-baselines
      assert {%{pos: ^far}, %{last: ^far, pending: nil}} = Minimap.accept(far, state)
    end

    test "an unreadable frame says 'I do not know' instead of repeating a stale position" do
      assert {%{pos: nil}, _state} = Minimap.accept(nil, %{last: @home, pending: nil})
    end
  end
end
