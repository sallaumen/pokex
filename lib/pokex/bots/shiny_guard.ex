defmodule Pokex.Bots.ShinyGuard do
  @moduledoc """
  O vigia das CORES ESPECIAIS — o gatilho do SHINY no Poké Alliance, que é o
  mesmo bicho que ele chamava de "chefe" ("o shiny É o chefe (…) nesse jogo o
  que tô chamando de chefe são os shinies", 01/09): recolor, vida e ataque
  muito maiores, e o troféu da noite. Um conceito, um caminho.

  O detector antigo esperava a estrela dourada que o PokeTibia pintava na
  battle list; o PA não pinta estrela nenhuma. O que separa o especial do
  comum aqui é a PALETA: o Electrode shiny é verde onde o comum é vermelho
  (print de 01/09), e o matiz sobrevive a qualquer pose — até ao rollout de
  ponta-cabeça. Então o vigia varre o quadrado ao redor do personagem (o
  mesmo do `SpotScan`) atrás das regras PROVADAS do `ColorRules`, com o
  `ColorMark` fazendo a leitura.

  SEM AÇÕES, por decisão dele (01/09): nem alarme, nem fuga — `shiny_action`
  e o `escape_fun` morreram com a estrela. Avistou = REGISTRA: linha no
  diário, troféu no `ShinyLog`, `{:shiny_seen, info}` no tópico "shiny" (o
  Catcher arma a bola garantida — `shiny_always_ball`), e o medidor vivo do
  painel. A reação inteligente nasce no protocolo shiny da fase 2 do plano
  (docs/shiny/plano-shiny-por-cor.md).

  A confirmação é por VARREDURAS SEGUIDAS (`special_color_confirm_frames`):
  um vislumbre de um quadro só não registra. O refratário por regra segura a
  metralhadora. A caixa do personagem e a do pokémon PARADO são proibidas —
  o verde do Torterra dele é quase o do Electrode shiny (armadilha nº 1 do
  plano); a prova de ruído do acervo é a outra metade dessa defesa.

  Filho sempre-vivo da aplicação, como o Guardian — um shiny importa também
  no jogo manual. `:shiny_guard_active` desliga a instância global nos
  testes; instâncias de teste optam por entrar com `active: true`.
  """

  use GenServer

  alias Pokex.Bots.Capture
  alias Pokex.Bots.Catcher.SpotScan
  alias Pokex.Calibration
  alias Pokex.Perception.WorldState
  alias Pokex.Pokedex.ShinyLog
  alias Pokex.Settings
  alias Pokex.Vision.{ColorMark, ColorRules, Frame}

  @combat_topic "combat"
  # o medidor do painel e o Catcher escutam aqui
  @reading_topic "shiny"
  @idle_poll_ms 1_000
  @refractory_ms 60_000
  @reading_throttle_ms 700
  # a janela em que um kill logo depois do avistamento É aquele shiny morrendo
  @encounter_window_ms 45_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    state = %{
      active?: Keyword.get(opts, :active, Application.get_env(:pokex, :shiny_guard_active, true)),
      capture: Keyword.get(opts, :capture, &Capture.frame/2),
      # varreduras seguidas com mancha, por regra — a confirmação
      streaks: %{},
      # último disparo por regra — o refratário
      fired_at: %{},
      last_fired_at: nil,
      last_reading_at: nil
    }

    case name do
      nil -> GenServer.start_link(__MODULE__, state)
      name -> GenServer.start_link(__MODULE__, state, name: name)
    end
  end

  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(state) do
    # combat's kill broadcast closes an open encounter as "killed"
    Phoenix.PubSub.subscribe(Pokex.PubSub, Pokex.Bots.Catcher.Worker.kill_topic())
    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       enabled?: state.active? and Settings.get(:shiny_guard_enabled),
       armed_rules: length(ColorRules.armed()),
       pending?: state.streaks != %{}
     }, state}
  end

  @impl true
  def handle_info(:scan, state) do
    state =
      if state.active? and Settings.get(:shiny_guard_enabled),
        do: look(state),
        else: %{state | streaks: %{}}

    schedule(state)
    {:noreply, state}
  end

  # A kill right after a sighting IS that shiny dying (Lucas: "se eu matei um
  # Shiny"). Outside the window it is an ordinary kill — ignored.
  def handle_info(kill, state) when kill in [{:kill}, {:kill, nil}] do
    if recent_sighting?(state), do: ShinyLog.resolve_last("killed")
    {:noreply, state}
  end

  def handle_info({:kill, _corpse}, state) do
    if recent_sighting?(state), do: ShinyLog.resolve_last("killed")
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- a varredura -------------------------------------------------------------

  defp look(state) do
    case ColorRules.armed() do
      [] ->
        %{state | streaks: %{}}

      rules ->
        case snapshot(state) do
          {:ok, frame, forbidden} -> judge(state, rules, frame, forbidden)
          # Cego não é "não tem chefe": sem foto o fato NÃO é reescrito, e ele
          # envelhece sozinho até o cérebro parar de acreditar nele.
          _blind -> state
        end
    end
  end

  defp snapshot(state) do
    with {:ok, calib} <- Calibration.load(),
         {:ok, {_x, _y, _w, _h} = region} <- SpotScan.region(calib),
         {:ok, %Frame{} = frame} <- state.capture.(region, "special_colors.raw") do
      {:ok, frame, forbidden_boxes(calib, frame, region)}
    end
  end

  # O personagem e o pokémon PARADO viram caixas proibidas de 3×3 tiles: o
  # verde do próprio Torterra é quase o do Electrode shiny. Pontos em
  # coordenadas de TELA; o frame conhece a própria escala.
  defp forbidden_boxes(calib, %Frame{scale: scale}, {rx, ry, _w, _h}) do
    meia = round(Calibration.tile_px() * 1.5 * scale)

    [calib.player_point, calib.pokemon_spot_point]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn {sx, sy} ->
      fx = round((sx - rx) * scale)
      fy = round((sy - ry) * scale)
      {fx - meia, fy - meia, fx + meia, fy + meia}
    end)
  end

  defp judge(state, rules, frame, forbidden) do
    {state, best, vistos} =
      Enum.reduce(rules, {state, 0, []}, fn rule, {state, best, vistos} ->
        result =
          ColorMark.scan(frame, rule.specs,
            min_cell_px: rule.min_cell_px,
            forbidden: forbidden
          )

        mancha = List.first(result.manchas)
        hit? = mancha != nil and mancha.px >= rule.min_px

        {advance(state, rule, mancha, hit?), max(best, result.px),
         if(hit?, do: [{rule, mancha} | vistos], else: vistos)}
      end)

    publish_special(vistos)
    broadcast_reading(state, best)
  end

  # O FATO, publicado a CADA varredura — não a cada anúncio. O troféu tem
  # refratário de um minuto (ninguém quer a metralhadora), mas o cérebro
  # precisa da PRESENÇA: enquanto o chefe está na tela, `heavy?` tem que ficar
  # de pé, e cair quando ele sai. São perguntas diferentes e relógios
  # diferentes.
  defp publish_special(vistos) do
    WorldState.put(
      :special,
      %{
        especial?: vistos != [],
        vistos: Enum.map(vistos, fn {rule, m} -> %{name: rule.name, px: m.px, point: m.point} end)
      },
      System.monotonic_time(:millisecond)
    )
  end

  defp advance(state, rule, _mancha, false),
    do: %{state | streaks: Map.delete(state.streaks, rule.slug)}

  defp advance(state, rule, mancha, true) do
    streak = Map.get(state.streaks, rule.slug, 0) + 1
    state = %{state | streaks: Map.put(state.streaks, rule.slug, streak)}

    if streak >= Settings.get(:special_color_confirm_frames) and cooled?(state, rule.slug),
      do: fire(state, rule, mancha),
      else: state
  end

  defp cooled?(state, slug) do
    case Map.get(state.fired_at, slug) do
      nil -> true
      at -> System.monotonic_time(:millisecond) - at > @refractory_ms
    end
  end

  # Avistou: registra e anuncia — nenhuma ação (decisão dele, 01/09). O
  # Catcher escuta o {:shiny_seen, _} e arma a bola garantida.
  defp fire(state, rule, mancha) do
    reason = "✨ #{rule.name} na tela — mancha de #{mancha.px}px da cor dele"

    # the trophy shelf first: the encounter is logged even if a broadcast fails.
    # `star_px` é o nome histórico do campo (a estrela morreu, o campo ficou):
    # hoje guarda os px da MANCHA.
    ShinyLog.record(star_px: mancha.px, action: nil, outcome: "seen", note: rule.name)

    Phoenix.PubSub.broadcast(Pokex.PubSub, @combat_topic, {:combat_log, :macro, reason})

    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      @reading_topic,
      {:shiny_seen, %{px: mancha.px, name: rule.name, point: mancha.point}}
    )

    now = System.monotonic_time(:millisecond)

    %{
      state
      | streaks: Map.delete(state.streaks, rule.slug),
        fired_at: Map.put(state.fired_at, rule.slug, now),
        last_fired_at: now
    }
  end

  defp recent_sighting?(%{last_fired_at: nil}), do: false

  defp recent_sighting?(%{last_fired_at: at}),
    do: System.monotonic_time(:millisecond) - at <= @encounter_window_ms

  # Feed the panel's live meter — throttled so the scan cadence doesn't
  # re-render the panel several times a second.
  defp broadcast_reading(state, px) do
    now = System.monotonic_time(:millisecond)

    if state.last_reading_at == nil or now - state.last_reading_at > @reading_throttle_ms do
      Phoenix.PubSub.broadcast(Pokex.PubSub, @reading_topic, {:shiny_reading, %{px: px}})
      %{state | last_reading_at: now}
    else
      state
    end
  end

  # Ligado, a cadência é a da varredura; desligado (ou sem regra armada), um
  # tique lento só pra reavaliar o interruptor.
  defp schedule(state) do
    ms =
      if state.active? and Settings.get(:shiny_guard_enabled) and ColorRules.armed() != [],
        do: Settings.get(:special_color_scan_ms),
        else: @idle_poll_ms

    Process.send_after(self(), :scan, ms)
  end
end
