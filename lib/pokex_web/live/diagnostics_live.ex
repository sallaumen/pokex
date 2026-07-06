defmodule PokexWeb.DiagnosticsLive do
  use PokexWeb, :live_view

  alias Pokex.Rig

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, msg: nil, capture_src: nil)}
  end

  @impl true
  def handle_event("press", %{"combo" => combo}, socket) do
    Process.send_after(self(), {:delayed_press, combo}, 2_000)
    {:noreply, assign(socket, msg: "Clique na janela do JOGO agora! Tecla #{combo} em 2s...")}
  end

  def handle_event("click", %{"x" => x, "y" => y, "button" => button}, socket) do
    button = String.to_existing_atom(button)
    result = Rig.impl().click(button, {int(x), int(y)})
    {:noreply, assign(socket, msg: "click #{button} → #{inspect(result)}")}
  end

  def handle_event("capture", %{"x" => x, "y" => y, "w" => w, "h" => h}, socket) do
    case Rig.impl().capture({int(x), int(y), int(w), int(h)}, "diag.png") do
      {:ok, path} ->
        src = "/captures/#{Path.basename(path)}?t=#{System.unique_integer([:positive])}"
        {:noreply, assign(socket, capture_src: src, msg: "capturado")}

      {:error, reason} ->
        {:noreply, assign(socket, msg: "erro na captura: #{inspect(reason)}")}
    end
  end

  def handle_event("capture_seq", %{"x" => x, "y" => y}, socket) do
    Process.send_after(self(), {:delayed_seq, {int(x), int(y)}}, 2_000)
    {:noreply, assign(socket, msg: "Clique na janela do JOGO agora! Shift+1+clique em 2s...")}
  end

  @impl true
  def handle_info({:delayed_press, combo}, socket) do
    {:noreply, assign(socket, msg: "press #{combo} → #{inspect(Rig.impl().press(combo))}")}
  end

  def handle_info({:delayed_seq, point}, socket) do
    {:noreply,
     assign(socket, msg: "capture_sequence → #{inspect(Rig.impl().capture_sequence(point))}")}
  end

  defp int(value), do: String.to_integer(String.trim(value))

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-4 space-y-6 max-w-2xl">
      <h1 class="text-xl font-bold">Pokex — Diagnóstico</h1>
      <p :if={@msg} class="rounded bg-base-200 p-2 font-mono text-sm">{@msg}</p>

      <section class="space-y-2">
        <h2 class="font-semibold">Teclas (2s de atraso para você focar o jogo)</h2>
        <div class="flex gap-2">
          <button class="btn" phx-click="press" phx-value-combo="shift+z">Shift+Z</button>
          <button class="btn" phx-click="press" phx-value-combo="1">Tecla 1</button>
          <button class="btn" phx-click="press" phx-value-combo="2">Tecla 2</button>
        </div>
      </section>

      <section class="space-y-2">
        <h2 class="font-semibold">Clique em coordenada (points de tela)</h2>
        <form id="click-form" phx-submit="click" class="flex items-end gap-2">
          <input name="x" value="800" class="input input-bordered w-24" />
          <input name="y" value="400" class="input input-bordered w-24" />
          <select name="button" class="select select-bordered">
            <option value="left">left</option>
            <option value="right">right</option>
          </select>
          <button class="btn">Clicar</button>
        </form>
      </section>

      <section class="space-y-2">
        <h2 class="font-semibold">Captura de região</h2>
        <form id="capture-form" phx-submit="capture" class="flex items-end gap-2">
          <input name="x" value="0" class="input input-bordered w-20" />
          <input name="y" value="0" class="input input-bordered w-20" />
          <input name="w" value="400" class="input input-bordered w-20" />
          <input name="h" value="300" class="input input-bordered w-20" />
          <button class="btn">Capturar</button>
        </form>
        <img :if={@capture_src} src={@capture_src} class="max-w-full border" />
      </section>

      <section class="space-y-2">
        <h2 class="font-semibold">Sequência de captura de pokémon (Shift+1 + clique)</h2>
        <form id="seq-form" phx-submit="capture_seq" class="flex items-end gap-2">
          <input name="x" value="800" class="input input-bordered w-24" />
          <input name="y" value="400" class="input input-bordered w-24" />
          <button class="btn btn-warning">Testar em 2s</button>
        </form>
      </section>
    </div>
    """
  end
end
