defmodule Pokex.Bots.Combat.LogicTest do
  use ExUnit.Case, async: true

  alias Pokex.Bots.Combat.Logic

  defp config(overrides) do
    Enum.into(overrides, %{
      tab_confirm_ms: 700,
      tab_confirm_frames: 1,
      tab_max_attempts: 3,
      hunt_cooldown_ms: 1_500,
      skill_burst_every_ms: 300,
      fight_timeout_ms: 6_000,
      target_lost_streak: 2,
      skill_keys: ["1", "2", "3"],
      combat_skill_burst_size: 3,
      max_consecutive_failures: 5,
      hunt_probe_window_ms: 8_000
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

    {still, []} =
      Logic.step(logic, obs(locked?: true, locked_row: 0, captured_at: 5), 20)

    assert still.state == :tabbing

    {fighting, actions} =
      Logic.step(still, obs(locked?: true, locked_row: 0, captured_at: 30), 40)

    assert fighting.state == :fighting
    assert [{:press, "1"}, {:press, "2"}, {:press, "3"}] = actions
  end

  # tab() stamps tabbed_at from `now` (10), not the obs's captured_at (5): a frame at 10
  # clears the dedup gate but must fail fresh_lock?, which requires strictly AFTER.
  test "tabbing: a lock captured exactly at tabbed_at (not strictly after) must NOT confirm" do
    {logic, _} = Logic.step(hunting(0), obs(enemies: [0], captured_at: 5), 10)
    assert logic.tabbed_at == 10

    {still, actions} = Logic.step(logic, obs(locked?: true, locked_row: 0, captured_at: 10), 20)
    assert still.state == :tabbing
    assert actions == []
  end

  # TWO rows on purpose: every extra Tab CYCLES to the next enemy, which is
  # what re-Tabbing is for. With a single row it cycles nothing (own test).
  test "tabbing: window expiry re-Tabs up to max attempts, then hunt cooldown" do
    {logic, _} = Logic.step(hunting(0), obs(enemies: [0, 1], captured_at: 10), 10)

    {logic, actions} = Logic.step(logic, obs(enemies: [0, 1], captured_at: 800), 811)
    assert logic.state == :tabbing and logic.tab_attempts == 2
    assert {:tab} in actions

    {logic, _} = Logic.step(logic, obs(enemies: [0, 1], captured_at: 1_600), 1_612)
    assert logic.tab_attempts == 3
    {logic, _} = Logic.step(logic, obs(enemies: [0, 1], captured_at: 2_400), 2_413)
    assert logic.state == :hunting
    assert logic.hold_until == 2_413 + 1_500

    assert {%Logic{state: :hunting}, []} =
             Logic.step(logic, obs(enemies: [0, 1], captured_at: 2_500), 2_500)

    {logic, actions} = Logic.step(logic, obs(enemies: [0, 1], captured_at: 4_000), 4_000)
    assert logic.state == :tabbing
    assert {:tab} in actions
  end

  # Re-Tab requires EVIDENCE: frame(s) captured after the Tab with no lock. Each extra Tab
  # cycles the target to the next enemy — clock-based re-Tab with no frame (slow/stuck
  # capture) was the "keeps tabbing without focusing the first" bug with a full list.
  test "tabbing: an expired window with no post-Tab frame never re-Tabs blindly" do
    {logic, _} = Logic.step(hunting(0), obs(enemies: [0], captured_at: 10), 10)
    assert logic.state == :tabbing and logic.tab_attempts == 1

    {logic, actions} = Logic.step(logic, nil, 811)
    assert logic.state == :tabbing
    assert logic.tab_attempts == 1
    refute {:tab} in actions

    {logic, actions} = Logic.step(logic, nil, 1_900)
    assert logic.tab_attempts == 1
    refute {:tab} in actions

    {logic, actions} = Logic.step(logic, nil, 2_900)
    assert logic.state == :hunting
    assert logic.hold_until == 2_900 + 1_500
    assert Enum.any?(actions, &match?({:log, "sem frame pós-Tab" <> _}, &1))
  end

  test "tabbing: an old (pre-Tab) frame does not count as evidence" do
    {logic, _} = Logic.step(hunting(0), obs(enemies: [0], captured_at: 10), 10)

    {logic, actions} = Logic.step(logic, obs(enemies: [0], captured_at: 5), 811)
    assert logic.tab_attempts == 1
    refute {:tab} in actions
  end

  test "tabbing: with tab_confirm_frames 2, one frame does not authorize — two do" do
    {logic, _} =
      Logic.step(hunting(0, tab_confirm_frames: 2), obs(enemies: [0, 1], captured_at: 10), 10)

    {logic, actions} = Logic.step(logic, obs(enemies: [0, 1], captured_at: 750), 811)
    assert logic.tab_attempts == 1
    refute {:tab} in actions

    {logic, actions} = Logic.step(logic, obs(enemies: [0, 1], captured_at: 900), 905)
    assert logic.tab_attempts == 2
    assert {:tab} in actions
  end

  # Re-Tab exists to CYCLE targets. With one row it selects the same row again,
  # three times, for two seconds — the slowness Lucas kept reporting.
  test "one row: a single Tab is the whole question, never three" do
    {logic, _} = Logic.step(hunting(0), obs(enemies: [0], captured_at: 10), 10)
    assert logic.tab_attempts == 1

    {logic, actions} = Logic.step(logic, obs(enemies: [0], captured_at: 800), 811)
    refute {:tab} in actions
    assert logic.state == :hunting
  end

  test "rescan clears the hunt hold (fish hooked → enemy imminent)" do
    {logic, _} = Logic.step(hunting(0), obs(enemies: [0], captured_at: 10), 10)
    logic = %{logic | state: :hunting, hold_until: 99_999, tabbed_at: nil}
    logic = Logic.rescan(logic, 50)
    assert logic.hold_until == nil
  end

  test "fighting: bursts are throttled by skill_burst_every_ms" do
    logic = confirmed()

    {logic, []} = Logic.step(logic, obs(locked?: true, locked_row: 0, captured_at: 150), 150)

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

  test "after a kill, hunting PROBES with blind Tabs even when no enemy is detected" do
    logic = confirmed()
    {logic, []} = Logic.step(logic, obs(locked?: false, captured_at: 500), 500)
    {logic, _} = Logic.step(logic, obs(locked?: false, captured_at: 620), 620)
    assert logic.state == :hunting

    {probing, actions} = Logic.step(logic, obs(enemies: [], captured_at: 740), 740)
    assert probing.state == :tabbing
    assert {:tab} in actions

    {probing_nil, actions_nil} = Logic.step(logic, nil, 900)
    assert probing_nil.state == :tabbing
    assert {:tab} in actions_nil
  end

  test "the probe window expires: blind hunting goes quiet after hunt_probe_window_ms" do
    logic = confirmed()
    {logic, []} = Logic.step(logic, obs(locked?: false, captured_at: 500), 500)
    {logic, _} = Logic.step(logic, obs(locked?: false, captured_at: 620), 620)

    late = 620 + 8_000
    {expired, actions} = Logic.step(logic, obs(enemies: [], captured_at: late), late)
    assert expired.state == :hunting
    assert actions == []

    {tabbed, actions} =
      Logic.step(expired, obs(enemies: [0], captured_at: late + 100), late + 100)

    assert tabbed.state == :tabbing
    assert {:tab} in actions
  end

  test "rescan (fish hooked) opens the probe window too" do
    logic = hunting(0) |> Logic.rescan(100)

    {probing, actions} = Logic.step(logic, obs(enemies: [], captured_at: 200), 200)
    assert probing.state == :tabbing
    assert {:tab} in actions
  end

  test "fighting: the SAME frame fed twice (event + racing wake) doesn't double-count the lost streak" do
    logic = confirmed()

    {logic, []} = Logic.step(logic, obs(locked?: false, captured_at: 500), 500)
    assert logic.lost_streak == 1

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

    assert Logic.next_wake(tabbing, 110) == 300

    assert Logic.next_wake(tabbing, 700) == 10
  end

  test "next_wake: fighting polls at min(fight-timeout remainder, skill_burst_every_ms)" do
    fighting = confirmed()

    assert Logic.next_wake(fighting, 100) == 300

    assert Logic.next_wake(fighting, fighting.entered_at + 5_900) == 100
  end

  # Free hunting must poll, not sleep forever: post-kill the battle list can be non-empty
  # but pixel-static (the feed never broadcasts), so an event-only hunt would wedge.
  test "next_wake: hunting hold → hold remainder; free hunting polls at the burst cadence" do
    held = %{hunting(0) | hold_until: 2_000}
    assert Logic.next_wake(held, 500) == 1_500

    assert Logic.next_wake(hunting(0), 500) == 300
  end

  test "next_wake: idle/error need no timer (purely event-driven)" do
    {idle, _} = Logic.stop(hunting(0))
    assert Logic.next_wake(idle, 500) == nil

    error =
      Enum.reduce(1..5, hunting(0), fn _, logic ->
        {logic, _} = Logic.io_failed(logic, :boom, 0)
        logic
      end)

    assert error.state == :error
    assert Logic.next_wake(error, 500) == nil
  end

  test "next_wake: free hunting polls at 1ms floor even with skill_burst_every_ms: 0" do
    free = hunting(0, skill_burst_every_ms: 0)
    assert Logic.next_wake(free, 500) == 1
  end

  test "hunt → tab → fight → kill → free hunting polls, then a fresh frame re-Tabs" do
    logic = confirmed()

    {logic, []} = Logic.step(logic, obs(locked?: false, captured_at: 500), 500)
    assert logic.lost_streak == 1

    {logic, actions} = Logic.step(logic, obs(locked?: false, captured_at: 620), 620)
    assert logic.state == :hunting
    assert logic.counters.fights == 1
    assert Enum.any?(actions, &match?({:log, _}, &1))

    refute Logic.next_wake(logic, 620) == nil

    {logic, actions} = Logic.step(logic, obs(enemies: [0], captured_at: 900), 900)
    assert logic.state == :tabbing
    assert {:tab} in actions
  end

  test "next_wake: fighting floors the final result at 1ms even with skill_burst_every_ms: 0" do
    fighting = confirmed(skill_burst_every_ms: 0)
    assert Logic.next_wake(fighting, 100) >= 1
  end

  describe "cooldown-aware rotation (the :skill_bar fact rides on the observation)" do
    test "fires only READY skills, in skill_keys priority order" do
      logic = confirmed()

      {logic, actions} =
        Logic.step(
          logic,
          obs(locked?: true, locked_row: 0, captured_at: 400, ready_skills: ["3", "1"]),
          400
        )

      assert logic.state == :fighting
      assert actions == [{:press, "1"}, {:press, "3"}]
    end

    test "a single ready skill fires ONCE per burst, not burst_size times" do
      logic = confirmed()

      {_logic, actions} =
        Logic.step(
          logic,
          obs(locked?: true, locked_row: 0, captured_at: 400, ready_skills: ["2"]),
          400
        )

      assert actions == [{:press, "2"}]
    end

    test "fails OPEN to the full blind rotation: no reading, empty, or none-of-ours" do
      for ready <- [nil, [], ["9"]] do
        logic = confirmed()

        {_logic, actions} =
          Logic.step(
            logic,
            obs(locked?: true, locked_row: 0, captured_at: 400, ready_skills: ready),
            400
          )

        assert actions == [{:press, "1"}, {:press, "2"}, {:press, "3"}],
               "ready_skills: #{inspect(ready)} must blind-rotate"
      end
    end

    test "an observation WITHOUT the key (older world snapshot) blind-rotates too" do
      logic = confirmed()

      {_logic, actions} =
        Logic.step(logic, obs(locked?: true, locked_row: 0, captured_at: 400), 400)

      assert actions == [{:press, "1"}, {:press, "2"}, {:press, "3"}]
    end
  end

  describe "presumed scenery (an unattackable mob stops motivating Tab)" do
    # Field 2026-07-30: a SCENERY pokemon parked in the list made combat "think it was
    # fighting", pressing Tab in a loop. After N full lockless hunts those targets are
    # presumed scenery — until the list grows, shrinks, or the TTL expires.
    defp scenery_config do
      [
        tab_max_attempts: 1,
        tab_confirm_ms: 100,
        hunt_cooldown_ms: 100,
        scenery_hunts_needed: 2,
        scenery_ttl_ms: 10_000
      ]
    end

    # One COMPLETE failed hunt: Tab the target, one post-Tab frame with no lock, window
    # expired → exhausts (tab_max_attempts: 1) and gives up.
    defp failed_hunt(logic, enemies_list, t0) do
      {logic, actions} = Logic.step(logic, obs(enemies: enemies_list, captured_at: t0), t0)
      assert {:tab} in actions
      Logic.step(logic, obs(enemies: enemies_list, captured_at: t0 + 50), t0 + 150)
    end

    defp latched(enemies_list) do
      logic = hunting(0, scenery_config())
      {logic, _} = failed_hunt(logic, enemies_list, 10)
      {logic, _} = failed_hunt(logic, enemies_list, 500)
      assert logic.scenery_rows == length(enemies_list)
      logic
    end

    test "N lockless hunts promote the targets to scenery — and the hunt goes quiet" do
      logic = hunting(0, scenery_config())

      {logic, actions} = failed_hunt(logic, [0], 10)

      assert Enum.any?(actions, fn
               {:log, msg} -> msg =~ "pausa na caça (1/2)"
               _other -> false
             end)

      {logic, actions} = failed_hunt(logic, [0], 500)

      assert Enum.any?(actions, fn
               {:log, msg} -> msg =~ "cenário presumido"
               _other -> false
             end)

      assert logic.scenery_rows == 1

      {logic, actions} = Logic.step(logic, obs(enemies: [0], captured_at: 1_000), 1_000)
      assert logic.state == :hunting
      refute {:tab} in actions
    end

    # Lucas, 2026-08-10: "está muito lento!!!" — nine Tabs over ten seconds to
    # learn that the only row in the list is his OWN pokémon, which can never
    # be locked. With his pokémon out of its ball, ONE Tab settles it.
    test "the only row, with his pokémon out, is presumed his after ONE failed hunt" do
      logic = hunting(0, scenery_config())

      {logic, actions} = failed_hunt_own(logic, [0], 10)

      assert logic.scenery_rows == 1

      assert Enum.any?(actions, fn
               {:log, msg} -> msg =~ "teu pokémon está fora — presumo que é ELE"
               _other -> false
             end)
    end

    test "one row WITHOUT his pokémon out still gives up in two hunts, not three" do
      logic = hunting(0, scenery_config() ++ [scenery_hunts_needed: 3])

      {logic, _} = failed_hunt(logic, [0], 10)
      assert logic.scenery_rows == nil

      {logic, _} = failed_hunt(logic, [0], 500)
      assert logic.scenery_rows == 1
    end

    test "TWO rows keep the careful dance, even with his pokémon out" do
      logic = hunting(0, scenery_config())

      {logic, actions} = failed_hunt_own(logic, [0, 1], 10)
      assert logic.scenery_rows == nil

      assert Enum.any?(actions, fn
               {:log, msg} -> msg =~ "pausa na caça (1/2)"
               _other -> false
             end)
    end

    test "one row and his pokémon IN its ball keeps the careful dance" do
      logic = hunting(0, scenery_config())

      {logic, _actions} = failed_hunt(logic, [0], 10)
      assert logic.scenery_rows == nil
    end

    # the same failed hunt, with the "his pokémon is out" fact riding along
    defp failed_hunt_own(logic, enemies_list, t0) do
      first = obs(enemies: enemies_list, captured_at: t0, own_out?: true)
      {logic, actions} = Logic.step(logic, first, t0)
      assert {:tab} in actions

      Logic.step(
        logic,
        obs(enemies: enemies_list, captured_at: t0 + 50, own_out?: true),
        t0 + 150
      )
    end

    test "one target beyond the scenery hunts immediately" do
      logic = latched([0])

      {logic, actions} = Logic.step(logic, obs(enemies: [0, 1], captured_at: 1_000), 1_000)
      assert logic.state == :tabbing
      assert {:tab} in actions
    end

    test "the list shrinking forgets the presumption (the composition changed)" do
      logic = latched([0, 1])

      {logic, actions} = Logic.step(logic, obs(enemies: [0], captured_at: 1_000), 1_000)
      assert logic.scenery_rows == nil
      assert {:tab} in actions
    end

    test "an expired TTL probes again" do
      logic = latched([0])

      {logic, actions} = Logic.step(logic, obs(enemies: [0], captured_at: 11_000), 11_000)
      assert logic.scenery_rows == nil
      assert {:tab} in actions
    end

    test "a blind probe (empty list) never learns scenery" do
      logic = hunting(0, scenery_config()) |> Logic.rescan(0)

      {logic, actions} = Logic.step(logic, obs(enemies: [], captured_at: 10), 10)
      assert {:tab} in actions

      {logic, actions} = Logic.step(logic, obs(enemies: [], captured_at: 60), 200)

      assert logic.failed_hunts == 0
      assert logic.scenery_rows == nil

      assert Enum.any?(actions, fn
               {:log, msg} -> msg == "Tab não lockou; pausa na caça"
               _other -> false
             end)
    end

    test "a real lock resets the failed-hunt count" do
      logic = hunting(0, scenery_config())
      {logic, _} = failed_hunt(logic, [0], 10)
      assert logic.failed_hunts == 1

      {logic, _} = Logic.step(logic, obs(enemies: [0], captured_at: 500), 500)
      {logic, _} = Logic.step(logic, obs(locked?: true, locked_row: 0, captured_at: 550), 560)

      assert logic.state == :fighting
      assert logic.failed_hunts == 0
    end

    # The walked-off-mid-fight bug (Lucas, 2026-08-10): a presumption lives for
    # its whole TTL (5 min in prod), and nothing killed it when a REAL fight
    # started. One row on screen, one held lock, scenery_rows = 1 — the
    # snapshot said "0 fightable rows" and the hunt strolled away from a live
    # enemy after the clear debounce. A lock is the one fact a presumption
    # cannot argue with.
    test "a fresh lock disproves a presumption that covers the whole list" do
      logic = %{hunting(0, scenery_config()) | scenery_rows: 1, scenery_until: 100_000}

      # the post-kill probe is how a covered row gets Tabbed at all
      logic = Logic.rescan(logic, 0)
      {logic, actions} = Logic.step(logic, obs(enemies: [0], captured_at: 10), 10)
      assert logic.state == :tabbing
      assert {:tab} in actions

      {logic, _} =
        Logic.step(logic, obs(enemies: [0], locked?: true, locked_row: 0, captured_at: 20), 30)

      assert logic.state == :fighting
      assert logic.scenery_rows == nil
    end

    test "a lock with rows BEYOND the presumption only clamps it" do
      # own pokémon (the presumed row) plus a real enemy: the lock proves one
      # row fights — the other may still be the own pokémon, keep presuming it
      logic = %{hunting(0, scenery_config()) | scenery_rows: 1, scenery_until: 100_000}

      {logic, _} = Logic.step(logic, obs(enemies: [0, 1], captured_at: 10), 10)
      assert logic.state == :tabbing

      {logic, _} =
        Logic.step(
          logic,
          obs(enemies: [0, 1], locked?: true, locked_row: 1, captured_at: 20),
          30
        )

      assert logic.state == :fighting
      assert logic.scenery_rows == 1
    end

    test "a held lock keeps disproving: rows shrinking onto the presumption clear it" do
      logic = %{hunting(0, scenery_config()) | scenery_rows: 1, scenery_until: 100_000}

      {logic, _} = Logic.step(logic, obs(enemies: [0, 1], captured_at: 10), 10)

      {logic, _} =
        Logic.step(
          logic,
          obs(enemies: [0, 1], locked?: true, locked_row: 1, captured_at: 20),
          30
        )

      assert logic.scenery_rows == 1

      # the other row left; the lock is still held on the one that remains
      {logic, _} =
        Logic.step(logic, obs(enemies: [0], locked?: true, locked_row: 0, captured_at: 40), 50)

      assert logic.scenery_rows == nil
    end

    test "a config without the scenery keys keeps the old behavior, clean log" do
      logic = hunting(0, tab_max_attempts: 1, tab_confirm_ms: 100)

      {logic, actions} = failed_hunt(logic, [0], 10)

      assert logic.scenery_rows == nil
      assert logic.failed_hunts == 0

      assert Enum.any?(actions, fn
               {:log, msg} -> msg == "Tab não lockou; pausa na caça"
               _other -> false
             end)
    end
  end

  # hunting --Tab--> tabbing --locked frame--> fighting (first burst already fired at t=40)
  defp confirmed(config_overrides \\ []) do
    {logic, _} = Logic.step(hunting(0, config_overrides), obs(enemies: [0], captured_at: 10), 10)
    {logic, _} = Logic.step(logic, obs(locked?: true, locked_row: 0, captured_at: 30), 40)
    assert logic.state == :fighting
    logic
  end
end
