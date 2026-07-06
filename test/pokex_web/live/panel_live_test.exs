defmodule PokexWeb.PanelLiveTest do
  use PokexWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  setup do
    {:ok, _} = Pokex.Rig.Fake.start_link()
    :ok
  end

  @tag :tmp_dir
  test "start without calibration shows preflight error", %{conn: conn, tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "idle"

    view |> element("button", "Start") |> render_click()
    assert render(view) =~ "calibração"
  end

  test "renders pubsub snapshots", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")

    snapshot = %{
      state: :watching,
      counters: %{cycles: 3, hooked: 2, fights: 1, loots: 1, captures: 1, failures: 0},
      error: nil
    }

    Phoenix.PubSub.broadcast(Pokex.PubSub, Pokex.Bots.Fisher.topic(), {:fisher, snapshot})
    assert render(view) =~ "watching"
    assert render(view) =~ ">3<"
  end

  test "saves glow threshold", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    view |> form("#threshold-form", %{"threshold" => "21.5"}) |> render_submit()
    assert Pokex.Settings.get(:glow_threshold) == 21.5
    Pokex.Settings.put(:glow_threshold, nil)
  end
end
