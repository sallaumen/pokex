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
      # 1 = a single empty read ends the fight; the debounce test overrides to 2.
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
  def enemy_obs(rows), do: Map.put(cursor_obs(), :enemy_rows, rows)

  def scanning do
    {l, []} = Logic.start(Logic.new(config()), 0)
    l
  end

  # scanning → click the enemy at row 0 → fighting, targeted, locked_row 0 (no skill fired yet).
  def advance_to_attacking, do: elem(Logic.step(scanning(), enemy_obs([0]), 100), 0)

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
    assert woke.entered_at == 500

    fighting = %Logic{state: :fighting, config: config(), targeted?: true, locked_row: 2}
    assert Logic.rescan(fighting, 500) == fighting
  end

  test "io_failed below max_consecutive_failures recovers into :scanning" do
    logic = %{Logic.new(config()) | state: :fighting, failures: 0}
    {l, [{:log, reason}]} = Logic.io_failed(logic, :boom, 100)

    assert l.state == :scanning
    assert l.failures == 1
    assert l.counters.failures == 1
    assert l.error == nil
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

  test "scanning needs the enemy rows (no lock ring)" do
    {l, []} = Logic.start(Logic.new(config()), 0)
    assert Logic.needs(l, 100) == [:cursor, :enemy_rows]
  end

  test "fighting reads :ready_skills only when a skill is about to fire" do
    base = %Logic{state: :fighting, targeted?: true, config: config()}

    # no skill fired yet → the next tick will cast → read the skill bar
    assert :ready_skills in Logic.needs(%{base | skills: nil}, 1000)

    # just fired, still inside the pacing window → skip the (unused) skill-bar read
    fired = %{base | skills: %Pokex.Bots.Fisher.Skills{order: ["1"], last_cast_at: 1000}}
    refute :ready_skills in Logic.needs(fired, 1000 + 100)
    # window elapsed (>= skill_cast_ms 500) → read again to fire the ready skill
    assert :ready_skills in Logic.needs(fired, 1000 + 500)
  end

  # -- scanning: idle gate ----------------------------------------------------

  describe "scanning idle gate (no enemy)" do
    test "no enemy emits ZERO mouse actions and stays in :scanning" do
      {l, actions} = Logic.step(scanning(), enemy_obs([]), 100)

      refute Enum.any?(actions, &match?({:click, _, _}, &1))
      refute Enum.any?(actions, &match?({:move, _}, &1))
      refute Enum.any?(actions, &match?({:press, _}, &1))
      assert l.state == :scanning
      refute l.targeted?

      {l2, actions2} = Logic.step(l, enemy_obs([]), 200)
      assert actions2 == []
      assert l2.state == :scanning
    end

    test "the idle log fires exactly once on entering idle, then goes silent" do
      obs = enemy_obs([])

      {l, [{:log, msg}]} = Logic.step(scanning(), obs, 100)
      assert msg =~ "sem inimigos"
      assert l.scan_idle?

      {l, []} = Logic.step(l, obs, 200)
      assert l.scan_idle?
      {_l, []} = Logic.step(l, obs, 300)
    end

    test "an absent enemy_rows key behaves like an empty list (idle)" do
      {l, [{:log, _}]} = Logic.step(scanning(), cursor_obs(), 100)
      assert l.state == :scanning
      refute l.targeted?
    end
  end

  # -- scanning: attack the enemy ---------------------------------------------

  describe "scanning attacks the enemy directly" do
    test "clicks the topmost enemy row and commits to fighting immediately (no verify)" do
      {l, actions} = Logic.step(scanning(), enemy_obs([0]), 100)

      assert actions == [{:click, :left, {1466, 138}}, {:move, {860, 470}}]
      assert l.state == :fighting
      assert l.targeted?
      assert l.locked_row == 0
      refute l.scan_idle?
    end

    test "picks the TOPMOST enemy when several rows are attackable" do
      {l, actions} = Logic.step(scanning(), enemy_obs([2, 4]), 100)

      assert actions == [{:click, :left, {1466, 198}}, {:move, {860, 470}}]
      assert l.locked_row == 2
    end

    test "the enemy row can be ANY row — the own-pokemon row is already excluded upstream" do
      # enemy_rows never contains the player's pokemon (the sensor subtracts the pokeball
      # row), so combat trusts it: an enemy at row 3 (own pokemon at row 0) is clicked, and
      # row 0 is never touched.
      {l, actions} = Logic.step(scanning(), enemy_obs([3]), 100)
      assert actions == [{:click, :left, {1466, 228}}, {:move, {860, 470}}]
      assert l.locked_row == 3
    end
  end

  # -- fighting ---------------------------------------------------------------

  describe "fighting" do
    test "the first fighting tick fires the strongest skill immediately" do
      {l, actions} = Logic.step(advance_to_attacking(), enemy_obs([0]), 200)
      assert actions == [{:press, "1"}]
      assert l.state == :fighting
      assert l.targeted?
    end

    test "while the enemy is present, keep hitting it (skill rotation, paced)" do
      l = advance_to_attacking()

      obs = enemy_obs([0]) |> Map.put(:hostile, {700, 350})
      {l, [{:press, "1"}]} = Logic.step(l, obs, 1000)
      assert l.last_hostile == {700, 350}
      assert l.lost_streak == 0

      {l, [{:press, "2"}]} = Logic.step(l, enemy_obs([0]), 2000)
      {_l, [{:press, "1"}]} = Logic.step(l, enemy_obs([0]), 3000)
    end

    test "skills are PACED to skill_cast_ms — a tick inside the window presses nothing" do
      l = advance_to_attacking()
      obs = enemy_obs([0])

      {l, [{:press, "1"}]} = Logic.step(l, obs, 1000)
      # 200ms later, inside the 500ms window → no press, still fighting
      {l, []} = Logic.step(l, obs, 1200)
      assert l.state == :fighting
      # window elapsed (600 > 500) → next skill
      {_l, [{:press, "2"}]} = Logic.step(l, obs, 1600)
    end

    test "fires the highest-priority READY skill when the skill bar is read" do
      l = advance_to_attacking()
      # ready_skills says only "2" is off cooldown → fire it, not blind "1"
      obs = enemy_obs([0]) |> Map.put(:ready_skills, ["2"])
      {_l, [{:press, "2"}]} = Logic.step(l, obs, 1000)
    end

    test "a single empty read past the streak ends the fight → loot" do
      cfg = Map.put(config(), :target_lost_streak, 2)
      l = %{advance_to_attacking() | config: cfg}

      # enemy gone once → still fighting, counts toward the loss
      {l, []} = Logic.step(l, enemy_obs([]), 1000)
      assert l.state == :fighting
      assert l.lost_streak == 1

      # enemy back before the streak completes → resets, resumes attacking
      {l, [{:press, _}]} = Logic.step(l, enemy_obs([0]), 2000)
      assert l.lost_streak == 0

      # gone twice in a row → dead, strip clear → collect the corpse
      {l, []} = Logic.step(l, enemy_obs([]), 3000)
      {l, []} = Logic.step(l, enemy_obs([]), 4000)
      assert l.state == :walking_to_loot
      assert l.counters.fights == 1
    end

    test "a lock that never dies is abandoned by the fight timeout (rescan, not a failure)" do
      l = advance_to_attacking()

      {l, [{:log, _}]} = Logic.step(l, enemy_obs([0]), 100 + 90_001)
      assert l.state == :scanning
      refute l.targeted?
      assert l.locked_row == nil
      assert l.failures == 0
    end
  end

  # -- kill-all: re-select the next survivor ----------------------------------

  describe "kill-all (multiple enemies)" do
    test "a STEADY enemy set keeps hitting the same target (no reselect)" do
      # two enemies at rows 1 and 2 (own pokemon at row 0 excluded) → attack the topmost (1).
      {l, _} = Logic.step(scanning(), enemy_obs([1, 2]), 100)
      assert l.locked_row == 1
      assert l.enemy_count == 2

      # count unchanged (both still alive) → keep firing at row 1, no re-scan.
      {l, [{:press, _}]} = Logic.step(l, enemy_obs([1, 2]), 1000)
      assert l.state == :fighting
      assert l.locked_row == 1
    end

    test "a kill (count drops, enemies remain) counts the fight and re-scans for the survivor" do
      # attacking with two enemies; one dies → the count drops from 2 to 1. Even if the
      # survivor re-packs into our old row index, bouncing through :scanning re-clicks it
      # FRESH, so we never fire at a dead-then-reused row.
      {l, _} = Logic.step(scanning(), enemy_obs([1, 2]), 100)
      assert l.enemy_count == 2

      {l, [{:log, _}]} = Logic.step(l, enemy_obs([1]), 1000)
      assert l.state == :scanning
      refute l.targeted?
      assert l.locked_row == nil
      assert l.counters.fights == 1

      # the next scanning tick clicks the topmost survivor fresh
      {l, actions} = Logic.step(l, enemy_obs([1]), 1100)
      assert l.state == :fighting
      assert l.locked_row == 1
      assert actions == [{:click, :left, {1466, 168}}, {:move, {860, 470}}]
    end

    test "a NEW enemy appearing mid-fight does not switch targets, but is tracked" do
      {l, _} = Logic.step(scanning(), enemy_obs([1]), 100)
      assert l.enemy_count == 1

      # a second enemy appears (count 1 → 2) → keep hitting our target, but track the count
      {l, [{:press, _}]} = Logic.step(l, enemy_obs([1, 2]), 1000)
      assert l.locked_row == 1
      assert l.enemy_count == 2

      # now one dies (2 → 1) → detected as a kill → re-scan
      {l, [{:log, _}]} = Logic.step(l, enemy_obs([1]), 2000)
      assert l.state == :scanning
      assert l.counters.fights == 1
    end

    test "when the strip is clear the fight is over → loot, not reselect" do
      l = advance_to_attacking()
      {l, []} = Logic.step(l, enemy_obs([]), 1000)
      assert l.state == :walking_to_loot
      assert l.counters.fights == 1
    end
  end

  # -- loot / capture / walk (model-independent chain) ------------------------

  describe "loot / capture / walk-back" do
    test "death → walks to corpse, space-loots, captures adjacent, walks back, loops to scanning" do
      l = advance_to_attacking()
      obs = enemy_obs([0]) |> Map.put(:hostile, {700, 350})
      {l, _} = Logic.step(l, obs, 1000)
      assert l.last_hostile == {700, 350}

      # target died (enemy_rows now []) → plan the walk ONCE from the corpse offset:
      # corpse {700,400} (hostile + tile_px below), player {600,300}, tile_px 50 →
      # dx=2, dy=2 → stop ADJACENT (one step short per axis) = ["right","down"]
      {l, []} = Logic.step(l, enemy_obs([]), 2000)
      assert l.state == :walking_to_loot
      assert l.counters.fights == 1
      assert l.walk_plan == ["right", "down"]
      assert l.loot_offset == {1, 1}

      {l, [{:press, "right"}]} = Logic.step(l, cursor_obs(), 2100)
      assert l.waiting_until == 2105

      {l, [{:press, "down"}]} = Logic.step(l, cursor_obs(), 2200)
      assert l.walk_taken == ["down", "right"]

      {l, []} = Logic.step(l, cursor_obs(), 2300)
      assert l.state == :looting

      {l, [{:press, "space"}]} = Logic.step(l, cursor_obs(), 2400)
      assert l.waiting_until == 2800

      {l, [{:press, "space"}]} = Logic.step(l, cursor_obs(), 2900)

      {l, []} = Logic.step(l, cursor_obs(), 3400)
      assert l.state == :capturing
      assert l.counters.loots == 1

      {l, [{:capture_sequence, {650, 350}}]} = Logic.step(l, cursor_obs(), 3900)
      assert l.state == :walking_back
      assert l.walk_plan == ["up", "left"]
      assert l.counters.captures == 1
      assert l.waiting_until == 5900

      {l, [{:press, "up"}]} = Logic.step(l, cursor_obs(), 6000)
      {l, [{:press, "left"}]} = Logic.step(l, cursor_obs(), 6100)

      {l, []} = Logic.step(l, cursor_obs(), 6200)
      assert l.state == :scanning
      refute l.targeted?
      assert l.failures == 0
    end

    test "capturing with auto_capture disabled throws no pokeball" do
      cfg = Map.put(config(), :auto_capture, false)
      logic = %Logic{state: :capturing, config: cfg, loot_offset: {0, 1}}

      {l, actions} = Logic.step(logic, cursor_obs(), 100)
      assert l.state == :walking_back
      assert [{:log, _}] = actions
      refute Enum.any?(actions, &match?({:capture_sequence, _}, &1))
      assert l.counters.captures == 0

      {l, []} = Logic.step(l, cursor_obs(), 2200)
      assert l.state == :scanning
    end

    test "unknown corpse: space-loots in place, captures one tile below, no walking" do
      l = advance_to_attacking()
      assert l.last_hostile == nil

      {l, []} = Logic.step(l, enemy_obs([]), 1000)
      assert l.state == :walking_to_loot
      assert l.walk_plan == []
      assert l.loot_offset == nil

      {l, []} = Logic.step(l, cursor_obs(), 1100)
      assert l.state == :looting

      {l, [{:press, "space"}]} = Logic.step(l, cursor_obs(), 1200)
      {l, [{:press, "space"}]} = Logic.step(l, cursor_obs(), 1700)

      {l, []} = Logic.step(l, cursor_obs(), 2200)
      assert l.state == :capturing

      {l, [{:capture_sequence, {600, 350}}]} = Logic.step(l, cursor_obs(), 2700)
      assert l.state == :walking_back
      assert l.walk_plan == []

      {l, []} = Logic.step(l, cursor_obs(), 4900)
      assert l.state == :scanning
    end

    test "a corpse farther than max_walk_tiles is treated as unknown (bad read)" do
      l = advance_to_attacking()
      obs = enemy_obs([0]) |> Map.put(:hostile, {1200, 300})
      {l, _} = Logic.step(l, obs, 1000)

      # dx = round((1200 - 600) / 50) = 12 > max_walk_tiles 7 → loot in place
      {l, []} = Logic.step(l, enemy_obs([]), 2000)
      assert l.state == :walking_to_loot
      assert l.walk_plan == []
      assert l.loot_offset == nil
    end

    test "kill corner aborts a walk in progress" do
      walking = %Logic{state: :walking_to_loot, config: config(), walk_plan: ["right", "down"]}
      {l, [{:log, _}]} = Logic.step(walking, %{cursor: {5, 5}}, 100)
      assert l.state == :idle
    end
  end
end
