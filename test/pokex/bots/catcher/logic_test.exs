defmodule Pokex.Bots.Catcher.LogicTest do
  use ExUnit.Case, async: true

  alias Pokex.Bots.Catcher.Logic

  defp config do
    %{
      corpse_match_tolerance_px: 32,
      corpse_max_balls: 2,
      corpse_ignore_ttl_ms: 120_000,
      corpse_confirm_after_ms: 800,
      feed_corpses_ms: 400
    }
  end

  defp armed do
    {logic, []} = Logic.start(Logic.new(config()), 0)
    logic
  end

  defp obs(corpses, at), do: %{scanning?: true, corpses: corpses, captured_at: at}

  test "a corpse observation throws ONE ball and awaits confirmation" do
    {logic, actions} = Logic.step(armed(), obs([{100, 200}], 10), 10)
    assert {:capture_sequence, {100, 200}} in actions
    assert logic.counters.throws == 1

    # a PRE-WINDOW frame (10 + 800 = 810 > 700) proves nothing: new corpses queue,
    # nothing else is thrown while one ball is in flight
    {logic, actions} = Logic.step(logic, obs([{100, 200}, {300, 300}], 700), 700)
    refute Enum.any?(actions, &match?({:capture_sequence, _}, &1))
    assert logic.queue == [{300, 300}]
  end

  test "the corpse vanishing after the flight window confirms and throws the next in one step" do
    {logic, _} = Logic.step(armed(), obs([{100, 200}], 10), 10)

    # past the window, {100,200} gone; {300,300} is new → confirm + admit + throw, same step
    {logic, actions} = Logic.step(logic, obs([{300, 300}], 900), 900)
    assert logic.counters.captures == 1
    assert {:capture_sequence, {300, 300}} in actions
  end

  test "an observation captured BEFORE the flight window never confirms nor retries" do
    {logic, _} = Logic.step(armed(), obs([{100, 200}], 10), 10)
    # captured_at 500 < throw at 10 + confirm_after 800 → too early, no verdict
    {logic, actions} = Logic.step(logic, obs([], 500), 500)
    assert logic.counters.captures == 0
    assert logic.throw != nil
    assert actions == []
  end

  test "a persisting blob gets one retry then joins the ignore list — even at the exact same spot" do
    {logic, _} = Logic.step(armed(), obs([{100, 200}], 10), 10)

    # still there after the window (position identical — a parked pet) → retry (ball 2)
    {logic, actions} = Logic.step(logic, obs([{100, 200}], 900), 900)
    assert {:capture_sequence, {100, 200}} in actions
    assert logic.throw.balls == 2

    # the retry got its own flight window (thrown at 900): still there past 1700 → ignored
    {logic, actions} = Logic.step(logic, obs([{100, 200}], 1_800), 1_800)
    refute Enum.any?(actions, &match?({:capture_sequence, _}, &1))
    assert logic.counters.ignored == 1
    assert logic.throw == nil

    # while ignored, never re-admitted
    {logic, actions} = Logic.step(logic, obs([{102, 198}], 2_400), 2_400)
    assert actions == []
    assert logic.queue == []

    # after the TTL (1_800 + 120_000) it is fair game again
    {_logic, actions} = Logic.step(logic, obs([{100, 200}], 130_000), 130_000)
    assert {:capture_sequence, {100, 200}} in actions
  end

  test "stale/nil observations do nothing" do
    assert {%Logic{}, []} = Logic.step(armed(), nil, 50)
  end

  test "frame dedup: the same captured_at never double-confirms" do
    {logic, _} = Logic.step(armed(), obs([{100, 200}], 10), 10)
    {logic, _} = Logic.step(logic, obs([], 900), 900)
    assert logic.counters.captures == 1

    # same frame again (event + wake race) → no second verdict, no crash
    {logic, actions} = Logic.step(logic, obs([], 900), 901)
    assert logic.counters.captures == 1
    assert actions == []
  end

  test "next_wake polls while a throw or queue is pending, sleeps when idle-empty" do
    logic = armed()
    assert Logic.next_wake(logic, 0) == nil

    {logic, _} = Logic.step(logic, obs([{100, 200}], 10), 10)
    assert Logic.next_wake(logic, 10) == 400

    {logic, _} = Logic.step(logic, obs([], 900), 900)
    assert Logic.next_wake(logic, 900) == nil
  end
end
