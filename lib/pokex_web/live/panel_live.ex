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
       threshold: Settings.get(:glow_threshold),
       mini_game_sound: Settings.get(:mini_game_sound),
       player_mode: Settings.get(:player_mode),
       skill_order: Enum.join(Settings.get(:skill_keys), " "),
       loot_enabled: Settings.get(:loot_enabled),
       capture_enabled: Settings.get(:capture_enabled),
       panicked?: false,
       focused?: initial_focus(),
       logs: [],
       show_debug: false,
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
       rescue_enabled: Settings.get(:rescue_enabled),
       rescue_pct: Settings.get(:pokemon_hp_rescue_pct),
       rescue_cooldown_s: div(Settings.get(:rescue_cooldown_ms), 1000),
       potion_enabled: Settings.get(:potion_enabled),
       potion_pct: Settings.get(:pokemon_hp_potion_pct),
       potion_cooldown_s: div(Settings.get(:potion_cooldown_ms), 1000),
       hook_skills: Enum.join(Settings.get(:hook_skill_keys), " ")
     )}
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
    do: {:noreply, assign(socket, fishing: snapshot, panicked?: false)}

  def handle_info({:combat, snapshot}, socket),
    do: {:noreply, assign(socket, combat: snapshot, panicked?: false)}

  def handle_info({:catcher, snapshot}, socket),
    do: {:noreply, assign(socket, catcher: snapshot)}

  def handle_info({:mini_game, snapshot}, socket) do
    socket = assign(socket, mini_game: snapshot)

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
    {:noreply, socket}
  end

  def handle_info({:fishing_log, level, text}, socket),
    do: {:noreply, append_log(socket, %{level: level, source: "🎣", text: text})}

  def handle_info({:combat_log, level, text}, socket),
    do: {:noreply, append_log(socket, %{level: level, source: "⚔️", text: text})}

  def handle_info({:mini_game_log, level, text}, socket),
    do: {:noreply, append_log(socket, %{level: level, source: "🎮", text: text})}

  def handle_info({:catcher_log, level, text}, socket),
    do: {:noreply, append_log(socket, %{level: level, source: "🎯", text: text})}

  def handle_info({:game, snapshot}, socket),
    do: {:noreply, assign(socket, game: snapshot)}

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
  def handle_event("start", _params, socket) do
    case BotSupervisor.start_all() do
      :ok ->
        status = BotSupervisor.status()

        {:noreply,
         assign(socket,
           errors: [],
           logs: [],
           panicked?: false,
           fishing: status.fishing,
           combat: status.combat,
           catcher: status.catcher,
           mini_game: status.mini_game,
           game: status.player_support
         )}

      {:error, messages} ->
        {:noreply, assign(socket, errors: messages)}
    end
  end

  def handle_event("stop", _params, socket) do
    BotSupervisor.stop_all()
    status = BotSupervisor.status()

    {:noreply,
     assign(socket,
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

  defp visible_logs(logs, show_debug), do: Enum.filter(logs, &(show_debug or &1.level == :macro))
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
          <div class="mx-auto flex h-12 max-w-[520px] items-center justify-between px-2">
            <.link navigate={~p"/"} class="flex items-center gap-2.5" aria-label="Ir ao painel">
              <span class="grid size-7 place-items-center rounded-lg bg-[#36cf78] text-sm font-black text-[#06150c]">P</span>
              <span class="text-sm font-bold">Pokex</span>
            </.link>
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
                </nav>
              </details>
            </div>
          </div>
        </header>

        <main class="mx-auto max-w-[520px] space-y-3 px-2 py-3">
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
                    name={if @mini_game_sound, do: "hero-speaker-wave", else: "hero-speaker-x-mark"}
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
            <ul
              :if={@errors != []}
              class="rounded-lg border border-[#674f20] bg-[#211b0d] px-3 py-2 text-xs text-[#e7ca82]"
            >
              <li :for={message <- @errors}>{message}</li>
            </ul>
          </div>

          <div
            :if={not @focused?}
            id="focus-pause-banner"
            class="flex items-center gap-3 rounded-lg border border-[#674f20] bg-[#211b0d] p-3 text-xs"
          >
            <.icon name="hero-pause-circle" class="size-5 shrink-0 text-[#f2c45b]" />
            <p class="flex-1 text-[#c8cdd1]">
              <span class="font-semibold text-[#f2c45b]">Pausado por segurança</span> — a janela do
              jogo perdeu o foco. Nada é digitado/clicado até você voltar pro jogo; aí os workers
              religam sozinhos.
            </p>
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
            </div>
          </details>

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
              <form id="rescue-cfg-form" phx-change="save_rescue_cfg" class="flex items-center gap-1">
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
              <form id="potion-cfg-form" phx-change="save_potion_cfg" class="flex items-center gap-1">
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

          <section>
            <h2 class="mb-2 px-0.5 font-mono text-[10px] font-bold uppercase tracking-[0.12em] text-[#69737b]">
              Sessão
            </h2>
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
            <p
              :if={@export_msg}
              class="border-b border-[#222a2f] px-3 py-1.5 text-[10px] text-[#37d07d]"
            >
              {@export_msg}
              <a :if={@export_src} href={@export_src} download class="underline">baixar</a>
            </p>
            <div
              id="activity-feed"
              class="h-64 overflow-y-auto p-3 font-mono text-[10px] leading-relaxed text-[#9aa3aa]"
            >
              <p :if={visible_logs(@logs, @show_debug) == []} class="max-w-[300px] text-[#59636b]">
                a atividade aparece aqui quando o bot roda<br />(marque "debug" pra ver cada tick)
              </p>
              <p
                :for={entry <- visible_logs(@logs, @show_debug)}
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

              <section class="border-t border-[#232b30] pt-4">
                <label class="flex cursor-pointer items-center justify-between gap-3"><span><span class="block text-xs font-semibold">Só pescar quando dá pra matar</span><span class="mt-0.5 block text-[10px] text-[#79838b]">Segura a fisga até as skills abaixo estarem prontas.</span></span><input
                  type="checkbox"
                  class="toggle toggle-success toggle-sm"
                  checked={@require_cooldowns}
                  phx-click="toggle_require_cooldowns"
                /></label>
                <form id="hook-skills-form" phx-submit="save_hook_skills" class="mt-3">
                  <label class="font-mono text-[10px] text-[#77828a]">Skills necessárias pra matar</label><div class="mt-1.5 flex gap-2">
                    <input
                      name="hook_skills"
                      value={@hook_skills}
                      placeholder="4 5 6 7"
                      class="input input-bordered h-10 min-w-0 flex-1 bg-[#090d0f] font-mono text-sm"
                    /><button class="btn h-10 border-0 bg-[#37d07d] px-5 text-xs font-bold text-[#06140c] hover:bg-[#45dd88]">Salvar</button>
                  </div>
                </form>
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
                <form id="timing-form" phx-submit="save_timing" class="mt-3 grid grid-cols-2 gap-2.5">
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
        </main>
      </div>
    </Layouts.app>
    """
  end
end
