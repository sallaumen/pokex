defmodule Pokex.Bots.Watchman.ChecksTest do
  @moduledoc """
  Each question the watchman asks, against the blackboard and the files, with
  the answer he needs to hear: which reading, and where to fix it.
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
    SettingsStash.stash!(watchman_stale_ms: 12_000, tile_px: 36)

    Calibration.save(%Calibration{
      scale: 1.0,
      screen_w: 1000,
      screen_h: 700,
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
    WorldState.put(:pokemon, %{hp_pct: 96}, @now)
    WorldState.put(:player, %{hp_pct: 100, readable?: true}, @now)
  end

  defp keys(now \\ @now), do: Checks.run(now) |> Enum.map(&elem(&1, 0))

  defp text(key, now \\ @now),
    do: Checks.run(now) |> Enum.find_value(fn {k, t} -> k == key && t end)

  test "with everything read there is nothing to say" do
    assert Checks.run(@now) == []
  end

  test "a reading older than the stale window is a problem, each with its fix" do
    later = @now + 20_000

    assert keys(later) == [:skill_bar, :battle, :pokemon, :player]
    assert text(:skill_bar, later) =~ "barra de skills do Torterra não é reconhecida"
    assert text(:skill_bar, later) =~ "recalibre a barra dele em /calibration"
    assert text(:battle, later) =~ "janela de batalha não é lida"
    assert text(:pokemon, later) =~ "Pokebar"
    assert text(:player, later) =~ "vida do PERSONAGEM não é lida"
  end

  test "a bar marked outside this screen says so, and where it was calibrated" do
    Pokex.Pokedex.Team.set_bar("Torterra", %{region: {1594, 1215, 278, 37}, count: 4, refs: nil})

    assert keys() == [:skill_bar]
    assert text(:skill_bar) =~ "fora desta tela (x=1594"
  end

  test "a bar the reader cannot recognise is a problem even when the frame arrives" do
    WorldState.put(:skill_bar, %{ready_keys: nil}, @now)
    assert keys() == [:skill_bar]
  end

  test "his life bar unmarked is a problem, because it is the one that shouts" do
    {:ok, calib} = Calibration.load()
    Calibration.save(%{calib | player_hp_region: nil})

    assert keys() == [:player]
    assert text(:player) =~ "não está marcada"
  end

  test "his life bar read as unreadable is a problem" do
    WorldState.put(:player, %{hp_pct: nil, readable?: false}, @now)
    assert keys() == [:player]
  end

  test "characters on the machine and none active: the legacy team is a problem" do
    {:ok, _slug} = Pokex.Characters.create("Lotavanon")

    assert keys() == [:character]
    assert text(:character) =~ "nenhum personagem ativo"
  end

  test "a tile that does not fit fifteen times across the screen is another screen's tile" do
    SettingsStash.stash!(tile_px: 151)

    assert keys() == [:tile]
    assert text(:tile) =~ "tile_px 151 não cabe nesta tela de 1000"
    assert text(:tile) =~ "36"
  end
end
