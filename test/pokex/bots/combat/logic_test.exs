defmodule Pokex.Bots.Combat.LogicTest do
  use ExUnit.Case, async: true
  alias Pokex.Bots.Combat.Logic

  def config do
    %{
      neutral_point: {860, 470},
      player_point: {600, 300},
      skill_keys: ["1", "2"],
      tile_px: 50,
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

  test "scanning and confirming read :battle only — combat cycles skills blind (no bar capture)" do
    assert Logic.needs(scanning(), 100) == [:cursor, :battle]
    confirming = %Logic{state: :confirming, config: config(), locked_row: 0}
    assert Logic.needs(confirming, 100) == [:cursor, :battle]
  end

  test "fighting never reads the skill bar (one capture per tick, the ring)" do
    base = %Logic{state: :fighting, targeted?: true, config: config()}
    refute :ready_skills in Logic.needs(base, 1000)
    assert :battle in Logic.needs(base, 1000)
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
    test "scanning clicks the topmost candidate and moves to :confirming — NO skill in that action" do
      {l, actions} = Logic.step(scanning(), battle_obs([0]), 100)

      # ONLY the click + move: a skill in the same action makes the game drop the select-click
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

    test "the ring confirms a real battle → :fighting, and that tick fires the first skill" do
      {l, _} = Logic.step(scanning(), battle_obs([0]), 100)
      assert l.state == :confirming

      # first skill fires on the confirm tick — one tick AFTER the click, so the click landed
      {l, [{:press, "1"}]} = Logic.step(l, battle_obs([0], ring(0)), 150)
      assert l.state == :fighting
      assert l.targeted?
      assert l.locked_row == 0
    end

    test "attacks through confirming, cycling skills each tick" do
      {l, _} = Logic.step(scanning(), battle_obs([0]), 100)
      assert l.state == :confirming

      # no ring yet → fire the first skill "1"
      {l, [{:press, "1"}]} = Logic.step(l, battle_obs([0]), 200)
      assert l.state == :confirming

      # the ring shows → commit to fighting AND fire the next skill "2"
      {l, [{:press, "2"}]} = Logic.step(l, battle_obs([0], ring(0)), 300)
      assert l.state == :fighting
    end

    test "no ring within battle_confirm_ms → the click engaged nothing → try the next candidate" do
      # candidate row 0 is a passing player's pokemon: clicked, but never rings.
      {l, _} = Logic.step(scanning(), battle_obs([0, 1]), 100)
      assert l.state == :confirming and l.locked_row == 0

      # inside the window, no ring → keep ATTACKING (fire "1") while waiting
      {l, [{:press, "1"}]} = Logic.step(l, battle_obs([0, 1]), 300)
      assert l.state == :confirming

      # window elapsed with no ring → mark row 0 tried, back to scanning (bail fires no skill)
      {l, [{:log, msg}]} = Logic.step(l, battle_obs([0, 1]), 700)
      assert l.state == :scanning
      assert msg =~ "não entrou em batalha"
      assert l.tried == [0]

      # scanning now SKIPS the tried row 0 and clicks the next candidate, row 1 (click+move only)
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
    test "the first fighting tick continues the rotation (confirm fired 1, fighting fires 2)" do
      {l, actions} = Logic.step(advance_to_attacking(), battle_obs([0], ring(0)), 300)
      assert actions == [{:press, "2"}]
      assert l.state == :fighting
    end

    test "while the ring holds, CYCLE the skills in order — no bar needed" do
      l = advance_to_attacking()
      obs = battle_obs([0], ring(0)) |> Map.put(:hostile, {700, 350})

      {l, [{:press, "2"}]} = Logic.step(l, obs, 1000)
      assert l.last_hostile == {700, 350}
      assert l.lost_streak == 0

      {l, [{:press, "1"}]} = Logic.step(l, battle_obs([0], ring(0)), 2000)
      {_l, [{:press, "2"}]} = Logic.step(l, battle_obs([0], ring(0)), 3000)
    end

    test "cycling NEVER stalls: it advances every tick even with no skill-bar reading at all" do
      # the old verify loop got stuck re-pressing the same key when the bar read came back empty;
      # cycling walks the order regardless, so a dropped input just comes back around next loop.
      l = advance_to_attacking()
      obs = battle_obs([0], ring(0))

      {l, [{:press, "2"}]} = Logic.step(l, obs, 1000)
      {l, [{:press, "1"}]} = Logic.step(l, obs, 1100)
      {l, [{:press, "2"}]} = Logic.step(l, obs, 1200)
      {_l, [{:press, "1"}]} = Logic.step(l, obs, 1300)
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
