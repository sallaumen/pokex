defmodule PokexWeb.FishingLabLiveTest do
  use PokexWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  test "renders the local fishing lab", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/fishing-lab")

    assert html =~ "Laboratorio do peixe"
    assert has_element?(view, "#fishing-lab[phx-hook='FishingLab']")
    assert has_element?(view, "#fishing-game-canvas")
    assert has_element?(view, ~s(button[data-lab-action="toggle-auto"]))
    assert has_element?(view, ~s(input[data-lab-range="latency"]))

    # low-fps vision simulation + pilot comparison controls
    assert html =~ "FPS da visao"
    assert html =~ "Leituras perdidas"
    assert has_element?(view, ~s(input[data-lab-range="vision-fps"][value="7"]))
    assert has_element?(view, ~s(input[data-lab-range="loss"][value="0"]))
    assert has_element?(view, ~s(button[data-lab-pilot="reactive"]))
    assert has_element?(view, ~s(button[data-lab-pilot="predictive"].btn-active))
    assert has_element?(view, ~s([data-stat="score"]))
    assert has_element?(view, ~s([data-stat="reading-age"]))
  end
end
