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
end
