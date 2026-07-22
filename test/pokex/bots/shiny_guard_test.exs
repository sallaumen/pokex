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
      shiny_guard_enabled: true,
      shiny_confirm_ms: 40,
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

  # Deliver EXACTLY like the Feed does — a PubSub broadcast on the world topic.
  # The live-sighting bug shipped because tests sent messages straight to the
  # process: an unsubscribed guard passed every test while deaf in production.
  defp world_broadcast(obs) do
    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      Pokex.Perception.topic(),
      {:world, :battle, obs}
    )
  end

  @tag :tmp_dir
  test "UM avistamento não refutado pela janela de confirmação dispara o alarme UMA vez", %{
    guard: guard
  } do
    Phoenix.PubSub.subscribe(Pokex.PubSub, "combat")

    # the feed DEDUPES: a calm list with a shiny broadcasts ONCE — one
    # message must be enough once the confirm window passes clean
    world_broadcast(shiny_obs())

    assert_receive {:rule_alarm, reason}, 500
    assert reason =~ "SHINY na lista de batalha"
    assert reason =~ "LUTA"

    # refractory: more sightings right after stay silent
    world_broadcast(shiny_obs())
    refute_receive {:rule_alarm, _}, 150
    _ = ShinyGuard.status(guard)
  end

  @tag :tmp_dir
  test "um frame limpo dentro da janela refuta o avistamento (debounce real)", %{guard: guard} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, "combat")

    world_broadcast(shiny_obs())
    world_broadcast(clean_obs())

    refute_receive {:rule_alarm, _}, 200
    _ = ShinyGuard.status(guard)
  end

  @tag :tmp_dir
  test "guard DESLIGADO ignora observações da batalha (o combate também atacha o feed)", %{
    guard: guard
  } do
    Settings.put(:shiny_guard_enabled, false)
    Phoenix.PubSub.subscribe(Pokex.PubSub, "combat")

    world_broadcast(shiny_obs())

    refute_receive {:rule_alarm, _}, 200
    _ = ShinyGuard.status(guard)
  end

  @tag :tmp_dir
  test "ação fugir dispara o protocolo de fuga injetado", %{guard: _guard} do
    Settings.put(:shiny_action, "fugir")

    world_broadcast(shiny_obs(77))

    assert_receive {:escaped, reason}, 500
    assert reason =~ "estrela 77px"
  end

  @tag :tmp_dir
  test "status expõe o estado do guarda", %{guard: guard} do
    status = ShinyGuard.status(guard)
    assert %{enabled?: _, attached?: false, pending?: false, star_min_px: _} = status
  end

  @tag :tmp_dir
  test "broadcasta a leitura ao vivo pro medidor do painel (throttled)", %{guard: guard} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, "shiny")

    world_broadcast(clean_obs())
    assert_receive {:shiny_reading, %{star_px: 0, min_px: _}}, 500

    # the throttle suppresses a second reading right after the first
    world_broadcast(clean_obs())
    refute_receive {:shiny_reading, _}, 100
    _ = ShinyGuard.status(guard)
  end
end
