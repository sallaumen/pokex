defmodule PokexWeb.WorldLiveTest do
  use PokexWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Pokex.Perception.WorldState

  setup do
    # one shared blackboard: start from an empty world, never from the last test's
    WorldState.clear()

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

    WorldState.put(:minimap, %{pos: {337, 46_107, 4}}, now)

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

  describe "the position" do
    test "appears with its age and says it IS being read", %{conn: conn} do
      now = System.monotonic_time(:millisecond)
      WorldState.put(:minimap, %{pos: {337, 46_107, 4}}, now)

      {:ok, view, _html} = live(conn, ~p"/world")

      position = view |> element("#world-position") |> render()
      assert position =~ "337, 46107 · andar 4"
      assert position =~ "lendo tua posição"
      assert position =~ "agora"
    end

    # "?" did not say WHICH of the two problems it was, and they have opposite fixes
    test "a stopped read is spelled out", %{conn: conn} do
      now = System.monotonic_time(:millisecond)
      WorldState.put(:minimap, %{pos: {337, 46_107, 4}}, now - 20_000)

      {:ok, view, _html} = live(conn, ~p"/world")

      position = view |> element("#world-position") |> render()
      assert position =~ "NÃO estou lendo tua posição"
      assert position =~ "há 20s"
    end

    test "the good/bad read ratio counts the minimap's publications", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/world")

      assert view |> element("#world-read-health") |> render() =~ "aguardando a primeira leitura"

      for obs <- [%{pos: {1, 2, 3}}, %{pos: {1, 2, 3}}, %{pos: nil}] do
        Phoenix.PubSub.broadcast(Pokex.PubSub, Pokex.Perception.topic(), {:world, :minimap, obs})
      end

      assert view |> element("#world-read-health") |> render() =~ "67% (2 ok, 1 falhas)"
    end
  end

  test "the periodic refresh picks up facts published after mount", %{conn: conn} do
    Enum.each([:battle, :arena, :corpses, :mini_game], &WorldState.forget/1)

    {:ok, view, _html} = live(conn, ~p"/world")
    # scoped to the page's OWN snapshot: the header rides on every route and
    # carries a `mini_game` alarm sector, so a bare substring over the whole
    # document stopped answering the question this test asks
    refute has_element?(view, "#world-facts")

    WorldState.put(
      :mini_game,
      %{playing?: false, confidence: 0.1},
      System.monotonic_time(:millisecond)
    )

    send(view.pid, :refresh)
    html = view |> element("#world-facts") |> render()

    assert html =~ "mini_game"
    assert html =~ "fora do jogo"
  end
end
