defmodule PokexWeb.PanelLive do
  use PokexWeb, :live_view

  alias Pokex.Bots.{BotSupervisor, Catcher, Combat, Fishing, PlayerSupport, SkillBar}
  alias Pokex.Bots.Cavebot
  alias Pokex.Diagnostics.Report
  alias PokexWeb.{HeaderState, PanelForms, PositionReadout}
  alias Pokex.{Calibration, Rig, Settings}

  @fishing_topic "fishing"
  @combat_topic "combat"
  @catcher_topic "catcher"
  @mini_game_topic "mini_game"
  @game_topic "game"
  @body_topic "body"
  @cooldown_poll_ms 1000

  # A fonte da caçada no feed, definida UMA VEZ e referenciada nos dois lugares
  # que precisam dela (a linha de log e a lista de chips do filtro). O filtro
  # compara a fonte por igualdade EXATA de binário, então um emoji digitado duas
  # vezes é um bug esperando acontecer: 🗺️ é U+1F5FA + U+FE0F (variation
  # selector) e sobrevive a um copiar-e-colar como U+1F5FA sozinho — visualmente
  # igual, binário diferente, chip que filtra um feed vazio. 🧭 (U+1F9ED) não tem
  # variação nenhuma, e mesmo assim o literal só existe aqui.
  @cavebot_source "🧭"

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
      Phoenix.PubSub.subscribe(Pokex.PubSub, Cavebot.Worker.topic())
      Phoenix.PubSub.subscribe(Pokex.PubSub, "shiny")
      Phoenix.PubSub.subscribe(Pokex.PubSub, Pokex.Layout.Sentinel.topic())
      Phoenix.PubSub.subscribe(Pokex.PubSub, Pokex.Bots.StockAlerts.topic())
      Phoenix.PubSub.subscribe(Pokex.PubSub, Pokex.Combos.Runner.topic())
      Phoenix.PubSub.subscribe(Pokex.PubSub, Pokex.Bots.Logout.topic())
      Phoenix.PubSub.subscribe(Pokex.PubSub, Pokex.Journal.topic())
      # feeds only capture while someone is attached — a watching page IS a
      # consumer, so :team and :minimap run exactly while they are looked at
      Pokex.Perception.DisplayFeeds.attach_all()
      Phoenix.PubSub.subscribe(Pokex.PubSub, Pokex.Perception.topic())
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
       cavebot: status.cavebot,
       minimap_reads: 0,
       minimap_misses: 0,
       errors: [],
       calibrated?: Calibration.exists?(),
       calib_stale?: calib_stale?(),
       layout_lost?: false,
       stocks: %{},
       world: Pokex.World.snapshot(),
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
       stop_after_action: Settings.get(:stop_after_action),
       logout: safe_logout_status(),
       last_order: safe_last_order(),
       escape_direction: Settings.get(:escape_direction),
       escape_steps: Settings.get(:escape_steps),
       escape_walk_wait_ms: Settings.get(:escape_walk_wait_ms),
       player_mode: Settings.get(:player_mode),
       skill_order: Enum.join(Settings.get(:skill_keys), " "),
       loot_enabled: Settings.get(:loot_enabled),
       capture_enabled: Settings.get(:capture_enabled),
       panicked?: false,
       logs: journal_seed(),
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
       shiny_star_run: nil,
       shiny_star_min_columns: Settings.get(:shiny_star_min_columns),
       shiny_log: Pokex.Pokedex.ShinyLog.entries(),
       potion_pct: Settings.get(:pokemon_hp_potion_pct),
       potion_cooldown_s: div(Settings.get(:potion_cooldown_ms), 1000),
       hook_skills: Enum.join(Settings.get(:hook_skill_keys), " "),
       presets: Settings.list_presets(),
       mode_overrides: mode_override_keys(),
       combos: Pokex.Combos.Store.all(),
       combos_enabled: Settings.get(:combos_enabled),
       combo_skip: combo_skip(),
       preset_msg: nil
     )}
  end

  defp start_bots(socket) do
    case BotSupervisor.start_all() do
      :ok ->
        status = BotSupervisor.status()

        socket
        |> HeaderState.sync_workers(status)
        |> assign(
          errors: [],
          logs: journal_seed(),
          panicked?: false,
          calib_stale?: calib_stale?(),
          session_started_at: session_started_at(),
          fishing: status.fishing,
          combat: status.combat,
          catcher: status.catcher,
          mini_game: status.mini_game,
          game: status.player_support,
          cavebot: status.cavebot
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
      presets: Settings.list_presets(),
      # the bundle keys whose value in force is NOT what the mode promises —
      # each one gets a "manual" badge instead of silently disagreeing
      mode_overrides: mode_override_keys()
    )
  end

  defp build_trigger("species", value), do: {:enemy_species, String.trim(value || "")}
  defp build_trigger(_element, value), do: {:enemy_element, String.trim(value || "")}

  # An empty dungeon field means "vale em todas" — the combo stays global.
  defp build_dungeon(value) do
    case String.trim(value || "") do
      "" -> nil
      dungeon -> dungeon
    end
  end

  # The runner keeps the last refusal, so a panel opened after the fight still
  # learns why nothing happened.
  defp combo_skip do
    Pokex.Combos.Runner.status().last_skip
  catch
    _kind, _reason -> nil
  end

  # Who is in the hotkeys RIGHT NOW, read from the screen. Only these can be
  # swap targets: a row with no portrait could be anyone, and a row with no C+N
  # label has no key to press.
  defp team_names(%{team: rows}) when is_list(rows) do
    rows
    |> Enum.filter(&(is_binary(&1[:name]) and is_integer(&1[:slot])))
    |> Enum.map(& &1.name)
    |> Enum.uniq()
  end

  defp team_names(_no_world), do: []

  defp mode_override_keys do
    Settings.get(:player_mode)
    |> Pokex.Modes.overrides()
    |> Enum.map(&elem(&1, 0))
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
       socket
       |> alarm_on_error(:fishing, snapshot)
       |> assign(fishing: snapshot, panicked?: false, last_order: safe_last_order())}

  def handle_info({:combat, snapshot}, socket),
    do:
      {:noreply,
       socket
       |> alarm_on_error(:combat, snapshot)
       |> assign(combat: snapshot, panicked?: false, last_order: safe_last_order())}

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

    # the same 1s cadence keeps the world card honest when a fact goes stale
    # without anything new being published
    socket = assign(socket, world: Pokex.World.snapshot())

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

  # A game is sitting there waiting for a HUMAN, and every worker is held while
  # it does — so this repeats until the overlay is gone. Muting silences it, the
  # same switch that mutes the enter/leave chirp.
  def handle_info({:mini_game_alert, %{text: text}}, socket) do
    socket =
      if Settings.get(:mini_game_sound),
        do: push_event(socket, "mini-game-transition", %{transition: :entered, state: :playing}),
        else: socket

    {:noreply, append_log(socket, %{level: :macro, source: "🎮", text: text})}
  end

  # --- a caçada (cavebot) -----------------------------------------------------
  #
  # O worker já emitia as três mensagens; o painel é que não escutava. A caçada
  # morria em ~6s "sem dizer nada" porque nada do que ela dizia chegava aqui.
  def handle_info({:cavebot, snapshot}, socket),
    do: {:noreply, assign(socket, cavebot: snapshot, last_order: safe_last_order())}

  # Bloqueio: entra no MESMO pipeline de alarme do {:rule_alarm, _} e do
  # {:panic, _} — linha :macro no feed, som (se não estiver mudo) e o anti-spam
  # por tipo. A chave inclui o motivo: dois bloqueios diferentes são dois fatos,
  # e o segundo não pode ser engolido pelo intervalo do primeiro.
  def handle_info({:cavebot_alarm, reason}, socket),
    do: {:noreply, alarm(socket, {:cavebot, reason}, cavebot_alarm_text(reason))}

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
  def handle_info({:shiny_reading, %{star_run: px, min_px: min_px}}, socket),
    do: {:noreply, assign(socket, shiny_star_run: px, shiny_star_min_columns: min_px)}

  # O FEED vem do journal (Frente 4): os logs dos workers chegam normalizados,
  # com repeats deduplicado, e o mount ressemeia o histórico — recarregar a
  # página parou de apagar a história. Alarmes de regra/sistema NÃO entram por
  # aqui: eles seguem no pipeline de alarme (som + anti-spam) que também
  # escreve no feed — entrar pelos dois caminhos duplicaria a linha.
  def handle_info({:journal_event, %{source: source} = event}, socket)
      when source not in [:regra, :sistema],
      do: {:noreply, merge_log(socket, journal_entry(event))}

  def handle_info({:journal_event, _alarme}, socket), do: {:noreply, socket}

  # A confirmed sighting: refresh the trophy shelf so the encounter shows up.
  def handle_info({:shiny_seen, _info}, socket),
    do: {:noreply, assign(socket, shiny_log: Pokex.Pokedex.ShinyLog.entries())}

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

  # A combo that MATCHED and could not run — the difference between "nenhum combo
  # casou" and "o combo casou e falhou", which used to look identical.
  def handle_info({:combo_skipped, skip}, socket),
    do: {:noreply, assign(socket, combo_skip: skip)}

  def handle_info({:combo_started, _info}, socket),
    do: {:noreply, assign(socket, combo_skip: nil)}

  def handle_info({:combo_done, _info}, socket), do: {:noreply, socket}
  def handle_info({:combo_aborted, _info}, socket), do: {:noreply, socket}

  # The minimap publishes on EVERY capture, readable coordinate or not (`pos:
  # nil` IS the miss) — counting its publishes is the only place the good/bad
  # ratio can come from, since the fact itself is overwritten and keeps no
  # history. It is what turns "a posição está velha" into "ele quase nunca
  # consegue ler".
  def handle_info({:world, :minimap, obs}, socket) do
    socket =
      if Map.get(obs, :pos) == nil,
        do: assign(socket, minimap_misses: socket.assigns.minimap_misses + 1),
        else: assign(socket, minimap_reads: socket.assigns.minimap_reads + 1)

    {:noreply, assign(socket, world: Pokex.World.snapshot())}
  end

  # Any world fact moving re-reads the snapshot — the blackboard is the truth,
  # and re-assembling it is a handful of ETS lookups.
  def handle_info({:world, _key, _obs}, socket),
    do: {:noreply, assign(socket, world: Pokex.World.snapshot())}

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

  def handle_info({:logout, snapshot}, socket), do: {:noreply, assign(socket, logout: snapshot)}

  # A REDE DE SEGURANÇA, e ela faltava: sem esta cláusula, a primeira mensagem
  # de um tópico novo derruba a LiveView inteira com FunctionClauseError. Não é
  # hipótese — o painel assina nove tópicos, e o mais novo deles (a caçada) fala
  # exatamente no pior momento possível: no bloqueio, quando ele está olhando pra
  # tela pra descobrir o que houve. Ignorar o desconhecido é sempre melhor do que
  # levar o painel junto.
  def handle_info(_msg, socket), do: {:noreply, socket}

  # Each log entry is a map {level, source, text, at}; the feed keeps the last
  # 200 (newest first) so it stays light, and macro vs debug lets the UI hide
  # the per-tick chatter by default. `at` is local (Mac) wall-clock HH:MM:SS.
  defp append_log(socket, entry) do
    entry = Map.put(entry, :at, timestamp())
    assign(socket, logs: Enum.take([entry | socket.assigns.logs], 200))
  end

  # O histórico ressemeado do journal no mount — é isto que faz o reload parar
  # de apagar a história. Journal fora do ar (teste isolado) → feed vazio.
  defp journal_seed do
    Pokex.Journal.recent(limit: 200) |> Enum.map(&journal_entry/1)
  catch
    :exit, _reason -> []
  end

  defp journal_entry(event) do
    %{
      level: event.severity,
      source: journal_emoji(event.source),
      text: event.text,
      at: format_wall(event.at),
      repeats: event.repeats
    }
  end

  # O journal já deduplicou chatter em repeats: quando o evento do topo é o
  # MESMO (origem+texto), troca a linha em vez de empilhar.
  defp merge_log(socket, %{source: source, text: text} = entry) do
    logs =
      case socket.assigns.logs do
        [%{source: ^source, text: ^text} | rest] -> [entry | rest]
        logs -> Enum.take([entry | logs], 200)
      end

    assign(socket, logs: logs)
  end

  defp journal_emoji(:fishing), do: "🎣"
  defp journal_emoji(:combat), do: "⚔️"
  defp journal_emoji(:catcher), do: "🎯"
  defp journal_emoji(:mini_game), do: "🎮"
  defp journal_emoji(:suporte), do: "🚑"
  defp journal_emoji(:body), do: "🧤"
  defp journal_emoji(:cavebot), do: @cavebot_source
  defp journal_emoji(:regra), do: "⏰"
  defp journal_emoji(:sistema), do: "🛑"
  defp journal_emoji(_outro), do: "•"

  defp format_wall(ms) do
    {_, {h, m, s}} = :calendar.system_time_to_local_time(ms, :millisecond)
    :io_lib.format(~c"~2..0B:~2..0B:~2..0B", [h, m, s]) |> List.to_string()
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
    BotSupervisor.stop_all("reinício pra recarregar a calibração")
    {:noreply, start_bots(socket)}
  end

  def handle_event("stop", _params, socket) do
    BotSupervisor.stop_all("Parar (painel)")
    status = BotSupervisor.status()

    {:noreply,
     socket
     |> HeaderState.sync_workers(status)
     |> assign(
       calib_stale?: false,
       last_order: safe_last_order(),
       fishing: status.fishing,
       combat: status.combat,
       catcher: status.catcher,
       mini_game: status.mini_game,
       game: status.player_support,
       cavebot: status.cavebot
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

    socket =
      case params["stop_after_action"] do
        action when action in ["parar", "deslogar"] ->
          Settings.put(:stop_after_action, action)
          assign(socket, stop_after_action: action)

        _invalid ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("logout_now", _params, socket) do
    safe_logout_request()
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
        action when action in ["alarme", "parar", "deslogar"] ->
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

  # Switching mode REAPPLIES that mode's defaults, discarding any exception made
  # under the previous one. The button says so; hiding it would leave him with a
  # bot quietly doing something the mode does not promise.
  def handle_event("set_player_mode", %{"mode" => mode}, socket) do
    case Pokex.Modes.apply!(mode) do
      :ok ->
        Catcher.Worker.mode_changed()

        {:noreply,
         socket
         |> assign(player_mode: mode)
         |> refresh_setting_assigns()}

      {:error, :unknown_mode} ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_combos_enabled", _params, socket) do
    value = not Settings.get(:combos_enabled)
    Settings.put(:combos_enabled, value)
    {:noreply, assign(socket, combos_enabled: value)}
  end

  def handle_event("toggle_combo", %{"name" => name}, socket) do
    enabled? = Enum.find_value(socket.assigns.combos, &(&1.name == name and &1.enabled?))
    :ok = Pokex.Combos.Store.set_enabled(name, not enabled?)
    {:noreply, assign(socket, combos: Pokex.Combos.Store.all())}
  end

  def handle_event("delete_combo", %{"name" => name}, socket) do
    :ok = Pokex.Combos.Store.delete(name)
    {:noreply, assign(socket, combos: Pokex.Combos.Store.all())}
  end

  # The builder writes the shape Lucas described: swap somebody in, use a skill,
  # then bring back whoever answers this enemy. The waits are the tuned settings,
  # not numbers typed into a form.
  def handle_event("save_combo", params, socket) do
    steps =
      [
        {:swap_member, params["member"]},
        {:wait, :combo_swap_wait_ms},
        {:skill, String.trim(params["skill"] || "")},
        {:wait, :combo_sing_wait_ms}
      ] ++ if(params["counter"], do: [{:swap_counter}], else: [])

    combo = %Pokex.Combos.Combo{
      name: String.trim(params["name"] || ""),
      trigger: build_trigger(params["trigger_kind"], params["trigger_value"]),
      steps: steps,
      dungeon: build_dungeon(params["dungeon"])
    }

    case Pokex.Combos.Store.add(combo) do
      :ok -> {:noreply, assign(socket, combos: Pokex.Combos.Store.all())}
      {:error, :invalid_name} -> {:noreply, socket}
    end
  end

  def handle_event("restore_mode_defaults", _params, socket) do
    :ok = Pokex.Modes.apply!(socket.assigns.player_mode)
    Catcher.Worker.mode_changed()
    {:noreply, refresh_setting_assigns(socket)}
  end

  def handle_event("toggle_loot_enabled", _params, socket) do
    value = not Settings.get(:loot_enabled)
    Settings.put(:loot_enabled, value)
    {:noreply, assign(socket, loot_enabled: value)}
  end

  # capture and reposition are the two keys the MODE has an opinion about, so
  # flipping them by hand may create an exception — recompute the badges.
  def handle_event("toggle_capture_enabled", _params, socket) do
    value = not Settings.get(:capture_enabled)
    Settings.put(:capture_enabled, value)
    Catcher.Worker.mode_changed()
    {:noreply, assign(socket, capture_enabled: value, mode_overrides: mode_override_keys())}
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
    {:noreply, assign(socket, reposition_enabled: value, mode_overrides: mode_override_keys())}
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

        {"sonda: colunas douradas por linha " <>
           Enum.map_join(Enum.with_index(clusters), " · ", fn {run, i} -> "L#{i}: #{run}" end) <>
           " (limiar #{settings[:shiny_star_min_columns]} colunas)", best}
      else
        error -> {"sonda falhou: #{inspect(error)}", nil}
      end

    {:noreply, assign(socket, shiny_msg: msg, shiny_star_run: px)}
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
      |> Enum.filter(fn {key, _v} ->
        # backend = quanto o SO demorou; espera = quanto o LEITOR ficou na fila
        # antes de ser atendido (Frente 3, Etapa 1) — é a espera, não o backend,
        # que afogou o combate ao vivo (2026-07-29). As duas lado a lado dizem
        # quem está sofrendo e por causa de quê.
        String.starts_with?(key, "capture.backend.") or
          String.starts_with?(key, "capture.espera:")
      end)
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

  # O Logout global fica inerte na suíte (:logout_active), então nem o mount nem
  # o botão podem depender de o processo responder — um call pra processo ausente
  # derrubaria a página inteira.
  # A resposta de "quem parou, por quê, há quanto tempo" — o critério de aceite
  # da Frente 1. O Session registra a ordem; aqui só se mostra. Session fora do
  # ar (teste isolado, boot parcial) → sem linha, nunca uma página caída.
  defp safe_last_order do
    Pokex.Bots.Session.last_order()
  catch
    :exit, _reason -> nil
  end

  defp last_order_line(nil), do: nil

  defp last_order_line(%{kind: :hold, at: at}),
    do: "pausado por foco perdido #{ago(at)} — retoma sozinho ao voltar pro jogo"

  defp last_order_line(%{kind: :stop, reason: reason, at: at}),
    do: "parado #{ago(at)} — #{reason || "sem motivo registrado"}"

  # :start com a frota PARADA = um Iniciar que falhou no preflight (a ordem foi
  # dada, os workers não subiram) — dizer isso é melhor que fingir que não houve
  defp last_order_line(%{kind: :start, at: at}),
    do: "um Iniciar #{ago(at)} não vingou (preflight?) — veja o alarme acima"

  defp last_order_line(_desconhecido), do: nil

  defp ago(at) do
    min = div(System.monotonic_time(:millisecond) - at, 60_000)

    cond do
      min < 1 -> "agora há pouco"
      min == 1 -> "há 1min"
      min < 120 -> "há #{min}min"
      true -> "há #{div(min, 60)}h"
    end
  end

  defp safe_logout_status do
    Pokex.Bots.Logout.status()
  catch
    :exit, _reason ->
      %{
        state: :idle,
        reason: nil,
        attempt: 0,
        attempts: 0,
        error: nil,
        finished_at: nil,
        duplicates: 0
      }
  end

  defp safe_logout_request do
    Pokex.Bots.Logout.request("manual (painel)")
  catch
    :exit, _reason -> :ok
  end

  # O painel nunca diz "deslogado" por omissão: cada estado tem seu texto, e a
  # falha diz POR QUE falhou.
  defp logout_label(%{state: :idle}), do: "nenhum logout ainda"

  defp logout_label(%{state: :pressing, attempt: n, attempts: total}),
    do: "apertando… tentativa #{n}/#{total}"

  defp logout_label(%{state: :verifying, attempt: n, attempts: total}),
    do: "conferindo a tela… tentativa #{n}/#{total}"

  defp logout_label(%{state: :out, reason: motivo}), do: "deslogado — #{motivo}"

  defp logout_label(%{state: :failed, error: erro, reason: motivo}),
    do: "FALHOU (#{erro}) — #{motivo}"

  defp logout_label(_desconhecido), do: "—"

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

  # Emoji + NOME, porque um botão cujo conteúdo inteiro é um emoji não tem
  # rótulo acessível nenhum — e porque o nome também vira o texto do "só X" e o
  # title. O emoji continua sendo o valor comparado no filtro, digitado UMA vez
  # aqui (o da caçada nem isso: vem de @cavebot_source).
  @feed_sources [
    {"🎣", "pesca"},
    {"⚔️", "batalha"},
    {"🎮", "mini game"},
    {"🎯", "captura"},
    {"🚑", "suporte"},
    {"🧤", "corpo"},
    {@cavebot_source, "caçada"},
    {"🔔", "alarmes"}
  ]

  defp feed_sources, do: @feed_sources

  defp feed_source_name(source) do
    case List.keyfind(@feed_sources, source, 0) do
      {_source, name} -> name
      nil -> source
    end
  end

  defp visible_logs(logs, show_debug, source_filter) do
    Enum.filter(logs, fn entry ->
      (show_debug or entry.level == :macro) and
        (source_filter == nil or entry.source == source_filter)
    end)
  end

  # "text-pk-title-content" esteve aqui: uma substituição em massa de classes
  # comeu o `text-base-content` do daisyUI e cuspiu um nome que não existe em
  # lugar nenhum do repositório. As linhas de log macro ficaram sem cor e nenhum
  # teste percebeu — classe inexistente não quebra, só some.
  #
  # E `opacity-50` compunha 1.64:1 com o timestamp: ilegível. Um nível de texto
  # já apagado não precisa ficar meio transparente por cima.
  defp log_class(:macro), do: "text-pk-body font-semibold text-pk-text"
  defp log_class(_debug), do: "text-pk-meta text-pk-text-3"

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

  # 🧭 Caçada (cavebot): anda a rota e cede a vez pro combate quando aparece
  # inimigo. Os três estados de PARADA têm nomes distintos de propósito — "não
  # anda" tem causas diferentes, e cada uma tem um conserto diferente.
  defp cavebot_label(:idle), do: "parado"
  defp cavebot_label(:walking), do: "andando"
  defp cavebot_label(:fighting), do: "lutando"
  defp cavebot_label(:post_fight), do: "pós-luta"
  defp cavebot_label(:stuck), do: "travado"
  defp cavebot_label(:fight_stalled), do: "luta travada"
  defp cavebot_label(:blocked), do: "bloqueado"
  defp cavebot_label(:ocupado), do: "ocupado"
  defp cavebot_label(other), do: to_string(other)

  defp cavebot_counters(%{counters: %{waypoints: waypoints, steps: steps}}),
    do: "#{waypoints} wp · #{steps} passos"

  defp cavebot_counters(_no_counters), do: nil

  # Onde ele está na rota, em uma linha: sem isto o painel dizia "andando" e mais
  # nada — e "andando" há dez minutos no mesmo waypoint parece igualzinho a
  # "andando" progredindo.
  defp cavebot_route_line(%{route: nil}), do: nil

  defp cavebot_route_line(%{route: route, wp_index: index, wp_total: total} = snapshot) do
    progress = "rota \"#{route}\" · wp #{index + 1}/#{total}"

    case Map.get(snapshot, :distance_tiles) do
      %{dx: dx, dy: dy} -> "#{progress} · faltam #{dx},#{dy} tiles (x,y)"
      _no_distance -> progress
    end
  end

  defp cavebot_route_line(_no_route), do: nil

  # O texto do alarme de bloqueio. Diz o que aconteceu E o que isso custou: um
  # bloqueio PERIGOSO parou a frota inteira, um LOCAL parou só a caçada — e a
  # diferença é a primeira coisa que ele quer saber. A linha sai com a fonte
  # 🔔 (é alarme), então leva o 🧭 no texto pra se identificar — e mesmo aqui o
  # emoji vem da constante, nunca de um literal repetido.
  defp cavebot_alarm_text(reason), do: "#{@cavebot_source} #{cavebot_block_text(reason)}"

  defp cavebot_block_text(:floor_changed),
    do: "caçada BLOQUEADA: mudou de andar — a rota é de outro andar, parei tudo"

  defp cavebot_block_text(:combat_preflight_failed),
    do: "caçada BLOQUEADA: o combate recusou o arranque — parei tudo"

  defp cavebot_block_text(:stuck),
    do: "caçada parada: travado, sem sair do lugar (o resto da frota segue)"

  defp cavebot_block_text(:fight_stalled),
    do: "caçada parada: a luta não termina (o resto da frota segue)"

  defp cavebot_block_text(reason), do: "caçada parada: #{inspect(reason)}"

  attr :testid, :string, required: true
  attr :name, :string, required: true
  attr :state, :atom, required: true
  attr :active?, :boolean, required: true
  attr :tone, :string, default: "bg-pk-ok"
  attr :label, :string, required: true
  attr :counters, :string, default: nil
  attr :snapshot, :map, required: true
  attr :now_ms, :integer, required: true
  attr :title, :string, default: nil
  # Uma linha neutra de contexto, do lado do 🔒 do hold_reason mas sem a cor de
  # aviso: hoje é a rota/waypoint da caçada, que não cabe na linha do estado (e
  # que, truncada, perde justamente o número que interessa).
  attr :detail, :string, default: nil
  slot :aside

  # One worker, one row: dot, name, what it is doing, what it did last, and — on
  # its own full-width line — WHY it is holding back.
  #
  # This used to be five near-identical cards in a 3-column grid, which left the
  # fifth card orphaned and gave each status line ~240px. MEASURED at Lucas's
  # window width (2026-07-22): the support line needed 248px inside that box, so
  # it was already cut with the SHORTEST counters it can print. A row spans the
  # whole column, so the state — the reason the row exists — never truncates.
  defp worker_row(assigns) do
    ~H"""
    <div
      data-testid={@testid}
      data-state={@state}
      title={@title}
      class="border-b border-pk-line px-3 py-2 last:border-b-0"
    >
      <%!-- min-h keeps every row the same height whether or not it carries a
            control, so the column of dots reads as one straight line --%>
      <div class="flex min-h-5 items-center gap-2">
        <span class={[
          "size-1.5 shrink-0 rounded-full",
          if(@active?, do: @tone, else: "bg-pk-text-3")
        ]} />
        <span class="w-[4.5rem] shrink-0 text-pk-body font-semibold text-pk-text">{@name}</span>
        <%!-- sentence case, no letter-spacing: the uppercase + 0.1em treatment this
              replaced cost 15% of the width (248px vs 212px, measured) and was what
              pushed these lines past their box --%>
        <span class="min-w-0 flex-1 text-pk-body text-pk-text-2">
          {@label}<span :if={@counters} class="pk-num text-pk-text-3">{" · " <> @counters}</span>
        </span>
        <span
          :if={last_action_text(@snapshot, @now_ms)}
          title={last_action_text(@snapshot, @now_ms)}
          class="hidden max-w-[15rem] shrink-0 truncate text-pk-meta text-pk-text-3 sm:block"
        >
          ⚡ {last_action_text(@snapshot, @now_ms)}
        </span>
        {render_slot(@aside)}
      </div>
      <p :if={@detail} class="mt-1 pl-[1.125rem] text-pk-meta text-pk-text-2">
        {@detail}
      </p>
      <%!-- the lock is the most useful line on the panel (it says why nothing is
            happening), so it gets the full width instead of a truncated sliver --%>
      <p
        :if={Map.get(@snapshot, :hold_reason)}
        class="mt-1 pl-[1.125rem] text-pk-meta text-pk-warn"
      >
        🔒 {Map.get(@snapshot, :hold_reason)}
      </p>
    </div>
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

  # --- world card (the blackboard, where he is already looking) ---------------

  # "—" for a value we do not have YET, never "?". A question mark reads as a
  # broken field; an em-dash reads as "nada lido ainda", which is the truth: the
  # feeds fail OPEN, so an unread value is normal, not an error.
  @unknown "—"

  defp world_num(nil), do: @unknown
  defp world_num(value), do: to_string(value)

  defp world_hp(nil), do: @unknown
  defp world_hp({current, max}), do: "#{current}/#{max}"

  defp world_pct(nil), do: @unknown
  defp world_pct(fraction), do: "#{round(fraction * 100)}%"

  defp world_enemies(%{enemies: [], shiny?: false}), do: "livre"
  defp world_enemies(%{enemies: [], shiny?: true}), do: "✨ SHINY"

  defp world_enemies(%{enemies: enemies, shiny?: shiny?}) do
    names = Enum.map_join(enemies, ", ", &(&1[:name] || "sem nome"))
    if shiny?, do: "✨ " <> names, else: names
  end

  defp hp_bar_class(nil), do: "bg-pk-line-strong"
  defp hp_bar_class(pct) when pct >= 0.5, do: "bg-pk-ok"
  defp hp_bar_class(pct) when pct >= 0.25, do: "bg-pk-warn"
  defp hp_bar_class(_low), do: "bg-pk-danger"

  defp team_chip_class(nil), do: "border-pk-line-strong text-pk-text-3"
  defp team_chip_class(pct) when pct >= 0.5, do: "border-pk-line-strong text-pk-text-2"
  defp team_chip_class(pct) when pct >= 0.25, do: "border-pk-warn-line text-pk-warn"
  defp team_chip_class(_low), do: "border-pk-danger-line bg-pk-danger-dim text-pk-danger"

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

  defp shiny_log_when(_entry), do: @unknown

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
      :hit -> "text-pk-danger"
      :warn -> "text-pk-warn"
      :safe -> "text-pk-ok"
      :none -> "text-pk-text-3"
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

  # What "Iniciar" will actually bring up, spelled out under the button.
  #
  # These say what each worker DOES, not what the code calls it. Lucas read
  # "suporte" under the movimento button and concluded the bot would not heal or
  # revive him while walking. It does — the word just told him nothing.
  defp mode_worker_labels(mode) do
    mode
    |> Pokex.Modes.workers()
    |> Enum.map(&worker_job/1)
    |> Enum.join(" · ")
  end

  defp worker_job(:fishing), do: "pesca"
  defp worker_job(:combat), do: "luta"
  defp worker_job(:catcher), do: "saque e captura"
  defp worker_job(:mini_game), do: "mini game"
  defp worker_job(:player_support), do: "revive e poção"
  defp worker_job(:cavebot), do: "anda a rota e luta"

  defp worker_name(:player_support), do: "suporte"
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
  # is the "no action yet" sentinel, handled above). The same wording the
  # position readout uses, from the same function: two age formats on one screen
  # would read as two different clocks.
  defp format_age(ms), do: PositionReadout.age_text(ms)

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp active?(state), do: BotSupervisor.active?(state)

  defp toggle_worker(socket, key, worker) do
    current = Map.fetch!(socket.assigns, key)
    result = if active?(current.state), do: worker.halt(), else: worker.run()

    case result do
      :ok -> {:noreply, assign(socket, key, worker.status())}
      {:error, messages} when is_list(messages) -> {:noreply, assign(socket, errors: messages)}
      {:error, reason} -> {:noreply, assign(socket, errors: [inspect(reason)])}
    end
  end

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
  attr :detail, :string, default: nil
  attr :override, :boolean, default: false

  defp automation_row(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "flex min-h-12 items-center gap-3 border-b border-pk-line px-3 py-2 last:border-b-0",
        @active && "bg-pk-ok-dim"
      ]}
    >
      <span class={[
        "h-7 w-0.5 shrink-0 rounded-full",
        if(@active, do: "bg-pk-ok", else: "bg-transparent")
      ]} />
      <div class="min-w-0 flex-1">
        <p class="flex items-center gap-1.5 text-pk-body font-semibold text-pk-text">
          <span class="truncate">{@title}</span>
          <%!-- YOUR exception to what the mode promises. Without this, the mode and
                the switch can disagree and only the bot knows which won. --%>
          <span
            :if={@override}
            data-testid="override-badge"
            class="shrink-0 rounded border border-pk-warn-line bg-pk-warn-dim px-1 font-mono text-pk-meta text-pk-warn"
            title="Você mudou esta chave: ela não está no padrão do modo."
          >
            manual
          </span>
        </p>
        <%!-- the description WRAPS instead of truncating: a sentence cut mid-word
              ("segura a fisga se o Pokémon está com pou…") tells him less than no
              sentence at all. The long-form explanation still lives in the tooltip. --%>
        <p class="mt-0.5 text-pk-body leading-tight text-pk-text-2" title={@detail}>
          {@description}
        </p>
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

  attr :label, :string, required: true
  attr :accent, :string, required: true
  attr :note, :string, default: nil
  attr :badge, :string, default: nil

  # The header has to carry the SCOPE, not whisper it: which of these switches
  # apply to the mode you are in is the whole reason the groups exist, and a
  # side-note in 11px grey lost that argument (Lucas, 2026-07-22: "não tá muito
  # claro que isso são pontos gerais"). So the scope is a full sentence on its
  # own line, under a label that is no longer a mono-caps whisper.
  defp group_header(assigns) do
    ~H"""
    <div class="flex items-start gap-2 border-y border-pk-line bg-pk-sunken px-3 py-2 first:border-t-0">
      <span class={["mt-1 h-3 w-0.5 shrink-0 rounded-full", @accent]} />
      <div class="min-w-0 flex-1">
        <p class="text-pk-body font-semibold text-pk-text-2">{@label}</p>
        <p :if={@note} class="text-pk-meta text-pk-text-3">{@note}</p>
      </div>
      <span
        :if={@badge}
        class="shrink-0 rounded border border-pk-line-strong px-1.5 py-0.5 font-mono text-pk-meta text-pk-text-3"
      >
        {@badge}
      </span>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_page={:panel}
      {Layouts.header(assigns)}
      max_width="max-w-[520px] xl:max-w-[1600px]"
    >
      <%!-- TWO columns, always: three was tested on his 3440×1440 and read as
           noise. Left is Comando (what the bot does), right is Percepção e ajustes. --%>
      <div
        id="panel-dashboard"
        class="space-y-3 xl:grid xl:grid-cols-2 xl:items-start xl:gap-4 xl:space-y-0"
      >
        <div class="min-w-0 space-y-3">
          <div class="min-w-0 space-y-3">
            <div
              :if={not @calibrated?}
              class="flex items-center gap-3 rounded-lg border border-pk-warn-line bg-pk-warn-dim p-3 text-pk-body"
            >
              <.icon name="hero-exclamation-triangle" class="size-5 shrink-0 text-pk-warn" />
              <p class="flex-1 text-pk-text">
                Calibre água, Battle, arena e skills antes de iniciar.
              </p>
              <.link navigate={~p"/calibration"} class="font-semibold text-pk-ok">Calibrar</.link>
            </div>

            <div
              :if={@layout_lost?}
              id="layout-banner"
              class="flex items-center gap-3 rounded-lg border border-pk-danger-line bg-pk-danger-dim p-3 text-pk-body"
            >
              <.icon name="hero-eye-slash" class="size-5 shrink-0 text-pk-danger" />
              <p class="flex-1 text-pk-text">
                Não achei o HUD na tela — o jogo está em tela cheia no monitor principal? Os
                feeds estão segurando: nada é lido nem clicado às cegas.
              </p>
            </div>

            <div
              :if={@calib_stale?}
              id="calib-stale-banner"
              class="flex items-center gap-3 rounded-lg border border-pk-warn-line bg-pk-warn-dim p-3 text-pk-body"
            >
              <.icon name="hero-exclamation-triangle" class="size-5 shrink-0 text-pk-warn" />
              <p class="flex-1 text-pk-text">
                A calibração mudou depois do último Start — os bots ainda usam a ANTIGA.
              </p>
              <button
                phx-click="restart_bots"
                class="btn btn-xs border border-pk-ok-line bg-transparent font-semibold text-pk-ok hover:bg-pk-ok-dim"
              >
                Parar e Iniciar
              </button>
            </div>

            <%!-- The five workers as ROWS in one card: a 3-column grid left the
                 fifth card orphaned, and every row here gets the full column width,
                 so the state never has to be truncated to fit. --%>
            <div class="overflow-hidden rounded-lg border border-pk-line bg-pk-surface">
              <.worker_row
                testid="fishing-pill"
                name="Pesca"
                state={@fishing.state}
                active?={active?(@fishing.state)}
                label={fishing_label(@fishing.state)}
                snapshot={@fishing}
                now_ms={@now_ms}
              />
              <.worker_row
                testid="combat-pill"
                name="Batalha"
                state={@combat.state}
                active?={active?(@combat.state)}
                label={combat_label(@combat.state, Map.get(@combat, :locked_row))}
                snapshot={@combat}
                now_ms={@now_ms}
              />
              <.worker_row
                testid="catcher-pill"
                name="Captura"
                state={@catcher.state}
                active?={active?(@catcher.state)}
                label={catcher_label(@catcher.state)}
                counters={"#{catcher_captures(@catcher)} bola · #{catcher_loots(@catcher)} saque"}
                snapshot={@catcher}
                now_ms={@now_ms}
              />
              <.worker_row
                testid="mini-game-pill"
                name="Mini game"
                state={@mini_game.state}
                active?={@mini_game.state == :playing}
                tone="bg-pk-warn"
                label={mini_game_label(@mini_game.state)}
                counters={@mini_game[:mode_label]}
                title={"confiança #{round((@mini_game.confidence || 0) * 100)}%"}
                snapshot={@mini_game}
                now_ms={@now_ms}
              >
                <:aside>
                  <button
                    type="button"
                    phx-click="toggle_mini_game_sound"
                    title={
                      if @mini_game_sound,
                        do: "Alerta sonoro ligado — clique para silenciar",
                        else: "Alerta sonoro MUDO — clique para reativar"
                    }
                    class={[
                      "flex shrink-0 cursor-pointer",
                      if(@mini_game_sound,
                        do: "text-pk-text-3 hover:text-pk-text",
                        else: "text-pk-warn hover:text-pk-warn"
                      )
                    ]}
                  >
                    <.icon
                      name={if @mini_game_sound, do: "hero-speaker-wave", else: "hero-speaker-x-mark"}
                      class="size-3.5"
                    />
                  </button>
                </:aside>
              </.worker_row>
              <.worker_row
                testid="support-pill"
                name="Suporte"
                state={@game.state}
                active?={@game.state == :monitoring}
                label={support_label(@game.state)}
                counters={"#{rescue_count(@game)} revive · #{potion_count(@game)} poção"}
                title="revive + poção — protege o Pokémon principal, até jogando manual"
                snapshot={@game}
                now_ms={@now_ms}
              />
              <%!-- A caçada é o único worker que ANDA, então é o único que pode
                   parar num lugar onde ninguém foi. Sem esta linha o painel não
                   dizia uma palavra sobre ela: nem rota, nem waypoint, nem por
                   que parou. --%>
              <.worker_row
                testid="cavebot-pill"
                name="Caçada"
                state={@cavebot.state}
                active?={active?(@cavebot.state)}
                label={cavebot_label(@cavebot.state)}
                counters={cavebot_counters(@cavebot)}
                detail={cavebot_route_line(@cavebot)}
                title="anda a rota do cavebot e cede a vez pro combate quando aparece inimigo"
                snapshot={@cavebot}
                now_ms={@now_ms}
              />
            </div>

            <div class="space-y-1">
              <div
                :if={@mini_game[:awaiting_manual?]}
                data-testid="mini-game-manual-banner"
                role="status"
                class="rounded-lg border border-pk-warn-line bg-pk-warn-dim px-3 py-2 text-pk-body text-pk-warn"
              >
                <p class="font-semibold">🎮 {@mini_game[:manual_text]}</p>
                <p class="mt-0.5 text-pk-text-2">
                  Resolva na janela do jogo — pesca, batalha e captura voltam sozinhas
                  quando o overlay sumir.
                  <.link navigate={~p"/mini-game"} class="underline">ver diagnóstico</.link>
                </p>
              </div>
              <p
                :if={@fishing.error}
                class="rounded-lg border border-pk-danger-line bg-pk-danger-dim px-3 py-2 text-pk-body text-pk-danger"
              >
                {@fishing.error}
              </p>
              <p
                :if={@combat.error}
                class="rounded-lg border border-pk-danger-line bg-pk-danger-dim px-3 py-2 text-pk-body text-pk-danger"
              >
                {@combat.error}
              </p>
              <p
                :if={@mini_game.error}
                class="rounded-lg border border-pk-danger-line bg-pk-danger-dim px-3 py-2 text-pk-body text-pk-danger"
              >
                {@mini_game.error}
              </p>
              <p
                :if={@catcher.error}
                class="rounded-lg border border-pk-danger-line bg-pk-danger-dim px-3 py-2 text-pk-body text-pk-danger"
              >
                {@catcher.error}
              </p>
              <p
                :if={@game.error}
                class="rounded-lg border border-pk-danger-line bg-pk-danger-dim px-3 py-2 text-pk-body text-pk-danger"
              >
                {@game.error}
              </p>
              <ul
                :if={@errors != []}
                class="rounded-lg border border-pk-warn-line bg-pk-warn-dim px-3 py-2 text-pk-body text-pk-warn"
              >
                <li :for={message <- @errors}>{message}</li>
              </ul>
            </div>

            <%!-- The MODE is what Iniciar means, so it sits on the button, not buried
                 in a list of eleven switches. Switching reapplies its defaults.

                 ONE control, two halves — not two cards side by side. Two equal
                 cards where one is tinted make the reader compare them to find the
                 difference; a segmented control says "this is a choice, and THIS
                 half is on" before you read a word. The chosen half also carries a
                 check, so the state survives a glance (and colour-blindness). --%>
            <div
              id="mode-picker"
              role="radiogroup"
              aria-label="Modo de jogo"
              class="grid grid-cols-3 gap-1 rounded-lg border border-pk-line-strong bg-pk-sunken p-1"
            >
              <button
                :for={
                  {mode, label, hint, icon} <- [
                    {"parado", "Parado", "pesca no spot", "hero-map-pin"},
                    {"movimento", "Movimento", "você anda, ele briga", "hero-arrow-trending-up"},
                    {"caçada", "Caçada", "ele anda a rota e caça", "hero-map"}
                  ]
                }
                id={"mode-#{mode}"}
                role="radio"
                phx-click="set_player_mode"
                phx-value-mode={mode}
                aria-checked={to_string(@player_mode == mode)}
                aria-pressed={to_string(@player_mode == mode)}
                class={[
                  "flex items-center gap-2 rounded-md px-2.5 py-2 text-left transition",
                  if(@player_mode == mode,
                    do: "bg-pk-ok-dim ring-1 ring-inset ring-pk-ok-line",
                    else: "opacity-70 hover:bg-pk-raised hover:opacity-100"
                  )
                ]}
              >
                <.icon
                  name={icon}
                  class={[
                    "size-4 shrink-0",
                    if(@player_mode == mode, do: "text-pk-ok", else: "text-pk-text-3")
                  ]}
                />
                <span class="min-w-0 flex-1">
                  <span class={[
                    "block truncate text-pk-body font-semibold",
                    if(@player_mode == mode, do: "text-pk-ok", else: "text-pk-text-2")
                  ]}>{label}</span>
                  <span class="block truncate text-pk-meta text-pk-text-3">{hint}</span>
                </span>
                <.icon
                  :if={@player_mode == mode}
                  name="hero-check-circle-solid"
                  class="size-4 shrink-0 text-pk-ok"
                />
              </button>
            </div>

            <div :if={not @bot_active?}>
              <button
                id="start-bot"
                class="flex h-12 w-full items-center justify-center gap-2 rounded-xl bg-pk-ok text-pk-title font-bold text-pk-bg shadow-[0_8px_24px_rgba(57,205,118,0.16)] transition hover:bg-[#45da83] active:scale-[0.99]"
                phx-click="start"
              >
                <.icon name="hero-play-solid" class="size-4" /> Iniciar — modo {@player_mode}
              </button>
              <p id="start-plan" class="mt-1 text-center font-mono text-pk-meta text-pk-text-3">
                liga {mode_worker_labels(@player_mode)}
              </p>
              <p
                :if={last_order_line(@last_order)}
                id="last-order"
                class="mt-1 truncate text-center font-mono text-pk-meta text-pk-text-3"
                title="A última ordem registrada na sessão — quem parou o bot e por quê."
              >
                ⏹ {last_order_line(@last_order)}
              </p>
            </div>
            <button
              :if={@bot_active?}
              id="stop-bot"
              class="flex h-12 w-full items-center justify-center gap-2 rounded-xl border border-[#703136] bg-[#281114] text-pk-title font-bold text-pk-danger transition hover:bg-[#35171b] active:scale-[0.99]"
              phx-click="stop"
            >
              <.icon name="hero-stop-solid" class="size-4" /> Parar bot
            </button>
          </div>

          <div class="min-w-0 space-y-3">
            <details id="automations-panel" open class="group">
              <summary class="mb-2 flex cursor-pointer list-none items-center justify-between px-0.5 font-mono text-pk-meta font-bold uppercase tracking-[0.12em] text-pk-text-3 transition hover:text-pk-text-2 [&::-webkit-details-marker]:hidden">
                <h2 class="flex items-center gap-1.5">
                  Automações
                  <.icon
                    name="hero-chevron-down"
                    class="size-3 text-pk-text-3 transition group-open:rotate-180"
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
              <div class="overflow-hidden rounded-lg border border-pk-line bg-pk-sunken">
                <.group_header
                  label="Valem sempre"
                  accent="bg-[#6c7780]"
                  note="ligam ou desligam nos dois modos, Parado e Movimento"
                />
                <.automation_row
                  id="automation-combat"
                  title="Luta automática"
                  description="ataca com as skills configuradas"
                  active={active?(@combat.state)}
                  event="toggle_combat"
                />
                <.automation_row
                  id="automation-loot"
                  title="Pegar loot (Espaço)"
                  description="Espaço a cada kill"
                  detail="O corpo cai no tile ao lado, onde a luta aconteceu — Espaço alcança ele parado ou andando."
                  active={@loot_enabled}
                  event="toggle_loot_enabled"
                />
                <%!-- Revive e poção NÃO são automações do bot: o monitor de suporte
                     roda sozinho, então protegem o Pokémon nos dois modos e também
                     com todo o resto parado, você jogando na mão. Estavam no mesmo
                     balaio de "luta automática" e isso escondia o ponto. --%>
                <.group_header
                  label="Proteção do Pokémon"
                  accent="bg-[#c9772f]"
                  note="valem nos dois modos — e continuam valendo com o bot parado, você jogando na mão"
                />
                <.automation_row
                  id="automation-rescue"
                  title="Revive automático"
                  description={"revive abaixo de #{@rescue_pct}%"}
                  detail="O monitor de suporte lê a vida sozinho: isso vale mesmo com pesca e batalha desligadas."
                  active={@rescue_enabled}
                  event="toggle_rescue"
                />
                <.automation_row
                  id="automation-potion"
                  title="Poção automática"
                  description={"tecla #{Settings.get(:potion_key)} abaixo de #{@potion_pct}%"}
                  detail="Bebe enquanto você caça; só segura numa luta travada ou quando está tomando dano (a cura é interrompida por dano)."
                  active={@potion_enabled}
                  event="toggle_potion"
                />
                <.automation_row
                  id="automation-support-waits-capture"
                  title="Suporte espera a captura"
                  description="ordem pós-luta: loot → bola → suporte"
                  detail="Poção e reposição só agem quando os corpos foram resolvidos, com teto de 10s pra nunca segurar a cura."
                  active={@support_waits_capture}
                  event="toggle_support_waits_capture"
                />

                <.group_header
                  label="Só no modo Parado"
                  accent="bg-[#1D9E75]"
                  note="desligam sozinhas quando você troca pro Movimento"
                  badge={
                    if @mode_overrides == [],
                      do: "no padrão",
                      else: "#{length(@mode_overrides)} exceção(ões)"
                  }
                />
                <.automation_row
                  id="automation-fishing"
                  title="Pesca automática"
                  description="lança e fisga sozinho"
                  active={active?(@fishing.state)}
                  event="toggle_fishing"
                />
                <.automation_row
                  id="automation-capture"
                  title="Capturar (Pokébola)"
                  description="joga bola nos corpos ao redor"
                  detail="Mira contra uma baseline do chão aprendida parado — por isso não existe em movimento."
                  active={@capture_enabled}
                  override={:capture_enabled in @mode_overrides}
                  event="toggle_capture_enabled"
                />
                <.automation_row
                  id="automation-reposition"
                  title="Reposicionar após lutas"
                  description="clique do meio no tile calibrado"
                  detail="2s depois da luta acabar, volta pro tile de Calibração → Posição do Pokémon. Andando, isso te arrastaria de volta pro spot."
                  active={@reposition_enabled}
                  override={:reposition_enabled in @mode_overrides}
                  event="toggle_reposition"
                />
                <button
                  :if={@player_mode == "parado"}
                  phx-click="relearn_ground"
                  class="mx-3 my-2 flex h-8 items-center gap-1.5 rounded-lg border border-pk-line-strong px-3 font-mono text-pk-meta text-pk-text-2 hover:text-white"
                >
                  <.icon name="hero-arrow-path" class="size-3" /> Reaprender chão (mudou de spot)
                </button>
                <button
                  :if={@mode_overrides != []}
                  id="restore-mode-defaults"
                  phx-click="restore_mode_defaults"
                  class="mx-3 my-2 flex h-8 items-center gap-1.5 rounded-lg border border-pk-warn-line px-3 font-mono text-pk-meta text-pk-warn hover:bg-pk-warn-dim"
                >
                  <.icon name="hero-arrow-uturn-left" class="size-3" /> Restaurar padrão do modo
                </button>
                <.automation_row
                  id="automation-require-cooldowns"
                  title="Só pescar quando dá pra matar"
                  description="segura a fisga até uma skill estar pronta"
                  active={@require_cooldowns}
                  event="toggle_require_cooldowns"
                />
                <form
                  id="hook-skills-form"
                  phx-submit="save_hook_skills"
                  class="border-b border-pk-line px-3 py-2.5"
                >
                  <label for="hook-skills-input" class="font-mono text-pk-meta text-pk-text-3">
                    Skills necessárias pra matar
                  </label>
                  <div class="mt-1.5 flex gap-2">
                    <input
                      id="hook-skills-input"
                      name="hook_skills"
                      value={@hook_skills}
                      placeholder="4 5 6 7"
                      class="input input-bordered h-9 min-w-0 flex-1 bg-pk-bg font-mono text-pk-title"
                    />
                    <button class="btn h-9 border border-pk-ok-line bg-transparent px-4 text-pk-body font-semibold text-pk-ok hover:bg-pk-ok-dim">
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
                <div id="automation-escape" class="border-b border-pk-line px-3 py-2.5">
                  <div class="flex min-h-10 items-center gap-3">
                    <div class="min-w-0 flex-1">
                      <p class="text-pk-title font-semibold text-pk-text">Fuga de emergência</p>
                      <p class="mt-0.5 text-pk-body leading-tight text-pk-text-2">
                        anda até o tile calibrado (Calibração → Escada de fuga), entra na escada
                        de seta, para TUDO e toca o alarme — vai ser o protocolo anti-shiny
                      </p>
                    </div>
                    <button
                      id="test-escape"
                      phx-click="test_escape"
                      data-confirm="Vai CLICAR NO JOGO (no tile calibrado), dar os passos de seta e PARAR todos os bots. Testar a fuga agora?"
                      class="btn btn-xs h-8 shrink-0 border border-pk-warn-line bg-transparent px-3 text-pk-body text-pk-warn hover:bg-pk-warn-dim"
                    >
                      <.icon name="hero-beaker" class="size-3" /> Testar fuga
                    </button>
                  </div>
                  <form
                    id="escape-cfg-form"
                    phx-change="save_escape_cfg"
                    title="Depois do clique no tile, espera o personagem ANDAR até lá e então dá os passos de seta pra dentro da escada."
                    class="mt-1.5 flex flex-wrap items-center gap-1 font-mono text-pk-meta text-pk-text-3"
                  >
                    <span>entra pra</span>
                    <select
                      id="escape-direction"
                      name="escape_direction"
                      aria-label="Direção de entrada na escada"
                      class="h-6 rounded border border-pk-line-strong bg-pk-bg px-1 font-mono text-pk-meta text-pk-text focus:border-pk-ok focus:outline-none"
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
                      aria-label="Quantos passos de seta dar para dentro da escada"
                      min="1"
                      max="10"
                      value={@escape_steps}
                      phx-debounce="500"
                      class="h-6 w-10 rounded border border-pk-line-strong bg-pk-bg px-1 text-center font-mono text-pk-meta text-pk-text focus:border-pk-ok focus:outline-none"
                    />
                    <span>passos · espera a caminhada por</span>
                    <input
                      id="escape-walk-wait"
                      name="escape_walk_wait_ms"
                      type="number"
                      aria-label="Espera pela caminhada até a escada, em milissegundos"
                      min="0"
                      max="10000"
                      step="100"
                      value={@escape_walk_wait_ms}
                      phx-debounce="500"
                      class="h-6 w-14 rounded border border-pk-line-strong bg-pk-bg px-1 text-center font-mono text-pk-meta text-pk-text focus:border-pk-ok focus:outline-none"
                    />
                    <span>ms</span>
                  </form>
                </div>
                <form id="fishing-hp-form" phx-submit="save_fishing_hp_cfg" class="px-3 py-2.5">
                  <label for="fishing-hp-input" class="font-mono text-pk-meta text-pk-text-3">
                    Vida mínima pra puxar a vara (%)
                  </label>
                  <div class="mt-1.5 flex gap-2">
                    <input
                      id="fishing-hp-input"
                      name="fishing_hp_pct"
                      inputmode="numeric"
                      value={@fishing_hp_pct}
                      class="input input-bordered h-9 min-w-0 flex-1 bg-pk-bg font-mono text-pk-title"
                    />
                    <button class="btn h-9 border border-pk-ok-line bg-transparent px-4 text-pk-body font-semibold text-pk-ok hover:bg-pk-ok-dim">
                      Salvar
                    </button>
                  </div>
                </form>
              </div>
            </details>

            <section id="presets-card" class="rounded-lg border border-pk-line bg-pk-surface p-3">
              <div class="flex items-center justify-between text-pk-body font-semibold">
                <span>Presets por Pokémon</span>
                <span class="font-mono text-pk-meta text-pk-text-3">skills · bolas · suporte</span>
              </div>
              <p class="mt-1 text-pk-body leading-tight text-pk-text-2">
                Salva o conjunto atual de skills, captura e suporte com o nome do Pokémon —
                trocar de Pokémon vira um clique.
              </p>
              <form id="preset-save-form" phx-submit="save_preset" class="mt-2 flex gap-2">
                <input
                  name="name"
                  placeholder="ex.: charizard"
                  class="input input-bordered h-9 min-w-0 flex-1 bg-pk-bg font-mono text-pk-title"
                />
                <button class="btn h-9 border border-pk-ok-line bg-transparent px-4 text-pk-body font-semibold text-pk-ok hover:bg-pk-ok-dim">
                  Salvar preset
                </button>
              </form>
              <p :if={@preset_msg} id="preset-msg" class="mt-2 text-pk-body text-pk-warn">
                {@preset_msg}
              </p>
              <ul
                :if={@presets != []}
                id="preset-list"
                class="mt-2 divide-y divide-pk-line overflow-hidden rounded-lg border border-pk-line"
              >
                <li
                  :for={preset <- @presets}
                  class="flex items-center gap-2 bg-pk-sunken px-3 py-2"
                >
                  <div class="min-w-0 flex-1">
                    <p class="truncate text-pk-title font-semibold text-pk-text">{preset.slug}</p>
                    <p class="truncate font-mono text-pk-meta text-pk-text-3">
                      {preset_summary(preset)}
                    </p>
                  </div>
                  <button
                    phx-click="apply_preset"
                    phx-value-slug={preset.slug}
                    class="btn btn-xs h-7 border border-pk-ok-line bg-transparent px-3 text-pk-body font-semibold text-pk-ok hover:bg-pk-ok-dim"
                  >
                    Aplicar
                  </button>
                  <button
                    phx-click="delete_preset"
                    phx-value-slug={preset.slug}
                    data-confirm={"Excluir o preset \"#{preset.slug}\"?"}
                    class="btn btn-xs h-7 border border-pk-danger-line bg-transparent px-2 text-pk-body text-pk-danger hover:bg-pk-danger-dim"
                  >
                    Excluir
                  </button>
                </li>
              </ul>
            </section>

            <section class="rounded-lg border border-pk-line bg-pk-surface p-3">
              <div class="flex items-center justify-between text-pk-body font-semibold">
                <span>Vida do Pokémon principal</span><span class="font-mono text-pk-ok">{hp_label(
                  @game
                )}</span>
              </div>
              <div class="mt-2 h-2 overflow-hidden rounded-full bg-pk-line-strong">
                <div
                  class="h-full rounded-full transition-[width] duration-300"
                  style={hp_bar_style(@game)}
                />
              </div>
              <div class="mt-2 flex items-center justify-between font-mono text-pk-meta text-pk-text-3">
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
                    aria-label="Vida mínima para revive, em por cento"
                    min="1"
                    max="90"
                    value={@rescue_pct}
                    phx-debounce="500"
                    class="h-6 w-12 rounded border border-pk-line-strong bg-pk-bg px-1 text-center font-mono text-pk-meta text-pk-text focus:border-pk-ok focus:outline-none"
                  />
                  <span>% · a cada</span>
                  <input
                    id="rescue-cooldown"
                    name="rescue_cooldown_s"
                    type="number"
                    aria-label="Intervalo mínimo entre revives, em segundos"
                    min="2"
                    max="600"
                    value={@rescue_cooldown_s}
                    phx-debounce="500"
                    class="h-6 w-12 rounded border border-pk-line-strong bg-pk-bg px-1 text-center font-mono text-pk-meta text-pk-text focus:border-pk-ok focus:outline-none"
                  />
                  <span>s</span>
                </form>
                <span>revives: {rescue_count(@game)}</span>
              </div>
              <div class="mt-1.5 flex items-center justify-between font-mono text-pk-meta text-pk-text-3">
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
                    aria-label="Vida mínima para poção, em por cento"
                    min="1"
                    max="99"
                    value={@potion_pct}
                    phx-debounce="500"
                    class="h-6 w-12 rounded border border-pk-line-strong bg-pk-bg px-1 text-center font-mono text-pk-meta text-pk-text focus:border-pk-ok focus:outline-none"
                  />
                  <span>% · a cada</span>
                  <input
                    id="potion-cooldown"
                    name="potion_cooldown_s"
                    type="number"
                    aria-label="Intervalo mínimo entre poções, em segundos"
                    min="1"
                    max="600"
                    value={@potion_cooldown_s}
                    phx-debounce="500"
                    class="h-6 w-12 rounded border border-pk-line-strong bg-pk-bg px-1 text-center font-mono text-pk-meta text-pk-text focus:border-pk-ok focus:outline-none"
                  />
                  <span>s</span>
                </form>
                <span>poções: {potion_count(@game)}</span>
              </div>
              <button
                id="use-potion"
                phx-click="use_potion"
                class="mt-2.5 flex h-9 w-full items-center justify-center gap-1.5 rounded-lg border border-pk-line-strong text-pk-body font-semibold text-pk-text-2 transition hover:border-pk-ok/60 hover:bg-pk-raised hover:text-white active:scale-[0.99]"
              >
                <.icon name="hero-beaker" class="size-3.5" /> Usar poção agora
              </button>

              <div class="mt-3 border-t border-pk-line pt-2.5">
                <div class="flex items-center justify-between">
                  <h3 class="font-mono text-pk-meta font-bold uppercase tracking-[0.12em] text-pk-text-3">
                    Cooldowns das skills
                  </h3>
                  <button
                    class="flex h-6 items-center gap-1 rounded-md border border-pk-line-strong px-2 font-mono text-pk-meta text-pk-text-2 transition hover:text-white"
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
                      "grid size-8 place-items-center rounded-md border font-mono text-pk-body font-bold",
                      if(state == :ready,
                        do: "border-pk-ok-line bg-pk-ok-dim text-pk-ok",
                        else: "border-pk-line-strong bg-pk-raised text-pk-text-3"
                      )
                    ]}
                  >{key}</span>
                  <span :if={is_nil(@cooldowns_states)} class="py-1.5 text-pk-meta text-pk-text-3">
                    Clique em Ler para verificar a barra calibrada.
                  </span>
                </div>
              </div>
            </section>
          </div>
        </div>

        <div class="min-w-0 space-y-3">
          <section
            id="world-card"
            class="rounded-lg border border-pk-line bg-pk-surface p-3"
          >
            <div class="flex items-baseline justify-between">
              <p class="font-mono text-pk-meta font-bold uppercase tracking-[0.12em] text-pk-text-3">
                o que a IA vê
              </p>
              <.link
                navigate={~p"/world"}
                class="font-mono text-pk-meta text-pk-text-3 hover:text-pk-text-2"
              >
                detalhes →
              </.link>
            </div>

            <p
              :if={not @world.layout?}
              class="mt-1 font-mono text-pk-meta text-pk-danger"
            >
              HUD não localizado — nada está sendo lido
            </p>

            <div class="mt-2 grid grid-cols-2 gap-x-3 gap-y-2">
              <div>
                <p class="font-mono text-pk-meta uppercase text-pk-text-3">Pokémon ativo</p>
                <p class="font-mono text-pk-title text-pk-text">
                  {world_hp(@world.me.pokemon_hp)}
                  <span
                    :if={Pokex.World.pokemon_hp_pct(@world)}
                    class="text-pk-body text-pk-text-2"
                  >
                    {world_pct(Pokex.World.pokemon_hp_pct(@world))}
                  </span>
                </p>
                <div class="mt-1 h-1 overflow-hidden rounded-full bg-pk-line">
                  <div
                    class={[
                      "h-full rounded-full transition-[width]",
                      hp_bar_class(Pokex.World.pokemon_hp_pct(@world))
                    ]}
                    style={"width: #{round((Pokex.World.pokemon_hp_pct(@world) || 0) * 100)}%"}
                  />
                </div>
              </div>

              <div>
                <p class="font-mono text-pk-meta uppercase text-pk-text-3">Level · pesca</p>
                <p class="font-mono text-pk-title text-pk-text">
                  {world_num(@world.me.level)} · {world_num(@world.me.fishing)}
                </p>
                <p class="mt-1 font-mono text-pk-meta text-pk-text-3">
                  comida {world_num(@world.me.food)}
                </p>
              </div>

              <%!-- Ele acompanha a posição o tempo todo pra conferir se o bot sabe
                   onde está, então o número sozinho não basta: vem com a IDADE e
                   com a frase que separa "não estou lendo" de "estou lendo, e
                   você está aqui" — um "—" mudo não dizia qual dos dois era. --%>
              <div id="world-position" class="col-span-2">
                <p class="font-mono text-pk-meta uppercase text-pk-text-3">Posição</p>
                <p class="font-mono text-pk-body text-pk-text">
                  {PositionReadout.coords(@world.pos)}
                </p>
                <p class={[
                  "font-mono text-pk-meta",
                  PositionReadout.note_class(@world.pos, @world.pos_age_ms)
                ]}>
                  {PositionReadout.note(@world.pos, @world.pos_age_ms)}
                </p>
                <p id="world-read-health" class="font-mono text-pk-meta text-pk-text-3">
                  {PositionReadout.read_health(@minimap_reads, @minimap_misses)}
                </p>
              </div>

              <div>
                <p class="font-mono text-pk-meta uppercase text-pk-text-3">Batalha</p>
                <p class={[
                  "font-mono text-pk-body",
                  if(@world.shiny?, do: "text-pk-warn", else: "text-pk-text")
                ]}>
                  {world_enemies(@world)}
                </p>
              </div>
            </div>

            <div class="mt-2 border-t border-pk-line pt-2">
              <p class="font-mono text-pk-meta uppercase text-pk-text-3">Estoques</p>
              <ul class="mt-1 flex flex-wrap gap-1.5">
                <li
                  :for={{slot, label, _setting} <- Pokex.Bots.StockAlerts.slots()}
                  id={"stock-badge-#{slot}"}
                  class={[
                    "rounded border px-2 py-0.5 font-mono text-pk-meta",
                    if(@stocks[slot] && @stocks[slot].low?,
                      do: "border-pk-danger-line bg-pk-danger-dim text-pk-danger",
                      else: "border-pk-line-strong text-pk-text-2"
                    )
                  ]}
                >
                  {label} {world_num(@world.inventory[slot])}
                </li>
              </ul>
            </div>

            <div :if={@world.team != []} class="mt-2 border-t border-pk-line pt-2">
              <p class="font-mono text-pk-meta uppercase text-pk-text-3">Time</p>
              <ul class="mt-1 flex flex-wrap gap-1.5">
                <li
                  :for={row <- @world.team}
                  class={[
                    "rounded border px-2 py-0.5 font-mono text-pk-meta",
                    team_chip_class(row.hp_pct)
                  ]}
                >
                  C+{row.slot} {world_pct(row.hp_pct)}
                </li>
              </ul>
            </div>
          </section>

          <PokexWeb.Panel.CombosCard.combos_card
            combos={@combos}
            enabled={@combos_enabled}
            skip={@combo_skip}
            team={team_names(@world)}
          />

          <section id="shiny-guard-card" class="rounded-lg border border-pk-line bg-pk-surface p-3">
            <div class="flex min-h-10 items-center gap-3">
              <div class="min-w-0 flex-1">
                <p class="text-pk-title font-semibold text-pk-text">Guarda anti-shiny ✨</p>
                <p class="mt-0.5 text-pk-body leading-tight text-pk-text-2">
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
                class="flex items-center gap-1 font-mono text-pk-meta text-pk-text-3"
              >
                <span>ao ver →</span>
                <select
                  id="shiny-action"
                  name="shiny_action"
                  aria-label="O que fazer ao ver um shiny"
                  class="h-6 rounded border border-pk-line-strong bg-pk-bg px-1 font-mono text-pk-meta text-pk-text focus:border-pk-ok focus:outline-none"
                >
                  <option value="fugir" selected={@shiny_action == "fugir"}>fugir 🏃</option>
                  <option value="alarme" selected={@shiny_action == "alarme"}>
                    lutar (só alarme) ⚔️
                  </option>
                </select>
              </form>

              <div class="flex min-w-[9rem] flex-1 items-center gap-2">
                <span class={[
                  "font-mono text-pk-title font-bold tabular-nums",
                  shiny_px_class(@shiny_star_run, @shiny_star_min_columns)
                ]}>
                  {shiny_px_label(@shiny_star_run)}<span class="text-pk-meta font-normal text-pk-text-3">/{@shiny_star_min_columns} col</span>
                </span>
                <div class="h-1.5 flex-1 overflow-hidden rounded-full bg-pk-line">
                  <div
                    class={[
                      "h-full rounded-full transition-[width]",
                      case shiny_zone(@shiny_star_run, @shiny_star_min_columns) do
                        :hit -> "bg-pk-danger"
                        :warn -> "bg-pk-warn"
                        :safe -> "bg-pk-ok"
                        :none -> "bg-pk-line-strong"
                      end
                    ]}
                    style={"width: #{shiny_bar_pct(@shiny_star_run, @shiny_star_min_columns)}%"}
                  />
                </div>
              </div>

              <button
                id="shiny-probe"
                type="button"
                phx-click="shiny_probe"
                title="lê a lista de batalha AGORA e mostra a pontuação da estrela por linha — sem shiny na lista tudo deve ler 0px"
                class="btn btn-xs h-6 shrink-0 border border-pk-line-strong bg-transparent px-2 text-pk-meta text-pk-text-2 hover:text-white"
              >
                🔬 Sonda
              </button>
            </div>

            <p :if={@shiny_msg} id="shiny-msg" class="mt-1 font-mono text-pk-meta text-pk-warn">
              {@shiny_msg}
            </p>

            <div :if={@shiny_log != []} id="shiny-log" class="mt-2">
              <div class="flex items-center justify-between">
                <p class="font-mono text-pk-meta font-bold uppercase tracking-[0.12em] text-[#c9a227]">
                  ✨ shinies encontrados ({length(@shiny_log)})
                </p>
                <button
                  phx-click="shiny_log_clear"
                  data-confirm="Apagar o registro de shinies encontrados?"
                  class="cursor-pointer font-mono text-pk-meta text-pk-text-3 hover:text-pk-danger"
                >
                  limpar
                </button>
              </div>
              <ul class="mt-1 space-y-0.5">
                <li
                  :for={entry <- Enum.take(@shiny_log, 5)}
                  class="flex items-center gap-2 rounded border border-[#3a3320] bg-[#181509] px-2 py-1 font-mono text-pk-meta"
                >
                  <span class="text-[#c9a227]">✨</span>
                  <span class="text-[#a8b0b7]">{shiny_log_when(entry)}</span>
                  <span class={[
                    "rounded px-1",
                    case entry.outcome do
                      "morto" -> "bg-pk-danger-dim text-pk-danger"
                      "bola" -> "bg-[#101d24] text-[#7cc0e8]"
                      "fugiu" -> "bg-pk-warn-dim text-pk-warn"
                      _visto -> "bg-pk-raised text-pk-text-2"
                    end
                  ]}>
                    {entry.outcome}
                  </span>
                  <span class="text-pk-text-3">{entry.star_px}px · {entry.action}</span>
                </li>
              </ul>
            </div>
          </section>

          <section>
            <div class="mb-2 flex items-center justify-between px-0.5">
              <h2 class="font-mono text-pk-meta font-bold uppercase tracking-[0.12em] text-pk-text-3">
                Sessão<span
                  :if={session_duration(@session_started_at, @now_ms)}
                  id="session-duration"
                  class="text-pk-text-2"
                > · {session_duration(@session_started_at, @now_ms)}</span>
              </h2>
              <span class="flex items-center gap-2 font-mono text-pk-meta text-pk-text-3">
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
                      do: "text-pk-text-3 hover:text-pk-text",
                      else: "text-pk-warn hover:text-pk-warn"
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
                class="rounded-lg border border-pk-line bg-pk-surface px-1 py-2 text-center"
              >
                <div class="text-pk-title font-bold tabular-nums leading-tight text-pk-text">
                  {Map.get(merged_counters(@fishing, @combat, @catcher), key, 0)}
                </div>
                <div class="mt-0.5 truncate font-mono text-pk-meta uppercase tracking-[0.08em] text-pk-text-3">
                  {label}
                </div>
              </div>
            </div>
            <form
              id="stop-conditions-form"
              phx-change="save_stop_conditions"
              title="Condições de parada: ao bater o limite, TUDO para (como o Stop) e o alarme toca; nada religa até você apertar Iniciar. 0 = nunca."
              class="mt-1.5 flex items-center gap-1 px-0.5 font-mono text-pk-meta text-pk-text-3"
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
                class="h-6 w-12 rounded border border-pk-line-strong bg-pk-bg px-1 text-center font-mono text-pk-meta text-pk-text focus:border-pk-ok focus:outline-none"
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
                class="h-6 w-14 rounded border border-pk-line-strong bg-pk-bg px-1 text-center font-mono text-pk-meta text-pk-text focus:border-pk-ok focus:outline-none"
              />
              <span>kills (0 = nunca) →</span>
              <select
                id="stop-after-action"
                name="stop_after_action"
                class="h-6 rounded border border-pk-line-strong bg-pk-bg px-1 font-mono text-pk-meta text-pk-text focus:border-pk-ok focus:outline-none"
              >
                <option value="parar" selected={@stop_after_action == "parar"}>parar tudo</option>
                <option value="deslogar" selected={@stop_after_action == "deslogar"}>
                  deslogar
                </option>
              </select>
            </form>
            <form
              id="stagnation-form"
              phx-change="save_stagnation"
              title="Anti-estagnação: sessão rodando mas sem NENHUM kill nem peixe (minigame vencido) pela janela toda = bot travado. Fisgada não conta enquanto o vigia do minigame está ligado: com o minigame travado a vara fisga a noite toda sem pegar nada. Alarme re-toca a cada janela; Parar usa a trava do Stop; Deslogar encerra a conta — o único que economiza estamina."
              class="mt-1 flex items-center gap-1 px-0.5 font-mono text-pk-meta text-pk-text-3"
            >
              <span>😴 sem atividade por</span>
              <input
                id="stagnation-minutes"
                name="stagnation_minutes"
                type="number"
                aria-label="Minutos sem progresso até agir"
                min="0"
                max="999"
                value={@stagnation_minutes}
                phx-debounce="500"
                class="h-6 w-12 rounded border border-pk-line-strong bg-pk-bg px-1 text-center font-mono text-pk-meta text-pk-text focus:border-pk-ok focus:outline-none"
              />
              <span>min →</span>
              <select
                id="stagnation-action"
                name="stagnation_action"
                class="h-6 rounded border border-pk-line-strong bg-pk-bg px-1 font-mono text-pk-meta text-pk-text focus:border-pk-ok focus:outline-none"
              >
                <option value="alarme" selected={@stagnation_action == "alarme"}>alarme</option>
                <option value="parar" selected={@stagnation_action == "parar"}>parar tudo</option>
                <option value="deslogar" selected={@stagnation_action == "deslogar"}>
                  deslogar
                </option>
              </select>
            </form>
            <div class="mt-1 flex items-center gap-2 px-0.5">
              <button
                type="button"
                phx-click="logout_now"
                title="Encerra a sessão no jogo (Ctrl+Q + Enter), para tudo e confere na tela se saiu mesmo. Parar o bot não economiza estamina; deslogar economiza."
                class="h-6 shrink-0 rounded border border-pk-line-strong px-2 font-mono text-pk-meta text-pk-text-2 hover:border-pk-warn hover:text-pk-warn focus:outline-none focus-visible:outline focus-visible:outline-2 focus-visible:outline-pk-warn"
              >
                🚪 Deslogar agora
              </button>
              <span class="truncate font-mono text-pk-meta text-pk-text-3">
                {logout_label(@logout)}
              </span>
            </div>
          </section>

          <section class="overflow-hidden rounded-lg border border-pk-line bg-pk-surface">
            <div class="flex h-10 items-center justify-between border-b border-pk-line px-3">
              <h2 class="font-mono text-pk-meta font-bold uppercase tracking-[0.12em] text-pk-text-2">
                O que ele está fazendo
              </h2>
              <label class="flex cursor-pointer items-center gap-2 font-mono text-pk-meta text-pk-text-3"><input
                type="checkbox"
                class="toggle toggle-success toggle-xs"
                checked={@show_debug}
                phx-click="toggle_debug"
              /> debug</label>
            </div>
            <div class="flex items-center gap-1 border-b border-pk-line px-3 py-1.5">
              <button
                :for={{source, name} <- feed_sources()}
                phx-click="filter_feed"
                phx-value-source={source}
                aria-label={"Só as linhas de #{name}"}
                aria-pressed={to_string(@feed_filter == source)}
                title={name}
                class={[
                  "rounded-md px-1.5 py-0.5 text-pk-body transition",
                  if(@feed_filter == source,
                    do: "bg-pk-ok-dim ring-1 ring-pk-ok",
                    else: "opacity-50 hover:opacity-100"
                  )
                ]}
              >
                {source}
              </button>
              <span :if={@feed_filter} class="ml-1 font-mono text-pk-meta text-pk-text-3">
                só {feed_source_name(@feed_filter)} — clique de novo pra limpar
              </span>
            </div>
            <p
              :if={@export_msg}
              class="border-b border-pk-line px-3 py-1.5 text-pk-meta text-pk-ok"
            >
              {@export_msg}
              <a :if={@export_src} href={@export_src} download class="underline">baixar</a>
            </p>
            <div
              id="activity-feed"
              class="h-64 overflow-y-auto p-3 font-mono text-pk-meta leading-relaxed text-pk-text-2 xl:h-[30rem]"
            >
              <p
                :if={visible_logs(@logs, @show_debug, @feed_filter) == []}
                class="max-w-[300px] text-pk-text-3"
              >
                a atividade aparece aqui quando o bot roda<br />(marque "debug" pra ver cada tick)
              </p>
              <p
                :for={entry <- visible_logs(@logs, @show_debug, @feed_filter)}
                class={["flex gap-1.5", log_class(entry.level)]}
              >
                <span class="shrink-0 text-pk-text-3">{entry.at}</span><span>{entry.source}</span><span>{entry.text}</span>
                <span
                  :if={Map.get(entry, :repeats, 1) > 1}
                  class="shrink-0 rounded bg-pk-raised px-1 text-pk-text-3"
                  title="a mesma linha repetiu — deduplicada pelo journal"
                >
                  ×{entry.repeats}
                </span>
              </p>
            </div>
            <div class="grid grid-cols-2 border-t border-pk-line">
              <button
                class="h-9 border-r border-pk-line text-pk-body text-pk-text-2 hover:bg-pk-raised hover:text-white"
                phx-click="export_events"
              >Exportar</button><button
                class="h-9 text-pk-body text-pk-text-2 hover:bg-pk-raised hover:text-white"
                phx-click="clear_logs"
              >Limpar</button>
            </div>
          </section>

          <details
            id="advanced-panel"
            class="group overflow-hidden rounded-lg border border-pk-line bg-pk-sunken"
          >
            <summary class="flex h-11 cursor-pointer list-none items-center justify-between px-3 text-pk-body font-semibold [&::-webkit-details-marker]:hidden">
              <span class="flex items-center gap-2"><.icon
                name="hero-wrench-screwdriver"
                class="size-3.5 text-pk-text-3"
              /> Avançado &amp; calibragem</span><.icon
                name="hero-chevron-down"
                class="size-3.5 text-pk-text-3 transition group-open:rotate-180"
              />
            </summary>
            <div class="space-y-5 border-t border-pk-line p-3">
              <section>
                <div class="flex items-center justify-between">
                  <h3 class="text-pk-body font-semibold">Captura de tela</h3><button
                    class="flex h-8 items-center gap-1.5 rounded-lg border border-pk-line-strong px-3 font-mono text-pk-meta text-pk-text-2 hover:text-white"
                    phx-click="read_capture_stats"
                  ><.icon name="hero-arrow-path" class="size-3" /> Medir</button>
                </div>
                <div :if={@capture_info} class="mt-2 space-y-1 font-mono text-pk-meta">
                  <p class="text-pk-text-2">
                    backend:
                    <span class={
                      if @capture_info.backend.backend == :screen_capture_kit,
                        do: "text-pk-ok",
                        else: "text-[#e0b43d]"
                    }>
                      {if @capture_info.backend.backend == :screen_capture_kit,
                        do: "ScreenCaptureKit (rápido)",
                        else: "screencapture CLI (lento — fallback)"}
                    </span>
                    <span :if={@capture_info.backend.recovering?} class="text-pk-text-3">
                      · tentando recuperar o SCK…
                    </span>
                  </p>
                  <p :if={@capture_info.stats == []} class="text-pk-text-3">
                    sem capturas na última janela — ligue um bot e clique Medir de novo
                  </p>
                  <p :for={{key, stat} <- @capture_info.stats} class="text-pk-text-3">
                    {String.replace_prefix(key, "capture.", "")} · n={stat.count}
                    <span :if={stat.total > 0}>
                      avg={Float.round(stat.total / stat.count, 1)}ms max={stat.max}ms
                    </span>
                  </p>
                </div>
              </section>

              <section class="grid gap-4 border-t border-pk-line pt-4">
                <div>
                  <h3 class="text-pk-body font-semibold">Sensibilidade do brilho</h3><p class="mt-0.5 text-pk-meta text-pk-text-3">
                    Valor sugerido pela calibração.
                  </p><form id="threshold-form" phx-submit="save_threshold" class="mt-2 flex gap-2">
                    <input
                      name="threshold"
                      value={@threshold}
                      placeholder="sugerido"
                      class="input input-bordered h-10 min-w-0 flex-1 bg-pk-bg font-mono text-pk-title"
                    /><button class="btn btn-outline h-10 border-[#303940] px-4 text-pk-body">Salvar</button>
                  </form>
                </div>
                <div>
                  <h3 class="text-pk-body font-semibold">Ordem das skills</h3><p class="mt-0.5 text-pk-meta text-pk-text-3">
                    Prioridade de ataque, as mais fortes primeiro.
                  </p><form id="skills-form" phx-submit="save_skills" class="mt-2 flex gap-2">
                    <input
                      name="skills"
                      value={@skill_order}
                      placeholder="1 2 3"
                      class="input input-bordered h-10 min-w-0 flex-1 bg-pk-bg font-mono text-pk-title"
                    /><button class="btn btn-outline h-10 border-[#303940] px-4 text-pk-body">Salvar</button>
                  </form>
                </div>
              </section>

              <section class="border-t border-pk-line pt-4">
                <h3 class="text-pk-body font-semibold">Timing do combate</h3><p class="mt-0.5 text-pk-meta text-pk-text-3">
                  Ajuste fino da velocidade de busca e de morte.
                </p>
                <form
                  id="timing-form"
                  phx-submit="save_timing"
                  class="mt-3 grid grid-cols-2 gap-2.5"
                >
                  <label
                    :for={{key, label, _hint} <- timing_fields()}
                    class="block font-mono text-pk-meta text-pk-text-3"
                  ><span>{label}</span><input
                    type="number"
                    min={if(positive_timing_key?(key), do: "1", else: "0")}
                    name={key}
                    value={@timing[key]}
                    class="input input-bordered mt-1 h-9 w-full bg-pk-bg font-mono text-pk-body"
                  /></label>
                  <button class="col-span-2 mt-1 h-10 rounded-lg bg-pk-ok text-pk-body font-bold text-pk-bg hover:bg-pk-ok">Salvar timing</button>
                </form>
              </section>

              <section :if={@calibrated?} class="border-t border-pk-line pt-4">
                <h3 class="text-pk-body font-semibold">Prints &amp; diagnóstico</h3><p class="mt-0.5 text-pk-meta text-pk-text-3">
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
                    class="h-8 rounded-lg border border-[#2b353b] px-3 text-pk-meta text-[#a3abb1] hover:border-pk-ok/60"
                    phx-click="shot"
                    phx-value-region={region}
                  >{label}</button>
                </div>
                <button
                  class="mt-3 h-10 w-full rounded-lg border border-[#30cf75] text-pk-body font-bold text-[#38dc80] hover:bg-pk-ok-dim"
                  phx-click="export_diagnostic"
                >Exportar diagnóstico (JSON)</button>
                <figure :if={@capture_src} class="mt-3">
                  <figcaption class="mb-1 text-pk-meta text-pk-text-3">{@capture_label}</figcaption><img
                    src={@capture_src}
                    class="max-h-64 rounded-lg border border-[#283138]"
                  />
                </figure>
                <p
                  :if={@capture_label && is_nil(@capture_src)}
                  class="mt-2 text-pk-meta text-[#ff929b]"
                >
                  {@capture_label}
                </p>
                <div
                  :if={@report}
                  class="mt-3 rounded-lg border border-[#263038] bg-pk-bg p-3 text-pk-meta text-pk-text-2"
                >
                  <div class="flex justify-between">
                    <span class="font-semibold text-pk-ok">{@report_msg}</span><a
                      :if={@report_src}
                      href={@report_src}
                      download
                      class="text-pk-ok underline"
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

              <nav class="grid grid-cols-3 gap-2 border-t border-pk-line pt-4 text-center text-pk-meta">
                <.link
                  navigate={~p"/calibration"}
                  class="rounded-lg border border-pk-line-strong px-2 py-2 hover:text-pk-ok"
                >Calibração</.link><.link
                  navigate={~p"/diagnostics"}
                  class="rounded-lg border border-pk-line-strong px-2 py-2 hover:text-pk-ok"
                >Diagnóstico</.link><.link
                  navigate={~p"/fishing-lab"}
                  class="rounded-lg border border-pk-line-strong px-2 py-2 hover:text-pk-ok"
                >Laboratório</.link>
              </nav>
            </div>
          </details>

          <div class="flex items-start gap-2 rounded-lg border border-[#6b2b32] bg-pk-danger-dim px-3 py-3 text-pk-meta leading-relaxed text-[#f0a0a7]">
            <.icon name="hero-hand-raised" class="mt-0.5 size-4 shrink-0 text-[#ffbf51]" /><p>
              <strong>Botão de pânico:</strong>
              jogue o mouse no canto superior-esquerdo e o bot para na hora.
            </p>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
