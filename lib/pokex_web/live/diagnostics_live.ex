defmodule PokexWeb.DiagnosticsLive do
  use PokexWeb, :live_view

  alias Pokex.Bots.Capture
  alias Pokex.Bots.Catcher.SpotScan
  alias Pokex.Calibration
  alias Pokex.Rig
  alias Pokex.Settings
  alias Pokex.Vision
  alias Pokex.Vision.Frame
  alias Pokex.Vision.Glyphs
  alias PokexWeb.CalibrationOverlay

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Diagnóstico",
       msg: nil,
       capture_src: nil,
       preview: nil,
       xray: nil,
       unknown_glyphs: [],
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
    # Cyan bubble pixels in the same expanded region used by the worker. Cast the
    # rod and click this while the blue bubbles show: the count should spike above
    # calm water, and it exercises ScreenCaptureKit when that backend is active.
    with {:ok, calib} <- Calibration.load(),
         region <- Calibration.glow_search_region(calib, Settings.get(:glow_search_margin) || 0),
         {:ok, frame} <- Capture.frame_uncached(region, "diag_glow.png") do
      signal = Vision.fishing_signal(frame, fishing_signal_opts(calib, region, frame))
      count = signal.bubble_count
      threshold = Settings.get(:glow_threshold) || 500

      {:noreply,
       assign(socket,
         msg:
           "bolhas: #{count} px | isca #{signal.lure_count}px | linha? #{signal.line_present?} | região #{inspect(region)} | limiar #{threshold} | mordida? #{count > threshold}"
       )}
    else
      error -> {:noreply, assign(socket, msg: "erro: #{inspect(error)}")}
    end
  end

  # Every "?" in the panel is one glyph this install has never seen. Rather
  # than wait for a developer to catch a screenshot with that digit in it, scan
  # the HUD, show whatever came back unreadable, and let him name it.
  def handle_event("scan_glyphs", _params, socket) do
    case Pokex.Layout.locate() do
      {:ok, fix} ->
        unknown =
          [:level, :food, :fishing, :slot_f1, :slot_f2, :slot_e, :slot_s_q]
          |> Enum.flat_map(&unknown_in_region(fix, &1, "feed_hud.png", :hud_bottom))
          |> Kernel.++(unknown_in_region(fix, :pokemon_hp, "feed_team.png", :team_column))
          |> Kernel.++(unknown_in_region(fix, :minimap_coord, "feed_minimap.png", :minimap))
          |> Enum.uniq_by(& &1.signature)

        msg =
          if unknown == [],
            do: "nenhum glifo desconhecido — tudo que está na tela é legível",
            else: "#{length(unknown)} glifo(s) que eu não sei ler: diga o que são"

        {:noreply, assign(socket, unknown_glyphs: unknown, msg: msg)}

      {:error, reason} ->
        {:noreply, assign(socket, msg: "HUD não localizado (#{inspect(reason)})")}
    end
  end

  def handle_event("teach_glyph", %{"signature" => signature, "char" => char}, socket) do
    char = String.trim(char)

    case char != "" && Glyphs.teach(signature, char) do
      {:ok, total} ->
        remaining = Enum.reject(socket.assigns.unknown_glyphs, &(&1.signature == signature))

        {:noreply,
         assign(socket,
           unknown_glyphs: remaining,
           msg: "aprendi \"#{char}\" — #{total} glifos conhecidos agora"
         )}

      {:error, :already_known} ->
        {:noreply, assign(socket, msg: "esse glifo já era conhecido")}

      _blank ->
        {:noreply, socket}
    end
  end

  def handle_event("find_hostile", _params, socket) do
    with {:ok, calib} <- Calibration.load(),
         {:ok, region} <- SpotScan.region(calib),
         {:ok, path} <- Rig.impl().capture(region, "diag_hostile.png"),
         {:ok, frame} <- Frame.from_png_file(path) do
      msg =
        case Vision.find_hostile(frame) do
          {:ok, pixel} ->
            "nome vermelho em #{inspect(Calibration.frame_to_screen(calib, region, pixel))} (points)"

          :not_found ->
            "nenhum nome vermelho no quadro em volta do personagem"
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

  def handle_event("detect_rows", _params, socket) do
    with {:ok, calib} <- Calibration.load(),
         {:ok, path} <- Rig.impl().capture(Calibration.battle_body(calib), "diag_rows.png"),
         {:ok, frame} <- Frame.from_png_file(path) do
      detected = Vision.hp_bar_rows(frame)
      {top, band} = Calibration.row_band_geometry(calib.scale, Settings.get(:battle_row_height))
      rows = Settings.get(:battle_max_rows)
      calibrated = for i <- 0..(rows - 1)//1, do: top + i * band + div(band, 2)

      {:noreply,
       assign(socket,
         msg:
           "barras de HP (frame-y): #{inspect(detected, charlists: :as_lists)} · bandas " <>
             "calibradas (centro): #{inspect(calibrated)} — se não baterem, a Battle está torta"
       )}
    else
      error -> {:noreply, assign(socket, msg: "erro: #{inspect(error)}")}
    end
  end

  # Raio-X: capture the decisive evidence for the "all region reads = 0 but the
  # overlay looks right" bug. If `screencapture -R` (region) and full-screen
  # `screencapture` capture at DIFFERENT resolutions (Retina 1x vs 2x), the scale
  # probe and the click coordinates disagree, so every absolute-coordinate region
  # capture lands in the wrong place. Compare the -R probe scale to the full-screen
  # scale, and SHOW the actual battle-body capture so we can see what the bot sees.
  def handle_event("xray", _params, socket) do
    with {:ok, calib} <- Calibration.load(),
         {:ok, probe_path} <- Capture.grab({0, 0, 100, 100}, "xray_probe.png"),
         {:ok, {probe_px, _}} <- Frame.png_dimensions(probe_path),
         {:ok, screen_path} <- Capture.screen("xray_screen.png"),
         {:ok, {full_px_w, full_px_h}} <- Frame.png_dimensions(screen_path),
         body_region = Calibration.battle_body(calib),
         {:ok, body_path} <- Rig.impl().capture(body_region, "xray_body.png"),
         {:ok, {body_px_w, body_px_h}} <- Frame.png_dimensions(body_path),
         {:ok, body_frame} <- Frame.from_png_file(body_path) do
      r_scale = probe_px / 100
      full_scale = if calib.screen_w in [nil, 0], do: nil, else: full_px_w / calib.screen_w

      xray = %{
        calib_scale: calib.scale,
        screen_w: calib.screen_w,
        screen_h: calib.screen_h,
        probe_px: probe_px,
        r_scale: r_scale,
        full_px: {full_px_w, full_px_h},
        full_scale: full_scale,
        battle_region: calib.battle_region,
        body_region: body_region,
        body_px: {body_px_w, body_px_h},
        body_reds: Vision.red_count(body_frame),
        body_bars: Vision.hp_bar_rows(body_frame),
        body_src: "/captures/#{Path.basename(body_path)}?t=#{System.unique_integer([:positive])}"
      }

      {verdict_kind, verdict_text} = xray_verdict(xray)
      xray = Map.merge(xray, %{verdict_kind: verdict_kind, verdict_text: verdict_text})

      {:noreply, assign(socket, xray: xray, msg: "raio-x capturado")}
    else
      error -> {:noreply, assign(socket, msg: "erro no raio-x: #{inspect(error)}")}
    end
  end

  def handle_event("close_xray", _params, socket) do
    {:noreply, assign(socket, xray: nil)}
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

  defp fishing_signal_opts(calib, region, frame) do
    [
      min_lure_pixels: Settings.get(:fishing_lure_min_pixels) || 20,
      bubble_radius_px: Settings.get(:fishing_bubble_radius_px) || 48,
      line_present_min_px: Settings.get(:line_present_min_px) || 100,
      expected_center: expected_glow_center(calib, region, frame)
    ]
  end

  defp expected_glow_center(%Calibration{glow_region: {gx, gy, gw, gh}}, {rx, ry, rw, rh}, frame)
       when rw > 0 and rh > 0 do
    {
      round((gx + gw / 2 - rx) * frame.width / rw),
      round((gy + gh / 2 - ry) * frame.height / rh)
    }
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
  # Via the Capture broker: same display as the production feeds (see Capture.screen/2).
  defp grab_screen do
    with {:ok, probe_path} <- Capture.grab({0, 0, 100, 100}, "diag_scale_probe.png"),
         {:ok, {probe_px, _}} <- Frame.png_dimensions(probe_path),
         {:ok, screen_path} <- Capture.screen("diag_screen.png"),
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

  # The one-line diagnosis from the raio-x numbers.
  defp xray_verdict(%{r_scale: r, full_scale: f})
       when is_number(r) and is_number(f) and abs(r - f) > 0.25 do
    {:error,
     "ESCALA INCONSISTENTE: o probe -R captura em #{fmt(r)}× e a tela cheia em #{fmt(f)}×. " <>
       "Por isso TODA captura de região cai no lugar errado (lê 0) enquanto o overlay, que é " <>
       "relativo, parece certo. Precisa recalibrar com a escala corrigida."}
  end

  defp xray_verdict(%{body_reds: 0}) do
    {:error,
     "A captura do painel Batalha não pegou NADA vermelho (0px), mesmo com bicho travado na " <>
       "lista. A região está apontando pro lugar errado — provável coordenada/escala."}
  end

  defp xray_verdict(%{body_reds: reds}) do
    {:ok,
     "Escala consistente e a captura do painel tem #{reds}px vermelhos — o problema é outro."}
  end

  defp fmt(n) when is_number(n), do: :erlang.float_to_binary(n / 1, decimals: 2)
  defp fmt(other), do: to_string(other)

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

  # The region rects are absolute; a feed frame is the panel crop, so each read
  # shifts by that panel's own origin.
  defp unknown_in_region(fix, region, filename, panel) do
    with {panel_rect, region_rect} when not is_nil(panel_rect) and not is_nil(region_rect) <-
           {Pokex.Layout.region(panel, fix), Pokex.Layout.region(region, fix)},
         {px, py, pw, ph} = panel_rect,
         {rx, ry, rw, rh} = region_rect,
         {:ok, frame} <- Capture.frame({px, py, pw, ph}, filename) do
      Glyphs.unknown_in(
        frame,
        {rx - px, ry - py, rw, rh},
        Pokex.Layout.region_opts(fix, region)
      )
    else
      _unavailable -> []
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_page={:diagnostics} {Layouts.header(assigns)}>
      <div class="space-y-4">
        <header>
          <h1 class="text-xl font-bold">Diagnóstico</h1>
          <p class="mt-1 text-sm opacity-70">
            Laboratório manual: teste cada ação e cada detecção olhando o jogo.
            Nada aqui liga o bot — são disparos avulsos.
          </p>
        </header>

        <section class="space-y-3 rounded-2xl border border-base-content/10 bg-base-200 p-5">
          <div class="flex items-start justify-between gap-3">
            <div>
              <h2 class="text-sm font-bold">Ensinar glifos</h2>
              <p class="mt-0.5 text-xs leading-relaxed opacity-60">
                Todo "?" no painel é UM caractere que esta instalação nunca viu — um dígito que
                nunca esteve na tela quando as capturas foram feitas. Varra o HUD, olhe o
                desenho e diga o que é: fica sabido pra sempre, e sobrevive a atualizações.
              </p>
            </div>
            <button class="btn btn-sm btn-primary shrink-0" phx-click="scan_glyphs">
              Varrer HUD
            </button>
          </div>

          <ul :if={@unknown_glyphs != []} class="flex flex-wrap gap-3">
            <li
              :for={glyph <- @unknown_glyphs}
              class="flex items-center gap-3 rounded-lg border border-base-content/20 bg-base-300 p-3"
            >
              <div class="flex flex-col gap-px">
                <div :for={row <- glyph.bitmap} class="flex gap-px">
                  <span
                    :for={cell <- row}
                    class={[
                      "size-1.5",
                      if(cell == 1, do: "bg-base-content", else: "bg-transparent")
                    ]}
                  />
                </div>
              </div>
              <form phx-submit="teach_glyph" class="flex items-center gap-2">
                <input type="hidden" name="signature" value={glyph.signature} />
                <input
                  name="char"
                  maxlength="2"
                  autocomplete="off"
                  placeholder="?"
                  class="input input-bordered input-sm w-14 text-center font-mono"
                />
                <button class="btn btn-sm">Aprender</button>
              </form>
            </li>
          </ul>
        </section>

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
              <button class="btn btn-sm" phx-click="press" phx-value-combo="shift+v">
                Vara (Shift+V)
              </button>
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
            <button class="btn btn-sm" phx-click="detect_rows">Detectar fileiras (HP)</button>
            <button class="btn btn-sm btn-error" phx-click="xray">
              <.icon name="hero-magnifying-glass" class="size-4" /> Raio-X (escala)
            </button>
            <button class="btn btn-sm btn-primary" phx-click="preview_regions">
              <.icon name="hero-eye" class="size-4" /> Preview das áreas
            </button>
          </div>
        </section>

        <section
          :if={@xray}
          class="space-y-3 rounded-xl border border-error/40 bg-base-200 p-4"
        >
          <div class="flex items-center justify-between">
            <h2 class="text-sm font-semibold">Raio-X da escala/captura</h2>
            <button class="btn btn-ghost btn-xs" phx-click="close_xray">Fechar</button>
          </div>

          <p class={[
            "rounded-lg px-3 py-2 text-sm font-medium",
            @xray.verdict_kind == :error && "bg-error/15 text-error",
            @xray.verdict_kind == :ok && "bg-success/15 text-success"
          ]}>
            {@xray.verdict_text}
          </p>

          <div class="grid gap-x-6 gap-y-1 font-mono text-xs sm:grid-cols-2">
            <span>escala salva (calib): <b>{fmt(@xray.calib_scale)}×</b></span>
            <span>tela salva (points): <b>{@xray.screen_w}×{@xray.screen_h}</b></span>
            <span>probe -R 100×100 → <b>{@xray.probe_px}px</b> (escala -R {fmt(@xray.r_scale)}×)</span>
            <span>
              tela cheia: <b>{elem(@xray.full_px, 0)}×{elem(@xray.full_px, 1)}px</b>
              (escala {fmt(@xray.full_scale)}×)
            </span>
            <span>battle_region (points): <b>{inspect(@xray.battle_region)}</b></span>
            <span>battle_body (points): <b>{inspect(@xray.body_region)}</b></span>
            <span>
              captura da Batalha: <b>{elem(@xray.body_px, 0)}×{elem(@xray.body_px, 1)}px</b>
            </span>
            <span>
              vermelho: <b>{@xray.body_reds}px</b>
              · barras HP: <b>{inspect(@xray.body_bars, charlists: :as_lists)}</b>
            </span>
          </div>

          <div>
            <p class="mb-1 text-xs opacity-70">
              O que o bot capturou como painel Batalha (deveria mostrar a lista de bichos):
            </p>
            <img
              src={@xray.body_src}
              class="max-h-64 rounded border border-error/40 bg-base-300"
            />
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
              skill_bar_region={@preview.calib.skill_bar_region}
              neutral_point={@preview.calib.neutral_point}
              player_point={Calibration.player_point(@preview.calib)}
              bands={
                Calibration.battle_row_bands(
                  @preview.calib,
                  Settings.get(:battle_row_height),
                  Settings.get(:battle_max_rows)
                )
              }
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
