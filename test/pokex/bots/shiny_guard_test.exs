defmodule Pokex.Bots.ShinyGuardTest do
  # async: false — stashes global Settings
  use ExUnit.Case, async: false

  alias Pokex.Bots.ShinyGuard
  alias Pokex.{Settings, SettingsStash}

  setup do
    SettingsStash.stash!(
      shiny_streak_needed: 2,
      shiny_action: "alarme"
    )

    test = self()
    escape_fun = fn reason -> send(test, {:escaped, reason}) end

    {:ok, guard} = ShinyGuard.start_link(name: nil, active: true, escape_fun: escape_fun)
    %{guard: guard}
  end

  defp shiny_obs(px \\ 40),
    do: %{
      hostile: nil,
      shiny: %{name: "Shiny Seadra", px: px},
      shiny_scores: [{"Shiny Seadra", px}]
    }

  defp clean_obs, do: %{hostile: nil, shiny: nil, shiny_scores: [{"Shiny Seadra", 0}]}

  test "streak de avistamentos com ação alarme: broadcasta {:rule_alarm, _} UMA vez", %{
    guard: guard
  } do
    Phoenix.PubSub.subscribe(Pokex.PubSub, "combat")

    send(guard, {:world, :arena, shiny_obs()})
    refute_receive {:rule_alarm, _}, 50

    send(guard, {:world, :arena, shiny_obs()})
    assert_receive {:rule_alarm, reason}, 500
    assert reason =~ "SHINY na área: Shiny Seadra"
    assert reason =~ "LUTA"

    # refractory: right after firing, more sightings stay silent
    send(guard, {:world, :arena, shiny_obs()})
    send(guard, {:world, :arena, shiny_obs()})
    refute_receive {:rule_alarm, _}, 100
  end

  test "um frame limpo no meio zera o streak (debounce real)", %{guard: guard} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, "combat")

    send(guard, {:world, :arena, shiny_obs()})
    send(guard, {:world, :arena, clean_obs()})
    send(guard, {:world, :arena, shiny_obs()})

    refute_receive {:rule_alarm, _}, 100
  end

  test "ação fugir dispara o protocolo de fuga injetado", %{guard: guard} do
    Settings.put(:shiny_action, "fugir")

    send(guard, {:world, :arena, shiny_obs(77)})
    send(guard, {:world, :arena, shiny_obs(77)})

    assert_receive {:escaped, reason}, 500
    assert reason =~ "Shiny Seadra (77px)"
  end

  test "status expõe o estado do guarda", %{guard: guard} do
    status = ShinyGuard.status(guard)
    assert %{enabled?: _, attached?: false, streak: 0, signatures: _} = status
  end

  test "broadcasta a leitura ao vivo pro medidor do painel (throttled)", %{guard: guard} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, "shiny")

    send(guard, {:world, :arena, clean_obs()})
    assert_receive {:shiny_reading, %{scores: scores, min_px: _}}, 500
    assert scores["Shiny Seadra"] == 0

    # the throttle suppresses a second reading right after the first
    send(guard, {:world, :arena, clean_obs()})
    refute_receive {:shiny_reading, _}, 100
  end
end
