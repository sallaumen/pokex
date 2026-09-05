defmodule Pokex.Bots.SkillBarTest do
  use ExUnit.Case, async: false
  alias Pokex.Bots.SkillBar
  alias Pokex.Pokedex.Team
  alias Pokex.Rig.Fake
  alias Pokex.Vision.Frame

  @settings %{skill_bar_count: 7, skill_ready_min_saturation: 40, skill_ready_min_vivid_pct: 7}

  defp on_field(region, count) do
    {:ok, _} = Pokex.Pokedex.Team.add("Bulbasaur")
    Pokex.Pokedex.Team.set_bar("Bulbasaur", %{region: region, count: count, refs: nil})
    Pokex.Pokedex.Team.set_active("Bulbasaur")
  end

  # 7 slots: os seis primeiros prontos, o sétimo frio — e em TODOS o rótulo da
  # tecla, que é o que faz o quadro ser a barra (`Pokex.SkillBarFixtures`).
  @bar_region Pokex.SkillBarFixtures.region(7)

  setup %{tmp_dir: tmp} do
    bar = Pokex.PngFixtures.write!(Path.join(tmp, "bar.png"), Pokex.SkillBarFixtures.rows(7, 6))
    {:ok, _} = Fake.start_link(%{capture: [{:ok, bar}]})
    :ok
  end

  @tag :tmp_dir
  test "reads per-slot states and derives readiness" do
    on_field(@bar_region, 7)
    slots = SkillBar.read(@settings)

    assert SkillBar.states(slots) ==
             [:ready, :ready, :ready, :ready, :ready, :ready, :cooldown]

    assert SkillBar.all_ready?(slots, ["4", "5", "6"]) == true
    # slot 7 on cooldown
    assert SkillBar.all_ready?(slots, ["4", "5", "6", "7"]) == false
    assert SkillBar.ready_keys(slots) == ["1", "2", "3", "4", "5", "6"]
  end

  @tag :tmp_dir
  test "an untrackable hook key (non-digit / out of range) can't softlock — fails open" do
    on_field(@bar_region, 7)
    slots = SkillBar.read(@settings)

    # "9" is past the 7 slots and "e" isn't a digit → untrackable → ignored, NOT held
    assert SkillBar.all_ready?(slots, ["4", "5", "9"]) == true
    assert SkillBar.all_ready?(slots, ["4", "5", "e"]) == true
    # a valid in-range cooldown key still gates
    assert SkillBar.all_ready?(slots, ["4", "7"]) == false
  end

  @tag :tmp_dir
  test "no bar on the field → nil read; fishing fails OPEN, combat falls back to blind" do
    Pokex.Pokedex.Team.set_active(nil)

    assert SkillBar.read(@settings) == nil
    assert SkillBar.states(nil) == nil
    # fail-open so require_cooldowns never softlocks fishing
    assert SkillBar.all_ready?(nil, ["4", "5"]) == true
    # nil (not []) so combat uses blind rotation, never "no skills ready"
    assert SkillBar.ready_keys(nil) == nil
  end

  @tag :tmp_dir
  test "any_ready?: the loosened gate pulls when AT LEAST ONE hook-skill is ready" do
    on_field(@bar_region, 7)
    slots = SkillBar.read(@settings)

    # slots 1-6 ready, 7 on cooldown
    assert SkillBar.any_ready?(slots, ["4", "5", "6"]) == true
    # only the cooldown slot → nothing ready → HOLD
    assert SkillBar.any_ready?(slots, ["7"]) == false
    # one ready among cooldowns is enough to pull
    assert SkillBar.any_ready?(slots, ["6", "7"]) == true
  end

  @tag :tmp_dir
  test "any_ready? fails OPEN too — an unreadable/untrackable bar never softlocks the hold" do
    on_field(@bar_region, 7)
    slots = SkillBar.read(@settings)

    # no reading at all → don't hold
    assert SkillBar.any_ready?(nil, ["4", "5"]) == true
    # ALL keys untrackable (past the bar / non-digit) → no info → don't hold
    assert SkillBar.any_ready?(slots, ["9", "e"]) == true
    # a trackable cooldown key alongside an untrackable one → still nothing ready → HOLD
    assert SkillBar.any_ready?(slots, ["7", "9"]) == false
  end

  # A CONTAGEM ESCRITA VENCE A REFERÊNCIA. A barra real da noite de 27→28/08,
  # com refs que liam tudo como pronta enquanto o jogo escrevia 32/33/43/44 em
  # cima das teclas 1, 3, 4 e 5 — o defeito que fez 2.372 recibos mentirem.
  @tag :tmp_dir
  test "a key with the cooldown written by the game is cooling, whatever the refs say" do
    {:ok, frame} = Frame.from_file("test/fixtures/skill_bar/quatro_contando.raw")
    on_field({0, 0, frame.width, frame.height}, 9)

    slots = SkillBar.slots_from_frame(frame, @settings)

    assert Enum.map(slots, & &1.counting?) ==
             [true, false, true, true, true, false, false, false, false]

    # o que a contagem GARANTE: as quatro teclas com número escrito são
    # cooldown; as vizinhas legíveis seguem prontas. (8 e 9 dependem de refs,
    # que este teste não calibra — o fallback de limiar responde por elas.)
    assert slots |> SkillBar.states() |> Enum.take(7) ==
             [:cooldown, :ready, :cooldown, :cooldown, :cooldown, :ready, :ready]

    ready = SkillBar.ready_keys(slots)
    assert ["2", "6", "7"] -- ready == []
    assert Enum.all?(["1", "3", "4", "5"], &(&1 not in ready))
  end

  # Um ref tirado com a contagem na tela é um ref envenenado — e agora a
  # contagem em si diz isso, sem depender do limiar de branco.
  @tag :tmp_dir
  test "calibrating with a key counting does not store its ref" do
    {:ok, frame} = Frame.from_file("test/fixtures/skill_bar/quatro_contando.raw")
    on_field({0, 0, frame.width, frame.height}, 9)

    refs = frame |> SkillBar.slots_from_frame(@settings) |> SkillBar.slot_refs(@settings)

    assert refs |> Enum.with_index() |> Enum.filter(fn {ref, _} -> ref == nil end) |> length() >=
             4

    assert [nil, _, nil, nil, nil | _] = refs
  end

  @tag :tmp_dir
  test "keeps the calibrated count even when the frame visually resembles another count" do
    row =
      1..8
      |> Enum.map_join(fn _ ->
        :binary.copy(<<40, 180, 80, 255>>, 8) <> :binary.copy(<<5, 5, 5, 255>>, 3)
      end)

    frame = %Frame{width: div(byte_size(row), 4), height: 4, rgba: :binary.copy(row, 4)}
    on_field({0, 0, frame.width, 4}, 6)
    slots = SkillBar.slots_from_frame(frame, @settings)

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
        Pokex.TestHome.restore()
      end)

      {:ok, _} = Team.add("Vespiquen")
      :ok
    end

    @tag :tmp_dir
    test "ITS slot count slices the frame — not the calibration's, not the setting's" do
      Team.set_bar("Vespiquen", %{region: @bar_region, count: 2, refs: nil})
      Team.set_active("Vespiquen")

      # the settings say 7 slots; the pokémon on the field says 2
      slots = SkillBar.read(@settings)

      assert length(slots) == 2
    end

    # The reason the bar had to move: the READY references ARE the skill icons.
    @tag :tmp_dir
    test "ITS references decide readiness, so a swap cannot judge against old art",
         %{tmp_dir: tmp} do
      # the reference of the bright half is what calibration would have taken
      # from this very picture; the other one is nowhere near anything on it
      {:ok, frame} = Frame.from_png_file(Path.join(tmp, "bar.png"))

      [bright_ref, _dark_ref] =
        frame |> Pokex.Vision.skill_slots(count: 2) |> SkillBar.slot_refs(@settings)

      Team.set_bar("Vespiquen", %{
        region: @bar_region,
        count: 2,
        refs: [bright_ref, {255, 0, 255}]
      })

      Team.set_active("Vespiquen")

      slots = SkillBar.read(Map.put(@settings, :skill_ref_max_distance, 25))

      assert SkillBar.states(slots) == [:ready, :cooldown]
    end

    # There is no shared bar to fall back to: a rectangle nobody on the field
    # owns is what let the screen ruler rescale 21 settings by a doubled slot
    # (2026-08-24). Nothing to read is the honest answer.
    @tag :tmp_dir
    test "nobody on the field means nothing to read" do
      Team.set_bar("Vespiquen", %{region: @bar_region, count: 2, refs: nil})
      Team.set_active(nil)

      assert SkillBar.read(@settings) == nil
    end
  end
end
