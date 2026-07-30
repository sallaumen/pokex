defmodule PokexWeb.PanelLiveTest do
  use PokexWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  # O feed agora chega pelo journal: broadcast → Pokex.Journal → {:journal_event}
  # → painel. Dois saltos assíncronos — o render precisa esperar a corrente.
  defp eventually_html(view, texto, tries \\ 50) do
    cond do
      render(view) =~ texto -> true
      tries == 0 -> false
      true -> Process.sleep(10) && eventually_html(view, texto, tries - 1)
    end
  end

  defp journal_event(source, severity, text) do
    {:journal_event,
     %{
       id: 1,
       at: System.system_time(:millisecond),
       source: source,
       severity: severity,
       text: text,
       generation: nil,
       repeats: 1
     }}
  end

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

  test "the world card is always there — stocks visible before anything goes wrong", %{
    conn: conn
  } do
    now = System.monotonic_time(:millisecond)

    Pokex.Perception.WorldState.put(
      :hud,
      %{level: 90, food: 1525, fishing: 96, slots: %{f1: 322, f2: 36, e: 7, s_q: 43}},
      now
    )

    Pokex.Perception.WorldState.put(:minimap, %{pos: {337, 46107, 4}}, now)

    Pokex.Perception.WorldState.put(
      :team,
      %{pokemon_hp: {5559, 6410}, rows: [%{slot: 2, present?: true, hp_pct: 0.86}]},
      now
    )

    on_exit(fn ->
      Enum.each([:hud, :minimap, :team], &Pokex.Perception.WorldState.forget/1)
    end)

    {:ok, view, html} = live(conn, ~p"/")

    assert has_element?(view, "#world-card")
    # the four stocks are ALWAYS on screen, not only once one goes low
    assert html =~ "322"
    assert html =~ "5559/6410"
    assert html =~ "337, 46107"
    assert html =~ "C+2"
  end

  test "a low stock turns its badge red and it stays until he restocks", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")

    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      Pokex.Bots.StockAlerts.topic(),
      {:stock, %{slot: :f1, count: 28, low?: true}}
    )

    assert view |> element("#stock-badge-f1") |> render() =~ "pk-danger"

    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      Pokex.Bots.StockAlerts.topic(),
      {:stock, %{slot: :f1, count: 200, low?: false}}
    )

    refute view |> element("#stock-badge-f1") |> render() =~ "pk-danger"
  end

  test "losing the HUD raises a banner that says nothing is being clicked blind", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    refute has_element?(view, "#layout-banner")

    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      Pokex.Layout.Sentinel.topic(),
      {:layout, %{ok?: false, reason: {:anchor_not_found, :battle_header}, anchors: %{}}}
    )

    assert view |> element("#layout-banner") |> render() =~ "tela cheia no monitor principal"

    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      Pokex.Layout.Sentinel.topic(),
      {:layout, %{ok?: true, reason: nil, anchors: %{}}}
    )

    refute has_element?(view, "#layout-banner")
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

    send(view.pid, journal_event(:fishing, :macro, "linha-da-pesca"))
    send(view.pid, journal_event(:combat, :macro, "linha-do-combate"))

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
    assert has_element?(view, "#app-navigation[phx-update=ignore]")
    assert has_element?(view, "#app-navigation-toggle[aria-label='Abrir navegação']")
    assert has_element?(view, "#app-nav-calibration[href='/calibration']")
    assert has_element?(view, "#app-nav-diagnostics[href='/diagnostics']")
    assert has_element?(view, "#app-nav-fishing-lab[href='/fishing-lab']")
    assert has_element?(view, "#app-nav-world[href='/world']")
    assert has_element?(view, "#app-nav-pokedex[href='/pokedex']")
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
      {:rule_alarm, "estagnação: sem kills nem peixes há 10min"}
    )

    assert_push_event(view, "alarm", %{text: text})
    assert text =~ "estagnação"
    assert render(view) =~ "⏰ estagnação"
  end

  @tag :tmp_dir
  test "guarda anti-shiny: ação persiste, sonda lê a lista de batalha, registro aparece", %{
    conn: conn,
    tmp_dir: tmp
  } do
    Application.put_env(:pokex, :home_dir, tmp)

    enabled = Pokex.Settings.get(:shiny_guard_enabled)
    action = Pokex.Settings.get(:shiny_action)

    on_exit(fn ->
      Application.delete_env(:pokex, :home_dir)
      Pokex.Settings.put(:shiny_guard_enabled, enabled)
      Pokex.Settings.put(:shiny_action, action)
    end)

    Pokex.Calibration.save(%Pokex.Calibration{
      scale: 1.0,
      screen_w: 1000,
      screen_h: 700,
      water_point: {400, 300},
      glow_region: {0, 0, 20, 20},
      battle_region: {900, 0, 239, 95},
      arena_region: {100, 100, 60, 40},
      neutral_point: {500, 500}
    })

    # the probe reads the REAL battle-list capture (Lucas's shiny Seadra) via
    # the shared Fake's default capture path
    File.mkdir_p!("/tmp/fake")
    File.cp!("test/fixtures/battle/shiny_star_list.png", "/tmp/fake/shiny_probe.png")

    {:ok, view, _} = live(conn, ~p"/")

    view |> element(~s(input[phx-click="toggle_shiny_guard"])) |> render_click()
    refute Pokex.Settings.get(:shiny_guard_enabled) == enabled

    view |> form("#shiny-cfg-form", %{"shiny_action" => "fugir"}) |> render_change()
    assert Pokex.Settings.get(:shiny_action) == "fugir"

    # the probe scores each row — the real capture has a star on one of them
    view |> element("#shiny-probe") |> render_click()
    html = render(view)
    assert html =~ "sonda: colunas douradas por linha"
    assert html =~ "L0:"

    # a live reading lights the meter
    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      "shiny",
      {:shiny_reading, %{star_run: 4, min_px: 3}}
    )

    assert render(view) =~ "4<span"

    # a sighting lands on the trophy shelf
    Pokex.Pokedex.ShinyLog.record(star_px: 22, action: "fugir", outcome: "visto")
    Phoenix.PubSub.broadcast(Pokex.PubSub, "shiny", {:shiny_seen, %{px: 22, action: "fugir"}})

    html = render(view)
    assert has_element?(view, "#shiny-log")
    assert html =~ "shinies encontrados (1)"
    assert html =~ "22px"
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

  test "trocar de modo aplica o pacote inteiro e o botão anuncia o que vai ligar", %{conn: conn} do
    Pokex.SettingsStash.stash_keys!([:player_mode, :capture_enabled, :reposition_enabled])

    {:ok, view, _} = live(conn, ~p"/")

    view |> element("#mode-movimento") |> render_click()
    assert Pokex.Settings.get(:player_mode) == "movimento"
    # the bundle rides along: no ball (no ground baseline) and no reposition
    # (it would drag him back to the fishing tile mid-trip)
    refute Pokex.Settings.get(:capture_enabled)
    refute Pokex.Settings.get(:reposition_enabled)

    html = render(view)
    assert html =~ "Iniciar — modo movimento"
    # and it says which workers, so no more starting the rod while walking
    assert html =~ "batalha"
    refute html =~ "liga pesca"

    view |> element("#mode-parado") |> render_click()
    assert Pokex.Settings.get(:capture_enabled)
    assert render(view) =~ "Reaprender chão"
  end

  # The escape hatch he asked for: a switch may disagree with the mode, but the
  # panel must SAY so rather than let the two quietly differ.
  test "uma exceção manual ao padrão do modo é marcada e restaurável", %{conn: conn} do
    Pokex.SettingsStash.stash_keys!([:player_mode, :capture_enabled, :reposition_enabled])

    {:ok, view, _} = live(conn, ~p"/")
    view |> element("#mode-parado") |> render_click()
    refute has_element?(view, "[data-testid=override-badge]")

    view |> element(~s(#automation-reposition input)) |> render_click()

    assert has_element?(view, "#automation-reposition [data-testid=override-badge]")
    assert render(view) =~ "1 exceção"
    refute Pokex.Settings.get(:reposition_enabled)

    view |> element("#restore-mode-defaults") |> render_click()
    assert Pokex.Settings.get(:reposition_enabled)
    refute render(view) =~ "restore-mode-defaults"
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

    # Isto afirmava `render(view) =~ "mudo"` — e passava por acidente: não existe
    # "mudo" minúsculo no painel, mas "mudou" (em três textos sem relação
    # nenhuma com o mini game) contém a substring. O teste nunca verificou o
    # mudo. Agora ele olha o botão de verdade.
    assert has_element?(
             view,
             ~s(button[phx-click="toggle_mini_game_sound"][title*="MUDO"])
           )

    Phoenix.PubSub.broadcast(Pokex.PubSub, "mini_game", {:mini_game, snapshot})
    assert render(view) =~ "em jogo"
    refute_push_event(view, "mini-game-transition", %{})
  end

  test "macro worker logs append to the activity feed", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")

    Phoenix.PubSub.broadcast(Pokex.PubSub, "fishing", {:fishing_log, :macro, "lançando a linha"})
    Phoenix.PubSub.broadcast(Pokex.PubSub, "combat", {:combat_log, :macro, "mirando linha 0"})
    Phoenix.PubSub.broadcast(Pokex.PubSub, "mini_game", {:mini_game_log, :macro, "pausando"})

    assert eventually_html(view, "lançando a linha")
    assert eventually_html(view, "mirando linha 0")
    assert eventually_html(view, "pausando")
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

  describe "a caçada no painel" do
    # A caçada morria em ~6s "sem dizer nada" — e não dizia mesmo: o worker
    # emitia snapshot, log e alarme, e o painel não assinava o tópico. Estes
    # testes guardam o consumo dessas três mensagens.
    @cavebot_topic Pokex.Bots.Cavebot.Worker.topic()

    defp walking_snapshot(overrides \\ %{}) do
      Map.merge(
        %{
          state: :walking,
          route: "cavena",
          wp_index: 2,
          wp_total: 9,
          wp_target: %{x: 337, y: 46_107, z: 4},
          pos: {332, 46_106, 4},
          pos_age_ms: 120,
          distance_tiles: %{dx: 5, dy: 1},
          hold_reason: nil,
          last_action: %{text: "passo 5,1", at: System.monotonic_time(:millisecond)},
          counters: %{waypoints: 2, steps: 41}
        },
        overrides
      )
    end

    test "a pílula da caçada existe no mount e conta a rota quando ele anda", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/")

      assert html =~ "Caçada"
      assert has_element?(view, "[data-testid=cavebot-pill]")

      Phoenix.PubSub.broadcast(Pokex.PubSub, @cavebot_topic, {:cavebot, walking_snapshot()})

      row = view |> element("[data-testid=cavebot-pill]") |> render()

      assert row =~ "andando"
      assert row =~ "cavena"
      # o índice é 0-based no worker e 1-based na tela: é o número que ele
      # reconhece na lista de waypoints do /cavebot
      assert row =~ "wp 3/9"
      assert row =~ "faltam 5,1 tiles"
      assert row =~ "41 passos"
      assert has_element?(view, "[data-testid=cavebot-pill][data-state=walking]")
    end

    test "uma linha da caçada aparece no feed", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")

      Phoenix.PubSub.broadcast(
        Pokex.PubSub,
        @cavebot_topic,
        {:cavebot_log, :macro, "caçada: waypoint 3/9"}
      )

      assert eventually_html(view, "caçada: waypoint 3/9")
      assert view |> element("#activity-feed") |> render() =~ "🧭"
    end

    test "o chip 🧭 filtra o feed da caçada (comparação exata de binário)", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")

      Phoenix.PubSub.broadcast(
        Pokex.PubSub,
        @cavebot_topic,
        {:cavebot_log, :macro, "caçada: waypoint 3/9"}
      )

      Phoenix.PubSub.broadcast(Pokex.PubSub, "fishing", {:fishing_log, :macro, "arremesso"})

      # o filtro compara a fonte por igualdade EXATA: um emoji com variation
      # selector digitado diferente nos dois lugares filtraria um feed vazio
      view
      |> element(~s(button[phx-click="filter_feed"][phx-value-source="🧭"]))
      |> render_click()

      feed = view |> element("#activity-feed") |> render()
      assert feed =~ "caçada: waypoint 3/9"
      refute feed =~ "arremesso"
    end

    test "um bloqueio não derruba a LiveView e vira linha visível", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")

      Phoenix.PubSub.broadcast(Pokex.PubSub, @cavebot_topic, {:cavebot_alarm, :stuck})

      # a LiveView continua de pé — sem catch-all de handle_info isto era um
      # FunctionClauseError no PIOR momento possível: o do bloqueio
      assert render(view) =~ "Caçada"
      assert view |> element("#activity-feed") |> render() =~ "caçada parada: travado"
    end

    test "um estado parado NUNCA acende a bolinha de ativo", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")

      for state <- [:blocked, :stuck, :fight_stalled] do
        Phoenix.PubSub.broadcast(
          Pokex.PubSub,
          @cavebot_topic,
          {:cavebot,
           walking_snapshot(%{state: state, hold_reason: "parei: travado, sem sair do lugar"})}
        )

        row = view |> element("[data-testid=cavebot-pill]") |> render()

        refute row =~ "bg-pk-ok",
               "#{state} acendeu verde — um cavebot parado não pode parecer saudável"

        assert row =~ "bg-pk-text-3"
        assert row =~ "🔒 parei: travado"
      end
    end

    test "uma mensagem desconhecida no tópico não derruba o painel", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")

      send(view.pid, {:cavebot_something_new, %{}})

      assert render(view) =~ "Caçada"
    end
  end

  describe "a posição no painel" do
    setup do
      on_exit(fn -> Pokex.Perception.WorldState.forget(:minimap) end)
      :ok
    end

    test "uma leitura boa diz ONDE ele está e há quanto tempo", %{conn: conn} do
      now = System.monotonic_time(:millisecond)
      Pokex.Perception.WorldState.put(:minimap, %{pos: {337, 46_107, 4}}, now)

      {:ok, view, _} = live(conn, ~p"/")

      position = view |> element("#world-position") |> render()
      assert position =~ "337, 46107 · andar 4"
      assert position =~ "lendo tua posição"
      assert position =~ "agora"
    end

    test "parar de ler é dito com todas as letras, com a idade da última leitura", %{conn: conn} do
      now = System.monotonic_time(:millisecond)
      Pokex.Perception.WorldState.put(:minimap, %{pos: {337, 46_107, 4}}, now - 20_000)

      {:ok, view, _} = live(conn, ~p"/")

      position = view |> element("#world-position") |> render()
      assert position =~ "NÃO estou lendo tua posição"
      assert position =~ "há 20s"
    end

    test "coordenada ilegível é diferente de feed parado", %{conn: conn} do
      # o feed está lendo AGORA; quem falhou foi a coordenada (a leitura é
      # tudo-ou-nada, um glifo duvidoso derruba as três casas)
      now = System.monotonic_time(:millisecond)
      Pokex.Perception.WorldState.put(:minimap, %{pos: nil}, now)

      {:ok, view, _} = live(conn, ~p"/")

      position = view |> element("#world-position") |> render()
      assert position =~ "coordenada saiu ilegível"
      refute position =~ "NÃO estou lendo"
    end

    test "a proporção de leitura boa/ruim conta as publicações do feed", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")

      assert view |> element("#world-read-health") |> render() =~ "aguardando a primeira leitura"

      for obs <- [%{pos: {1, 2, 3}}, %{pos: {1, 2, 3}}, %{pos: nil}] do
        Phoenix.PubSub.broadcast(
          Pokex.PubSub,
          Pokex.Perception.topic(),
          {:world, :minimap, obs}
        )
      end

      assert view |> element("#world-read-health") |> render() =~ "67% (2 ok, 1 falhas)"
    end
  end

  describe "o card de combos" do
    setup do
      tmp =
        Path.join(System.tmp_dir!(), "pokex-panel-combos-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      Application.put_env(:pokex, :home_dir, tmp)

      on_exit(fn ->
        Application.delete_env(:pokex, :home_dir)
        File.rm_rf!(tmp)
        # mounting the panel attaches the display feeds, which can leave a
        # :layout fact behind — and a test elsewhere asserts on NOT having one
        Enum.each([:team, :layout], &Pokex.Perception.WorldState.forget/1)
      end)

      :ok
    end

    defp team_on_screen(rows) do
      Pokex.Perception.WorldState.put(
        :team,
        %{pokemon_hp: nil, rows: rows},
        System.monotonic_time(:millisecond)
      )
    end

    test "lista o combo semeado e marca o passo que NÃO pode rodar", %{conn: conn} do
      # his real team: Wigglytuff, not the Jigglypuff the seed asks for
      team_on_screen([
        %{slot: 2, name: "Xatu", present?: true, hp_pct: 1.0},
        %{slot: 5, name: "Wigglytuff", present?: true, hp_pct: 1.0}
      ])

      {:ok, view, _} = live(conn, ~p"/")

      assert has_element?(view, "#combos-card")
      assert render(view) =~ "sing"
      # the chip turns red and says why, instead of him finding out mid-fight
      assert has_element?(view, ~s([title*="Jigglypuff NÃO está nos atalhos"]))
    end

    test "criar um combo usa o time lido da tela e ele passa a valer", %{conn: conn} do
      team_on_screen([%{slot: 5, name: "Wigglytuff", present?: true, hp_pct: 1.0}])

      {:ok, view, _} = live(conn, ~p"/")

      view
      |> form("#combo-form", %{
        "name" => "dorme",
        "trigger_kind" => "element",
        "trigger_value" => "Water",
        "member" => "Wigglytuff",
        "skill" => "4",
        "counter" => "on"
      })
      |> render_submit()

      saved = Enum.find(Pokex.Combos.Store.all(), &(&1.name == "dorme"))
      assert saved.trigger == {:enemy_element, "Water"}
      assert {:swap_member, "Wigglytuff"} in saved.steps
      assert {:swap_counter} in saved.steps
      # dungeon em branco = combo global
      assert saved.dungeon == nil
      # and now the chip is green, because Wigglytuff IS in the hotkeys
      refute has_element?(view, ~s([title*="Wigglytuff NÃO está nos atalhos"]))
    end

    test "um combo pode valer só numa dungeon, e a linha mostra qual", %{conn: conn} do
      team_on_screen([%{slot: 5, name: "Wigglytuff", present?: true, hp_pct: 1.0}])

      {:ok, view, _} = live(conn, ~p"/")

      view
      |> form("#combo-form", %{
        "name" => "na-dg",
        "trigger_kind" => "element",
        "trigger_value" => "Water",
        "member" => "Wigglytuff",
        "skill" => "4",
        "dungeon" => "  cavena  "
      })
      |> render_submit()

      assert Enum.find(Pokex.Combos.Store.all(), &(&1.name == "na-dg")).dungeon == "cavena"
      assert view |> element(~s(#combo-na-dg)) |> render() =~ "cavena"
    end

    test "excluir tira o combo da lista", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")

      view |> element(~s([phx-click="delete_combo"][phx-value-name="sing"])) |> render_click()

      refute Enum.any?(Pokex.Combos.Store.all(), &(&1.name == "sing"))
    end

    # The whole point: "liguei os combos e não aconteceu nada" gets an answer.
    test "uma recusa transmitida aparece no painel em português", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")

      Phoenix.PubSub.broadcast(
        Pokex.PubSub,
        Pokex.Combos.Runner.topic(),
        {:combo_skipped,
         %{combo: "sing", enemy: "Tentacool", reason: {:not_on_screen, "Jigglypuff"}}}
      )

      html = render(view)
      assert html =~ "sing não rodou contra Tentacool"
      assert html =~ "Jigglypuff não está nos atalhos"
    end

    test "um passo de espera mostra os milissegundos, não o nome da setting", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")

      # "espera combo_swap_wait_ms" is an internal name printed on his screen, and
      # it does not answer the only question the chip exists to answer: how long?
      chip = view |> element(~s([title*="combo_swap_wait_ms"])) |> render()

      assert chip =~ "espera #{Pokex.Settings.get(:combo_swap_wait_ms)}ms"
      # the setting name still lives a hover away, in the tooltip
      assert chip =~ "ajustável nas configurações"
    end
  end

  describe "o sistema visual" do
    # These are markup guards for things a LiveView test cannot measure in pixels.
    # MEASURED in the browser at Lucas's window width (2026-07-22): the worker
    # status lines had 15-30px of slack and the support line was ALREADY cut, and
    # the uppercase + 0.1em treatment alone accounted for 36px (15%) of the width.
    # Nothing here re-measures that — these just keep the causes from coming back.
    test "o estado dos workers não é escrito em caixa alta espaçada", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")

      for testid <- ~w(fishing combat catcher mini-game support cavebot) do
        row = view |> element(~s([data-testid="#{testid}-pill"])) |> render()

        refute row =~ "uppercase",
               "a linha de #{testid} voltou pra caixa alta — ela custa 15% da largura"

        refute row =~ "tracking-[0.1em]"
      end
    end

    test "o estado de um worker nunca é truncado; a última ação pode ser", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")

      Phoenix.PubSub.broadcast(
        Pokex.PubSub,
        "game",
        {:game,
         %{
           state: :monitoring,
           counters: %{rescues: 27, potions: 194, failures: 0},
           error: nil,
           hp_pct: 100,
           last_action: %{text: "poção", at: System.monotonic_time(:millisecond)}
         }}
      )

      row = view |> element(~s([data-testid="support-pill"])) |> render()

      # the state + counters live in a span that is allowed to grow
      assert row =~ "monitorando"
      assert row =~ "27 revive · 194 poção"
      refute row =~ ~s(class="min-w-0 flex-1 text-pk-body text-pk-text-2 truncate)
    end

    test "um valor que ainda não foi lido aparece como — e nunca como ?", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")
      world = view |> element("#world-card") |> render()

      # "?" reads as a broken field; the feeds fail OPEN, so "ainda não li" is
      # normal and must look normal.
      refute world =~ ">?<"
      assert world =~ "—"
    end
  end

  describe "seletor de personagem" do
    test "o seletor de personagem troca o active_character", %{conn: conn} do
      Pokex.SettingsStash.stash_keys!([:active_character])
      {:ok, view, _} = live(conn, ~p"/")
      assert has_element?(view, "#character-picker")
      view |> element("form[phx-change=set_character]") |> render_change(%{"character" => ""})
      assert Pokex.Settings.get(:active_character) == ""
    end

    test "criar um personagem seleciona ele", %{conn: conn} do
      tmp = Path.join(System.tmp_dir!(), "pokex-char-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      Application.put_env(:pokex, :home_dir, tmp)
      Pokex.SettingsStash.stash_keys!([:active_character])

      on_exit(fn ->
        Application.delete_env(:pokex, :home_dir)
        File.rm_rf!(tmp)
      end)

      {:ok, view, _} = live(conn, ~p"/")
      view |> element("form[phx-submit=create_character]") |> render_submit(%{"name" => "Lowbie"})
      assert Pokex.Settings.get(:active_character) == "lowbie"
    end
  end

  describe "motivo da parada (Frente 1, fatia 4)" do
    # O critério de aceite do plano de consolidação: com o bot parado, a tela
    # responde "quem parou, por quê, há quanto tempo" — sem arqueologia de log.
    test "um Stop com motivo aparece sob o botão Iniciar", %{conn: conn} do
      Pokex.Bots.Session.order(:stop, "teste: o Guardian bateu a meta")

      {:ok, view, _html} = live(conn, ~p"/")

      assert view |> element("#last-order") |> render() =~ "teste: o Guardian bateu a meta"
      assert view |> element("#last-order") |> render() =~ "parado"
    end

    test "uma pausa por foco diz que retoma sozinha", %{conn: conn} do
      Pokex.Bots.Session.order(:hold, "foco perdido")

      {:ok, view, _html} = live(conn, ~p"/")

      assert view |> element("#last-order") |> render() =~ "retoma sozinho ao voltar"
    end

    test "o botão Parar do painel registra o próprio motivo", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "stop")

      assert %{kind: :stop, reason: "Parar (painel)"} = Pokex.Bots.Session.last_order()
      assert view |> element("#last-order") |> render() =~ "Parar (painel)"
    end

    test "com a frota ATIVA a linha some — motivo de parada é coisa de parado", %{conn: conn} do
      Pokex.Bots.Session.order(:stop, "teste: some quando roda")
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#last-order")

      Phoenix.PubSub.broadcast(
        Pokex.PubSub,
        "fishing",
        {:fishing, %{state: :pescando, counters: %{}, error: nil}}
      )

      # a linha mora no bloco do botão Iniciar, que só existe com o bot parado
      refute eventually_has(view, "#last-order")
    end

    defp eventually_has(view, selector, tries \\ 30) do
      cond do
        has_element?(view, selector) and tries > 0 ->
          Process.sleep(10)
          eventually_has(view, selector, tries - 1)

        true ->
          has_element?(view, selector)
      end
    end
  end

  describe "logout" do
    setup do
      on_exit(fn ->
        Pokex.Settings.put(:stagnation_action, "alarme")
        Pokex.Settings.put(:stop_after_action, "parar")
      end)

      :ok
    end

    test "o botão 'Deslogar agora' existe e clicar nele não derruba a página", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, ~s(button[phx-click="logout_now"]))

      # o Logout global fica inerte na suíte — o clique tem que sobreviver a isso
      render_click(view, "logout_now")
      assert render(view) =~ "Deslogar agora"
    end

    test "o painel mostra o desfecho do logout, e uma mensagem estranha não o derruba", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/")

      send(
        view.pid,
        {:logout,
         %{
           state: :out,
           reason: "manual (painel)",
           attempt: 1,
           attempts: 3,
           error: nil,
           finished_at: 1,
           duplicates: 0
         }}
      )

      assert render(view) =~ "deslogado — manual (painel)"

      # e uma falha diz POR QUE falhou, nunca só "falhou"
      send(
        view.pid,
        {:logout,
         %{
           state: :failed,
           reason: "estagnação",
           attempt: 3,
           attempts: 3,
           error: :ainda_logado,
           finished_at: 2,
           duplicates: 0
         }}
      )

      assert render(view) =~ "FALHOU (ainda_logado)"

      # qualquer coisa sem cláusula continua sendo ignorada em vez de derrubar
      send(view.pid, {:mensagem_que_ninguem_espera, 42})
      assert render(view) =~ "Deslogar agora"
    end

    test "os dois seletores de ação oferecem deslogar", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, ~s(select#stagnation-action option[value="deslogar"]))
      assert has_element?(view, ~s(select#stop-after-action option[value="deslogar"]))
    end

    test "escolher deslogar nos dois seletores grava o ajuste", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> element("#stagnation-form")
      |> render_change(%{"stagnation_minutes" => "5", "stagnation_action" => "deslogar"})

      assert Pokex.Settings.get(:stagnation_action) == "deslogar"

      view
      |> element("#stop-conditions-form")
      |> render_change(%{
        "stop_minutes" => "0",
        "stop_kills" => "0",
        "stop_after_action" => "deslogar"
      })

      assert Pokex.Settings.get(:stop_after_action) == "deslogar"
    end
  end
end
