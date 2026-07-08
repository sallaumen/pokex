defmodule Pokex.Bots.Fisher.SkillsTest do
  use ExUnit.Case, async: true
  alias Pokex.Bots.Fisher.Skills

  test "fires the first skill immediately, then paces the next to cast_ms" do
    s = Skills.new(["7", "6", "5"])

    {s, action} = Skills.decide(s, 1000, 800)
    assert action == {:press, "7"}

    # a tick INSIDE the cast window → nothing fires
    {s, action} = Skills.decide(s, 1500, 800)
    assert action == :wait

    # window elapsed → the next skill in priority order
    {s, action} = Skills.decide(s, 1800, 800)
    assert action == {:press, "6"}

    {_s, action} = Skills.decide(s, 2600, 800)
    assert action == {:press, "5"}
  end

  test "loops back to the strongest after the weakest" do
    s = Skills.new(["1", "2"])
    {s, {:press, "1"}} = Skills.decide(s, 0, 100)
    {s, {:press, "2"}} = Skills.decide(s, 100, 100)
    {_s, {:press, "1"}} = Skills.decide(s, 200, 100)
  end

  test "no skills configured → always waits, state unchanged" do
    empty = Skills.new([])
    assert {^empty, :wait} = Skills.decide(empty, 0, 100)
  end

  test "nil cast_ms disables pacing — fires on every call" do
    s = Skills.new(["1"])
    {s, {:press, "1"}} = Skills.decide(s, 0, nil)
    {_s, {:press, "1"}} = Skills.decide(s, 1, nil)
  end

  describe "decide/4 (cooldown-aware)" do
    test "nil readiness → blind rotation, same as decide/3" do
      s = Skills.new(["7", "6", "5"])
      {s, {:press, "7"}} = Skills.decide(s, 0, 100, nil)
      {_s, {:press, "6"}} = Skills.decide(s, 100, 100, nil)
    end

    test "fires the highest-priority READY skill, skipping cooldowns" do
      s = Skills.new(["7", "6", "5", "4"])
      # 7 and 6 on cooldown → fire 5 (the highest-priority ready one)
      {s, action} = Skills.decide(s, 0, 100, ["5", "4"])
      assert action == {:press, "5"}
      # next window: 7 is ready again → fire 7
      {_s, action} = Skills.decide(s, 100, 100, ["7", "5"])
      assert action == {:press, "7"}
    end

    test "none of the rotation ready → waits, no wasted press, retries immediately" do
      s = Skills.new(["7", "6"])
      assert {^s, :wait} = Skills.decide(s, 0, 100, ["1", "2"])
      # nothing cast → no pacing accrues → a skill fires the instant it's ready
      {_s, {:press, "7"}} = Skills.decide(s, 1, 100, ["7"])
    end

    test "pacing still applies with a reading" do
      s = Skills.new(["7", "6"])
      {s, {:press, "7"}} = Skills.decide(s, 0, 800, ["7", "6"])
      # within the cast window → wait even though 6 is ready
      assert {^s, :wait} = Skills.decide(s, 500, 800, ["6"])
      {_s, {:press, "6"}} = Skills.decide(s, 900, 800, ["6"])
    end
  end
end
