defmodule Pokex.Bots.KeyProbeTest do
  use ExUnit.Case, async: true

  alias Pokex.Bots.KeyProbe

  defp seen(code, shift?), do: %{code: code, shift?: shift?, at: 0}

  describe "what the machine SAW after pressing a combo" do
    test "a plain key the watcher saw is posted" do
      assert %{verdict: :posted, seen: 1} = KeyProbe.verdict("1", [seen(18, false)])
    end

    test "a key the watcher never saw is silent — it did not leave this machine" do
      assert %{verdict: :silent, seen: 0} = KeyProbe.verdict("1", [])
      assert %{verdict: :silent, seen: 0} = KeyProbe.verdict("shift+1", [seen(19, true)])
    end

    # The one that costs damage: the game would read a bare "1" and fire the
    # skill bound to it instead of switching stance.
    test "a modified key that arrived WITHOUT the modifier is naked" do
      assert %{verdict: :naked, seen: 2} =
               KeyProbe.verdict("shift+1", [seen(18, false), seen(18, false)])
    end

    test "one shifted sighting is enough — the flag is sampled, not guaranteed per event" do
      assert %{verdict: :posted, seen: 2} =
               KeyProbe.verdict("shift+1", [seen(18, false), seen(18, true)])
    end

    test "events for other keys never count" do
      assert %{verdict: :silent, seen: 0} =
               KeyProbe.verdict("shift+3", [seen(18, true), seen(49, true)])
    end

    # A combo whose key has no keycode cannot be measured at all, and saying
    # "silent" about it would read as "the key did not go out".
    test "an unmappable key is unmeasurable, never a verdict about the key" do
      assert %{verdict: :unmeasurable, seen: 0} = KeyProbe.verdict("shift+v", [seen(18, true)])
    end
  end

  describe "the codes the watcher has to be armed with" do
    test "every measurable key in the combos, deduped" do
      assert KeyProbe.codes(["1", "shift+1", "shift+3"]) == [18, 20]
    end

    test "unmappable combos contribute nothing" do
      assert KeyProbe.codes(["shift+v", "tab"]) == [48]
    end
  end
end
