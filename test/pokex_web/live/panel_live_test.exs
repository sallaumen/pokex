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
    assert html =~ "parado"

    view |> element("#start-bot") |> render_click()
    assert render(view) =~ "calibração"
  end

  test "renders the independent status pills on mount", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")

    assert html =~ "Pesca"
    assert html =~ "Batalha"
    assert html =~ "Mini game"
    assert html =~ "Automações"
    assert html =~ "parado"
    assert has_element?(view, "#panel-navigation[phx-update=ignore]")
    assert has_element?(view, "#panel-navigation-toggle[aria-label='Abrir navegação']")
    assert has_element?(view, "#panel-nav-calibration[href='/calibration']")
    assert has_element?(view, "#panel-nav-diagnostics[href='/diagnostics']")
    assert has_element?(view, "#panel-nav-fishing-lab[href='/fishing-lab']")
  end

  test "a fishing broadcast updates only the fishing pill", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")

    snapshot = %{
      state: :watching,
      counters: %{cycles: 3, hooked: 2, fights: 1, loots: 1, captures: 1, failures: 0},
      error: nil
    }

    Phoenix.PubSub.broadcast(Pokex.PubSub, "fishing", {:fishing, snapshot})

    html = render(view)
    assert html =~ "vigiando"
    assert view |> element("#counter-cycles") |> render() =~ ~r/>\s*3\s*</

    # combat pill untouched — still parado
    assert html =~ "parado"
  end

  test "a combat broadcast updates only the combat pill, including the locked row", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")

    snapshot = %{
      state: :fighting,
      counters: %{fights: 1, loots: 0, captures: 0, failures: 0},
      error: nil,
      locked_row: 2
    }

    Phoenix.PubSub.broadcast(Pokex.PubSub, "combat", {:combat, snapshot})

    html = render(view)
    assert html =~ "lutando linha 2"
  end

  test "a loot broadcast updates the loot pill and its loots/captures counters", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")

    snapshot = %{state: :looting, counters: %{loots: 3, captures: 2, failures: 0}, error: nil}
    Phoenix.PubSub.broadcast(Pokex.PubSub, "loot", {:loot, snapshot})

    # the loot pill reflects the worker's state, and its counters drive the Loots/Capturas tallies
    assert render(view) =~ "coletando"
    assert has_element?(view, "[data-testid=loot-pill][data-state=looting]")
  end

  test "a mini game broadcast updates the mini game pill", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")

    snapshot = %{
      state: :playing,
      in_game?: true,
      confidence: 0.91,
      counters: %{detections: 1, clears: 0, failures: 0},
      error: nil,
      transition: :entered
    }

    Phoenix.PubSub.broadcast(Pokex.PubSub, "mini_game", {:mini_game, snapshot})

    assert render(view) =~ "em jogo"
    assert has_element?(view, "[data-testid=mini-game-pill][data-state=playing]")
  end

  test "macro worker logs append to the activity feed", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")

    Phoenix.PubSub.broadcast(Pokex.PubSub, "fishing", {:fishing_log, :macro, "lançando a linha"})
    Phoenix.PubSub.broadcast(Pokex.PubSub, "combat", {:combat_log, :macro, "mirando linha 0"})
    Phoenix.PubSub.broadcast(Pokex.PubSub, "mini_game", {:mini_game_log, :macro, "pausando"})

    html = render(view)
    assert html =~ "lançando a linha"
    assert html =~ "mirando linha 0"
    assert html =~ "pausando"
  end

  test "debug logs are hidden until the debug toggle is on", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")

    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      "fishing",
      {:fishing_log, :debug, "vigiando: bolhas 3px"}
    )

    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      "body",
      {:body_log, :debug, "fila >N key:shift+v espera=42ms h=0 n=0"}
    )

    refute render(view) =~ "vigiando: bolhas 3px"
    refute render(view) =~ "fila &gt;N key:shift+v"

    view |> element(~s(input[phx-click="toggle_debug"])) |> render_click()
    html = render(view)
    assert html =~ "vigiando: bolhas 3px"
    assert html =~ "fila &gt;N key:shift+v"
  end

  test "tolerates a legacy 2-tuple log broadcast without crashing", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")

    # A worker on an old build mid hot-reload can still send the pre-level shape.
    Phoenix.PubSub.broadcast(Pokex.PubSub, "fishing", {:fishing_log, "stale build line"})
    view |> element(~s(input[phx-click="toggle_debug"])) |> render_click()
    assert render(view) =~ "stale build line"
  end

  @tag :tmp_dir
  test "exports the recent events to a downloadable file", %{conn: conn, tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

    {:ok, view, _} = live(conn, ~p"/")
    Phoenix.PubSub.broadcast(Pokex.PubSub, "combat", {:combat_log, :macro, "matou o bicho"})
    render(view)

    view |> element(~s(button[phx-click="export_events"])) |> render_click()
    assert render(view) =~ "eventos exportados"
    assert [_one] = Path.wildcard(Path.join([tmp, "exports", "events-*.log"]))
  end

  @tag :tmp_dir
  test "screenshot + diagnostic-export controls appear when calibrated", %{
    conn: conn,
    tmp_dir: tmp
  } do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)
    save_calibration()

    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, ~s(button[phx-click="export_diagnostic"]))
    assert has_element?(view, ~s(button[phx-value-region="battle"]))
    assert has_element?(view, ~s(button[phx-value-region="screen"]))
  end

  @tag :tmp_dir
  test "exporting the diagnostic renders the battle matrix and writes latest.json", %{
    conn: conn,
    tmp_dir: tmp
  } do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)
    save_calibration()

    # Re-script the shared Fake so every captured region decodes to a real PNG,
    # exercising the full path: capture → Frame → Vision → matrix → rendered grid.
    Agent.stop(Pokex.Rig.Fake)

    {:ok, _} =
      Pokex.Rig.Fake.start_link(%{
        capture: [
          {:ok, png!(tmp, "g.png", 8, 8, {0, 180, 200})},
          {:ok, png!(tmp, "b.png", 20, 12, {0, 200, 0})},
          {:ok, png!(tmp, "s.png", 8, 12, {255, 0, 0})},
          {:ok, png!(tmp, "a.png", 12, 12, {0, 0, 0})},
          {:ok, png!(tmp, "p.png", 50, 50, {0, 0, 0})}
        ],
        capture_screen: [{:ok, png!(tmp, "scr.png", 60, 40, {0, 0, 0})}]
      })

    {:ok, view, _} = live(conn, ~p"/")
    view |> element(~s(button[phx-click="export_diagnostic"])) |> render_click()

    html = render(view)
    assert html =~ "diagnóstico exportado"
    assert html =~ "matriz do painel Batalha"
    assert File.regular?(Path.join([tmp, "exports", "latest.json"]))
  end

  defp png!(dir, name, w, h, {r, g, b}) do
    path = Path.join(dir, name)
    row = for _ <- 1..w, do: {r, g, b, 255}
    Pokex.PngFixtures.write!(path, for(_ <- 1..h, do: row))
    path
  end

  test "toggles require_cooldowns and saves the hook skills", %{conn: conn} do
    req = Pokex.Settings.get(:require_cooldowns)
    keys = Pokex.Settings.get(:hook_skill_keys)

    on_exit(fn ->
      Pokex.Settings.put(:require_cooldowns, req)
      Pokex.Settings.put(:hook_skill_keys, keys)
    end)

    {:ok, view, _} = live(conn, ~p"/")

    view |> element(~s(input[phx-click="toggle_require_cooldowns"])) |> render_click()
    refute Pokex.Settings.get(:require_cooldowns) == req

    view |> form("#hook-skills-form", %{"hook_skills" => "5 6 7"}) |> render_submit()
    assert Pokex.Settings.get(:hook_skill_keys) == ["5", "6", "7"]
  end

  @tag :tmp_dir
  test "the 'Ler' button reads the skill bar on demand", %{conn: conn, tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

    row = List.duplicate({200, 200, 0, 255}, 12) ++ List.duplicate({20, 20, 20, 255}, 2)
    bar = Pokex.PngFixtures.write!(Path.join(tmp, "bar.png"), [row])
    Agent.stop(Pokex.Rig.Fake)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, bar}]})

    Pokex.Calibration.save(%Pokex.Calibration{
      scale: 1.0,
      screen_w: 100,
      screen_h: 75,
      water_point: {50, 30},
      glow_region: {18, -2, 64, 64},
      battle_region: {70, 10, 20, 30},
      arena_region: {20, 20, 60, 40},
      neutral_point: {52, 36},
      skill_bar_region: {0, 0, 14, 1}
    })

    {:ok, view, _} = live(conn, ~p"/")
    assert render(view) =~ "Clique em Ler"

    view |> element(~s(button[phx-click="read_cooldowns"])) |> render_click()
    # reading done → the hint is replaced by the per-slot pills
    refute render(view) =~ "Clique em Ler"
  end

  defp save_calibration do
    Pokex.Calibration.save(%Pokex.Calibration{
      scale: 2.0,
      screen_w: 1000,
      screen_h: 700,
      water_point: {400, 300},
      glow_region: {368, 268, 64, 64},
      battle_region: {700, 100, 260, 200},
      arena_region: {200, 100, 400, 400},
      neutral_point: {420, 350}
    })
  end

  test "a panic broadcast idles both pills and is idempotent on repeat", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")

    # Get both pills into non-idle state first.
    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      "fishing",
      {:fishing, %{state: :watching, counters: %{}, error: nil}}
    )

    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      "combat",
      {:combat, %{state: :scanning, counters: %{}, error: nil, locked_row: nil}}
    )

    assert render(view) =~ "vigiando"

    Phoenix.PubSub.broadcast(Pokex.PubSub, "fishing", {:panic, "kill corner"})
    Phoenix.PubSub.broadcast(Pokex.PubSub, "combat", {:panic, "kill corner"})

    html = render(view)
    refute html =~ "vigiando"
    assert html =~ "parado"

    logs_after_first = view |> element("#activity-feed") |> render()

    # The Guardian re-broadcasts {:panic} on every poll tick while the cursor
    # sits in the corner — a second (and third) panic must not duplicate log
    # spam.
    Phoenix.PubSub.broadcast(Pokex.PubSub, "fishing", {:panic, "kill corner"})
    Phoenix.PubSub.broadcast(Pokex.PubSub, "combat", {:panic, "kill corner"})
    Phoenix.PubSub.broadcast(Pokex.PubSub, "fishing", {:panic, "kill corner"})

    logs_after_repeat = view |> element("#activity-feed") |> render()
    assert logs_after_first == logs_after_repeat
  end

  test "saves glow threshold", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    view |> form("#threshold-form", %{"threshold" => "21.5"}) |> render_submit()
    assert Pokex.Settings.get(:glow_threshold) == 21.5
    Pokex.Settings.put(:glow_threshold, nil)
  end

  test "saves combat timing knobs and ignores blanks", %{conn: conn} do
    keys = [
      :tick_ms_fighting,
      :combat_skill_burst_size,
      :combat_skill_tap_count,
      :combat_skill_gap_ms,
      :combat_skill_jitter_ms,
      :target_lost_streak,
      :fight_timeout_ms
    ]

    originals = Map.new(keys, &{&1, Pokex.Settings.get(&1)})
    on_exit(fn -> Enum.each(originals, fn {k, v} -> Pokex.Settings.put(k, v) end) end)

    {:ok, view, _} = live(conn, ~p"/")

    view
    |> form("#timing-form", %{
      "tick_ms_fighting" => "120",
      "combat_skill_burst_size" => "3",
      "combat_skill_tap_count" => "0",
      "combat_skill_gap_ms" => "25",
      "combat_skill_jitter_ms" => "20",
      "target_lost_streak" => "",
      "fight_timeout_ms" => "5000"
    })
    |> render_submit()

    assert Pokex.Settings.get(:tick_ms_fighting) == 120
    assert Pokex.Settings.get(:combat_skill_burst_size) == 3
    # positive timing knobs clamp 0 to 1 instead of persisting an inert combat setting.
    assert Pokex.Settings.get(:combat_skill_tap_count) == 1
    assert Pokex.Settings.get(:combat_skill_gap_ms) == 25
    assert Pokex.Settings.get(:combat_skill_jitter_ms) == 20
    assert Pokex.Settings.get(:fight_timeout_ms) == 5000
    # blank left the current value untouched
    assert Pokex.Settings.get(:target_lost_streak) == originals.target_lost_streak
  end
end
