defmodule Pokex.Bots.Fishing.LogicTest do
  use ExUnit.Case, async: true
  alias Pokex.Bots.Fishing.Logic

  def config do
    %{
      water_point: {800, 400},
      neutral_point: {860, 470},
      rod_key: "v",
      tick_ms_watching: 200,
      tick_ms_default: 300,
      wait_focus_ms: 150,
      wait_after_equip_ms: 300,
      wait_cast_settle_ms: nil,
      wait_assess_ms: 1500,
      watch_timeout_ms: 30_000,
      watch_dead_streak_needed: 10,
      max_consecutive_failures: 3,
      glow_streak_needed: 1,
      calm_streak_needed: 1
    }
  end

  def cursor_obs, do: %{cursor: {500, 500}}

  def advance_to(:focusing), do: elem(Logic.start(Logic.new(config()), 0), 0)

  def advance_to(:equipping) do
    {l, _} = Logic.step(advance_to(:focusing), cursor_obs(), 0)
    l
  end

  def advance_to(:casting) do
    {l, _} = Logic.step(advance_to(:equipping), cursor_obs(), 200)
    l
  end

  def advance_to(:watching) do
    {l, _} = Logic.step(advance_to(:casting), cursor_obs(), 600)
    l
  end

  test "start only from idle or error" do
    {l, []} = Logic.start(Logic.new(config()), 0)
    assert l.state == :focusing
    # começar de novo não muda nada
    assert {^l, []} = Logic.start(l, 10)
  end

  test "focusing clicks neutral point and waits" do
    {l, actions} = Logic.step(advance_to(:focusing), cursor_obs(), 0)
    assert l.state == :equipping
    assert actions == [{:click, :left, {860, 470}}]
    assert l.waiting_until == 150
    # tick dentro da espera: nada acontece
    assert {^l, []} = Logic.step(l, cursor_obs(), 100)
  end

  test "equipping presses the rod key then casting clicks water" do
    {l, actions} = Logic.step(advance_to(:equipping), cursor_obs(), 200)
    assert l.state == :casting
    assert actions == [{:press, "v"}]

    {l, actions} = Logic.step(l, cursor_obs(), 600)
    assert l.state == :watching
    assert actions == [{:click, :left, {800, 400}}]
    assert l.counters.cycles == 1
  end

  test "casting waits out the cast splash before watching" do
    cfg = Map.put(config(), :wait_cast_settle_ms, 500)
    {l, _} = Logic.step(%{advance_to(:equipping) | config: cfg}, cursor_obs(), 200)
    {l, actions} = Logic.step(l, cursor_obs(), 600)
    assert l.state == :watching
    assert actions == [{:click, :left, {800, 400}}]
    # a settle window is armed, so the splash isn't read as a bite
    assert l.waiting_until == 600 + 500
    assert {^l, []} = Logic.step(l, Map.put(cursor_obs(), :glow, true), 700)
  end

  test "watching: settle on calm water first, THEN a bubble hooks and loops back to casting" do
    watching = advance_to(:watching)
    refute watching.settled?

    # cyan BEFORE settling = the cast splash → ignored, stays watching
    {still, []} = Logic.step(watching, Map.put(cursor_obs(), :glow, true), 650)
    assert still.state == :watching
    refute still.settled?

    # calm water → settled (splash gone)
    {settled, []} = Logic.step(watching, Map.put(cursor_obs(), :glow, false), 700)
    assert settled.state == :watching
    assert settled.settled?

    # now a bubble is a real bite → hook, and loop straight back to casting (no combat)
    {l, actions} = Logic.step(settled, Map.put(cursor_obs(), :glow, true), 900)
    assert l.state == :casting
    assert actions == [{:press, "v"}]
    assert l.counters.hooked == 1
    assert l.waiting_until == 900 + 1500
  end

  test "a confirmed bite hooks and loops straight back to casting (no combat)" do
    settled = %Logic{state: :watching, settled?: true, config: config()}
    {l, actions} = Logic.step(settled, Map.put(cursor_obs(), :glow, true), 1000)
    assert l.state == :casting
    assert actions == [{:press, "v"}]
    assert l.counters.hooked == 1
  end

  test "watching debounces the bite: needs consecutive bubble frames to hook" do
    cfg = Map.put(config(), :glow_streak_needed, 2)
    watching = %Logic{state: :watching, config: cfg, entered_at: 0, settled?: true}

    {l, actions} = Logic.step(watching, Map.put(cursor_obs(), :glow, true), 100)
    assert l.state == :watching
    assert actions == []
    assert l.glow_streak == 1

    {l, actions} = Logic.step(l, Map.put(cursor_obs(), :glow, true), 200)
    assert l.state == :casting
    assert actions == [{:press, "v"}]

    # a lone bubble frame followed by calm resets the streak
    {reset, _} = Logic.step(watching, Map.put(cursor_obs(), :glow, true), 100)
    {reset, _} = Logic.step(reset, Map.put(cursor_obs(), :glow, false), 200)
    assert reset.glow_streak == 0
  end

  test "watching: an oscillating cast splash never latches settled? and never hooks" do
    cfg = config() |> Map.put(:calm_streak_needed, 2) |> Map.put(:glow_streak_needed, 2)

    watching = %Logic{
      state: :watching,
      config: cfg,
      entered_at: 0,
      settled?: false,
      calm_streak: 0,
      glow_streak: 0
    }

    # splash oscillates crest/trough; each trough advances calm_streak to 1,
    # each crest resets it to 0 → settled? can never reach the 2-consecutive gate.
    seq = [true, false, true, false, true, true]

    {final, _acts} =
      Enum.reduce(Enum.with_index(seq), {watching, []}, fn {glow, i}, {l, _} ->
        Logic.step(l, Map.put(cursor_obs(), :glow, glow), 100 + i * 100)
      end)

    assert final.state == :watching
    refute final.settled?
  end

  test "watching: settles only after calm_streak_needed consecutive calm frames" do
    cfg = Map.put(config(), :calm_streak_needed, 2)

    watching = %Logic{
      state: :watching,
      config: cfg,
      entered_at: 0,
      settled?: false,
      calm_streak: 0
    }

    {one, []} = Logic.step(watching, Map.put(cursor_obs(), :glow, false), 100)
    refute one.settled?
    assert one.calm_streak == 1

    {two, []} = Logic.step(one, Map.put(cursor_obs(), :glow, false), 200)
    assert two.settled?
  end

  test "watching: a splash crest resets the calm run before settling" do
    cfg = Map.put(config(), :calm_streak_needed, 2)

    watching = %Logic{
      state: :watching,
      config: cfg,
      entered_at: 0,
      settled?: false,
      calm_streak: 0
    }

    {one, []} = Logic.step(watching, Map.put(cursor_obs(), :glow, false), 100)
    assert one.calm_streak == 1

    {crest, []} = Logic.step(one, Map.put(cursor_obs(), :glow, true), 200)
    refute crest.settled?
    assert crest.calm_streak == 0
  end

  test "watching: after settling, a bubble still hooks even much later" do
    cfg = config() |> Map.put(:calm_streak_needed, 2) |> Map.put(:glow_streak_needed, 1)

    watching = %Logic{
      state: :watching,
      config: cfg,
      entered_at: 0,
      settled?: false,
      calm_streak: 0
    }

    {a, []} = Logic.step(watching, Map.put(cursor_obs(), :glow, false), 100)
    {settled, []} = Logic.step(a, Map.put(cursor_obs(), :glow, false), 200)
    assert settled.settled?

    # a calm dip mid-watch keeps settled? true (clause c)
    {still, []} = Logic.step(settled, Map.put(cursor_obs(), :glow, false), 15_000)
    assert still.settled?

    {hooked, [{:press, "v"}]} = Logic.step(still, Map.put(cursor_obs(), :glow, true), 15_100)
    assert hooked.state == :casting
  end

  test "watching recasts (via equipping) after the absolute watch timeout" do
    # a single frame past watch_timeout_ms trips the backstop even before the
    # dead-frame streak fills; recovery re-arms the rod (routes through :equipping).
    watching = advance_to(:watching)
    {l, actions} = Logic.step(watching, Map.put(cursor_obs(), :glow, false), 600 + 30_001)
    assert l.state == :equipping
    assert [{:log, _}] = actions
  end

  test "watching recasts via equipping after watch_dead_streak_needed no-bubble frames" do
    # config() sets watch_dead_streak_needed: 10; feed 10 consecutive no-bite
    # frames with the clock well under watch_timeout_ms so ONLY the dead-frame
    # path can fire. Recovery re-arms the rod (press v) rather than just re-click.
    watching = advance_to(:watching)

    {result, actions} =
      Enum.reduce(1..10, {watching, []}, fn i, {l, _} ->
        Logic.step(l, Map.put(cursor_obs(), :glow, false), 700 + i * 100)
      end)

    assert result.state == :equipping
    assert [{:log, msg}] = actions
    assert msg =~ "re-lançando"
  end

  test "a bubble frame resets the dead-frame streak — a live line is never recast mid-bite" do
    # already settled and part-way to the dead threshold; a bite-magnitude frame
    # (needs 2 to hook here) doesn't hook yet but must clear the dead streak, so a
    # slow-but-live bite can never trip the recast.
    cfg = Map.put(config(), :glow_streak_needed, 2)

    watching = %Logic{
      state: :watching,
      config: cfg,
      entered_at: 0,
      settled?: true,
      dead_streak: 9
    }

    {live, []} = Logic.step(watching, Map.put(cursor_obs(), :glow, true), 100)
    assert live.state == :watching
    assert live.dead_streak == 0
    assert live.glow_streak == 1
  end

  test "a present line pulsing below the bite threshold holds the dead streak (only empty water counts)" do
    # line? true = the cast line is in the water (pulsing between bites) but below
    # the bite threshold → NOT a dead frame: a resting line keeps fishing forever.
    watching = %Logic{
      state: :watching,
      config: config(),
      entered_at: 0,
      settled?: true,
      dead_streak: 7
    }

    {held, []} = Logic.step(watching, %{cursor: {500, 500}, glow: false, line?: true}, 100)
    assert held.state == :watching
    assert held.dead_streak == 0

    # line? false = near-empty water (dropped rod) → this one DOES count up
    {climb, []} = Logic.step(held, %{cursor: {500, 500}, glow: false, line?: false}, 200)
    assert climb.dead_streak == 1
  end

  test "kill corner stops from any active state" do
    {l, actions} = Logic.step(advance_to(:watching), %{cursor: {5, 5}, glow: true}, 700)
    assert l.state == :idle
    assert [{:log, _}] = actions
  end

  test "needs per state" do
    assert Logic.needs(advance_to(:focusing)) == [:cursor]
    assert Logic.needs(advance_to(:watching)) == [:cursor, :glow]
    assert Logic.needs(%Logic{state: :idle}) == []
  end

  test "tick_interval per state" do
    assert Logic.tick_interval(advance_to(:watching)) == 200
    assert Logic.tick_interval(advance_to(:focusing)) == 300
  end

  test "io_failed counts and eventually errors" do
    l = advance_to(:watching)
    {l, _} = Logic.io_failed(l, "boom", 700)
    assert l.state == :equipping
    assert l.failures == 1
    assert l.counters.failures == 1

    {l, _} = Logic.io_failed(l, "boom", 800)
    {l, _} = Logic.io_failed(l, "boom", 900)
    assert l.state == :error
    assert l.error =~ "boom"
  end

  test "kill corner beats an active waiting_until" do
    # focusing sets waiting_until = now + wait_focus_ms (150); stepping again at
    # now < 150 would normally be a no-op wait — kill corner must still win.
    focusing = advance_to(:focusing)
    {equipping, _} = Logic.step(focusing, cursor_obs(), 0)
    assert equipping.state == :equipping
    assert equipping.waiting_until == 150

    {killed, actions} = Logic.step(equipping, %{cursor: {3, 3}}, 50)
    assert killed.state == :idle
    assert [{:log, _}] = actions
  end
end
