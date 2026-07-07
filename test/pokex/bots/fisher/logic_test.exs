defmodule Pokex.Bots.Fisher.LogicTest do
  use ExUnit.Case, async: true
  alias Pokex.Bots.Fisher.Logic

  def config do
    %{
      water_point: {800, 400},
      neutral_point: {860, 470},
      battle_first_row: {1466, 138},
      player_point: {600, 300},
      rod_key: "v",
      skill_keys: ["1", "2"],
      tile_px: 50,
      walk_step_ms: 5,
      loot_presses: 2,
      max_walk_tiles: 7,
      tick_ms_watching: 200,
      tick_ms_fighting: 1000,
      tick_ms_default: 300,
      wait_focus_ms: 150,
      wait_after_equip_ms: 300,
      wait_cast_settle_ms: nil,
      wait_assess_ms: 1500,
      wait_loot_ms: 400,
      wait_after_capture_ms: 2000,
      watch_timeout_ms: 30_000,
      fight_timeout_ms: 90_000,
      max_consecutive_failures: 3,
      hostile_scan_every: 2,
      auto_capture: true,
      glow_streak_needed: 1,
      calm_streak_needed: 1,
      line_absent_needed: 3,
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

  test "watching: settle on calm water first, THEN a bubble hooks and assesses" do
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

    # now a bubble is a real bite → hook
    {l, actions} = Logic.step(settled, Map.put(cursor_obs(), :glow, true), 900)
    assert l.state == :assessing
    assert actions == [{:press, "v"}]
    assert l.counters.hooked == 1
    assert l.waiting_until == 900 + 1500
  end

  test "watching debounces the bite: needs consecutive bubble frames to hook" do
    cfg = Map.put(config(), :glow_streak_needed, 2)
    watching = %Logic{state: :watching, config: cfg, entered_at: 0, settled?: true}

    {l, actions} = Logic.step(watching, Map.put(cursor_obs(), :glow, true), 100)
    assert l.state == :watching
    assert actions == []
    assert l.glow_streak == 1

    {l, actions} = Logic.step(l, Map.put(cursor_obs(), :glow, true), 200)
    assert l.state == :assessing
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

  test "watching: re-casts when the line never landed (no bait ring for N frames)" do
    cfg = Map.put(config(), :line_absent_needed, 3)
    # settled, calm — but line?: false means NO bait ring (a dropped equip/cast)
    watching = %Logic{state: :watching, config: cfg, entered_at: 0, settled?: true}
    absent = %{cursor: {500, 500}, glow: false, line?: false}

    {a, []} = Logic.step(watching, absent, 100)
    assert a.state == :watching
    assert a.absent_streak == 1

    {b, []} = Logic.step(a, absent, 200)
    assert b.absent_streak == 2

    {c, [{:log, msg}]} = Logic.step(b, absent, 300)
    assert c.state == :focusing
    assert msg =~ "sem isca"
  end

  test "watching: a frame with the bait ring resets the line-absent run" do
    cfg = Map.put(config(), :line_absent_needed, 3)

    watching = %Logic{
      state: :watching,
      config: cfg,
      entered_at: 0,
      settled?: true,
      absent_streak: 2
    }

    {l, []} = Logic.step(watching, %{cursor: {500, 500}, glow: false, line?: true}, 100)
    assert l.state == :watching
    assert l.absent_streak == 0
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
    assert hooked.state == :assessing
  end

  test "watching times out back to casting" do
    watching = advance_to(:watching)
    {l, actions} = Logic.step(watching, Map.put(cursor_obs(), :glow, false), 600 + 30_001)
    assert l.state == :casting
    assert [{:log, _}] = actions
  end

  test "assessing trusts the bite and always goes to fighting" do
    watching = advance_to(:watching)
    {settled, _} = Logic.step(watching, Map.put(cursor_obs(), :glow, false), 800)
    {assessing, _} = Logic.step(settled, Map.put(cursor_obs(), :glow, true), 900)

    {fighting, []} = Logic.step(assessing, cursor_obs(), 3000)
    assert fighting.state == :fighting
    refute fighting.targeted?
    assert fighting.select_idx == 0
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
    # cursor-only during the walk → the kill-corner abort stays live mid-walk
    assert Logic.needs(%Logic{state: :walking_to_loot}) == [:cursor]
    assert Logic.needs(%Logic{state: :walking_back}) == [:cursor]
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

  test "start_combat begins in fighting selection, flagged as a combat test" do
    {l, []} = Logic.start_combat(Logic.new(config()), 0)
    assert l.state == :fighting
    assert l.combat_test?
    refute l.targeted?
    assert l.select_idx == 0
  end

  test "combat test loops back to fighting after capturing (not into fishing)" do
    cfg = config() |> Map.put(:auto_capture, false)

    capturing = %Logic{
      state: :capturing,
      config: cfg,
      combat_test?: true,
      walk_taken: ["down", "right"],
      loot_offset: {1, 1}
    }

    # capture step arms the walk-back (exact retrace of the steps taken)
    {l, [{:log, _}]} = Logic.step(capturing, cursor_obs(), 100)
    assert l.state == :walking_back
    assert l.walk_plan == ["up", "left"]

    {l, [{:press, "up"}]} = Logic.step(l, cursor_obs(), 2200)
    {l, [{:press, "left"}]} = Logic.step(l, cursor_obs(), 2300)

    # back at the fishing spot → the combat test loops the fight itself
    {looped, []} = Logic.step(l, cursor_obs(), 2400)
    assert looped.state == :fighting
    refute looped.targeted?
    assert looped.select_idx == 0
  end

  describe "fighting/looting/capturing" do
    def advance_to_fighting do
      watching = advance_to(:watching)
      {settled, _} = Logic.step(watching, Map.put(cursor_obs(), :glow, false), 800)
      {assessing, _} = Logic.step(settled, Map.put(cursor_obs(), :glow, true), 900)
      {fighting, []} = Logic.step(assessing, cursor_obs(), 3000)
      fighting
    end

    def advance_to_attacking do
      f = advance_to_fighting()
      {f, _} = Logic.step(f, cursor_obs(), 3100)
      {f, _} = Logic.step(f, Map.put(cursor_obs(), :battle_lock, lock(0, 100)), 3200)
      f
    end

    test "selection re-checks the lock FIRST: an already-locked target is attacked, not re-clicked" do
      # a red ring already up when we're about to click → attack it, no click
      # (a second click on a selected row deselects it and cancels the fight)
      {l, actions} =
        Logic.step(advance_to_fighting(), Map.put(cursor_obs(), :battle_lock, lock(0, 100)), 3100)

      assert l.targeted?
      refute l.pending_verify?
      assert l.locked_row == 0
      assert actions == []
    end

    test "selection: first tick clicks battle row 0 and waits to verify" do
      {l, actions} = Logic.step(advance_to_fighting(), cursor_obs(), 3100)
      refute l.targeted?
      assert l.pending_verify?
      assert actions == [{:click, :left, {1466, 138}}]
      assert Logic.needs(l) == [:cursor, :battle_lock]
    end

    test "selection: a fixed red border locks the target" do
      {l, _} = Logic.step(advance_to_fighting(), cursor_obs(), 3100)
      {l, actions} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(0, 100)), 3200)
      assert l.targeted?
      assert l.locked_row == 0
      assert actions == []
    end

    test "selection: only a blink (no lock) skips to the next row" do
      {l, _} = Logic.step(advance_to_fighting(), cursor_obs(), 3100)
      {l, []} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(0, 0)), 3200)
      refute l.targeted?
      assert l.select_idx == 1

      {_l, actions} = Logic.step(l, cursor_obs(), 3300)
      assert actions == [{:click, :left, {1466, 168}}]
    end

    test "background red (wild names/red sprites, no fight) never fakes a lock" do
      # measured: unlocked baseline reads ~40-150 red px (Magikarp names/sprites),
      # a REAL ring reads 600-900 — the threshold must sit between them
      cfg = Map.put(config(), :target_locked_min_pixels, 350)
      f = %{advance_to_fighting() | config: cfg}

      # pre-click read sees only the baseline → NOT a fight: goes clicking rows
      {l, actions} = Logic.step(f, Map.put(cursor_obs(), :battle_lock, lock(0, 150)), 3100)
      refute l.targeted?
      assert actions == [{:click, :left, {1466, 138}}]

      # verify reads the same baseline noise → row did not lock
      {l, []} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(0, 150)), 3200)
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
      {l, _} = Logic.step(f, cursor_obs(), 3100)

      # first verify read catches the blink at full ring magnitude
      {l, []} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(0, 600)), 3200)
      refute l.targeted?
      assert l.target_streak == 1

      # blink faded → consecutive-high broken; retries then gives the row up
      {l, []} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(0, 0)), 3500)
      refute l.targeted?
      assert l.target_streak == 0
      {l, []} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(0, 0)), 3800)
      {l, []} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(0, 0)), 4100)
      refute l.targeted?
      assert l.select_idx == 1

      # a REAL ring persists across both reads → locks. select_idx is now 1, so
      # the ring must light row 1's band.
      {l, _} = Logic.step(l, cursor_obs(), 4200)
      {l, []} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(1, 620)), 4500)
      {l, []} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(1, 610)), 4800)
      assert l.targeted?
      assert l.locked_row == 1
    end

    test "selection: no attackable row → recasts" do
      l =
        Enum.reduce(0..5, advance_to_fighting(), fn i, acc ->
          {acc, _} = Logic.step(acc, cursor_obs(), 3100 + i * 100)

          {acc, _} =
            Logic.step(acc, Map.put(cursor_obs(), :battle_lock, lock(i, 0)), 3150 + i * 100)

          acc
        end)

      {l, actions} = Logic.step(l, cursor_obs(), 4000)
      assert l.state == :equipping
      assert [{:log, _}] = actions
    end

    test "target lock needs the red to PERSIST — a blink doesn't lock" do
      cfg = config() |> Map.put(:target_lock_streak, 2)

      verifying = %Logic{
        state: :fighting,
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

      {f, [{:click, :left, {1466, 138}}]} = Logic.step(f, cursor_obs(), 3100)
      assert f.pending_verify?

      # pre-ring frame (ring renders ~200ms after the click) → re-read the SAME row
      {f, []} = Logic.step(f, Map.put(cursor_obs(), :battle_lock, lock(0, 0)), 3200)
      assert f.pending_verify?
      assert f.select_idx == 0
      assert f.verify_attempts == 1
      assert f.waiting_until == 3205

      {f, []} = Logic.step(f, Map.put(cursor_obs(), :battle_lock, lock(0, 0)), 3300)
      assert f.verify_attempts == 2
      assert f.select_idx == 0

      # the ring finally drew → attack row 0; NO intermediate click ever happened
      {f, []} = Logic.step(f, Map.put(cursor_obs(), :battle_lock, lock(0, 906)), 3400)
      assert f.targeted?
      refute f.pending_verify?
      assert f.verify_attempts == 0
      assert f.select_idx == 0
      assert f.locked_row == 0
    end

    test "verify: a row that never locks (0,0,0) advances only after 3 reads" do
      cfg = Map.put(config(), :target_verify_attempts, 3)
      f = %{advance_to_fighting() | config: cfg}

      {f, [{:click, :left, {1466, 138}}]} = Logic.step(f, cursor_obs(), 3100)

      {f, []} = Logic.step(f, Map.put(cursor_obs(), :battle_lock, lock(0, 0)), 3200)
      assert f.select_idx == 0

      {f, []} = Logic.step(f, Map.put(cursor_obs(), :battle_lock, lock(0, 0)), 3300)
      assert f.select_idx == 0

      # third below-threshold read exhausts the budget → NOW advance to row 1
      {f, []} = Logic.step(f, Map.put(cursor_obs(), :battle_lock, lock(0, 0)), 3400)
      refute f.pending_verify?
      assert f.select_idx == 1
      assert f.verify_attempts == 0
      assert f.waiting_until == nil

      # next click gets a fresh attempts budget
      {f, [{:click, :left, {1466, 168}}]} = Logic.step(f, cursor_obs(), 3500)
      assert f.pending_verify?
      assert f.verify_attempts == 0
    end

    test "verify: attempts and lock streak compose" do
      cfg2 = config() |> Map.put(:target_verify_attempts, 3) |> Map.put(:target_lock_streak, 2)

      verifying = %Logic{
        state: :fighting,
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
      {l, actions} = Logic.step(l, obs, 4100)
      assert actions == [{:press, "1"}]
      assert l.last_hostile == {700, 350}
      assert l.lost_streak == 0

      {l, actions} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(0, 100)), 5100)
      assert actions == [{:press, "2"}]

      {_l, actions} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(0, 100)), 6100)
      assert actions == [{:press, "1"}]
    end

    test "a single blink of the border does NOT end the fight (debounce)" do
      cfg = config() |> Map.put(:target_lost_streak, 2)
      l = %{advance_to_attacking() | config: cfg}

      # border gone once → still fighting, just counts toward the loss
      {l, []} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(0, 0)), 4100)
      assert l.state == :fighting
      assert l.targeted?
      assert l.lost_streak == 1

      # border back before the streak completes → resets, resumes attacking
      {l, [{:press, _}]} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(0, 100)), 5100)
      assert l.lost_streak == 0

      # gone twice in a row → target really died, strip clear → go collect the corpse
      {l, []} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(0, 0)), 6100)
      {l, []} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(0, 0)), 7100)
      assert l.state == :walking_to_loot
      assert l.counters.fights == 1
    end

    test "death → walks to the corpse, space-loots, captures adjacent, walks back" do
      l = advance_to_attacking()
      obs = cursor_obs() |> Map.put(:battle_lock, lock(0, 100)) |> Map.put(:hostile, {700, 350})
      {l, _} = Logic.step(l, obs, 4100)

      # target died (strip now clear) → plan the walk ONCE from the corpse offset:
      # corpse {700,400} (hostile + tile_px below), player {600,300}, tile_px 50 →
      # dx=2, dy=2 → stop ADJACENT (one step short per axis) = ["right","down"]
      {l, []} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(0, 0)), 5100)
      assert l.state == :walking_to_loot
      assert l.counters.fights == 1
      assert l.walk_plan == ["right", "down"]
      assert l.loot_offset == {1, 1}

      # one arrow press per tick, SPACED (rapid inputs bug the pokemon out)
      {l, [{:press, "right"}]} = Logic.step(l, cursor_obs(), 5200)
      assert l.waiting_until == 5205

      {l, [{:press, "down"}]} = Logic.step(l, cursor_obs(), 5300)
      assert l.walk_taken == ["down", "right"]

      {l, []} = Logic.step(l, cursor_obs(), 5400)
      assert l.state == :looting

      # SPACE loots any adjacent corpse — no aiming needed
      {l, [{:press, "space"}]} = Logic.step(l, cursor_obs(), 5500)
      assert l.waiting_until == 5900

      {l, [{:press, "space"}]} = Logic.step(l, cursor_obs(), 6000)

      {l, []} = Logic.step(l, cursor_obs(), 6500)
      assert l.state == :capturing
      assert l.counters.loots == 1

      # pokeball click lands one tile toward the corpse (player + offset*tile_px)
      {l, [{:capture_sequence, {650, 350}}]} = Logic.step(l, cursor_obs(), 7000)
      assert l.state == :walking_back
      assert l.walk_plan == ["up", "left"]
      assert l.counters.captures == 1
      assert l.waiting_until == 9000

      # exact retrace (walk_taken reversed via opposites) → fishing spot intact
      {l, [{:press, "up"}]} = Logic.step(l, cursor_obs(), 9100)
      {l, [{:press, "left"}]} = Logic.step(l, cursor_obs(), 9200)

      {l, []} = Logic.step(l, cursor_obs(), 9300)
      assert l.state == :equipping
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
      assert l.state == :equipping
    end

    test "unknown corpse: space-loots in place, captures one tile below, no walking" do
      l = advance_to_attacking()
      assert l.last_hostile == nil

      {l, []} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(0, 0)), 4100)
      assert l.state == :walking_to_loot
      assert l.walk_plan == []
      assert l.loot_offset == nil

      {l, []} = Logic.step(l, cursor_obs(), 4200)
      assert l.state == :looting

      # each step pattern-matches the FULL action list → no arrow press anywhere
      {l, [{:press, "space"}]} = Logic.step(l, cursor_obs(), 4300)
      {l, [{:press, "space"}]} = Logic.step(l, cursor_obs(), 4800)

      {l, []} = Logic.step(l, cursor_obs(), 5300)
      assert l.state == :capturing

      # unknown offset → capture one tile below the (centered) player
      {l, [{:capture_sequence, {600, 350}}]} = Logic.step(l, cursor_obs(), 5800)
      assert l.state == :walking_back
      assert l.walk_plan == []

      {l, []} = Logic.step(l, cursor_obs(), 8000)
      assert l.state == :equipping
    end

    test "a corpse farther than max_walk_tiles is treated as unknown (bad read)" do
      l = advance_to_attacking()
      obs = cursor_obs() |> Map.put(:battle_lock, lock(0, 100)) |> Map.put(:hostile, {1200, 300})
      {l, _} = Logic.step(l, obs, 4100)

      # dx = round((1200 - 600) / 50) = 12 > max_walk_tiles 7 → loot in place
      {l, []} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(0, 0)), 5100)
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
        Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(0, 100)), 3200 + 90_001)

      assert l.state == :fighting
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
        Logic.step(l, Map.put(cursor_obs(), :battle_lock, [0, 0, 0, 700, 0, 0]), 4100)

      assert l.state == :fighting
      refute l.targeted?
      assert l.select_idx == 0
      assert l.locked_row == nil
      assert l.counters.fights == 1
    end

    test "a neighbor's late ring during verify does NOT commit the wrong row" do
      cfg = Map.put(config(), :target_verify_attempts, 3)
      f = %{advance_to_fighting() | config: cfg}

      {f, [{:click, :left, {1466, 138}}]} = Logic.step(f, cursor_obs(), 3100)

      # row 1 lights up (a neighbor's ring), row 0 stays dark across every verify —
      # the machine must NEVER commit row 0 to a row-1 ring, and NEVER click again.
      {f, []} = Logic.step(f, Map.put(cursor_obs(), :battle_lock, lock(1, 906)), 3200)
      refute f.targeted?
      assert f.select_idx == 0

      {f, []} = Logic.step(f, Map.put(cursor_obs(), :battle_lock, lock(1, 906)), 3300)
      refute f.targeted?
      assert f.select_idx == 0

      # budget exhausted → move to row 1; no second attackable click was ever emitted
      {f, []} = Logic.step(f, Map.put(cursor_obs(), :battle_lock, lock(1, 906)), 3400)
      refute f.targeted?
      assert f.select_idx == 1
    end

    test "selection never clicks a second attackable row while another row is locked" do
      # row 2 is already locked (a live prior selection) but select_idx is 0 —
      # the pre-click clause attributes to select_idx, so it clicks row 0, NOT
      # commits row 2. Clicking a fresh attackable row would aggro a 2nd monster.
      {l, actions} =
        Logic.step(advance_to_fighting(), Map.put(cursor_obs(), :battle_lock, lock(2, 600)), 3100)

      refute l.targeted?
      assert l.locked_row == nil
      assert actions == [{:click, :left, {1466, 138}}]
    end

    # -- KILL-ALL loop (both modes) -----------------------------------------

    test "after a kill, if another row still locks, re-selects the next target (normal mode)" do
      l = advance_to_attacking()

      # mob 1 (row 0) dies but row 1 still locks → reselect, DO NOT loot yet
      {l, [{:log, _}]} =
        Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(1, 610)), 4100)

      assert l.state == :fighting
      refute l.targeted?
      assert l.select_idx == 0
      assert l.locked_row == nil
      assert l.counters.fights == 1

      # selection re-scans: row 0 is now empty → verify miss walks toward row 1
      {l, [{:click, :left, {1466, 138}}]} = Logic.step(l, cursor_obs(), 4200)
      {l, []} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(0, 0)), 4300)
      assert l.select_idx == 1

      # row 1 locks → commit mob 2
      {l, [{:click, :left, {1466, 168}}]} = Logic.step(l, cursor_obs(), 4400)
      {l, []} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(1, 610)), 4500)
      assert l.targeted?
      assert l.locked_row == 1

      # mob 2 dies and the strip is now CLEAR → finally loot
      {l, []} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(0, 0)), 5500)
      assert l.state == :walking_to_loot
      assert l.counters.fights == 2
    end

    test "kill-all stops when the strip is clear on the death tick (loots straight away)" do
      l = advance_to_attacking()

      # committed row 0 dies with NO other row locked → straight to loot, no reselect
      {l, []} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(0, 0)), 4100)
      assert l.state == :walking_to_loot
      assert l.counters.fights == 1
    end

    test "combat_test mode also kills all before looting, then loops to :fighting once" do
      cfg = Map.put(config(), :auto_capture, false)
      l = %{advance_to_attacking() | combat_test?: true, config: cfg}

      # mob 1 dies, row 1 still locks → reselect (no loot)
      {l, [{:log, _}]} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(1, 610)), 4100)
      assert l.state == :fighting
      assert l.counters.fights == 1
      assert l.counters.loots == 0

      # commit + kill mob 2, strip clear → loot chain runs ONCE
      {l, [{:click, :left, {1466, 138}}]} = Logic.step(l, cursor_obs(), 4200)
      {l, []} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(0, 0)), 4300)
      {l, [{:click, :left, {1466, 168}}]} = Logic.step(l, cursor_obs(), 4400)
      {l, []} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(1, 610)), 4500)
      assert l.targeted?

      {l, []} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(0, 0)), 5500)
      assert l.state == :walking_to_loot
      assert l.counters.fights == 2

      # unknown corpse (last_hostile nil) → loot in place → capture → walk_back empty.
      # wait_loot_ms is 400, so each space press is spaced past that window.
      {l, []} = Logic.step(l, cursor_obs(), 5600)
      assert l.state == :looting
      {l, [{:press, "space"}]} = Logic.step(l, cursor_obs(), 5700)
      {l, [{:press, "space"}]} = Logic.step(l, cursor_obs(), 6200)
      {l, []} = Logic.step(l, cursor_obs(), 6700)
      assert l.state == :capturing
      assert l.counters.loots == 1

      {l, [{:log, _}]} = Logic.step(l, cursor_obs(), 7200)
      assert l.state == :walking_back

      # walk_back is empty (loot in place) → combat_test loops back to fighting, ONCE.
      # wait_after_capture_ms is 2000, so the loop step is past that window.
      {looped, []} = Logic.step(l, cursor_obs(), 9300)
      assert looped.state == :fighting
      refute looped.targeted?
      assert looped.select_idx == 0
      assert looped.counters.loots == 1
    end
  end
end
