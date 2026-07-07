defmodule PokexWeb.DiagnosticsLive do
  use PokexWeb, :live_view

  alias Pokex.Rig
  alias Pokex.{Calibration, Settings, Vision}
  alias Pokex.Vision.Frame

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Diagnóstico",
       msg: nil,
       capture_src: nil,
       calibrated?: Calibration.exists?()
     )}
  end

  @impl true
  def handle_event("press", %{"combo" => combo}, socket) do
    Process.send_after(self(), {:delayed_press, combo}, 2_000)
    {:noreply, assign(socket, msg: "Clique na janela do JOGO agora! Tecla #{combo} em 2s...")}
  end

  def handle_event("click", %{"x" => x, "y" => y, "button" => button}, socket) do
    with {:ok, [x, y]} <- parse_ints([x, y]),
         {:ok, btn} <- parse_button(button) do
      result = Rig.impl().click(btn, {x, y})
      {:noreply, assign(socket, msg: "click #{btn} → #{inspect(result)}")}
    else
      _ -> {:noreply, assign(socket, msg: "coordenada ou botão inválido")}
    end
  end

  def handle_event("capture", %{"x" => x, "y" => y, "w" => w, "h" => h}, socket) do
    case parse_ints([x, y, w, h]) do
      {:ok, [x, y, w, h]} ->
        case Rig.impl().capture({x, y, w, h}, "diag.png") do
          {:ok, path} ->
            src = "/captures/#{Path.basename(path)}?t=#{System.unique_integer([:positive])}"
            {:noreply, assign(socket, capture_src: src, msg: "capturado")}

          {:error, reason} ->
            {:noreply, assign(socket, msg: "erro na captura: #{inspect(reason)}")}
        end

      :error ->
        {:noreply, assign(socket, msg: "coordenada inválida — use apenas números inteiros")}
    end
  end

  def handle_event("capture_seq", %{"x" => x, "y" => y}, socket) do
    case parse_ints([x, y]) do
      {:ok, [x, y]} ->
        Process.send_after(self(), {:delayed_seq, {x, y}}, 2_000)

        {:noreply, assign(socket, msg: "Clique na janela do JOGO agora! Shift+1+clique em 2s...")}

      :error ->
        {:noreply, assign(socket, msg: "coordenada inválida — use apenas números inteiros")}
    end
  end

  def handle_event("glow_score", _params, socket) do
    # Two quick captures → how much the region CHANGED. Cast the rod and click this
    # while the blue bubbles show: the number spikes. Set the threshold just below.
    with {:ok, calib} <- Calibration.load(),
         {:ok, pa} <- Rig.impl().capture(calib.glow_region, "diag_glow_a.png"),
         {:ok, fa} <- Frame.from_png_file(pa),
         {:ok, pb} <- Rig.impl().capture(calib.glow_region, "diag_glow_b.png"),
         {:ok, fb} <- Frame.from_png_file(pb) do
      variation = Vision.distance(fa, fb)
      threshold = Settings.get(:glow_threshold) || calib.suggested_glow_threshold || 8.0

      {:noreply,
       assign(socket,
         msg:
           "variação: #{Float.round(variation, 2)} | limiar #{threshold} | " <>
             "mordida? #{variation > threshold}"
       )}
    else
      error -> {:noreply, assign(socket, msg: "erro: #{inspect(error)}")}
    end
  end

  def handle_event("find_hostile", _params, socket) do
    with {:ok, calib} <- Calibration.load(),
         {:ok, path} <- Rig.impl().capture(calib.arena_region, "diag_arena.png"),
         {:ok, frame} <- Frame.from_png_file(path) do
      msg =
        case Vision.find_hostile(frame) do
          {:ok, pixel} ->
            "nome vermelho em #{inspect(Calibration.frame_to_screen(calib, calib.arena_region, pixel))} (points)"

          :not_found ->
            "nenhum nome vermelho na arena"
        end

      {:noreply, assign(socket, msg: msg)}
    else
      error -> {:noreply, assign(socket, msg: "erro: #{inspect(error)}")}
    end
  end

  def handle_event("wild_check", _params, socket) do
    with {:ok, calib} <- Calibration.load(),
         {:ok, path} <- Rig.impl().capture(Calibration.battle_strip(calib), "diag_strip.png"),
         {:ok, frame} <- Frame.from_png_file(path) do
      min = Settings.get(:wild_min_red_pixels)
      present = Vision.wild_present?(frame, min_count: min)

      {:noreply,
       assign(socket, msg: "pokébola: #{present} — #{Vision.red_count(frame)} px (limiar #{min})")}
    else
      error -> {:noreply, assign(socket, msg: "erro: #{inspect(error)}")}
    end
  end

  def handle_event("target_locked", _params, socket) do
    with {:ok, calib} <- Calibration.load(),
         {:ok, path} <- Rig.impl().capture(Calibration.battle_body(calib), "diag_target.png"),
         {:ok, frame} <- Frame.from_png_file(path) do
      min = Settings.get(:target_locked_min_pixels)
      locked = Vision.target_locked?(frame, min_count: min)

      {:noreply,
       assign(socket,
         msg: "alvo travado? #{locked} — #{Vision.red_count(frame)} px (limiar #{min})"
       )}
    else
      error -> {:noreply, assign(socket, msg: "erro: #{inspect(error)}")}
    end
  end

  @impl true
  def handle_info({:delayed_press, combo}, socket) do
    {:noreply, assign(socket, msg: "press #{combo} → #{inspect(Rig.impl().press(combo))}")}
  end

  def handle_info({:delayed_seq, point}, socket) do
    {:noreply,
     assign(socket, msg: "capture_sequence → #{inspect(Rig.impl().capture_sequence(point))}")}
  end

  defp parse_ints(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case Integer.parse(String.trim(value)) do
        {n, ""} -> {:cont, {:ok, acc ++ [n]}}
        _ -> {:halt, :error}
      end
    end)
  end

  defp parse_button("left"), do: {:ok, :left}
  defp parse_button("right"), do: {:ok, :right}
  defp parse_button(_), do: :error

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_page={:diagnostics}>
      <div class="space-y-4">
        <header>
          <h1 class="text-xl font-bold">Diagnóstico</h1>
          <p class="mt-1 text-sm opacity-70">
            Laboratório manual: teste cada ação e cada detecção olhando o jogo.
            Nada aqui liga o bot — são disparos avulsos.
          </p>
        </header>

        <div class="flex min-h-10 items-center gap-2 rounded-lg border border-base-content/10 bg-base-300 px-3 py-2 font-mono text-sm">
          <.icon name="hero-chevron-right" class="size-4 shrink-0 text-primary" />
          <span :if={@msg}>{@msg}</span>
          <span :if={is_nil(@msg)} class="opacity-40">resultado aparece aqui…</span>
        </div>

        <div class="grid gap-4 sm:grid-cols-2">
          <section class="space-y-2 rounded-xl border border-base-content/10 bg-base-200 p-4">
            <h2 class="text-sm font-semibold">
              Teclas <span class="font-normal opacity-50">(2s para focar o jogo)</span>
            </h2>
            <div class="flex flex-wrap gap-2">
              <button class="btn btn-sm" phx-click="press" phx-value-combo="shift+z">Shift+Z</button>
              <button class="btn btn-sm" phx-click="press" phx-value-combo="1">Tecla 1</button>
              <button class="btn btn-sm" phx-click="press" phx-value-combo="2">Tecla 2</button>
            </div>
          </section>

          <section class="space-y-2 rounded-xl border border-base-content/10 bg-base-200 p-4">
            <h2 class="text-sm font-semibold">Clique em coordenada</h2>
            <form id="click-form" phx-submit="click" class="flex flex-wrap items-end gap-2">
              <input name="x" value="800" class="input input-bordered input-sm w-20" />
              <input name="y" value="400" class="input input-bordered input-sm w-20" />
              <select name="button" class="select select-bordered select-sm">
                <option value="left">left</option>
                <option value="right">right</option>
              </select>
              <button class="btn btn-sm">Clicar</button>
            </form>
          </section>

          <section class="space-y-2 rounded-xl border border-base-content/10 bg-base-200 p-4">
            <h2 class="text-sm font-semibold">Captura de região</h2>
            <form id="capture-form" phx-submit="capture" class="flex flex-wrap items-end gap-2">
              <input name="x" value="0" class="input input-bordered input-sm w-16" />
              <input name="y" value="0" class="input input-bordered input-sm w-16" />
              <input name="w" value="400" class="input input-bordered input-sm w-16" />
              <input name="h" value="300" class="input input-bordered input-sm w-16" />
              <button class="btn btn-sm">Capturar</button>
            </form>
            <img
              :if={@capture_src}
              src={@capture_src}
              class="mt-2 max-w-full rounded border border-base-content/20"
            />
          </section>

          <section class="space-y-2 rounded-xl border border-base-content/10 bg-base-200 p-4">
            <h2 class="text-sm font-semibold">
              Sequência de captura <span class="font-normal opacity-50">(Shift+1 + clique)</span>
            </h2>
            <form id="seq-form" phx-submit="capture_seq" class="flex flex-wrap items-end gap-2">
              <input name="x" value="800" class="input input-bordered input-sm w-20" />
              <input name="y" value="400" class="input input-bordered input-sm w-20" />
              <button class="btn btn-sm btn-warning">Testar em 2s</button>
            </form>
          </section>
        </div>

        <section
          :if={@calibrated?}
          class="space-y-2 rounded-xl border border-base-content/10 bg-base-200 p-4"
        >
          <h2 class="text-sm font-semibold">
            Visão <span class="font-normal opacity-50">(usa a calibração salva)</span>
          </h2>
          <div class="flex flex-wrap gap-2">
            <button class="btn btn-sm" phx-click="glow_score">Variação (bolhas)</button>
            <button class="btn btn-sm" phx-click="find_hostile">Procurar nome vermelho</button>
            <button class="btn btn-sm" phx-click="wild_check">Pokébola presente?</button>
            <button class="btn btn-sm" phx-click="target_locked">Alvo travado?</button>
          </div>
        </section>

        <div
          :if={not @calibrated?}
          class="rounded-lg bg-base-200 px-3 py-2 text-xs opacity-70"
        >
          Os testes de visão aparecem depois que você <.link
            navigate={~p"/calibration"}
            class="link link-primary"
          >calibrar</.link>.
        </div>
      </div>
    </Layouts.app>
    """
  end
end
