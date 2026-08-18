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

    assert html =~ "Calibrando a barra de"
    assert html =~ "Vespiquen"
  end

  # The count field used to start at the SCREEN's number: Vespiquen carries 8
  # and the screen said 9, so capturing without noticing rewrote her bar with a
  # slot she does not have — silently, and with the wrong number sitting in the
  # field looking like hers.
  @tag :tmp_dir
  test "the skill count starts at the aimed pokemon's own, not the screen's", %{conn: conn} do
    Team.set_bar("Vespiquen", %{region: {1, 2, 300, 40}, count: 8, refs: nil})

    {:ok, _view, html} = live(conn, ~p"/calibration?#{[bar: "Vespiquen"]}")

    assert html =~ "8 skills"
  end

  @tag :tmp_dir
  test "the banner carries the two-click action, so it does not have to be hunted for", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/calibration?#{[bar: "Vespiquen"]}")

    assert has_element?(view, ~s{button[phx-click="calibrate_skillbar"]}, "Marcar a barra dele")
  end

  @tag :tmp_dir
  test "the picker marks who already carries a bar of their own", %{conn: conn} do
    Team.set_bar("Vespiquen", %{region: {1, 2, 300, 40}, count: 8, refs: nil})

    {:ok, _view, html} = live(conn, ~p"/calibration")

    assert html =~ "✓ 8"
  end

  @tag :tmp_dir
  test "offers a way back to the screen's own bar", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/calibration?#{[bar: "Vespiquen"]}")

    assert has_element?(view, ~s{a[href="/calibration"]}, "calibrar a da tela")
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

    refute html =~ "Calibrando a barra de"
  end

  # This is the bug he reported: he could only calibrate Vespiquen at her real
  # 8, and every OTHER pokémon offered 9 — Shiny Vileplume's leftover count
  # from before per-pokémon bars existed, sitting in the legacy global file and
  # looking exactly as confident as a real answer.
  @tag :tmp_dir
  test "warns when the count is borrowed from another calibration, not this pokemon's own", %{
    conn: conn
  } do
    {:ok, _view, html} = live(conn, ~p"/calibration?#{[bar: "Gardevoir"]}")

    assert html =~ "sobra de outra calibração"
  end

  @tag :tmp_dir
  test "says nothing once the pokemon has calibrated its own bar", %{conn: conn} do
    Team.set_bar("Gardevoir", %{region: {1, 2, 300, 40}, count: 8, refs: nil})

    {:ok, _view, html} = live(conn, ~p"/calibration?#{[bar: "Gardevoir"]}")

    refute html =~ "sobra de outra calibração"
  end

  # Typing the real number in IS the fix: the warning must clear the moment he
  # does, in the same session, without requiring a page reload to notice it
  # took.
  @tag :tmp_dir
  test "typing the real count clears the warning without a reload", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/calibration?#{[bar: "Gardevoir"]}")
    assert html =~ "sobra de outra calibração"

    html =
      view
      |> form("#skill-count-form", skill_bar: %{count: "8"})
      |> render_change()

    refute html =~ "sobra de outra calibração"
  end

  # A name typed into the URL that is not on the team would write a bar nothing
  # will ever read.
  @tag :tmp_dir
  test "ignores a pokemon that is not on the team", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/calibration?#{[bar: "Mewtwo"]}")

    refute html =~ "Calibrando a barra de"
  end
end
