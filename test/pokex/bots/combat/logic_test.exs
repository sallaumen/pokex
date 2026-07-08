defmodule Pokex.Bots.Combat.LogicTest do
  use ExUnit.Case, async: true
  alias Pokex.Bots.Combat.Logic

  def config do
    %{
      neutral_point: {860, 470},
      player_point: {600, 300},
      skill_keys: ["1", "2"],
      skill_cast_ms: 500,
      tile_px: 50,
      walk_step_ms: 5,
      loot_presses: 2,
      max_walk_tiles: 7,
      tick_ms_fighting: 1000,
      tick_ms_default: 300,
      wait_loot_ms: 400,
      wait_after_capture_ms: 2000,
      fight_timeout_ms: 90_000,
      max_consecutive_failures: 3,
      hostile_scan_every: 2,
      auto_capture: true,
      target_locked_min_pixels: 350,
      battle_confirm_ms: 500,
      # 1 = a single ring-gone read ends the fight; the debounce test overrides to 2.
      target_lost_streak: 1,
      battle_rows: [
        {1466, 138},
        {1466, 168},
        {1466, 198},
        {1466, 228},
        {1466, 258},
        {1466, 288}
      ]
    }
  end

  def cursor_obs, do: %{cursor: {500, 500}}

  # A battle observation: attackable candidate rows + a per-row lock-ring list. `red` defaults
  # to no ring; pass `ring(row)` to light a row's lock.
  def battle_obs(enemies, red \\ [0, 0, 0, 0, 0, 0]),
    do: Map.put(cursor_obs(), :battle, %{enemies: enemies, red: red})

  def ring(row, px \\ 600), do: for(i <- 0..5, do: if(i == row, do: px, else: 0))

  def scanning do
    {l, []} = Logic.start(Logic.new(config()), 0)
    l
  end

  # scanning → click candidate row 0 (→ confirming) → ring on row 0 confirms → fighting.
  def advance_to_attacking do
    {l, _} = Logic.step(scanning(), battle_obs([0]), 100)
    {l, _} = Logic.step(l, battle_obs([0], ring(0)), 200)
    l
  end

  # -- lifecycle --------------------------------------------------------------

  test "start begins scanning" do
    {l, []} = Logic.start(Logic.new(config()), 0)
    assert l.state == :scanning
    refute l.targeted?
    assert l.locked_row == nil
  end

  test "rescan clears the idle latch so the next tick looks immediately; no-op while fighting" do
    idle = %Logic{state: :scanning, config: config(), scan_idle?: true, waiting_until: 999}
    woke = Logic.rescan(idle, 500)
    refute woke.scan_idle?
    assert woke.waiting_until == nil

    fighting = %Logic{state: :fighting, config: config(), targeted?: true, locked_row: 2}
    assert Logic.rescan(fighting, 500) == fighting
  end

  test "io_failed below max_consecutive_failures recovers into :scanning" do
    logic = %{Logic.new(config()) | state: :fighting, failures: 0}
    {l, [{:log, reason}]} = Logic.io_failed(logic, :boom, 100)

    assert l.state == :scanning
    assert l.failures == 1
    assert l.counters.failures == 1
    assert reason == "boom"
  end

  test "io_failed at max_consecutive_failures stops into :error" do
    cfg = Map.put(config(), :max_consecutive_failures, 2)
    logic = %{Logic.new(cfg) | state: :fighting, failures: 1}
    {l, [{:log, _}]} = Logic.io_failed(logic, :boom, 100)

    assert l.state == :error
    assert l.failures == 2
    assert l.error =~ "boom"
  end

  # -- driver hints -----------------------------------------------------------

  test "scanning reads :battle; confirming also reads the skill bar (it fires while confirming)" do
    assert Logic.needs(scanning(), 100) == [:cursor, :battle]
    confirming = %Logic{state: :confirming, config: config(), locked_row: 0}
    assert Logic.needs(confirming, 100) == [:cursor, :battle, :ready_skills]
  end

  test "fighting reads the skill bar EVERY tick — the bar is how a press is verified" do
    base = %Logic{state: :fighting, targeted?: true, config: config()}
    assert :ready_skills in Logic.needs(base, 1000)
    assert :ready_skills in Logic.needs(base, 2000)
  end

  # -- scanning: idle gate ----------------------------------------------------

  describe "scanning idle gate (no candidate)" do
    test "no candidate emits ZERO mouse actions and stays in :scanning" do
      {l, actions} = Logic.step(scanning(), battle_obs([]), 100)

      refute Enum.any?(actions, &match?({:click, _, _}, &1))
      refute Enum.any?(actions, &match?({:move, _}, &1))
      refute Enum.any?(actions, &match?({:press, _}, &1))
      assert l.state == :scanning

      {l2, []} = Logic.step(l, battle_obs([]), 200)
      assert l2.state == :scanning
    end

    test "the idle log fires exactly once on entering idle, then goes silent" do
      obs = battle_obs([])
      {l, [{:log, msg}]} = Logic.step(scanning(), obs, 100)
      assert msg =~ "sem inimigos"
      assert l.scan_idle?

      {l, []} = Logic.step(l, obs, 200)
      {_l, []} = Logic.step(l, obs, 300)
    end

    test "an absent :battle key behaves like no candidate (idle)" do
      {l, [{:log, _}]} = Logic.step(scanning(), cursor_obs(), 100)
      assert l.state == :scanning
      refute l.targeted?
    end
  end

  # -- scanning → confirming → fighting ---------------------------------------

  describe "click a candidate, then CONFIRM the battle via the ring" do
    test "scanning clicks the topmost candidate and moves to :confirming (not fighting yet)" do
      {l, actions} = Logic.step(scanning(), battle_obs([0]), 100)

      assert actions == [{:click, :left, {1466, 138}}, {:move, {860, 470}}]
      assert l.state == :confirming
      assert l.locked_row == 0
      refute l.targeted?
    end

    test "picks the topmost candidate when several are attackable" do
      {l, actions} = Logic.step(scanning(), battle_obs([2, 4]), 100)
      assert actions == [{:click, :left, {1466, 198}}, {:move, {860, 470}}]
      assert l.locked_row == 2
    end

    test "the ring on the clicked row confirms a real battle → :fighting" do
      {l, _} = Logic.step(scanning(), battle_obs([0]), 100)
      assert l.state == :confirming

      {l, []} = Logic.step(l, battle_obs([0], ring(0)), 150)
      assert l.state == :fighting
      assert l.targeted?
      assert l.locked_row == 0
    end

    test "attacks WHILE confirming — the first skill fires before the ring, then confirms" do
      {l, _} = Logic.step(scanning(), battle_obs([0]), 100)
      assert l.state == :confirming

      # no ring yet, inside the window → press the strongest skill NOW (don't wait for the ring)
      {l, [{:press, "1"}]} = Logic.step(l, battle_obs([0]), 200)
      assert l.state == :confirming

      # the ring shows up → commit to fighting
      {l, []} = Logic.step(l, battle_obs([0], ring(0)), 300)
      assert l.state == :fighting
    end

    test "no ring within battle_confirm_ms → the click engaged nothing → try the next candidate" do
      # candidate row 0 is a passing player's pokemon: clicked, but never rings.
      {l, _} = Logic.step(scanning(), battle_obs([0, 1]), 100)
      assert l.state == :confirming and l.locked_row == 0

      # inside the window, still no ring → keep ATTACKING (strongest skill) while waiting
      {l, [{:press, "1"}]} = Logic.step(l, battle_obs([0, 1]), 300)
      assert l.state == :confirming

      # window elapsed with no ring → mark row 0 tried, back to scanning
      {l, [{:log, msg}]} = Logic.step(l, battle_obs([0, 1]), 700)
      assert l.state == :scanning
      assert msg =~ "não entrou em batalha"
      assert l.tried == [0]

      # scanning now SKIPS the tried row 0 and clicks the next candidate, row 1
      {l, actions} = Logic.step(l, battle_obs([0, 1]), 750)
      assert l.state == :confirming
      assert l.locked_row == 1
      assert actions == [{:click, :left, {1466, 168}}, {:move, {860, 470}}]
    end

    test "when every candidate is a dud (no ring), combat goes idle instead of fake-fighting" do
      # one candidate, a player → click, no ring → tried, then no untried candidate → idle
      {l, _} = Logic.step(scanning(), battle_obs([0]), 100)
      {l, [{:log, _}]} = Logic.step(l, battle_obs([0]), 700)
      assert l.state == :scanning
      assert l.tried == [0]

      {l, actions} = Logic.step(l, battle_obs([0]), 750)
      assert l.state == :scanning
      refute l.targeted?
      refute Enum.any?(actions, &match?({:click, _, _}, &1))
    end

    test "a changed candidate set forgets the tried rows (re-evaluates the new pass)" do
      {l, _} = Logic.step(scanning(), battle_obs([0]), 100)
      {l, [{:log, _}]} = Logic.step(l, battle_obs([0]), 700)
      assert l.tried == [0]

      # the list changed (a real enemy appeared at row 2) → tried resets → row 0 clickable again,
      # but row 0 is topmost so it's clicked; the point is `tried` was cleared for the new set.
      {l, _} = Logic.step(l, battle_obs([0, 2]), 750)
      assert l.state == :confirming
      assert l.tried == []
      assert l.tried_for == [0, 2]
    end
  end

  # -- fighting ---------------------------------------------------------------

  describe "fighting (ring-based)" do
    test "the first fighting tick fires the strongest skill immediately" do
      {l, actions} = Logic.step(advance_to_attacking(), battle_obs([0], ring(0)), 300)
      assert actions == [{:press, "1"}]
      assert l.state == :fighting
    end

    test "while the ring holds, keep hitting the highest-priority READY skill" do
      l = advance_to_attacking()

      obs = fn ready ->
        battle_obs([0], ring(0)) |> Map.put(:ready_skills, ready) |> Map.put(:hostile, {700, 350})
      end

      # both ready → the strongest, "1"
      {l, [{:press, "1"}]} = Logic.step(l, obs.(["1", "2"]), 1000)
      assert l.last_hostile == {700, 350}
      assert l.lost_streak == 0

      # "1" is on cooldown now (fired), only "2" ready → fire "2"
      {l, [{:press, "2"}]} = Logic.step(l, obs.(["2"]), 2000)
      # "1" back up → fire "1" again (highest priority)
      {_l, [{:press, "1"}]} = Logic.step(l, obs.(["1", "2"]), 3000)
    end

    test "the verify loop: re-press the SAME skill until the bar shows it fired, then advance" do
      l = advance_to_attacking()
      obs = fn ready -> battle_obs([0], ring(0)) |> Map.put(:ready_skills, ready) end

      # "1" ready → press "1"
      {l, [{:press, "1"}]} = Logic.step(l, obs.(["1", "2"]), 1000)
      # the game DROPPED the press — "1" is STILL ready → press "1" AGAIN (not "2")
      {l, [{:press, "1"}]} = Logic.step(l, obs.(["1", "2"]), 1100)
      # "1" finally landed (off the ready list, on cooldown) → advance to "2"
      {_l, [{:press, "2"}]} = Logic.step(l, obs.(["2"]), 1200)
    end

    test "fires the highest-priority READY skill when the skill bar is read" do
      l = advance_to_attacking()
      obs = battle_obs([0], ring(0)) |> Map.put(:ready_skills, ["2"])
      {_l, [{:press, "2"}]} = Logic.step(l, obs, 1000)
    end

    test "a single ring blink does NOT end the fight (debounce), two in a row → loot" do
      cfg = Map.put(config(), :target_lost_streak, 2)
      l = %{advance_to_attacking() | config: cfg}

      # ring gone once → still fighting, counts toward the loss
      {l, []} = Logic.step(l, battle_obs([0]), 1000)
      assert l.state == :fighting
      assert l.lost_streak == 1

      # ring back before the streak completes → resets, resumes attacking
      {l, [{:press, _}]} = Logic.step(l, battle_obs([0], ring(0)), 2000)
      assert l.lost_streak == 0

      # gone twice in a row → target dead → hand off to loot and re-scan for the next enemy
      {l, []} = Logic.step(l, battle_obs([0]), 3000)
      {l, []} = Logic.step(l, battle_obs([0]), 4000)
      assert l.state == :scanning
      assert l.counters.fights == 1
    end

    test "the fight timeout abandons a target that never dies (rescan, not a failure)" do
      l = advance_to_attacking()
      {l, [{:log, _}]} = Logic.step(l, battle_obs([0], ring(0)), 200 + 90_001)
      assert l.state == :scanning
      refute l.targeted?
      assert l.failures == 0
    end
  end

  # -- kill hand-off (loot now lives in Loot.Worker) --------------------------

  describe "kill hand-off" do
    test "a kill returns to :scanning, counts the fight, and PRESERVES last_hostile for the event" do
      l = advance_to_attacking()
      obs = battle_obs([0], ring(0)) |> Map.put(:hostile, {700, 350})
      {l, _} = Logic.step(l, obs, 1000)
      assert l.last_hostile == {700, 350}

      # ring gone (target_lost_streak 1) → target dead → back to scanning for the next enemy.
      # The worker reads counters.fights + last_hostile to broadcast {:kill, {700, 350}}.
      {l, actions} = Logic.step(l, battle_obs([0]), 2000)
      assert l.state == :scanning
      refute l.targeted?
      assert l.counters.fights == 1
      assert l.last_hostile == {700, 350}
      # combat emits no loot/walk actions anymore
      refute Enum.any?(actions, &match?({:press, "space"}, &1))
      refute Enum.any?(actions, &match?({:capture_sequence, _}, &1))
    end

    test "a kill with an unknown corpse (last_hostile nil) still just re-scans" do
      l = advance_to_attacking()
      assert l.last_hostile == nil

      {l, []} = Logic.step(l, battle_obs([0]), 1000)
      assert l.state == :scanning
      assert l.counters.fights == 1
    end
  end
end
