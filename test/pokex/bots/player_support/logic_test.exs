defmodule Pokex.Bots.PlayerSupport.LogicTest do
  use ExUnit.Case, async: true
  alias Pokex.Bots.PlayerSupport.Logic

  # prev_hp_pct defaults to 0 (previous read agreed it's low) so the threshold/cooldown tests
  # exercise their own rule; the consecutive-reads guard has its own dedicated tests.
  defp input(overrides) do
    %{
      hp_pct: 100,
      prev_hp_pct: 0,
      threshold_pct: 50,
      enabled?: true,
      cooldown_ms: 60_000,
      last_rescue_at: nil,
      now: 10_000
    }
    |> Map.merge(Map.new(overrides))
  end

  describe "decide/1" do
    test "holds while HP is at or above the rescue threshold" do
      assert Logic.decide(input(hp_pct: 100)) == :hold
      assert Logic.decide(input(hp_pct: 50)) == :hold
    end

    test "rescues the first time HP drops below the threshold" do
      assert Logic.decide(input(hp_pct: 49)) == :rescue
      assert Logic.decide(input(hp_pct: 10)) == :rescue
    end

    test "an unknown HP reading never rescues (fail-safe: don't burn a revive on nil)" do
      assert Logic.decide(input(hp_pct: nil)) == :hold
    end

    test "the toggle disables the rescue entirely" do
      assert Logic.decide(input(hp_pct: 5, enabled?: false)) == :hold
    end

    test "the protection cooldown blocks a second combo within the window" do
      assert Logic.decide(input(hp_pct: 5, last_rescue_at: 10_000, now: 40_000)) == :hold
    end

    test "the combo fires again once the cooldown has fully elapsed" do
      assert Logic.decide(input(hp_pct: 5, last_rescue_at: 10_000, now: 70_000)) == :rescue
      assert Logic.decide(input(hp_pct: 5, last_rescue_at: 10_000, now: 200_000)) == :rescue
    end

    test "one garbage frame never burns a revive: the PREVIOUS read must agree it's low" do
      assert Logic.decide(input(hp_pct: 5, prev_hp_pct: nil)) == :hold
      assert Logic.decide(input(hp_pct: 5, prev_hp_pct: 90)) == :hold
      assert Logic.decide(input(hp_pct: 5, prev_hp_pct: 40)) == :rescue
    end
  end

  describe "potion_wanted?/1" do
    defp potion_input(overrides) do
      %{
        hp_pct: 100,
        prev_hp_pct: 0,
        threshold_pct: 70,
        enabled?: true,
        cooldown_ms: 10_000,
        last_potion_at: nil,
        now: 50_000
      }
      |> Map.merge(Map.new(overrides))
    end

    test "wants a potion the first time HP drops below the potion threshold" do
      assert Logic.potion_wanted?(potion_input(hp_pct: 69))
      assert Logic.potion_wanted?(potion_input(hp_pct: 30))
    end

    test "holds at or above the threshold, on nil HP, or when disabled" do
      refute Logic.potion_wanted?(potion_input(hp_pct: 70))
      refute Logic.potion_wanted?(potion_input(hp_pct: 100))
      refute Logic.potion_wanted?(potion_input(hp_pct: nil))
      refute Logic.potion_wanted?(potion_input(hp_pct: 30, enabled?: false))
    end

    test "the heal-channel cooldown blocks a second sip within the window" do
      refute Logic.potion_wanted?(potion_input(hp_pct: 30, last_potion_at: 45_000, now: 50_000))
      assert Logic.potion_wanted?(potion_input(hp_pct: 30, last_potion_at: 40_000, now: 50_000))
    end

    test "one garbage frame never chugs a potion: the previous read must agree" do
      refute Logic.potion_wanted?(potion_input(hp_pct: 30, prev_hp_pct: nil))
      refute Logic.potion_wanted?(potion_input(hp_pct: 30, prev_hp_pct: 95))
      assert Logic.potion_wanted?(potion_input(hp_pct: 30, prev_hp_pct: 60))
    end
  end

  describe "combo/1" do
    test "builds the recall → max-revive-on-photo → release → recentre sequence" do
      config = %{
        rescue_key: "q",
        max_revive_key: "shift+q",
        photo_point: {70, 934},
        neutral_point: {1457, 666},
        step_ms: 40
      }

      assert Logic.combo(config) == [
               {:press, "q"},
               {:wait, 40},
               {:move, {70, 934}},
               {:wait, 40},
               {:press, "shift+q"},
               {:wait, 40},
               {:press, "q"},
               {:wait, 40},
               {:move, {1457, 666}}
             ]
    end

    test "with stun_steps: the stun comes before the recall, in the same atomic list" do
      config = %{
        rescue_key: "q",
        max_revive_key: "shift+q",
        photo_point: {70, 934},
        neutral_point: {1457, 666},
        step_ms: 40,
        stun_steps: [{:press, "1"}, {:wait, 500}, {:press, "2"}]
      }

      assert Logic.combo(config) == [
               {:press, "1"},
               {:wait, 500},
               {:press, "2"},
               {:wait, 40},
               {:press, "q"},
               {:wait, 40},
               {:move, {70, 934}},
               {:wait, 40},
               {:press, "shift+q"},
               {:wait, 40},
               {:press, "q"},
               {:wait, 40},
               {:move, {1457, 666}}
             ]
    end

    test "empty stun_steps adds no glue — sequence identical to the direct mode" do
      config = %{
        rescue_key: "q",
        max_revive_key: "shift+q",
        photo_point: {70, 934},
        neutral_point: {1457, 666},
        step_ms: 40
      }

      assert Logic.combo(Map.put(config, :stun_steps, [])) == Logic.combo(config)
    end
  end

  describe "stun_prefix/2" do
    @stun_steps [{:skill, "1"}, {:wait, 500}, {:skill, "2"}, {:wait, 500}]

    test "unavailable reading (nil): presses everything blind — never holds the rescue" do
      assert Logic.stun_prefix(@stun_steps, nil) ==
               {[{:press, "1"}, {:wait, 500}, {:press, "2"}, {:wait, 500}], []}
    end

    test "only READY skills go in; the ones on cooldown are skipped and named" do
      assert Logic.stun_prefix(@stun_steps, ["2", "3"]) ==
               {[{:wait, 500}, {:press, "2"}, {:wait, 500}], ["1"]}
    end

    test "none ready: only the waits remain, every skill named in the skip" do
      assert {actions, ["1", "2"]} = Logic.stun_prefix(@stun_steps, [])
      refute Enum.any?(actions, &match?({:press, _}, &1))
    end

    # Eligibility filters earlier; this is the seatbelt for a combo changing between the
    # selection and the firing.
    test "a step that is not skill/wait is ignored — it never crashes a rescue" do
      steps = [{:swap_member, "Jigglypuff"}, {:skill, "1"}]
      assert Logic.stun_prefix(steps, nil) == {[{:press, "1"}], []}
    end
  end

  # "se o pokémon morrer naturalmente, a gente tem que saber lidar com o fluxo"
  # (Lucas, 2026-08-14). A dead pokémon has no bar to read — the window itself
  # changes shape — so death is read from the TRAJECTORY of the last bar seen.
  describe "reading a death off the vanished bar" do
    defp faint(overrides) do
      Map.merge(
        %{
          enabled?: true,
          unreadable_streak: 2,
          last_seen_hp: 10,
          faint_below_pct: 35,
          cooldown_ms: 15_000,
          last_faint_at: nil,
          now: 0
        },
        Map.new(overrides)
      )
    end

    test "a low bar that vanishes for two reads is a death" do
      assert Logic.fainted?(faint([]))
    end

    test "one unreadable frame is never a death" do
      refute Logic.fainted?(faint(unreadable_streak: 1))
    end

    # The covered-window case: a healthy bar does not stop being healthy
    # because someone put a browser in front of the game.
    test "a HEALTHY bar that vanishes is a window, not a death" do
      refute Logic.fainted?(faint(last_seen_hp: 100))
      refute Logic.fainted?(faint(last_seen_hp: 36))
    end

    # Never seeing it alive is "no pokémon out", which is not something to
    # spend a revive on.
    test "with no live reading behind it, nothing fires" do
      refute Logic.fainted?(faint(last_seen_hp: nil))
    end

    test "the toggle and the cooldown both hold it" do
      refute Logic.fainted?(faint(enabled?: false))
      refute Logic.fainted?(faint(last_faint_at: 0, now: 14_999))
      assert Logic.fainted?(faint(last_faint_at: 0, now: 15_000))
    end
  end

  describe "the fallen combo" do
    defp fallen_config do
      %{
        rescue_key: "q",
        max_revive_key: "shift+q",
        photo_point: {40, 620},
        neutral_point: {500, 500},
        step_ms: 40
      }
    end

    # He is already inside the ball: opening with a recall would be pressing Q
    # at nothing, and the first press has to be the revive itself.
    test "it starts on the portrait and revives — never a recall" do
      assert [{:move, {40, 620}} | rest] = Logic.fallen_combo(fallen_config())
      assert [{:wait, 40}, {:press, "shift+q"} | _] = rest
    end

    test "the release comes after the revive, and the cursor goes home" do
      combo = Logic.fallen_combo(fallen_config())

      revive = Enum.find_index(combo, &(&1 == {:press, "shift+q"}))
      release = Enum.find_index(combo, &(&1 == {:press, "q"}))

      assert revive < release
      assert List.last(combo) == {:move, {500, 500}}
    end

    # The low-HP combo pays a stun and a settle because a pokémon is still out
    # there tanking. Here nobody is: the shortest path IS the safety.
    test "it is shorter than the low-HP combo — no stun, no settle" do
      fallen = Logic.fallen_combo(fallen_config())

      refute Enum.any?(fallen, &match?({:wait, ms} when ms > 40, &1))
      assert length(fallen) < length(Logic.combo(fallen_config()))
    end
  end
end
