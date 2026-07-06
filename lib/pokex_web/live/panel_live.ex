defmodule PokexWeb.PanelLive do
  use PokexWeb, :live_view

  alias Pokex.Bots.Fisher
  alias Pokex.Settings

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Pokex.PubSub, Fisher.topic())

    {:ok,
     assign(socket,
       snap: Fisher.status(),
       errors: [],
       threshold: Settings.get(:glow_threshold)
     )}
  end

  @impl true
  def handle_info({:fisher, snapshot}, socket), do: {:noreply, assign(socket, snap: snapshot)}

  @impl true
  def handle_event("start", _params, socket) do
    case Fisher.start_bot() do
      :ok -> {:noreply, assign(socket, errors: [], snap: Fisher.status())}
      {:error, messages} -> {:noreply, assign(socket, errors: messages)}
    end
  end

  def handle_event("stop", _params, socket) do
    Fisher.stop_bot()
    {:noreply, assign(socket, snap: Fisher.status())}
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

  defp state_class(:idle), do: "badge-neutral"
  defp state_class(:error), do: "badge-error"
  defp state_class(_state), do: "badge-success"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-4 space-y-4 max-w-md">
      <div class="flex items-center justify-between">
        <h1 class="text-xl font-bold">Pokex 🎣</h1>
        <span class={"badge " <> state_class(@snap.state)}>{@snap.state}</span>
      </div>

      <p :if={@snap.error} class="alert alert-error text-sm">{@snap.error}</p>

      <ul :if={@errors != []} class="alert alert-warning block text-sm">
        <li :for={message <- @errors}>{message}</li>
      </ul>

      <div class="flex gap-2">
        <button class="btn btn-success" phx-click="start">Start</button>
        <button class="btn btn-error" phx-click="stop">Stop</button>
      </div>

      <div class="grid grid-cols-3 gap-2 text-center">
        <div
          :for={
            {label, key} <- [
              {"Ciclos", :cycles},
              {"Fisgadas", :hooked},
              {"Lutas", :fights},
              {"Loots", :loots},
              {"Capturas", :captures},
              {"Falhas", :failures}
            ]
          }
          class="rounded bg-base-200 p-2"
        >
          <div class="text-2xl font-bold">{@snap.counters[key]}</div>
          <div class="text-xs">{label}</div>
        </div>
      </div>

      <form id="threshold-form" phx-submit="save_threshold" class="flex items-end gap-2">
        <label class="text-sm">
          Threshold do brilho (vazio = sugerido)
          <input name="threshold" value={@threshold} class="input input-bordered w-28" />
        </label>
        <button class="btn btn-sm">Salvar</button>
      </form>

      <div class="flex gap-4 text-sm">
        <.link navigate={~p"/calibration"} class="link">Calibração</.link>
        <.link navigate={~p"/diagnostics"} class="link">Diagnóstico</.link>
      </div>

      <p class="text-xs opacity-60">
        Pânico: jogue o mouse no canto superior-esquerdo da tela e o bot para sozinho.
      </p>
    </div>
    """
  end
end
