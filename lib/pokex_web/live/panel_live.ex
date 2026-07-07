defmodule PokexWeb.PanelLive do
  use PokexWeb, :live_view

  alias Pokex.Bots.{BotSupervisor, Combat, Fishing}
  alias Pokex.Diagnostics.Report
  alias Pokex.{Calibration, Rig, Settings}

  @fishing_topic "fishing"
  @combat_topic "combat"

  @counters [
    {"Ciclos", :cycles, "hero-arrow-path"},
    {"Fisgadas", :hooked, "hero-sparkles"},
    {"Lutas", :fights, "hero-bolt"},
    {"Loots", :loots, "hero-gift"},
    {"Capturas", :captures, "hero-check-badge"},
    {"Falhas", :failures, "hero-exclamation-triangle"}
  ]

  @idle_fishing %{state: :idle, counters: %{}, error: nil}
  @idle_combat %{state: :idle, counters: %{}, error: nil, locked_row: nil}

  # Combat timing knobs Lucas tunes live to speed up search + kills. Config is
  # built once at Start/Testar, so these apply on the NEXT run (noted in the UI).
  @timing_fields [
    {:skill_cast_ms, "Cadência das skills (ms)",
     "menor = mata mais rápido; abaixo do cooldown real o jogo ignora"},
    {:target_verify_attempts, "Tentativas por linha",
     "leituras do anel antes de pular a linha — menor = busca mais rápida"},
    {:wait_target_verify_ms, "Espera do anel (ms)",
     "tempo pro anel vermelho aparecer depois do clique"},
    {:fight_timeout_ms, "Timeout de alvo (ms)", "desiste de um alvo que não morre nesse tempo"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Pokex.PubSub, @fishing_topic)
      Phoenix.PubSub.subscribe(Pokex.PubSub, @combat_topic)
    end

    status = BotSupervisor.status()

    {:ok,
     assign(socket,
       page_title: "Painel",
       fishing: status.fishing,
       combat: status.combat,
       errors: [],
       calibrated?: Calibration.exists?(),
       threshold: Settings.get(:glow_threshold),
       auto_capture: Settings.get(:auto_capture),
       skill_order: Enum.join(Settings.get(:skill_keys), " "),
       panicked?: false,
       logs: [],
       show_debug: false,
       export_src: nil,
       export_msg: nil,
       capture_src: nil,
       capture_label: nil,
       report: nil,
       report_src: nil,
       report_msg: nil,
       timing: timing_settings()
     )}
  end

  defp timing_settings do
    Map.new(@timing_fields, fn {key, _label, _hint} -> {key, Settings.get(key)} end)
  end

  @impl true
  def handle_info({:fishing, snapshot}, socket),
    do: {:noreply, assign(socket, fishing: snapshot, panicked?: false)}

  def handle_info({:combat, snapshot}, socket),
    do: {:noreply, assign(socket, combat: snapshot, panicked?: false)}

  def handle_info({:fishing_log, level, text}, socket),
    do: {:noreply, append_log(socket, %{level: level, source: "🎣", text: text})}

  def handle_info({:combat_log, level, text}, socket),
    do: {:noreply, append_log(socket, %{level: level, source: "⚔️", text: text})}

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
           combat: status.combat
         )}

      {:error, messages} ->
        {:noreply, assign(socket, errors: messages)}
    end
  end

  def handle_event("stop", _params, socket) do
    BotSupervisor.stop_all()
    status = BotSupervisor.status()
    {:noreply, assign(socket, fishing: status.fishing, combat: status.combat)}
  end

  def handle_event("test_combat", _params, socket) do
    case Combat.Worker.run() do
      :ok ->
        {:noreply,
         assign(socket, errors: [], logs: [], panicked?: false, combat: Combat.Worker.status())}

      {:error, messages} ->
        {:noreply, assign(socket, errors: messages)}
    end
  end

  # Run ONLY the fishing worker — combat stays idle, so you can watch the fishing
  # loop alone (cast → watch → hook → repeat) without the mouse being shared.
  def handle_event("test_fishing", _params, socket) do
    case Fishing.Worker.run() do
      :ok ->
        {:noreply,
         assign(socket, errors: [], logs: [], panicked?: false, fishing: Fishing.Worker.status())}

      {:error, messages} ->
        {:noreply, assign(socket, errors: messages)}
    end
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
    keys = String.split(raw, ~r/[\s,]+/, trim: true)
    keys = if keys == [], do: Settings.get(:skill_keys), else: keys
    Settings.put(:skill_keys, keys)
    {:noreply, assign(socket, skill_order: Enum.join(keys, " "))}
  end

  # Persist the combat timing knobs; blanks/invalid keep the current value. They
  # apply on the next Start/Testar (config is frozen at run start).
  def handle_event("save_timing", params, socket) do
    timing =
      Enum.reduce(@timing_fields, socket.assigns.timing, fn {key, _label, _hint}, acc ->
        case parse_non_neg(params[to_string(key)]) do
          {:ok, n} ->
            Settings.put(key, n)
            Map.put(acc, key, n)

          :error ->
            acc
        end
      end)

    {:noreply, assign(socket, timing: timing)}
  end

  def handle_event("toggle_capture", _params, socket) do
    value = not Settings.get(:auto_capture)
    Settings.put(:auto_capture, value)
    {:noreply, assign(socket, auto_capture: value)}
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
    case Rig.impl().capture_screen() do
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

  defp region_spec("glow", calib), do: {calib.glow_region, "água (glow)", "shot_glow.png"}

  defp region_spec("battle", calib),
    do: {calib.battle_region, "painel Batalha", "shot_battle.png"}

  defp region_spec("arena", calib), do: {calib.arena_region, "arena", "shot_arena.png"}
  defp region_spec(_other, _calib), do: :error

  defp capture_src(path),
    do: "/captures/#{Path.basename(path)}?t=#{System.unique_integer([:positive])}"

  defp parse_non_neg(nil), do: :error

  defp parse_non_neg(raw) do
    case Integer.parse(String.trim(raw)) do
      {n, _} when n >= 0 -> {:ok, n}
      _ -> :error
    end
  end

  # Nil-safe deep fetch into the report map (regions may carry :error instead of
  # :metrics/:matrix when a capture fails), so the render never KeyErrors.
  defp gi(map, path), do: get_in(map, path)

  defp cell_style(%{rgb: [r, g, b]}), do: "background: rgb(#{r}, #{g}, #{b})"

  defp visible_logs(logs, show_debug), do: Enum.filter(logs, &(show_debug or &1.level == :macro))
  defp macro_count(logs), do: Enum.count(logs, &(&1.level == :macro))

  defp log_class(:macro), do: "text-base-content"
  defp log_class(_debug), do: "opacity-50"

  defp counters, do: @counters
  defp timing_fields, do: @timing_fields

  # Fishing and combat only truly overlap on :failures — sum those; every
  # other counter belongs to exactly one worker, so a plain merge is right
  # for them.
  defp merged_counters(fishing, combat) do
    Map.merge(Map.new(fishing.counters || %{}), Map.new(combat.counters || %{}), fn
      :failures, a, b -> a + b
      _key, _a, b -> b
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

  # ⚔️ Batalha: parado / procurando / lutando linha N / coletando (loot +
  # capture + the walks around them) / erro.
  defp combat_label(:idle, _row), do: "parado"
  defp combat_label(:scanning, _row), do: "procurando"
  defp combat_label(:fighting, row) when is_integer(row), do: "lutando linha #{row}"
  defp combat_label(:fighting, _row), do: "lutando"
  defp combat_label(:walking_to_loot, _row), do: "coletando"
  defp combat_label(:looting, _row), do: "coletando"
  defp combat_label(:capturing, _row), do: "coletando"
  defp combat_label(:walking_back, _row), do: "coletando"
  defp combat_label(:error, _row), do: "erro"
  defp combat_label(other, _row), do: to_string(other)

  defp active?(:idle), do: false
  defp active?(_state), do: true

  defp pill_class(:error), do: "badge-error"
  defp pill_class(:idle), do: "badge-ghost"
  defp pill_class(_running), do: "badge-success"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_page={:panel}>
      <div class="space-y-5">
        <div
          :if={not @calibrated?}
          class="flex items-center gap-3 rounded-xl border border-warning/40 bg-warning/10 p-4"
        >
          <.icon name="hero-exclamation-triangle" class="size-6 shrink-0 text-warning" />
          <div class="flex-1 text-sm">
            <p class="font-semibold">Você ainda não calibrou.</p>
            <p class="opacity-80">
              O bot precisa saber onde ficam a água, a janela Battle e a arena antes de começar.
            </p>
          </div>
          <.link navigate={~p"/calibration"} class="btn btn-warning btn-sm">Calibrar →</.link>
        </div>

        <section class="rounded-2xl border border-base-content/10 bg-base-200 p-5">
          <div class="flex flex-wrap items-center justify-between gap-4">
            <div class="flex flex-wrap items-center gap-2">
              <span
                data-testid="fishing-pill"
                data-state={@fishing.state}
                class={["badge gap-1.5 badge-lg", pill_class(@fishing.state)]}
              >
                <span class={[
                  "size-2 rounded-full bg-current",
                  active?(@fishing.state) && "motion-safe:animate-pulse"
                ]} /> 🎣 Pesca: {fishing_label(@fishing.state)}
              </span>
              <span
                data-testid="combat-pill"
                data-state={@combat.state}
                class={["badge gap-1.5 badge-lg", pill_class(@combat.state)]}
              >
                <span class={[
                  "size-2 rounded-full bg-current",
                  active?(@combat.state) && "motion-safe:animate-pulse"
                ]} /> ⚔️ Batalha: {combat_label(@combat.state, Map.get(@combat, :locked_row))}
              </span>
            </div>
            <div class="flex flex-wrap gap-2">
              <button class="btn btn-success gap-1.5" phx-click="start">
                <.icon name="hero-play" class="size-4" /> Start
              </button>
              <button class="btn btn-outline btn-error gap-1.5" phx-click="stop">
                <.icon name="hero-stop" class="size-4" /> Stop
              </button>
              <button
                class="btn btn-outline btn-warning gap-1.5"
                phx-click="test_combat"
                title="Só o combate em loop: mira → ataca → loot → captura, repetindo"
              >
                <.icon name="hero-bug-ant" class="size-4" /> Testar combate
              </button>
              <button
                class="btn btn-outline btn-info gap-1.5"
                phx-click="test_fishing"
                title="Só a pesca em loop: arremessa → vigia → fisga, repetindo (combate parado)"
              >
                <.icon name="hero-bug-ant" class="size-4" /> Testar pesca
              </button>
            </div>
          </div>

          <p :if={@fishing.error} class="mt-3 rounded-lg bg-error/15 px-3 py-2 text-sm text-error">
            🎣 {@fishing.error}
          </p>
          <p :if={@combat.error} class="mt-3 rounded-lg bg-error/15 px-3 py-2 text-sm text-error">
            ⚔️ {@combat.error}
          </p>
          <ul :if={@errors != []} class="mt-3 space-y-1 rounded-lg bg-warning/10 px-3 py-2 text-sm">
            <li :for={message <- @errors} class="flex items-start gap-2">
              <.icon name="hero-x-circle" class="mt-0.5 size-4 shrink-0 text-warning" />
              <span>{message}</span>
            </li>
          </ul>
        </section>

        <section>
          <div class="mb-2 flex flex-wrap items-center justify-between gap-2 px-1">
            <h2 class="text-xs font-semibold uppercase tracking-wide opacity-50">
              O que ele está fazendo
            </h2>
            <div class="flex flex-wrap items-center gap-2 text-[11px]">
              <span class="opacity-50">{macro_count(@logs)} eventos · {length(@logs)} no total</span>
              <label class="flex cursor-pointer items-center gap-1 opacity-70">
                <input
                  type="checkbox"
                  class="toggle toggle-xs"
                  checked={@show_debug}
                  phx-click="toggle_debug"
                /> debug
              </label>
              <button class="btn btn-ghost btn-xs" phx-click="export_events">
                <.icon name="hero-arrow-down-tray" class="size-3" /> Exportar
              </button>
              <button class="btn btn-ghost btn-xs" phx-click="clear_logs">Limpar</button>
            </div>
          </div>
          <p :if={@export_msg} class="mb-1 px-1 text-[11px] text-success">
            {@export_msg}
            <a :if={@export_src} href={@export_src} download class="link link-primary">baixar</a>
          </p>
          <div
            id="activity-feed"
            class="h-40 space-y-0.5 overflow-y-auto rounded-lg border border-base-content/10 bg-base-300 p-2 font-mono text-xs"
          >
            <p :if={visible_logs(@logs, @show_debug) == []} class="opacity-40">
              a atividade aparece aqui quando o bot roda (marque "debug" pra ver cada tick)
            </p>
            <p
              :for={entry <- visible_logs(@logs, @show_debug)}
              class={["flex gap-1.5", log_class(entry.level)]}
            >
              <span class="shrink-0 opacity-40">{entry.at}</span>
              <span class="shrink-0">{entry.source}</span>
              <span>{entry.text}</span>
            </p>
          </div>
        </section>

        <section>
          <h2 class="mb-2 px-1 text-xs font-semibold uppercase tracking-wide opacity-50">
            Sessão
          </h2>
          <div class="grid grid-cols-3 gap-2 sm:grid-cols-6">
            <div
              :for={{label, key, icon} <- counters()}
              class="rounded-xl border border-base-content/10 bg-base-200 p-3 text-center"
            >
              <div class="text-2xl font-bold tabular-nums">
                {Map.get(merged_counters(@fishing, @combat), key, 0)}
              </div>
              <div class="mt-0.5 flex items-center justify-center gap-1 text-[11px] opacity-60">
                <.icon name={icon} class="size-3" />{label}
              </div>
            </div>
          </div>
        </section>

        <section
          :if={@calibrated?}
          class="space-y-3 rounded-2xl border border-base-content/10 bg-base-200 p-5"
        >
          <div class="flex flex-wrap items-center justify-between gap-2">
            <h2 class="text-sm font-semibold">Prints &amp; Diagnóstico</h2>
            <button class="btn btn-sm btn-primary gap-1.5" phx-click="export_diagnostic">
              <.icon name="hero-document-arrow-down" class="size-4" /> Exportar diagnóstico (JSON)
            </button>
          </div>
          <p class="text-xs opacity-60">
            Tira prints das áreas calibradas e gera um JSON com tudo que o bot enxerga
            (pixels, contagens, matriz). Manda o JSON pro Claude diagnosticar sem precisar de foto.
          </p>
          <div class="flex flex-wrap gap-2">
            <button class="btn btn-sm btn-outline" phx-click="shot" phx-value-region="screen">
              📸 Tela cheia
            </button>
            <button class="btn btn-sm btn-outline" phx-click="shot" phx-value-region="glow">
              📸 Água
            </button>
            <button class="btn btn-sm btn-outline" phx-click="shot" phx-value-region="battle">
              📸 Batalha
            </button>
            <button class="btn btn-sm btn-outline" phx-click="shot" phx-value-region="arena">
              📸 Arena
            </button>
          </div>

          <figure :if={@capture_src} class="space-y-1">
            <figcaption class="flex items-center gap-2 text-xs opacity-70">
              <span>{@capture_label}</span>
              <a href={@capture_src} download class="link link-primary">baixar</a>
            </figcaption>
            <img
              src={@capture_src}
              class="max-h-72 rounded border border-base-content/20 bg-base-300"
            />
          </figure>
          <p :if={@capture_label && is_nil(@capture_src)} class="text-xs text-error">
            {@capture_label}
          </p>

          <div
            :if={@report}
            class="space-y-3 rounded-xl border border-base-content/10 bg-base-300 p-3"
          >
            <div class="flex flex-wrap items-center justify-between gap-2 text-xs">
              <span class="font-semibold text-success">{@report_msg}</span>
              <a :if={@report_src} href={@report_src} download class="link link-primary">
                baixar JSON completo
              </a>
            </div>

            <div class="grid gap-x-6 gap-y-1 font-mono text-[11px] sm:grid-cols-2">
              <span>
                🎣 bolhas: <b>{gi(@report, [:regions, :glow, :metrics, :bubble_count]) || "—"}</b>
                · mordida? <b>{inspect(gi(@report, [:regions, :glow, :metrics, :bite?]))}</b>
              </span>
              <span>
                ⚔️ tem bicho?
                <b>{inspect(gi(@report, [:regions, :battle_body, :metrics, :has_creature?]))}</b>
                · travado:
                <b>{inspect(gi(@report, [:regions, :battle_body, :metrics, :locked_row]))}</b>
              </span>
              <span>
                ⚔️ por linha:
                <b>{inspect(gi(@report, [:regions, :battle_body, :metrics, :red_row_counts]))}</b>
              </span>
              <span>
                ⚔️ pokébola?
                <b>{inspect(gi(@report, [:regions, :battle_strip, :metrics, :wild_present?]))}</b>
              </span>
              <span>escala (probe): <b>{gi(@report, [:screen, :r_scale]) || "—"}×</b></span>
              <span>tela: <b>{inspect(gi(@report, [:screen, :pixels]))}px</b></span>
            </div>

            <% matrix = gi(@report, [:regions, :battle_body, :matrix]) %>
            <div :if={matrix}>
              <p class="mb-1 text-[11px] opacity-70">
                matriz do painel Batalha ({matrix.cols}×{matrix.rows}) — o que o bot vê
                <span class="opacity-60">(verde = HP · vermelho = lock/alvo · ciano = bolha)</span>
              </p>
              <div
                class="inline-grid gap-px rounded border border-base-content/20 bg-base-100 p-1"
                style={"grid-template-columns: repeat(#{matrix.cols}, 10px)"}
              >
                <div
                  :for={cell <- List.flatten(matrix.cells)}
                  class="size-[10px]"
                  style={cell_style(cell)}
                  title={to_string(cell.class)}
                >
                </div>
              </div>
            </div>
          </div>
        </section>

        <section class="space-y-4 rounded-2xl border border-base-content/10 bg-base-200 p-5">
          <div>
            <h2 class="text-sm font-semibold">Sensibilidade do brilho</h2>
            <p class="text-xs opacity-60">
              Vazio = usa o valor sugerido na calibração. Ajuste fino em tempo real no <.link
                navigate={~p"/diagnostics"}
                class="link link-primary"
              >Diagnóstico</.link>.
            </p>
            <form id="threshold-form" phx-submit="save_threshold" class="mt-2 flex items-center gap-2">
              <input
                name="threshold"
                value={@threshold}
                placeholder="sugerido"
                class="input input-bordered input-sm w-28"
              />
              <button class="btn btn-sm btn-primary">Salvar</button>
            </form>
          </div>

          <div class="border-t border-base-content/10 pt-4">
            <h2 class="text-sm font-semibold">Ordem das skills</h2>
            <p class="text-xs opacity-60">
              Prioridade de ataque, as mais fortes primeiro. Ele percorre nesta ordem;
              skill em cooldown o jogo ignora. Ex.: <code class="font-mono">7 6 5 4 3 2 1</code>.
            </p>
            <form id="skills-form" phx-submit="save_skills" class="mt-2 flex items-center gap-2">
              <input
                name="skills"
                value={@skill_order}
                placeholder="1 2 3"
                class="input input-bordered input-sm w-40"
              />
              <button class="btn btn-sm btn-primary">Salvar</button>
            </form>
          </div>

          <div class="border-t border-base-content/10 pt-4">
            <h2 class="text-sm font-semibold">Timing do combate (calibragem)</h2>
            <p class="text-xs opacity-60">
              Ajuste fino da velocidade de busca e de morte. Aplica no próximo <span class="font-medium">Start</span>/<span class="font-medium">Testar</span>.
            </p>
            <form id="timing-form" phx-submit="save_timing" class="mt-2 grid gap-3 sm:grid-cols-2">
              <label :for={{key, label, hint} <- timing_fields()} class="block text-xs">
                <span class="font-medium">{label}</span>
                <input
                  type="number"
                  min="0"
                  name={key}
                  value={@timing[key]}
                  class="input input-bordered input-sm mt-1 w-full"
                />
                <span class="mt-0.5 block opacity-50">{hint}</span>
              </label>
              <div class="sm:col-span-2">
                <button class="btn btn-sm btn-primary">Salvar timing</button>
              </div>
            </form>
          </div>

          <label class="flex cursor-pointer items-center justify-between gap-3 border-t border-base-content/10 pt-4">
            <span>
              <span class="text-sm font-semibold">Auto-captura</span>
              <span class="block text-xs opacity-60">
                Joga a pokébola base (Shift+1) em todo pokémon pescado.
              </span>
            </span>
            <input
              type="checkbox"
              class="toggle toggle-success"
              checked={@auto_capture}
              phx-click="toggle_capture"
            />
          </label>

          <div class="flex items-start gap-2 rounded-lg bg-base-300 px-3 py-2 text-xs">
            <.icon name="hero-hand-raised" class="mt-0.5 size-4 shrink-0 text-error" />
            <p>
              <span class="font-semibold">Botão de pânico:</span>
              jogue o mouse no canto superior-esquerdo da tela e o bot para na hora.
            </p>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
