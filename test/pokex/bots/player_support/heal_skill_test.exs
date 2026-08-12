defmodule Pokex.Bots.PlayerSupport.HealSkillTest do
  @moduledoc """
  The pokémon's own healing skill — the rung above the potion.

  It exists because of a hole the potion cannot cover: a potion is a CHANNEL and
  combat cancels it, so the sip only ever happens out of battle. HP falling
  WHILE the pokémon fights had nothing between the full bar and the revive.
  """
  use ExUnit.Case, async: true

  alias Pokex.Bots.PlayerSupport.Logic

  defp input(overrides) do
    Map.merge(
      %{
        hp_pct: 40,
        prev_hp_pct: 40,
        threshold_pct: 70,
        enabled?: true,
        cooldown_ms: 3_000,
        last_heal_at: nil,
        now: 100_000
      },
      overrides
    )
  end

  describe "when the skill goes off" do
    test "below the threshold, with two reads agreeing" do
      assert Logic.heal_wanted?(input(%{hp_pct: 69, prev_hp_pct: 69}))
    end

    test "at or above the threshold it holds" do
      refute Logic.heal_wanted?(input(%{hp_pct: 70, prev_hp_pct: 40}))
    end

    # The same rule the revive and the potion follow: one torn frame must not
    # spend anything.
    test "a single low frame is not enough — the previous read must agree" do
      refute Logic.heal_wanted?(input(%{hp_pct: 30, prev_hp_pct: 90}))
      refute Logic.heal_wanted?(input(%{hp_pct: 30, prev_hp_pct: nil}))
    end

    test "an unknown reading holds, and so does the toggle being off" do
      refute Logic.heal_wanted?(input(%{hp_pct: nil}))
      refute Logic.heal_wanted?(input(%{enabled?: false}))
    end
  end

  describe "the anti-spam cooldown" do
    test "it holds inside the window and fires after it" do
      refute Logic.heal_wanted?(input(%{last_heal_at: 98_000, cooldown_ms: 3_000}))
      assert Logic.heal_wanted?(input(%{last_heal_at: 97_000, cooldown_ms: 3_000}))
    end

    test "having never fired, nothing holds it back" do
      assert Logic.heal_wanted?(input(%{last_heal_at: nil}))
    end
  end

  # The three rungs are separate decisions on the same bar, and their order is
  # the whole design: free and always available first, the expensive last.
  describe "the ladder" do
    test "at 65% only the skill wants to go; at 55% the potion joins; at 45% the revive" do
      # his real thresholds: heal 70, potion 60, rescue 50
      at = fn hp ->
        {
          Logic.heal_wanted?(input(%{hp_pct: hp, prev_hp_pct: hp, threshold_pct: 70})),
          Logic.potion_wanted?(%{
            hp_pct: hp,
            prev_hp_pct: hp,
            threshold_pct: 60,
            enabled?: true,
            cooldown_ms: 0,
            last_potion_at: nil,
            now: 0
          }),
          Logic.decide(%{
            hp_pct: hp,
            prev_hp_pct: hp,
            threshold_pct: 50,
            enabled?: true,
            cooldown_ms: 0,
            last_rescue_at: nil,
            now: 0
          })
        }
      end

      assert at.(65) == {true, false, :hold}
      assert at.(55) == {true, true, :hold}
      assert at.(45) == {true, true, :rescue}
      assert at.(80) == {false, false, :hold}
    end
  end
end
