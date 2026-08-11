defmodule Pokex.Bots.Cavebot.HandsReadTest do
  @moduledoc """
  What his hands say while he records.

  "Quando eu aperto Shift+3 é pq eu já terminei de matar tudo, quando eu aperto
  shift+1 é por que vou matar monstro" (Lucas, 2026-08-11) — boundaries told by
  the hand that fights, with the skills he used in between.
  """
  use ExUnit.Case, async: true

  alias Pokex.Bots.Cavebot.HandsRead
  alias Pokex.Rig.Mac.Commands

  defp press(key, at, shift? \\ false) do
    {:ok, code} = Commands.keycode(key)
    %{code: code, shift?: shift?, at: at}
  end

  test "shift+1 opens the fight and shift+3 closes it, with its length" do
    {state, opened} = HandsRead.read(HandsRead.new(), [press("1", 1_000, true)])
    assert opened.fight_started?
    assert opened.fight_ms == nil

    {_state, closed} = HandsRead.read(state, [press("3", 9_500, true)])
    assert closed.fight_ms == 8_500
  end

  test "shift+3 with no fight open says nothing — the recording may start mid-hunt" do
    {_state, reading} = HandsRead.read(HandsRead.new(), [press("3", 500, true)])

    assert reading.fight_ms == nil
    refute reading.fight_started?
  end

  # The same physical key, opposite meanings: 1 is a skill, shift+1 is "I am
  # going to kill". Reading one as the other would put attack mode in a combo.
  test "a MODE change is never mistaken for a skill" do
    {_state, reading} =
      HandsRead.read(HandsRead.new(), [press("1", 10, true), press("3", 20, true)])

    assert reading.combo == []
  end

  test "the skills he pressed come out in order" do
    events = [press("4", 10), press("1", 20), press("3", 30), press("5", 40)]
    {_state, reading} = HandsRead.read(HandsRead.new(), events)

    assert reading.combo == ["4", "1", "3", "5"]
  end

  describe "the huddle he actually waits" do
    test "from parking the pokémon to the FIRST skill" do
      state = HandsRead.parked(HandsRead.new(), 1_000)

      {state, reading} = HandsRead.read(state, [press("1", 4_800), press("3", 4_900)])
      assert reading.gather_ms == 3_800

      # only the first one counts: the rest of the combo is not a huddle
      {_state, more} = HandsRead.read(state, [press("5", 6_000)])
      assert more.gather_ms == nil
    end

    test "skills with no parking before them measure no huddle" do
      {_state, reading} = HandsRead.read(HandsRead.new(), [press("1", 500)])

      assert reading.gather_ms == nil
      assert reading.combo == ["1"]
    end

    test "parking again re-arms it — one huddle per kill spot" do
      state = HandsRead.parked(HandsRead.new(), 0)
      {state, _first} = HandsRead.read(state, [press("1", 100)])

      state = HandsRead.parked(state, 10_000)
      {_state, reading} = HandsRead.read(state, [press("1", 13_500)])

      assert reading.gather_ms == 3_500
    end
  end

  test "the watched codes are the whole hotbar" do
    assert length(HandsRead.codes()) == 10
    assert {:ok, hd(HandsRead.codes())} == Commands.keycode("1")
  end
end
