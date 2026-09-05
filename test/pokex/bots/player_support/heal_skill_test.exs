defmodule Pokex.Bots.PlayerSupport.HealSkillTest do
  @moduledoc """
  The pokémon's own healing skill — the rung below the revive.

  It exists because HP falling WHILE the pokémon fights had nothing between the
  full bar and recalling it. A skill is one press, so it is the rung that works
  mid-fight.
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

    # The same rule the revive follows: one torn frame must not spend
    # anything.
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
end
