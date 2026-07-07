defmodule PokexWeb.DiagnosticsLive do
  use PokexWeb, :live_view

  alias Pokex.Rig
  alias Pokex.{Calibration, Settings, Vision}
  alias Pokex.Vision.Frame
  alias PokexWeb.CalibrationOverlay

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Diagnóstico",
       msg: nil,
       capture_src: nil,
       preview: nil,
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
    # Cyan bubble pixels in the region. Cast the rod and click this while the blue
    # bubbles show: the count spikes (in-game ~512 vs 0 calm). Set the threshold
    # between them.
    with {:ok, calib} <- Calibration.load(),
         {:ok, path} <- Rig.impl().capture(calib.glow_region, "diag_glow.png"),
         {:ok, frame} <- Frame.from_png_file(path) do
      count = Vision.bubble_count(frame)
      threshold = Settings.get(:glow_threshold) || 500

      {:noreply,
       assign(socket,
         msg: "bolhas: #{count} px ciano | limiar #{threshold} | mordida? #{count > threshold}"
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
      # same {top, band} the live sensor uses — centered on the click point
      {top, band} = Calibration.row_band_geometry(calib.scale, Settings.get(:battle_row_height))
      rows = Settings.get(:battle_max_rows)
      counts = Vision.red_row_counts(frame, top: top, band: band, rows: rows)

      picked =
        case Vision.locked_row(counts, min) do
          {:ok, i} -> "linha #{i}"
          :none -> "nenhuma"
        end

      {:noreply,
       assign(socket,
         msg: "por linha: #{inspect(counts)} — travada: #{picked} (limiar #{min})"
       )}
    else
      error -> {:noreply, assign(socket, msg: "erro: #{inspect(error)}")}
    end
  end

  def handle_event("preview_regions", _params, socket) do
    with {:ok, calib} <- Calibration.load(),
         {:ok, screen} <- grab_screen() do
      {:noreply,
       assign(socket,
         preview: Map.put(screen, :calib, calib),
         msg: "preview das áreas calibradas — vermelho = bandas do lock (L0…)"
       )}
    else
      error -> {:noreply, assign(socket, msg: "erro no preview: #{inspect(error)}")}
    end
  end

  def handle_event("close_preview", _params, socket) do
    {:noreply, assign(socket, preview: nil)}
  end

  @impl true
  def handle_info({:delayed_press, combo}, socket) do
    {:noreply, assign(socket, msg: "press #{combo} → #{inspect(Rig.impl().press(combo))}")}
  end

  def handle_info({:delayed_seq, point}, socket) do
    {:noreply,
     assign(socket, msg: "capture_sequence → #{inspect(Rig.impl().capture_sequence(point))}")}
  end

  # Probe a 100x100 region for the Retina scale, then grab the full screen — same
  # recipe as CalibrationLive, so the preview lines up 1:1 with the saved points.
  defp grab_screen do
    with {:ok, probe_path} <- Rig.impl().capture({0, 0, 100, 100}, "diag_scale_probe.png"),
         {:ok, {probe_px, _}} <- Frame.png_dimensions(probe_path),
         {:ok, screen_path} <- Rig.impl().capture_screen(),
         {:ok, {px_w, px_h}} <- Frame.png_dimensions(screen_path) do
      scale = probe_px / 100

      {:ok,
       %{
         src: "/captures/#{Path.basename(screen_path)}?t=#{System.unique_integer([:positive])}",
         scale: scale,
         w: round(px_w / scale),
         h: round(px_h / scale)
       }}
    end
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
              <button class="btn btn-sm" phx-click="press" phx-value-combo="v">Vara (V)</button>
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
            <button class="btn btn-sm" phx-click="glow_score">Bolhas (ciano)</button>
            <button class="btn btn-sm" phx-click="find_hostile">Procurar nome vermelho</button>
            <button class="btn btn-sm" phx-click="wild_check">Pokébola presente?</button>
            <button class="btn btn-sm" phx-click="target_locked">Alvo travado?</button>
            <button class="btn btn-sm btn-primary" phx-click="preview_regions">
              <.icon name="hero-eye" class="size-4" /> Preview das áreas
            </button>
          </div>
        </section>

        <section
          :if={@preview}
          class="space-y-3 rounded-xl border border-base-content/10 bg-base-200 p-4"
        >
          <div class="flex items-center justify-between">
            <h2 class="text-sm font-semibold">
              Áreas calibradas <span class="font-normal opacity-50">(vermelho = bandas do lock)</span>
            </h2>
            <button class="btn btn-ghost btn-xs" phx-click="close_preview">Fechar</button>
          </div>
          <CalibrationOverlay.legend />
          <div class="relative overflow-hidden rounded-lg border border-base-content/20">
            <img src={@preview.src} class="w-full" />
            <CalibrationOverlay.overlays
              screen={@preview}
              water_point={@preview.calib.water_point}
              glow_region={@preview.calib.glow_region}
              battle_region={@preview.calib.battle_region}
              arena_region={@preview.calib.arena_region}
              neutral_point={@preview.calib.neutral_point}
              player_point={Calibration.player_point(@preview.calib)}
              bands={Calibration.battle_row_bands(@preview.calib, Settings.get(:battle_row_height), Settings.get(:battle_max_rows))}
            />
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
