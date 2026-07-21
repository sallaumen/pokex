defmodule PokexWeb.PanelLiveTest do
  use PokexWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  setup do
    {:ok, _} = Pokex.Rig.Fake.start_link()

    on_exit(fn ->
      Pokex.Perception.WorldState.forget(:calibration)
      Pokex.Perception.WorldState.forget(:session)
    end)

    :ok
  end

  test "a calibration edited after the last Start raises the stale banner", %{conn: conn} do
    # the stamp says the bots loaded mtime 123; the file on disk differs (absent here)
    Pokex.Perception.WorldState.put(
      :calibration,
      %{loaded_mtime: 123},
      System.monotonic_time(:millisecond)
    )

    {:ok, view, html} = live(conn, ~p"/")

    assert html =~ "calibração mudou"
    assert has_element?(view, "#calib-stale-banner button[phx-click='restart_bots']")
  end

  test "no stamp (bots never started) → no stale banner", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    refute has_element?(view, "#calib-stale-banner")
  end

  test "losing game focus shows the header badge — never the layout-shifting banner", %{
    conn: conn
  } do
    # The old banner sat right above the Start/Stop button and pushed it down
    # whenever Lucas clicked another window — an alert beside the logo (full
    # message on hover) keeps the layout identical in both states.
    {:ok, view, _} = live(conn, ~p"/")
    refute has_element?(view, "#focus-pause-badge")

    Phoenix.PubSub.broadcast(Pokex.PubSub, "focus", {:focus, %{focused?: false}})

    assert view |> element("#focus-pause-badge") |> render() =~ "Pausado por segurança"
    refute has_element?(view, "#focus-pause-banner")

    Phoenix.PubSub.broadcast(Pokex.PubSub, "focus", {:focus, %{focused?: true}})
    refute has_element?(view, "#focus-pause-badge")
  end

  test "the feed filter isolates one worker's lines and toggles off", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")

    send(view.pid, {:fishing_log, :macro, "linha-da-pesca"})
    send(view.pid, {:combat_log, :macro, "linha-do-combate"})

    html = render(view)
    assert html =~ "linha-da-pesca"
    assert html =~ "linha-do-combate"

    view |> element("button[phx-value-source='🎣']") |> render_click()
    html = render(view)
    assert html =~ "linha-da-pesca"
    refute html =~ "linha-do-combate"

    # click the same chip again → filter cleared
    view |> element("button[phx-value-source='🎣']") |> render_click()
    assert render(view) =~ "linha-do-combate"
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
    assert html =~ "Só pescar com vida"
    assert html =~ "Reposicionar após lutas"
    assert has_element?(view, "#fishing-hp-form")
    assert has_element?(view, "#panel-navigation[phx-update=ignore]")
    assert has_element?(view, "#panel-navigation-toggle[aria-label='Abrir navegação']")
    assert has_element?(view, "#panel-nav-calibration[href='/calibration']")
    assert has_element?(view, "#panel-nav-diagnostics[href='/diagnostics']")
    assert has_element?(view, "#panel-nav-fishing-lab[href='/fishing-lab']")
    assert has_element?(view, "#panel-nav-world[href='/world']")
    assert has_element?(view, "#panel-nav-pokedex[href='/pokedex']")
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

  test "hold reason and last action render as pill detail lines (Fase 1)", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")

    snapshot = %{
      state: :watching,
      counters: %{cycles: 1, hooked: 0, failures: 0},
      error: nil,
      hold_reason: "sem pokémon ativo",
      last_action: %{text: "arremesso da isca", at: System.monotonic_time(:millisecond) - 5_000}
    }

    Phoenix.PubSub.broadcast(Pokex.PubSub, "fishing", {:fishing, snapshot})

    html = render(view)
    assert html =~ "🔒 sem pokémon ativo"
    # the age is measured against the mount's clock, a hair before the broadcast — 4 or 5s
    assert html =~ ~r/arremesso da isca · há [45]s/
  end

  test "catcher and support errors surface in the error banners", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")

    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      "catcher",
      {:catcher,
       %{
         state: :idle,
         mode: "parado",
         counters: %{captures: 0, throws: 0, ignored: 0},
         error: "detector confuso"
       }}
    )

    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      "game",
      {:game,
       %{
         state: :idle,
         hp_pct: nil,
         enabled?: false,
         last_rescue_at: nil,
         counters: %{rescues: 0, potions: 0, reads: 0, failures: 0, repositions: 0},
         error: "leitura de vida falhou"
       }}
    )

    html = render(view)
    assert html =~ "detector confuso"
    assert html =~ "leitura de vida falhou"
  end

  test "sessão ativa mostra duração e taxas por hora no header", %{conn: conn} do
    at = System.monotonic_time(:millisecond)
    Pokex.Perception.WorldState.put(:session, %{started_at: at - 65_000}, at)
    on_exit(fn -> Pokex.Perception.WorldState.forget(:session) end)

    {:ok, view, html} = live(conn, ~p"/")

    assert has_element?(view, "#session-duration")
    assert html =~ "1m05s"
    assert html =~ "kills/h"
    assert html =~ "capturas/h"
  end

  test "sem sessão: nem relógio nem taxas", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    refute has_element?(view, "#session-duration")
    refute has_element?(view, "#session-rates")
  end

  test "condição de parada atingida: alarme 🛑 e o relógio da sessão some", %{conn: conn} do
    at = System.monotonic_time(:millisecond)
    Pokex.Perception.WorldState.put(:session, %{started_at: at - 5_000}, at)

    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, "#session-duration")

    # what the real stop does first: the fleet halt forgets the fact
    Pokex.Perception.WorldState.forget(:session)

    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      "combat",
      {:session_stop, "meta de kills atingida (200/200)"}
    )

    assert_push_event(view, "alarm", %{text: text})
    assert text =~ "meta de kills"
    assert render(view) =~ "caçada parada"
    refute has_element?(view, "#session-duration")
  end

  test "o form da fuga persiste direção, passos e espera da caminhada", %{conn: conn} do
    direction = Pokex.Settings.get(:escape_direction)
    steps = Pokex.Settings.get(:escape_steps)
    wait = Pokex.Settings.get(:escape_walk_wait_ms)

    on_exit(fn ->
      Pokex.Settings.put(:escape_direction, direction)
      Pokex.Settings.put(:escape_steps, steps)
      Pokex.Settings.put(:escape_walk_wait_ms, wait)
    end)

    {:ok, view, _} = live(conn, ~p"/")

    view
    |> form("#escape-cfg-form", %{
      "escape_direction" => "left",
      "escape_steps" => "3",
      "escape_walk_wait_ms" => "1500"
    })
    |> render_change()

    assert Pokex.Settings.get(:escape_direction) == "left"
    assert Pokex.Settings.get(:escape_steps) == 3
    assert Pokex.Settings.get(:escape_walk_wait_ms) == 1500
  end

  test "um {:rule_alarm, _} (anti-estagnação) toca o alarme sem parar nada", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")

    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      "combat",
      {:rule_alarm, "estagnação: sem kills nem fisgadas há 10min"}
    )

    assert_push_event(view, "alarm", %{text: text})
    assert text =~ "estagnação"
    assert render(view) =~ "⏰ estagnação"
  end

  @tag :tmp_dir
  test "guarda anti-shiny: toggle e config persistem; a sonda lê a arena e pontua", %{
    conn: conn,
    tmp_dir: tmp
  } do
    Application.put_env(:pokex, :home_dir, tmp)

    enabled = Pokex.Settings.get(:shiny_guard_enabled)
    names = Pokex.Settings.get(:shiny_watch_names)
    action = Pokex.Settings.get(:shiny_action)

    on_exit(fn ->
      Application.delete_env(:pokex, :home_dir)
      Pokex.Settings.put(:shiny_guard_enabled, enabled)
      Pokex.Settings.put(:shiny_watch_names, names)
      Pokex.Settings.put(:shiny_action, action)
      Pokex.Pokedex.ShinySignatures.clear()
    end)

    # an arena region for the probe to capture…
    Pokex.Calibration.save(%Pokex.Calibration{
      scale: 1.0,
      screen_w: 1000,
      screen_h: 700,
      water_point: {400, 300},
      glow_region: {0, 0, 20, 20},
      battle_region: {0, 0, 20, 20},
      arena_region: {100, 100, 60, 40},
      neutral_point: {500, 500}
    })

    # …and a REAL dark png at the shared Fake's default capture path
    File.mkdir_p!("/tmp/fake")
    dark = for _ <- 1..40, do: List.duplicate({20, 20, 20, 255}, 60)
    Pokex.PngFixtures.write!("/tmp/fake/shiny_probe.png", dark)

    {:ok, view, _} = live(conn, ~p"/")

    view |> element(~s(input[phx-click="toggle_shiny_guard"])) |> render_click()
    refute Pokex.Settings.get(:shiny_guard_enabled) == enabled

    view
    |> form("#shiny-cfg-form", %{"shiny_watch" => "Seadra", "shiny_action" => "fugir"})
    |> render_change()

    assert Pokex.Settings.get(:shiny_watch_names) == ["Seadra"]
    assert Pokex.Settings.get(:shiny_action) == "fugir"

    # the probe runs the REAL pipeline (repo sprites, sips conversion) against
    # the dark frame — every watched shiny must score 0px
    view |> element("#shiny-probe") |> render_click()
    html = render(view)
    assert html =~ "sonda: "
    assert html =~ "0px"
  end

  test "o protocolo de fuga: botão presente e o {:escape, _, _} toca o alarme com o resultado",
       %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")

    assert has_element?(view, "#test-escape[data-confirm]")

    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      "combat",
      {:escape, "shiny detectado", {:error, :not_calibrated}}
    )

    assert_push_event(view, "alarm", %{text: text})
    assert text =~ "FUGA: shiny detectado"
    assert text =~ "SEM escada calibrada"
    assert render(view) =~ "FUGA"
  end

  test "o form da anti-estagnação persiste janela e ação", %{conn: conn} do
    minutes = Pokex.Settings.get(:stagnation_minutes)
    action = Pokex.Settings.get(:stagnation_action)

    on_exit(fn ->
      Pokex.Settings.put(:stagnation_minutes, minutes)
      Pokex.Settings.put(:stagnation_action, action)
    end)

    {:ok, view, _} = live(conn, ~p"/")

    view
    |> form("#stagnation-form", %{"stagnation_minutes" => "10", "stagnation_action" => "parar"})
    |> render_change()

    assert Pokex.Settings.get(:stagnation_minutes) == 10
    assert Pokex.Settings.get(:stagnation_action) == "parar"
  end

  test "o form das condições de parada persiste minutos e kills", %{conn: conn} do
    minutes = Pokex.Settings.get(:stop_after_minutes)
    kills = Pokex.Settings.get(:stop_after_kills)

    on_exit(fn ->
      Pokex.Settings.put(:stop_after_minutes, minutes)
      Pokex.Settings.put(:stop_after_kills, kills)
    end)

    {:ok, view, _} = live(conn, ~p"/")

    view
    |> form("#stop-conditions-form", %{"stop_minutes" => "120", "stop_kills" => "200"})
    |> render_change()

    assert Pokex.Settings.get(:stop_after_minutes) == 120
    assert Pokex.Settings.get(:stop_after_kills) == 200
  end

  test "um erro NOVO de worker dispara o alarme uma vez; o gap dedupa a recaída", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")

    err = %{state: :error, counters: %{cycles: 0, hooked: 0, failures: 1}, error: "vara sumiu"}
    ok = %{err | state: :watching, error: nil}

    Phoenix.PubSub.broadcast(Pokex.PubSub, "fishing", {:fishing, err})
    assert_push_event(view, "alarm", %{text: text})
    assert text =~ "pesca em erro: vara sumiu"
    assert render(view) =~ "🔔"

    # clears and errors again INSIDE the min gap → the edge exists but the dedupe holds
    Phoenix.PubSub.broadcast(Pokex.PubSub, "fishing", {:fishing, ok})
    Phoenix.PubSub.broadcast(Pokex.PubSub, "fishing", {:fishing, err})
    render(view)
    refute_push_event(view, "alarm", %{text: _})
  end

  test "alarme mudo: sem som, mas o feed 🔔 registra", %{conn: conn} do
    sound = Pokex.Settings.get(:alarm_sound)
    on_exit(fn -> Pokex.Settings.put(:alarm_sound, sound) end)
    Pokex.Settings.put(:alarm_sound, false)

    {:ok, view, _} = live(conn, ~p"/")

    err = %{
      state: :error,
      counters: %{fights: 0, failures: 1},
      error: "tab não pegou",
      locked_row: nil
    }

    Phoenix.PubSub.broadcast(Pokex.PubSub, "combat", {:combat, err})

    assert render(view) =~ "batalha em erro: tab não pegou"
    refute_push_event(view, "alarm", %{text: _})
  end

  test "vida cruzando o limiar de resgate dispara o alarme de vida crítica", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")

    base = %{
      state: :monitoring,
      hp_pct: 80,
      enabled?: false,
      last_rescue_at: nil,
      counters: %{rescues: 0, potions: 0, reads: 1, failures: 0, repositions: 0},
      error: nil
    }

    Phoenix.PubSub.broadcast(Pokex.PubSub, "game", {:game, base})
    render(view)
    refute_push_event(view, "alarm", %{text: _})

    Phoenix.PubSub.broadcast(Pokex.PubSub, "game", {:game, %{base | hp_pct: 20}})
    assert_push_event(view, "alarm", %{text: text})
    assert text =~ "vida crítica: 20%"
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

  test "a catcher broadcast updates the catcher pill", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")

    snapshot = %{
      state: :armed,
      mode: "parado",
      counters: %{captures: 2, throws: 3, ignored: 0},
      error: nil
    }

    Phoenix.PubSub.broadcast(Pokex.PubSub, "catcher", {:catcher, snapshot})

    assert render(view) =~ "capturando"
    assert has_element?(view, "[data-testid=catcher-pill][data-state=armed]")
  end

  test "the global player mode selector persists and gates the toggles' hints", %{conn: conn} do
    mode = Pokex.Settings.get(:player_mode)
    on_exit(fn -> Pokex.Settings.put(:player_mode, mode) end)

    {:ok, view, _} = live(conn, ~p"/")

    view |> element(~s(button[phx-value-mode="movimento"])) |> render_click()
    assert Pokex.Settings.get(:player_mode) == "movimento"
    assert render(view) =~ "você saqueia e captura manualmente"

    view |> element(~s(button[phx-value-mode="parado"])) |> render_click()
    assert render(view) =~ "Reaprender chão"
  end

  test "loot and capture toggles persist independently", %{conn: conn} do
    loot = Pokex.Settings.get(:loot_enabled)
    cap = Pokex.Settings.get(:capture_enabled)

    on_exit(fn ->
      Pokex.Settings.put(:loot_enabled, loot)
      Pokex.Settings.put(:capture_enabled, cap)
    end)

    {:ok, view, _} = live(conn, ~p"/")

    view |> element(~s(input[phx-click="toggle_loot_enabled"])) |> render_click()
    refute Pokex.Settings.get(:loot_enabled) == loot

    view |> element(~s(input[phx-click="toggle_capture_enabled"])) |> render_click()
    refute Pokex.Settings.get(:capture_enabled) == cap
  end

  test "a política pós-luta (suporte espera a captura) persiste pelo toggle", %{conn: conn} do
    value = Pokex.Settings.get(:support_waits_capture)
    on_exit(fn -> Pokex.Settings.put(:support_waits_capture, value) end)

    {:ok, view, _} = live(conn, ~p"/")

    view |> element(~s(input[phx-click="toggle_support_waits_capture"])) |> render_click()
    refute Pokex.Settings.get(:support_waits_capture) == value
  end

  test "the busy placeholder snapshots render without crashing (worker missed its status window)",
       %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")

    # exactly the shape BotSupervisor.safe_status/2 falls back to for each worker — the
    # panel must render it as "ocupado" (not active) instead of raising on a missing key
    busy = %{state: :ocupado, counters: %{}, error: "sem resposta (captura lenta?)"}

    Phoenix.PubSub.broadcast(Pokex.PubSub, "fishing", {:fishing, busy})
    Phoenix.PubSub.broadcast(Pokex.PubSub, "combat", {:combat, Map.put(busy, :locked_row, nil)})
    Phoenix.PubSub.broadcast(Pokex.PubSub, "catcher", {:catcher, Map.put(busy, :mode, "parado")})

    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      "mini_game",
      {:mini_game, Map.merge(busy, %{in_game?: false, confidence: 0.0})}
    )

    Phoenix.PubSub.broadcast(Pokex.PubSub, "game", {:game, Map.put(busy, :hp_pct, nil)})

    html = render(view)
    assert html =~ "ocupado"
    # busy is UNKNOWN, not running — the header must not flip to active
    refute html =~ "Parar bot"
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

  test "mini game transitions push the sound event unless muted", %{conn: conn} do
    original = Pokex.Settings.get(:mini_game_sound)
    on_exit(fn -> Pokex.Settings.put(:mini_game_sound, original) end)
    Pokex.Settings.put(:mini_game_sound, true)

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
    assert_push_event(view, "mini-game-transition", %{transition: :entered})

    # the mute button silences the event at the SOURCE (no push at all)
    view |> element(~s(button[phx-click="toggle_mini_game_sound"])) |> render_click()
    assert Pokex.Settings.get(:mini_game_sound) == false
    assert render(view) =~ "mudo"

    Phoenix.PubSub.broadcast(Pokex.PubSub, "mini_game", {:mini_game, snapshot})
    assert render(view) =~ "em jogo"
    refute_push_event(view, "mini-game-transition", %{})
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
  test "preset por Pokémon: salvar → aplicar → excluir no painel", %{conn: conn, tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

    keys = Pokex.Settings.get(:hook_skill_keys)
    on_exit(fn -> Pokex.Settings.put(:hook_skill_keys, keys) end)

    {:ok, view, _} = live(conn, ~p"/")

    # save captures the CURRENT settings under the Pokémon's name
    Pokex.Settings.put(:hook_skill_keys, ["8", "9"])
    view |> form("#preset-save-form", %{"name" => "Blastoise"}) |> render_submit()
    html = render(view)
    assert html =~ "Preset &quot;blastoise&quot; salvo"
    assert html =~ "fisga 8 9"

    # settings drift, apply restores the bundle AND the visible fields
    Pokex.Settings.put(:hook_skill_keys, ["1"])

    view
    |> element(~s(#preset-list button[phx-value-slug="blastoise"]), "Aplicar")
    |> render_click()

    assert Pokex.Settings.get(:hook_skill_keys) == ["8", "9"]
    html = render(view)
    assert html =~ "aplicado"
    assert html =~ "8 9"

    view
    |> element(~s(#preset-list button[phx-value-slug="blastoise"]), "Excluir")
    |> render_click()

    refute render(view) =~ "fisga 8 9"
  end

  test "saves the rescue threshold + cooldown and rejects nonsense values", %{conn: conn} do
    original = Pokex.Settings.get(:pokemon_hp_rescue_pct)
    cooldown = Pokex.Settings.get(:rescue_cooldown_ms)

    on_exit(fn ->
      Pokex.Settings.put(:pokemon_hp_rescue_pct, original)
      Pokex.Settings.put(:rescue_cooldown_ms, cooldown)
    end)

    {:ok, view, _} = live(conn, ~p"/")

    view
    |> form("#rescue-cfg-form", %{"rescue_pct" => "30", "rescue_cooldown_s" => "20"})
    |> render_change()

    assert Pokex.Settings.get(:pokemon_hp_rescue_pct) == 30
    # the UI speaks seconds, the setting stores milliseconds
    assert Pokex.Settings.get(:rescue_cooldown_ms) == 20_000
    assert render(view) =~ "abaixo de 30%"

    # out-of-range and garbage inputs must not touch the saved values — but a valid field
    # beside an invalid one still saves
    view
    |> form("#rescue-cfg-form", %{"rescue_pct" => "95", "rescue_cooldown_s" => "1"})
    |> render_change()

    view
    |> form("#rescue-cfg-form", %{"rescue_pct" => "abc", "rescue_cooldown_s" => "45"})
    |> render_change()

    assert Pokex.Settings.get(:pokemon_hp_rescue_pct) == 30
    assert Pokex.Settings.get(:rescue_cooldown_ms) == 45_000

    # the floor is 2s (Lucas lowered it from 5): the boundary value saves
    view
    |> form("#rescue-cfg-form", %{"rescue_pct" => "30", "rescue_cooldown_s" => "2"})
    |> render_change()

    assert Pokex.Settings.get(:rescue_cooldown_ms) == 2_000
  end

  test "saves the potion threshold + cooldown and toggles the auto-potion", %{conn: conn} do
    pct = Pokex.Settings.get(:pokemon_hp_potion_pct)
    cooldown = Pokex.Settings.get(:potion_cooldown_ms)
    enabled = Pokex.Settings.get(:potion_enabled)

    on_exit(fn ->
      Pokex.Settings.put(:pokemon_hp_potion_pct, pct)
      Pokex.Settings.put(:potion_cooldown_ms, cooldown)
      Pokex.Settings.put(:potion_enabled, enabled)
    end)

    {:ok, view, _} = live(conn, ~p"/")

    view
    |> form("#potion-cfg-form", %{"potion_pct" => "65", "potion_cooldown_s" => "8"})
    |> render_change()

    assert Pokex.Settings.get(:pokemon_hp_potion_pct) == 65
    assert Pokex.Settings.get(:potion_cooldown_ms) == 8_000
    assert render(view) =~ "abaixo de 65%"

    view
    |> form("#potion-cfg-form", %{"potion_pct" => "0", "potion_cooldown_s" => "700"})
    |> render_change()

    assert Pokex.Settings.get(:pokemon_hp_potion_pct) == 65
    assert Pokex.Settings.get(:potion_cooldown_ms) == 8_000

    view |> element(~s(#automation-potion input[phx-click="toggle_potion"])) |> render_click()
    refute Pokex.Settings.get(:potion_enabled) == enabled
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
      {:combat, %{state: :hunting, counters: %{}, error: nil, locked_row: nil}}
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
    # restore the SEED default (dropping the override) — the old cleanup put
    # nil, which became a real nil override in the global mirror and randomly
    # broke settings_test depending on file order
    threshold = Pokex.Settings.get(:glow_threshold)
    on_exit(fn -> Pokex.Settings.put(:glow_threshold, threshold) end)

    {:ok, view, _} = live(conn, ~p"/")
    view |> form("#threshold-form", %{"threshold" => "21.5"}) |> render_submit()
    assert Pokex.Settings.get(:glow_threshold) == 21.5
  end

  test "saves combat timing knobs and ignores blanks", %{conn: conn} do
    keys = [
      :combat_skill_burst_size,
      :combat_skill_tap_count,
      :combat_skill_gap_ms,
      :combat_skill_jitter_ms,
      :target_lost_streak,
      :fight_timeout_ms
    ]

    Pokex.SettingsStash.stash_keys!(keys)
    original_streak = Pokex.Settings.get(:target_lost_streak)

    {:ok, view, _} = live(conn, ~p"/")

    view
    |> form("#timing-form", %{
      "combat_skill_burst_size" => "3",
      "combat_skill_tap_count" => "0",
      "combat_skill_gap_ms" => "25",
      "combat_skill_jitter_ms" => "20",
      "target_lost_streak" => "",
      "fight_timeout_ms" => "5000"
    })
    |> render_submit()

    assert Pokex.Settings.get(:combat_skill_burst_size) == 3
    # positive timing knobs clamp 0 to 1 instead of persisting an inert combat setting.
    assert Pokex.Settings.get(:combat_skill_tap_count) == 1
    assert Pokex.Settings.get(:combat_skill_gap_ms) == 25
    assert Pokex.Settings.get(:combat_skill_jitter_ms) == 20
    assert Pokex.Settings.get(:fight_timeout_ms) == 5000
    # blank left the current value untouched
    assert Pokex.Settings.get(:target_lost_streak) == original_streak
  end

  test "capture metrics block reports the backend on demand", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")

    html = view |> element(~s(button[phx-click="read_capture_stats"])) |> render_click()
    assert html =~ "backend:"
    assert html =~ "screencapture CLI" or html =~ "ScreenCaptureKit"
  end
end
