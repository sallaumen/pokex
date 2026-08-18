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

  test "armed, every panel renders — the map, the combo and the calibration table", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/sim")

    html = live |> element("button", "Armar simulação") |> render_click()

    assert html =~ "O combo que mata"
    assert html =~ "Mesa de calibragem"
    assert html =~ "seu pokémon"
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
