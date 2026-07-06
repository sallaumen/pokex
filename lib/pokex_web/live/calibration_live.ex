defmodule PokexWeb.CalibrationLive do
  use PokexWeb, :live_view

  alias Pokex.{Calibration, Home, Rig, Vision}
  alias Pokex.Vision.Frame

  @baseline_count 10
  @glow_half 32

  @instructions %{
    water: "1/6 — Clique no PONTO DA ÁGUA onde o bot deve arremessar.",
    battle_a: "2/6 — Clique no canto SUPERIOR-ESQUERDO da área de criaturas da janela Battle.",
    battle_b:
      "3/6 — Agora o canto INFERIOR-DIREITO da mesma área (incluindo a coluna do ícone de pokébola).",
    arena_a:
      "4/6 — Canto superior-esquerdo da ARENA (área ao redor do personagem onde o pokémon pescado aparece).",
    arena_b: "5/6 — Canto inferior-direito da arena.",
    neutral: "6/6 — Clique num PONTO NEUTRO seguro (sugestão: o tile do seu próprio personagem).",
    baselines:
      "Tudo marcado! Deixe a água visível SEM pesca ativa e clique em 'Capturar linhas de base'."
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       screen: nil,
       scale: nil,
       step: nil,
       draft: %{},
       baselines_done: 0,
       done: false,
       error: nil
     )}
  end

  @impl true
  def handle_event("capture_screen", _params, socket) do
    with {:ok, probe_path} <- Rig.impl().capture({0, 0, 100, 100}, "scale_probe.png"),
         {:ok, {probe_px, _}} <- Frame.png_dimensions(probe_path),
         {:ok, screen_path} <- Rig.impl().capture_screen(),
         {:ok, {px_w, px_h}} <- Frame.png_dimensions(screen_path) do
      scale = probe_px / 100

      {:noreply,
       assign(socket,
         scale: scale,
         screen: %{
           src: "/captures/#{Path.basename(screen_path)}?t=#{System.unique_integer([:positive])}",
           w: round(px_w / scale),
           h: round(px_h / scale)
         },
         step: :water,
         draft: %{},
         done: false,
         error: nil
       )}
    else
      error -> {:noreply, assign(socket, error: "captura falhou: #{inspect(error)}")}
    end
  end

  def handle_event(
        "img_click",
        %{"x" => x, "y" => y, "cw" => cw, "ch" => ch, "nw" => nw, "nh" => nh},
        socket
      ) do
    scale = socket.assigns.scale
    point = {round(x * nw / cw / scale), round(y * nh / ch / scale)}
    {:noreply, record_point(socket, point)}
  end

  def handle_event("capture_baselines", _params, socket) do
    File.mkdir_p!(Home.baselines_dir())
    send(self(), {:baseline, 0})
    {:noreply, assign(socket, baselines_done: 0)}
  end

  @impl true
  def handle_info({:baseline, index}, socket) when index < @baseline_count do
    destination = Path.join(Home.baselines_dir(), "glow_#{index}.png")

    case Rig.impl().capture(socket.assigns.draft.glow_region, "baseline.png") do
      {:ok, path} ->
        File.cp!(path, destination)
        gap = Application.get_env(:pokex, :baseline_gap_ms, 400)
        Process.send_after(self(), {:baseline, index + 1}, gap)
        {:noreply, assign(socket, baselines_done: index + 1)}

      {:error, reason} ->
        {:noreply, assign(socket, error: "baseline falhou: #{inspect(reason)}")}
    end
  end

  def handle_info({:baseline, _index}, socket) do
    draft = socket.assigns.draft

    baseline_paths =
      for i <- 0..(@baseline_count - 1), do: Path.join(Home.baselines_dir(), "glow_#{i}.png")

    frames =
      for path <- baseline_paths, {:ok, frame} <- [Frame.from_png_file(path)], do: frame

    battle_baseline = Path.join(Home.baselines_dir(), "battle_empty.png")

    case Rig.impl().capture(Calibration.battle_strip(draft.battle_region), "battle_base.png") do
      {:ok, path} -> File.cp!(path, battle_baseline)
      {:error, _} -> :ok
    end

    calib = %Calibration{
      scale: socket.assigns.scale,
      screen_w: socket.assigns.screen.w,
      screen_h: socket.assigns.screen.h,
      water_point: draft.water_point,
      glow_region: draft.glow_region,
      battle_region: draft.battle_region,
      arena_region: draft.arena_region,
      neutral_point: draft.neutral_point,
      glow_baselines: baseline_paths,
      battle_baseline: battle_baseline,
      suggested_glow_threshold: Vision.suggested_threshold(frames)
    }

    Calibration.save(calib)
    {:noreply, assign(socket, done: true, step: nil)}
  end

  defp record_point(socket, point) do
    %{step: step, draft: draft} = socket.assigns

    case step do
      :water ->
        {x, y} = point

        draft =
          Map.merge(draft, %{
            water_point: point,
            glow_region: {x - @glow_half, y - @glow_half, @glow_half * 2, @glow_half * 2}
          })

        assign(socket, draft: draft, step: :battle_a)

      :battle_a ->
        assign(socket, draft: Map.put(draft, :battle_a, point), step: :battle_b)

      :battle_b ->
        assign(socket,
          draft: Map.put(draft, :battle_region, region_from(draft.battle_a, point)),
          step: :arena_a
        )

      :arena_a ->
        assign(socket, draft: Map.put(draft, :arena_a, point), step: :arena_b)

      :arena_b ->
        assign(socket,
          draft: Map.put(draft, :arena_region, region_from(draft.arena_a, point)),
          step: :neutral
        )

      :neutral ->
        assign(socket, draft: Map.put(draft, :neutral_point, point), step: :baselines)

      _ ->
        socket
    end
  end

  defp region_from({x1, y1}, {x2, y2}), do: {min(x1, x2), min(y1, y2), abs(x2 - x1), abs(y2 - y1)}

  @impl true
  def render(assigns) do
    # module attributes are not available inside ~H as @foo (that reads
    # assigns), so expose the instruction map as an assign first
    assigns = assign(assigns, :instr, @instructions)

    ~H"""
    <div class="p-4 space-y-4">
      <h1 class="text-xl font-bold">Pokex — Calibração</h1>
      <p class="text-sm opacity-70">
        Deixe a janela do jogo visível e SEM o navegador na frente. Depois de calibrar,
        não mova nem redimensione a janela do jogo (senão recalibre).
      </p>
      <p :if={@error} class="alert alert-error text-sm">{@error}</p>

      <button class="btn btn-primary" phx-click="capture_screen">Capturar tela</button>

      <p :if={@step && @step != :baselines} class="alert alert-info text-sm">
        {@instr[@step]}
      </p>

      <div :if={@step == :baselines} class="space-y-2">
        <p class="alert alert-info text-sm">{@instr.baselines}</p>
        <button class="btn btn-primary" phx-click="capture_baselines">
          Capturar linhas de base
        </button>
        <p class="text-sm">{@baselines_done}/10 capturadas</p>
      </div>

      <p :if={@done} class="alert alert-success">
        Calibração salva! Threshold sugerido do brilho gravado. Pode fechar e ir ao painel.
      </p>

      <img
        :if={@screen && @step in [:water, :battle_a, :battle_b, :arena_a, :arena_b, :neutral]}
        id="calibration-screen"
        phx-hook="ImgClick"
        src={@screen.src}
        class="w-full cursor-crosshair border"
      />
    </div>
    """
  end
end
