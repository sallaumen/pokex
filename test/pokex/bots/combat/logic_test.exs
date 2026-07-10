defmodule Pokex.Bots.Combat.LogicTest do
  use ExUnit.Case, async: true

  alias Pokex.Bots.Combat.Logic

  defp config(overrides) do
    Enum.into(overrides, %{
      tab_confirm_ms: 700,
      tab_max_attempts: 3,
      hunt_cooldown_ms: 1_500,
      skill_burst_every_ms: 300,
      fight_timeout_ms: 6_000,
      target_lost_streak: 2,
      skill_keys: ["1", "2", "3"],
      combat_skill_burst_size: 3,
      max_consecutive_failures: 5
    })
  end

  defp hunting(now \\ 0, config_overrides \\ []) do
    {logic, []} = Logic.start(Logic.new(config(config_overrides)), now)
    logic
  end

  defp obs(fields),
    do:
      Enum.into(fields, %{enemies: [], red: [], locked?: false, locked_row: nil, captured_at: 0})

  test "start enters :hunting" do
    assert %Logic{state: :hunting} = hunting()
  end

  test "hunting: enemies present → Tab, :tabbing" do
    {logic, actions} = Logic.step(hunting(0), obs(enemies: [0], captured_at: 10), 10)
    assert logic.state == :tabbing
    assert logic.tab_attempts == 1
    assert {:tab} in actions
  end

  test "hunting: empty battle or nil obs → hold, no actions" do
    assert {%Logic{state: :hunting}, []} = Logic.step(hunting(0), obs(captured_at: 10), 10)
    assert {%Logic{state: :hunting}, []} = Logic.step(hunting(0), nil, 10)
  end

  test "tabbing: a lock on a frame captured AFTER the Tab confirms and fires the first burst" do
    {logic, _} = Logic.step(hunting(0), obs(enemies: [0], captured_at: 10), 10)

    # a frame captured BEFORE the tab (stale) must NOT confirm
    {still, []} =
      Logic.step(logic, obs(locked?: true, locked_row: 0, captured_at: 5), 20)

    assert still.state == :tabbing

    {fighting, actions} =
      Logic.step(still, obs(locked?: true, locked_row: 0, captured_at: 30), 40)

    assert fighting.state == :fighting
    assert [{:press, "1"}, {:press, "2"}, {:press, "3"}] = actions
  end

  test "tabbing: a lock captured exactly at tabbed_at (not strictly after) must NOT confirm" do
    # tab() stamps tabbed_at from `now` (10), not from the triggering obs's captured_at (5) —
    # so this frame (captured_at: 10) clears the dedup gate (10 > last_obs_at 5) but must
    # still fail the freshness check: fresh_lock? requires strictly AFTER, not >=.
    {logic, _} = Logic.step(hunting(0), obs(enemies: [0], captured_at: 5), 10)
    assert logic.tabbed_at == 10

    {still, actions} = Logic.step(logic, obs(locked?: true, locked_row: 0, captured_at: 10), 20)
    assert still.state == :tabbing
    assert actions == []
  end

  test "tabbing: window expiry re-Tabs up to max attempts, then hunt cooldown" do
    {logic, _} = Logic.step(hunting(0), obs(enemies: [0], captured_at: 10), 10)

    # 800ms later, no lock → second Tab
    {logic, actions} = Logic.step(logic, obs(enemies: [0], captured_at: 800), 811)
    assert logic.state == :tabbing and logic.tab_attempts == 2
    assert {:tab} in actions

    # exhaust the third attempt, then the next expiry sends us to hunting WITH a hold
    {logic, _} = Logic.step(logic, obs(enemies: [0], captured_at: 1_600), 1_612)
    assert logic.tab_attempts == 3
    {logic, _} = Logic.step(logic, obs(enemies: [0], captured_at: 2_400), 2_413)
    assert logic.state == :hunting
    assert logic.hold_until == 2_413 + 1_500

    # while held, enemies do NOT trigger a Tab
    assert {%Logic{state: :hunting}, []} =
             Logic.step(logic, obs(enemies: [0], captured_at: 2_500), 2_500)

    # after the hold, they do
    {logic, actions} = Logic.step(logic, obs(enemies: [0], captured_at: 4_000), 4_000)
    assert logic.state == :tabbing
    assert {:tab} in actions
  end

  test "rescan clears the hunt hold (fish hooked → enemy imminent)" do
    {logic, _} = Logic.step(hunting(0), obs(enemies: [0], captured_at: 10), 10)
    logic = %{logic | state: :hunting, hold_until: 99_999, tabbed_at: nil}
    logic = Logic.rescan(logic, 50)
    assert logic.hold_until == nil
  end

  test "fighting: bursts are throttled by skill_burst_every_ms" do
    logic = confirmed()

    # immediately after the confirm burst, another locked frame does NOT burst again
    {logic, []} = Logic.step(logic, obs(locked?: true, locked_row: 0, captured_at: 150), 150)

    # past the throttle, a DISTINCT fresh frame does burst, continuing the rotation (burst 2
    # wraps: keys 1,2,3 again) — this also guards that dedup doesn't eat legit new frames.
    {_logic, actions} =
      Logic.step(logic, obs(locked?: true, locked_row: 0, captured_at: 460), 460)

    assert [{:press, _}, {:press, _}, {:press, _}] = actions
  end

  test "fighting: lock gone for target_lost_streak frames counts the kill and re-hunts" do
    logic = confirmed()

    {logic, []} = Logic.step(logic, obs(locked?: false, captured_at: 500), 500)
    assert logic.lost_streak == 1

    {logic, actions} = Logic.step(logic, obs(locked?: false, captured_at: 620), 620)
    assert logic.state == :hunting
    assert logic.counters.fights == 1
    assert Enum.any?(actions, &match?({:log, _}, &1))
  end

  test "fighting: the SAME frame fed twice (event + racing wake) doesn't double-count the lost streak" do
    logic = confirmed()

    {logic, []} = Logic.step(logic, obs(locked?: false, captured_at: 500), 500)
    assert logic.lost_streak == 1

    # identical captured_at: e.g. the wake fired before the feed wrote a new ETS entry —
    # must be normalized to nil (no vote), not counted as a second observed frame.
    {logic, []} = Logic.step(logic, obs(locked?: false, captured_at: 500), 620)
    assert logic.lost_streak == 1
    assert logic.counters.fights == 0
  end

  test "fighting: a nil obs (timer wake) never counts toward the lost streak" do
    logic = confirmed()
    {logic, []} = Logic.step(logic, nil, 500)
    assert logic.lost_streak == 0
  end

  test "fighting: fight_timeout drops the target" do
    logic = confirmed()

    {logic, actions} =
      Logic.step(logic, obs(locked?: true, locked_row: 0, captured_at: 7_000), 7_000)

    assert logic.state == :hunting
    assert Enum.any?(actions, &match?({:log, _}, &1))
    assert logic.counters.fights == 0
  end

  test "next_wake: tabbing polls at min(confirm-window remainder, skill_burst_every_ms)" do
    {tabbing, _} = Logic.step(hunting(0), obs(enemies: [0], captured_at: 10), 10)

    # tabbed_at: 10, tab_confirm_ms: 700 → deadline at 710. Window remainder (600) is larger
    # than the burst cadence (300) → capped at the cadence so a static screen still polls.
    assert Logic.next_wake(tabbing, 110) == 300

    # near the window's expiry the remainder (10) is smaller than the cadence → it wins.
    assert Logic.next_wake(tabbing, 700) == 10
  end

  test "next_wake: fighting polls at min(fight-timeout remainder, skill_burst_every_ms)" do
    fighting = confirmed()

    # fresh fight: 6000ms remaining vs a 300ms burst cadence → capped at the cadence.
    assert Logic.next_wake(fighting, 100) == 300

    # near timeout: the remainder (100) is smaller than the cadence → it wins.
    assert Logic.next_wake(fighting, fighting.entered_at + 5_900) == 100
  end

  test "next_wake: hunting hold → hold remainder; free hunting → nil" do
    held = %{hunting(0) | hold_until: 2_000}
    assert Logic.next_wake(held, 500) == 1_500

    assert Logic.next_wake(hunting(0), 500) == nil
  end

  test "next_wake: fighting floors the final result at 1ms even with skill_burst_every_ms: 0 (N1)" do
    # A user-set 0ms burst cadence must not make next_wake return 0 — that would busy-loop
    # the driver on a self-wake instead of yielding at least 1ms.
    fighting = confirmed(skill_burst_every_ms: 0)
    assert Logic.next_wake(fighting, 100) >= 1
  end

  # hunting --Tab--> tabbing --locked frame--> fighting (first burst already fired at t=40)
  defp confirmed(config_overrides \\ []) do
    {logic, _} = Logic.step(hunting(0, config_overrides), obs(enemies: [0], captured_at: 10), 10)
    {logic, _} = Logic.step(logic, obs(locked?: true, locked_row: 0, captured_at: 30), 40)
    assert logic.state == :fighting
    logic
  end
end
