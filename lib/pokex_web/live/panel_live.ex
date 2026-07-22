defmodule PokexWeb.PanelLive do
  use PokexWeb, :live_view

  alias Pokex.Bots.{BotSupervisor, Catcher, Combat, Fishing, PlayerSupport, SkillBar}
  alias Pokex.Diagnostics.Report
  alias PokexWeb.PanelForms
  alias Pokex.{Calibration, Rig, Settings}

  @fishing_topic "fishing"
  @combat_topic "combat"
  @catcher_topic "catcher"
  @mini_game_topic "mini_game"
  @game_topic "game"
  @body_topic "body"
  @focus_topic "focus"
  @cooldown_poll_ms 1000

  @counters [
    {"Ciclos", :cycles, "hero-arrow-path"},
    {"Fisgadas", :hooked, "hero-sparkles"},
    {"Lutas", :fights, "hero-bolt"},
    {"Capturas", :captures, "hero-check-badge"}
  ]

  @idle_fishing %{state: :idle, counters: %{}, error: nil}
  @idle_combat %{state: :idle, counters: %{}, error: nil, locked_row: nil}

  # Combat timing knobs Lucas tunes live to speed up search + kills. Config is
  # built once at Start/Testar, so these apply on the NEXT run (noted in the UI).
  @timing_fields [
    {:combat_skill_burst_size, "Skills por leitura",
     "quantas teclas de skill ele engatilha antes de olhar a luta de novo"},
    {:combat_skill_tap_count, "Toques por skill",
     "quantas vezes repetir cada tecla dentro da rajada"},
    {:combat_skill_gap_ms, "Intervalo entre skills (ms)",
     "pausa base entre teclas da rajada; 0 = sem pausa fixa"},
    {:combat_skill_jitter_ms, "Variação aleatória pós-skill (ms)",
     "sorteia +0..N ms depois de cada skill; 20 = intervalo base + 0 a 20ms"},
    {:target_lost_streak, "Confirmações de morte",
     "quantas leituras sem inimigo até considerar o alvo morto"},
    {:fight_timeout_ms, "Timeout de alvo (ms)", "desiste de um alvo que não morre nesse tempo"}
  ]

  @positive_timing_keys [:combat_skill_burst_size, :combat_skill_tap_count]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Pokex.PubSub, @fishing_topic)
      Phoenix.PubSub.subscribe(Pokex.PubSub, @combat_topic)
      Phoenix.PubSub.subscribe(Pokex.PubSub, @catcher_topic)
      Phoenix.PubSub.subscribe(Pokex.PubSub, @mini_game_topic)
      Phoenix.PubSub.subscribe(Pokex.PubSub, @game_topic)
      Phoenix.PubSub.subscribe(Pokex.PubSub, @body_topic)
      Phoenix.PubSub.subscribe(Pokex.PubSub, @focus_topic)
      Phoenix.PubSub.subscribe(Pokex.PubSub, "shiny")
      Phoenix.PubSub.subscribe(Pokex.PubSub, Pokex.Layout.Sentinel.topic())
      Phoenix.PubSub.subscribe(Pokex.PubSub, Pokex.Bots.StockAlerts.topic())
      # Keep the cooldown display LIVE while the fishing gate is on, so it never goes stale —
      # you can watch the reading flip to ready the instant your skills come off cooldown (the
      # SAME SkillBar read the fishing gate uses each tick).
      Process.send_after(self(), :refresh_cooldowns, @cooldown_poll_ms)
    end

    status = BotSupervisor.status()

    {:ok,
     assign(socket,
       page_title: "Painel",
       fishing: status.fishing,
       combat: status.combat,
       catcher: status.catcher,
       mini_game: status.mini_game,
       game: status.player_support,
       errors: [],
       calibrated?: Calibration.exists?(),
       calib_stale?: calib_stale?(),
       layout_lost?: false,
       stocks: %{},
       now_ms: now_ms(),
       threshold: Settings.get(:glow_threshold),
       mini_game_sound: Settings.get(:mini_game_sound),
       alarm_sound: Settings.get(:alarm_sound),
       alarm_last: %{},
       session_started_at: session_started_at(),
       stop_after_minutes: Settings.get(:stop_after_minutes),
       stop_after_kills: Settings.get(:stop_after_kills),
       stagnation_minutes: Settings.get(:stagnation_minutes),
       stagnation_action: Settings.get(:stagnation_action),
       escape_direction: Settings.get(:escape_direction),
       escape_steps: Settings.get(:escape_steps),
       escape_walk_wait_ms: Settings.get(:escape_walk_wait_ms),
       player_mode: Settings.get(:player_mode),
       skill_order: Enum.join(Settings.get(:skill_keys), " "),
       loot_enabled: Settings.get(:loot_enabled),
       capture_enabled: Settings.get(:capture_enabled),
       panicked?: false,
       focused?: initial_focus(),
       logs: [],
       show_debug: false,
       feed_filter: nil,
       export_src: nil,
       export_msg: nil,
       capture_src: nil,
       capture_label: nil,
       report: nil,
       report_src: nil,
       report_msg: nil,
       timing: timing_settings(),
       cooldowns_states: nil,
       capture_info: nil,
       require_cooldowns: Settings.get(:require_cooldowns),
       require_pokemon_hp: Settings.get(:require_pokemon_hp),
       fishing_hp_pct: Settings.get(:pokemon_hp_fishing_pct),
       rescue_enabled: Settings.get(:rescue_enabled),
       rescue_pct: Settings.get(:pokemon_hp_rescue_pct),
       rescue_cooldown_s: div(Settings.get(:rescue_cooldown_ms), 1000),
       potion_enabled: Settings.get(:potion_enabled),
       reposition_enabled: Settings.get(:reposition_enabled),
       support_waits_capture: Settings.get(:support_waits_capture),
       shiny_guard_enabled: Settings.get(:shiny_guard_enabled),
       shiny_action: Settings.get(:shiny_action),
       shiny_msg: nil,
       shiny_star_px: nil,
       shiny_star_min_px: Settings.get(:shiny_star_min_px),
       shiny_log: Pokex.Pokedex.ShinyLog.entries(),
       potion_pct: Settings.get(:pokemon_hp_potion_pct),
       potion_cooldown_s: div(Settings.get(:potion_cooldown_ms), 1000),
       hook_skills: Enum.join(Settings.get(:hook_skill_keys), " "),
       presets: Settings.list_presets(),
       preset_msg: nil
     )}
  end

  defp start_bots(socket) do
    case BotSupervisor.start_all() do
      :ok ->
        status = BotSupervisor.status()

        assign(socket,
          errors: [],
          logs: [],
          panicked?: false,
          calib_stale?: calib_stale?(),
          session_started_at: session_started_at(),
          fishing: status.fishing,
          combat: status.combat,
          catcher: status.catcher,
          mini_game: status.mini_game,
          game: status.player_support
        )

      {:error, messages} ->
        assign(socket, errors: messages, calib_stale?: calib_stale?())
    end
  end

  # The Settings-derived assigns a preset can change — re-read after apply_preset
  # so every toggle/field on screen matches what was just applied.
  defp refresh_setting_assigns(socket) do
    assign(socket,
      skill_order: Enum.join(Settings.get(:skill_keys), " "),
      hook_skills: Enum.join(Settings.get(:hook_skill_keys), " "),
      loot_enabled: Settings.get(:loot_enabled),
      capture_enabled: Settings.get(:capture_enabled),
      require_cooldowns: Settings.get(:require_cooldowns),
      require_pokemon_hp: Settings.get(:require_pokemon_hp),
      fishing_hp_pct: Settings.get(:pokemon_hp_fishing_pct),
      rescue_enabled: Settings.get(:rescue_enabled),
      rescue_pct: Settings.get(:pokemon_hp_rescue_pct),
      potion_enabled: Settings.get(:potion_enabled),
      potion_pct: Settings.get(:pokemon_hp_potion_pct),
      reposition_enabled: Settings.get(:reposition_enabled),
      support_waits_capture: Settings.get(:support_waits_capture),
      presets: Settings.list_presets()
    )
  end

  # The workers load the calibration at Start; edits after that (a quick fix, an
  # applied profile) do NOTHING until Parar/Iniciar — a trap that already cost two
  # live test sessions. Compare the file's mtime with the one stamped at the last
  # start: different = the bots are flying an old calibration.
  defp calib_stale? do
    now = System.monotonic_time(:millisecond)

    case Pokex.Perception.WorldState.get(:calibration, 4_000_000_000, now) do
      {:ok, %{loaded_mtime: loaded}} -> loaded != Calibration.mtime()
      _not_started -> false
    end
  end

  defp timing_settings do
    Map.new(@timing_fields, fn {key, _label, _hint} -> {key, Settings.get(key)} end)
  end

  # The Focus poller may not have published yet at mount; ask it directly (fail-open to focused
  # so the pause banner never shows spuriously when the feature is off / the poller is absent).
  defp initial_focus do
    Pokex.Bots.Focus.status().focused?
  catch
    _kind, _reason -> true
  end

  defp hp_pct(%{hp_pct: pct}) when is_integer(pct), do: pct
  defp hp_pct(_game), do: nil

  defp hp_label(game) do
    case hp_pct(game) do
      nil -> "—"
      pct -> "#{pct}%"
    end
  end

  defp hp_bar_style(game) do
    pct = hp_pct(game) || 0

    color =
      cond do
        pct > 50 -> "#22c55e"
        pct > 25 -> "#eab308"
        true -> "#ef4444"
      end

    "width: #{pct}%; background-color: #{color};"
  end

  @impl true
  def handle_info({:fishing, snapshot}, socket),
    do:
      {:noreply,
       socket |> alarm_on_error(:fishing, snapshot) |> assign(fishing: snapshot, panicked?: false)}

  def handle_info({:combat, snapshot}, socket),
    do:
      {:noreply,
       socket |> alarm_on_error(:combat, snapshot) |> assign(combat: snapshot, panicked?: false)}

  def handle_info({:catcher, snapshot}, socket),
    do: {:noreply, socket |> alarm_on_error(:catcher, snapshot) |> assign(catcher: snapshot)}

  def handle_info({:mini_game, snapshot}, socket) do
    socket = socket |> alarm_on_error(:mini_game, snapshot) |> assign(mini_game: snapshot)

    socket =
      case Map.get(snapshot, :transition) do
        # Muted = no event at all, so the mute silences every open panel tab.
        transition when transition in [:entered, :left] ->
          if Settings.get(:mini_game_sound) do
            push_event(socket, "mini-game-transition", %{
              transition: transition,
              state: snapshot.state
            })
          else
            socket
          end

        _ ->
          socket
      end

    {:noreply, socket}
  end

  # Live cooldown poll: re-read the skill bar WHILE the fishing gate is on, so the display
  # tracks the reading the gate uses every tick (never stale). Off → skip the capture but keep
  # the timer alive so it resumes the moment the gate is turned on. Always reschedule.
  def handle_info(:refresh_cooldowns, socket) do
    socket =
      if socket.assigns.require_cooldowns,
        do: assign(socket, cooldowns_states: read_cooldown_states()),
        else: socket

    Process.send_after(self(), :refresh_cooldowns, @cooldown_poll_ms)
    # now_ms anchors the "há Xs" ages of the pills' last actions AND the session
    # clock — the same 1s cadence keeps both ticking without any extra timer.
    {:noreply,
     assign(socket,
       calib_stale?: calib_stale?(),
       now_ms: now_ms(),
       session_started_at: session_started_at()
     )}
  end

  def handle_info({:fishing_log, level, text}, socket),
    do: {:noreply, append_log(socket, %{level: level, source: "🎣", text: text})}

  def handle_info({:combat_log, level, text}, socket),
    do: {:noreply, append_log(socket, %{level: level, source: "⚔️", text: text})}

  def handle_info({:mini_game_log, level, text}, socket),
    do: {:noreply, append_log(socket, %{level: level, source: "🎮", text: text})}

  def handle_info({:catcher_log, level, text}, socket),
    do: {:noreply, append_log(socket, %{level: level, source: "🎯", text: text})}

  def handle_info({:game, snapshot}, socket) do
    socket =
      socket
      |> alarm_on_error(:game, snapshot)
      |> alarm_on_critical_hp(snapshot)
      |> assign(game: snapshot)

    {:noreply, socket}
  end

  # The emergency-escape protocol ran (BotSupervisor.emergency_escape): the
  # fleet is halting (workers broadcast their own idle snapshots) — report
  # WHAT happened to the flee click alongside the trigger.
  def handle_info({:escape, reason, flee}, socket) do
    note =
      case flee do
        :ok -> "clique na escada executado"
        {:error, :not_calibrated} -> "SEM escada calibrada — só parou tudo"
        {:error, other} -> "clique falhou (#{inspect(other)}) — só parou tudo"
      end

    socket =
      socket
      |> alarm(:escape, "🏃 FUGA: #{reason} — #{note}")
      |> assign(session_started_at: nil)

    {:noreply, socket}
  end

  # The ShinyGuard's live star reading (throttled) — feeds the meter.
  def handle_info({:shiny_reading, %{star_px: px, min_px: min_px}}, socket),
    do: {:noreply, assign(socket, shiny_star_px: px, shiny_star_min_px: min_px)}

  # A confirmed sighting: refresh the trophy shelf so the encounter shows up.
  def handle_info({:shiny_seen, _info}, socket),
    do: {:noreply, assign(socket, shiny_log: Pokex.Pokedex.ShinyLog.entries())}

  def handle_info({:focus, %{focused?: focused?}}, socket),
    do: {:noreply, assign(socket, focused?: focused?)}

  def handle_info({:game_log, level, text}, socket),
    do: {:noreply, append_log(socket, %{level: level, source: "🚑", text: text})}

  def handle_info({:body_log, level, text}, socket),
    do: {:noreply, append_log(socket, %{level: level, source: "🧤", text: text})}

  # Backward-compat: a worker still running an OLD build (mid hot-reload) may
  # broadcast the pre-level 2-tuple form. Treat it as debug so the panel never
  # crashes on the stale shape.
  def handle_info({:fishing_log, text}, socket),
    do: {:noreply, append_log(socket, %{level: :debug, source: "🎣", text: text})}

  def handle_info({:combat_log, text}, socket),
    do: {:noreply, append_log(socket, %{level: :debug, source: "⚔️", text: text})}

  # The Guardian re-broadcasts {:panic} on EVERY poll tick (~10x/sec) while
  # the cursor stays in the kill corner — a human parked there wants the bot
  # to STAY stopped, so this must stay idempotent: only the first panic (the
  # transition) idles the pills and logs; repeats are a safe, silent no-op so
  # the feed doesn't fill up with duplicate spam.
  # A rule fired with the ALARM action (Guardian, e.g. anti-stagnation): ring
  # the F7 pipeline — nothing was halted, the sound + 🔔 line ARE the action.
  # The HUD could not be located: every feed is holding rather than reading
  # (or clicking) blind coordinates — say so loudly and permanently.
  def handle_info({:layout, %{ok?: ok?}}, socket),
    do: {:noreply, assign(socket, layout_lost?: not ok?)}

  def handle_info({:layout_suspect, _key}, socket), do: {:noreply, socket}

  # A slot's stock crossed its threshold — the badge stays until he restocks.
  def handle_info({:stock, %{slot: slot} = reading}, socket),
    do: {:noreply, assign(socket, stocks: Map.put(socket.assigns.stocks, slot, reading))}

  def handle_info({:rule_alarm, reason}, socket),
    do: {:noreply, alarm(socket, :rule_alarm, "⏰ #{reason}")}

  # A stop condition fired (Guardian): the fleet is already halting (workers
  # broadcast their own idle snapshots) — ring the alarm with the MET GOAL and
  # drop the session clock. Not a panic: no red banner, just the record.
  def handle_info({:session_stop, reason}, socket) do
    socket =
      socket
      |> alarm(:session_stop, "🛑 caçada parada: #{reason}")
      |> assign(session_started_at: nil)

    {:noreply, socket}
  end

  def handle_info({:panic, _reason}, %{assigns: %{panicked?: true}} = socket),
    do: {:noreply, socket}

  def handle_info({:panic, _reason}, socket) do
    socket =
      socket
      |> assign(fishing: @idle_fishing, combat: @idle_combat, panicked?: true)
      |> append_log(%{level: :macro, source: "🛑", text: "pânico: mouse no canto — tudo parado"})

    {:noreply, socket}
  end

  # Each log entry is a map {level, source, text, at}; the feed keeps the last
  # 200 (newest first) so it stays light, and macro vs debug lets the UI hide
  # the per-tick chatter by default. `at` is local (Mac) wall-clock HH:MM:SS.
  defp append_log(socket, entry) do
    entry = Map.put(entry, :at, timestamp())
    assign(socket, logs: Enum.take([entry | socket.assigns.logs], 200))
  end

  defp timestamp do
    {_, {h, m, s}} = :calendar.local_time()
    :io_lib.format(~c"~2..0B:~2..0B:~2..0B", [h, m, s]) |> List.to_string()
  end

  @impl true
  def handle_event("start", _params, socket), do: {:noreply, start_bots(socket)}

  # The stale-calibration banner's one-click fix: full stop + fresh start, so the
  # workers reload whatever is on disk (quick fixes, an applied profile).
  def handle_event("restart_bots", _params, socket) do
    BotSupervisor.stop_all()
    {:noreply, start_bots(socket)}
  end

  def handle_event("stop", _params, socket) do
    BotSupervisor.stop_all()
    status = BotSupervisor.status()

    {:noreply,
     assign(socket,
       calib_stale?: false,
       fishing: status.fishing,
       combat: status.combat,
       catcher: status.catcher,
       mini_game: status.mini_game,
       game: status.player_support
     )}
  end

  def handle_event("toggle_mini_game_sound", _params, socket) do
    next = not Settings.get(:mini_game_sound)
    Settings.put(:mini_game_sound, next)
    {:noreply, assign(socket, mini_game_sound: next)}
  end

  def handle_event("toggle_alarm_sound", _params, socket) do
    next = not Settings.get(:alarm_sound)
    Settings.put(:alarm_sound, next)
    {:noreply, assign(socket, alarm_sound: next)}
  end

  def handle_event("save_stop_conditions", params, socket) do
    socket =
      socket
      |> save_int(params["stop_minutes"], 0..999, :stop_after_minutes, :stop_after_minutes)
      |> save_int(params["stop_kills"], 0..9999, :stop_after_kills, :stop_after_kills)

    {:noreply, socket}
  end

  def handle_event("save_stagnation", params, socket) do
    socket =
      save_int(
        socket,
        params["stagnation_minutes"],
        0..999,
        :stagnation_minutes,
        :stagnation_minutes
      )

    socket =
      case params["stagnation_action"] do
        action when action in ["alarme", "parar"] ->
          Settings.put(:stagnation_action, action)
          assign(socket, stagnation_action: action)

        _invalid ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("toggle_fishing", _params, socket),
    do: toggle_worker(socket, :fishing, Fishing.Worker)

  def handle_event("toggle_combat", _params, socket),
    do: toggle_worker(socket, :combat, Combat.Worker)

  def handle_event("set_player_mode", %{"mode" => mode}, socket)
      when mode in ~w(parado movimento) do
    Settings.put(:player_mode, mode)
    Catcher.Worker.mode_changed()
    {:noreply, assign(socket, player_mode: mode)}
  end

  def handle_event("toggle_loot_enabled", _params, socket) do
    value = not Settings.get(:loot_enabled)
    Settings.put(:loot_enabled, value)
    {:noreply, assign(socket, loot_enabled: value)}
  end

  def handle_event("toggle_capture_enabled", _params, socket) do
    value = not Settings.get(:capture_enabled)
    Settings.put(:capture_enabled, value)
    Catcher.Worker.mode_changed()
    {:noreply, assign(socket, capture_enabled: value)}
  end

  def handle_event("relearn_ground", _params, socket) do
    Catcher.Worker.relearn()
    {:noreply, socket}
  end

  def handle_event("save_threshold", %{"threshold" => raw}, socket) do
    value =
      case Float.parse(raw) do
        {parsed, _rest} -> parsed
        :error -> nil
      end

    Settings.put(:glow_threshold, value)
    {:noreply, assign(socket, threshold: value)}
  end

  def handle_event("save_skills", %{"skills" => raw}, socket) do
    # Priority order, strongest first. The attack loop cycles these in order; a
    # skill on cooldown is a harmless no-op in the game, so the ready ones fire.
    keys = PanelForms.parse_skill_keys(raw)
    keys = if keys == [], do: Settings.get(:skill_keys), else: keys
    Settings.put(:skill_keys, keys)
    {:noreply, assign(socket, skill_order: Enum.join(keys, " "))}
  end

  # Persist the combat timing knobs; blanks/invalid keep the current value. They
  # apply on the next Start/Testar (config is frozen at run start).
  def handle_event("save_timing", params, socket) do
    timing =
      Enum.reduce(@timing_fields, socket.assigns.timing, fn {key, _label, _hint}, acc ->
        case PanelForms.parse_timing(key, params[to_string(key)], @positive_timing_keys) do
          {:ok, n} ->
            Settings.put(key, n)
            Map.put(acc, key, n)

          :error ->
            acc
        end
      end)

    {:noreply, assign(socket, timing: timing)}
  end

  def handle_event("toggle_require_cooldowns", _params, socket) do
    value = not Settings.get(:require_cooldowns)
    Settings.put(:require_cooldowns, value)
    {:noreply, assign(socket, require_cooldowns: value)}
  end

  def handle_event("toggle_require_pokemon_hp", _params, socket) do
    value = not Settings.get(:require_pokemon_hp)
    Settings.put(:require_pokemon_hp, value)
    # the gate reads the :pokemon fact the support monitor publishes — make sure it's ticking
    if value, do: arm_support()
    {:noreply, assign(socket, require_pokemon_hp: value)}
  end

  def handle_event("save_fishing_hp_cfg", params, socket) do
    {:noreply,
     save_int(socket, params["fishing_hp_pct"], 1..90, :pokemon_hp_fishing_pct, :fishing_hp_pct)}
  end

  def handle_event("save_preset", %{"name" => name}, socket) do
    case Settings.save_preset(name) do
      {:ok, slug} ->
        {:noreply,
         assign(socket, presets: Settings.list_presets(), preset_msg: "Preset \"#{slug}\" salvo")}

      {:error, :invalid_name} ->
        {:noreply, assign(socket, preset_msg: "Nome inválido — use letras/números")}
    end
  end

  def handle_event("apply_preset", %{"slug" => slug}, socket) do
    case Settings.apply_preset(slug) do
      {:ok, %{applied: applied}} ->
        # same side effect as the individual toggles: a support gate the preset
        # turned on needs the monitor ticking
        support_keys = [
          :require_pokemon_hp,
          :rescue_enabled,
          :potion_enabled,
          :reposition_enabled
        ]

        if Enum.any?(support_keys, &Settings.get/1), do: arm_support()

        {:noreply,
         socket
         |> refresh_setting_assigns()
         |> assign(
           preset_msg:
             "Preset \"#{slug}\" aplicado (#{applied} ajustes) — bots rodando pegam as skills no próximo Parar e Iniciar"
         )}

      {:error, _not_found_or_corrupt} ->
        {:noreply, assign(socket, preset_msg: "Preset \"#{slug}\" ilegível ou inexistente")}
    end
  end

  def handle_event("delete_preset", %{"slug" => slug}, socket) do
    Settings.delete_preset(slug)

    {:noreply,
     assign(socket, presets: Settings.list_presets(), preset_msg: "Preset \"#{slug}\" excluído")}
  end

  def handle_event("toggle_rescue", _params, socket) do
    value = not Settings.get(:rescue_enabled)
    Settings.put(:rescue_enabled, value)
    if value, do: arm_support()
    {:noreply, assign(socket, rescue_enabled: value)}
  end

  # Threshold + cooldown are expensive to get wrong in BOTH directions: a too-eager rescue burns
  # revives on scratches, a too-slow one revives a corpse. The form sends both fields on every
  # change; each is validated on its own range and an invalid value simply leaves that setting
  # untouched (the other still saves).
  def handle_event("save_rescue_cfg", params, socket) do
    socket =
      socket
      |> save_int(params["rescue_pct"], 1..90, :pokemon_hp_rescue_pct, :rescue_pct)
      |> save_seconds(
        params["rescue_cooldown_s"],
        2..600,
        :rescue_cooldown_ms,
        :rescue_cooldown_s
      )

    {:noreply, socket}
  end

  def handle_event("toggle_potion", _params, socket) do
    value = not Settings.get(:potion_enabled)
    Settings.put(:potion_enabled, value)
    if value, do: arm_support()
    {:noreply, assign(socket, potion_enabled: value)}
  end

  def handle_event("toggle_reposition", _params, socket) do
    value = not Settings.get(:reposition_enabled)
    Settings.put(:reposition_enabled, value)
    if value, do: arm_support()
    {:noreply, assign(socket, reposition_enabled: value)}
  end

  def handle_event("toggle_support_waits_capture", _params, socket) do
    value = not Settings.get(:support_waits_capture)
    Settings.put(:support_waits_capture, value)
    {:noreply, assign(socket, support_waits_capture: value)}
  end

  def handle_event("toggle_shiny_guard", _params, socket) do
    value = not Settings.get(:shiny_guard_enabled)
    Settings.put(:shiny_guard_enabled, value)
    {:noreply, assign(socket, shiny_guard_enabled: value)}
  end

  def handle_event("save_shiny_cfg", params, socket) do
    socket =
      case params["shiny_action"] do
        action when action in ["fugir", "alarme"] ->
          Settings.put(:shiny_action, action)
          assign(socket, shiny_action: action)

        _invalid ->
          socket
      end

    {:noreply, socket}
  end

  # The shiny PROBE: capture the battle list NOW and show the star score of
  # every row — the tuning tool. A list with no shiny reads 0 everywhere; the
  # measured star lands at 15+.
  def handle_event("shiny_probe", _params, socket) do
    {msg, px} =
      with {:ok, calib} <- Calibration.load(),
           {:ok, frame} <- Pokex.Bots.Capture.frame(calib.battle_region, "shiny_probe.png") do
        settings = Settings.all()
        {top, band} = Calibration.row_band_geometry(calib.scale, settings[:battle_row_height])
        rows = settings[:battle_max_rows]
        strip = round(Calibration.strip_width() * calib.scale)
        body = Pokex.Vision.Frame.crop(frame, {0, 0, frame.width - strip, frame.height})

        clusters = Pokex.Vision.star_row_clusters(body, top: top, band: band, rows: rows)
        best = Enum.max(clusters, fn -> 0 end)

        {"sonda: estrela por linha " <>
           Enum.map_join(Enum.with_index(clusters), " · ", fn {px, i} -> "L#{i}: #{px}px" end) <>
           " (limiar #{settings[:shiny_star_min_px]}px)", best}
      else
        error -> {"sonda falhou: #{inspect(error)}", nil}
      end

    {:noreply, assign(socket, shiny_msg: msg, shiny_star_px: px)}
  end

  def handle_event("shiny_log_clear", _params, socket) do
    Pokex.Pokedex.ShinyLog.clear()
    {:noreply, assign(socket, shiny_log: [], shiny_msg: "registro de shinies limpo")}
  end

  # The escape SIMULATION (the aceite's "simulação"): runs the REAL protocol —
  # real click, real walk, real halt, real alarm — behind the button's
  # data-confirm. The {:escape, ...} broadcast coming back updates this panel.
  def handle_event("test_escape", _params, socket) do
    BotSupervisor.emergency_escape("teste manual")
    {:noreply, socket}
  end

  def handle_event("save_escape_cfg", params, socket) do
    socket =
      socket
      |> save_int(params["escape_steps"], 1..10, :escape_steps, :escape_steps)
      |> save_int(
        params["escape_walk_wait_ms"],
        0..10_000,
        :escape_walk_wait_ms,
        :escape_walk_wait_ms
      )

    socket =
      case params["escape_direction"] do
        direction when direction in ["left", "right", "up", "down"] ->
          Settings.put(:escape_direction, direction)
          assign(socket, escape_direction: direction)

        _invalid ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("save_potion_cfg", params, socket) do
    socket =
      socket
      |> save_int(params["potion_pct"], 1..99, :pokemon_hp_potion_pct, :potion_pct)
      |> save_seconds(
        params["potion_cooldown_s"],
        1..600,
        :potion_cooldown_ms,
        :potion_cooldown_s
      )

    {:noreply, socket}
  end

  def handle_event("use_potion", _params, socket) do
    PlayerSupport.Worker.use_potion()
    {:noreply, socket}
  end

  # One-shot skill-bar read for the display (no loop, no shared process).
  def handle_event("read_cooldowns", _params, socket) do
    {:noreply, assign(socket, cooldowns_states: read_cooldown_states())}
  end

  # On-demand capture diagnostics: backend + last-window timings. A button, not a timer —
  # metrics are for humans debugging, they must not add render churn to the hot panel.
  def handle_event("read_capture_stats", _params, socket) do
    snapshot = Pokex.Bots.Perf.snapshot()

    window =
      if map_size(snapshot.last_window) > 0, do: snapshot.last_window, else: snapshot.current

    stats =
      window
      |> Enum.filter(fn {key, _v} -> String.starts_with?(key, "capture.backend.") end)
      |> Enum.sort_by(fn {key, _v} -> key end)

    info = %{backend: Pokex.Bots.Capture.backend_info(), stats: stats}
    {:noreply, assign(socket, capture_info: info)}
  end

  def handle_event("save_hook_skills", %{"hook_skills" => raw}, socket) do
    keys = PanelForms.parse_skill_keys(raw)
    keys = if keys == [], do: Settings.get(:hook_skill_keys), else: keys
    Settings.put(:hook_skill_keys, keys)
    {:noreply, assign(socket, hook_skills: Enum.join(keys, " "))}
  end

  # One chip per worker: click isolates that worker's lines, click again clears.
  def handle_event("filter_feed", %{"source" => source}, socket) do
    next = if socket.assigns.feed_filter == source, do: nil, else: source
    {:noreply, assign(socket, feed_filter: next)}
  end

  def handle_event("toggle_debug", _params, socket),
    do: {:noreply, assign(socket, show_debug: not socket.assigns.show_debug)}

  def handle_event("clear_logs", _params, socket),
    do: {:noreply, assign(socket, logs: [], export_src: nil, export_msg: nil)}

  # Dump the current feed (oldest→newest) to ~/.pokex/exports/events-<ms>.log so
  # Lucas can hand Claude the last events without screenshotting the panel.
  def handle_event("export_events", _params, socket) do
    logs = socket.assigns.logs

    case export_events(logs) do
      {:ok, name} ->
        {:noreply,
         assign(socket,
           export_src: "/exports/#{name}",
           export_msg: "#{length(logs)} eventos exportados"
         )}

      {:error, reason} ->
        {:noreply,
         assign(socket, export_src: nil, export_msg: "erro ao exportar: #{inspect(reason)}")}
    end
  end

  # One-click screenshot of a calibrated region (or the whole screen), served
  # via /captures/:name for inline preview + download.
  def handle_event("shot", %{"region" => region}, socket) do
    case capture_region(region) do
      {:ok, src, label} -> {:noreply, assign(socket, capture_src: src, capture_label: label)}
      {:error, msg} -> {:noreply, assign(socket, capture_src: nil, capture_label: msg)}
    end
  end

  # Dump everything the bot sees (regions + pixel metrics + a colour matrix) to
  # ~/.pokex/exports/ and render it inline, so Lucas can eyeball the matrix and
  # hand Claude the JSON.
  def handle_event("export_diagnostic", _params, socket) do
    case Report.capture() do
      {:ok, report, path} ->
        {:noreply,
         assign(socket,
           report: report,
           report_src: "/exports/#{Path.basename(path)}",
           report_msg: "diagnóstico exportado"
         )}

      {:error, reason} ->
        {:noreply, assign(socket, report: nil, report_msg: "erro: #{inspect(reason)}")}
    end
  end

  # Turning a support feature ON re-arms the (idempotent) monitor — the natural re-enable after
  # a panic halted it. Gated by the same env flag as the boot auto-start so the app-global
  # worker never starts ticking against the shared Rig during unrelated tests.
  defp arm_support do
    if Application.get_env(:pokex, :player_support_auto_monitor, true),
      do: PlayerSupport.Worker.run()

    :ok
  catch
    :exit, _reason -> :ok
  end

  defp save_int(socket, raw, range, setting_key, assign_key) do
    case PanelForms.parse_int(raw, range) do
      {:ok, value} ->
        Settings.put(setting_key, value)
        assign(socket, assign_key, value)

      :error ->
        socket
    end
  end

  # The UI speaks SECONDS (what Lucas reasons in); the settings store milliseconds.
  defp save_seconds(socket, raw, range, setting_key, assign_key) do
    case PanelForms.parse_int(raw, range) do
      {:ok, seconds} ->
        Settings.put(setting_key, seconds * 1000)
        assign(socket, assign_key, seconds)

      :error ->
        socket
    end
  end

  defp export_events(logs) do
    name = "events-#{System.system_time(:millisecond)}.log"
    path = Path.join(Pokex.Home.exports_dir(), name)

    body =
      logs
      |> Enum.reverse()
      |> Enum.map_join("\n", fn e -> "#{e.at} #{e.source} [#{e.level}] #{e.text}" end)

    case File.write(path, body <> "\n") do
      :ok -> {:ok, name}
      error -> error
    end
  end

  defp capture_region("screen") do
    case Pokex.Bots.Capture.screen("panel_screen.png") do
      {:ok, path} -> {:ok, capture_src(path), "tela cheia"}
      {:error, reason} -> {:error, "erro na captura: #{inspect(reason)}"}
    end
  end

  defp capture_region(name) do
    with {:ok, calib} <- Calibration.load(),
         {region, label, file} <- region_spec(name, calib),
         {:ok, path} <- Rig.impl().capture(region, file) do
      {:ok, capture_src(path), label}
    else
      :error -> {:error, "região desconhecida"}
      {:error, reason} -> {:error, "erro na captura: #{inspect(reason)}"}
    end
  end

  defp region_spec("glow", calib) do
    region = Calibration.glow_search_region(calib, Settings.get(:glow_search_margin) || 0)
    {region, "água (glow ampliado)", "shot_glow.png"}
  end

  defp region_spec("battle", calib),
    do: {calib.battle_region, "painel Batalha", "shot_battle.png"}

  defp region_spec("arena", calib), do: {calib.arena_region, "arena", "shot_arena.png"}
  defp region_spec("skills", %{skill_bar_region: nil}), do: :error

  defp region_spec("skills", calib),
    do: {calib.skill_bar_region, "barra de skills", "shot_skills.png"}

  defp region_spec(_other, _calib), do: :error

  defp capture_src(path),
    do: "/captures/#{Path.basename(path)}?t=#{System.unique_integer([:positive])}"

  # Nil-safe deep fetch into the report map (regions may carry :error instead of
  # :metrics/:matrix when a capture fails), so the render never KeyErrors.
  defp gi(map, path), do: get_in(map, path)

  defp cell_style(%{rgb: [r, g, b]}), do: "background: rgb(#{r}, #{g}, #{b})"

  @feed_sources ["🎣", "⚔️", "🎮", "🎯", "🚑", "🧤", "🔔"]
  defp feed_sources, do: @feed_sources

  defp visible_logs(logs, show_debug, source_filter) do
    Enum.filter(logs, fn entry ->
      (show_debug or entry.level == :macro) and
        (source_filter == nil or entry.source == source_filter)
    end)
  end

  defp log_class(:macro), do: "text-base-content"
  defp log_class(_debug), do: "opacity-50"

  # A one-shot read of the per-slot skill states (:ready | :cooldown), or nil when the bar
  # isn't calibrated / the capture fails. This is exactly the read SkillBar does for the gate.
  defp read_cooldown_states do
    case Calibration.load() do
      {:ok, calib} -> SkillBar.states(SkillBar.read(calib, Settings.all()))
      _ -> nil
    end
  end

  defp counters, do: @counters
  defp timing_fields, do: @timing_fields
  defp positive_timing_key?(key), do: key in @positive_timing_keys

  # Fishing and combat only truly overlap on :failures — sum those; every
  # other counter belongs to exactly one worker, so a plain merge is right
  # for them.
  defp merged_counters(fishing, combat, catcher) do
    # captures now come from the Catcher.Worker (combat's are always 0 since the extraction),
    # fights from combat, hooked from fishing; failures sum across fishing+combat (catcher
    # tracks its own throws/ignored separately, with no notion of an I/O failure).
    [fishing, combat, catcher]
    |> Enum.map(&Map.new(&1.counters || %{}))
    |> Enum.reduce(%{}, fn m, acc ->
      Map.merge(acc, m, fn
        :failures, a, b -> a + b
        _key, _a, b -> b
      end)
    end)
  end

  # 🎣 Pesca: parado / arremessando (equipping, casting, focusing all read as
  # the cast-prep phase) / vigiando (watching the glow) / erro.
  defp fishing_label(:idle), do: "parado"
  defp fishing_label(:focusing), do: "arremessando"
  defp fishing_label(:equipping), do: "arremessando"
  defp fishing_label(:casting), do: "arremessando"
  defp fishing_label(:watching), do: "vigiando"
  defp fishing_label(:error), do: "erro"
  defp fishing_label(other), do: to_string(other)

  # ⚔️ Batalha: parado / caçando / confirmando alvo (Tab) / lutando linha N / erro. Corpse
  # capture is a separate worker (see catcher_label/1).
  defp combat_label(:idle, _row), do: "parado"
  defp combat_label(:hunting, _row), do: "caçando"
  defp combat_label(:tabbing, _row), do: "confirmando alvo (Tab)"
  defp combat_label(:fighting, row) when is_integer(row), do: "lutando linha #{row}"
  defp combat_label(:fighting, _row), do: "lutando"
  defp combat_label(:error, _row), do: "erro"
  defp combat_label(other, _row), do: to_string(other)

  # 🎯 Captura: parado (mode "parado" mas sem corpo ainda / mode "movimento" halted) /
  # capturando (armado, jogando pokébola nos corpos detectados) / manual (mode "movimento" —
  # você captura na mão).
  defp catcher_label(:idle), do: "parado"
  defp catcher_label(:armed), do: "capturando"
  defp catcher_label(:manual), do: "manual"
  defp catcher_label(:saqueando), do: "só saque"
  defp catcher_label(other), do: to_string(other)

  # 🚑 Suporte (PlayerSupport): revive + poção. Halts on panic/Stop like every worker.
  defp support_label(:monitoring), do: "monitorando"
  defp support_label(:idle), do: "parado"
  defp support_label(other), do: to_string(other)

  # 🎮 Mini game: desligado / observando a arena / jogando (os outros workers se
  # seguram sozinhos lendo o fato :mini_game no blackboard).
  defp mini_game_label(:off), do: "parado"
  defp mini_game_label(:watching), do: "observando"
  defp mini_game_label(:playing), do: "em jogo"
  defp mini_game_label(:error), do: "erro"
  defp mini_game_label(other), do: to_string(other)

  # The Fase-1 pill details: WHY the worker is holding back (amber lock) and the
  # last performed actuation with its live age. Snapshots without the keys (an
  # old worker mid-rolling-restart) render nothing — Map.get keeps it safe.
  defp pill_details(assigns) do
    ~H"""
    <p
      :if={Map.get(@snapshot, :hold_reason)}
      title={Map.get(@snapshot, :hold_reason)}
      class="mt-0.5 truncate pl-3 font-mono text-[8px] uppercase tracking-[0.1em] text-[#f2c45b]"
    >
      🔒 {Map.get(@snapshot, :hold_reason)}
    </p>
    <p
      :if={last_action_text(@snapshot, @now_ms)}
      title={last_action_text(@snapshot, @now_ms)}
      class="mt-0.5 truncate pl-3 font-mono text-[8px] uppercase tracking-[0.1em] text-[#5d6670]"
    >
      ⚡ {last_action_text(@snapshot, @now_ms)}
    </p>
    """
  end

  # --- sessão e alarmes (Fase 7) ---------------------------------------------

  # Same practically-forever max age the :calibration stamp uses — the fact only
  # disappears because stop_all forgets it, never by expiring.
  @session_max_age_ms 4_000_000_000

  defp session_started_at do
    case Pokex.Perception.WorldState.get(:session, @session_max_age_ms, now_ms()) do
      {:ok, %{started_at: at}} -> at
      _no_session -> nil
    end
  end

  # --- shiny guard (star meter + trophy shelf) --------------------------------

  # "há 3min" / the clock time — the shelf reads as a timeline, not ISO noise.
  defp shiny_log_when(%{at: at}) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, dt, _} ->
        diff = DateTime.diff(DateTime.utc_now(), dt)

        cond do
          diff < 60 -> "agora"
          diff < 3_600 -> "há #{div(diff, 60)}min"
          diff < 86_400 -> "há #{div(diff, 3_600)}h"
          true -> "há #{div(diff, 86_400)}d"
        end

      _bad ->
        at
    end
  end

  defp shiny_log_when(_entry), do: "?"

  defp shiny_px_label(nil), do: "—"
  defp shiny_px_label(px), do: to_string(px)

  defp shiny_bar_pct(nil, _min), do: 0
  defp shiny_bar_pct(_px, min) when min <= 0, do: 0
  defp shiny_bar_pct(px, min), do: min(round(px / min * 100), 100)

  # green = no star (normal list), red = A SHINY is listed — red is GOOD here.
  defp shiny_zone(nil, _min), do: :none
  defp shiny_zone(px, min) when px >= min, do: :hit
  defp shiny_zone(px, min) when px >= min * 0.5, do: :warn
  defp shiny_zone(_px, _min), do: :safe

  defp shiny_px_class(px, min) do
    case shiny_zone(px, min) do
      :hit -> "text-[#ff6b74]"
      :warn -> "text-[#f2c45b]"
      :safe -> "text-[#37d07d]"
      :none -> "text-[#5d6670]"
    end
  end

  defp session_duration(nil, _now_ms), do: nil

  defp session_duration(started_at, now_ms) do
    total_s = max(div(now_ms - started_at, 1000), 0)
    {h, m, s} = {div(total_s, 3600), div(rem(total_s, 3600), 60), rem(total_s, 60)}

    cond do
      h > 0 -> "#{h}h#{String.pad_leading("#{m}", 2, "0")}m"
      m > 0 -> "#{m}m#{String.pad_leading("#{s}", 2, "0")}s"
      true -> "#{s}s"
    end
  end

  # Per-hour rate over the session window, one decimal ("12.5"). The 1-minute
  # floor keeps the first seconds from printing absurd extrapolations.
  defp session_rate(count, started_at, now_ms) do
    hours = max(now_ms - started_at, 60_000) / 3_600_000
    :erlang.float_to_binary(count / hours, decimals: 1)
  end

  # A worker snapshot arriving with a FRESH error (previous had none) rings the
  # alarm. A persisting error is no edge; the min-gap dedupe below covers
  # flapping. Map.get on both sides: the busy placeholder has no :error key.
  defp alarm_on_error(socket, key, snapshot) do
    previous_error = Map.get(socket.assigns[key], :error)

    case Map.get(snapshot, :error) do
      error when is_binary(error) and is_nil(previous_error) ->
        alarm(socket, {:error, key}, "#{worker_name(key)} em erro: #{error}")

      _no_edge ->
        socket
    end
  end

  # HP crossing BELOW the rescue threshold (or first read already below it).
  defp alarm_on_critical_hp(socket, snapshot) do
    threshold = Settings.get(:pokemon_hp_rescue_pct)
    previous = socket.assigns.game.hp_pct
    current = Map.get(snapshot, :hp_pct)

    if is_integer(current) and current < threshold and
         (previous == nil or previous >= threshold) do
      alarm(socket, :hp_critical, "vida crítica: #{current}% (limiar #{threshold}%)")
    else
      socket
    end
  end

  # One pipeline for every alarm: the per-type min gap (KizuBot's
  # antiSpamInterval) dedupes a flapping source; inside the gap NOTHING happens
  # (no line, no sound). Mute only silences the sound — the 🔔 feed line stays,
  # so a muted panel still keeps the record.
  defp alarm(socket, key, text) do
    last = Map.get(socket.assigns.alarm_last, key)
    at = now_ms()

    if last != nil and at - last < Settings.get(:alarm_min_gap_ms) do
      socket
    else
      socket =
        socket
        |> assign(alarm_last: Map.put(socket.assigns.alarm_last, key, at))
        |> append_log(%{level: :macro, source: "🔔", text: text})

      if Settings.get(:alarm_sound),
        do: push_event(socket, "alarm", %{text: text}),
        else: socket
    end
  end

  defp worker_name(:fishing), do: "pesca"
  defp worker_name(:combat), do: "batalha"
  defp worker_name(:catcher), do: "captura"
  defp worker_name(:mini_game), do: "mini game"
  defp worker_name(:game), do: "suporte"

  # One line summarizing what a preset would change — the two skill lists are
  # the piece you actually scan for when switching Pokémon.
  defp preset_summary(preset) do
    [
      preset.skill_keys && "skills #{Enum.join(preset.skill_keys, " ")}",
      preset.hook_skill_keys && "fisga #{Enum.join(preset.hook_skill_keys, " ")}"
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "—"
      parts -> Enum.join(parts, " · ")
    end
  end

  defp last_action_text(snapshot, now_ms) do
    case Map.get(snapshot, :last_action) do
      %{text: text, at: at} when is_integer(at) -> "#{text} · #{format_age(now_ms - at)}"
      _absent -> nil
    end
  end

  # Ages come from monotonic timestamps (may be negative numbers — nil, never 0,
  # is the "no action yet" sentinel, handled above).
  defp format_age(ms) when ms < 1_000, do: "agora"
  defp format_age(ms) when ms < 60_000, do: "há #{div(ms, 1000)}s"
  defp format_age(ms) when ms < 3_600_000, do: "há #{div(ms, 60_000)}min"
  defp format_age(_ms), do: "há 1h+"

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp active?(:idle), do: false
  defp active?(:off), do: false
  # BotSupervisor's busy placeholder (a worker that missed its 1s status window) — unknown,
  # so don't paint it green/"Ativo" and don't offer "Parar" for a state we couldn't read.
  defp active?(:ocupado), do: false
  defp active?(_state), do: true

  defp toggle_worker(socket, key, worker) do
    current = Map.fetch!(socket.assigns, key)
    result = if active?(current.state), do: worker.halt(), else: worker.run()

    case result do
      :ok -> {:noreply, assign(socket, key, worker.status())}
      {:error, messages} when is_list(messages) -> {:noreply, assign(socket, errors: messages)}
      {:error, reason} -> {:noreply, assign(socket, errors: [inspect(reason)])}
    end
  end

  # Catcher isn't part of this check: in "movimento" mode it always reads :manual — a display
  # choice, not a running/halted signal — so it can't tell you whether the bot is on.
  defp overall_active?(fishing, combat),
    do: Enum.any?([fishing.state, combat.state], &active?/1)

  defp automation_count(
         fishing,
         combat,
         player_mode,
         loot_enabled,
         capture_enabled,
         rescue_enabled,
         potion_enabled
       ) do
    [
      active?(fishing.state),
      active?(combat.state),
      loot_enabled and player_mode == "parado",
      capture_enabled and player_mode == "parado",
      rescue_enabled,
      potion_enabled
    ]
    |> Enum.count(& &1)
  end

  defp rescue_count(game), do: get_in(game, [:counters, :rescues]) || 0
  defp potion_count(game), do: get_in(game, [:counters, :potions]) || 0
  defp catcher_captures(catcher), do: get_in(catcher, [:counters, :captures]) || 0
  defp catcher_loots(catcher), do: get_in(catcher, [:counters, :loots]) || 0

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, required: true
  attr :active, :boolean, required: true
  attr :event, :string, required: true

  defp automation_row(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "flex min-h-14 items-center gap-3 border-b border-[#222a2f] px-3 py-2.5 last:border-b-0",
        @active && "bg-[#102019]"
      ]}
    >
      <span class={[
        "h-8 w-0.5 shrink-0 rounded-full",
        if(@active, do: "bg-[#37d07d]", else: "bg-transparent")
      ]} />
      <div class="min-w-0 flex-1">
        <p class="text-sm font-semibold text-[#d9dde1]">{@title}</p>
        <p class="mt-0.5 text-[11px] leading-tight text-[#7f8992]">{@description}</p>
      </div>
      <input
        id={"#{@id}-toggle"}
        type="checkbox"
        class="toggle toggle-success toggle-sm shrink-0"
        checked={@active}
        phx-click={@event}
        aria-label={@title}
      />
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_page={:panel}>
      <div id="panel-dashboard" class="min-h-dvh bg-[#080b0d] text-[#d9dde1]">
        <header class="sticky top-0 z-30 border-b border-[#1f262b] bg-[#090c0f]/95 backdrop-blur">
          <div class="mx-auto flex h-12 max-w-[520px] items-center justify-between px-2 xl:max-w-[1080px] 2xl:max-w-[1800px]">
            <div class="flex items-center gap-2">
              <.link navigate={~p"/"} class="flex items-center gap-2.5" aria-label="Ir ao painel">
                <span class="grid size-7 place-items-center rounded-lg bg-[#36cf78] text-sm font-black text-[#06150c]">P</span>
                <span class="text-sm font-bold">Pokex</span>
              </.link>
              <span
                :if={not @focused?}
                id="focus-pause-badge"
                class="grid size-6 place-items-center rounded-full border border-[#674f20] bg-[#211b0d] text-[#f2c45b]"
                title="Pausado por segurança — a janela do jogo perdeu o foco. Nada é digitado/clicado até você voltar pro jogo; aí os workers religam sozinhos."
                aria-label="Pausado por segurança: a janela do jogo perdeu o foco"
              >
                <.icon name="hero-pause-circle" class="size-4" />
              </span>
            </div>
            <div class="flex items-center gap-2">
              <span class="flex items-center gap-2 rounded-full border border-[#293137] px-2.5 py-1 font-mono text-[10px] font-bold uppercase tracking-[0.14em] text-[#8b949d]">
                <span class={[
                  "size-1.5 rounded-full",
                  if(overall_active?(@fishing, @combat),
                    do: "bg-[#37d07d]",
                    else: "bg-[#68727b]"
                  )
                ]} />
                {if(overall_active?(@fishing, @combat), do: "Ativo", else: "Parado")}
              </span>
              <details id="panel-navigation" phx-update="ignore" class="group relative">
                <summary
                  id="panel-navigation-toggle"
                  class="grid size-8 cursor-pointer list-none place-items-center rounded-lg border border-[#293137] text-[#a4adb4] transition hover:border-[#37d07d]/60 hover:bg-[#14191d] hover:text-white [&::-webkit-details-marker]:hidden"
                  title="Abrir navegação"
                  aria-label="Abrir navegação"
                >
                  <.icon name="hero-bars-3" class="size-4" />
                </summary>
                <nav
                  aria-label="Navegação principal"
                  class="absolute right-0 top-10 z-50 w-48 overflow-hidden rounded-lg border border-[#293238] bg-[#111519] p-1 shadow-2xl shadow-black/50"
                >
                  <.link
                    id="panel-nav-home"
                    navigate={~p"/"}
                    aria-current="page"
                    class="flex items-center gap-2 rounded-md bg-[#17231c] px-3 py-2.5 text-xs font-semibold text-[#4ade86]"
                  >
                    <.icon name="hero-play-circle" class="size-4" /> Painel
                  </.link>
                  <.link
                    id="panel-nav-calibration"
                    navigate={~p"/calibration"}
                    class="flex items-center gap-2 rounded-md px-3 py-2.5 text-xs text-[#c7cdd2] transition hover:bg-[#1a2024] hover:text-white"
                  >
                    <.icon name="hero-viewfinder-circle" class="size-4 text-[#7f8992]" /> Calibração
                  </.link>
                  <.link
                    id="panel-nav-diagnostics"
                    navigate={~p"/diagnostics"}
                    class="flex items-center gap-2 rounded-md px-3 py-2.5 text-xs text-[#c7cdd2] transition hover:bg-[#1a2024] hover:text-white"
                  >
                    <.icon name="hero-beaker" class="size-4 text-[#7f8992]" /> Diagnóstico
                  </.link>
                  <.link
                    id="panel-nav-fishing-lab"
                    navigate={~p"/fishing-lab"}
                    class="flex items-center gap-2 rounded-md px-3 py-2.5 text-xs text-[#c7cdd2] transition hover:bg-[#1a2024] hover:text-white"
                  >
                    <.icon name="hero-sparkles" class="size-4 text-[#7f8992]" /> Laboratório
                  </.link>
                  <.link
                    id="panel-nav-world"
                    navigate={~p"/world"}
                    class="flex items-center gap-2 rounded-md px-3 py-2.5 text-xs text-[#c7cdd2] transition hover:bg-[#1a2024] hover:text-white"
                  >
                    <.icon name="hero-eye" class="size-4 text-[#7f8992]" /> Mundo
                  </.link>
                  <.link
                    id="panel-nav-pokedex"
                    navigate={~p"/pokedex"}
                    class="flex items-center gap-2 rounded-md px-3 py-2.5 text-xs text-[#c7cdd2] transition hover:bg-[#1a2024] hover:text-white"
                  >
                    <.icon name="hero-book-open" class="size-4 text-[#7f8992]" /> Pokédex
                  </.link>
                </nav>
              </details>
            </div>
          </div>
        </header>

        <main class="mx-auto max-w-[520px] space-y-3 px-2 py-3 xl:grid xl:max-w-[1080px] xl:grid-cols-2 xl:items-start xl:gap-4 xl:space-y-0 2xl:max-w-[1800px] 2xl:grid-cols-3">
          <div class="min-w-0 space-y-3 2xl:contents 2xl:space-y-0">
            <div class="min-w-0 space-y-3">
              <div
                :if={not @calibrated?}
                class="flex items-center gap-3 rounded-lg border border-[#674f20] bg-[#211b0d] p-3 text-xs"
              >
                <.icon name="hero-exclamation-triangle" class="size-5 shrink-0 text-[#f2c45b]" />
                <p class="flex-1 text-[#c8cdd1]">
                  Calibre água, Battle, arena e skills antes de iniciar.
                </p>
                <.link navigate={~p"/calibration"} class="font-semibold text-[#37d07d]">Calibrar</.link>
              </div>

              <div
                :if={@layout_lost?}
                id="layout-banner"
                class="flex items-center gap-3 rounded-lg border border-[#5f292f] bg-[#241114] p-3 text-xs"
              >
                <.icon name="hero-eye-slash" class="size-5 shrink-0 text-[#ff9ca4]" />
                <p class="flex-1 text-[#c8cdd1]">
                  Não achei o HUD na tela — o jogo está em tela cheia no monitor principal? Os
                  feeds estão segurando: nada é lido nem clicado às cegas.
                </p>
              </div>

              <div
                :if={@calib_stale?}
                id="calib-stale-banner"
                class="flex items-center gap-3 rounded-lg border border-[#674f20] bg-[#211b0d] p-3 text-xs"
              >
                <.icon name="hero-exclamation-triangle" class="size-5 shrink-0 text-[#f2c45b]" />
                <p class="flex-1 text-[#c8cdd1]">
                  A calibração mudou depois do último Start — os bots ainda usam a ANTIGA.
                </p>
                <button
                  phx-click="restart_bots"
                  class="btn btn-xs border-0 bg-[#37d07d] font-bold text-[#06140c] hover:bg-[#45dd88]"
                >
                  Parar e Iniciar
                </button>
              </div>

              <div class="grid grid-cols-3 gap-1.5">
                <div
                  data-testid="fishing-pill"
                  data-state={@fishing.state}
                  class="rounded-lg border border-[#232a30] bg-[#111519] px-2 py-2"
                >
                  <div class="flex items-center gap-1.5 text-[11px] font-semibold">
                    <span class={[
                      "size-1.5 shrink-0 rounded-full",
                      if(active?(@fishing.state), do: "bg-[#37d07d]", else: "bg-[#68717a]")
                    ]} /> Pesca
                  </div>
                  <p class="mt-0.5 truncate pl-3 font-mono text-[8px] uppercase tracking-[0.1em] text-[#7d8790]">
                    {fishing_label(@fishing.state)}
                  </p>
                  <.pill_details snapshot={@fishing} now_ms={@now_ms} />
                </div>
                <div
                  data-testid="combat-pill"
                  data-state={@combat.state}
                  class="rounded-lg border border-[#232a30] bg-[#111519] px-2 py-2"
                >
                  <div class="flex items-center gap-1.5 text-[11px] font-semibold">
                    <span class={[
                      "size-1.5 shrink-0 rounded-full",
                      if(active?(@combat.state), do: "bg-[#37d07d]", else: "bg-[#68717a]")
                    ]} /> Batalha
                  </div>
                  <p class="mt-0.5 truncate pl-3 font-mono text-[8px] uppercase tracking-[0.1em] text-[#7d8790]">
                    {combat_label(@combat.state, Map.get(@combat, :locked_row))}
                  </p>
                  <.pill_details snapshot={@combat} now_ms={@now_ms} />
                </div>
                <div
                  data-testid="catcher-pill"
                  data-state={@catcher.state}
                  class="rounded-lg border border-[#232a30] bg-[#111519] px-2 py-2"
                >
                  <div class="flex items-center gap-1.5 text-[11px] font-semibold">
                    <span class={[
                      "size-1.5 shrink-0 rounded-full",
                      if(active?(@catcher.state), do: "bg-[#37d07d]", else: "bg-[#68717a]")
                    ]} /> Captura
                  </div>
                  <p class="mt-0.5 truncate pl-3 font-mono text-[8px] uppercase tracking-[0.1em] text-[#7d8790]">
                    {catcher_label(@catcher.state)} · {catcher_captures(@catcher)}🎯 {catcher_loots(
                      @catcher
                    )}🧰
                  </p>
                  <.pill_details snapshot={@catcher} now_ms={@now_ms} />
                </div>
                <div
                  data-testid="mini-game-pill"
                  data-state={@mini_game.state}
                  title={"confiança #{round((@mini_game.confidence || 0) * 100)}%"}
                  class="rounded-lg border border-[#232a30] bg-[#111519] px-2 py-2"
                >
                  <div class="flex items-center justify-between text-[11px] font-semibold">
                    <span class="flex items-center gap-1.5">
                      <span class={[
                        "size-1.5 shrink-0 rounded-full",
                        if(@mini_game.state == :playing, do: "bg-[#f3ba4e]", else: "bg-[#68717a]")
                      ]} /> Mini game
                    </span>
                    <button
                      type="button"
                      phx-click="toggle_mini_game_sound"
                      title={
                        if @mini_game_sound,
                          do: "Alerta sonoro ligado — clique para silenciar",
                          else: "Alerta sonoro MUDO — clique para reativar"
                      }
                      class={[
                        "cursor-pointer",
                        if(@mini_game_sound,
                          do: "text-[#7d8790] hover:text-[#e8ecef]",
                          else: "text-[#f3ba4e] hover:text-[#ffd27a]"
                        )
                      ]}
                    >
                      <.icon
                        name={
                          if @mini_game_sound, do: "hero-speaker-wave", else: "hero-speaker-x-mark"
                        }
                        class="size-3"
                      />
                    </button>
                  </div>
                  <p class="mt-0.5 truncate pl-3 font-mono text-[8px] uppercase tracking-[0.1em] text-[#7d8790]">
                    {mini_game_label(@mini_game.state)}
                  </p>
                </div>
                <div
                  data-testid="support-pill"
                  data-state={@game.state}
                  title="revive + poção — protege o Pokémon principal, até jogando manual"
                  class="rounded-lg border border-[#232a30] bg-[#111519] px-2 py-2"
                >
                  <div class="flex items-center gap-1.5 text-[11px] font-semibold">
                    <span class={[
                      "size-1.5 shrink-0 rounded-full",
                      if(@game.state == :monitoring, do: "bg-[#37d07d]", else: "bg-[#68717a]")
                    ]} /> Suporte
                  </div>
                  <p class="mt-0.5 truncate pl-3 font-mono text-[8px] uppercase tracking-[0.1em] text-[#7d8790]">
                    {support_label(@game.state)} · {rescue_count(@game)}🚑 {potion_count(@game)}🧪
                  </p>
                  <.pill_details snapshot={@game} now_ms={@now_ms} />
                </div>
              </div>

              <div class="space-y-1">
                <p
                  :if={@fishing.error}
                  class="rounded-lg border border-[#5f292f] bg-[#241114] px-3 py-2 text-xs text-[#ff9ca4]"
                >
                  {@fishing.error}
                </p>
                <p
                  :if={@combat.error}
                  class="rounded-lg border border-[#5f292f] bg-[#241114] px-3 py-2 text-xs text-[#ff9ca4]"
                >
                  {@combat.error}
                </p>
                <p
                  :if={@mini_game.error}
                  class="rounded-lg border border-[#5f292f] bg-[#241114] px-3 py-2 text-xs text-[#ff9ca4]"
                >
                  {@mini_game.error}
                </p>
                <p
                  :if={@catcher.error}
                  class="rounded-lg border border-[#5f292f] bg-[#241114] px-3 py-2 text-xs text-[#ff9ca4]"
                >
                  {@catcher.error}
                </p>
                <p
                  :if={@game.error}
                  class="rounded-lg border border-[#5f292f] bg-[#241114] px-3 py-2 text-xs text-[#ff9ca4]"
                >
                  {@game.error}
                </p>
                <ul
                  :if={@errors != []}
                  class="rounded-lg border border-[#674f20] bg-[#211b0d] px-3 py-2 text-xs text-[#e7ca82]"
                >
                  <li :for={message <- @errors}>{message}</li>
                </ul>
              </div>

              <button
                :if={not overall_active?(@fishing, @combat)}
                id="start-bot"
                class="flex h-12 w-full items-center justify-center gap-2 rounded-xl bg-[#39cd76] text-sm font-bold text-[#041109] shadow-[0_8px_24px_rgba(57,205,118,0.16)] transition hover:bg-[#45da83] active:scale-[0.99]"
                phx-click="start"
              >
                <.icon name="hero-play-solid" class="size-4" /> Iniciar bot
              </button>
              <button
                :if={overall_active?(@fishing, @combat)}
                id="stop-bot"
                class="flex h-12 w-full items-center justify-center gap-2 rounded-xl border border-[#703136] bg-[#281114] text-sm font-bold text-[#ff9ca4] transition hover:bg-[#35171b] active:scale-[0.99]"
                phx-click="stop"
              >
                <.icon name="hero-stop-solid" class="size-4" /> Parar bot
              </button>
            </div>

            <div class="min-w-0 space-y-3">
              <details id="automations-panel" open class="group">
                <summary class="mb-2 flex cursor-pointer list-none items-center justify-between px-0.5 font-mono text-[10px] font-bold uppercase tracking-[0.12em] text-[#69737b] transition hover:text-[#9aa3aa] [&::-webkit-details-marker]:hidden">
                  <h2 class="flex items-center gap-1.5">
                    Automações
                    <.icon
                      name="hero-chevron-down"
                      class="size-3 text-[#68727a] transition group-open:rotate-180"
                    />
                  </h2>
                  <span>{automation_count(
                    @fishing,
                    @combat,
                    @player_mode,
                    @loot_enabled,
                    @capture_enabled,
                    @rescue_enabled,
                    @potion_enabled
                  )}/6 on</span>
                </summary>
                <div class="overflow-hidden rounded-lg border border-[#232b30] bg-[#101418]">
                  <.automation_row
                    id="automation-fishing"
                    title="Pesca automática"
                    description="Lança e fisga sozinho"
                    active={active?(@fishing.state)}
                    event="toggle_fishing"
                  />
                  <.automation_row
                    id="automation-combat"
                    title="Luta automática"
                    description="Ataca inimigos com as skills"
                    active={active?(@combat.state)}
                    event="toggle_combat"
                  />
                  <div
                    id="automation-mode"
                    class="flex min-h-14 items-center gap-3 border-b border-[#222a2f] px-3 py-2.5"
                  >
                    <div class="min-w-0 flex-1">
                      <p class="text-sm font-semibold text-[#d9dde1]">Modo</p>
                      <p class="mt-0.5 text-[11px] leading-tight text-[#7f8992]">
                        {if @player_mode == "parado",
                          do: "parado no spot — loot e captura agem sozinhos",
                          else: "você saqueia e captura manualmente — em movimento o bot não age"}
                      </p>
                    </div>
                    <div class="flex shrink-0 gap-1">
                      <button
                        :for={{mode, label} <- [{"parado", "Parado"}, {"movimento", "Em movimento"}]}
                        phx-click="set_player_mode"
                        phx-value-mode={mode}
                        class={[
                          "h-8 rounded-lg border px-2.5 text-[11px]",
                          if(@player_mode == mode,
                            do: "border-[#237d4d] bg-[#0d3822] text-[#3de083]",
                            else: "border-[#293238] text-[#89939a] hover:text-white"
                          )
                        ]}
                      >{label}</button>
                    </div>
                  </div>
                  <.automation_row
                    id="automation-loot"
                    title="Pegar loot (Espaço)"
                    description="Espaço após cada kill (o corpo cai do teu lado)"
                    active={@loot_enabled}
                    event="toggle_loot_enabled"
                  />
                  <.automation_row
                    id="automation-capture"
                    title="Capturar (Pokébola)"
                    description="joga bola nos corpos detectados ao redor"
                    active={@capture_enabled}
                    event="toggle_capture_enabled"
                  />
                  <button
                    :if={@player_mode == "parado"}
                    phx-click="relearn_ground"
                    class="mx-3 mb-2 flex h-8 items-center gap-1.5 rounded-lg border border-[#293238] px-3 font-mono text-[10px] text-[#89939a] hover:text-white"
                  >
                    <.icon name="hero-arrow-path" class="size-3" /> Reaprender chão (mudou de spot)
                  </button>
                  <.automation_row
                    id="automation-rescue"
                    title="Revive automático"
                    description={"Revive quando a vida cai abaixo de #{@rescue_pct}%"}
                    active={@rescue_enabled}
                    event="toggle_rescue"
                  />
                  <.automation_row
                    id="automation-potion"
                    title="Poção automática"
                    description={"Poção (tecla #{Settings.get(:potion_key)}) abaixo de #{@potion_pct}%, só fora de luta"}
                    active={@potion_enabled}
                    event="toggle_potion"
                  />
                  <.automation_row
                    id="automation-reposition"
                    title="Reposicionar após lutas"
                    description="clique do meio no tile calibrado (Calibração → Posição do Pokémon) 2s depois da luta acabar"
                    active={@reposition_enabled}
                    event="toggle_reposition"
                  />
                  <.automation_row
                    id="automation-support-waits-capture"
                    title="Suporte espera a captura"
                    description="ordem pós-luta: loot → bola → suporte — poção e reposição só agem quando os corpos foram resolvidos (teto de 10s pra nunca segurar a cura)"
                    active={@support_waits_capture}
                    event="toggle_support_waits_capture"
                  />
                  <.automation_row
                    id="automation-require-cooldowns"
                    title="Só pescar quando dá pra matar"
                    description="segura a fisga até pelo menos UMA das skills abaixo estar pronta"
                    active={@require_cooldowns}
                    event="toggle_require_cooldowns"
                  />
                  <form
                    id="hook-skills-form"
                    phx-submit="save_hook_skills"
                    class="border-b border-[#222a2f] px-3 py-2.5"
                  >
                    <label class="font-mono text-[10px] text-[#77828a]">
                      Skills necessárias pra matar
                    </label>
                    <div class="mt-1.5 flex gap-2">
                      <input
                        name="hook_skills"
                        value={@hook_skills}
                        placeholder="4 5 6 7"
                        class="input input-bordered h-9 min-w-0 flex-1 bg-[#090d0f] font-mono text-sm"
                      />
                      <button class="btn h-9 border-0 bg-[#37d07d] px-4 text-xs font-bold text-[#06140c] hover:bg-[#45dd88]">
                        Salvar
                      </button>
                    </div>
                  </form>
                  <.automation_row
                    id="automation-require-pokemon-hp"
                    title="Só pescar com vida"
                    description="segura a fisga se o Pokémon está com pouca vida ou fora da pokébola (lê o monitor de suporte)"
                    active={@require_pokemon_hp}
                    event="toggle_require_pokemon_hp"
                  />
                  <div id="automation-escape" class="border-b border-[#222a2f] px-3 py-2.5">
                    <div class="flex min-h-10 items-center gap-3">
                      <div class="min-w-0 flex-1">
                        <p class="text-sm font-semibold text-[#d9dde1]">Fuga de emergência</p>
                        <p class="mt-0.5 text-[11px] leading-tight text-[#7f8992]">
                          anda até o tile calibrado (Calibração → Escada de fuga), entra na escada
                          de seta, para TUDO e toca o alarme — vai ser o protocolo anti-shiny
                        </p>
                      </div>
                      <button
                        id="test-escape"
                        phx-click="test_escape"
                        data-confirm="Vai CLICAR NO JOGO (no tile calibrado), dar os passos de seta e PARAR todos os bots. Testar a fuga agora?"
                        class="btn btn-xs h-8 shrink-0 border border-[#674f20] bg-transparent px-3 text-[11px] text-[#e7ca82] hover:bg-[#211b0d]"
                      >
                        🧪 Testar fuga
                      </button>
                    </div>
                    <form
                      id="escape-cfg-form"
                      phx-change="save_escape_cfg"
                      title="Depois do clique no tile, espera o personagem ANDAR até lá e então dá os passos de seta pra dentro da escada."
                      class="mt-1.5 flex flex-wrap items-center gap-1 font-mono text-[9px] text-[#737d85]"
                    >
                      <span>entra pra</span>
                      <select
                        id="escape-direction"
                        name="escape_direction"
                        class="h-6 rounded border border-[#293238] bg-[#090d0f] px-1 font-mono text-[10px] text-[#dce1e4] focus:border-[#36d47c] focus:outline-none"
                      >
                        <option value="left" selected={@escape_direction == "left"}>
                          ← esquerda
                        </option>
                        <option value="right" selected={@escape_direction == "right"}>
                          → direita
                        </option>
                        <option value="up" selected={@escape_direction == "up"}>↑ cima</option>
                        <option value="down" selected={@escape_direction == "down"}>↓ baixo</option>
                      </select>
                      <span>×</span>
                      <input
                        id="escape-steps"
                        name="escape_steps"
                        type="number"
                        min="1"
                        max="10"
                        value={@escape_steps}
                        phx-debounce="500"
                        class="h-6 w-10 rounded border border-[#293238] bg-[#090d0f] px-1 text-center font-mono text-[10px] text-[#dce1e4] focus:border-[#36d47c] focus:outline-none"
                      />
                      <span>passos · espera a caminhada por</span>
                      <input
                        id="escape-walk-wait"
                        name="escape_walk_wait_ms"
                        type="number"
                        min="0"
                        max="10000"
                        step="100"
                        value={@escape_walk_wait_ms}
                        phx-debounce="500"
                        class="h-6 w-14 rounded border border-[#293238] bg-[#090d0f] px-1 text-center font-mono text-[10px] text-[#dce1e4] focus:border-[#36d47c] focus:outline-none"
                      />
                      <span>ms</span>
                    </form>
                  </div>
                  <form id="fishing-hp-form" phx-submit="save_fishing_hp_cfg" class="px-3 py-2.5">
                    <label class="font-mono text-[10px] text-[#77828a]">
                      Vida mínima pra puxar a vara (%)
                    </label>
                    <div class="mt-1.5 flex gap-2">
                      <input
                        name="fishing_hp_pct"
                        inputmode="numeric"
                        value={@fishing_hp_pct}
                        class="input input-bordered h-9 min-w-0 flex-1 bg-[#090d0f] font-mono text-sm"
                      />
                      <button class="btn h-9 border-0 bg-[#37d07d] px-4 text-xs font-bold text-[#06140c] hover:bg-[#45dd88]">
                        Salvar
                      </button>
                    </div>
                  </form>
                </div>
              </details>

              <section id="presets-card" class="rounded-lg border border-[#232b30] bg-[#111519] p-3">
                <div class="flex items-center justify-between text-xs font-semibold">
                  <span>Presets por Pokémon</span>
                  <span class="font-mono text-[9px] text-[#737d85]">skills · bolas · suporte</span>
                </div>
                <p class="mt-1 text-[11px] leading-tight text-[#7f8992]">
                  Salva o conjunto atual de skills, captura e suporte com o nome do Pokémon —
                  trocar de Pokémon vira um clique.
                </p>
                <form id="preset-save-form" phx-submit="save_preset" class="mt-2 flex gap-2">
                  <input
                    name="name"
                    placeholder="ex.: charizard"
                    class="input input-bordered h-9 min-w-0 flex-1 bg-[#090d0f] font-mono text-sm"
                  />
                  <button class="btn h-9 border-0 bg-[#37d07d] px-4 text-xs font-bold text-[#06140c] hover:bg-[#45dd88]">
                    Salvar preset
                  </button>
                </form>
                <p :if={@preset_msg} id="preset-msg" class="mt-2 text-[11px] text-[#e7ca82]">
                  {@preset_msg}
                </p>
                <ul
                  :if={@presets != []}
                  id="preset-list"
                  class="mt-2 divide-y divide-[#222a2f] overflow-hidden rounded-lg border border-[#232b30]"
                >
                  <li
                    :for={preset <- @presets}
                    class="flex items-center gap-2 bg-[#101418] px-3 py-2"
                  >
                    <div class="min-w-0 flex-1">
                      <p class="truncate text-sm font-semibold text-[#d9dde1]">{preset.slug}</p>
                      <p class="truncate font-mono text-[9px] text-[#737d85]">
                        {preset_summary(preset)}
                      </p>
                    </div>
                    <button
                      phx-click="apply_preset"
                      phx-value-slug={preset.slug}
                      class="btn btn-xs h-7 border-0 bg-[#37d07d] px-3 text-[11px] font-bold text-[#06140c] hover:bg-[#45dd88]"
                    >
                      Aplicar
                    </button>
                    <button
                      phx-click="delete_preset"
                      phx-value-slug={preset.slug}
                      data-confirm={"Excluir o preset \"#{preset.slug}\"?"}
                      class="btn btn-xs h-7 border border-[#5f292f] bg-transparent px-2 text-[11px] text-[#ff9ca4] hover:bg-[#241114]"
                    >
                      Excluir
                    </button>
                  </li>
                </ul>
              </section>

              <section class="rounded-lg border border-[#232b30] bg-[#111519] p-3">
                <div class="flex items-center justify-between text-xs font-semibold">
                  <span>Vida do Pokémon principal</span><span class="font-mono text-[#36d47c]">{hp_label(
                    @game
                  )}</span>
                </div>
                <div class="mt-2 h-2 overflow-hidden rounded-full bg-[#273037]">
                  <div
                    class="h-full rounded-full transition-[width] duration-300"
                    style={hp_bar_style(@game)}
                  />
                </div>
                <div class="mt-2 flex items-center justify-between font-mono text-[9px] text-[#737d85]">
                  <form
                    id="rescue-cfg-form"
                    phx-change="save_rescue_cfg"
                    class="flex items-center gap-1"
                  >
                    <label for="rescue-pct">revive &lt;</label>
                    <input
                      id="rescue-pct"
                      name="rescue_pct"
                      type="number"
                      min="1"
                      max="90"
                      value={@rescue_pct}
                      phx-debounce="500"
                      class="h-6 w-12 rounded border border-[#293238] bg-[#090d0f] px-1 text-center font-mono text-[10px] text-[#dce1e4] focus:border-[#36d47c] focus:outline-none"
                    />
                    <span>% · a cada</span>
                    <input
                      id="rescue-cooldown"
                      name="rescue_cooldown_s"
                      type="number"
                      min="2"
                      max="600"
                      value={@rescue_cooldown_s}
                      phx-debounce="500"
                      class="h-6 w-12 rounded border border-[#293238] bg-[#090d0f] px-1 text-center font-mono text-[10px] text-[#dce1e4] focus:border-[#36d47c] focus:outline-none"
                    />
                    <span>s</span>
                  </form>
                  <span>revives: {rescue_count(@game)}</span>
                </div>
                <div class="mt-1.5 flex items-center justify-between font-mono text-[9px] text-[#737d85]">
                  <form
                    id="potion-cfg-form"
                    phx-change="save_potion_cfg"
                    class="flex items-center gap-1"
                  >
                    <label for="potion-pct">poção &lt;</label>
                    <input
                      id="potion-pct"
                      name="potion_pct"
                      type="number"
                      min="1"
                      max="99"
                      value={@potion_pct}
                      phx-debounce="500"
                      class="h-6 w-12 rounded border border-[#293238] bg-[#090d0f] px-1 text-center font-mono text-[10px] text-[#dce1e4] focus:border-[#36d47c] focus:outline-none"
                    />
                    <span>% · a cada</span>
                    <input
                      id="potion-cooldown"
                      name="potion_cooldown_s"
                      type="number"
                      min="1"
                      max="600"
                      value={@potion_cooldown_s}
                      phx-debounce="500"
                      class="h-6 w-12 rounded border border-[#293238] bg-[#090d0f] px-1 text-center font-mono text-[10px] text-[#dce1e4] focus:border-[#36d47c] focus:outline-none"
                    />
                    <span>s</span>
                  </form>
                  <span>poções: {potion_count(@game)}</span>
                </div>
                <button
                  id="use-potion"
                  phx-click="use_potion"
                  class="mt-2.5 flex h-9 w-full items-center justify-center gap-1.5 rounded-lg border border-[#293238] text-[11px] font-semibold text-[#a4adb4] transition hover:border-[#37d07d]/60 hover:bg-[#14191d] hover:text-white active:scale-[0.99]"
                >
                  🧪 Usar poção agora
                </button>

                <div class="mt-3 border-t border-[#222a2f] pt-2.5">
                  <div class="flex items-center justify-between">
                    <h3 class="font-mono text-[9px] font-bold uppercase tracking-[0.12em] text-[#69737b]">
                      Cooldowns das skills
                    </h3>
                    <button
                      class="flex h-6 items-center gap-1 rounded-md border border-[#293238] px-2 font-mono text-[9px] text-[#89939a] transition hover:text-white"
                      phx-click="read_cooldowns"
                    >
                      <.icon name="hero-arrow-path" class="size-2.5" /> Ler
                    </button>
                  </div>
                  <div class="mt-1.5 flex flex-wrap gap-1.5">
                    <span
                      :for={
                        {state, key} <-
                          Enum.zip(
                            @cooldowns_states || [],
                            SkillBar.keys(length(@cooldowns_states || []))
                          )
                      }
                      class={[
                        "grid size-8 place-items-center rounded-md border font-mono text-[11px] font-bold",
                        if(state == :ready,
                          do: "border-[#237d4d] bg-[#0d3822] text-[#3de083]",
                          else: "border-[#313a40] bg-[#171c20] text-[#626c74]"
                        )
                      ]}
                    >{key}</span>
                    <span :if={is_nil(@cooldowns_states)} class="py-1.5 text-[10px] text-[#69737b]">
                      Clique em Ler para verificar a barra calibrada.
                    </span>
                  </div>
                </div>
              </section>
            </div>
          </div>

          <div class="min-w-0 space-y-3">
            <section
              :if={@stocks != %{}}
              id="stock-badges"
              class="rounded-lg border border-[#232b30] bg-[#111519] p-3"
            >
              <p class="font-mono text-[9px] font-bold uppercase tracking-[0.12em] text-[#69737b]">
                estoques
              </p>
              <ul class="mt-2 flex flex-wrap gap-2">
                <li
                  :for={{slot, label, _setting} <- Pokex.Bots.StockAlerts.slots()}
                  :if={@stocks[slot]}
                  id={"stock-badge-#{slot}"}
                  class={[
                    "rounded border px-2 py-1 font-mono text-[10px]",
                    if(@stocks[slot].low?,
                      do: "border-[#5f292f] bg-[#241114] text-[#ff9ca4]",
                      else: "border-[#293238] text-[#7f8992]"
                    )
                  ]}
                >
                  {label} {@stocks[slot].count}
                </li>
              </ul>
            </section>

            <section id="shiny-guard-card" class="rounded-lg border border-[#232b30] bg-[#111519] p-3">
              <div class="flex min-h-10 items-center gap-3">
                <div class="min-w-0 flex-1">
                  <p class="text-sm font-semibold text-[#d9dde1]">Guarda anti-shiny ✨</p>
                  <p class="mt-0.5 text-[11px] leading-tight text-[#7f8992]">
                    vê a ESTRELA dourada que a lista de batalha põe no shiny — vale pra
                    QUALQUER shiny, e a bola sempre voa (mesmo com captura desligada)
                  </p>
                </div>
                <input
                  type="checkbox"
                  class="toggle toggle-success toggle-sm shrink-0"
                  checked={@shiny_guard_enabled}
                  phx-click="toggle_shiny_guard"
                />
              </div>

              <div class="mt-2 flex flex-wrap items-center gap-2">
                <form
                  id="shiny-cfg-form"
                  phx-change="save_shiny_cfg"
                  class="flex items-center gap-1 font-mono text-[9px] text-[#737d85]"
                >
                  <span>ao ver →</span>
                  <select
                    id="shiny-action"
                    name="shiny_action"
                    class="h-6 rounded border border-[#293238] bg-[#090d0f] px-1 font-mono text-[10px] text-[#dce1e4] focus:border-[#36d47c] focus:outline-none"
                  >
                    <option value="fugir" selected={@shiny_action == "fugir"}>fugir 🏃</option>
                    <option value="alarme" selected={@shiny_action == "alarme"}>
                      lutar (só alarme) ⚔️
                    </option>
                  </select>
                </form>

                <div class="flex min-w-[9rem] flex-1 items-center gap-2">
                  <span class={[
                    "font-mono text-sm font-bold tabular-nums",
                    shiny_px_class(@shiny_star_px, @shiny_star_min_px)
                  ]}>
                    {shiny_px_label(@shiny_star_px)}<span class="text-[9px] font-normal text-[#737d85]">/{@shiny_star_min_px}px</span>
                  </span>
                  <div class="h-1.5 flex-1 overflow-hidden rounded-full bg-[#222a2f]">
                    <div
                      class={[
                        "h-full rounded-full transition-[width]",
                        case shiny_zone(@shiny_star_px, @shiny_star_min_px) do
                          :hit -> "bg-[#ff6b74]"
                          :warn -> "bg-[#f2c45b]"
                          :safe -> "bg-[#37d07d]"
                          :none -> "bg-[#3a4249]"
                        end
                      ]}
                      style={"width: #{shiny_bar_pct(@shiny_star_px, @shiny_star_min_px)}%"}
                    />
                  </div>
                </div>

                <button
                  id="shiny-probe"
                  type="button"
                  phx-click="shiny_probe"
                  title="lê a lista de batalha AGORA e mostra a pontuação da estrela por linha — sem shiny na lista tudo deve ler 0px"
                  class="btn btn-xs h-6 shrink-0 border border-[#293238] bg-transparent px-2 text-[10px] text-[#89939a] hover:text-white"
                >
                  🔬 Sonda
                </button>
              </div>

              <p :if={@shiny_msg} id="shiny-msg" class="mt-1 font-mono text-[9px] text-[#e7ca82]">
                {@shiny_msg}
              </p>

              <div :if={@shiny_log != []} id="shiny-log" class="mt-2">
                <div class="flex items-center justify-between">
                  <p class="font-mono text-[9px] font-bold uppercase tracking-[0.12em] text-[#c9a227]">
                    ✨ shinies encontrados ({length(@shiny_log)})
                  </p>
                  <button
                    phx-click="shiny_log_clear"
                    data-confirm="Apagar o registro de shinies encontrados?"
                    class="cursor-pointer font-mono text-[9px] text-[#68727a] hover:text-[#ff9ca4]"
                  >
                    limpar
                  </button>
                </div>
                <ul class="mt-1 space-y-0.5">
                  <li
                    :for={entry <- Enum.take(@shiny_log, 5)}
                    class="flex items-center gap-2 rounded border border-[#3a3320] bg-[#181509] px-2 py-1 font-mono text-[9px]"
                  >
                    <span class="text-[#c9a227]">✨</span>
                    <span class="text-[#a8b0b7]">{shiny_log_when(entry)}</span>
                    <span class={[
                      "rounded px-1",
                      case entry.outcome do
                        "morto" -> "bg-[#241114] text-[#ff9ca4]"
                        "bola" -> "bg-[#101d24] text-[#7cc0e8]"
                        "fugiu" -> "bg-[#211b0d] text-[#f3ba4e]"
                        _visto -> "bg-[#14191d] text-[#8b949d]"
                      end
                    ]}>
                      {entry.outcome}
                    </span>
                    <span class="text-[#5d6670]">{entry.star_px}px · {entry.action}</span>
                  </li>
                </ul>
              </div>
            </section>

            <section>
              <div class="mb-2 flex items-center justify-between px-0.5">
                <h2 class="font-mono text-[10px] font-bold uppercase tracking-[0.12em] text-[#69737b]">
                  Sessão<span
                    :if={session_duration(@session_started_at, @now_ms)}
                    id="session-duration"
                    class="text-[#9aa3aa]"
                  > · {session_duration(@session_started_at, @now_ms)}</span>
                </h2>
                <span class="flex items-center gap-2 font-mono text-[9px] text-[#758089]">
                  <span :if={@session_started_at} id="session-rates">
                    {session_rate(
                      Map.get(merged_counters(@fishing, @combat, @catcher), :fights, 0),
                      @session_started_at,
                      @now_ms
                    )} kills/h · {session_rate(
                      Map.get(merged_counters(@fishing, @combat, @catcher), :captures, 0),
                      @session_started_at,
                      @now_ms
                    )} capturas/h
                  </span>
                  <button
                    type="button"
                    phx-click="toggle_alarm_sound"
                    title={
                      if @alarm_sound,
                        do:
                          "Alarmes sonoros ligados (erro de worker, vida crítica) — clique para silenciar",
                        else: "Alarmes MUDOS — clique para reativar (o feed 🔔 continua registrando)"
                    }
                    class={[
                      "cursor-pointer",
                      if(@alarm_sound,
                        do: "text-[#7d8790] hover:text-[#e8ecef]",
                        else: "text-[#f3ba4e] hover:text-[#ffd27a]"
                      )
                    ]}
                  >
                    <.icon
                      name={if @alarm_sound, do: "hero-bell-alert", else: "hero-bell-slash"}
                      class="size-3.5"
                    />
                  </button>
                </span>
              </div>
              <div class="grid grid-cols-4 gap-1.5">
                <div
                  :for={{label, key, _icon} <- counters()}
                  id={"counter-#{key}"}
                  class="rounded-lg border border-[#232b30] bg-[#111519] px-1 py-2 text-center"
                >
                  <div class="text-base font-bold tabular-nums leading-tight text-[#dce1e4]">
                    {Map.get(merged_counters(@fishing, @combat, @catcher), key, 0)}
                  </div>
                  <div class="mt-0.5 truncate font-mono text-[8px] uppercase tracking-[0.08em] text-[#758089]">
                    {label}
                  </div>
                </div>
              </div>
              <form
                id="stop-conditions-form"
                phx-change="save_stop_conditions"
                title="Condições de parada: ao bater o limite, TUDO para (como o Stop) e o alarme toca; nada religa até você apertar Iniciar. 0 = nunca."
                class="mt-1.5 flex items-center gap-1 px-0.5 font-mono text-[9px] text-[#737d85]"
              >
                <span>🛑 parar após</span>
                <input
                  id="stop-minutes"
                  name="stop_minutes"
                  type="number"
                  min="0"
                  max="999"
                  value={@stop_after_minutes}
                  phx-debounce="500"
                  class="h-6 w-12 rounded border border-[#293238] bg-[#090d0f] px-1 text-center font-mono text-[10px] text-[#dce1e4] focus:border-[#36d47c] focus:outline-none"
                />
                <span>min ·</span>
                <input
                  id="stop-kills"
                  name="stop_kills"
                  type="number"
                  min="0"
                  max="9999"
                  value={@stop_after_kills}
                  phx-debounce="500"
                  class="h-6 w-14 rounded border border-[#293238] bg-[#090d0f] px-1 text-center font-mono text-[10px] text-[#dce1e4] focus:border-[#36d47c] focus:outline-none"
                />
                <span>kills (0 = nunca)</span>
              </form>
              <form
                id="stagnation-form"
                phx-change="save_stagnation"
                title="Anti-estagnação: sessão rodando mas sem NENHUM kill nem fisgada pela janela toda = bot travado (água vazia, detector preso). Alarme re-toca a cada janela de silêncio; Parar usa a mesma trava do Stop. 0 = desligado."
                class="mt-1 flex items-center gap-1 px-0.5 font-mono text-[9px] text-[#737d85]"
              >
                <span>😴 sem atividade por</span>
                <input
                  id="stagnation-minutes"
                  name="stagnation_minutes"
                  type="number"
                  min="0"
                  max="999"
                  value={@stagnation_minutes}
                  phx-debounce="500"
                  class="h-6 w-12 rounded border border-[#293238] bg-[#090d0f] px-1 text-center font-mono text-[10px] text-[#dce1e4] focus:border-[#36d47c] focus:outline-none"
                />
                <span>min →</span>
                <select
                  id="stagnation-action"
                  name="stagnation_action"
                  class="h-6 rounded border border-[#293238] bg-[#090d0f] px-1 font-mono text-[10px] text-[#dce1e4] focus:border-[#36d47c] focus:outline-none"
                >
                  <option value="alarme" selected={@stagnation_action == "alarme"}>alarme</option>
                  <option value="parar" selected={@stagnation_action == "parar"}>parar tudo</option>
                </select>
              </form>
            </section>

            <section class="overflow-hidden rounded-lg border border-[#232b30] bg-[#111519]">
              <div class="flex h-10 items-center justify-between border-b border-[#222a2f] px-3">
                <h2 class="font-mono text-[10px] font-bold uppercase tracking-[0.12em] text-[#9099a1]">
                  O que ele está fazendo
                </h2>
                <label class="flex cursor-pointer items-center gap-2 font-mono text-[10px] text-[#79838b]"><input
                  type="checkbox"
                  class="toggle toggle-success toggle-xs"
                  checked={@show_debug}
                  phx-click="toggle_debug"
                /> debug</label>
              </div>
              <div class="flex items-center gap-1 border-b border-[#222a2f] px-3 py-1.5">
                <button
                  :for={source <- feed_sources()}
                  phx-click="filter_feed"
                  phx-value-source={source}
                  class={[
                    "rounded-md px-1.5 py-0.5 text-[11px] transition",
                    if(@feed_filter == source,
                      do: "bg-[#17231c] ring-1 ring-[#37d07d]",
                      else: "opacity-50 hover:opacity-100"
                    )
                  ]}
                >
                  {source}
                </button>
                <span :if={@feed_filter} class="ml-1 font-mono text-[9px] text-[#79838b]">
                  só {@feed_filter} — clique de novo pra limpar
                </span>
              </div>
              <p
                :if={@export_msg}
                class="border-b border-[#222a2f] px-3 py-1.5 text-[10px] text-[#37d07d]"
              >
                {@export_msg}
                <a :if={@export_src} href={@export_src} download class="underline">baixar</a>
              </p>
              <div
                id="activity-feed"
                class="h-64 overflow-y-auto p-3 font-mono text-[10px] leading-relaxed text-[#9aa3aa] xl:h-[30rem]"
              >
                <p
                  :if={visible_logs(@logs, @show_debug, @feed_filter) == []}
                  class="max-w-[300px] text-[#59636b]"
                >
                  a atividade aparece aqui quando o bot roda<br />(marque "debug" pra ver cada tick)
                </p>
                <p
                  :for={entry <- visible_logs(@logs, @show_debug, @feed_filter)}
                  class={["flex gap-1.5", log_class(entry.level)]}
                >
                  <span class="shrink-0 text-[#59636b]">{entry.at}</span><span>{entry.source}</span><span>{entry.text}</span>
                </p>
              </div>
              <div class="grid grid-cols-2 border-t border-[#222a2f]">
                <button
                  class="h-9 border-r border-[#222a2f] text-[11px] text-[#858f97] hover:bg-[#171c20] hover:text-white"
                  phx-click="export_events"
                >Exportar</button><button
                  class="h-9 text-[11px] text-[#858f97] hover:bg-[#171c20] hover:text-white"
                  phx-click="clear_logs"
                >Limpar</button>
              </div>
            </section>

            <details
              id="advanced-panel"
              class="group overflow-hidden rounded-lg border border-[#232b30] bg-[#101418]"
            >
              <summary class="flex h-11 cursor-pointer list-none items-center justify-between px-3 text-xs font-semibold [&::-webkit-details-marker]:hidden">
                <span class="flex items-center gap-2"><.icon
                  name="hero-wrench-screwdriver"
                  class="size-3.5 text-[#758089]"
                /> Avançado &amp; calibragem</span><.icon
                  name="hero-chevron-down"
                  class="size-3.5 text-[#68727a] transition group-open:rotate-180"
                />
              </summary>
              <div class="space-y-5 border-t border-[#232b30] p-3">
                <section>
                  <div class="flex items-center justify-between">
                    <h3 class="text-xs font-semibold">Captura de tela</h3><button
                      class="flex h-8 items-center gap-1.5 rounded-lg border border-[#293238] px-3 font-mono text-[10px] text-[#89939a] hover:text-white"
                      phx-click="read_capture_stats"
                    ><.icon name="hero-arrow-path" class="size-3" /> Medir</button>
                  </div>
                  <div :if={@capture_info} class="mt-2 space-y-1 font-mono text-[10px]">
                    <p class="text-[#9aa3aa]">
                      backend:
                      <span class={
                        if @capture_info.backend.backend == :screen_capture_kit,
                          do: "text-[#3de083]",
                          else: "text-[#e0b43d]"
                      }>
                        {if @capture_info.backend.backend == :screen_capture_kit,
                          do: "ScreenCaptureKit (rápido)",
                          else: "screencapture CLI (lento — fallback)"}
                      </span>
                      <span :if={@capture_info.backend.recovering?} class="text-[#79838b]">
                        · tentando recuperar o SCK…
                      </span>
                    </p>
                    <p :if={@capture_info.stats == []} class="text-[#69737b]">
                      sem capturas na última janela — ligue um bot e clique Medir de novo
                    </p>
                    <p :for={{key, stat} <- @capture_info.stats} class="text-[#79838b]">
                      {String.replace_prefix(key, "capture.backend.", "")} · n={stat.count}
                      <span :if={stat.total > 0}>
                        avg={Float.round(stat.total / stat.count, 1)}ms max={stat.max}ms
                      </span>
                    </p>
                  </div>
                </section>

                <section class="grid gap-4 border-t border-[#232b30] pt-4">
                  <div>
                    <h3 class="text-xs font-semibold">Sensibilidade do brilho</h3><p class="mt-0.5 text-[10px] text-[#78828a]">
                      Valor sugerido pela calibração.
                    </p><form id="threshold-form" phx-submit="save_threshold" class="mt-2 flex gap-2">
                      <input
                        name="threshold"
                        value={@threshold}
                        placeholder="sugerido"
                        class="input input-bordered h-10 min-w-0 flex-1 bg-[#090d0f] font-mono text-sm"
                      /><button class="btn btn-outline h-10 border-[#303940] px-4 text-xs">Salvar</button>
                    </form>
                  </div>
                  <div>
                    <h3 class="text-xs font-semibold">Ordem das skills</h3><p class="mt-0.5 text-[10px] text-[#78828a]">
                      Prioridade de ataque, as mais fortes primeiro.
                    </p><form id="skills-form" phx-submit="save_skills" class="mt-2 flex gap-2">
                      <input
                        name="skills"
                        value={@skill_order}
                        placeholder="1 2 3"
                        class="input input-bordered h-10 min-w-0 flex-1 bg-[#090d0f] font-mono text-sm"
                      /><button class="btn btn-outline h-10 border-[#303940] px-4 text-xs">Salvar</button>
                    </form>
                  </div>
                </section>

                <section class="border-t border-[#232b30] pt-4">
                  <h3 class="text-xs font-semibold">Timing do combate</h3><p class="mt-0.5 text-[10px] text-[#78828a]">
                    Ajuste fino da velocidade de busca e de morte.
                  </p>
                  <form
                    id="timing-form"
                    phx-submit="save_timing"
                    class="mt-3 grid grid-cols-2 gap-2.5"
                  >
                    <label
                      :for={{key, label, _hint} <- timing_fields()}
                      class="block font-mono text-[9px] text-[#7d8790]"
                    ><span>{label}</span><input
                      type="number"
                      min={if(positive_timing_key?(key), do: "1", else: "0")}
                      name={key}
                      value={@timing[key]}
                      class="input input-bordered mt-1 h-9 w-full bg-[#090d0f] font-mono text-xs"
                    /></label>
                    <button class="col-span-2 mt-1 h-10 rounded-lg bg-[#37d07d] text-xs font-bold text-[#06140c] hover:bg-[#45dd88]">Salvar timing</button>
                  </form>
                </section>

                <section :if={@calibrated?} class="border-t border-[#232b30] pt-4">
                  <h3 class="text-xs font-semibold">Prints &amp; diagnóstico</h3><p class="mt-0.5 text-[10px] text-[#78828a]">
                    Gera um JSON com tudo que o bot enxerga para diagnosticar sem foto.
                  </p>
                  <div class="mt-2 flex flex-wrap gap-2">
                    <button
                      :for={
                        {label, region} <- [
                          {"Tela cheia", "screen"},
                          {"Água", "glow"},
                          {"Batalha", "battle"},
                          {"Arena", "arena"},
                          {"Skills", "skills"}
                        ]
                      }
                      class="h-8 rounded-lg border border-[#2b353b] px-3 text-[10px] text-[#a3abb1] hover:border-[#37d07d]/60"
                      phx-click="shot"
                      phx-value-region={region}
                    >{label}</button>
                  </div>
                  <button
                    class="mt-3 h-10 w-full rounded-lg border border-[#30cf75] text-xs font-bold text-[#38dc80] hover:bg-[#102019]"
                    phx-click="export_diagnostic"
                  >Exportar diagnóstico (JSON)</button>
                  <figure :if={@capture_src} class="mt-3">
                    <figcaption class="mb-1 text-[10px] text-[#7d8790]">{@capture_label}</figcaption><img
                      src={@capture_src}
                      class="max-h-64 rounded-lg border border-[#283138]"
                    />
                  </figure>
                  <p
                    :if={@capture_label && is_nil(@capture_src)}
                    class="mt-2 text-[10px] text-[#ff929b]"
                  >
                    {@capture_label}
                  </p>
                  <div
                    :if={@report}
                    class="mt-3 rounded-lg border border-[#263038] bg-[#090d0f] p-3 text-[10px] text-[#89939a]"
                  >
                    <div class="flex justify-between">
                      <span class="font-semibold text-[#37d07d]">{@report_msg}</span><a
                        :if={@report_src}
                        href={@report_src}
                        download
                        class="text-[#37d07d] underline"
                      >baixar JSON</a>
                    </div>
                    <% matrix = gi(@report, [:regions, :battle_body, :matrix]) %>
                    <div :if={matrix} class="mt-3">
                      <p class="mb-1">matriz do painel Batalha ({matrix.cols}×{matrix.rows})</p><div
                        class="inline-grid gap-px rounded border border-[#263038] bg-black p-1"
                        style={"grid-template-columns: repeat(#{matrix.cols}, 8px)"}
                      >
                        <div
                          :for={cell <- List.flatten(matrix.cells)}
                          class="size-2"
                          style={cell_style(cell)}
                          title={to_string(cell.class)}
                        />
                      </div>
                    </div>
                  </div>
                </section>

                <nav class="grid grid-cols-3 gap-2 border-t border-[#232b30] pt-4 text-center text-[10px]">
                  <.link
                    navigate={~p"/calibration"}
                    class="rounded-lg border border-[#293238] px-2 py-2 hover:text-[#37d07d]"
                  >Calibração</.link><.link
                    navigate={~p"/diagnostics"}
                    class="rounded-lg border border-[#293238] px-2 py-2 hover:text-[#37d07d]"
                  >Diagnóstico</.link><.link
                    navigate={~p"/fishing-lab"}
                    class="rounded-lg border border-[#293238] px-2 py-2 hover:text-[#37d07d]"
                  >Laboratório</.link>
                </nav>
              </div>
            </details>

            <div class="flex items-start gap-2 rounded-lg border border-[#6b2b32] bg-[#241114] px-3 py-3 text-[10px] leading-relaxed text-[#f0a0a7]">
              <.icon name="hero-hand-raised" class="mt-0.5 size-4 shrink-0 text-[#ffbf51]" /><p>
                <strong>Botão de pânico:</strong>
                jogue o mouse no canto superior-esquerdo e o bot para na hora.
              </p>
            </div>
          </div>
        </main>
      </div>
    </Layouts.app>
    """
  end
end
