defmodule PokexWeb.PanelLive do
  use PokexWeb, :live_view

  alias Pokex.Bots.Fisher
  alias Pokex.{Calibration, Settings}

  @counters [
    {"Ciclos", :cycles, "hero-arrow-path"},
    {"Fisgadas", :hooked, "hero-sparkles"},
    {"Lutas", :fights, "hero-bolt"},
    {"Loots", :loots, "hero-gift"},
    {"Capturas", :captures, "hero-check-badge"},
    {"Falhas", :failures, "hero-exclamation-triangle"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Pokex.PubSub, Fisher.topic())

    {:ok,
     assign(socket,
       page_title: "Painel",
       snap: Fisher.status(),
       errors: [],
       calibrated?: Calibration.exists?(),
       threshold: Settings.get(:glow_threshold),
       auto_capture: Settings.get(:auto_capture),
       logs: []
     )}
  end

  @impl true
  def handle_info({:fisher, snapshot}, socket), do: {:noreply, assign(socket, snap: snapshot)}

  def handle_info({:fisher_log, text}, socket),
    do: {:noreply, assign(socket, logs: Enum.take([text | socket.assigns.logs], 25))}

  @impl true
  def handle_event("start", _params, socket) do
    case Fisher.start_bot() do
      :ok -> {:noreply, assign(socket, errors: [], logs: [], snap: Fisher.status())}
      {:error, messages} -> {:noreply, assign(socket, errors: messages)}
    end
  end

  def handle_event("stop", _params, socket) do
    Fisher.stop_bot()
    {:noreply, assign(socket, snap: Fisher.status())}
  end

  def handle_event("test_combat", _params, socket) do
    case Fisher.start_combat() do
      :ok -> {:noreply, assign(socket, errors: [], logs: [], snap: Fisher.status())}
      {:error, messages} -> {:noreply, assign(socket, errors: messages)}
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

  def handle_event("toggle_capture", _params, socket) do
    value = not Settings.get(:auto_capture)
    Settings.put(:auto_capture, value)
    {:noreply, assign(socket, auto_capture: value)}
  end

  defp counters, do: @counters

  defp state_label(:idle), do: "Parado"
  defp state_label(:focusing), do: "Focando o jogo"
  defp state_label(:equipping), do: "Equipando a vara"
  defp state_label(:casting), do: "Arremessando"
  defp state_label(:watching), do: "Vigiando o brilho"
  defp state_label(:assessing), do: "Avaliando a fisgada"
  defp state_label(:fighting), do: "Em combate"
  defp state_label(:looting), do: "Coletando o item"
  defp state_label(:capturing), do: "Capturando"
  defp state_label(:error), do: "Erro — parado"
  defp state_label(other), do: to_string(other)

  defp state_dot(:idle), do: "bg-base-content/40"
  defp state_dot(:error), do: "bg-error"
  defp state_dot(_running), do: "bg-success motion-safe:animate-pulse"

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

        <section
          class="rounded-2xl border border-base-content/10 bg-base-200 p-5"
          data-state={@snap.state}
        >
          <div class="flex flex-wrap items-center justify-between gap-4">
            <div class="flex items-center gap-3">
              <span class={["size-3 rounded-full", state_dot(@snap.state)]} />
              <div>
                <p class="text-lg font-semibold leading-tight">{state_label(@snap.state)}</p>
                <p class="font-mono text-xs opacity-50">{@snap.state}</p>
              </div>
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
            </div>
          </div>

          <p :if={@snap.error} class="mt-3 rounded-lg bg-error/15 px-3 py-2 text-sm text-error">
            {@snap.error}
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
          <div class="h-40 space-y-0.5 overflow-y-auto rounded-lg border border-base-content/10 bg-base-300 p-2 font-mono text-xs">
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
              <div class="text-2xl font-bold tabular-nums">{@snap.counters[key]}</div>
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
