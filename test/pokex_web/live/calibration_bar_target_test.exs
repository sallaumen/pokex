defmodule PokexWeb.CalibrationBarTargetTest do
  @moduledoc """
  The page has accepted `?bar=<name>` and saved to that pokémon since the
  feature landed — and said nothing about it. A calibration aimed at one
  creature looked identical to the shared one, so there was no way to tell which
  one you were doing, and no way in from the page itself.
  """
  use PokexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Pokex.Pokedex.Team

  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

    Team.add("Vespiquen")
    Team.add("Gardevoir")
    :ok
  end

  @tag :tmp_dir
  test "says whose bar is being calibrated", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/calibration?#{[bar: "Vespiquen"]}")

    assert html =~ "calibrando a barra de"
    assert html =~ "Vespiquen"
  end

  @tag :tmp_dir
  test "offers a way back to the screen's own bar", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/calibration?#{[bar: "Vespiquen"]}")

    assert has_element?(view, ~s{a[href="/calibration"]}, "calibrar a barra da tela")
  end

  @tag :tmp_dir
  test "offers every team member as a target when none is aimed at", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/calibration")

    assert has_element?(view, ~s{a[href="/calibration?bar=Vespiquen"]})
    assert has_element?(view, ~s{a[href="/calibration?bar=Gardevoir"]})
  end

  @tag :tmp_dir
  test "does not announce a target when calibrating the screen's bar", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/calibration")

    refute html =~ "calibrando a barra de"
  end

  # A name typed into the URL that is not on the team would write a bar nothing
  # will ever read.
  @tag :tmp_dir
  test "ignores a pokemon that is not on the team", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/calibration?#{[bar: "Mewtwo"]}")

    refute html =~ "calibrando a barra de"
  end
end
