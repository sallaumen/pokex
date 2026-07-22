defmodule PokexWeb.WorldLiveTest do
  use PokexWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Pokex.Perception.WorldState

  setup do
    on_exit(fn ->
      Enum.each(
        [:battle, :corpses, :mini_game, :world_test_key, :hud, :team, :minimap],
        &WorldState.forget/1
      )
    end)

    :ok
  end

  test "the snapshot card shows the whole game state at a glance", %{conn: conn} do
    now = System.monotonic_time(:millisecond)

    WorldState.put(
      :hud,
      %{level: 90, food: 1525, fishing: 96, slots: %{f1: 322, f2: 36, e: 7, s_q: 43}},
      now
    )

    WorldState.put(
      :team,
      %{pokemon_hp: {5559, 6410}, rows: [%{slot: 2, present?: true, hp_pct: 0.86}]},
      now
    )

    WorldState.put(:minimap, %{pos: {337, 46107, 4}}, now)

    WorldState.put(
      :battle,
      %{
        enemies: [0],
        locked?: true,
        shiny_rows: [],
        enemies_detail: [%{row: 0, name: "Pidgeot"}]
      },
      now
    )

    {:ok, view, html} = live(conn, ~p"/world")

    assert has_element?(view, "#world-snapshot")
    assert html =~ "5559/6410"
    assert html =~ "337, 46107"
    assert html =~ "Pidgeot"
    assert html =~ "322"
    assert html =~ "C+2"
  end

  test "renders the empty state before anything is published", %{conn: conn} do
    Enum.each([:battle, :arena, :corpses, :mini_game], &WorldState.forget/1)

    {:ok, _view, html} = live(conn, ~p"/world")

    assert html =~ "Mundo"
    assert html =~ "nada publicado ainda"
  end

  test "shows each fact with a per-key summary and its age", %{conn: conn} do
    now = System.monotonic_time(:millisecond)

    WorldState.put(:mini_game, %{playing?: true, confidence: 0.87}, now)

    WorldState.put(
      :battle,
      %{enemies: [0, 2], red: [], locked?: true, locked_row: 0, captured_at: now},
      now
    )

    WorldState.put(:corpses, %{scanning?: true, corpses: [{130, 224}], captured_at: now}, now)

    {:ok, _view, html} = live(conn, ~p"/world")

    assert html =~ "mini_game"
    assert html =~ "jogando"
    assert html =~ "0.87"

    assert html =~ "battle"
    assert html =~ "2 na lista"
    assert html =~ "lock na linha 0"

    assert html =~ "corpses"
    assert html =~ "1 corpo"

    assert html =~ "ms"
  end

  test "an unknown key falls back to a raw inspect summary", %{conn: conn} do
    WorldState.put(:world_test_key, %{anything: 42}, System.monotonic_time(:millisecond))

    {:ok, _view, html} = live(conn, ~p"/world")

    assert html =~ "world_test_key"
    assert html =~ "anything"
  end

  test "the periodic refresh picks up facts published after mount", %{conn: conn} do
    Enum.each([:battle, :arena, :corpses, :mini_game], &WorldState.forget/1)

    {:ok, view, html} = live(conn, ~p"/world")
    refute html =~ "mini_game"

    WorldState.put(
      :mini_game,
      %{playing?: false, confidence: 0.1},
      System.monotonic_time(:millisecond)
    )

    send(view.pid, :refresh)
    html = render(view)

    assert html =~ "mini_game"
    assert html =~ "fora do jogo"
  end
end
