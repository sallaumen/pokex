defmodule Pokex.Bots.SkillBarTest do
  use ExUnit.Case, async: false
  alias Pokex.Bots.SkillBar
  alias Pokex.Calibration
  alias Pokex.Vision.Frame

  @settings %{skill_bar_count: 7, skill_ready_min_saturation: 40, skill_ready_min_vivid_pct: 7}

  defp calib(region, count \\ nil) do
    %Calibration{
      scale: 1.0,
      screen_w: 100,
      screen_h: 100,
      water_point: {0, 0},
      glow_region: {0, 0, 1, 1},
      battle_region: {0, 0, 1, 1},
      arena_region: {0, 0, 1, 1},
      neutral_point: {0, 0},
      skill_bar_region: region,
      skill_bar_count: count
    }
  end

  setup %{tmp_dir: tmp} do
    # 7 slots × 2px: slots 1-6 bright (ready), slot 7 dark (cooldown).
    row = List.duplicate({200, 200, 0, 255}, 12) ++ List.duplicate({20, 20, 20, 255}, 2)
    bar = Pokex.PngFixtures.write!(Path.join(tmp, "bar.png"), [row])
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, bar}]})
    :ok
  end

  @tag :tmp_dir
  test "reads per-slot states and derives readiness" do
    slots = SkillBar.read(calib({0, 0, 14, 1}), @settings)

    assert SkillBar.states(slots) ==
             [:ready, :ready, :ready, :ready, :ready, :ready, :cooldown]

    assert SkillBar.all_ready?(slots, ["4", "5", "6"]) == true
    # slot 7 on cooldown
    assert SkillBar.all_ready?(slots, ["4", "5", "6", "7"]) == false
    assert SkillBar.ready_keys(slots) == ["1", "2", "3", "4", "5", "6"]
  end

  @tag :tmp_dir
  test "an untrackable hook key (non-digit / out of range) can't softlock — fails open" do
    slots = SkillBar.read(calib({0, 0, 14, 1}), @settings)

    # "9" is past the 7 slots and "e" isn't a digit → untrackable → ignored, NOT held
    assert SkillBar.all_ready?(slots, ["4", "5", "9"]) == true
    assert SkillBar.all_ready?(slots, ["4", "5", "e"]) == true
    # a valid in-range cooldown key still gates
    assert SkillBar.all_ready?(slots, ["4", "7"]) == false
  end

  @tag :tmp_dir
  test "no skill_bar_region → nil read; fishing fails OPEN, combat falls back to blind" do
    assert SkillBar.read(calib(nil), @settings) == nil
    assert SkillBar.states(nil) == nil
    # fail-open so require_cooldowns never softlocks fishing
    assert SkillBar.all_ready?(nil, ["4", "5"]) == true
    # nil (not []) so combat uses blind rotation, never "no skills ready"
    assert SkillBar.ready_keys(nil) == nil
  end

  @tag :tmp_dir
  test "any_ready?: the loosened gate pulls when AT LEAST ONE hook-skill is ready" do
    slots = SkillBar.read(calib({0, 0, 14, 1}), @settings)

    # slots 1-6 ready, 7 on cooldown
    assert SkillBar.any_ready?(slots, ["4", "5", "6"]) == true
    # only the cooldown slot → nothing ready → HOLD
    assert SkillBar.any_ready?(slots, ["7"]) == false
    # one ready among cooldowns is enough to pull
    assert SkillBar.any_ready?(slots, ["6", "7"]) == true
  end

  @tag :tmp_dir
  test "any_ready? fails OPEN too — an unreadable/untrackable bar never softlocks the hold" do
    slots = SkillBar.read(calib({0, 0, 14, 1}), @settings)

    # no reading at all → don't hold
    assert SkillBar.any_ready?(nil, ["4", "5"]) == true
    # ALL keys untrackable (past the bar / non-digit) → no info → don't hold
    assert SkillBar.any_ready?(slots, ["9", "e"]) == true
    # a trackable cooldown key alongside an untrackable one → still nothing ready → HOLD
    assert SkillBar.any_ready?(slots, ["7", "9"]) == false
  end

  @tag :tmp_dir
  test "keeps the calibrated count even when the frame visually resembles another count" do
    row =
      1..8
      |> Enum.map_join(fn _ ->
        :binary.copy(<<40, 180, 80, 255>>, 8) <> :binary.copy(<<5, 5, 5, 255>>, 3)
      end)

    frame = %Frame{width: div(byte_size(row), 4), height: 4, rgba: :binary.copy(row, 4)}
    slots = SkillBar.slots_from_frame(frame, calib({0, 0, frame.width, 4}, 6), @settings)

    assert length(slots) == 6
    assert SkillBar.ready_keys(slots) == ["1", "2", "3", "4", "5", "6"]
  end

  @tag :tmp_dir
  test "maps the tenth skill to hotkey 0" do
    slots = List.duplicate(%{state: :ready}, 10)

    assert SkillBar.keys(10) == ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
    assert List.last(SkillBar.ready_keys(slots)) == "0"
    assert SkillBar.all_ready?(slots, ["9", "0"])
  end

  @tag :tmp_dir
  test "fits a saved priority order when the selected pokemon has more or fewer skills" do
    assert SkillBar.fit_order(["6", "5", "4", "3", "2", "1"], 8) ==
             ["6", "5", "4", "3", "2", "1", "7", "8"]

    assert SkillBar.fit_order(["8", "6", "3", "1"], 5) == ["3", "1", "2", "4", "5"]
    assert List.last(SkillBar.fit_order(Enum.map(1..10, &to_string/1), 10)) == "0"
  end
end
