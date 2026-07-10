defmodule PokexWeb.CalibrationLive do
  use PokexWeb, :live_view

  alias Pokex.{Calibration, Home, Rig, Settings, Vision}
  alias Pokex.Bots.SkillBar
  alias Pokex.Vision.Frame

  import PokexWeb.CalibrationOverlay, only: [overlays: 1, legend: 1]

  @baseline_count 10
  @glow_half 32

  @total_steps 11
  # Click-to-zoom magnification: a rough click magnifies the screenshot around it (via CSS
  # transform, which the ImgClick hook's getBoundingClientRect already accounts for), then a
  # precise second click is transcribed back to screen coordinates. Helps a lot on a small screen.
  @zoom_factor 3.5

  @instructions %{
    water: "Clique no PONTO DA ÁGUA onde o bot deve arremessar.",
    battle_a: "Clique no canto SUPERIOR-ESQUERDO da área de criaturas da janela Battle.",
    battle_b:
      "Agora o canto INFERIOR-DIREITO da mesma área (incluindo a coluna do ícone de pokébola).",
    arena_a:
      "Canto SUPERIOR-ESQUERDO da ARENA (área ao redor do personagem onde o pokémon pescado aparece).",
    arena_b: "Canto INFERIOR-DIREITO da arena.",
    neutral: "Clique num PONTO NEUTRO seguro (sugestão: o tile do seu próprio personagem).",
    baselines:
      "Tudo marcado! Agora LANCE A LINHA na água (Shift+V) e, com ela ESPERANDO sem nada fisgado, clique em 'Capturar linhas de base'. Assim o bot aprende a água COM a linha — senão ele acha que é sempre brilho e fisga na hora.",
    skill_a: "Canto SUPERIOR-ESQUERDO da barra de skills (bem no início do slot 1).",
    skill_b:
      "Canto INFERIOR-DIREITO da barra, depois da última skill deste Pokémon. Não inclua outros botões.",
    hp_a:
      "Canto SUPERIOR-ESQUERDO da barra de VIDA do Pokémon principal — bem RENTE à barra, sem pegar o fundo azul acima nem os ícones abaixo.",
    hp_b: "Canto INFERIOR-DIREITO da MESMA barra de vida (colado na barra, só ela).",
    photo: "Centro da FOTO do Pokémon principal (onde o mouse fica pro Shift+Q do revive)."
  }

  @impl true
  def mount(_params, _session, socket) do
    skill_count = configured_skill_count()

    {:ok,
     assign(socket,
       page_title: "Calibração",
       screen: nil,
       scale: nil,
       step: nil,
       mode: nil,
       draft: %{},
       baselines_done: 0,
       done: false,
       calibrated?: Calibration.exists?(),
       review: nil,
       error: nil,
       skillbar_msg: nil,
       zoom_at: nil,
       skill_count: skill_count,
       skill_count_form: skill_count_form(skill_count),
       row_height: Settings.get(:battle_row_height),
       max_rows: Settings.get(:battle_max_rows)
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
         mode: :full,
         draft: %{skill_bar_count: socket.assigns.skill_count},
         done: false,
         review: nil,
         error: nil,
         skillbar_msg: nil,
         zoom_at: nil
       )}
    else
      error -> {:noreply, assign(socket, error: "captura falhou: #{inspect(error)}")}
    end
  end

  # Standalone correction for an existing calibration. The normal 8-step wizard
  # already includes these two clicks.
  def handle_event("calibrate_skillbar", _params, socket) do
    with {:ok, screen} <- grab_screen("skillbar_probe.png") do
      {:noreply,
       assign(socket,
         scale: screen.scale,
         screen: screen,
         step: :skill_a,
         mode: :skillbar_only,
         draft: %{skill_bar_count: socket.assigns.skill_count},
         done: false,
         review: nil,
         error: nil,
         skillbar_msg: nil,
         zoom_at: nil
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

  def handle_event("set_skill_count", %{"skill_bar" => %{"count" => raw}}, socket) do
    count = parse_skill_count(raw, socket.assigns.skill_count)

    {:noreply,
     assign(socket,
       skill_count: count,
       skill_count_form: skill_count_form(count),
       draft: Map.put(socket.assigns.draft, :skill_bar_count, count)
     )}
  end

  def handle_event(
        "img_click",
        %{"x" => x, "y" => y, "cw" => cw, "ch" => ch, "nw" => nw, "nh" => nh},
        socket
      ) do
    scale = socket.assigns.scale
    point = {round(x * nw / cw / scale), round(y * nh / ch / scale)}

    socket =
      if socket.assigns.zoom_at do
        # A precise click on the magnified view → record it, then drop the zoom for the next point.
        socket |> record_point(point) |> assign(zoom_at: nil)
      else
        # A rough first click → magnify around it so the real target is easy to hit on a small screen.
        assign(socket, zoom_at: point)
      end

    {:noreply, socket}
  end

  def handle_event("cancel_zoom", _params, socket) do
    {:noreply, assign(socket, zoom_at: nil)}
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
      skill_bar_region: draft.skill_bar_region,
      skill_bar_count: draft.skill_bar_count,
      pokemon_hp_region: draft[:pokemon_hp_region],
      pokemon_photo_point: draft[:pokemon_photo_point],
      glow_baselines: baseline_paths,
      battle_baseline: battle_baseline,
      suggested_glow_threshold: Vision.suggested_threshold(frames)
    }

    Calibration.save(calib)
    persist_skill_settings(draft.skill_bar_count)
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
        assign(socket, draft: Map.put(draft, :neutral_point, point), step: :skill_a)

      :skill_a ->
        assign(socket, draft: Map.put(draft, :skill_a, point), step: :skill_b)

      :skill_b ->
        region = region_from(draft.skill_a, point)
        count = draft.skill_bar_count

        case socket.assigns.mode do
          :full ->
            assign(socket,
              draft:
                draft
                |> Map.put(:skill_bar_region, region)
                |> Map.put(:skill_bar_count, count),
              step: :hp_a,
              skillbar_msg: "Barra configurada com #{count} skills."
            )

          :skillbar_only ->
            persist_skill_settings(count)
            save_skill_bar(socket, region, count)

          _ ->
            socket
        end

      :hp_a ->
        assign(socket, draft: Map.put(draft, :hp_a, point), step: :hp_b)

      :hp_b ->
        assign(socket,
          draft: Map.put(draft, :pokemon_hp_region, region_from(draft.hp_a, point)),
          step: :photo
        )

      :photo ->
        assign(socket, draft: Map.put(draft, :pokemon_photo_point, point), step: :baselines)

      _ ->
        socket
    end
  end

  defp region_from({x1, y1}, {x2, y2}), do: {min(x1, x2), min(y1, y2), abs(x2 - x1), abs(y2 - y1)}

  # CSS transform that magnifies the screenshot around the rough click (a screen point). The
  # transform-origin keeps that point in place while everything around it scales up; the ImgClick
  # hook reads the transformed getBoundingClientRect, so the precise click maps back correctly.
  defp zoom_style(nil, _screen, _factor), do: nil

  defp zoom_style({x, y}, %{w: w, h: h}, factor) when w > 0 and h > 0,
    do: "transform: scale(#{factor}); transform-origin: #{x / w * 100}% #{y / h * 100}%"

  defp zoom_style(_zoom_at, _screen, _factor), do: nil

  defp save_skill_bar(socket, region, count) do
    case Calibration.load() do
      {:ok, calib} ->
        Calibration.save(%{calib | skill_bar_region: region, skill_bar_count: count})

        assign(socket,
          draft: %{},
          step: nil,
          screen: nil,
          calibrated?: true,
          skillbar_msg: "Barra salva com #{count} skills. Confira a leitura no painel."
        )

      {:error, reason} ->
        assign(socket,
          step: nil,
          screen: nil,
          error: "não deu pra salvar a barra: #{inspect(reason)}"
        )
    end
  end

  defp persist_skill_settings(count) do
    Settings.put(:skill_bar_count, count)
    Settings.put(:skill_keys, SkillBar.fit_order(Settings.get(:skill_keys), count))
  end

  defp configured_skill_count do
    case Calibration.load() do
      {:ok, %Calibration{skill_bar_count: count}} when count in 1..10 -> count
      _ -> Settings.get(:skill_bar_count) |> clamp_skill_count()
    end
  end

  defp parse_skill_count(raw, fallback) do
    case Integer.parse(to_string(raw)) do
      {count, ""} -> clamp_skill_count(count)
      _ -> fallback
    end
  end

  defp clamp_skill_count(count) when is_integer(count), do: min(max(count, 1), 10)
  defp clamp_skill_count(_count), do: 6

  defp skill_count_form(count), do: to_form(%{"count" => to_string(count)}, as: :skill_bar)

  # Any step where the user clicks the screenshot to mark a point/region (the numbered wizard
  # steps AND the standalone Pokémon-HP flow).
  defp marking_step?(step),
    do:
      step in [
        :water,
        :battle_a,
        :battle_b,
        :arena_a,
        :arena_b,
        :neutral,
        :skill_a,
        :skill_b,
        :hp_a,
        :hp_b,
        :photo
      ]

  defp step_index(:water), do: 1
  defp step_index(:battle_a), do: 2
  defp step_index(:battle_b), do: 3
  defp step_index(:arena_a), do: 4
  defp step_index(:arena_b), do: 5
  defp step_index(:neutral), do: 6
  defp step_index(:skill_a), do: 7
  defp step_index(:skill_b), do: 8
  defp step_index(:hp_a), do: 9
  defp step_index(:hp_b), do: 10
  defp step_index(:photo), do: 11
  defp step_index(_), do: nil

  defp step_pill_class(n, step) do
    case step_index(step) do
      nil -> "bg-base-300 opacity-50"
      current when n < current -> "bg-success text-success-content"
      current when n == current -> "bg-primary text-primary-content"
      _ -> "bg-base-300 opacity-50"
    end
  end

  # Preview bands over the draft battle_region as the user marks it, so drift is
  # visible before saving. Empty until the battle corners are placed.
  defp draft_bands(%{battle_region: region}, scale, row_height, rows),
    do: Calibration.battle_row_bands(region, scale, row_height, rows)

  defp draft_bands(_draft, _scale, _row_height, _rows), do: []

  defp draft_player(%{arena_region: region}), do: Calibration.player_point(region)
  defp draft_player(_draft), do: nil

  @impl true
  def render(assigns) do
    # module attributes are not available inside ~H as @foo (that reads
    # assigns), so expose the instruction map as an assign first
    assigns =
      assign(assigns, instr: @instructions, total_steps: @total_steps, zoom_factor: @zoom_factor)

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
        <p :if={@skillbar_msg} class="rounded-lg bg-success/15 px-3 py-2 text-sm text-success">
          {@skillbar_msg}
        </p>

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
              skill_bar_region={@review.calib.skill_bar_region}
              neutral_point={@review.calib.neutral_point}
              player_point={Calibration.player_point(@review.calib)}
              pokemon_hp_region={@review.calib.pokemon_hp_region}
              pokemon_photo_point={@review.calib.pokemon_photo_point}
              bands={Calibration.battle_row_bands(@review.calib, @row_height, @max_rows)}
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
          <.form
            for={@skill_count_form}
            id="skill-count-form"
            phx-change="set_skill_count"
            class="mx-auto w-44 text-left"
          >
            <.input
              field={@skill_count_form[:count]}
              type="number"
              min="1"
              max="10"
              label="Quantidade de skills"
            />
          </.form>
          <button class="btn btn-primary" phx-click="capture_screen">
            <.icon name="hero-camera" class="size-4" /> Capturar tela (calibração completa)
          </button>
          <p class="text-xs opacity-60">
            Marca tudo em sequência: água, Battle, arena, ponto neutro, barra de skills e a vida do
            Pokémon principal.
          </p>

          <div :if={@calibrated?} class="mt-2 space-y-2 border-t border-base-content/10 pt-3">
            <p class="text-xs font-semibold opacity-70">Correções rápidas (sem refazer tudo)</p>
            <div class="flex flex-wrap justify-center gap-2">
              <button class="btn btn-ghost btn-sm" phx-click="review">
                <.icon name="hero-eye" class="size-4" /> Revisar áreas salvas
              </button>
              <button class="btn btn-ghost btn-sm" phx-click="calibrate_skillbar">
                <.icon name="hero-bolt" class="size-4" /> Só as skills
              </button>
            </div>
          </div>
        </div>

        <div :if={@screen} class="space-y-3">
          <ol :if={@mode == :full and step_index(@step)} class="flex flex-wrap items-center gap-1.5">
            <li
              :for={n <- 1..@total_steps}
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
            <span :if={@mode == :full} class="font-bold">
              Passo {step_index(@step)}/{@total_steps} —
            </span>
            {@instr[@step]}
            <span :if={@step in [:skill_a, :skill_b]} class="ml-1 font-bold">
              Quantidade fixa: {@skill_count}.
            </span>
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

          <p :if={marking_step?(@step)} class="text-xs">
            <span :if={is_nil(@zoom_at)} class="opacity-70">
              Dê um clique APROXIMADO no alvo — a imagem amplia pra você mirar com precisão.
            </span>
            <span :if={@zoom_at} class="font-semibold text-primary">
              Ampliado {@zoom_factor}× — agora clique PRECISO no alvo.
            </span>
            <button
              :if={@zoom_at}
              type="button"
              class="btn btn-ghost btn-xs ml-1 align-middle"
              phx-click="cancel_zoom"
            >
              <.icon name="hero-arrow-uturn-left" class="size-3" /> refazer o clique
            </button>
          </p>

          <.legend :if={marking_step?(@step)} />

          <div
            :if={marking_step?(@step)}
            class="overflow-hidden rounded-lg border border-base-content/20"
          >
            <div class="relative" style={zoom_style(@zoom_at, @screen, @zoom_factor)}>
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
                skill_bar_region={@draft[:skill_bar_region]}
                neutral_point={@draft[:neutral_point]}
                player_point={draft_player(@draft)}
                pokemon_hp_region={@draft[:pokemon_hp_region]}
                pokemon_photo_point={@draft[:pokemon_photo_point]}
                bands={draft_bands(@draft, @scale, @row_height, @max_rows)}
              />
            </div>
          </div>
        </div>

        <div
          :if={@done}
          class="space-y-3 rounded-2xl border border-success/40 bg-success/10 p-6 text-center"
        >
          <.icon name="hero-check-circle" class="mx-auto size-8 text-success" />
          <p class="font-semibold">Calibração salva!</p>
          <p class="text-sm opacity-70">
            Brilho, {@draft[:skill_bar_count] || Settings.get(:skill_bar_count)} skills e a vida do
            Pokémon gravados. Confira a vida no painel e ligue o combo de sobrevivência.
          </p>
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
