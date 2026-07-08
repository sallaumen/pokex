defmodule Pokex.Bots.Combat.LogicTest do
  use ExUnit.Case, async: true
  alias Pokex.Bots.Combat.Logic

  def config do
    %{
      neutral_point: {860, 470},
      battle_first_row: {1466, 138},
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
      wait_target_verify_ms: 5,
      target_locked_min_pixels: 40,
      target_lock_streak: 1,
      target_lost_streak: 1,
      # pinned at 1 = single-shot verify (today's behavior); the attempts tests
      # override to 3 explicitly, so every pre-existing selection test's
      # one-miss-advances semantics stays valid.
      target_verify_attempts: 1,
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

  # A rows-length battle_lock list with `px` red in `row`, 0 elsewhere (6 rows to
  # match config()). `lock(list)` passes an explicit per-row list through.
  def lock(row, px), do: for(i <- 0..5, do: if(i == row, do: px, else: 0))
  def lock(list) when is_list(list), do: list

  test "start begins scanning the battle list" do
    {l, []} = Logic.start(Logic.new(config()), 0)
    assert l.state == :scanning
    refute l.targeted?
    assert l.select_idx == 0
  end

  test "scanning clicks battle row 0 and moves the cursor off to verify" do
    logic = %Logic{state: :scanning, config: config(), select_idx: 0}
    {l, actions} = Logic.step(logic, cursor_obs(), 100)
    assert l.pending_verify?
    assert actions == [{:click, :left, {1466, 138}}, {:move, {860, 470}}]
  end

  test "scanning SKIPS an empty row (≈no red) without clicking it" do
    cfg = Map.put(config(), :scan_min_red_to_click, 5)
    logic = %Logic{state: :scanning, config: cfg, select_idx: 0}
    # row 0 is empty (0 red), row 1 has a creature → skip row 0, no click, no verify
    obs =
      cursor_obs()
      |> Map.put(:battle_lock, [0, 100, 0, 0, 0, 0])
      |> Map.put(:battle_creatures?, true)

    {l, actions} = Logic.step(logic, obs, 100)
    assert l.select_idx == 1
    assert actions == []
    refute l.pending_verify?
  end

  # Minor gap flagged in the Task 2 review: io_failed/3 was ported (as fail/3's
  # public entry) but never exercised by the ported combat test suite. The
  # driver (Combat.Worker) calls this when Body.perform/3 returns {:error, _}.
  # Below max_consecutive_failures it must recover into :scanning (not :error),
  # bumping counters.failures and failures, so the worker keeps ticking.
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

  describe "battle idle gate (battle_creatures?)" do
    def scanning do
      {l, []} = Logic.start(Logic.new(config()), 0)
      l
    end

    test "battle_creatures?: false emits ZERO mouse actions and stays in :scanning (no click)" do
      # The transition tick is allowed exactly one {:log, _} entry (see the next
      # test) — but never a click/move/press: the idle gate must free the mouse
      # for fishing on the very first tick it sees an empty Battle list.
      {l, actions} =
        Logic.step(scanning(), Map.put(cursor_obs(), :battle_creatures?, false), 100)

      refute Enum.any?(actions, &match?({:click, _, _}, &1))
      refute Enum.any?(actions, &match?({:move, _}, &1))
      refute Enum.any?(actions, &match?({:press, _}, &1))
      assert l.state == :scanning
      refute l.targeted?

      # a SECOND idle tick (past the transition) really is a hard [] — no log,
      # no mouse actions of any kind whatsoever.
      {l2, actions2} =
        Logic.step(l, Map.put(cursor_obs(), :battle_creatures?, false), 200)

      assert actions2 == []
      assert l2.state == :scanning
      refute l2.targeted?
    end

    test "the idle log fires exactly once on entering idle, then goes silent on later idle ticks" do
      obs = Map.put(cursor_obs(), :battle_creatures?, false)

      {l, actions} = Logic.step(scanning(), obs, 100)
      assert actions == [{:log, "Battle vazia — combate parado (mouse livre pra pesca)"}]
      assert l.scan_idle?

      # second tick, still empty → no repeated log
      {l, actions} = Logic.step(l, obs, 200)
      assert actions == []
      assert l.scan_idle?

      # third tick, still empty → still silent
      {_l, actions} = Logic.step(l, obs, 300)
      assert actions == []
    end

    test "battle_creatures?: true behaves exactly like the key being absent (existing click behavior)" do
      explicit_true = Map.put(cursor_obs(), :battle_creatures?, true)
      key_absent = cursor_obs()

      {l_true, actions_true} = Logic.step(scanning(), explicit_true, 100)
      {l_absent, actions_absent} = Logic.step(scanning(), key_absent, 100)

      assert actions_true == [{:click, :left, {1466, 138}}, {:move, {860, 470}}]
      assert actions_absent == actions_true
      assert l_true.pending_verify? == l_absent.pending_verify?
      refute l_true.targeted?
      refute l_absent.targeted?
    end

    test "recovering from idle (creature appears) clears scan_idle? and resumes clicking" do
      idle_obs = Map.put(cursor_obs(), :battle_creatures?, false)
      {l, [{:log, _}]} = Logic.step(scanning(), idle_obs, 100)
      assert l.scan_idle?

      present_obs = Map.put(cursor_obs(), :battle_creatures?, true)
      {l, actions} = Logic.step(l, present_obs, 200)

      refute l.scan_idle?
      assert actions == [{:click, :left, {1466, 138}}, {:move, {860, 470}}]
    end
  end

  describe "fighting/looting/capturing" do
    def advance_to_fighting do
      {l, []} = Logic.start(Logic.new(config()), 0)
      l
    end

    def advance_to_attacking do
      f = advance_to_fighting()
      {f, _} = Logic.step(f, cursor_obs(), 100)
      {f, _} = Logic.step(f, Map.put(cursor_obs(), :battle_lock, lock(0, 100)), 200)
      f
    end

    test "selection re-checks the lock FIRST: an already-locked target is attacked, not re-clicked" do
      # a red ring already up when we're about to click → attack it, no click
      # (a second click on a selected row deselects it and cancels the fight)
      {l, actions} =
        Logic.step(advance_to_fighting(), Map.put(cursor_obs(), :battle_lock, lock(0, 100)), 100)

      assert l.targeted?
      refute l.pending_verify?
      assert l.locked_row == 0
      assert actions == []
    end

    test "selection: first tick clicks battle row 0 and waits to verify" do
      {l, actions} = Logic.step(advance_to_fighting(), cursor_obs(), 100)
      refute l.targeted?
      assert l.pending_verify?
      assert actions == [{:click, :left, {1466, 138}}, {:move, {860, 470}}]
      assert Logic.needs(l, 100) == [:cursor, :battle_lock, :battle_creatures?]
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

    test "selection: a fixed red border locks the target" do
      {l, _} = Logic.step(advance_to_fighting(), cursor_obs(), 100)
      {l, actions} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(0, 100)), 200)
      assert l.targeted?
      assert l.locked_row == 0
      assert actions == []
    end

    test "selection: only a blink (no lock) skips to the next row" do
      {l, _} = Logic.step(advance_to_fighting(), cursor_obs(), 100)
      {l, []} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(0, 0)), 200)
      refute l.targeted?
      assert l.select_idx == 1

      {_l, actions} = Logic.step(l, cursor_obs(), 300)
      assert actions == [{:click, :left, {1466, 168}}, {:move, {860, 470}}]
    end

    test "background red (wild names/red sprites, no fight) never fakes a lock" do
      # measured: unlocked baseline reads ~40-150 red px (Magikarp names/sprites),
      # a REAL ring reads 600-900 — the threshold must sit between them
      cfg = Map.put(config(), :target_locked_min_pixels, 350)
      f = %{advance_to_fighting() | config: cfg}

      # pre-click read sees only the baseline → NOT a fight: goes clicking rows
      {l, actions} = Logic.step(f, Map.put(cursor_obs(), :battle_lock, lock(0, 150)), 100)
      refute l.targeted?
      assert actions == [{:click, :left, {1466, 138}}, {:move, {860, 470}}]

      # verify reads the same baseline noise → row did not lock
      {l, []} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(0, 150)), 200)
      refute l.targeted?
    end

    test "clicking our OWN pokemon blinks red once — persistence filters it out" do
      # blink: one ring-magnitude read that fades before the second check;
      # a real lock persists. target_lock_streak 2 = two consecutive high reads.
      cfg =
        config()
        |> Map.put(:target_locked_min_pixels, 350)
        |> Map.put(:target_lock_streak, 2)
        |> Map.put(:target_verify_attempts, 3)

      f = %{advance_to_fighting() | config: cfg}
      {l, _} = Logic.step(f, cursor_obs(), 100)

      # first verify read catches the blink at full ring magnitude
      {l, []} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(0, 600)), 200)
      refute l.targeted?
      assert l.target_streak == 1

      # blink faded → consecutive-high broken; retries then gives the row up
      {l, []} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(0, 0)), 500)
      refute l.targeted?
      assert l.target_streak == 0
      {l, []} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(0, 0)), 800)
      {l, []} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(0, 0)), 1100)
      refute l.targeted?
      assert l.select_idx == 1

      # a REAL ring persists across both reads → locks. select_idx is now 1, so
      # the ring must light row 1's band.
      {l, _} = Logic.step(l, cursor_obs(), 1200)
      {l, []} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(1, 620)), 1500)
      {l, []} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(1, 610)), 1800)
      assert l.targeted?
      assert l.locked_row == 1
    end

    test "selection: no attackable row loops back to scanning (no recast)" do
      l =
        Enum.reduce(0..5, advance_to_fighting(), fn i, acc ->
          {acc, _} = Logic.step(acc, cursor_obs(), 100 + i * 100)

          {acc, _} =
            Logic.step(acc, Map.put(cursor_obs(), :battle_lock, lock(i, 0)), 150 + i * 100)

          acc
        end)

      {l, actions} = Logic.step(l, cursor_obs(), 1000)
      assert l.state == :scanning
      assert l.select_idx == 0
      assert [{:log, _}] = actions
    end

    test "target lock needs the red to PERSIST — a blink doesn't lock" do
      cfg = config() |> Map.put(:target_lock_streak, 2)

      verifying = %Logic{
        state: :scanning,
        config: cfg,
        targeted?: false,
        pending_verify?: true,
        select_idx: 0
      }

      # first high check: not locked yet, keeps verifying
      {still, []} = Logic.step(verifying, Map.put(cursor_obs(), :battle_lock, lock(0, 100)), 100)
      refute still.targeted?
      assert still.pending_verify?
      assert still.target_streak == 1

      # red PERSISTED on the second check → locks
      {locked, []} = Logic.step(still, Map.put(cursor_obs(), :battle_lock, lock(0, 100)), 500)
      assert locked.targeted?
      assert locked.locked_row == 0

      # but if the red DROPPED (a blink that faded) → next row, no lock
      {gone, []} = Logic.step(still, Map.put(cursor_obs(), :battle_lock, lock(0, 0)), 500)
      refute gone.targeted?
      assert gone.select_idx == 1
    end

    test "verify: a late ring (0,0,906) locks row 0 with zero extra clicks" do
      cfg = Map.put(config(), :target_verify_attempts, 3)
      f = %{advance_to_fighting() | config: cfg}

      {f, [{:click, :left, {1466, 138}}, {:move, {860, 470}}]} = Logic.step(f, cursor_obs(), 100)
      assert f.pending_verify?

      # pre-ring frame (ring renders ~200ms after the click) → re-read the SAME row
      {f, []} = Logic.step(f, Map.put(cursor_obs(), :battle_lock, lock(0, 0)), 200)
      assert f.pending_verify?
      assert f.select_idx == 0
      assert f.verify_attempts == 1
      assert f.waiting_until == 205

      {f, []} = Logic.step(f, Map.put(cursor_obs(), :battle_lock, lock(0, 0)), 300)
      assert f.verify_attempts == 2
      assert f.select_idx == 0

      # the ring finally drew → attack row 0; NO intermediate click ever happened
      {f, []} = Logic.step(f, Map.put(cursor_obs(), :battle_lock, lock(0, 906)), 400)
      assert f.targeted?
      refute f.pending_verify?
      assert f.verify_attempts == 0
      assert f.select_idx == 0
      assert f.locked_row == 0
    end

    test "verify: a row that never locks (0,0,0) advances only after 3 reads" do
      cfg = Map.put(config(), :target_verify_attempts, 3)
      f = %{advance_to_fighting() | config: cfg}

      {f, [{:click, :left, {1466, 138}}, {:move, {860, 470}}]} = Logic.step(f, cursor_obs(), 100)

      {f, []} = Logic.step(f, Map.put(cursor_obs(), :battle_lock, lock(0, 0)), 200)
      assert f.select_idx == 0

      {f, []} = Logic.step(f, Map.put(cursor_obs(), :battle_lock, lock(0, 0)), 300)
      assert f.select_idx == 0

      # third below-threshold read exhausts the budget → NOW advance to row 1
      {f, []} = Logic.step(f, Map.put(cursor_obs(), :battle_lock, lock(0, 0)), 400)
      refute f.pending_verify?
      assert f.select_idx == 1
      assert f.verify_attempts == 0
      assert f.waiting_until == nil

      # next click gets a fresh attempts budget
      {f, [{:click, :left, {1466, 168}}, {:move, {860, 470}}]} = Logic.step(f, cursor_obs(), 500)
      assert f.pending_verify?
      assert f.verify_attempts == 0
    end

    test "verify: attempts and lock streak compose" do
      cfg2 = config() |> Map.put(:target_verify_attempts, 3) |> Map.put(:target_lock_streak, 2)

      verifying = %Logic{
        state: :scanning,
        config: cfg2,
        targeted?: false,
        pending_verify?: true,
        select_idx: 0
      }

      # a miss consumes an attempt
      {l, []} = Logic.step(verifying, Map.put(cursor_obs(), :battle_lock, lock(0, 0)), 100)
      assert l.verify_attempts == 1

      # a red read feeds the lock streak and consumes NO attempt
      {l, []} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(0, 100)), 200)
      assert l.target_streak == 1
      refute l.targeted?

      {l, []} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(0, 100)), 300)
      assert l.targeted?
    end

    test "while the red border holds, keep hitting the SAME target (cycle skills)" do
      l = advance_to_attacking()

      obs = cursor_obs() |> Map.put(:battle_lock, lock(0, 100)) |> Map.put(:hostile, {700, 350})
      {l, actions} = Logic.step(l, obs, 1000)
      assert actions == [{:press, "1"}]
      assert l.last_hostile == {700, 350}
      assert l.lost_streak == 0

      {l, actions} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(0, 100)), 2000)
      assert actions == [{:press, "2"}]

      {_l, actions} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(0, 100)), 3000)
      assert actions == [{:press, "1"}]
    end

    test "skills are PACED to skill_cast_ms — a tick inside the window presses nothing" do
      l = advance_to_attacking()
      obs = Map.put(cursor_obs(), :battle_lock, lock(0, 100))

      # first attacking tick fires the strongest skill immediately
      {l, [{:press, "1"}]} = Logic.step(l, obs, 1000)

      # a tick 200ms later is INSIDE the 500ms cast window → no press, still fighting
      {l, []} = Logic.step(l, obs, 1200)
      assert l.targeted?
      assert l.state == :fighting

      # once the window elapses (600ms > 500) → the next skill
      {_l, [{:press, "2"}]} = Logic.step(l, obs, 1600)
    end

    test "a single blink of the border does NOT end the fight (debounce)" do
      cfg = config() |> Map.put(:target_lost_streak, 2)
      l = %{advance_to_attacking() | config: cfg}

      # border gone once → still fighting, just counts toward the loss
      {l, []} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(0, 0)), 1000)
      assert l.state == :fighting
      assert l.targeted?
      assert l.lost_streak == 1

      # border back before the streak completes → resets, resumes attacking
      {l, [{:press, _}]} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(0, 100)), 2000)
      assert l.lost_streak == 0

      # gone twice in a row → target really died, strip clear → go collect the corpse
      {l, []} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(0, 0)), 3000)
      {l, []} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(0, 0)), 4000)
      assert l.state == :walking_to_loot
      assert l.counters.fights == 1
    end

    test "death → walks to the corpse, space-loots, captures adjacent, walks back, loops to scanning" do
      l = advance_to_attacking()
      obs = cursor_obs() |> Map.put(:battle_lock, lock(0, 100)) |> Map.put(:hostile, {700, 350})
      {l, _} = Logic.step(l, obs, 1000)

      # target died (strip now clear) → plan the walk ONCE from the corpse offset:
      # corpse {700,400} (hostile + tile_px below), player {600,300}, tile_px 50 →
      # dx=2, dy=2 → stop ADJACENT (one step short per axis) = ["right","down"]
      {l, []} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(0, 0)), 2000)
      assert l.state == :walking_to_loot
      assert l.counters.fights == 1
      assert l.walk_plan == ["right", "down"]
      assert l.loot_offset == {1, 1}

      # one arrow press per tick, SPACED (rapid inputs bug the pokemon out)
      {l, [{:press, "right"}]} = Logic.step(l, cursor_obs(), 2100)
      assert l.waiting_until == 2105

      {l, [{:press, "down"}]} = Logic.step(l, cursor_obs(), 2200)
      assert l.walk_taken == ["down", "right"]

      {l, []} = Logic.step(l, cursor_obs(), 2300)
      assert l.state == :looting

      # SPACE loots any adjacent corpse — no aiming needed
      {l, [{:press, "space"}]} = Logic.step(l, cursor_obs(), 2400)
      assert l.waiting_until == 2800

      {l, [{:press, "space"}]} = Logic.step(l, cursor_obs(), 2900)

      {l, []} = Logic.step(l, cursor_obs(), 3400)
      assert l.state == :capturing
      assert l.counters.loots == 1

      # pokeball click lands one tile toward the corpse (player + offset*tile_px)
      {l, [{:capture_sequence, {650, 350}}]} = Logic.step(l, cursor_obs(), 3900)
      assert l.state == :walking_back
      assert l.walk_plan == ["up", "left"]
      assert l.counters.captures == 1
      assert l.waiting_until == 5900

      # exact retrace (walk_taken reversed via opposites) → back at the start
      {l, [{:press, "up"}]} = Logic.step(l, cursor_obs(), 6000)
      {l, [{:press, "left"}]} = Logic.step(l, cursor_obs(), 6100)

      # walk_back empty → loops back to scanning to re-check for more enemies
      {l, []} = Logic.step(l, cursor_obs(), 6200)
      assert l.state == :scanning
      refute l.targeted?
      assert l.select_idx == 0
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
      assert l.failures == 0

      {l, []} = Logic.step(l, cursor_obs(), 2200)
      assert l.state == :scanning
    end

    test "unknown corpse: space-loots in place, captures one tile below, no walking" do
      l = advance_to_attacking()
      assert l.last_hostile == nil

      {l, []} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(0, 0)), 1000)
      assert l.state == :walking_to_loot
      assert l.walk_plan == []
      assert l.loot_offset == nil

      {l, []} = Logic.step(l, cursor_obs(), 1100)
      assert l.state == :looting

      # each step pattern-matches the FULL action list → no arrow press anywhere
      {l, [{:press, "space"}]} = Logic.step(l, cursor_obs(), 1200)
      {l, [{:press, "space"}]} = Logic.step(l, cursor_obs(), 1700)

      {l, []} = Logic.step(l, cursor_obs(), 2200)
      assert l.state == :capturing

      # unknown offset → capture one tile below the (centered) player
      {l, [{:capture_sequence, {600, 350}}]} = Logic.step(l, cursor_obs(), 2700)
      assert l.state == :walking_back
      assert l.walk_plan == []

      {l, []} = Logic.step(l, cursor_obs(), 4900)
      assert l.state == :scanning
    end

    test "a corpse farther than max_walk_tiles is treated as unknown (bad read)" do
      l = advance_to_attacking()
      obs = cursor_obs() |> Map.put(:battle_lock, lock(0, 100)) |> Map.put(:hostile, {1200, 300})
      {l, _} = Logic.step(l, obs, 1000)

      # dx = round((1200 - 600) / 50) = 12 > max_walk_tiles 7 → loot in place
      {l, []} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(0, 0)), 2000)
      assert l.state == :walking_to_loot
      assert l.walk_plan == []
      assert l.loot_offset == nil
    end

    test "kill corner aborts a walk in progress" do
      walking = %Logic{state: :walking_to_loot, config: config(), walk_plan: ["right", "down"]}

      {l, [{:log, _}]} = Logic.step(walking, %{cursor: {5, 5}}, 100)
      assert l.state == :idle
    end

    test "a lock that never dies is abandoned for the next row (not a failure)" do
      l = advance_to_attacking()
      assert l.select_idx == 0

      # border still up, but the target never died within fight_timeout_ms →
      # give up THIS row and move to the next one, without counting a failure.
      {l, [{:log, _}]} =
        Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(0, 100)), 200 + 90_001)

      assert l.state == :scanning
      refute l.targeted?
      assert l.select_idx == 1
      assert l.locked_row == nil
      assert l.failures == 0
    end

    # -- per-row attribution (the bug fixes) --------------------------------

    test "attacking reads only the COMMITTED row's band — a sibling ring never fakes 'alive'" do
      l = advance_to_attacking()
      assert l.locked_row == 0

      # committed row 0 is dark (dead) but row 3 is blazing → the committed target
      # is DEAD; the aggregate would have wrongly kept 'attacking'. target_lost_streak
      # is 1, and row 3 still locks → KILL-ALL reselects for the survivor.
      {l, [{:log, _}]} =
        Logic.step(l, Map.put(cursor_obs(), :battle_lock, [0, 0, 0, 700, 0, 0]), 1000)

      assert l.state == :scanning
      refute l.targeted?
      assert l.select_idx == 0
      assert l.locked_row == nil
      assert l.counters.fights == 1
    end

    test "a neighbor's late ring during verify does NOT commit the wrong row" do
      cfg = Map.put(config(), :target_verify_attempts, 3)
      f = %{advance_to_fighting() | config: cfg}

      {f, [{:click, :left, {1466, 138}}, {:move, {860, 470}}]} = Logic.step(f, cursor_obs(), 100)

      # row 1 lights up (a neighbor's ring), row 0 stays dark across every verify —
      # the machine must NEVER commit row 0 to a row-1 ring, and NEVER click again.
      {f, []} = Logic.step(f, Map.put(cursor_obs(), :battle_lock, lock(1, 906)), 200)
      refute f.targeted?
      assert f.select_idx == 0

      {f, []} = Logic.step(f, Map.put(cursor_obs(), :battle_lock, lock(1, 906)), 300)
      refute f.targeted?
      assert f.select_idx == 0

      # budget exhausted → move to row 1; no second attackable click was ever emitted
      {f, []} = Logic.step(f, Map.put(cursor_obs(), :battle_lock, lock(1, 906)), 400)
      refute f.targeted?
      assert f.select_idx == 1
    end

    test "selection never clicks a second attackable row while another row is locked" do
      # row 2 is already locked (a live prior selection) but select_idx is 0 —
      # the pre-click clause attributes to select_idx, so it clicks row 0, NOT
      # commits row 2. Clicking a fresh attackable row would aggro a 2nd monster.
      {l, actions} =
        Logic.step(advance_to_fighting(), Map.put(cursor_obs(), :battle_lock, lock(2, 600)), 100)

      refute l.targeted?
      assert l.locked_row == nil
      assert actions == [{:click, :left, {1466, 138}}, {:move, {860, 470}}]
    end

    # -- KILL-ALL loop --------------------------------------------------------

    test "after a kill, if another row still locks, re-selects the next target" do
      l = advance_to_attacking()

      # mob 1 (row 0) dies but row 1 still locks → reselect, DO NOT loot yet
      {l, [{:log, _}]} =
        Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(1, 610)), 1000)

      assert l.state == :scanning
      refute l.targeted?
      assert l.select_idx == 0
      assert l.locked_row == nil
      assert l.counters.fights == 1

      # selection re-scans: row 0 is now empty → verify miss walks toward row 1
      {l, [{:click, :left, {1466, 138}}, {:move, {860, 470}}]} = Logic.step(l, cursor_obs(), 1100)
      {l, []} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(0, 0)), 1200)
      assert l.select_idx == 1

      # row 1 locks → commit mob 2
      {l, [{:click, :left, {1466, 168}}, {:move, {860, 470}}]} = Logic.step(l, cursor_obs(), 1300)
      {l, []} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(1, 610)), 1400)
      assert l.targeted?
      assert l.locked_row == 1

      # mob 2 dies and the strip is now CLEAR → finally loot
      {l, []} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(0, 0)), 2400)
      assert l.state == :walking_to_loot
      assert l.counters.fights == 2
    end

    test "kill-all stops when the strip is clear on the death tick (loots straight away)" do
      l = advance_to_attacking()

      # committed row 0 dies with NO other row locked → straight to loot, no reselect
      {l, []} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(0, 0)), 1000)
      assert l.state == :walking_to_loot
      assert l.counters.fights == 1
    end

    test "after full cycle completes, loops back to scanning to check for more enemies" do
      cfg = Map.put(config(), :auto_capture, false)
      l = %{advance_to_attacking() | config: cfg}

      # mob 1 dies, row 1 still locks → reselect (no loot)
      {l, [{:log, _}]} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(1, 610)), 1000)
      assert l.state == :scanning
      assert l.counters.fights == 1
      assert l.counters.loots == 0

      # commit + kill mob 2, strip clear → loot chain runs ONCE
      {l, [{:click, :left, {1466, 138}}, {:move, {860, 470}}]} = Logic.step(l, cursor_obs(), 1100)
      {l, []} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(0, 0)), 1200)
      {l, [{:click, :left, {1466, 168}}, {:move, {860, 470}}]} = Logic.step(l, cursor_obs(), 1300)
      {l, []} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(1, 610)), 1400)
      assert l.targeted?

      {l, []} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(0, 0)), 2400)
      assert l.state == :walking_to_loot
      assert l.counters.fights == 2

      # unknown corpse (last_hostile nil) → loot in place → capture → walk_back empty.
      # wait_loot_ms is 400, so each space press is spaced past that window.
      {l, []} = Logic.step(l, cursor_obs(), 2500)
      assert l.state == :looting
      {l, [{:press, "space"}]} = Logic.step(l, cursor_obs(), 2600)
      {l, [{:press, "space"}]} = Logic.step(l, cursor_obs(), 3100)
      {l, []} = Logic.step(l, cursor_obs(), 3600)
      assert l.state == :capturing
      assert l.counters.loots == 1

      {l, [{:log, _}]} = Logic.step(l, cursor_obs(), 4100)
      assert l.state == :walking_back

      # walk_back is empty (loot in place) → always loops back to scanning.
      # wait_after_capture_ms is 2000, so the loop step is past that window.
      {looped, []} = Logic.step(l, cursor_obs(), 6200)
      assert looped.state == :scanning
      refute looped.targeted?
      assert looped.select_idx == 0
      assert looped.counters.loots == 1
    end
  end
end
