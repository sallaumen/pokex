defmodule Pokex.Bots.SkillBarTest do
  use ExUnit.Case, async: false
  alias Pokex.Bots.SkillBar
  alias Pokex.Calibration
  alias Pokex.Pokedex.Team
  alias Pokex.Rig.Fake
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
      neutral_point: {0, 0},
      skill_bar_region: region,
      skill_bar_count: count
    }
  end

  setup %{tmp_dir: tmp} do
    # 7 slots × 2px: slots 1-6 bright (ready), slot 7 dark (cooldown).
    row = List.duplicate({200, 200, 0, 255}, 12) ++ List.duplicate({20, 20, 20, 255}, 2)
    bar = Pokex.PngFixtures.write!(Path.join(tmp, "bar.png"), [row])
    {:ok, _} = Fake.start_link(%{capture: [{:ok, bar}]})
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

  describe "slot_refs/2 (calibration-time reference building)" do
    @tag :tmp_dir
    test "a slot that LOOKS like a countdown gets NO reference — a poisoned ref inverts" do
      # Calibrating with a skill mid-cooldown would store the dark panel as "this is what
      # ready looks like": every later cooldown then MATCHES the ref (distance ~0 → :ready)
      # and the true ready art mismatches — the reading inverts permanently for that slot.
      # A countdown glyph at calibration time (white_pct at/over the cooldown threshold)
      # therefore yields nil (→ threshold fallback), never a reference.
      slots = [
        %{signature: {200, 200, 0}, white_pct: 1},
        %{signature: {24, 35, 25}, white_pct: 11},
        %{signature: nil, white_pct: 0}
      ]

      assert SkillBar.slot_refs(slots, %{skill_cooldown_min_white_pct: 4}) ==
               [{200, 200, 0}, nil, nil]
    end

    @tag :tmp_dir
    test "nil slots (no reading) and missing settings fail safe" do
      assert SkillBar.slot_refs(nil, %{}) == nil

      assert SkillBar.slot_refs([%{signature: {1, 2, 3}, white_pct: 5}], %{}) == [nil]
    end
  end

  # The bar belongs to the pokémon (#257). Proving that inside ActiveBar is not
  # the same as proving it reaches the READING — this is where the feature
  # either affects the fight or does not.
  describe "the pokémon on the field owns the reading" do
    setup %{tmp_dir: tmp} do
      dataset = %{
        "species" => [%{"name" => "Vespiquen", "number" => 416, "elements" => ["Bug"]}],
        "lures" => []
      }

      File.write!(Path.join(tmp, "pokedex.json"), JSON.encode!(dataset))
      Application.put_env(:pokex, :pokedex_path, Path.join(tmp, "pokedex.json"))
      Application.put_env(:pokex, :home_dir, tmp)

      on_exit(fn ->
        Application.delete_env(:pokex, :pokedex_path)
        Application.delete_env(:pokex, :home_dir)
      end)

      {:ok, _} = Team.add("Vespiquen")
      :ok
    end

    @tag :tmp_dir
    test "ITS slot count slices the frame — not the calibration's, not the setting's" do
      Team.set_bar("Vespiquen", %{region: {0, 0, 14, 1}, count: 2, refs: nil})
      Team.set_active("Vespiquen")

      # the calibration says 6 and the settings say 7; the pokémon says 2
      slots = SkillBar.read(calib({0, 0, 14, 1}, 6), @settings)

      assert length(slots) == 2
    end

    # The reason the bar had to move: the READY references ARE the skill icons.
    @tag :tmp_dir
    test "ITS references decide readiness, so a swap cannot judge against old art" do
      # slots 1-6 are bright yellow in the fixture; slot 7 is dark.
      Team.set_bar("Vespiquen", %{
        region: {0, 0, 14, 1},
        count: 2,
        # one reference matching the bright half, one nowhere near it
        refs: [{200, 200, 0}, {255, 0, 255}]
      })

      Team.set_active("Vespiquen")

      slots =
        SkillBar.read(calib({0, 0, 14, 1}, 6), Map.put(@settings, :skill_ref_max_distance, 25))

      assert SkillBar.states(slots) == [:ready, :cooldown]
    end

    @tag :tmp_dir
    test "nobody on the field falls back to the screen calibration" do
      Team.set_bar("Vespiquen", %{region: {0, 0, 14, 1}, count: 2, refs: nil})

      slots = SkillBar.read(calib({0, 0, 14, 1}, 6), @settings)

      assert length(slots) == 6
    end
  end
end
