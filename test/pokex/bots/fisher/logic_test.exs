defmodule Pokex.Bots.Fisher.LogicTest do
  use ExUnit.Case, async: true
  alias Pokex.Bots.Fisher.Logic

  def config do
    %{
      water_point: {800, 400},
      neutral_point: {860, 470},
      battle_first_row: {1466, 138},
      fallback_points: [{800, 400}, {768, 400}, {832, 400}, {800, 368}, {800, 432}],
      skill_keys: ["1", "2"],
      tile_size: 32,
      tick_ms_watching: 200,
      tick_ms_fighting: 1000,
      tick_ms_default: 300,
      wait_focus_ms: 150,
      wait_after_equip_ms: 300,
      wait_assess_ms: 1500,
      wait_loot_ms: 400,
      wait_after_capture_ms: 2000,
      watch_timeout_ms: 30_000,
      fight_timeout_ms: 90_000,
      max_consecutive_failures: 3,
      hostile_scan_every: 2,
      auto_capture: true,
      glow_streak_needed: 1,
      wait_target_verify_ms: 5,
      target_locked_min_pixels: 40,
      target_lock_streak: 1,
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

  test "equipping presses shift+z then casting clicks water" do
    {l, actions} = Logic.step(advance_to(:equipping), cursor_obs(), 200)
    assert l.state == :casting
    assert actions == [{:press, "shift+z"}]

    {l, actions} = Logic.step(l, cursor_obs(), 600)
    assert l.state == :watching
    assert actions == [{:click, :left, {800, 400}}]
    assert l.counters.cycles == 1
  end

  test "watching: no glow keeps watching, glow hooks and assesses" do
    watching = advance_to(:watching)
    assert {^watching, []} = Logic.step(watching, Map.put(cursor_obs(), :glow, false), 700)

    {l, actions} = Logic.step(watching, Map.put(cursor_obs(), :glow, true), 900)
    assert l.state == :assessing
    assert actions == [{:press, "shift+z"}]
    assert l.counters.hooked == 1
    assert l.waiting_until == 900 + 1500
  end

  test "watching debounces glow: needs consecutive frames to hook" do
    cfg = Map.put(config(), :glow_streak_needed, 2)
    watching = %Logic{state: :watching, config: cfg, entered_at: 0}

    {l, actions} = Logic.step(watching, Map.put(cursor_obs(), :glow, true), 100)
    assert l.state == :watching
    assert actions == []
    assert l.glow_streak == 1

    {l, actions} = Logic.step(l, Map.put(cursor_obs(), :glow, true), 200)
    assert l.state == :assessing
    assert actions == [{:press, "shift+z"}]

    # a lone glow frame followed by a gap resets the streak
    {reset, _} = Logic.step(watching, Map.put(cursor_obs(), :glow, true), 100)
    {reset, _} = Logic.step(reset, Map.put(cursor_obs(), :glow, false), 200)
    assert reset.glow_streak == 0
  end

  test "watching times out back to casting" do
    watching = advance_to(:watching)
    {l, actions} = Logic.step(watching, Map.put(cursor_obs(), :glow, false), 600 + 30_001)
    assert l.state == :casting
    assert [{:log, _}] = actions
  end

  test "assessing: wild goes to fighting, nothing goes back to equipping" do
    watching = advance_to(:watching)
    {assessing, _} = Logic.step(watching, Map.put(cursor_obs(), :glow, true), 900)

    {fighting, []} = Logic.step(assessing, Map.put(cursor_obs(), :wild, true), 3000)
    assert fighting.state == :fighting
    refute fighting.targeted?

    {recast, [{:log, _}]} = Logic.step(assessing, Map.put(cursor_obs(), :wild, false), 3000)
    assert recast.state == :equipping
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
      last_hostile: {700, 350}
    }

    {looped, _} = Logic.step(capturing, cursor_obs(), 100)
    assert looped.state == :fighting
    refute looped.targeted?
    assert looped.select_idx == 0
  end

  describe "fighting/looting/capturing" do
    def advance_to_fighting do
      watching = advance_to(:watching)
      {assessing, _} = Logic.step(watching, Map.put(cursor_obs(), :glow, true), 900)
      {fighting, []} = Logic.step(assessing, Map.put(cursor_obs(), :wild, true), 3000)
      fighting
    end

    def advance_to_attacking do
      f = advance_to_fighting()
      {f, _} = Logic.step(f, cursor_obs(), 3100)
      {f, _} = Logic.step(f, Map.put(cursor_obs(), :target_locked, 100), 3200)
      f
    end

    test "selection re-checks the lock FIRST: an already-locked target is attacked, not re-clicked" do
      # a red ring already up when we're about to click → attack it, no click
      # (a second click on a selected row deselects it and cancels the fight)
      {l, actions} =
        Logic.step(advance_to_fighting(), Map.put(cursor_obs(), :target_locked, 100), 3100)

      assert l.targeted?
      refute l.pending_verify?
      assert actions == []
    end

    test "selection: first tick clicks battle row 0 and waits to verify" do
      {l, actions} = Logic.step(advance_to_fighting(), cursor_obs(), 3100)
      refute l.targeted?
      assert l.pending_verify?
      assert actions == [{:click, :left, {1466, 138}}]
      assert Logic.needs(l) == [:cursor, :target_locked]
    end

    test "selection: a fixed red border locks the target" do
      {l, _} = Logic.step(advance_to_fighting(), cursor_obs(), 3100)
      {l, actions} = Logic.step(l, Map.put(cursor_obs(), :target_locked, 100), 3200)
      assert l.targeted?
      assert actions == []
    end

    test "selection: only a blink (no lock) skips to the next row" do
      {l, _} = Logic.step(advance_to_fighting(), cursor_obs(), 3100)
      {l, []} = Logic.step(l, Map.put(cursor_obs(), :target_locked, 0), 3200)
      refute l.targeted?
      assert l.select_idx == 1

      {_l, actions} = Logic.step(l, cursor_obs(), 3300)
      assert actions == [{:click, :left, {1466, 168}}]
    end

    test "selection: no attackable row → recasts" do
      l =
        Enum.reduce(0..5, advance_to_fighting(), fn i, acc ->
          {acc, _} = Logic.step(acc, cursor_obs(), 3100 + i * 100)
          {acc, _} = Logic.step(acc, Map.put(cursor_obs(), :target_locked, 0), 3150 + i * 100)
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
      {still, []} = Logic.step(verifying, Map.put(cursor_obs(), :target_locked, 100), 100)
      refute still.targeted?
      assert still.pending_verify?
      assert still.target_streak == 1

      # red PERSISTED on the second check → locks
      {locked, []} = Logic.step(still, Map.put(cursor_obs(), :target_locked, 100), 500)
      assert locked.targeted?

      # but if the red DROPPED (a blink that faded) → next row, no lock
      {gone, []} = Logic.step(still, Map.put(cursor_obs(), :target_locked, 0), 500)
      refute gone.targeted?
      assert gone.select_idx == 1
    end

    test "while the red border holds, keep hitting the SAME target (cycle skills)" do
      l = advance_to_attacking()

      obs = cursor_obs() |> Map.put(:target_locked, 100) |> Map.put(:hostile, {700, 350})
      {l, actions} = Logic.step(l, obs, 4100)
      assert actions == [{:press, "1"}]
      assert l.last_hostile == {700, 350}
      assert l.lost_streak == 0

      {l, actions} = Logic.step(l, Map.put(cursor_obs(), :target_locked, 100), 5100)
      assert actions == [{:press, "2"}]

      {_l, actions} = Logic.step(l, Map.put(cursor_obs(), :target_locked, 100), 6100)
      assert actions == [{:press, "1"}]
    end

    test "a single blink of the border does NOT end the fight (debounce)" do
      cfg = config() |> Map.put(:target_lost_streak, 2)
      l = %{advance_to_attacking() | config: cfg}

      # border gone once → still fighting, just counts toward the loss
      {l, []} = Logic.step(l, Map.put(cursor_obs(), :target_locked, 0), 4100)
      assert l.state == :fighting
      assert l.targeted?
      assert l.lost_streak == 1

      # border back before the streak completes → resets, resumes attacking
      {l, [{:press, _}]} = Logic.step(l, Map.put(cursor_obs(), :target_locked, 100), 5100)
      assert l.lost_streak == 0

      # gone twice in a row → target really died → loot
      {l, []} = Logic.step(l, Map.put(cursor_obs(), :target_locked, 0), 6100)
      {l, []} = Logic.step(l, Map.put(cursor_obs(), :target_locked, 0), 7100)
      assert l.state == :looting
      assert l.counters.fights == 1
    end

    test "death → loot at last hostile one tile below → capture there" do
      l = advance_to_attacking()
      obs = cursor_obs() |> Map.put(:target_locked, 100) |> Map.put(:hostile, {700, 350})
      {l, _} = Logic.step(l, obs, 4100)

      {l, []} = Logic.step(l, Map.put(cursor_obs(), :target_locked, 0), 5100)
      assert l.state == :looting
      assert l.counters.fights == 1

      {l, actions} = Logic.step(l, cursor_obs(), 5400)
      assert actions == [{:click, :right, {700, 382}}]
      assert l.state == :capturing
      assert l.counters.loots == 1

      {l, actions} = Logic.step(l, cursor_obs(), 6000)
      assert actions == [{:capture_sequence, {700, 382}}]
      assert l.state == :equipping
      assert l.counters.captures == 1
      assert l.failures == 0
    end

    test "capturing with auto_capture disabled throws no pokeball" do
      cfg = Map.put(config(), :auto_capture, false)
      logic = %Logic{state: :capturing, config: cfg, last_hostile: {700, 350}}

      {l, actions} = Logic.step(logic, cursor_obs(), 100)
      assert l.state == :equipping
      assert [{:log, _}] = actions
      refute Enum.any?(actions, &match?({:capture_sequence, _}, &1))
      assert l.counters.captures == 0
      assert l.failures == 0
    end

    test "unknown corpse position loots through fallbacks then captures at water" do
      l = advance_to_attacking()
      {l, []} = Logic.step(l, Map.put(cursor_obs(), :target_locked, 0), 4100)
      assert l.state == :looting
      assert l.last_hostile == nil

      expected = [{800, 400}, {768, 400}, {832, 400}, {800, 368}, {800, 432}]

      l =
        for {point, i} <- Enum.with_index(expected), reduce: l do
          acc ->
            {acc, actions} = Logic.step(acc, cursor_obs(), 5000 + i * 300)
            assert actions == [{:click, :right, point}]
            acc
        end

      assert l.state == :looting
      {l, actions} = Logic.step(l, cursor_obs(), 9000)
      assert l.state == :capturing
      assert actions == []

      {l, actions} = Logic.step(l, cursor_obs(), 9400)
      assert actions == [{:capture_sequence, {800, 400}}]
      assert l.state == :equipping
    end

    test "a lock that never dies is abandoned for the next row (not a failure)" do
      l = advance_to_attacking()
      assert l.select_idx == 0

      # border still up, but the target never died within fight_timeout_ms →
      # give up THIS row and move to the next one, without counting a failure.
      {l, [{:log, _}]} = Logic.step(l, Map.put(cursor_obs(), :target_locked, 100), 3200 + 90_001)
      assert l.state == :fighting
      refute l.targeted?
      assert l.select_idx == 1
      assert l.failures == 0
    end
  end
end
