defmodule Pokex.Bots.Fisher.SkillsTest do
  use ExUnit.Case, async: true
  alias Pokex.Bots.Fisher.Skills

  test "picks the highest-priority READY skill, skipping cooldowns" do
    assert Skills.pick(["7", "6", "5", "4"], ["5", "4"]) == "5"
    assert Skills.pick(["7", "6", "5", "4"], ["7", "5"]) == "7"
  end

  test "the verify loop: a skill still ready is picked AGAIN; once it fires, advance" do
    # pressed "7" last tick but the input dropped — it's still ready → pick it again
    assert Skills.pick(["7", "6"], ["7", "6"]) == "7"
    # "7" landed (now on cooldown, not ready) → the next tick advances to "6"
    assert Skills.pick(["7", "6"], ["6"]) == "6"
  end

  test "nothing in the rotation ready → nil (auto-attack; retry next tick)" do
    assert Skills.pick(["7", "6"], ["1", "2"]) == nil
    assert Skills.pick(["7", "6"], []) == nil
  end

  test "no skill-bar reading (nil) → press the strongest key blindly" do
    assert Skills.pick(["7", "6", "5"], nil) == "7"
  end

  test "no skills configured → nil" do
    assert Skills.pick([], ["1"]) == nil
    assert Skills.pick([], nil) == nil
  end
end
