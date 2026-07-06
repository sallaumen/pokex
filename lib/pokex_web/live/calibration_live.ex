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
       page_title: "Calibração",
       screen: nil,
       scale: nil,
       step: nil,
       draft: %{},
       baselines_done: 0,
       done: false,
       calibrated?: Calibration.exists?(),
       review: nil,
       error: nil
     )}
  end

  @impl true
  def handle_event("capture_screen", _params, socket) do
    with {:ok, screen} <- grab_screen("scale_probe.png") do
      {:noreply,
       assign(socket,
         scale: screen.scale,
         screen: screen,
         step: :water,
         draft: %{},
         done: false,
         review: nil,
         error: nil
       )}
    else
      error -> {:noreply, assign(socket, error: "captura falhou: #{inspect(error)}")}
    end
  end

  def handle_event("review", _params, socket) do
    with {:ok, calib} <- Calibration.load(),
         {:ok, screen} <- grab_screen("review_probe.png") do
      {:noreply, assign(socket, review: Map.put(screen, :calib, calib), error: nil)}
    else
      error -> {:noreply, assign(socket, error: "não deu pra revisar: #{inspect(error)}")}
    end
  end

  def handle_event("close_review", _params, socket) do
    {:noreply, assign(socket, review: nil)}
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
    {:noreply, assign(socket, done: true, step: nil, calibrated?: true)}
  end

  # Probe a 100x100 region for the Retina scale, then grab the full screen.
  defp grab_screen(probe_name) do
    with {:ok, probe_path} <- Rig.impl().capture({0, 0, 100, 100}, probe_name),
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

  defp step_index(:water), do: 1
  defp step_index(:battle_a), do: 2
  defp step_index(:battle_b), do: 3
  defp step_index(:arena_a), do: 4
  defp step_index(:arena_b), do: 5
  defp step_index(:neutral), do: 6
  defp step_index(_), do: nil

  defp step_pill_class(n, step) do
    case step_index(step) do
      nil -> "bg-base-300 opacity-50"
      current when n < current -> "bg-success text-success-content"
      current when n == current -> "bg-primary text-primary-content"
      _ -> "bg-base-300 opacity-50"
    end
  end

  # Percentage-based positioning of a point/region over the full-screen image.
  defp point_style({x, y}, %{w: w, h: h}), do: "left:#{x / w * 100}%;top:#{y / h * 100}%"

  defp region_style({x, y, rw, rh}, %{w: w, h: h}),
    do: "left:#{x / w * 100}%;top:#{y / h * 100}%;width:#{rw / w * 100}%;height:#{rh / h * 100}%"

  attr :screen, :map, required: true
  attr :water_point, :any, default: nil
  attr :glow_region, :any, default: nil
  attr :battle_region, :any, default: nil
  attr :arena_region, :any, default: nil
  attr :neutral_point, :any, default: nil

  defp overlays(assigns) do
    ~H"""
    <div
      :if={@glow_region}
      class="absolute rounded border-2 border-info bg-info/10"
      style={region_style(@glow_region, @screen)}
    >
      <span class="absolute -top-4 left-0 rounded bg-info px-1 text-[10px] font-bold text-info-content">
        brilho
      </span>
    </div>
    <div
      :if={@battle_region}
      class="absolute rounded border-2 border-warning bg-warning/10"
      style={region_style(@battle_region, @screen)}
    >
      <span class="absolute -top-4 left-0 rounded bg-warning px-1 text-[10px] font-bold text-warning-content">
        Battle
      </span>
    </div>
    <div
      :if={@arena_region}
      class="absolute rounded border-2 border-success bg-success/10"
      style={region_style(@arena_region, @screen)}
    >
      <span class="absolute -top-4 left-0 rounded bg-success px-1 text-[10px] font-bold text-success-content">
        arena
      </span>
    </div>
    <div
      :if={@water_point}
      class="absolute -ml-1.5 -mt-1.5 size-3 rounded-full border-2 border-white bg-info shadow"
      style={point_style(@water_point, @screen)}
      title="água"
    />
    <div
      :if={@neutral_point}
      class="absolute -ml-1.5 -mt-1.5 size-3 rounded-full border-2 border-white bg-neutral shadow"
      style={point_style(@neutral_point, @screen)}
      title="neutro"
    />
    """
  end

  defp legend(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-x-4 gap-y-1 text-xs">
      <span class="flex items-center gap-1">
        <span class="size-2.5 rounded-full bg-info" /> água + brilho
      </span>
      <span class="flex items-center gap-1">
        <span class="size-2.5 rounded-sm border-2 border-warning" /> janela Battle
      </span>
      <span class="flex items-center gap-1">
        <span class="size-2.5 rounded-sm border-2 border-success" /> arena
      </span>
      <span class="flex items-center gap-1">
        <span class="size-2.5 rounded-full bg-neutral" /> ponto neutro
      </span>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    # module attributes are not available inside ~H as @foo (that reads
    # assigns), so expose the instruction map as an assign first
    assigns = assign(assigns, :instr, @instructions)

    ~H"""
    <Layouts.app flash={@flash} current_page={:calibration}>
      <div class="space-y-4">
        <header>
          <h1 class="text-xl font-bold">Calibração</h1>
          <p class="mt-1 text-sm opacity-70">
            Deixe a janela do jogo visível e SEM o navegador na frente. Depois de calibrar,
            não mova nem redimensione a janela do jogo (senão recalibre).
          </p>
        </header>

        <p :if={@error} class="rounded-lg bg-error/15 px-3 py-2 text-sm text-error">{@error}</p>

        <div
          :if={@review}
          class="space-y-3 rounded-2xl border border-base-content/10 bg-base-200 p-4"
        >
          <div class="flex items-center justify-between">
            <h2 class="text-sm font-semibold">Áreas que o bot está usando</h2>
            <button class="btn btn-ghost btn-xs" phx-click="close_review">Fechar</button>
          </div>
          <.legend />
          <div class="relative overflow-hidden rounded-lg border border-base-content/20">
            <img src={@review.src} class="w-full" />
            <.overlays
              screen={@review}
              water_point={@review.calib.water_point}
              glow_region={@review.calib.glow_region}
              battle_region={@review.calib.battle_region}
              arena_region={@review.calib.arena_region}
              neutral_point={@review.calib.neutral_point}
            />
          </div>
        </div>

        <div
          :if={is_nil(@screen) and is_nil(@review)}
          class="space-y-3 rounded-2xl border border-base-content/10 bg-base-200 p-6 text-center"
        >
          <.icon name="hero-camera" class="mx-auto size-8 opacity-60" />
          <p class="text-sm opacity-70">
            Capture a tela do jogo para começar a marcar os pontos.
          </p>
          <div class="flex flex-wrap justify-center gap-2">
            <button class="btn btn-primary" phx-click="capture_screen">
              <.icon name="hero-camera" class="size-4" /> Capturar tela
            </button>
            <button :if={@calibrated?} class="btn btn-ghost" phx-click="review">
              <.icon name="hero-eye" class="size-4" /> Revisar áreas salvas
            </button>
          </div>
        </div>

        <div :if={@screen} class="space-y-3">
          <ol :if={step_index(@step)} class="flex items-center gap-1.5">
            <li
              :for={n <- 1..6}
              class={[
                "flex size-6 items-center justify-center rounded-full text-xs font-semibold",
                step_pill_class(n, @step)
              ]}
            >
              {n}
            </li>
          </ol>

          <p
            :if={@step && @step != :baselines}
            class="rounded-lg bg-info/15 px-3 py-2 text-sm font-medium"
          >
            {@instr[@step]}
          </p>

          <div
            :if={@step == :baselines}
            class="space-y-3 rounded-xl border border-base-content/10 bg-base-200 p-4"
          >
            <p class="text-sm">{@instr.baselines}</p>
            <button class="btn btn-primary" phx-click="capture_baselines">
              Capturar linhas de base
            </button>
            <progress class="progress progress-primary w-full" value={@baselines_done} max="10" />
            <p class="text-xs opacity-60">{@baselines_done}/10 capturadas</p>
          </div>

          <.legend :if={@step in [:water, :battle_a, :battle_b, :arena_a, :arena_b, :neutral]} />

          <div
            :if={@step in [:water, :battle_a, :battle_b, :arena_a, :arena_b, :neutral]}
            class="relative overflow-hidden rounded-lg border border-base-content/20"
          >
            <img
              id="calibration-screen"
              phx-hook="ImgClick"
              src={@screen.src}
              class="w-full cursor-crosshair"
            />
            <.overlays
              screen={@screen}
              water_point={@draft[:water_point]}
              glow_region={@draft[:glow_region]}
              battle_region={@draft[:battle_region]}
              arena_region={@draft[:arena_region]}
              neutral_point={@draft[:neutral_point]}
            />
          </div>
        </div>

        <div
          :if={@done}
          class="space-y-3 rounded-2xl border border-success/40 bg-success/10 p-6 text-center"
        >
          <.icon name="hero-check-circle" class="mx-auto size-8 text-success" />
          <p class="font-semibold">Calibração salva!</p>
          <p class="text-sm opacity-70">Threshold do brilho gravado. Pode ir para o painel.</p>
          <div class="flex flex-wrap justify-center gap-2">
            <button class="btn btn-ghost btn-sm" phx-click="review">
              <.icon name="hero-eye" class="size-4" /> Revisar áreas
            </button>
            <.link navigate={~p"/"} class="btn btn-success btn-sm">Ir ao painel →</.link>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
