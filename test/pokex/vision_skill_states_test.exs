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

    test "a mostly-dark icon with a few VIVID pixels reads :ready (the green skill-3 case)" do
      # 9 near-black px + 1 vivid green px in one slot: avg brightness 29 and avg saturation 16
      # are BOTH below 90/25 (the old average test misread this as cooldown forever), but 10%
      # of the pixels are strongly coloured → :ready via vivid_pct.
      rgba = :binary.copy(<<10, 10, 10, 255>>, 9) <> <<40, 200, 40, 255>>
      frame = %Frame{width: 10, height: 1, rgba: rgba}

      states =
        Vision.skill_slots(frame,
          count: 1,
          min_brightness: 90,
          min_saturation: 25,
          min_vivid_pct: 6
        )
        |> Enum.map(& &1.state)

      assert states == [:ready]
    end

    test "a greyed cooldown icon with a white number stays :cooldown (no vivid pixels)" do
      # a darkened greyish icon (desaturated) + one white countdown px: nothing is strongly
      # coloured (grey/white are colourless), avg brightness stays low → :cooldown.
      rgba = :binary.copy(<<40, 45, 40, 255>>, 9) <> <<240, 240, 240, 255>>
      frame = %Frame{width: 10, height: 1, rgba: rgba}

      states =
        Vision.skill_slots(frame,
          count: 1,
          min_brightness: 90,
          min_saturation: 25,
          min_vivid_pct: 6
        )
        |> Enum.map(& &1.state)

      assert states == [:cooldown]
    end

    test "clamps the slot count to the frame width" do
      frame = bar([{200, 200, 0}, {200, 200, 0}], 1)
      assert length(Vision.skill_states(frame, count: 50)) == 2
    end
  end

  describe "skill_slots/2 (detailed, for the diagnostic + tuning)" do
    test "reports brightness, saturation, vivid_pct and state per slot" do
      [ready, cooldown] = Vision.skill_slots(bar([{200, 200, 0}, {20, 20, 20}], 2), count: 2)

      assert ready.state == :ready
      assert ready.brightness == 200
      assert ready.saturation == 200
      assert ready.vivid_pct == 100
      assert cooldown.state == :cooldown
      assert cooldown.brightness == 20
      assert cooldown.saturation == 0
      assert cooldown.vivid_pct == 0
    end

    test "thresholds are tunable" do
      # force everything to :cooldown with impossible thresholds (all three paths)
      states =
        bar([{200, 200, 0}, {20, 20, 20}], 2)
        |> Vision.skill_slots(
          count: 2,
          min_brightness: 999,
          min_saturation: 999,
          min_vivid_pct: 999
        )
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
