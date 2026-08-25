defmodule PokexWeb.SimLiveTest do
  @moduledoc """
  The page has to RENDER, armed, with a world in it.

  There was no test at this level, and the gap cost a live crash: the template
  still read `knobs.aoe_damage` after the knob became `aoe_damage_pct`, and
  every unit test stayed green because none of them rendered that branch. The
  first click in a browser was a KeyError page.

  A template is code. It reads keys off structs like any other code, and
  nothing else in the suite type-checks it.
  """
  use PokexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Pokex.Bots.Cavebot.Store
  alias Pokex.Sim.Fence

  # A route has to EXIST for any of this to render: without one the world is
  # nil and every panel is behind `:if={@world}`. That is correct behaviour on
  # the page and a trap in a test, because the page then renders empty and
  # green while proving nothing.
  setup do
    Store.put([route()])
    on_exit(fn -> Fence.disarm() end)
    :ok
  end

  defp route do
    %Pokex.Bots.Cavebot.Route{
      name: "sim",
      waypoints:
        for {x, y, z} <- [{100, 200, 5}, {110, 200, 5}] do
          %{
            x: x,
            y: y,
            z: z,
            action: :walk,
            stops: [],
            at: nil,
            dwell_ms: nil,
            park_point: nil,
            park_tiles: nil,
            fight_ms: nil,
            gather_ms: 2_000,
            combo: [],
            skills: [],
            gather_wait_ms: nil
          }
        end
    }
  end

  test "the page renders before anything is armed", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/sim")

    assert html =~ "Simulação desarmada"
  end

  # A battle fact left on the shared blackboard by ANOTHER producer carries no
  # `enemies_detail` — and took this page down with a FunctionClauseError while
  # rendering (CI, 2026-08-24). The blackboard is shared; the page reads it.
  test "a battle fact with no detail renders instead of crashing", %{conn: conn} do
    Pokex.Perception.WorldState.put(
      :battle,
      %{enemies: [0, 1], red: [], locked?: false, locked_row: nil},
      System.monotonic_time(:millisecond)
    )

    on_exit(fn -> Pokex.Perception.WorldState.forget(:battle) end)

    {:ok, _live, html} = live(conn, ~p"/sim")

    assert html =~ "linha 0"
    assert html =~ "linha 1"
  end

  test "armed, every panel renders — the map, the combo and the calibration table", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/sim")

    html = live |> element("button", "Armar simulação") |> render_click()

    assert html =~ "O combo que mata"
    assert html =~ "Mesa de calibragem"
    assert html =~ "seu pokémon"
  end

  # The table is the answer to "validar vários cenários": one row per scenario,
  # and a template that reads outcome keys is code nothing else type-checks.
  test "rodar TODOS renders one row per scenario, with the knobs it used", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/sim")

    html = live |> element("button", "Rodar TODOS") |> render_click()

    assert html =~ "Todos os cenários"
    assert html =~ "engaja a partir de"

    for scenario <- Pokex.Sim.Scenario.all() do
      assert html =~ scenario.name, "faltou a linha de #{scenario.id}"
    end

    # "Ele cai" is the one run that must not read as a clean night
    assert html =~ "caiu"
  end

  # The scoreboard is the instrument he tunes on, and a template that reads
  # nested outcome keys is code nothing else type-checks.
  test "o placar renderiza os seis mostradores, a comparação e a ressalva", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/sim")

    html = live |> element("button", "Placar") |> render_click()

    assert html =~ "Placar da caçada"

    for label <- ["mortos/min", "quedas/min", "sem cooldown", "no chão", "pilha (mediana)"] do
      assert html =~ label, "faltou o mostrador de #{label}"
    end

    # a comparação existe e é nomeada
    assert html =~ "O revive como reset de cooldown (R3b)"
    assert html =~ "revives proativos"

    # uma linha por cenário
    for scenario <- Pokex.Sim.Scenario.all() do
      assert html =~ scenario.name, "faltou a linha de #{scenario.id}"
    end

    # e a ressalva honesta sobre o que os números valem
    assert html =~ "Comparação vale"
  end

  # As quatro medições que faltavam pro placar virar absoluto. Sem noite
  # medida, cada uma tem que DIZER que não mediu em vez de mostrar um padrão.
  test "as quatro medições aparecem, e uma noite vazia diz que não mediu", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/sim")

    assert html =~ "As quatro medições do jogo"

    for label <- ["a mordida", "o custo de um bicho", "o preço do F4", "F4 zera cooldown?"] do
      assert html =~ label, "faltou a leitura de #{label}"
    end

    assert html =~ "a noite não mediu"
    assert html =~ "faça sair o pokémon de", "a página tem que dizer COMO medir a quarta"
  end

  test "opening the calibration table renders every field it offers", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/sim")
    live |> element("button", "Armar simulação") |> render_click()

    html = live |> element("button", "Mesa de calibragem") |> render_click()

    for knob <- Pokex.Sim.Setup.tunable() do
      assert html =~ ~s(name="#{knob}"), "faltou o campo de #{knob} na mesa"
    end
  end

  test "the close-up and the whole-route view both render", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/sim")
    live |> element("button", "Armar simulação") |> render_click()

    perto = live |> element("button", "aproximar") |> render_click()
    assert perto =~ "perto"

    assert live |> element("button", "perto") |> render_click() =~ "aproximar"
  end
end
