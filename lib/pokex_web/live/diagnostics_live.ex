defmodule PokexWeb.DiagnosticsLive do
  use PokexWeb, :live_view

  alias Pokex.Bots.Capture
  alias Pokex.Bots.Catcher.SpotScan
  alias Pokex.Bots.KeyProbe
  alias Pokex.Calibration
  alias Pokex.Perception.Interpret.Minimap
  alias Pokex.Rig
  alias Pokex.Rig.Mac.KeyEvents
  alias Pokex.Screenshot
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
       # Each group of actions writes its own result, next to the buttons that
       # produced it — one shared line across eleven unrelated tools meant a
       # click on "Teclas" could bury the answer a scroll away from "Visão".
       glyph_msg: nil,
       tools_msg: nil,
       vision_msg: nil,
       # The one thing shared across delayed actions (press, capture_seq): which
       # one, if any, is still counting down to its 2s window. Disables the
       # triggers so a second click can't start a race against the first.
       pending: nil,
       capture_src: nil,
       preview: nil,
       xray: nil,
       unknown_glyphs: [],
       # Quais dígitos o atlas não tem, POR ALTURA de fonte. Nesta página a
       # lista inteira é o assunto (na Central só a altura que ele lê é), e é
       # ela que diz o que procurar: um dígito ausente não aparece como "?" na
       # tela, aparece como outro dígito.
       glyph_gaps: Glyphs.missing_digits(),
       probe: nil,
       calibrated?: Calibration.exists?(),
       native_status: KeyEvents.status()
     )}
  end

  # THE STANCE KEYS HAVE NO RECEIPT. A skill proves itself with its cooldown
  # (Pokex.Bots.SkillReceipt); shift+1 and shift+3 change a mode and leave
  # nothing on the bar, so they were pressed blind — and they never once worked
  # ("nunca até hoje funcionou isso de mudar para modo de ataque ou defesa com
  # os comandos de shift", 2026-08-12).
  #
  # Two rounds, drained apart, so the two suspects cannot hide behind each
  # other: the NATIVE path alone, then a list carrying a "+" — which drops the
  # WHOLE burst onto osascript (Rig.Mac.native_pressable?/1), putting the plain
  # key and the shifted ones on the very same road.
  @probe_focus_ms 3_000
  @probe_native ["1"]
  @probe_osa ["1", "shift+1", "shift+3"]

  @impl true
  def handle_event("probe_keys", _params, socket) do
    Process.send_after(self(), :probe_native, @probe_focus_ms)

    {:noreply,
     assign(socket,
       probe: %{
         stage: :waiting,
         native: [],
         osa: [],
         error: nil,
         busy?: true,
         helper: KeyEvents.status(),
         hint: "Clique na janela do JOGO agora! Medindo em #{probe_focus_seconds()}s…"
       }
     )}
  end

  def handle_event("press", %{"combo" => combo}, socket) do
    Process.send_after(self(), {:delayed_press, combo}, 2_000)

    {:noreply,
     assign(socket,
       pending: %{hint: "Clique na janela do JOGO agora! Tecla #{combo} em 2s..."}
     )}
  end

  def handle_event("click", %{"x" => x, "y" => y, "button" => button}, socket) do
    with {:ok, [x, y]} <- parse_ints([x, y]),
         {:ok, btn} <- parse_button(button) do
      result = Rig.impl().click(btn, {x, y})
      {:noreply, assign(socket, tools_msg: "click #{btn} → #{inspect(result)}")}
    else
      _ -> {:noreply, assign(socket, tools_msg: "coordenada ou botão inválido")}
    end
  end

  def handle_event("capture", %{"x" => x, "y" => y, "w" => w, "h" => h}, socket) do
    case parse_ints([x, y, w, h]) do
      {:ok, [x, y, w, h]} ->
        case Rig.impl().capture({x, y, w, h}, "diag.png") do
          {:ok, path} ->
            src = "/captures/#{Path.basename(path)}?t=#{System.unique_integer([:positive])}"
            {:noreply, assign(socket, capture_src: src, tools_msg: "capturado")}

          {:error, reason} ->
            {:noreply, assign(socket, tools_msg: "erro na captura: #{inspect(reason)}")}
        end

      :error ->
        {:noreply, assign(socket, tools_msg: "coordenada inválida — use apenas números inteiros")}
    end
  end

  def handle_event("capture_seq", %{"x" => x, "y" => y}, socket) do
    case parse_ints([x, y]) do
      {:ok, [x, y]} ->
        Process.send_after(self(), {:delayed_seq, {x, y}}, 2_000)

        {:noreply,
         assign(socket,
           pending: %{hint: "Clique na janela do JOGO agora! Shift+1+clique em 2s..."}
         )}

      :error ->
        {:noreply, assign(socket, tools_msg: "coordenada inválida — use apenas números inteiros")}
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
         vision_msg:
           "bolhas: #{count} px | isca #{signal.lure_count}px | linha? #{signal.line_present?} | região #{inspect(region)} | limiar #{threshold} | mordida? #{count > threshold}"
       )}
    else
      error -> {:noreply, assign(socket, vision_msg: "erro: #{inspect(error)}")}
    end
  end

  # Every "?" in the panel is one glyph this install has never seen. Rather
  # than wait for a developer to catch a screenshot with that digit in it, scan
  # the HUD, show whatever came back unreadable, and let him name it.
  def handle_event("scan_glyphs", _params, socket) do
    {found, skipped} = sweep_glyphs()

    {:noreply, assign(socket, unknown_glyphs: found, glyph_msg: sweep_msg(found, skipped))}
  end

  def handle_event("teach_glyph", %{"signature" => signature, "char" => char}, socket) do
    char = String.trim(char)

    case char != "" && Glyphs.teach(signature, char) do
      {:ok, total} ->
        remaining = Enum.reject(socket.assigns.unknown_glyphs, &(&1.signature == signature))

        {:noreply,
         assign(socket,
           unknown_glyphs: remaining,
           glyph_gaps: Glyphs.missing_digits(),
           glyph_msg: "aprendi \"#{char}\" — #{total} glifos conhecidos agora"
         )}

      {:error, :already_known} ->
        {:noreply, assign(socket, glyph_msg: "esse glifo já era conhecido")}

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

      {:noreply, assign(socket, vision_msg: msg)}
    else
      error -> {:noreply, assign(socket, vision_msg: "erro: #{inspect(error)}")}
    end
  end

  def handle_event("wild_check", _params, socket) do
    with {:ok, calib} <- Calibration.load(),
         {:ok, path} <- Rig.impl().capture(Calibration.battle_strip(calib), "diag_strip.png"),
         {:ok, frame} <- Frame.from_png_file(path) do
      min = Settings.get(:wild_min_red_pixels)
      present = Vision.wild_present?(frame, min_count: min)

      {:noreply,
       assign(socket,
         vision_msg: "pokébola: #{present} — #{Vision.red_count(frame)} px (limiar #{min})"
       )}
    else
      error -> {:noreply, assign(socket, vision_msg: "erro: #{inspect(error)}")}
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
         vision_msg: "por linha: #{inspect(counts)} — travada: #{picked} (limiar #{min})"
       )}
    else
      error -> {:noreply, assign(socket, vision_msg: "erro: #{inspect(error)}")}
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
         vision_msg:
           "barras de HP (frame-y): #{inspect(detected, charlists: :as_lists)} · bandas " <>
             "calibradas (centro): #{inspect(calibrated)} — se não baterem, a Battle está torta"
       )}
    else
      error -> {:noreply, assign(socket, vision_msg: "erro: #{inspect(error)}")}
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

      {:noreply, assign(socket, xray: xray, vision_msg: "raio-x capturado")}
    else
      error -> {:noreply, assign(socket, vision_msg: "erro no raio-x: #{inspect(error)}")}
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
         vision_msg: "preview das áreas calibradas — vermelho = bandas do lock (L0…)"
       )}
    else
      error -> {:noreply, assign(socket, vision_msg: "erro no preview: #{inspect(error)}")}
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
  def handle_info(:probe_native, socket) do
    {:noreply, fire_probe(socket, :native, @probe_native, :probe_osa)}
  end

  def handle_info(:probe_osa, socket) do
    {:noreply, fire_probe(socket, :osa, @probe_osa, nil)}
  end

  def handle_info({:probe_read, stage, combos, next}, socket) do
    case Rig.impl().key_watch(KeyProbe.codes(combos)) do
      {:ok, sightings} ->
        rows = Enum.map(combos, &%{combo: &1, result: KeyProbe.verdict(&1, sightings)})

        probe =
          socket.assigns.probe
          |> Map.put(stage, rows)
          |> Map.merge(%{stage: stage, hint: probe_msg(stage, next), busy?: next != nil})

        if next, do: send(self(), next)
        {:noreply, assign(socket, probe: probe)}

      # The watcher itself is the instrument; if IT cannot answer, nothing below
      # is a statement about the keys.
      {:error, reason} ->
        probe = %{
          socket.assigns.probe
          | stage: :failed,
            error: inspect(reason),
            busy?: false,
            hint: nil
        }

        {:noreply, assign(socket, probe: probe)}
    end
  end

  def handle_info({:delayed_press, combo}, socket) do
    {:noreply,
     assign(socket,
       pending: nil,
       tools_msg: "press #{combo} → #{inspect(Rig.impl().press(combo))}"
     )}
  end

  def handle_info({:delayed_seq, point}, socket) do
    {:noreply,
     assign(socket,
       pending: nil,
       tools_msg: "capture_sequence → #{inspect(Rig.impl().capture_sequence(point))}"
     )}
  end

  # Arms the watcher (the first call sets the codes AND drains whatever was
  # buffered, so each round is measured clean), fires the burst off the LiveView
  # process — an osascript burst takes ~1.2s and the page must stay alive — and
  # reads back once the keys have had time to land.
  @probe_settle_ms 700
  defp fire_probe(socket, stage, combos, next) do
    codes = KeyProbe.codes(combos)
    Rig.impl().key_watch(codes)

    page = self()

    Task.start(fn ->
      Rig.impl().press_many(combos, tap_count: 2, gap_ms: 80)
      Process.sleep(@probe_settle_ms)
      send(page, {:probe_read, stage, combos, next})
    end)

    assign(socket,
      probe: Map.put(socket.assigns.probe, :hint, "disparando #{Enum.join(combos, ", ")}…")
    )
  end

  defp probe_msg(:native, _next), do: "caminho nativo medido; indo pro osascript…"
  defp probe_msg(_stage, nil), do: "medição encerrada — agora olhe o JOGO"
  defp probe_msg(_stage, _next), do: "medindo…"

  defp probe_focus_seconds, do: div(@probe_focus_ms, 1000)

  attr :title, :string, required: true
  attr :rows, :list, required: true

  defp probe_round(assigns) do
    ~H"""
    <div class="space-y-1.5 rounded-lg border border-pk-line bg-pk-sunken p-3">
      <h3 class="font-mono text-pk-meta font-semibold uppercase tracking-[0.1em] text-pk-text-3">
        {@title}
      </h3>
      <p :if={@rows == []} class="text-pk-meta text-pk-text-3">aguardando…</p>
      <ul class="space-y-1">
        <li :for={row <- @rows} class="flex items-center gap-2 text-pk-body">
          <span class="w-20 font-mono text-pk-text">{row.combo}</span>
          <span class={["font-mono font-semibold", probe_tone(row.result.verdict)]}>
            {probe_label(row.result.verdict)}
          </span>
          <span class="font-mono text-pk-meta text-pk-text-3">{row.result.seen}×</span>
        </li>
      </ul>
    </div>
    """
  end

  defp probe_label(:posted), do: "saiu inteira"
  defp probe_label(:naked), do: "saiu SEM o shift"
  defp probe_label(:silent), do: "não saiu"
  defp probe_label(:unmeasurable), do: "não dá para medir"

  defp probe_tone(:posted), do: "text-pk-ok"
  defp probe_tone(:naked), do: "text-pk-danger"
  defp probe_tone(:silent), do: "text-pk-danger"
  defp probe_tone(:unmeasurable), do: "text-pk-text-3"

  # The readout every group of actions writes into — one per group, next to its
  # own buttons, so a result is never a scroll away from what produced it.
  attr :msg, :string, default: nil
  attr :placeholder, :string, default: "resultado aparece aqui…"

  defp result_line(assigns) do
    ~H"""
    <div class="flex min-h-8 items-center gap-2 rounded-lg border border-pk-line bg-pk-sunken px-3 py-1.5 font-mono text-pk-body">
      <.icon name="hero-chevron-right" class="size-3.5 shrink-0 text-pk-ok" />
      <span :if={@msg} class="text-pk-text-2">{@msg}</span>
      <span :if={is_nil(@msg)} class="text-pk-text-3">{@placeholder}</span>
    </div>
    """
  end

  # Literally the recipe CalibrationLive marks on, so this preview lines up 1:1
  # with the saved points instead of measuring the screen its own way.
  defp grab_screen do
    with {:ok, shot} <- Screenshot.take("diag_screen.png") do
      {:ok,
       Map.put(
         shot,
         :src,
         "/captures/#{Path.basename(shot.path)}?t=#{System.unique_integer([:positive])}"
       )}
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
  # A VARREDURA, pela mesma calibração que o bot usa.
  #
  # Antes ela começava com `Layout.locate/0`, que fotografa a tela e exige que
  # as TRÊS âncoras apareçam. Faltando uma, a função para na primeira e a
  # varredura inteira morria — foi o que ele viu em 27/08:
  # `{:anchor_not_found, :battle_header}`, com a janela de batalha fechada.
  #
  # E o layout era o único caminho, então as marcações À MÃO dele — que são o
  # que o cavebot usa pra ler a coordenada todo dia — não contavam. A faixa que
  # ele PRECISAVA ensinar era exatamente a que ele tinha marcado.
  #
  # Agora cada região se resolve sozinha, na ordem do bot (mão ganha, layout é
  # reserva), e uma que não resolve é PULADA com o motivo, não fatal.
  defp sweep_glyphs do
    calib =
      case Calibration.load() do
        {:ok, calib} -> calib
        _none -> %Calibration{scale: 1.0, layout: nil}
      end

    calib = %{calib | layout: calib.layout || Pokex.Layout.current()}

    {found, skipped} =
      Enum.reduce(sweep_targets(calib), {[], []}, fn {label, target}, {found, skipped} ->
        case sweep_one(target) do
          {:ok, glyphs} -> {found ++ glyphs, skipped}
          {:skip, why} -> {found, skipped ++ ["#{label} (#{why})"]}
        end
      end)

    {Enum.uniq_by(found, & &1.signature), skipped}
  end

  # A faixa da coordenada PRIMEIRO: é a que ele lê o dia inteiro, a única que
  # sobrevive sem layout, e a do buraco do 8. As opções dela vêm do leitor de
  # verdade — um glifo cortado noutro piso de tinta é outro bitmap, e o atlas
  # aprenderia uma forma que o leitor nunca produz.
  @doc false
  def sweep_targets(calib) do
    fix = calib.layout

    coord =
      {"coordenada",
       %{
         panel: Calibration.minimap_capture_region(calib),
         region: Calibration.minimap_coord_region(calib),
         opts: Minimap.coord_opts(calib, Settings.all()),
         file: "diag_glyphs_coord.raw"
       }}

    hud =
      for region <- [:level, :food, :fishing, :slot_f1, :slot_f2, :slot_e, :slot_s_q] do
        {"HUD/#{region}", layout_target(fix, region, :hud_bottom, "diag_glyphs_hud.raw")}
      end

    team = [
      {"time/pokemon_hp", layout_target(fix, :pokemon_hp, :team_column, "diag_glyphs_team.raw")}
    ]

    [coord | hud ++ team]
  end

  defp layout_target(fix, region, panel, file),
    do: %{
      panel: Pokex.Layout.region(panel, fix),
      region: Pokex.Layout.region(region, fix),
      opts: Pokex.Layout.region_opts(fix, region),
      file: file
    }

  defp sweep_one(%{panel: nil}), do: {:skip, "sem layout nem marcação"}
  defp sweep_one(%{region: nil}), do: {:skip, "sem layout nem marcação"}

  defp sweep_one(%{panel: {px, py, pw, ph}, region: {rx, ry, rw, rh}} = target) do
    case Capture.frame({px, py, pw, ph}, target.file) do
      {:ok, frame} ->
        {:ok, Glyphs.uncertain_in(frame, {rx - px, ry - py, rw, rh}, target.opts)}

      {:error, reason} ->
        {:skip, inspect(reason)}
    end
  end

  # Uma linha por ALTURA de fonte, que é como uma fonte funciona: todos os
  # dígitos dela têm a mesma altura, e larguras diferentes por desenho.
  defp gap_line(faltam) do
    Enum.map_join(Enum.sort(faltam), " · ", fn {altura, digitos} ->
      "#{altura}px: #{Enum.join(digitos, " ")}"
    end)
  end

  defp sweep_msg([], []), do: "nada pra varrer: nenhuma região resolveu"

  defp sweep_msg([], skipped),
    do: "nenhum glifo duvidoso no que deu pra ler" <> skipped_tail(skipped)

  defp sweep_msg(found, skipped),
    do:
      "#{length(found)} glifo(s) que eu não sei de verdade: confira o desenho e diga o que são" <>
        skipped_tail(skipped)

  defp skipped_tail([]), do: ""
  defp skipped_tail(skipped), do: " · pulei #{Enum.join(skipped, ", ")}"

  defp native_ready?(:ready), do: true
  defp native_ready?(_other), do: false

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_page={:diagnostics} {Layouts.header(assigns)}>
      <div class="space-y-4">
        <header class="flex flex-wrap items-start justify-between gap-3">
          <div>
            <h1 class="text-pk-title font-bold text-pk-text">Diagnóstico</h1>
            <p class="mt-1 text-pk-body text-pk-text-2">
              Laboratório manual: teste cada ação e cada detecção olhando o jogo.
              Nada aqui liga o bot — são disparos avulsos.
            </p>
          </div>

          <div class="flex flex-wrap items-center gap-2">
            <span class="flex items-center gap-2 rounded-full border border-pk-line-strong px-2.5 py-1 font-mono text-pk-meta font-bold uppercase tracking-[0.14em] text-pk-text-2">
              <span class={[
                "size-1.5 rounded-full",
                if(@calibrated?, do: "bg-pk-ok", else: "bg-pk-text-3")
              ]} />
              {if @calibrated?, do: "Calibrado", else: "Não calibrado"}
            </span>
            <span class="flex items-center gap-2 rounded-full border border-pk-line-strong px-2.5 py-1 font-mono text-pk-meta font-bold uppercase tracking-[0.14em] text-pk-text-2">
              <span class={[
                "size-1.5 rounded-full",
                if(native_ready?(@native_status), do: "bg-pk-ok", else: "bg-pk-warn")
              ]} />
              {if native_ready?(@native_status),
                do: "Ajudante nativo pronto",
                else: "Ajudante nativo: #{@native_status}"}
            </span>
            <.link
              :if={not @calibrated?}
              id="status-calibrate-link"
              navigate={~p"/calibration"}
              class="font-mono text-pk-meta text-pk-ok hover:underline"
            >
              calibrar →
            </.link>
          </div>
        </header>

        <section
          id="key-probe"
          class="space-y-3 rounded-2xl border border-pk-warn-line/40 bg-pk-surface p-5"
        >
          <div>
            <h2 class="font-mono text-pk-meta font-bold uppercase tracking-[0.12em] text-pk-warn">
              A tecla chegou? (modo de ataque / defesa)
            </h2>
            <p class="mt-1 text-pk-body leading-relaxed text-pk-text-2">
              As skills provam que saíram pelo <b class="text-pk-text">cooldown</b>. O
              <b class="text-pk-text">shift+1</b>
              e o <b class="text-pk-text">shift+3</b>
              mudam um modo e não gastam nada, então sempre foram apertados <b class="text-pk-text">às cegas</b>. Aqui a máquina se escuta: dispara e depois lê
              o teclado de verdade para dizer se a tecla saiu <b class="text-pk-text">e se o shift foi junto</b>.
            </p>
          </div>

          <div class="flex flex-wrap items-center gap-3">
            <button
              class="btn btn-sm h-8 border border-pk-warn-line bg-pk-warn-dim px-4 font-mono text-pk-body font-semibold text-pk-warn hover:bg-pk-warn-dim/70 disabled:cursor-not-allowed disabled:opacity-50"
              phx-click="probe_keys"
              disabled={@probe && @probe.busy?}
            >
              <span :if={@probe && @probe.busy?} class="loading loading-spinner loading-xs" />
              Medir as teclas de modo
            </button>
            <span class="text-pk-meta text-pk-text-3">
              clique e vá para o JOGO — o disparo sai em {probe_focus_seconds()}s
            </span>
          </div>

          <div :if={@probe} class="space-y-3">
            <p :if={@probe.hint} class="font-mono text-pk-body text-pk-text-2">
              {@probe.hint}
            </p>
            <p :if={@probe.helper != :ready} class="text-pk-body text-pk-danger">
              O ajudante nativo está <b class="font-mono">{@probe.helper}</b>
              — sem ele não há leitura nenhuma, e nada abaixo significa coisa alguma.
            </p>
            <p :if={@probe.error} class="text-pk-body text-pk-danger">
              A leitura falhou: <span class="font-mono">{@probe.error}</span>
            </p>

            <div class="grid gap-3 sm:grid-cols-2">
              <.probe_round title="Caminho nativo (controle)" rows={@probe.native} />
              <.probe_round title="Caminho osascript (é por aqui que o shift vai)" rows={@probe.osa} />
            </div>

            <p :if={@probe.stage == :osa} class="text-pk-meta leading-relaxed text-pk-text-3">
              Isto diz só o que <b class="text-pk-text-2">o macOS viu sair</b>. Se tudo acima
              estiver verde e mesmo assim o modo <b class="text-pk-text-2">não mudar no jogo</b>,
              então a tecla morre do outro lado da janela — e essa parte só o seu olho na tela
              responde.
            </p>
          </div>
        </section>

        <section
          :if={@calibrated?}
          class="space-y-3 rounded-2xl border border-pk-line bg-pk-surface p-5"
        >
          <h2 class="font-mono text-pk-meta font-bold uppercase tracking-[0.12em] text-pk-text-3">
            Visão <span class="normal-case text-pk-text-3">— usa a calibração salva</span>
          </h2>
          <div class="flex flex-wrap gap-2">
            <button
              class="btn btn-xs h-7 border border-pk-line-strong bg-transparent px-3 text-pk-body text-pk-text-2 hover:bg-pk-raised hover:text-white"
              phx-click="glow_score"
            >
              Bolhas (ciano)
            </button>
            <button
              class="btn btn-xs h-7 border border-pk-line-strong bg-transparent px-3 text-pk-body text-pk-text-2 hover:bg-pk-raised hover:text-white"
              phx-click="find_hostile"
            >
              Procurar nome vermelho
            </button>
            <button
              class="btn btn-xs h-7 border border-pk-line-strong bg-transparent px-3 text-pk-body text-pk-text-2 hover:bg-pk-raised hover:text-white"
              phx-click="wild_check"
            >
              Pokébola presente?
            </button>
            <button
              class="btn btn-xs h-7 border border-pk-line-strong bg-transparent px-3 text-pk-body text-pk-text-2 hover:bg-pk-raised hover:text-white"
              phx-click="target_locked"
            >
              Alvo travado?
            </button>
            <button
              class="btn btn-xs h-7 border border-pk-line-strong bg-transparent px-3 text-pk-body text-pk-text-2 hover:bg-pk-raised hover:text-white"
              phx-click="detect_rows"
            >
              Detectar fileiras (HP)
            </button>
            <button
              class="btn btn-xs h-7 border border-pk-danger-line bg-transparent px-3 text-pk-body text-pk-danger hover:bg-pk-danger-dim"
              phx-click="xray"
            >
              <.icon name="hero-magnifying-glass" class="size-3.5" /> Raio-X (escala)
            </button>
            <button
              class="btn btn-xs h-7 border border-pk-ok-line bg-transparent px-3 text-pk-body font-semibold text-pk-ok hover:bg-pk-ok-dim"
              phx-click="preview_regions"
            >
              <.icon name="hero-eye" class="size-3.5" /> Preview das áreas
            </button>
          </div>

          <.result_line msg={@vision_msg} />

          <section
            :if={@xray}
            class="space-y-3 rounded-xl border border-pk-danger-line bg-pk-sunken p-4"
          >
            <div class="flex items-center justify-between">
              <h3 class="font-mono text-pk-meta font-bold uppercase tracking-[0.12em] text-pk-text-3">
                Raio-X da escala/captura
              </h3>
              <button
                class="btn btn-ghost btn-xs h-6 text-pk-text-2 hover:text-white"
                phx-click="close_xray"
              >
                Fechar
              </button>
            </div>

            <p class={[
              "rounded-lg px-3 py-2 text-pk-body font-medium",
              @xray.verdict_kind == :error && "bg-pk-danger-dim text-pk-danger",
              @xray.verdict_kind == :ok && "bg-pk-ok-dim text-pk-ok"
            ]}>
              {@xray.verdict_text}
            </p>

            <div class="grid gap-x-6 gap-y-1 font-mono text-pk-meta text-pk-text-2 sm:grid-cols-2">
              <span>escala salva (calib): <b class="text-pk-text">{fmt(@xray.calib_scale)}×</b></span>
              <span>
                tela salva (points): <b class="text-pk-text">{@xray.screen_w}×{@xray.screen_h}</b>
              </span>
              <span>
                probe -R 100×100 → <b class="text-pk-text">{@xray.probe_px}px</b>
                (escala -R {fmt(@xray.r_scale)}×)
              </span>
              <span>
                tela cheia:
                <b class="text-pk-text">{elem(@xray.full_px, 0)}×{elem(@xray.full_px, 1)}px</b>
                (escala {fmt(@xray.full_scale)}×)
              </span>
              <span>battle_region (points): <b class="text-pk-text">{inspect(@xray.battle_region)}</b></span>
              <span>battle_body (points): <b class="text-pk-text">{inspect(@xray.body_region)}</b></span>
              <span>
                captura da Batalha:
                <b class="text-pk-text">{elem(@xray.body_px, 0)}×{elem(@xray.body_px, 1)}px</b>
              </span>
              <span>
                vermelho: <b class="text-pk-text">{@xray.body_reds}px</b>
                · barras HP:
                <b class="text-pk-text">{inspect(@xray.body_bars, charlists: :as_lists)}</b>
              </span>
            </div>

            <div>
              <p class="mb-1 text-pk-meta text-pk-text-3">
                O que o bot capturou como painel Batalha (deveria mostrar a lista de bichos):
              </p>
              <img
                src={@xray.body_src}
                class="max-h-64 rounded border border-pk-danger-line bg-pk-bg"
              />
            </div>
          </section>

          <section :if={@preview} class="space-y-3 rounded-xl border border-pk-line bg-pk-sunken p-4">
            <div class="flex items-center justify-between">
              <h3 class="font-mono text-pk-meta font-bold uppercase tracking-[0.12em] text-pk-text-3">
                Áreas calibradas
                <span class="normal-case text-pk-text-3">— vermelho = bandas do lock</span>
              </h3>
              <button
                class="btn btn-ghost btn-xs h-6 text-pk-text-2 hover:text-white"
                phx-click="close_preview"
              >
                Fechar
              </button>
            </div>
            <CalibrationOverlay.legend />
            <div class="relative overflow-hidden rounded-lg border border-pk-line">
              <img src={@preview.src} class="w-full" />
              <CalibrationOverlay.overlays
                screen={@preview}
                water_point={@preview.calib.water_point}
                glow_region={@preview.calib.glow_region}
                battle_region={@preview.calib.battle_region}
                skill_bar_region={@preview.calib.skill_bar_region}
                skill_bar_count={@preview.calib.skill_bar_count || 0}
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
        </section>

        <div
          :if={not @calibrated?}
          class="rounded-lg border border-pk-line bg-pk-sunken px-3 py-2 text-pk-meta text-pk-text-2"
        >
          Os testes de visão aparecem depois que você <.link
            navigate={~p"/calibration"}
            class="text-pk-ok hover:underline"
          >calibrar</.link>.
        </div>

        <section class="space-y-3 rounded-2xl border border-pk-line bg-pk-surface p-5">
          <h2 class="font-mono text-pk-meta font-bold uppercase tracking-[0.12em] text-pk-text-3">
            Ferramentas avulsas
          </h2>

          <div class="grid gap-3 sm:grid-cols-2">
            <div class="space-y-2 rounded-lg border border-pk-line bg-pk-sunken p-3">
              <h3 class="font-mono text-pk-meta text-pk-text-3">
                Teclas <span class="normal-case">(2s para focar o jogo)</span>
              </h3>
              <div class="flex flex-wrap gap-2">
                <button
                  class="btn btn-xs h-7 border border-pk-line-strong bg-transparent px-3 text-pk-body text-pk-text-2 hover:bg-pk-raised hover:text-white disabled:cursor-not-allowed disabled:opacity-50"
                  phx-click="press"
                  phx-value-combo="shift+v"
                  disabled={@pending != nil}
                >
                  Vara (Shift+V)
                </button>
                <button
                  class="btn btn-xs h-7 border border-pk-line-strong bg-transparent px-3 text-pk-body text-pk-text-2 hover:bg-pk-raised hover:text-white disabled:cursor-not-allowed disabled:opacity-50"
                  phx-click="press"
                  phx-value-combo="1"
                  disabled={@pending != nil}
                >
                  Tecla 1
                </button>
                <button
                  class="btn btn-xs h-7 border border-pk-line-strong bg-transparent px-3 text-pk-body text-pk-text-2 hover:bg-pk-raised hover:text-white disabled:cursor-not-allowed disabled:opacity-50"
                  phx-click="press"
                  phx-value-combo="2"
                  disabled={@pending != nil}
                >
                  Tecla 2
                </button>
              </div>
            </div>

            <div class="space-y-2 rounded-lg border border-pk-line bg-pk-sunken p-3">
              <h3 class="font-mono text-pk-meta text-pk-text-3">Clique em coordenada</h3>
              <form id="click-form" phx-submit="click" class="flex flex-wrap items-end gap-2">
                <input
                  name="x"
                  value="800"
                  class="h-8 w-20 rounded-lg border border-pk-line-strong bg-pk-raised px-2 font-mono text-pk-meta text-pk-text"
                />
                <input
                  name="y"
                  value="400"
                  class="h-8 w-20 rounded-lg border border-pk-line-strong bg-pk-raised px-2 font-mono text-pk-meta text-pk-text"
                />
                <select
                  name="button"
                  class="h-8 rounded-lg border border-pk-line-strong bg-pk-raised px-2 font-mono text-pk-meta text-pk-text"
                >
                  <option value="left">left</option>
                  <option value="right">right</option>
                </select>
                <button class="btn btn-xs h-8 border border-pk-line-strong bg-transparent px-3 text-pk-body text-pk-text-2 hover:bg-pk-raised hover:text-white">
                  Clicar
                </button>
              </form>
            </div>

            <div class="space-y-2 rounded-lg border border-pk-line bg-pk-sunken p-3">
              <h3 class="font-mono text-pk-meta text-pk-text-3">Captura de região</h3>
              <form id="capture-form" phx-submit="capture" class="flex flex-wrap items-end gap-2">
                <input
                  name="x"
                  value="0"
                  class="h-8 w-16 rounded-lg border border-pk-line-strong bg-pk-raised px-2 font-mono text-pk-meta text-pk-text"
                />
                <input
                  name="y"
                  value="0"
                  class="h-8 w-16 rounded-lg border border-pk-line-strong bg-pk-raised px-2 font-mono text-pk-meta text-pk-text"
                />
                <input
                  name="w"
                  value="400"
                  class="h-8 w-16 rounded-lg border border-pk-line-strong bg-pk-raised px-2 font-mono text-pk-meta text-pk-text"
                />
                <input
                  name="h"
                  value="300"
                  class="h-8 w-16 rounded-lg border border-pk-line-strong bg-pk-raised px-2 font-mono text-pk-meta text-pk-text"
                />
                <button class="btn btn-xs h-8 border border-pk-line-strong bg-transparent px-3 text-pk-body text-pk-text-2 hover:bg-pk-raised hover:text-white">
                  Capturar
                </button>
              </form>
              <img
                :if={@capture_src}
                src={@capture_src}
                class="mt-2 max-w-full rounded border border-pk-line"
              />
            </div>

            <div class="space-y-2 rounded-lg border border-pk-line bg-pk-sunken p-3">
              <h3 class="font-mono text-pk-meta text-pk-text-3">
                Sequência de captura <span class="normal-case">(Shift+1 + clique)</span>
              </h3>
              <form id="seq-form" phx-submit="capture_seq" class="flex flex-wrap items-end gap-2">
                <input
                  name="x"
                  value="800"
                  class="h-8 w-20 rounded-lg border border-pk-line-strong bg-pk-raised px-2 font-mono text-pk-meta text-pk-text"
                />
                <input
                  name="y"
                  value="400"
                  class="h-8 w-20 rounded-lg border border-pk-line-strong bg-pk-raised px-2 font-mono text-pk-meta text-pk-text"
                />
                <button
                  class="btn btn-xs h-8 border border-pk-warn-line bg-transparent px-3 text-pk-body text-pk-warn hover:bg-pk-warn-dim disabled:cursor-not-allowed disabled:opacity-50"
                  disabled={@pending != nil}
                >
                  Testar em 2s
                </button>
              </form>
            </div>
          </div>

          <p :if={@pending} class="flex items-center gap-2 font-mono text-pk-body text-pk-warn">
            <span class="loading loading-spinner loading-xs" /> {@pending.hint}
          </p>

          <.result_line msg={@tools_msg} />
        </section>

        <section class="space-y-3 rounded-2xl border border-pk-line bg-pk-surface p-5">
          <div class="flex items-start justify-between gap-3">
            <div>
              <h2 class="font-mono text-pk-meta font-bold uppercase tracking-[0.12em] text-pk-text-3">
                Ensinar glifos
              </h2>
              <p class="mt-1 text-pk-body leading-relaxed text-pk-text-2">
                Aqui aparece todo caractere que esta instalação
                <b class="text-pk-text">não sabe de verdade</b>
                — tanto o que virou "?" quanto o que ela apenas <b class="text-pk-text">chutou</b>
                pelo desenho mais parecido. Chute erra, e erra calado: em 27/08 a faixa dizia
                <span class="font-mono text-pk-text-2">1088, 1409, 5</span>
                e o leitor respondeu <span class="font-mono text-pk-text-2">1066, 1409</span>
                — um 8 que o atlas nunca teve vira o 6 mais parecido, com folga. Varre a faixa da
                coordenada primeiro (é a que sobrevive só com a tua marcação à mão), depois o HUD e
                o time. <b class="text-pk-text">Confira o desenho</b>
                e confirme: fica sabido pra sempre e o chute acaba.
              </p>
            </div>
            <button
              class="btn btn-sm h-8 shrink-0 border border-pk-ok-line bg-pk-ok-dim px-4 font-mono text-pk-body font-semibold text-pk-ok hover:bg-pk-ok-dim/70"
              phx-click="scan_glyphs"
            >
              Varrer tela
            </button>
          </div>

          <p
            :if={@glyph_gaps != %{}}
            id="glyph-gaps"
            class="rounded-lg border border-pk-warn-line bg-pk-warn-dim/40 p-2 font-mono text-pk-meta text-pk-warn"
          >
            dígitos que o atlas não tem: {gap_line(@glyph_gaps)}
          </p>

          <ul :if={@unknown_glyphs != []} class="flex flex-wrap gap-3">
            <li
              :for={glyph <- @unknown_glyphs}
              class="flex items-center gap-3 rounded-lg border border-pk-line bg-pk-sunken p-3"
            >
              <div class="flex flex-col gap-px">
                <div :for={row <- glyph.bitmap} class="flex gap-px">
                  <span
                    :for={cell <- row}
                    class={[
                      "size-1.5",
                      if(cell == 1, do: "bg-pk-text", else: "bg-transparent")
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
                  value={glyph[:guess]}
                  placeholder="?"
                  class="h-8 w-14 rounded-lg border border-pk-line-strong bg-pk-raised text-center font-mono text-pk-body text-pk-text"
                />
                <button class="btn btn-xs h-8 border border-pk-line-strong bg-transparent px-3 text-pk-body text-pk-text-2 hover:bg-pk-raised hover:text-white">
                  Aprender
                </button>
              </form>
              <%!-- The guess is filled in and LABELLED as a guess: it is right
                    often enough to save typing and wrong often enough that
                    hiding its nature would be the bug all over again. --%>
              <span :if={glyph[:guess]} class="text-pk-meta text-pk-text-3">
                chutou <b class="font-mono text-pk-text-2">{glyph[:guess]}</b> — confere no desenho
              </span>
              <span :if={is_nil(glyph[:guess])} class="text-pk-meta text-pk-warn">
                não leu nada
              </span>
            </li>
          </ul>

          <.result_line msg={@glyph_msg} />
        </section>
      </div>
    </Layouts.app>
    """
  end
end
