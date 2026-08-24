defmodule PokexWeb.PanelLiveTest do
  use PokexWeb.ConnCase, async: false

  alias Pokex.Bots.Session
  alias Pokex.Bots.StockAlerts
  alias Pokex.Combos.Combo
  alias Pokex.Combos.Runner
  alias Pokex.Combos.Store
  alias Pokex.Layout.Sentinel
  alias Pokex.Perception.WorldState
  alias Pokex.Pokedex.ShinyLog
  alias Pokex.Rig.Fake
  import Phoenix.LiveViewTest

  # the feed arrives via the journal: broadcast → Pokex.Journal → {:journal_event}
  # → panel. Two async hops — the render must wait for the chain.
  defp eventually_html(view, text, tries \\ 50) do
    cond do
      render(view) =~ text -> true
      tries == 0 -> false
      true -> Process.sleep(10) && eventually_html(view, text, tries - 1)
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
    # one shared blackboard: start from an empty world, never from the last test's
    WorldState.clear()

    {:ok, _} = Fake.start_link()

    on_exit(fn ->
      WorldState.forget(:calibration)
      WorldState.forget(:session)
    end)

    :ok
  end

  test "a calibration edited after the last Start raises the stale banner", %{conn: conn} do
    WorldState.put(
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

    WorldState.put(
      :hud,
      %{level: 90, food: 1525, fishing: 96, slots: %{f1: 322, f2: 36, e: 7, s_q: 43}},
      now
    )

    WorldState.put(:minimap, %{pos: {337, 46_107, 4}}, now)

    WorldState.put(
      :team,
      %{pokemon_hp: {5559, 6410}, rows: [%{slot: 2, present?: true, hp_pct: 0.86}]},
      now
    )

    on_exit(fn ->
      Enum.each([:hud, :minimap, :team], &WorldState.forget/1)
    end)

    {:ok, view, html} = live(conn, ~p"/")

    assert has_element?(view, "#world-card")
    assert html =~ "322"
    assert html =~ "5559/6410"
    assert html =~ "337, 46107"
    assert html =~ "C+2"
  end

  test "a low stock turns its badge red and it stays until he restocks", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")

    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      StockAlerts.topic(),
      {:stock, %{slot: :f1, count: 28, low?: true}}
    )

    assert view |> element("#stock-badge-f1") |> render() =~ "pk-danger"

    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      StockAlerts.topic(),
      {:stock, %{slot: :f1, count: 200, low?: false}}
    )

    refute view |> element("#stock-badge-f1") |> render() =~ "pk-danger"
  end

  test "losing the HUD raises a banner that says nothing is being clicked blind", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    refute has_element?(view, "#layout-banner")

    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      Sentinel.topic(),
      {:layout, %{ok?: false, reason: {:anchor_not_found, :battle_header}, anchors: %{}}}
    )

    assert view |> element("#layout-banner") |> render() =~ "tela cheia no monitor principal"

    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      Sentinel.topic(),
      {:layout, %{ok?: true, reason: nil, anchors: %{}}}
    )

    refute has_element?(view, "#layout-banner")
  end

  test "no stamp (bots never started) → no stale banner", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    refute has_element?(view, "#calib-stale-banner")
  end

  # the old banner sat right above the Start/Stop button and pushed it down
  # whenever another window took focus; the badge keeps the layout identical
  test "losing game focus shows the header badge — never the layout-shifting banner", %{
    conn: conn
  } do
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

    view |> element("button[phx-value-source='🎣']") |> render_click()
    assert render(view) =~ "linha-do-combate"
  end

  @tag :tmp_dir
  test "start without calibration shows preflight error", %{conn: conn, tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Pokex.TestHome.restore() end)

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
    assert has_element?(view, "#quick-toggles")
    assert has_element?(view, "#quick-fishing")
    assert has_element?(view, "#open-settings[href='/config']")
    refute has_element?(view, "#fishing-hp-form")
    refute html =~ "Só pescar com vida"
    # the menu is no longer ignored by the patcher — app_header_test sweeps
    # every route for that, with the reasoning
    assert has_element?(view, "#app-navigation-toggle[aria-label='Abrir navegação']")
    assert has_element?(view, "#app-nav-calibration[href='/calibration']")
    assert has_element?(view, "#app-nav-diagnostics[href='/diagnostics']")
    assert has_element?(view, "#app-nav-fishing-lab[href='/fishing-lab']")
    assert has_element?(view, "#app-nav-world[href='/world']")
    assert has_element?(view, "#app-nav-pokedex[href='/pokedex']")
    assert has_element?(view, "#app-nav-config[href='/config']")
  end

  describe "the ⚙️ overlay over the dashboard" do
    test "opens at /config with the live dashboard behind it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/config")

      assert has_element?(view, "#settings-overlay")
      assert has_element?(view, ~s([data-testid="fishing-pill"]))
      assert has_element?(view, "#quick-toggles")
      assert has_element?(view, "#rescue-pct")
      assert has_element?(view, "#hook-skills-form")
      assert has_element?(view, "#automation-require-pokemon-hp")
      assert has_element?(view, "#escape-cfg-form")
    end

    test "the dashboard keeps only operation; all configuration lives in the ⚙️", %{conn: conn} do
      {:ok, dash, _html} = live(conn, ~p"/")

      assert has_element?(dash, ~s([data-testid="fishing-pill"]))
      assert has_element?(dash, "#quick-toggles")
      assert has_element?(dash, "#session-duration") or render(dash) =~ "Sessão"
      assert has_element?(dash, "#world-card")

      refute has_element?(dash, "#presets-card")
      refute has_element?(dash, "#combos-card")
      refute has_element?(dash, "#shiny-guard-card")
      refute has_element?(dash, "#advanced-panel")
      refute has_element?(dash, "#stop-conditions-form")

      {:ok, cfg, _html} = live(conn, ~p"/config")

      assert has_element?(cfg, "#presets-card")
      assert has_element?(cfg, "#combos-card")
      assert has_element?(cfg, "#shiny-guard-card")
      assert has_element?(cfg, "#advanced-panel")
      assert has_element?(cfg, "#stop-conditions-form")
      assert has_element?(cfg, "#quick-toggles")
    end

    test "on the plain dashboard the overlay does not exist", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#settings-overlay")
      refute has_element?(view, "#rescue-pct")
      assert has_element?(view, "#open-settings")
    end

    test "closing returns to the dashboard without remounting the LiveView", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/config")
      assert has_element?(view, "#settings-overlay")

      view |> element("#close-settings") |> render_click()

      refute has_element?(view, "#settings-overlay")
      assert has_element?(view, "#quick-toggles")
    end

    test "the six quick toggles fire the same events as always", %{conn: conn} do
      antes = %{
        loot: Pokex.Settings.get(:loot_enabled),
        rescue: Pokex.Settings.get(:rescue_enabled)
      }

      on_exit(fn ->
        Pokex.Settings.put(:loot_enabled, antes.loot)
        Pokex.Settings.put(:rescue_enabled, antes.rescue)
      end)

      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#quick-loot") |> render_click()
      refute Pokex.Settings.get(:loot_enabled) == antes.loot

      view |> element("#quick-rescue") |> render_click()
      refute Pokex.Settings.get(:rescue_enabled) == antes.rescue
    end

    # In single-key mode the form sends only the mode and the key — no combo
    # select, no settle field — so this render is the one place the key input
    # and its save path are exercised.
    test "single-key revive shows its key on this screen, and saves it", %{conn: conn} do
      antes = %{mode: Pokex.Settings.get(:rescue_mode), key: Pokex.Settings.get(:rescue_key)}

      on_exit(fn ->
        Pokex.Settings.put(:rescue_mode, antes.mode)
        Pokex.Settings.put(:rescue_key, antes.key)
      end)

      Pokex.Settings.put(:rescue_mode, "single_key")
      Pokex.Settings.put(:rescue_key, "f4")

      {:ok, view, _html} = live(conn, ~p"/config")
      assert has_element?(view, "#rescue-key[value=f4]")

      view
      |> element("#rescue-combo-form")
      |> render_change(%{"rescue_mode" => "single_key", "rescue_key" => "F5 "})

      assert Pokex.Settings.get(:rescue_key) == "f5"
      assert has_element?(view, "#rescue-key[value=f5]")
    end

    # A measuring switch nobody can find is a measuring switch nobody uses: the
    # only other way to flip it is editing ~/.pokex/settings.json by hand.
    test "measuring the walk is a switch on this screen, off until he flips it", %{conn: conn} do
      antes = Pokex.Settings.get(:cavebot_measure_walk)
      on_exit(fn -> Pokex.Settings.put(:cavebot_measure_walk, antes) end)
      Pokex.Settings.put(:cavebot_measure_walk, false)

      {:ok, view, _html} = live(conn, ~p"/config")
      assert has_element?(view, "#measure-walk-toggle")

      view |> element("#measure-walk-toggle") |> render_click()
      assert Pokex.Settings.get(:cavebot_measure_walk)

      view |> element("#measure-walk-toggle") |> render_click()
      refute Pokex.Settings.get(:cavebot_measure_walk)
    end
  end

  # Judging the layout while the game is BEHIND the panel is judging the wrong
  # picture: the capture is of the DISPLAY. With a single monitor every glance
  # at this page put the browser in front of the HUD and the answer was "não
  # achei o HUD" — a red alarm for the most normal act there is (Lucas,
  # 2026-08-06). Not found and not looked at are different facts.
  test "o jogo atrás do painel não é HUD perdido — e o alarme vermelho continua sendo", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/")

    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      "layout",
      {:layout, %{ok?: false, reason: :game_not_front, anchors: %{}}}
    )

    html = render(view)
    assert html =~ "O jogo está atrás desta janela"
    refute html =~ "Não achei o HUD"

    # uma perda de verdade continua gritando
    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      "layout",
      {:layout, %{ok?: false, reason: :battle_header_not_found, anchors: %{}}}
    )

    assert render(view) =~ "Não achei o HUD"

    Phoenix.PubSub.broadcast(Pokex.PubSub, "layout", {:layout, %{ok?: true, anchors: %{}}})
    refute render(view) =~ "Não achei o HUD"
  end

  # The revive RECALLS the Pokémon and puts it back; the potion just heals. HP
  # falls through the higher number first, so a revive threshold ABOVE the
  # potion's means the potion can NEVER fire and the Pokémon is pulled out of
  # every fight. Lucas ran an hour with revive 65 / potion 50 (2026-08-07) —
  # nothing fished, nothing fought — and read it as "o bot não faz nada certo".
  # The bot was doing exactly what the numbers said; nothing on screen said so.
  test "o ⚙️ avisa quando o revive dispara antes da poção", %{conn: conn} do
    antes = %{
      rescue: Pokex.Settings.get(:pokemon_hp_rescue_pct),
      potion: Pokex.Settings.get(:pokemon_hp_potion_pct),
      rescue_on: Pokex.Settings.get(:rescue_enabled),
      potion_on: Pokex.Settings.get(:potion_enabled)
    }

    on_exit(fn ->
      Pokex.Settings.put(:pokemon_hp_rescue_pct, antes.rescue)
      Pokex.Settings.put(:pokemon_hp_potion_pct, antes.potion)
      Pokex.Settings.put(:rescue_enabled, antes.rescue_on)
      Pokex.Settings.put(:potion_enabled, antes.potion_on)
    end)

    Pokex.Settings.put(:rescue_enabled, true)
    Pokex.Settings.put(:potion_enabled, true)

    # os números dele: o revive pega primeiro e a poção nunca acontece
    Pokex.Settings.put(:pokemon_hp_rescue_pct, 65)
    Pokex.Settings.put(:pokemon_hp_potion_pct, 50)

    {:ok, view, _html} = live(conn, ~p"/config")
    assert has_element?(view, "#rescue-above-potion")
    assert render(view) =~ "recolhido em toda luta"

    # invertidos pro jeito certo, o aviso some
    Pokex.Settings.put(:pokemon_hp_rescue_pct, 20)
    Pokex.Settings.put(:pokemon_hp_potion_pct, 70)

    {:ok, ok_view, _html} = live(conn, ~p"/config")
    refute has_element?(ok_view, "#rescue-above-potion")
  end

  # Os dois números da MORTE moravam só no arquivo de settings — inúteis
  # justamente na noite em que ele está calibrando o que é morte e o que é
  # janela coberta (2026-08-14).
  test "o ⚙️ salva quando a barra que some vira morte, e o intervalo do revive", %{conn: conn} do
    Pokex.SettingsStash.stash_keys!([
      :pokemon_hp_fainted_below_pct,
      :fainted_revive_cooldown_ms
    ])

    {:ok, view, _html} = live(conn, ~p"/config")

    view
    |> form("#fainted-cfg-form", %{"fainted_below_pct" => "25", "fainted_cooldown_s" => "30"})
    |> render_change()

    assert Pokex.Settings.get(:pokemon_hp_fainted_below_pct) == 25
    assert Pokex.Settings.get(:fainted_revive_cooldown_ms) == 30_000
  end

  # "Essas partes da proteção do Pokémon, eu não consigo mais desativar
  # individualmente?" (2026-08-06). Os dois interruptores sempre existiram — na
  # faixa do dashboard. Lendo "revive < 65%" no ⚙️ sem um liga/desliga do lado,
  # a conclusão honesta é que não dá mais. E um revive que ele não consegue
  # parar é um revive em loop num Pokémon que não vai voltar.
  test "revive e poção se desligam ao lado do próprio número, no ⚙️", %{conn: conn} do
    antes = %{
      rescue: Pokex.Settings.get(:rescue_enabled),
      potion: Pokex.Settings.get(:potion_enabled)
    }

    on_exit(fn ->
      Pokex.Settings.put(:rescue_enabled, antes.rescue)
      Pokex.Settings.put(:potion_enabled, antes.potion)
    end)

    {:ok, view, _html} = live(conn, ~p"/config")

    view |> element("#rescue-enabled-toggle") |> render_click()
    refute Pokex.Settings.get(:rescue_enabled) == antes.rescue

    view |> element("#potion-enabled-toggle") |> render_click()
    refute Pokex.Settings.get(:potion_enabled) == antes.potion

    # e um não arrasta o outro
    view |> element("#rescue-enabled-toggle") |> render_click()
    assert Pokex.Settings.get(:rescue_enabled) == antes.rescue
    refute Pokex.Settings.get(:potion_enabled) == antes.potion
  end

  # Lucas asked for the switch to sit "junto da parte de captura, em Settings"
  # (2026-08-05) — and for the sweep to be something he can FIRE and see, not a
  # checkbox he has to trust.
  describe "varredura cega no ⚙️" do
    setup do
      Pokex.SettingsStash.stash!(
        sweep_enabled: false,
        sweep_interval_ms: 30_000,
        sweep_radius_tiles: 4,
        sweep_side: "square"
      )

      :ok
    end

    test "the switch applies to a bot already running", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/config")

      view |> element("#automation-sweep-toggle") |> render_click()
      assert Pokex.Settings.get(:sweep_enabled)

      view |> element("#automation-sweep-toggle") |> render_click()
      refute Pokex.Settings.get(:sweep_enabled)
    end

    test "cadence, radius and side are saved — and the cost is on screen first", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/config")

      html =
        view
        |> form("#sweep-cfg-form", %{
          "sweep_interval_s" => "45",
          "sweep_radius_tiles" => "2",
          "sweep_side" => "right"
        })
        |> render_change()

      assert Pokex.Settings.get(:sweep_interval_ms) == 45_000
      assert Pokex.Settings.get(:sweep_radius_tiles) == 2
      assert Pokex.Settings.get(:sweep_side) == "right"

      # radius 2 to the right = 3 columns × 5 rows, minus his own tile. Raising
      # the radius costs SECONDS of mouse, and the screen says so BEFORE he does.
      assert html =~ "14 bola(s) por passada"
    end

    # The click used to WAIT on the catcher, and a catcher parked on a capture
    # timed the call out — the exit inside handle_event killed the whole page
    # (2026-08-05). Now it asks and moves on; the verdict arrives as a broadcast.
    test "Varrer agora answers on screen without ever waiting on the worker", %{conn: conn} do
      # The button asks the APP-GLOBAL catcher, which would throw real balls into
      # the shared Rig other tests assert on (it did — stray f1+move pairs in
      # DiagnosticsLiveTest, 2026-08-06). Closing the gate is the honest way to
      # keep it grounded: the ask still happens, the sweep is held, and the
      # answer still has to reach the screen.
      Pokex.Bots.InputGate.set_focus_ok(false)
      on_exit(fn -> Pokex.Bots.InputGate.set_focus_ok(true) end)

      {:ok, view, _html} = live(conn, ~p"/config")

      refute has_element?(view, "#sweep-msg")

      assert view |> element("#sweep-now") |> render_click() =~ "pedindo varredura"

      Phoenix.PubSub.broadcast(
        Pokex.PubSub,
        "catcher",
        {:sweep_result, "não varreu: luta em andamento"}
      )

      assert render(view) =~ "não varreu: luta em andamento"
    end
  end

  test "a fishing broadcast updates only the fishing pill", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/config")

    snapshot = %{
      state: :watching,
      counters: %{cycles: 3, hooked: 2, fights: 1, loots: 1, captures: 1, failures: 0},
      error: nil
    }

    Phoenix.PubSub.broadcast(Pokex.PubSub, "fishing", {:fishing, snapshot})

    html = render(view)
    assert html =~ "vigiando"
    assert view |> element("#counter-cycles") |> render() =~ ~r/>\s*3\s*</

    assert html =~ "parado"
  end

  # the age is measured against the mount's clock, a hair before the broadcast — 4 or 5s
  test "hold reason and last action render as pill detail lines", %{conn: conn} do
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
         mode: "still",
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

  test "an active session shows duration and hourly rates in the header", %{conn: conn} do
    at = System.monotonic_time(:millisecond)
    WorldState.put(:session, %{started_at: at - 65_000}, at)
    on_exit(fn -> WorldState.forget(:session) end)

    {:ok, view, html} = live(conn, ~p"/")

    assert has_element?(view, "#session-duration")
    assert html =~ "1m05s"
    assert html =~ "kills/h"
    assert html =~ "capturas/h"
  end

  test "no session: no clock and no rates", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    refute has_element?(view, "#session-duration")
    refute has_element?(view, "#session-rates")
  end

  test "stop condition reached: alarm sounds and the session clock disappears", %{conn: conn} do
    at = System.monotonic_time(:millisecond)
    WorldState.put(:session, %{started_at: at - 5_000}, at)

    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, "#session-duration")

    WorldState.forget(:session)

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

  test "the escape form persists direction, steps and walk wait", %{conn: conn} do
    direction = Pokex.Settings.get(:escape_direction)
    steps = Pokex.Settings.get(:escape_steps)
    wait = Pokex.Settings.get(:escape_walk_wait_ms)

    on_exit(fn ->
      Pokex.Settings.put(:escape_direction, direction)
      Pokex.Settings.put(:escape_steps, steps)
      Pokex.Settings.put(:escape_walk_wait_ms, wait)
    end)

    {:ok, view, _} = live(conn, ~p"/config")

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

  test "a {:rule_alarm, _} (anti-stagnation) sounds the alarm without stopping anything", %{
    conn: conn
  } do
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

  test "a muted sector silences the sound — the feed still records it, and another sector keeps sounding",
       %{
         conn: conn
       } do
    muted = Pokex.Settings.get(:alarm_muted_categories)
    on_exit(fn -> Pokex.Settings.put(:alarm_muted_categories, muted) end)
    Pokex.Settings.put(:alarm_muted_categories, ["stock"])

    {:ok, view, _} = live(conn, ~p"/")

    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      "combat",
      {:rule_alarm, :stock, "estoque baixo: F1 com 9 (limiar 30)"}
    )

    refute_push_event(view, "alarm", %{text: _})
    assert render(view) =~ "⏰ estoque baixo"

    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      "combat",
      {:rule_alarm, :shiny, "✨ SHINY na lista de batalha — LUTA!"}
    )

    assert_push_event(view, "alarm", %{text: text})
    assert text =~ "SHINY"
  end

  @tag :tmp_dir
  # the probe reads the real battle-list capture through the shared Fake's
  # default capture path (/tmp/fake)
  test "shiny guard: action persists, the probe reads the battle list, the log appears", %{
    conn: conn,
    tmp_dir: tmp
  } do
    Application.put_env(:pokex, :home_dir, tmp)

    enabled = Pokex.Settings.get(:shiny_guard_enabled)
    action = Pokex.Settings.get(:shiny_action)

    on_exit(fn ->
      Pokex.TestHome.restore()
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
      neutral_point: {500, 500}
    })

    File.mkdir_p!("/tmp/fake")
    File.cp!("test/fixtures/battle/shiny_star_list.png", "/tmp/fake/shiny_probe.png")

    {:ok, view, _} = live(conn, ~p"/config")

    view |> element(~s(input[phx-click="toggle_shiny_guard"])) |> render_click()
    refute Pokex.Settings.get(:shiny_guard_enabled) == enabled

    view |> form("#shiny-cfg-form", %{"shiny_action" => "escape"}) |> render_change()
    assert Pokex.Settings.get(:shiny_action) == "escape"

    view |> element("#shiny-probe") |> render_click()
    html = render(view)
    assert html =~ "sonda: colunas douradas por linha"
    assert html =~ "L0:"

    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      "shiny",
      {:shiny_reading, %{star_run: 4, min_px: 3}}
    )

    assert render(view) =~ "4<span"

    ShinyLog.record(star_px: 22, action: "escape", outcome: "visto")
    Phoenix.PubSub.broadcast(Pokex.PubSub, "shiny", {:shiny_seen, %{px: 22, action: "escape"}})

    html = render(view)
    assert has_element?(view, "#shiny-log")
    assert html =~ "shinies encontrados (1)"
    assert html =~ "22px"
  end

  test "the escape protocol: button present and {:escape, _, _} sounds the alarm with the result",
       %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/config")

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

  test "the anti-stagnation form persists window and action", %{conn: conn} do
    minutes = Pokex.Settings.get(:stagnation_minutes)
    action = Pokex.Settings.get(:stagnation_action)

    on_exit(fn ->
      Pokex.Settings.put(:stagnation_minutes, minutes)
      Pokex.Settings.put(:stagnation_action, action)
    end)

    {:ok, view, _} = live(conn, ~p"/config")

    view
    |> form("#stagnation-form", %{"stagnation_minutes" => "10", "stagnation_action" => "stop"})
    |> render_change()

    assert Pokex.Settings.get(:stagnation_minutes) == 10
    assert Pokex.Settings.get(:stagnation_action) == "stop"
  end

  test "the stop-conditions form persists minutes and kills", %{conn: conn} do
    minutes = Pokex.Settings.get(:stop_after_minutes)
    kills = Pokex.Settings.get(:stop_after_kills)

    on_exit(fn ->
      Pokex.Settings.put(:stop_after_minutes, minutes)
      Pokex.Settings.put(:stop_after_kills, kills)
    end)

    {:ok, view, _} = live(conn, ~p"/config")

    view
    |> form("#stop-conditions-form", %{"stop_minutes" => "120", "stop_kills" => "200"})
    |> render_change()

    assert Pokex.Settings.get(:stop_after_minutes) == 120
    assert Pokex.Settings.get(:stop_after_kills) == 200
  end

  test "a new worker error fires the alarm once; the gap dedupes the relapse", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")

    err = %{state: :error, counters: %{cycles: 0, hooked: 0, failures: 1}, error: "vara sumiu"}
    ok = %{err | state: :watching, error: nil}

    Phoenix.PubSub.broadcast(Pokex.PubSub, "fishing", {:fishing, err})
    assert_push_event(view, "alarm", %{text: text})
    assert text =~ "pesca em erro: vara sumiu"
    assert render(view) =~ "🔔"

    Phoenix.PubSub.broadcast(Pokex.PubSub, "fishing", {:fishing, ok})
    Phoenix.PubSub.broadcast(Pokex.PubSub, "fishing", {:fishing, err})
    render(view)
    refute_push_event(view, "alarm", %{text: _})
  end

  test "muted alarm: no sound, but the feed still records", %{conn: conn} do
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

  test "HP crossing the rescue threshold fires the critical-life alarm", %{conn: conn} do
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
      mode: "still",
      counters: %{captures: 2, throws: 3, ignored: 0},
      error: nil
    }

    Phoenix.PubSub.broadcast(Pokex.PubSub, "catcher", {:catcher, snapshot})

    assert render(view) =~ "capturando"
    assert has_element?(view, "[data-testid=catcher-pill][data-state=armed]")
  end

  test "switching modes applies the whole bundle and the button announces what will start", %{
    conn: conn
  } do
    Pokex.SettingsStash.stash_keys!([:player_mode, :capture_enabled, :reposition_enabled])

    {:ok, view, _} = live(conn, ~p"/")

    view |> element("#mode-moving") |> render_click()
    assert Pokex.Settings.get(:player_mode) == "moving"
    refute Pokex.Settings.get(:capture_enabled)
    refute Pokex.Settings.get(:reposition_enabled)

    html = render(view)
    assert html =~ "Iniciar — modo Movimento"
    assert html =~ "batalha"
    refute html =~ "liga pesca"

    view |> element("#mode-still") |> render_click()
    assert Pokex.Settings.get(:capture_enabled)

    {:ok, config, _} = live(conn, ~p"/config")
    assert render(config) =~ "Reaprender chão"
  end

  # a switch may disagree with the mode, but the panel must SAY so rather than
  # let the two quietly differ
  test "a manual exception to the mode default is marked and restorable", %{conn: conn} do
    Pokex.SettingsStash.stash_keys!([:player_mode, :capture_enabled, :reposition_enabled])

    {:ok, view, _} = live(conn, ~p"/config")
    view |> element("#mode-still") |> render_click()
    refute has_element?(view, "[data-testid=override-badge]")

    view |> element(~s(#automation-reposition input)) |> render_click()

    assert has_element?(view, "#automation-reposition [data-testid=override-badge]")
    assert render(view) =~ "1 exceção"
    refute Pokex.Settings.get(:reposition_enabled)

    view |> element("#restore-mode-defaults") |> render_click()
    assert Pokex.Settings.get(:reposition_enabled)
    refute render(view) =~ "restore-mode-defaults"
  end

  # The blind sweep is excellent for an ordinary fishing hunt and wrong when he
  # is after one specific quarry, and he switches between the two in the same
  # session — so it belongs on the strip he can reach without opening a screen,
  # not three clicks deep in the ⚙️.
  test "the blind sweep can be flipped from the panel itself", %{conn: conn} do
    original = Pokex.Settings.get(:sweep_enabled)
    on_exit(fn -> Pokex.Settings.put(:sweep_enabled, original) end)

    {:ok, view, _} = live(conn, ~p"/")

    assert has_element?(view, "#quick-sweep")

    view |> element("#quick-sweep") |> render_click()
    refute Pokex.Settings.get(:sweep_enabled) == original

    view |> element("#quick-sweep") |> render_click()
    assert Pokex.Settings.get(:sweep_enabled) == original
  end

  # He keeps more than one kind of ball on the hotbar and wants the good one
  # spent on the creature he is hunting, not on everything.
  describe "which ball for which corpse" do
    setup do
      types = Pokex.Settings.get(:ball_types)
      rules = Pokex.Settings.get(:ball_rules)

      on_exit(fn ->
        Pokex.Settings.put(:ball_types, types)
        Pokex.Settings.put(:ball_rules, rules)
      end)

      :ok
    end

    test "a rule written on the screen is the rule the aim obeys", %{conn: conn} do
      Pokex.Settings.put(:ball_rules, [
        %{"trigger" => %{"kind" => "species", "value" => "Rattata"}, "key" => "f2"}
      ])

      {:ok, view, _} = live(conn, ~p"/config")

      view
      |> element("#ball-rule-0")
      |> render_change(%{"idx" => "0", "kind" => "element", "value" => "Water", "key" => "f2"})

      assert [%{"trigger" => %{"kind" => "element", "value" => "Water"}, "key" => "f2"}] =
               Pokex.Settings.get(:ball_rules)

      assert Pokex.Bots.Catcher.Balls.key_for("Tentacool") == "f2"
    end

    test "a rule can be added and thrown away", %{conn: conn} do
      before = length(Pokex.Settings.get(:ball_rules))
      {:ok, view, _} = live(conn, ~p"/config")

      view |> element("#ball-rule-add") |> render_click()
      assert length(Pokex.Settings.get(:ball_rules)) == before + 1

      view
      |> element(~s(button[phx-click="ball_rule_remove"][phx-value-idx="0"]))
      |> render_click()

      assert length(Pokex.Settings.get(:ball_rules)) == before
    end

    # Removing the last ball would leave nothing to throw AND a value Settings
    # refuses (a list key's type is read off its seed, which is never empty).
    test "throwing away the last ball falls back to the shipped list", %{conn: conn} do
      Pokex.Settings.put(:ball_types, [%{"key" => "f2", "name" => "Só essa"}])
      {:ok, view, _} = live(conn, ~p"/config")

      view
      |> element(~s(button[phx-click="ball_type_remove"][phx-value-idx="0"]))
      |> render_click()

      assert Pokex.Settings.get(:ball_types) == Map.fetch!(Pokex.Settings.defaults(), :ball_types)
    end
  end

  test "loot and capture toggles persist independently", %{conn: conn} do
    loot = Pokex.Settings.get(:loot_enabled)
    cap = Pokex.Settings.get(:capture_enabled)

    on_exit(fn ->
      Pokex.Settings.put(:loot_enabled, loot)
      Pokex.Settings.put(:capture_enabled, cap)
    end)

    {:ok, view, _} = live(conn, ~p"/")

    view |> element("#quick-loot") |> render_click()
    refute Pokex.Settings.get(:loot_enabled) == loot

    view |> element("#quick-capture") |> render_click()
    refute Pokex.Settings.get(:capture_enabled) == cap
  end

  test "the post-fight policy (support waits for capture) persists via the toggle", %{conn: conn} do
    value = Pokex.Settings.get(:support_waits_capture)
    on_exit(fn -> Pokex.Settings.put(:support_waits_capture, value) end)

    {:ok, view, _} = live(conn, ~p"/config")

    view |> element(~s(input[phx-click="toggle_support_waits_capture"])) |> render_click()
    refute Pokex.Settings.get(:support_waits_capture) == value
  end

  # busy is the exact shape BotSupervisor.safe_status/2 falls back to; it means
  # UNKNOWN, not running
  test "the busy placeholder snapshots render without crashing (worker missed its status window)",
       %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")

    busy = %{state: :busy, counters: %{}, error: "sem resposta (captura lenta?)"}

    Phoenix.PubSub.broadcast(Pokex.PubSub, "fishing", {:fishing, busy})
    Phoenix.PubSub.broadcast(Pokex.PubSub, "combat", {:combat, Map.put(busy, :locked_row, nil)})
    Phoenix.PubSub.broadcast(Pokex.PubSub, "catcher", {:catcher, Map.put(busy, :mode, "still")})

    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      "mini_game",
      {:mini_game, Map.merge(busy, %{in_game?: false, confidence: 0.0})}
    )

    Phoenix.PubSub.broadcast(Pokex.PubSub, "game", {:game, Map.put(busy, :hp_pct, nil)})

    html = render(view)
    assert html =~ "ocupado"
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

  # the old assertion `render(view) =~ "mudo"` passed by accident: "mudou" in
  # three unrelated texts contains the substring, so the mute was never verified
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

    view |> element(~s(button[phx-click="toggle_mini_game_sound"])) |> render_click()
    assert Pokex.Settings.get(:mini_game_sound) == false

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

  # a worker on an old build mid hot-reload can still send the pre-level 2-tuple shape
  test "tolerates a legacy 2-tuple log broadcast without crashing", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")

    Phoenix.PubSub.broadcast(Pokex.PubSub, "fishing", {:fishing_log, "stale build line"})
    view |> element(~s(input[phx-click="toggle_debug"])) |> render_click()
    assert render(view) =~ "stale build line"
  end

  @tag :tmp_dir
  test "exports the recent events to a downloadable file", %{conn: conn, tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Pokex.TestHome.restore() end)

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
    on_exit(fn -> Pokex.TestHome.restore() end)
    save_calibration()

    {:ok, view, _} = live(conn, ~p"/config")
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
    on_exit(fn -> Pokex.TestHome.restore() end)
    save_calibration()

    Agent.stop(Fake)

    {:ok, _} =
      Fake.start_link(%{
        capture: [
          {:ok, png!(tmp, "g.png", 8, 8, {0, 180, 200})},
          {:ok, png!(tmp, "b.png", 20, 12, {0, 200, 0})},
          {:ok, png!(tmp, "s.png", 8, 12, {255, 0, 0})},
          {:ok, png!(tmp, "a.png", 12, 12, {0, 0, 0})},
          {:ok, png!(tmp, "p.png", 50, 50, {0, 0, 0})}
        ],
        capture_screen: [{:ok, png!(tmp, "scr.png", 60, 40, {0, 0, 0})}]
      })

    {:ok, view, _} = live(conn, ~p"/config")
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

    {:ok, view, _} = live(conn, ~p"/config")

    view |> element(~s(input[phx-click="toggle_require_cooldowns"])) |> render_click()
    refute Pokex.Settings.get(:require_cooldowns) == req

    view |> form("#hook-skills-form", %{"hook_skills" => "5 6 7"}) |> render_submit()
    assert Pokex.Settings.get(:hook_skill_keys) == ["5", "6", "7"]
  end

  @tag :tmp_dir
  test "per-Pokémon preset: save → apply → delete in the panel", %{conn: conn, tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Pokex.TestHome.restore() end)

    keys = Pokex.Settings.get(:hook_skill_keys)
    on_exit(fn -> Pokex.Settings.put(:hook_skill_keys, keys) end)

    {:ok, view, _} = live(conn, ~p"/config")

    Pokex.Settings.put(:hook_skill_keys, ["8", "9"])
    view |> form("#preset-save-form", %{"name" => "Blastoise"}) |> render_submit()
    html = render(view)
    assert html =~ "Preset &quot;blastoise&quot; salvo"
    assert html =~ "fisga 8 9"

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

  test "the ⚙️ saves the capture knobs — the UI speaks %, the setting stores a fraction", %{
    conn: conn
  } do
    originais =
      for key <- [
            :corpse_match_min_similarity,
            :ball_key,
            :ball_needs_click,
            :corpse_max_balls,
            :corpse_scan_radius_tiles,
            :dry_balls_alarm
          ],
          into: %{},
          do: {key, Pokex.Settings.get(key)}

    on_exit(fn -> Enum.each(originais, fn {k, v} -> Pokex.Settings.put(k, v) end) end)

    {:ok, view, _} = live(conn, ~p"/config")

    view
    |> form("#capture-cfg-form", %{
      "corpse_match_pct" => "80",
      "ball_key" => "F3",
      "corpse_max_balls" => "3",
      "corpse_scan_radius_tiles" => "4",
      "dry_balls_alarm" => "6"
    })
    |> render_change()

    assert Pokex.Settings.get(:corpse_match_min_similarity) == 0.8
    assert Pokex.Settings.get(:ball_key) == "f3"
    assert Pokex.Settings.get(:corpse_max_balls) == 3
    assert Pokex.Settings.get(:corpse_scan_radius_tiles) == 4
    assert Pokex.Settings.get(:dry_balls_alarm) == 6

    view |> form("#capture-cfg-form", %{"ball_key" => "  "}) |> render_change()
    assert Pokex.Settings.get(:ball_key) == "f3"

    refute Pokex.Settings.get(:ball_needs_click)
    view |> element("#automation-ball-click-toggle") |> render_click()
    assert Pokex.Settings.get(:ball_needs_click)
  end

  test "the ⚙️ saves the stock thresholds", %{conn: conn} do
    originais =
      for key <- [:stock_alert_f1, :stock_alert_f2, :stock_alert_e, :stock_alert_s_q],
          into: %{},
          do: {key, Pokex.Settings.get(key)}

    on_exit(fn -> Enum.each(originais, fn {k, v} -> Pokex.Settings.put(k, v) end) end)

    {:ok, view, _} = live(conn, ~p"/config")

    view
    |> form("#stock-cfg-form", %{
      "stock_alert_f1" => "50",
      "stock_alert_f2" => "15",
      "stock_alert_e" => "8",
      "stock_alert_s_q" => "12"
    })
    |> render_change()

    assert Pokex.Settings.get(:stock_alert_f1) == 50
    assert Pokex.Settings.get(:stock_alert_f2) == 15
    assert Pokex.Settings.get(:stock_alert_e) == 8
    assert Pokex.Settings.get(:stock_alert_s_q) == 12
  end

  # the cooldown floor is 2s (lowered from 5); the boundary value must save
  test "saves the rescue threshold + cooldown and rejects nonsense values", %{conn: conn} do
    original = Pokex.Settings.get(:pokemon_hp_rescue_pct)
    cooldown = Pokex.Settings.get(:rescue_cooldown_ms)

    on_exit(fn ->
      Pokex.Settings.put(:pokemon_hp_rescue_pct, original)
      Pokex.Settings.put(:rescue_cooldown_ms, cooldown)
    end)

    {:ok, view, _} = live(conn, ~p"/config")

    view
    |> form("#rescue-cfg-form", %{"rescue_pct" => "30", "rescue_cooldown_s" => "20"})
    |> render_change()

    assert Pokex.Settings.get(:pokemon_hp_rescue_pct) == 30
    assert Pokex.Settings.get(:rescue_cooldown_ms) == 20_000
    assert has_element?(view, ~s(#rescue-pct[value="30"]))

    view
    |> form("#rescue-cfg-form", %{"rescue_pct" => "95", "rescue_cooldown_s" => "1"})
    |> render_change()

    view
    |> form("#rescue-cfg-form", %{"rescue_pct" => "abc", "rescue_cooldown_s" => "45"})
    |> render_change()

    assert Pokex.Settings.get(:pokemon_hp_rescue_pct) == 30
    assert Pokex.Settings.get(:rescue_cooldown_ms) == 45_000

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

    {:ok, view, _} = live(conn, ~p"/config")

    view
    |> form("#potion-cfg-form", %{"potion_pct" => "65", "potion_cooldown_s" => "8"})
    |> render_change()

    assert Pokex.Settings.get(:pokemon_hp_potion_pct) == 65
    assert Pokex.Settings.get(:potion_cooldown_ms) == 8_000
    assert has_element?(view, ~s(#potion-pct[value="65"]))

    view
    |> form("#potion-cfg-form", %{"potion_pct" => "0", "potion_cooldown_s" => "700"})
    |> render_change()

    assert Pokex.Settings.get(:pokemon_hp_potion_pct) == 65
    assert Pokex.Settings.get(:potion_cooldown_ms) == 8_000

    view |> element(~s(#quick-potion)) |> render_click()
    refute Pokex.Settings.get(:potion_enabled) == enabled
  end

  @tag :tmp_dir
  test "the 'Ler' button reads the skill bar on demand", %{conn: conn, tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Pokex.TestHome.restore() end)

    row = List.duplicate({200, 200, 0, 255}, 12) ++ List.duplicate({20, 20, 20, 255}, 2)
    bar = Pokex.PngFixtures.write!(Path.join(tmp, "bar.png"), [row])
    Agent.stop(Fake)
    {:ok, _} = Fake.start_link(%{capture: [{:ok, bar}]})

    Pokex.Calibration.save(%Pokex.Calibration{
      scale: 1.0,
      screen_w: 100,
      screen_h: 75,
      water_point: {50, 30},
      glow_region: {18, -2, 64, 64},
      battle_region: {70, 10, 20, 30},
      neutral_point: {52, 36},
      skill_bar_region: {0, 0, 14, 1}
    })

    {:ok, view, _} = live(conn, ~p"/")
    assert render(view) =~ "Clique em Ler"

    view |> element(~s(button[phx-click="read_cooldowns"])) |> render_click()
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
      neutral_point: {420, 350}
    })
  end

  # the Guardian re-broadcasts {:panic} on every poll tick while the cursor sits
  # in the corner — repeats must not duplicate log spam
  test "a panic broadcast idles both pills and is idempotent on repeat", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")

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

    Phoenix.PubSub.broadcast(Pokex.PubSub, "fishing", {:panic, "kill corner"})
    Phoenix.PubSub.broadcast(Pokex.PubSub, "combat", {:panic, "kill corner"})
    Phoenix.PubSub.broadcast(Pokex.PubSub, "fishing", {:panic, "kill corner"})

    logs_after_repeat = view |> element("#activity-feed") |> render()
    assert logs_after_first == logs_after_repeat
  end

  # cleanup restores the seed default: the old cleanup put nil, which became a
  # real nil override in the global mirror and randomly broke settings_test
  # depending on file order
  test "saves glow threshold", %{conn: conn} do
    threshold = Pokex.Settings.get(:glow_threshold)
    on_exit(fn -> Pokex.Settings.put(:glow_threshold, threshold) end)

    {:ok, view, _} = live(conn, ~p"/config")
    view |> form("#threshold-form", %{"threshold" => "21.5"}) |> render_submit()
    assert Pokex.Settings.get(:glow_threshold) == 21.5
  end

  # positive timing knobs clamp 0 up to 1 instead of persisting an inert combat setting
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

    {:ok, view, _} = live(conn, ~p"/config")

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
    assert Pokex.Settings.get(:combat_skill_tap_count) == 1
    assert Pokex.Settings.get(:combat_skill_gap_ms) == 25
    assert Pokex.Settings.get(:combat_skill_jitter_ms) == 20
    assert Pokex.Settings.get(:fight_timeout_ms) == 5000
    assert Pokex.Settings.get(:target_lost_streak) == original_streak
  end

  test "capture metrics block reports the backend on demand", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/config")

    html = view |> element(~s(button[phx-click="read_capture_stats"])) |> render_click()
    assert html =~ "backend:"
    assert html =~ "screencapture CLI" or html =~ "ScreenCaptureKit"
  end

  describe "the hunt on the panel" do
    # the hunt died in ~6s "saying nothing" — and truly said nothing: the worker
    # emitted snapshot, log and alarm, and the panel never subscribed to the
    # topic. These tests guard the consumption of those three messages.
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

    # A worker that DIED or wedged keeps its last snapshot on screen forever,
    # which reads as "walking, all good" while nothing is happening. Lucas asked
    # for visibility of a problem even with the sound off (2026-08-03).
    test "a worker that goes silent says so, in its own row", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      Phoenix.PubSub.broadcast(Pokex.PubSub, @cavebot_topic, {:cavebot, walking_snapshot()})
      assert view |> element("[data-testid=cavebot-pill]") |> render() =~ "andando"
      refute view |> element("[data-testid=cavebot-pill]") |> render() =~ "sem notícias"

      # the clock moves on without a new snapshot
      send(view.pid, {:silence_check, System.monotonic_time(:millisecond) + 60_000})

      row = view |> element("[data-testid=cavebot-pill]") |> render()
      assert row =~ "sem notícias"
      assert row =~ "text-pk-danger"
    end

    # The hunt is the only worker that can stop somewhere nobody went, and its
    # three stop states have different fixes — so the panel states the problem
    # in full instead of a truncated pill word.
    test "a blocked hunt states the problem in a banner, sound or no sound", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      Phoenix.PubSub.broadcast(
        Pokex.PubSub,
        @cavebot_topic,
        {:cavebot,
         walking_snapshot(%{
           state: :blocked,
           hold_reason: "não sei onde estou há 12s — a coordenada do minimapa não está sendo lida"
         })}
      )

      banner = view |> element("[data-testid=cavebot-problem]") |> render()

      assert banner =~ "Caçada bloqueada"
      assert banner =~ "não sei onde estou"
    end

    test "a walking hunt shows no problem banner", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      Phoenix.PubSub.broadcast(Pokex.PubSub, @cavebot_topic, {:cavebot, walking_snapshot()})

      refute has_element?(view, "[data-testid=cavebot-problem]")
    end

    test "a stopped worker is quiet on purpose and is never accused", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      Phoenix.PubSub.broadcast(
        Pokex.PubSub,
        @cavebot_topic,
        {:cavebot, walking_snapshot(%{state: :idle})}
      )

      send(view.pid, {:silence_check, System.monotonic_time(:millisecond) + 60_000})

      refute view |> element("[data-testid=cavebot-pill]") |> render() =~ "sem notícias"
    end

    # the waypoint index is 0-based in the worker and 1-based on screen (the
    # number seen in /cavebot's waypoint list)
    test "the hunt pill exists on mount and narrates the route while walking", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/")

      assert html =~ "Caçada"
      assert has_element?(view, "[data-testid=cavebot-pill]")

      Phoenix.PubSub.broadcast(Pokex.PubSub, @cavebot_topic, {:cavebot, walking_snapshot()})

      row = view |> element("[data-testid=cavebot-pill]") |> render()

      assert row =~ "andando"
      assert row =~ "cavena"
      assert row =~ "wp 3/9"
      assert row =~ "faltam 5,1 tiles"
      assert row =~ "41 passos"
      assert has_element?(view, "[data-testid=cavebot-pill][data-state=walking]")
    end

    test "a hunt line appears in the feed", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")

      Phoenix.PubSub.broadcast(
        Pokex.PubSub,
        @cavebot_topic,
        {:cavebot_log, :macro, "caçada: waypoint 3/9"}
      )

      assert eventually_html(view, "caçada: waypoint 3/9")
      assert view |> element("#activity-feed") |> render() =~ "🧭"
    end

    # the filter compares the source by EXACT equality: an emoji typed with a
    # different variation selector in the two places would filter to an empty feed
    test "the 🧭 chip filters the hunt feed (exact binary comparison)", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")

      Phoenix.PubSub.broadcast(
        Pokex.PubSub,
        @cavebot_topic,
        {:cavebot_log, :macro, "caçada: waypoint 3/9"}
      )

      Phoenix.PubSub.broadcast(Pokex.PubSub, "fishing", {:fishing_log, :macro, "arremesso"})

      view
      |> element(~s(button[phx-click="filter_feed"][phx-value-source="🧭"]))
      |> render_click()

      feed = view |> element("#activity-feed") |> render()
      assert feed =~ "caçada: waypoint 3/9"
      refute feed =~ "arremesso"
    end

    test "a blockage does not crash the LiveView and becomes a visible line", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")

      Phoenix.PubSub.broadcast(Pokex.PubSub, @cavebot_topic, {:cavebot_alarm, :stuck})

      assert render(view) =~ "Caçada"
      assert view |> element("#activity-feed") |> render() =~ "caçada parada: travado"
    end

    test "a stopped state never lights the active dot", %{conn: conn} do
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
               "#{state} lit green — a stalled cavebot must not look healthy"

        assert row =~ "bg-pk-text-3"
        assert row =~ "🔒 parei: travado"
      end
    end

    test "an unknown message on the topic does not crash the panel", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")

      send(view.pid, {:cavebot_something_new, %{}})

      assert render(view) =~ "Caçada"
    end
  end

  describe "position on the panel" do
    setup do
      on_exit(fn -> WorldState.forget(:minimap) end)
      :ok
    end

    test "a good read says where the player is and how long ago", %{conn: conn} do
      now = System.monotonic_time(:millisecond)
      WorldState.put(:minimap, %{pos: {337, 46_107, 4}}, now)

      {:ok, view, _} = live(conn, ~p"/")

      position = view |> element("#world-position") |> render()
      assert position =~ "337, 46107 · andar 4"
      assert position =~ "lendo tua posição"
      assert position =~ "agora"
    end

    test "a stopped read is spelled out, with the age of the last read", %{conn: conn} do
      now = System.monotonic_time(:millisecond)
      WorldState.put(:minimap, %{pos: {337, 46_107, 4}}, now - 20_000)

      {:ok, view, _} = live(conn, ~p"/")

      position = view |> element("#world-position") |> render()
      assert position =~ "NÃO estou lendo tua posição"
      assert position =~ "há 20s"
    end

    # the feed is reading NOW; the coordinate failed (all-or-nothing: one
    # doubtful glyph kills all three numbers)
    test "an unreadable coordinate is different from a stopped feed", %{conn: conn} do
      now = System.monotonic_time(:millisecond)
      WorldState.put(:minimap, %{pos: nil}, now)

      {:ok, view, _} = live(conn, ~p"/")

      position = view |> element("#world-position") |> render()
      assert position =~ "coordenada saiu ilegível"
      refute position =~ "NÃO estou lendo"
    end

    test "the good/bad read ratio counts the feed's publications", %{conn: conn} do
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

  describe "the combos card" do
    setup do
      tmp =
        Path.join(System.tmp_dir!(), "pokex-panel-combos-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      Application.put_env(:pokex, :home_dir, tmp)

      on_exit(fn ->
        Pokex.TestHome.restore()
        File.rm_rf!(tmp)
        # mounting the panel attaches the display feeds, which can leave a
        # :layout fact behind — and a test elsewhere asserts on NOT having one
        Enum.each([:team, :layout], &WorldState.forget/1)
      end)

      :ok
    end

    defp team_on_screen(rows) do
      WorldState.put(
        :team,
        %{pokemon_hp: nil, rows: rows},
        System.monotonic_time(:millisecond)
      )
    end

    test "lists the seeded combo and marks the step that cannot run", %{conn: conn} do
      team_on_screen([
        %{slot: 2, name: "Xatu", present?: true, hp_pct: 1.0},
        %{slot: 5, name: "Wigglytuff", present?: true, hp_pct: 1.0}
      ])

      {:ok, view, _} = live(conn, ~p"/config")

      assert has_element?(view, "#combos-card")
      assert render(view) =~ "sing"
      assert has_element?(view, ~s([title*="Jigglypuff NÃO está nos atalhos"]))
    end

    test "creating a combo uses the team read off the screen and it takes effect", %{conn: conn} do
      team_on_screen([%{slot: 5, name: "Wigglytuff", present?: true, hp_pct: 1.0}])

      {:ok, view, _} = live(conn, ~p"/config")

      view
      |> element("#combo-form")
      |> render_change(%{
        "name" => "dorme",
        "trigger_kind" => "element",
        "trigger_value" => "Water"
      })

      view
      |> element("#combo-form")
      |> render_change(%{"step_kind" => "swap_member", "step_value" => "Wigglytuff"})

      view |> element("#combo-add-step") |> render_click()

      view |> element("#combo-form") |> render_change(%{"step_kind" => "swap_counter"})
      view |> element("#combo-add-step") |> render_click()

      view |> element("#combo-form") |> render_submit(%{})

      saved = Enum.find(Store.all(), &(&1.name == "dorme"))
      assert saved.trigger == {:enemy_element, "Water"}
      assert {:swap_member, "Wigglytuff"} in saved.steps
      assert {:swap_counter} in saved.steps
      assert saved.dungeon == nil
      refute has_element?(view, ~s([title*="Wigglytuff NÃO está nos atalhos"]))
    end

    test "a combo can apply to a single dungeon, and the row shows which", %{conn: conn} do
      team_on_screen([%{slot: 5, name: "Wigglytuff", present?: true, hp_pct: 1.0}])

      {:ok, view, _} = live(conn, ~p"/config")

      view
      |> element("#combo-form")
      |> render_change(%{
        "name" => "na-dg",
        "trigger_kind" => "element",
        "trigger_value" => "Water",
        "dungeon" => "  cavena  ",
        "step_kind" => "skill",
        "step_value" => "4"
      })

      view |> element("#combo-add-step") |> render_click()
      view |> element("#combo-form") |> render_submit(%{})

      assert Enum.find(Store.all(), &(&1.name == "na-dg")).dungeon == "cavena"
      assert view |> element(~s(#combo-na-dg)) |> render() =~ "cavena"
    end

    test "deleting removes the combo from the list", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/config")

      view |> element(~s([phx-click="delete_combo"][phx-value-name="sing"])) |> render_click()

      refute Enum.any?(Store.all(), &(&1.name == "sing"))
    end

    # Editing a SAVED combo. Before this, tuning the rescue's first wait meant
    # deleting the combo and rebuilding it step by step.
    # Its OWN combo, not the seed: this is about editing arbitrary steps, and a
    # test that leans on whatever the seed happens to be breaks when the seed
    # changes for unrelated reasons.
    @editable_steps [{:wait, 400}, {:skill, "1"}, {:wait, 500}, {:skill, "2"}]

    defp editable_combo! do
      :ok =
        Store.add(%Combo{
          name: "socorro",
          trigger: {:rescue_only},
          steps: @editable_steps,
          dungeon: "cavena"
        })
    end

    defp open_editor(conn, name \\ "socorro") do
      if name == "socorro", do: editable_combo!()
      {:ok, view, _} = live(conn, ~p"/config")
      view |> element(~s([phx-click="edit_combo"][phx-value-name="#{name}"])) |> render_click()
      view
    end

    defp steps_of(name) do
      Store.all() |> Enum.find(&(&1.name == name)) |> Map.fetch!(:steps)
    end

    defp save_edit(view, name) do
      view |> element(~s(#combo-edit-#{name} button), "Salvar") |> render_click()
    end

    test "editing: the pencil turns the steps into fields, one per step", %{conn: conn} do
      view = open_editor(conn)

      assert has_element?(view, "#combo-edit-socorro")
      assert has_element?(view, ~s([data-testid="combo-edit-step-0"]))
      assert has_element?(view, ~s([data-testid="combo-edit-step-3"]))
      refute has_element?(view, ~s([data-testid="combo-edit-step-4"]))
    end

    test "editing: only the combo being edited opens", %{conn: conn} do
      view = open_editor(conn)

      assert has_element?(view, "#combo-edit-socorro")
      refute has_element?(view, "#combo-edit-sing")
    end

    test "editing: a step dragged onto another position stays there", %{conn: conn} do
      view = open_editor(conn)

      render_hook(view, "move_combo_step", %{"from" => 1, "to" => 0})
      save_edit(view, "socorro")

      assert [{:skill, "1"}, {:wait, 400} | _rest] = steps_of("socorro")
    end

    test "editing: a wait takes a new duration and it reaches the file", %{conn: conn} do
      view = open_editor(conn)

      render_hook(view, "change_combo_step", %{"index" => "0", "value" => "1200"})
      save_edit(view, "socorro")

      assert [{:wait, 1200} | _rest] = steps_of("socorro")
    end

    test "editing: a skill takes a new hotbar key", %{conn: conn} do
      view = open_editor(conn)

      render_hook(view, "change_combo_step", %{"index" => "1", "value" => "7"})
      save_edit(view, "socorro")

      assert [_wait, {:skill, "7"} | _rest] = steps_of("socorro")
    end

    test "editing: a step can be dropped", %{conn: conn} do
      view = open_editor(conn)
      before = length(steps_of("socorro"))

      view
      |> element(~s([phx-click="delete_combo_step"][phx-value-index="0"]))
      |> render_click()

      save_edit(view, "socorro")

      assert length(steps_of("socorro")) == before - 1
      assert [{:skill, "1"} | _rest] = steps_of("socorro")
    end

    test "editing: a step can be appended while editing", %{conn: conn} do
      view = open_editor(conn)
      before = length(steps_of("socorro"))

      view
      |> element("#combo-edit-add-form")
      |> render_change(%{"step_kind" => "wait", "step_value" => "800"})

      view |> element("#combo-edit-add-step") |> render_click()
      save_edit(view, "socorro")

      steps = steps_of("socorro")
      assert length(steps) == before + 1
      assert List.last(steps) == {:wait, 800}
    end

    test "editing: cancelling throws the edit away and leaves the file untouched", %{conn: conn} do
      view = open_editor(conn)
      before = steps_of("socorro")

      render_hook(view, "change_combo_step", %{"index" => "0", "value" => "9999"})
      view |> element(~s(#combo-edit-socorro button), "Cancelar") |> render_click()

      assert steps_of("socorro") == before
      refute has_element?(view, "#combo-edit-socorro")
    end

    # The name is the identity everything else works by, and the badges on the
    # card come from the trigger and the on/off flag.
    test "editing: the steps change but the trigger, dungeon and on/off keep the trigger, the dungeon and the on/off state",
         %{conn: conn} do
      :ok = Store.set_enabled("sing", false)
      sing = Enum.find(Store.all(), &(&1.name == "sing"))

      view = open_editor(conn, "sing")
      render_hook(view, "move_combo_step", %{"from" => 0, "to" => 2})
      save_edit(view, "sing")

      saved = Enum.find(Store.all(), &(&1.name == "sing"))
      assert saved.trigger == sing.trigger
      assert saved.dungeon == sing.dungeon
      assert saved.enabled? == false
    end

    # "I turned combos on and nothing happened" gets an answer
    test "a broadcast refusal appears on the panel in Portuguese", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/config")

      Phoenix.PubSub.broadcast(
        Pokex.PubSub,
        Runner.topic(),
        {:combo_skipped,
         %{combo: "sing", enemy: "Tentacool", reason: {:not_on_screen, "Jigglypuff"}}}
      )

      html = render(view)
      assert html =~ "sing não rodou contra Tentacool"
      assert html =~ "Jigglypuff não está nos atalhos"
    end

    test "a wait step shows the milliseconds, not the setting name", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/config")

      chip = view |> element(~s([title*="combo_swap_wait_ms"])) |> render()

      assert chip =~ "espera #{Pokex.Settings.get(:combo_swap_wait_ms)}ms"
      assert chip =~ "ajustável nas configurações"
    end
  end

  describe "the visual system" do
    # Markup guards for things a LiveView test cannot measure in pixels.
    # MEASURED in the browser at the real window width: the worker status lines
    # had 15-30px of slack, the support line was ALREADY cut, and the uppercase
    # + 0.1em treatment alone accounted for 36px (15%) of the width. Nothing
    # here re-measures that — these keep the causes from coming back.
    test "worker states are not written in spaced uppercase", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")

      for testid <- ~w(fishing combat catcher mini-game support cavebot) do
        row = view |> element(~s([data-testid="#{testid}-pill"])) |> render()

        refute row =~ "uppercase",
               "a linha de #{testid} voltou pra caixa alta — ela custa 15% da largura"

        refute row =~ "tracking-[0.1em]"
      end
    end

    test "a worker's state is never truncated; the last action may be", %{conn: conn} do
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

      assert row =~ "monitorando"
      assert row =~ "27 revive · 194 poção"
      refute row =~ ~s(class="min-w-0 flex-1 text-pk-body text-pk-text-2 truncate)
    end

    test "a value not yet read renders as — and never as ?", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")
      world = view |> element("#world-card") |> render()

      refute world =~ ">?<"
      assert world =~ "—"
    end
  end

  describe "character picker" do
    test "the character picker switches active_character", %{conn: conn} do
      Pokex.SettingsStash.stash_keys!([:active_character])
      {:ok, view, _} = live(conn, ~p"/")
      assert has_element?(view, "#character-picker")
      view |> element("form[phx-change=set_character]") |> render_change(%{"character" => ""})
      assert Pokex.Settings.get(:active_character) == ""
    end

    test "creating a character selects it", %{conn: conn} do
      tmp = Path.join(System.tmp_dir!(), "pokex-char-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      Application.put_env(:pokex, :home_dir, tmp)
      Pokex.SettingsStash.stash_keys!([:active_character])

      on_exit(fn ->
        Pokex.TestHome.restore()
        File.rm_rf!(tmp)
      end)

      {:ok, view, _} = live(conn, ~p"/")
      view |> element("form[phx-submit=create_character]") |> render_submit(%{"name" => "Lowbie"})
      assert Pokex.Settings.get(:active_character) == "lowbie"
    end
  end

  describe "stop reason" do
    # with the bot stopped, the screen answers who stopped it, why, and how long
    # ago — no log archaeology
    test "a Stop with a reason appears under the Start button", %{conn: conn} do
      Session.order(:stop, "teste: o Guardian bateu a meta")

      {:ok, view, _html} = live(conn, ~p"/")

      assert view |> element("#last-order") |> render() =~ "teste: o Guardian bateu a meta"
      assert view |> element("#last-order") |> render() =~ "parado"
    end

    test "a focus hold says it resumes on its own", %{conn: conn} do
      Session.order(:hold, "foco perdido")

      {:ok, view, _html} = live(conn, ~p"/")

      assert view |> element("#last-order") |> render() =~ "retoma sozinho ao voltar"
    end

    test "the panel's Stop button records its own reason", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "stop")

      assert %{kind: :stop, reason: "Parar (painel)"} = Session.last_order()
      assert view |> element("#last-order") |> render() =~ "Parar (painel)"
    end

    test "with the fleet active the line disappears — a stop reason is for stopped bots", %{
      conn: conn
    } do
      Session.order(:stop, "teste: some quando roda")
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#last-order")

      Phoenix.PubSub.broadcast(
        Pokex.PubSub,
        "fishing",
        {:fishing, %{state: :fishing, counters: %{}, error: nil}}
      )

      refute eventually_has(view, "#last-order")
    end

    defp eventually_has(view, selector, tries \\ 30) do
      if has_element?(view, selector) and tries > 0 do
        Process.sleep(10)
        eventually_has(view, selector, tries - 1)
      else
        has_element?(view, selector)
      end
    end
  end

  describe "auto-revive with a stun combo" do
    setup do
      tmp =
        Path.join(System.tmp_dir!(), "pokex-panel-resgate-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      Application.put_env(:pokex, :home_dir, tmp)
      Pokex.SettingsStash.stash_keys!([:rescue_mode, :rescue_combo])

      on_exit(fn ->
        Pokex.TestHome.restore()
        File.rm_rf!(tmp)
        Enum.each([:team, :layout], &WorldState.forget/1)
      end)

      Store.put([
        %Pokex.Combos.Combo{
          name: "stun-area",
          trigger: nil,
          steps: [{:skill, "1"}, {:wait, 500}, {:skill, "2"}],
          enabled?: true
        },
        %Pokex.Combos.Combo{
          name: "com-troca",
          trigger: nil,
          steps: [{:swap_member, "Jigglypuff"}, {:skill, "4"}],
          enabled?: true
        }
      ])

      :ok
    end

    test "combo mode: dropdown, sequence preview and the conflict warning", %{conn: conn} do
      Pokex.Settings.put(:rescue_mode, "combo")
      Pokex.Settings.put(:rescue_combo, "stun-area")

      {:ok, view, _html} = live(conn, ~p"/config")

      assert has_element?(view, "#rescue-mode")
      assert has_element?(view, "#rescue-combo")

      assert has_element?(view, ~s([data-testid="rescue-combo-preview"]))
      assert render(view) =~ "1 → 500ms → 2"

      assert has_element?(view, ~s([data-testid="rescue-combo-conflict"]))

      assert has_element?(view, ~s(#rescue-combo option[disabled]))
    end

    test "in direct mode the dropdown and the preview do not even exist", %{conn: conn} do
      Pokex.Settings.put(:rescue_mode, "direct")

      {:ok, view, _html} = live(conn, ~p"/config")

      assert has_element?(view, "#rescue-mode")
      refute has_element?(view, "#rescue-combo")
      refute has_element?(view, ~s([data-testid="rescue-combo-preview"]))
    end

    # real field state: mode "combo" with an empty rescue_combo — the skills
    # looked reserved but the revive went direct
    test "combo mode without a valid combo warns — and the button configures everything in one click",
         %{conn: conn} do
      Pokex.Settings.put(:rescue_mode, "combo")
      Pokex.Settings.put(:rescue_combo, "")

      {:ok, view, _html} = live(conn, ~p"/config")

      assert has_element?(view, ~s([data-testid="rescue-combo-missing"]))

      view |> element("#create-rescue-combo") |> render_click()

      assert %Pokex.Combos.Combo{steps: steps, trigger: {:rescue_only}} =
               Enum.find(Store.all(), &(&1.name == "resgate"))

      assert [{:skill, "1"}, {:wait, _}, {:skill, "2"}] = steps

      assert Pokex.Settings.get(:rescue_combo) == "resgate"
      assert Pokex.Settings.get(:rescue_mode) == "combo"
      refute has_element?(view, ~s([data-testid="rescue-combo-missing"]))
      assert has_element?(view, ~s([data-testid="combo-rescue-badge"]))
    end
  end

  describe "combo editor" do
    setup do
      tmp =
        Path.join(System.tmp_dir!(), "pokex-panel-editor-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      Application.put_env(:pokex, :home_dir, tmp)

      on_exit(fn ->
        Pokex.TestHome.restore()
        File.rm_rf!(tmp)
        Enum.each([:team, :layout], &WorldState.forget/1)
      end)

      :ok
    end

    # the fields had no server-side value and the panel re-renders on every
    # snapshot (~10x/s) — everything typed vanished on blur; this test IS that bug
    test "typed input survives the workers' re-renders", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/config")

      view |> element("#combo-form") |> render_change(%{"name" => "resgate"})
      assert has_element?(view, ~s(#combo-name[value="resgate"]))

      Phoenix.PubSub.broadcast(
        Pokex.PubSub,
        "fishing",
        {:fishing, %{state: :fishing, counters: %{}, error: nil}}
      )

      assert has_element?(view, ~s(#combo-name[value="resgate"]))
    end

    test "builds the free sequence skill 1 → wait → skill 2", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/config")

      view
      |> element("#combo-form")
      |> render_change(%{"name" => "stun", "trigger_kind" => "rescue_only"})

      add_step(view, "skill", "1")
      add_step(view, "wait", "500")
      add_step(view, "skill", "2")

      view |> element("#combo-form") |> render_submit(%{})

      assert %Pokex.Combos.Combo{trigger: {:rescue_only}, steps: steps} =
               Enum.find(Store.all(), &(&1.name == "stun"))

      assert steps == [{:skill, "1"}, {:wait, 500}, {:skill, "2"}]

      assert has_element?(view, ~s(#combo-name[value=""]))
    end

    test "a step can be removed before saving", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/config")

      add_step(view, "skill", "9")
      assert render(view) =~ "skill 9"

      view |> element(~s([phx-click="remove_combo_step"][phx-value-index="0"])) |> render_click()
      refute render(view) =~ "skill 9"
    end

    test "an invalid step (skill without a key, wait without a number) does not enter", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/config")

      add_step(view, "skill", "")
      add_step(view, "wait", "logo ali")

      assert render(view) =~ "Sem passos ainda"
    end

    test "a combo with no steps is not saved", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/config")

      view |> element("#combo-form") |> render_change(%{"name" => "vazio"})
      view |> element("#combo-form") |> render_submit(%{})

      refute Enum.any?(Store.all(), &(&1.name == "vazio"))
    end

    defp add_step(view, kind, value) do
      view
      |> element("#combo-form")
      |> render_change(%{"step_kind" => kind, "step_value" => value})

      view |> element("#combo-add-step") |> render_click()
    end
  end

  describe "logout" do
    setup do
      on_exit(fn ->
        Pokex.Settings.put(:stagnation_action, "alarm")
        Pokex.Settings.put(:stop_after_action, "stop")
      end)

      :ok
    end

    # the global Logout is inert in the suite — the click must survive that
    test "the 'Deslogar agora' button exists and clicking it does not crash the page", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/config")

      assert has_element?(view, ~s(button[phx-click="logout_now"]))

      render_click(view, "logout_now")
      assert render(view) =~ "Deslogar agora"
    end

    test "the panel shows the logout outcome, and a strange message does not crash it", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/config")

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

      send(
        view.pid,
        {:logout,
         %{
           state: :failed,
           reason: "estagnação",
           attempt: 3,
           attempts: 3,
           error: :still_logged_in,
           finished_at: 2,
           duplicates: 0
         }}
      )

      assert render(view) =~ "FALHOU (ainda_logado)"

      send(view.pid, {:unexpected_message, 42})
      assert render(view) =~ "Deslogar agora"
    end

    test "both action selectors offer deslogar", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/config")

      assert has_element?(view, ~s(select#stagnation-action option[value="logout"]))
      assert has_element?(view, ~s(select#stop-after-action option[value="logout"]))
    end

    test "choosing deslogar in both selectors persists the setting", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/config")

      view
      |> element("#stagnation-form")
      |> render_change(%{"stagnation_minutes" => "5", "stagnation_action" => "logout"})

      assert Pokex.Settings.get(:stagnation_action) == "logout"

      view
      |> element("#stop-conditions-form")
      |> render_change(%{
        "stop_minutes" => "0",
        "stop_kills" => "0",
        "stop_after_action" => "logout"
      })

      assert Pokex.Settings.get(:stop_after_action) == "logout"
    end
  end
end
