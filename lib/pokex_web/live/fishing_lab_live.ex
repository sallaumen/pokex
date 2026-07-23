defmodule PokexWeb.FishingLabLive do
  use PokexWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Laboratorio de pesca")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_page={:fishing_lab} {Layouts.header(assigns)}>
      <div class="space-y-5">
        <section class="overflow-hidden rounded-2xl border border-base-content/10 bg-base-200">
          <div class="grid gap-0 lg:grid-cols-[minmax(0,1fr)_16rem]">
            <div class="p-5">
              <div class="mb-3 flex flex-wrap items-center gap-2">
                <span class="badge badge-primary gap-1.5">
                  <.icon name="hero-sparkles" class="size-3.5" /> simulador local
                </span>
                <span class="badge badge-ghost">jogo a 60 FPS · visao configuravel</span>
                <span class="badge badge-ghost">input minimo 50ms</span>
              </div>
              <h1 class="text-2xl font-bold tracking-tight">Laboratorio do peixe</h1>
              <p class="mt-2 max-w-2xl text-sm leading-6 text-base-content/70">
                Um minigame isolado para calibrar a fisica da barra, testar deteccao por
                diferenca de fundo e medir um piloto automatico com limites de atuacao.
                Nada aqui envia tecla para fora da pagina.
              </p>
            </div>

            <div class="border-t border-base-content/10 bg-base-300/70 p-5 lg:border-l lg:border-t-0">
              <p class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
                Modelo
              </p>
              <p class="mt-2 text-sm leading-6">
                O peixe combina ondas, impulso aleatorio e amortecimento. O detector olha
                pixels diferentes do fundo, entao a cor do peixe pode variar sem mudar o
                algoritmo.
              </p>
            </div>
          </div>
        </section>

        <section
          id="fishing-lab"
          phx-hook="FishingLab"
          phx-update="ignore"
          data-min-toggle-ms="50"
          class="rounded-2xl border border-base-content/10 bg-base-200 p-3 shadow-sm sm:p-4"
        >
          <div class="grid gap-4 lg:grid-cols-[minmax(0,420px)_1fr]">
            <div class="space-y-3">
              <div class="relative overflow-hidden rounded-xl border border-base-content/10 bg-base-300">
                <canvas
                  id="fishing-game-canvas"
                  width="420"
                  height="680"
                  tabindex="0"
                  aria-label="Simulador local do minigame de pesca"
                  class="block aspect-[420/680] w-full cursor-crosshair outline-none"
                ></canvas>
                <div class="pointer-events-none absolute left-3 top-3 rounded-lg bg-black/55 px-2.5 py-1.5 text-xs font-semibold text-white backdrop-blur">
                  Space: segurar/soltar
                </div>
              </div>

              <div class="grid grid-cols-3 gap-2 text-center text-xs">
                <div class="rounded-lg border border-base-content/10 bg-base-300 px-2 py-2">
                  <div class="text-[10px] uppercase tracking-wide opacity-50">Progresso</div>
                  <div data-stat="progress" class="mt-1 text-lg font-bold tabular-nums">0%</div>
                </div>
                <div class="rounded-lg border border-base-content/10 bg-base-300 px-2 py-2">
                  <div class="text-[10px] uppercase tracking-wide opacity-50">Sobreposicao</div>
                  <div data-stat="overlap" class="mt-1 text-lg font-bold tabular-nums">0%</div>
                </div>
                <div class="rounded-lg border border-base-content/10 bg-base-300 px-2 py-2">
                  <div class="text-[10px] uppercase tracking-wide opacity-50">FPS visao</div>
                  <div data-stat="vision-fps" class="mt-1 text-lg font-bold tabular-nums">0</div>
                </div>
              </div>
            </div>

            <div class="flex min-w-0 flex-col gap-3">
              <div class="grid grid-cols-2 gap-2">
                <button
                  type="button"
                  data-lab-action="toggle-running"
                  class="btn btn-primary gap-1.5"
                >
                  <.icon name="hero-pause" class="size-4" />
                  <span data-label="running">Pausar</span>
                </button>
                <button type="button" data-lab-action="reset" class="btn btn-outline gap-1.5">
                  <.icon name="hero-arrow-path" class="size-4" /> Reiniciar
                </button>
                <button
                  type="button"
                  data-lab-action="toggle-auto"
                  class="btn btn-success gap-1.5"
                >
                  <.icon name="hero-cpu-chip" class="size-4" />
                  <span data-label="auto">Auto ligado</span>
                </button>
                <button type="button" data-lab-action="new-fish" class="btn btn-outline gap-1.5">
                  <.icon name="hero-swatch" class="size-4" /> Nova cor
                </button>
                <div class="join col-span-2 w-full">
                  <button
                    type="button"
                    data-lab-pilot="reactive"
                    class="btn btn-outline btn-sm join-item flex-1"
                  >
                    Reativo
                  </button>
                  <button
                    type="button"
                    data-lab-pilot="predictive"
                    class="btn btn-outline btn-sm join-item flex-1 btn-active"
                  >
                    Preditivo
                  </button>
                </div>
              </div>

              <div class="rounded-xl border border-base-content/10 bg-base-300 p-3">
                <div class="mb-2 flex items-center justify-between gap-2">
                  <h2 class="text-sm font-semibold">Estado do piloto</h2>
                  <span data-stat="press-state" class="badge badge-ghost">solto</span>
                </div>
                <div class="grid grid-cols-2 gap-2 text-xs">
                  <div>
                    <div class="opacity-50">Acao/min</div>
                    <div data-stat="actions" class="text-lg font-semibold tabular-nums">0</div>
                  </div>
                  <div>
                    <div class="opacity-50">Confianca visual</div>
                    <div data-stat="confidence" class="text-lg font-semibold tabular-nums">0%</div>
                  </div>
                  <div>
                    <div class="opacity-50">Erro medio</div>
                    <div data-stat="error" class="text-lg font-semibold tabular-nums">0px</div>
                  </div>
                  <div>
                    <div class="opacity-50">Rodada</div>
                    <div data-stat="round" class="text-lg font-semibold tabular-nums">1</div>
                  </div>
                  <div>
                    <div class="opacity-50">Ultima leitura</div>
                    <div data-stat="reading-age" class="text-lg font-semibold tabular-nums">—</div>
                  </div>
                  <div>
                    <div class="opacity-50">Placar</div>
                    <div data-stat="score" class="text-lg font-semibold tabular-nums">0V · 0D</div>
                  </div>
                </div>
              </div>

              <div class="space-y-3 rounded-xl border border-base-content/10 bg-base-300 p-3">
                <label for="fishing-lab-difficulty" class="block">
                  <div class="mb-1 flex items-center justify-between gap-3 text-sm">
                    <span>Dificuldade</span>
                    <span data-output="difficulty" class="font-mono text-xs opacity-60">65%</span>
                  </div>
                  <input
                    id="fishing-lab-difficulty"
                    type="range"
                    min="20"
                    max="100"
                    value="65"
                    data-lab-range="difficulty"
                    class="range range-primary range-sm"
                  />
                </label>

                <label for="fishing-lab-latency" class="block">
                  <div class="mb-1 flex items-center justify-between gap-3 text-sm">
                    <span>Latencia do piloto</span>
                    <span data-output="latency" class="font-mono text-xs opacity-60">110ms</span>
                  </div>
                  <input
                    id="fishing-lab-latency"
                    type="range"
                    min="50"
                    max="240"
                    value="110"
                    step="5"
                    data-lab-range="latency"
                    class="range range-info range-sm"
                  />
                </label>

                <label for="fishing-lab-deadband" class="block">
                  <div class="mb-1 flex items-center justify-between gap-3 text-sm">
                    <span>Zona morta</span>
                    <span data-output="deadband" class="font-mono text-xs opacity-60">13px</span>
                  </div>
                  <input
                    id="fishing-lab-deadband"
                    type="range"
                    min="4"
                    max="32"
                    value="13"
                    data-lab-range="deadband"
                    class="range range-warning range-sm"
                  />
                </label>

                <label for="fishing-lab-vision-fps" class="block">
                  <div class="mb-1 flex items-center justify-between gap-3 text-sm">
                    <span>FPS da visao</span>
                    <span data-output="vision-fps" class="font-mono text-xs opacity-60">7 fps · ~143ms</span>
                  </div>
                  <input
                    id="fishing-lab-vision-fps"
                    type="range"
                    min="2"
                    max="60"
                    value="7"
                    data-lab-range="vision-fps"
                    class="range range-secondary range-sm"
                  />
                </label>

                <label for="fishing-lab-loss" class="block">
                  <div class="mb-1 flex items-center justify-between gap-3 text-sm">
                    <span>Leituras perdidas</span>
                    <span data-output="loss" class="font-mono text-xs opacity-60">0%</span>
                  </div>
                  <input
                    id="fishing-lab-loss"
                    type="range"
                    min="0"
                    max="40"
                    value="0"
                    step="5"
                    data-lab-range="loss"
                    class="range range-error range-sm"
                  />
                </label>

                <label class="flex cursor-pointer items-center justify-between gap-3 text-sm">
                  <span>Deteccao por pixels</span>
                  <input
                    type="checkbox"
                    data-lab-action="toggle-vision"
                    class="toggle toggle-info toggle-sm"
                    checked
                  />
                </label>
              </div>

              <p
                data-stat="message"
                class="min-h-10 rounded-lg bg-base-100 px-3 py-2 text-sm text-base-content/70"
              >
                O piloto esta usando apenas o detector local do canvas.
              </p>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
