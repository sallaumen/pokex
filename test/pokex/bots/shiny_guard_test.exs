defmodule Pokex.Bots.ShinyGuardTest do
  # async: false — stashes global Settings
  use ExUnit.Case, async: false

  alias Pokex.Bots.ShinyGuard
  alias Pokex.{Settings, SettingsStash}

  setup %{tmp_dir: tmp} do
    # the trophy shelf writes under the Pokex home — keep it out of the real one
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

    SettingsStash.stash!(
      shiny_streak_needed: 2,
      shiny_action: "alarme"
    )

    test = self()
    escape_fun = fn reason -> send(test, {:escaped, reason}) end

    {:ok, guard} = ShinyGuard.start_link(name: nil, active: true, escape_fun: escape_fun)
    %{guard: guard}
  end

  # what Interpret.battle publishes: which rows carry the gold star + the best
  # cluster score seen
  defp shiny_obs(px \\ 40),
    do: %{enemies: [0], red: [0, 0], locked?: false, shiny_rows: [1], shiny_star_px: px}

  defp clean_obs,
    do: %{enemies: [0], red: [0, 0], locked?: false, shiny_rows: [], shiny_star_px: 0}

  @tag :tmp_dir
  test "streak de avistamentos com ação alarme: broadcasta {:rule_alarm, _} UMA vez", %{
    guard: guard
  } do
    Phoenix.PubSub.subscribe(Pokex.PubSub, "combat")

    send(guard, {:world, :battle, shiny_obs()})
    refute_receive {:rule_alarm, _}, 50

    send(guard, {:world, :battle, shiny_obs()})
    assert_receive {:rule_alarm, reason}, 500
    assert reason =~ "SHINY na lista de batalha"
    assert reason =~ "LUTA"

    # refractory: right after firing, more sightings stay silent
    send(guard, {:world, :battle, shiny_obs()})
    send(guard, {:world, :battle, shiny_obs()})
    refute_receive {:rule_alarm, _}, 100
  end

  @tag :tmp_dir
  test "um frame limpo no meio zera o streak (debounce real)", %{guard: guard} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, "combat")

    send(guard, {:world, :battle, shiny_obs()})
    send(guard, {:world, :battle, clean_obs()})
    send(guard, {:world, :battle, shiny_obs()})

    refute_receive {:rule_alarm, _}, 100
  end

  @tag :tmp_dir
  test "ação fugir dispara o protocolo de fuga injetado", %{guard: guard} do
    Settings.put(:shiny_action, "fugir")

    send(guard, {:world, :battle, shiny_obs(77)})
    send(guard, {:world, :battle, shiny_obs(77)})

    assert_receive {:escaped, reason}, 500
    assert reason =~ "estrela 77px"
  end

  @tag :tmp_dir
  test "status expõe o estado do guarda", %{guard: guard} do
    status = ShinyGuard.status(guard)
    assert %{enabled?: _, attached?: false, streak: 0, star_min_px: _} = status
  end

  @tag :tmp_dir
  test "broadcasta a leitura ao vivo pro medidor do painel (throttled)", %{guard: guard} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, "shiny")

    send(guard, {:world, :battle, clean_obs()})
    assert_receive {:shiny_reading, %{star_px: 0, min_px: _}}, 500

    # the throttle suppresses a second reading right after the first
    send(guard, {:world, :battle, clean_obs()})
    refute_receive {:shiny_reading, _}, 100
  end
end
