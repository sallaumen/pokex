defmodule PokexWeb.DiagnosticsLiveTest do
  use PokexWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  setup do
    {:ok, _} = Pokex.Rig.Fake.start_link()
    :ok
  end

  test "press is delayed then executed through the rig", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/diagnostics")

    view |> element("button[phx-value-combo='shift+z']") |> render_click()
    assert render(view) =~ "em 2s"

    send(view.pid, {:delayed_press, "shift+z"})
    assert render(view) =~ "press shift+z → :ok"
    assert Pokex.Rig.Fake.calls() == [{:press, "shift+z"}]
  end

  test "click goes straight through", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/diagnostics")

    view
    |> form("#click-form", %{"x" => "812", "y" => "402", "button" => "left"})
    |> render_submit()

    assert {:click, :left, {812, 402}} in Pokex.Rig.Fake.calls()
  end

  test "capture renders the image tag", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/diagnostics")

    html =
      view
      |> form("#capture-form", %{"x" => "0", "y" => "0", "w" => "100", "h" => "80"})
      |> render_submit()

    assert html =~ "/captures/diag.png"
    assert {:capture, {0, 0, 100, 80}, "diag.png"} in Pokex.Rig.Fake.calls()
  end
end
