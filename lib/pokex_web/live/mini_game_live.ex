defmodule PokexWeb.MiniGameLive do
  @moduledoc """
  What the mini-game watcher is seeing, right now.

  The picture is the frame that was ACTUALLY analysed — the play loop copies
  the PNG it just decoded, so nothing here is a second capture of a different
  moment. Everything drawn over it (the track bounds, the raw fish reading, the
  reading the gate accepted, the capsule) comes from the same sample.
  """
  use PokexWeb, :live_view

  alias Pokex.Bots.MiniGame.{Export, Mode, Replay, Worker}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
      Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.diag_topic())
    end

    {:ok,
     socket
     |> assign(
       page_title: "Mini-game",
       mode: Mode.current(),
       sample: nil,
       preview_src: nil,
       summary: nil,
       replay: nil,
       msg: nil
     )
     |> assign(status: worker_status())
     |> assign_bundles()}
  end

  @impl true
  def handle_info({:mini_game_tick, payload}, socket) do
    {:noreply,
     assign(socket,
       sample: payload.sample,
       mode: payload.mode,
       preview_src: preview_src(payload)
     )}
  end

  def handle_info({:mini_game_summary, summary}, socket),
    do: {:noreply, socket |> assign(summary: summary) |> assign_bundles()}

  def handle_info({:mini_game, status}, socket), do: {:noreply, assign(socket, status: status)}
  def handle_info({:mini_game_log, _level, _text}, socket), do: {:noreply, socket}

  def handle_info({:mini_game_alert, %{text: text}}, socket),
    do: {:noreply, assign(socket, msg: text)}

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("set_mode", %{"mode" => mode}, socket) do
    Mode.put(mode)
    mode = Mode.current()

    {:noreply,
     assign(socket,
       mode: mode,
       status: worker_status(),
       msg: "modo: #{Mode.label(mode)}"
     )}
  end

  # Offline by construction: Replay.run/2 defaults to a Rig whose every
  # callback raises, so this button can never actuate anything.
  def handle_event("replay", %{"bundle" => bundle}, socket) do
    case Replay.run(bundle) do
      {:ok, report} ->
        {:noreply, assign(socket, replay: report, msg: "replay de #{Path.basename(bundle)}")}

      {:error, reason} ->
        {:noreply, assign(socket, msg: "replay falhou: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_page={:mini_game}>
      <div class="space-y-5">
        <section class="rounded-2xl border border-base-content/10 bg-base-200 p-5">
          <div class="flex flex-wrap items-center justify-between gap-3">
            <div>
              <h1 class="text-2xl font-bold tracking-tight">Mini-game da pesca</h1>
              <p class="mt-1 text-sm text-base-content/70">
                O quadro abaixo é exatamente o que o código analisou — nenhuma captura extra.
              </p>
            </div>

            <form id="mini-game-mode-form" phx-change="set_mode" class="flex items-center gap-2">
              <label for="mini-game-mode" class="text-xs uppercase tracking-wide text-base-content/50">
                modo
              </label>
              <select id="mini-game-mode" name="mode" class="select select-sm select-bordered">
                <option :for={mode <- Mode.all()} value={mode} selected={mode == @mode}>
                  {Mode.label(mode)}
                </option>
              </select>
            </form>
          </div>

          <div :if={@status} class="mt-4 flex flex-wrap items-center gap-2">
            <span class="badge badge-ghost">estado: {state_label(@status.state)}</span>
            <span class="badge badge-ghost">
              confiança {round((@status.confidence || 0) * 100)}%
            </span>
            <span class="badge badge-ghost">detecções: {@status.counters.detections}</span>
            <span class="badge badge-ghost">falhas: {@status.counters.failures}</span>
          </div>

          <div
            :if={@status && @status.awaiting_manual?}
            class="mt-4 rounded-xl border border-warning/40 bg-warning/10 p-4"
            role="status"
          >
            <p class="text-lg font-semibold text-warning">{@status.manual_text}</p>
            <p class="mt-1 text-sm text-base-content/70">
              Pesca, batalha e captura estão seguradas pelo fato <code>:mini_game</code>
              e voltam sozinhas quando o overlay sumir.
            </p>
          </div>

          <p :if={@msg} class="mt-3 text-sm text-base-content/70">{@msg}</p>
        </section>

        <section class="rounded-2xl border border-base-content/10 bg-base-200 p-5">
          <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/50">
            Quadro analisado
          </h2>

          <p :if={is_nil(@sample)} class="mt-3 text-sm text-base-content/60">
            Nenhuma partida em andamento. A imagem aparece assim que o overlay for detectado.
          </p>

          <div :if={@sample} class="mt-3 grid gap-4 lg:grid-cols-[minmax(0,320px)_1fr]">
            <%!-- justify-self-start: a grid item stretches by default, and a stretched
                  box would stretch the overlay with it — the lines must sit on the
                  pixels they were read from --%>
            <div class="relative inline-block justify-self-start self-start overflow-hidden rounded-xl border border-base-content/10 bg-base-300">
              <%!-- the strip is tall and narrow (~80x950 px): cap the HEIGHT and let the
                    width follow, or it stretches into a several-thousand-pixel column --%>
              <img
                :if={@preview_src}
                src={@preview_src}
                alt="quadro analisado"
                class="block max-h-[32rem] w-auto"
              />
              <svg
                :if={@sample[:frame_w]}
                viewBox={"0 0 #{@sample.frame_w} #{@sample.frame_h}"}
                preserveAspectRatio="none"
                class="absolute inset-0 h-full w-full"
              >
                <rect
                  x="0.5"
                  y="0.5"
                  width={@sample.frame_w - 1}
                  height={@sample.frame_h - 1}
                  fill="none"
                  stroke="#38bdf8"
                  stroke-width="1"
                  stroke-dasharray="4 3"
                />
                <g :if={@sample[:top]}>
                  <line
                    x1="0"
                    y1={@sample.top}
                    x2={@sample.frame_w}
                    y2={@sample.top}
                    stroke="#94a3b8"
                    stroke-width="1"
                  />
                  <line
                    x1="0"
                    y1={@sample.bottom}
                    x2={@sample.frame_w}
                    y2={@sample.bottom}
                    stroke="#94a3b8"
                    stroke-width="1"
                  />
                  <line
                    :if={@sample[:fish_y]}
                    x1="0"
                    y1={row(@sample, @sample.fish_y)}
                    x2={@sample.frame_w}
                    y2={row(@sample, @sample.fish_y)}
                    stroke="#f97316"
                    stroke-width="2"
                  />
                  <line
                    :if={@sample[:fish_aim]}
                    x1="0"
                    y1={row(@sample, @sample.fish_aim)}
                    x2={@sample.frame_w}
                    y2={row(@sample, @sample.fish_aim)}
                    stroke="#facc15"
                    stroke-width="1"
                    stroke-dasharray="3 2"
                  />
                  <line
                    :if={@sample[:bar_y]}
                    x1="0"
                    y1={row(@sample, @sample.bar_y)}
                    x2={@sample.frame_w}
                    y2={row(@sample, @sample.bar_y)}
                    stroke="#22d3ee"
                    stroke-width="2"
                  />
                </g>
              </svg>
            </div>

            <div class="space-y-3">
              <div class="flex flex-wrap gap-3 text-[0.7rem] text-base-content/70">
                <span class="flex items-center gap-1.5">
                  <span class="inline-block h-0.5 w-4 bg-[#94a3b8]" /> bounds do track
                </span>
                <span class="flex items-center gap-1.5">
                  <span class="inline-block h-0.5 w-4 bg-[#f97316]" /> peixe (bruto)
                </span>
                <span class="flex items-center gap-1.5">
                  <span class="inline-block h-0.5 w-4 bg-[#facc15]" /> peixe (aceito pelo gate)
                </span>
                <span class="flex items-center gap-1.5">
                  <span class="inline-block h-0.5 w-4 bg-[#22d3ee]" /> cápsula
                </span>
              </div>

              <div class="grid grid-cols-2 gap-2 text-sm sm:grid-cols-3">
                <.stat label="leitura" value={to_string(@sample[:read])} />
                <.stat label="origem" value={to_string(@sample[:bar_source] || "—")} />
                <.stat label="captura" value={"#{@sample[:cap_ms]} ms"} />
                <.stat label="intervalo" value={"#{@sample[:gap_ms] || "—"} ms"} />
                <.stat label="tick" value={"#{@sample[:tick_ms]} ms"} />
                <.stat label="peixe (bruto)" value={num(@sample[:fish_y])} />
                <.stat label="peixe (aceito)" value={num(@sample[:fish_aim])} />
                <.stat label="cápsula" value={num(@sample[:bar_y])} />
                <.stat label="erro" value={num(@sample[:error])} />
                <.stat label="v peixe" value={num(@sample[:fish_vy])} />
                <.stat label="v cápsula" value={num(@sample[:bar_vy])} />
                <.stat label="segurando" value={to_string(@sample[:hold])} />
                <.stat label="bounds" value={"#{@sample[:top]}..#{@sample[:bottom]}"} />
                <.stat label="px azul" value={to_string(@sample[:blue_px])} />
                <.stat label="px escuro" value={to_string(@sample[:dark_px])} />
                <.stat
                  label="última recusa"
                  value={if @sample[:accepted] == false, do: to_string(@sample[:verdict]), else: "—"}
                />
                <.stat label="modo" value={Mode.label(@sample[:mode] || @mode)} />
              </div>
            </div>
          </div>
        </section>

        <section :if={@summary} class="rounded-2xl border border-base-content/10 bg-base-200 p-5">
          <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/50">
            Última partida
          </h2>
          <div class="mt-3 grid grid-cols-2 gap-2 text-sm sm:grid-cols-4">
            <.stat label="duração" value={"#{@summary.duration_ms} ms"} />
            <.stat label="ticks" value={to_string(@summary.ticks)} />
            <.stat label="fps" value={to_string(@summary.fps)} />
            <.stat label="captura p95" value={"#{@summary.capture_ms.p95} ms"} />
            <.stat label="trocas de origem" value={to_string(@summary.source_flips)} />
            <.stat label="leituras recusadas" value={to_string(@summary.rejected_readings)} />
            <.stat label="ticks cegos" value={to_string(@summary.blind_ticks)} />
            <.stat label="erro máx" value={to_string(@summary.error_max)} />
            <.stat label="saída" value={to_string(@summary.exit_reason)} />
          </div>
        </section>

        <section class="rounded-2xl border border-base-content/10 bg-base-200 p-5">
          <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/50">
            Pacotes de diagnóstico
          </h2>
          <p class="mt-1 text-xs text-base-content/60">
            O replay roda offline: só Detector, Track e as contas — nunca captura nem tecla.
          </p>

          <p :if={@bundles == []} class="mt-3 text-sm text-base-content/60">
            Nenhum pacote ainda. Cada partida terminada grava um.
          </p>

          <ul class="mt-3 space-y-2">
            <li
              :for={bundle <- @bundles}
              class="flex flex-wrap items-center justify-between gap-2 rounded-xl bg-base-300/60 px-3 py-2 text-sm"
            >
              <span class="font-mono text-xs">{bundle.name}</span>
              <span class="text-xs text-base-content/60">{kb(bundle.bytes)}</span>
              <span class="flex items-center gap-2">
                <.link
                  href={~p"/exports/#{bundle.name}/summary.json"}
                  target="_blank"
                  class="btn btn-ghost btn-xs"
                >
                  summary
                </.link>
                <button phx-click="replay" phx-value-bundle={bundle.path} class="btn btn-xs">
                  replay
                </button>
              </span>
            </li>
          </ul>

          <div :if={@replay} class="mt-4 rounded-xl border border-base-content/10 p-3 text-sm">
            <p class="font-semibold">
              replay: {@replay.frames} quadros de {Path.basename(@replay.source)}
            </p>
            <ul class="mt-2 space-y-1 font-mono text-xs">
              <li :for={sample <- @replay.samples}>
                #{sample[:i]} {sample[:tag]} · leitura {sample[:read]} · peixe {num(sample[:fish_y])} · cápsula {num(
                  sample[:bar_y]
                )} · deriva {num(sample[:fish_drift])}
              </li>
            </ul>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true

  defp stat(assigns) do
    ~H"""
    <div class="rounded-lg bg-base-300/60 px-3 py-2">
      <p class="text-[0.65rem] uppercase tracking-wide text-base-content/50">{@label}</p>
      <p class="font-mono text-sm">{@value}</p>
    </div>
    """
  end

  # Track-normalized 0..1 back to the row it came from, so the overlay lands on
  # the same pixels the reading was taken from.
  defp row(%{top: top, bottom: bottom}, value) when is_number(value),
    do: top + value * max(bottom - top, 1)

  defp row(_sample, _value), do: 0

  defp num(value) when is_float(value), do: value |> Float.round(3) |> to_string()
  defp num(value) when is_integer(value), do: to_string(value)
  defp num(_absent), do: "—"

  defp kb(bytes), do: "#{Float.round(bytes / 1024, 1)} KB"

  defp state_label(:off), do: "parado"
  defp state_label(:watching), do: "observando"
  defp state_label(:playing), do: "em jogo"
  defp state_label(other), do: to_string(other)

  defp preview_src(%{preview_file: file, preview_version: version}),
    do: "/captures/#{file}?v=#{version}"

  defp assign_bundles(socket), do: assign(socket, bundles: Enum.take(Export.list(), 10))

  defp worker_status do
    case GenServer.whereis(Worker) do
      nil -> nil
      _pid -> Worker.status()
    end
  end
end
