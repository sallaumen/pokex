defmodule Pokex.VisionSkillStatesTest do
  use ExUnit.Case, async: true
  alias Pokex.Vision
  alias Pokex.Vision.Frame

  describe "skill_states/2" do
    test "a colourful/bright slot reads :ready, a dark grey slot reads :cooldown" do
      # slots: yellow (ready), dark grey (cooldown), pink (ready), dark grey (cooldown)
      frame = bar([{200, 200, 0}, {30, 30, 30}, {210, 40, 160}, {25, 25, 25}], 3)
      assert Vision.skill_states(frame, count: 4) == [:ready, :cooldown, :ready, :cooldown]
    end

    test "a DARK but colourful icon still reads :ready (saturation, not just brightness)" do
      # dark green: brightness 90 (< 140) but saturation 90 (>= 40) → ready.
      frame = bar([{0, 90, 0}, {30, 30, 30}], 2)
      assert Vision.skill_states(frame, count: 2) == [:ready, :cooldown]
    end

    test "clamps the slot count to the frame width" do
      frame = bar([{200, 200, 0}, {200, 200, 0}], 1)
      assert length(Vision.skill_states(frame, count: 50)) == 2
    end
  end

  describe "skill_slots/2 (detailed, for the diagnostic + tuning)" do
    test "reports brightness, saturation and state per slot" do
      [ready, cooldown] = Vision.skill_slots(bar([{200, 200, 0}, {20, 20, 20}], 2), count: 2)

      assert ready.state == :ready
      assert ready.brightness == 200
      assert ready.saturation == 200
      assert cooldown.state == :cooldown
      assert cooldown.brightness == 20
      assert cooldown.saturation == 0
    end

    test "thresholds are tunable" do
      # force everything to :cooldown with impossible thresholds
      states =
        bar([{200, 200, 0}, {20, 20, 20}], 2)
        |> Vision.skill_slots(count: 2, min_brightness: 999, min_saturation: 999)
        |> Enum.map(& &1.state)

      assert states == [:cooldown, :cooldown]
    end
  end

  # One-row frame: each slot is `slot_w` px of a solid colour, left→right.
  defp bar(colors, slot_w) do
    rgba = for {r, g, b} <- colors, into: <<>>, do: :binary.copy(<<r, g, b, 255>>, slot_w)
    %Frame{width: length(colors) * slot_w, height: 1, rgba: rgba}
  end
end
