defmodule PokexWeb.PanelLive do
  use PokexWeb, :live_view

  alias Pokex.Bots.{BotSupervisor, Combat, Fishing}
  alias Pokex.{Calibration, Settings}

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
       logs: []
     )}
  end

  @impl true
  def handle_info({:fishing, snapshot}, socket),
    do: {:noreply, assign(socket, fishing: snapshot, panicked?: false)}

  def handle_info({:combat, snapshot}, socket),
    do: {:noreply, assign(socket, combat: snapshot, panicked?: false)}

  def handle_info({:fishing_log, text}, socket),
    do: {:noreply, append_log(socket, "🎣 " <> text)}

  def handle_info({:combat_log, text}, socket),
    do: {:noreply, append_log(socket, "⚔️ " <> text)}

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
      |> append_log("🛑 pânico: mouse no canto — tudo parado")

    {:noreply, socket}
  end

  defp append_log(socket, text),
    do: assign(socket, logs: Enum.take([text | socket.assigns.logs], 25))

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

  def handle_event("toggle_capture", _params, socket) do
    value = not Settings.get(:auto_capture)
    Settings.put(:auto_capture, value)
    {:noreply, assign(socket, auto_capture: value)}
  end

  defp counters, do: @counters

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
          <h2 class="mb-2 px-1 text-xs font-semibold uppercase tracking-wide opacity-50">
            O que ele está fazendo
          </h2>
          <div
            id="activity-feed"
            class="h-40 space-y-0.5 overflow-y-auto rounded-lg border border-base-content/10 bg-base-300 p-2 font-mono text-xs"
          >
            <p :if={@logs == []} class="opacity-40">
              a atividade aparece aqui quando o bot roda (mostra onde ele clica)
            </p>
            <p
              :for={{line, i} <- Enum.with_index(@logs)}
              class={(i == 0 && "text-primary") || "opacity-70"}
            >
              {line}
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
