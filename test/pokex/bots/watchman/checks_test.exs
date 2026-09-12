defmodule Pokex.Bots.Watchman.ChecksTest do
  @moduledoc """
  Each question the watchman asks: the readings it samples (good now or not)
  and the problems it judges from when each was last good, plus the structural
  ones — each with the answer he needs to hear, and where to fix it.
  """
  use ExUnit.Case, async: false

  alias Pokex.Bots.Watchman.Checks
  alias Pokex.Calibration
  alias Pokex.Perception.WorldState
  alias Pokex.SettingsStash

  @moduletag :tmp_dir
  @now 500_000

  setup %{tmp_dir: tmp} do
    WorldState.clear()
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Pokex.TestHome.restore() end)
    SettingsStash.stash!(watchman_stale_ms: 12_000)

    Calibration.save(%Calibration{
      scale: 1.0,
      screen_w: 1000,
      screen_h: 700,
      tile_px: 36,
      water_point: {1, 1},
      glow_region: {0, 0, 8, 8},
      battle_region: {0, 0, 8, 8},
      neutral_point: {1, 1},
      player_hp_region: {0, 100, 20, 4}
    })

    Pokex.TeamFixtures.ready!("Torterra", count: 4)
    everything_read()
    :ok
  end

  defp everything_read do
    WorldState.put(:skill_bar, %{ready_keys: ~w(1 2 3 4)}, @now)
    WorldState.put(:battle, %{enemies: []}, @now)
    # The whole fact the reader really publishes: `WorldState` is one table for
    # the run, and a half-built fact left here is read by whatever renders next.
    WorldState.put(:pokemon, %{hp_pct: 96, readable?: true, fainted?: false}, @now)
    WorldState.put(:player, %{hp_pct: 100, readable?: true}, @now)
  end

  @all_good %{skill_bar: @now, battle: @now, pokemon: @now, player: @now}

  defp keys(last_good \\ @all_good, now \\ @now),
    do: Checks.problems(now, last_good) |> Enum.map(&elem(&1, 0))

  defp text(key, last_good \\ @all_good, now \\ @now),
    do: Checks.problems(now, last_good) |> Enum.find_value(fn {k, t} -> k == key && t end)

  describe "the readings, good now or not" do
    test "with everything read, every reading is good" do
      assert Checks.readings(@now) ==
               %{skill_bar: true, battle: true, pokemon: true, player: true}
    end

    test "a fact older than a few seconds is not good now" do
      assert Checks.readings(@now + 5_000) ==
               %{skill_bar: false, battle: false, pokemon: false, player: false}
    end

    test "a frame that arrives but is not recognised is not good" do
      WorldState.put(:skill_bar, %{ready_keys: nil}, @now)
      WorldState.put(:player, %{hp_pct: nil, readable?: false}, @now)
      WorldState.put(:pokemon, %{hp_pct: nil, readable?: false}, @now)

      assert Checks.readings(@now) ==
               %{skill_bar: false, battle: true, pokemon: false, player: false}
    end
  end

  describe "the problems" do
    test "with everything good there is nothing to say" do
      assert Checks.problems(@now, @all_good) == []
    end

    # The bar vanishes for two seconds while the revive recalls the pokémon;
    # that never reaches the stale window (2026-09-08: seven false rings).
    test "a reading bad for less than the stale window is not a problem" do
      assert keys(%{@all_good | skill_bar: @now - 3_000}) == []
    end

    test "a reading bad for longer than the stale window is, each with its fix" do
      old = %{
        skill_bar: @now - 20_000,
        battle: @now - 20_000,
        pokemon: @now - 20_000,
        player: @now - 20_000
      }

      assert keys(old) == [:skill_bar, :battle, :pokemon, :player]
      assert text(:skill_bar, old) =~ "barra de skills do Torterra não é reconhecida"
      assert text(:battle, old) =~ "janela de batalha não é lida"
      assert text(:pokemon, old) =~ "Pokebar"
      assert text(:player, old) =~ "vida do PERSONAGEM não é lida"
    end

    # …E O CONSERTO É O DA CAUSA. Esta frase ficou 304 vezes no diário de 12/09
    # mandando recalibrar a barra — e recalibrar conserta UM dos três jeitos de
    # a barra ficar sem leitura. Nos outros dois é conselho errado dito com
    # toda a confiança, que é o que fez cinco horas passarem sem o certo.
    test "the bar's alarm names the fix that matches the cause" do
      old = %{@all_good | skill_bar: @now - 20_000}

      # veio quadro e o reconhecimento recusou
      WorldState.put(:skill_bar, %{ready_keys: nil}, @now)
      assert text(:skill_bar, old) =~ "não passa no reconhecimento"
      assert text(:skill_bar, old) =~ "recalibre a dele em /calibration"

      # a leitura prestou e envelheceu: o recorte está certo
      ceiling = Pokex.Settings.get(:skill_bar_fact_max_age_ms)
      WorldState.put(:skill_bar, %{ready_keys: ~w(1 2)}, @now - ceiling - 500)
      texto = text(:skill_bar, old)
      assert texto =~ "a última leitura PRESTOU"
      assert texto =~ "o problema é a captura, não a calibração"
      refute texto =~ "recalibre"

      # ninguém fotografou a barra nesta sessão
      WorldState.forget(:skill_bar)
      assert text(:skill_bar, old) =~ "não publicou nada nesta sessão"
      refute text(:skill_bar, old) =~ "recalibre"
    end

    test "a reading never sampled is taken as good" do
      assert keys(%{}) == []
    end

    test "a bar marked outside this screen says so, and where it was calibrated" do
      Pokex.Pokedex.Team.set_bar("Torterra", %{region: {1594, 1215, 278, 37}, count: 4, refs: nil})

      assert keys() == [:skill_bar]
      assert text(:skill_bar) =~ "fora desta tela (x=1594"
    end

    test "his life bar unmarked is a problem, because it is the one that shouts" do
      {:ok, calib} = Calibration.load()
      Calibration.save(%{calib | player_hp_region: nil})

      assert keys() == [:player]
      assert text(:player) =~ "não está marcada"
    end

    test "characters on the machine and none active: the legacy team is a problem" do
      {:ok, _slug} = Pokex.Characters.create("Lotavanon")

      assert keys() == [:character]
      assert text(:character) =~ "nenhum personagem ativo"
    end

    test "a screen nobody measured the tile of is a problem, naming the ones the bot knows" do
      {:ok, calib} = Calibration.load()
      Calibration.save(%{calib | tile_px: nil})

      assert keys() == [:tile]
      assert text(:tile) =~ "esta tela (1000×700) não tem o tamanho do tile medido"
      assert text(:tile) =~ "1512×982 → 36"
    end

    test "a measured screen needs no tile of its own" do
      {:ok, calib} = Calibration.load()
      Calibration.save(%{calib | screen_w: 1512, screen_h: 982, tile_px: nil})
      # the bar is per screen: give the new screen one, so only the tile is judged
      Pokex.Pokedex.Team.set_bar("Torterra", %{region: {10, 10, 140, 35}, count: 4, refs: nil})

      assert keys() == []
    end

    # THE BAR OF ANOTHER SCREEN (09/09): calibrated on the notebook, it fits
    # inside the ultrawide and is not there. The watchman names the screen that
    # has it instead of a bare "recalibre".
    test "a bar calibrated on another screen says which screen has it" do
      {:ok, calib} = Calibration.load()
      Calibration.save(%{calib | screen_w: 3440, screen_h: 1440, tile_px: 151})

      assert keys() == [:skill_bar]
      assert text(:skill_bar) =~ "Torterra tem barra de skills calibrada só na tela 1000×700"
      assert text(:skill_bar) =~ "nesta tela (3440×1440) não"
    end
  end
end
