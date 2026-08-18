defmodule Pokex.Bots.SkillSuspectTest do
  use ExUnit.Case, async: true

  alias Pokex.Bots.SkillSuspect

  @watched ~w(3 4 6 7 8)

  defp missed_times(tally, key, times),
    do: Enum.reduce(1..times//1, tally, fn _n, acc -> SkillSuspect.missed(acc, [key]) end)

  test "says nothing about a key that never missed" do
    assert SkillSuspect.suspects(SkillSuspect.new()) == []
  end

  test "says nothing about a few misses" do
    tally = missed_times(SkillSuspect.new(), "8", 3)

    assert SkillSuspect.suspects(tally) == []
  end

  test "names a key that missed many times and was never seen cooling" do
    tally = missed_times(SkillSuspect.new(), "8", 25)

    assert SkillSuspect.suspects(tally) == ["8"]
  end

  test "clears a key the moment the bar shows it cooling" do
    tally =
      SkillSuspect.new()
      |> missed_times("8", 25)
      |> SkillSuspect.observe(~w(3 4 6 7), @watched)

    assert SkillSuspect.suspects(tally) == []
  end

  test "a cleared key stays cleared even if it misses again" do
    tally =
      SkillSuspect.new()
      |> SkillSuspect.observe(~w(3 4 6 7), @watched)
      |> missed_times("8", 25)

    assert SkillSuspect.suspects(tally) == []
  end

  test "an unreadable bar clears nobody, because it says nothing" do
    tally =
      SkillSuspect.new()
      |> missed_times("8", 25)
      |> SkillSuspect.observe(nil, @watched)

    assert SkillSuspect.suspects(tally) == ["8"]
  end

  test "a reading where every watched key is ready clears nobody" do
    tally =
      SkillSuspect.new()
      |> missed_times("8", 25)
      |> SkillSuspect.observe(@watched, @watched)

    assert SkillSuspect.suspects(tally) == ["8"]
  end

  test "names several keys when several are inverted" do
    tally = SkillSuspect.new() |> missed_times("8", 25) |> missed_times("4", 9)

    assert Enum.sort(SkillSuspect.suspects(tally)) == ["4", "8"]
  end

  test "the threshold is the caller's to raise" do
    tally = missed_times(SkillSuspect.new(), "8", 9)

    assert SkillSuspect.suspects(tally, 20) == []
    assert SkillSuspect.suspects(tally, 8) == ["8"]
  end

  # His hunt of 2026-08-18: key 8 missed 25 times, keys 6 and 7 four times each.
  # Only 8 crosses the line, and 6/7 have a different, already-handled cause.
  test "his hunt of 2026-08-18 names key 8 and nobody else" do
    tally =
      SkillSuspect.new()
      |> missed_times("8", 25)
      |> missed_times("7", 7)
      |> missed_times("6", 5)
      |> missed_times("5", 2)

    assert SkillSuspect.suspects(tally) == ["8"]
  end

  test "the explanation names the key, the count and what to do" do
    text = SkillSuspect.explain("8", 25)

    assert text =~ "tecla 8"
    assert text =~ "25x"
    assert text =~ "Recalibre"
  end
end
