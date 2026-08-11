defmodule Pokex.Bots.SkillReceiptTest do
  @moduledoc """
  Did the skill actually go off?

  Pressing a key proves nothing: the window can be unfocused, the gate shut,
  the mana short, the client busy. In fishing a missed skill cost a few
  seconds. Hunting is different — "é mais difícil e mais perigoso as coisas"
  (Lucas, 2026-08-11) — and the one that matters most is the crowd control
  that puts everything to sleep BEFORE his pokémon leaves the field.

  The receipt is the cooldown: a skill that fired is no longer ready.
  """
  use ExUnit.Case, async: true

  alias Pokex.Bots.SkillReceipt

  # ready_keys as the skill-bar feed publishes them
  defp bar(keys), do: keys

  describe "reading the receipt" do
    test "ready before, not ready after: it fired" do
      assert %{fired: ["1"], missed: [], unknown: []} =
               SkillReceipt.check(bar(["1", "2"]), bar(["2"]), ["1"])
    end

    test "ready before AND after: the press did not land" do
      assert %{fired: [], missed: ["1"], unknown: []} =
               SkillReceipt.check(bar(["1", "2"]), bar(["1", "2"]), ["1"])
    end

    # A key already cooling was never going to fire — the press was a no-op in
    # game, and calling that a miss would send the caller chasing a ghost.
    test "cooling before: not a miss, just nothing to press" do
      assert %{fired: [], missed: [], unknown: ["1"]} =
               SkillReceipt.check(bar(["2"]), bar(["2"]), ["1"])
    end

    test "several keys at once, each judged on its own" do
      before = bar(["1", "2", "3"])
      later = bar(["2"])

      assert %{fired: fired, missed: missed} = SkillReceipt.check(before, later, ["1", "2", "3"])
      assert fired == ["1", "3"]
      assert missed == ["2"]
    end
  end

  # The bar is a READING, and readings fail. Every unknown must stay unknown:
  # a caller that treats "I could not see" as "it fired" is exactly the caller
  # that strips the field with the mobs wide awake.
  describe "when the bar cannot be read" do
    test "no reading before or after is unknown, never fired and never missed" do
      assert %{fired: [], missed: [], unknown: ["1"]} = SkillReceipt.check(nil, bar([]), ["1"])
      assert %{fired: [], missed: [], unknown: ["1"]} = SkillReceipt.check(bar(["1"]), nil, ["1"])
      assert %{fired: [], missed: [], unknown: ["1"]} = SkillReceipt.check(nil, nil, ["1"])
    end

    test "an empty key list has nothing to say" do
      assert %{fired: [], missed: [], unknown: []} = SkillReceipt.check(bar(["1"]), bar([]), [])
    end
  end

  describe "the verdict a caller acts on" do
    test "confirmed when everything asked for fired" do
      assert SkillReceipt.verdict(%{fired: ["1", "2"], missed: [], unknown: []}) == :confirmed
    end

    test "missed wins over unknown — something provably did not happen" do
      assert SkillReceipt.verdict(%{fired: [], missed: ["1"], unknown: ["2"]}) == {:missed, ["1"]}
    end

    test "nothing fired and nothing is known: unconfirmed, not confirmed" do
      assert SkillReceipt.verdict(%{fired: [], missed: [], unknown: ["1"]}) == :unconfirmed
    end

    # Half a stun is not a stun, but it IS something — the caller decides what
    # to do about it, and needs to know which half is missing.
    test "some fired, some unknown: unconfirmed, with what is in doubt" do
      assert SkillReceipt.verdict(%{fired: ["1"], missed: [], unknown: ["2"]}) == :unconfirmed
    end

    test "nothing was asked for at all is confirmed — vacuously, and honestly" do
      assert SkillReceipt.verdict(%{fired: [], missed: [], unknown: []}) == :confirmed
    end
  end
end
