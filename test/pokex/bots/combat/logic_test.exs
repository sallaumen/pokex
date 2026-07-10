defmodule Pokex.Bots.Combat.LogicTest do
  use ExUnit.Case, async: true

  alias Pokex.Bots.Combat.Logic

  defp config(overrides \\ []) do
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

  defp hunting(now \\ 0) do
    {logic, []} = Logic.start(Logic.new(config()), now)
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

    # past the throttle it does, continuing the rotation (burst 2 wraps: keys 1,2,3 again)
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

  test "next_wake: tabbing → confirm window remainder; fighting → timeout remainder; hunting hold → hold remainder; free hunting → nil" do
    {tabbing, _} = Logic.step(hunting(0), obs(enemies: [0], captured_at: 10), 10)
    assert Logic.next_wake(tabbing, 110) == 600

    fighting = confirmed()
    assert Logic.next_wake(fighting, 100) == 6_000 - (100 - fighting.entered_at)

    held = %{hunting(0) | hold_until: 2_000}
    assert Logic.next_wake(held, 500) == 1_500

    assert Logic.next_wake(hunting(0), 500) == nil
  end

  # hunting --Tab--> tabbing --locked frame--> fighting (first burst already fired at t=40)
  defp confirmed do
    {logic, _} = Logic.step(hunting(0), obs(enemies: [0], captured_at: 10), 10)
    {logic, _} = Logic.step(logic, obs(locked?: true, locked_row: 0, captured_at: 30), 40)
    assert logic.state == :fighting
    logic
  end
end
