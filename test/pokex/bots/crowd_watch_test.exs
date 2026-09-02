defmodule Pokex.Bots.CrowdWatchTest do
  @moduledoc """
  O olho da espera, fase 1: mede, escreve, guarda a foto — e não decide.
  """
  use ExUnit.Case, async: false

  alias Pokex.Bots.CrowdWatch
  alias Pokex.Perception.WorldState
  alias Pokex.SettingsStash

  @png "data:image/png;base64," <> Base.encode64("png-de-mentira")

  setup %{tmp_dir: tmp} do
    WorldState.clear()
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Pokex.TestHome.restore() end)
    SettingsStash.stash!(crowd_watch_enabled: true)
    Phoenix.PubSub.subscribe(Pokex.PubSub, "engine")

    test = self()

    look = fn opts ->
      send(test, {:looked, opts})

      %{
        read?: true,
        seen: 3,
        listed: opts[:listed],
        spots: [%{tiles: 1}, %{tiles: 1}, %{tiles: 4}],
        anchor: :pokemon,
        radius: 6,
        took_ms: 12,
        evidence: @png
      }
    end

    pid = start_supervised!({CrowdWatch, name: nil, active: true, look: look})
    %{watch: pid}
  end

  defp orders!(phase), do: WorldState.put(:orders, %{phase: phase, why: "teste"}, now())

  defp battle!(n),
    do: WorldState.put(:battle, %{enemies: Enum.to_list(1..n), captured_at: now()}, now())

  defp now, do: System.monotonic_time(:millisecond)

  @tag :tmp_dir
  test "esperando o bolo, fotografa, publica o fato e escreve no feed", %{watch: watch} do
    orders!(:bunching)
    battle!(6)

    :ok = CrowdWatch.look_now(watch)

    assert_receive {:looked, opts}
    assert opts[:listed] == 6
    assert {:ok, crowd} = WorldState.get(:crowd, 5_000, now())
    assert crowd.near == 2
    assert crowd.seen == 3
    assert crowd.listed == 6
    assert crowd.reach_tiles == 1
    assert_receive {:engine_log, :macro, "olho: 👀 perto: 2 de 6 a ≤1 tile" <> _}
  end

  @tag :tmp_dir
  test "a mesma leitura não repete a linha", %{watch: watch} do
    orders!(:bunching)
    battle!(6)

    :ok = CrowdWatch.look_now(watch)
    :ok = CrowdWatch.look_now(watch)

    assert_receive {:engine_log, :macro, "olho: 👀 perto" <> _}
    refute_receive {:engine_log, :macro, "olho: 👀 perto" <> _}, 100
  end

  @tag :tmp_dir
  test "andando, lutando ou revivendo, não fotografa", %{watch: watch} do
    battle!(6)

    for phase <- [:travelling, :engaged, :resetting, :recovering, :skipping] do
      orders!(phase)
      :ok = CrowdWatch.look_now(watch)
      refute_receive {:looked, _}, 50
    end
  end

  @tag :tmp_dir
  test "desligado no /config, não fotografa nem esperando", %{watch: watch} do
    SettingsStash.stash!(crowd_watch_enabled: false)
    orders!(:bunching)
    battle!(6)

    :ok = CrowdWatch.look_now(watch)

    refute_receive {:looked, _}, 50
  end

  @tag :tmp_dir
  test "na abertura, guarda a última foto da espera", %{watch: watch, tmp_dir: tmp} do
    orders!(:bunching)
    battle!(6)
    :ok = CrowdWatch.look_now(watch)

    orders!(:engaged)
    :ok = CrowdWatch.look_now(watch)

    assert_receive {:engine_log, :macro, "olho: 📷 abriu com 2 de 6" <> _}
    dir = Path.join(Pokex.Home.captures_dir(), "crowd")
    assert [foto] = File.ls!(dir)
    assert foto =~ "2de6"
    assert File.read!(Path.join(dir, foto)) == "png-de-mentira"
    assert String.starts_with?(Pokex.Home.captures_dir(), tmp)
  end
end
