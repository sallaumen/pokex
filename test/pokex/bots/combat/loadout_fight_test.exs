defmodule Pokex.Bots.Combat.LoadoutFightTest do
  @moduledoc """
  The whole path, end to end: what he classified on `/time` decides which keys
  the fight presses.

  Every other combat test feeds `skill_keys` straight into the config. These
  drive the REAL `Logic` through the same entry point the Worker uses
  (`set_loadout/2` + `step/3`) and assert on the keys that came out — so a rule
  that is only true in `Strategy` and never reaches a press fails here.
  """
  use ExUnit.Case, async: true

  alias Pokex.Bots.Combat.{Loadout, Logic}

  # 1 aura, 2 control, 3..6 area, 7 single-target — his Shiny Vileplume.
  @profile %{
    "1" => :buffs,
    "2" => :crowd,
    "3" => :aoe,
    "4" => :aoe,
    "5" => :aoe,
    "6" => :aoe,
    "7" => :single
  }

  @config %{
    tab_confirm_ms: 500,
    tab_confirm_frames: 1,
    tab_max_attempts: 3,
    hunt_cooldown_ms: 500,
    scenery_hunts_needed: 99,
    scenery_ttl_ms: 60_000,
    hunt_probe_window_ms: 0,
    skill_burst_every_ms: 0,
    fight_timeout_ms: 60_000,
    target_lost_streak: 2,
    # the hand-written list, deliberately DIFFERENT from anything the profile
    # would produce, so a press proves which source decided it
    skill_keys: ["9"],
    combat_skill_burst_size: 9,
    combat_aoe_from_enemies: 3,
    # A ORDEM entre área e alvo único é o assunto deste arquivo, e desde 27/08
    # ela só existe com as de alvo único LIGADAS — por padrão a caçada não as
    # usa ("o que dá dano é a skill em área, praticamente exclusivamente").
    combat_single_target: true,
    # …e o Tab ligado: este arquivo prova a ORDEM das teclas que chegam ao jogo,
    # e a máquina que leva a luta até elas aqui é a de travar alvo.
    combat_tab_target: true,
    max_consecutive_failures: 5
  }

  defp fighting(loadout, enemies) do
    obs = %{enemies: enemies, locked?: true, locked_row: 0, captured_at: 1}

    logic =
      @config
      |> Logic.new()
      |> Logic.start(0)
      |> elem(0)
      |> Logic.set_loadout(loadout)

    # hunting → Tab → tabbing → lock → fighting, the way the machine really gets there
    {logic, _tab} = Logic.step(logic, obs, 10)
    {_logic, actions} = Logic.step(logic, %{obs | captured_at: 15}, 20)

    # uniq: the blind rotation wraps around the list to fill the burst, and what
    # this file is about is the ORDER of the distinct keys, not the burst size
    Enum.uniq(for {:press, key} <- actions, do: key)
  end

  defp loadout, do: Loadout.resolve("Shiny Vileplume", @profile)

  describe "the keys that actually reach the game" do
    test "one enemy: single-target leads, area behind it" do
      assert fighting(loadout(), [0]) == ~w(7 3 4 5 6)
    end

    test "a crowd: area leads" do
      assert fighting(loadout(), [0, 1, 2, 3]) == ~w(3 4 5 6 7)
    end

    # The rule the auto-revive depends on. Asserting it on the PRESSES, not on
    # Strategy's return value, is the point: a reserved key that never reaches
    # a press is the only version of this rule that matters.
    test "the control key is never pressed, crowd or no crowd" do
      refute "2" in fighting(loadout(), [0])
      refute "2" in fighting(loadout(), [0, 1, 2, 3, 4])
    end

    test "the aura is not pressed by the fight either — it has its own moment" do
      refute "1" in fighting(loadout(), [0, 1, 2, 3])
    end
  end

  describe "without a loadout nothing changes" do
    # The fallback is not a degraded mode: it is the behaviour that existed
    # before any of this, and a pokémon he never classified must not make the
    # bot stop attacking.
    test "no pokémon chosen: the configured list is pressed, as always" do
      assert fighting(nil, [0, 1, 2]) == ["9"]
    end

    test "a pokémon with nothing to ATTACK with falls back, loadout or not" do
      only_reserved = Loadout.resolve("Gogoat", %{"2" => :crowd, "8" => :heal})

      refute Loadout.attacks?(only_reserved)
      assert fighting(only_reserved, [0, 1, 2]) == ["9"]
    end
  end

  describe "the threshold is a setting, not a hunch" do
    test "lowering it makes a pair count as a crowd" do
      logic_keys = fn aoe_from ->
        obs = %{enemies: [0, 1], locked?: true, locked_row: 0, captured_at: 1}

        logic =
          %{@config | combat_aoe_from_enemies: aoe_from}
          |> Logic.new()
          |> Logic.start(0)
          |> elem(0)
          |> Logic.set_loadout(loadout())

        {logic, _tab} = Logic.step(logic, obs, 10)
        {_logic, actions} = Logic.step(logic, %{obs | captured_at: 15}, 20)
        Enum.uniq(for {:press, key} <- actions, do: key)
      end

      assert logic_keys.(3) == ~w(7 3 4 5 6)
      assert logic_keys.(2) == ~w(3 4 5 6 7)
    end
  end

  describe "keys/2 — this category's key on this pokémon" do
    test "answers with the keys classified for the category" do
      loadout = Loadout.resolve("Vespiquen", %{"2" => :buffs, "3" => :aoe, "4" => :aoe})

      assert Loadout.keys(loadout, :buffs) == ["2"]
      assert Loadout.keys(loadout, :aoe) == ["3", "4"]
    end

    test "a category with no key classified is an empty list, not an error" do
      loadout = Loadout.resolve("Sunkern", %{"3" => :aoe})

      assert Loadout.keys(loadout, :heal) == []
    end

    # With no pokémon on the field the question has no answer — and whoever is
    # asking (the hunt, the timers) must not break because of it.
    test "no loadout is an empty list" do
      assert Loadout.keys(nil, :buffs) == []
    end

    test "a category nobody knows is an empty list" do
      loadout = Loadout.resolve("Gogoat", %{"1" => :buffs})

      assert Loadout.keys(loadout, :name) == []
    end
  end

  # E O PADRÃO, provado onde importa: nas TECLAS que chegam ao jogo.
  describe "com as de alvo único desligadas (o padrão)" do
    defp so_area(loadout, enemies) do
      obs = %{enemies: enemies, locked?: true, locked_row: 0, captured_at: 1}

      logic =
        %{@config | combat_single_target: false}
        |> Logic.new()
        |> Logic.start(0)
        |> elem(0)
        |> Logic.set_loadout(loadout)

      {logic, _tab} = Logic.step(logic, obs, 10)
      {_logic, actions} = Logic.step(logic, %{obs | captured_at: 15}, 20)

      Enum.uniq(for {:press, key} <- actions, do: key)
    end

    test "com dois bichos ele abre com ÁREA, não com alvo único" do
      assert so_area(loadout(), [0, 1]) == ~w(3 4 5 6)
    end

    test "e com um só, também" do
      assert so_area(loadout(), [0]) == ~w(3 4 5 6)
    end
  end
end
