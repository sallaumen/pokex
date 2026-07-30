defmodule Pokex.Bots.Guardian do
  @moduledoc """
  The single owner of the panic corner. Polls `Body.cursor/1` on a timer
  (bypasses the input queue — safe to poll live) and, the instant the cursor
  sits in `Pokex.Bots.Corner`'s top-left kill corner, halts EVERYTHING at
  once via `on_panic` and broadcasts `{:panic, "kill corner"}` on both the
  "fishing" and "combat" PubSub topics.

  ALSO the watchdog for the session STOP CONDITIONS (hunt goals) and the
  ANTI-STAGNATION rule: the same poll checks the `:session` fact against
  `stop_after_minutes` / `stop_after_kills`, and against
  `stagnation_minutes` of silence, whose action is an `{:rule_alarm, _}`
  broadcast (re-armed per window), the same full stop, or a LOGOUT. A hit
  halts the fleet through the SAME latch + on_panic path as the corner — a
  reached goal is a standing order to stay stopped until the human presses
  Iniciar — but broadcasts `{:session_stop, reason}` instead of
  `{:panic, _}`, so the panel reports a met goal, not an emergency. Being
  external to every worker, the stop can never deadlock on a worker halting
  itself; and since `on_panic` (stop_all) forgets the `:session` fact, a
  fired condition cannot re-fire.

  ## O que conta como sinal de vida

  Kill + MINIGAME VENCIDO. **Não** fisgada: uma fisgada é o puxão da vara, e
  com o minigame travado a vara fisga a noite inteira sem pegar peixe nenhum —
  o contador sobe, o relógio zera, e a regra dorme feliz enquanto a estamina
  queima. Foi exatamente assim que uma madrugada da conta principal do Lucas
  foi embora. A fisgada só volta a valer quando o vigia do minigame está
  parado (ele jogando o minigame na mão), senão a regra dispararia no meio de
  uma pescaria que ia bem. Os três contadores pegam carona nos snapshots que
  combate, pesca e minigame já publicam; este processo assina os três.

  Deslogar é a ação que de fato economiza estamina: parar o bot não economiza
  nada, porque o personagem continua online. O `Pokex.Bots.Logout` (injetável
  por `:logout_fun`) trava o latch e para a frota por conta própria — aqui não
  se duplica nenhum dos dois.

  `on_panic` is injected (not a hard dependency on the bot supervisor) so
  this module doesn't need to know about `BotSupervisor` — callers pass e.g.
  `&BotSupervisor.stop_all/0`.

  Design note: `on_panic` fires on EVERY poll tick that finds the cursor in
  the corner, not just on the first entry. A human parked in the corner
  wants the bot to stay stopped, and re-invoking a stop is harmless as long
  as `on_panic` is idempotent (stopping already-stopped workers is a no-op)
  — which is simpler and safer than tracking "fresh entry" edge state that
  could itself have a bug that lets a second panic slip through unhandled.

  The poll loop must never crash on a bad cursor read: an `{:error, _}`
  reply (or any other unexpected shape) just reschedules the next poll.

  Bound on the panic guarantee: panic is delivered promptly but is bounded
  by whatever `Body` action is currently in flight — a worker blocked
  mid-action is halted once that action returns (actions are short: one
  osascript/cliclick).
  """
  use GenServer
  require Logger

  alias Pokex.Bots.{Body, Corner, InputGate}
  alias Pokex.Perception.WorldState
  alias Pokex.Settings

  @fishing_topic "fishing"
  @combat_topic "combat"

  # same practically-forever max age the :calibration/:session stamps use
  @session_max_age_ms 4_000_000_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    on_panic = Keyword.fetch!(opts, :on_panic)
    body = Keyword.get(opts, :body, Body)
    poll_ms = Keyword.get(opts, :poll_ms, 100)

    # Same pattern as :player_support_auto_monitor: the env flag turns the
    # session rules OFF for the app-global instance in the test env, so a test
    # planting a :session fact + global limits never wakes the real Guardian
    # (its real stop_all would race the test's own scoped Guardian — measured
    # flaky). Test Guardians opt back in via the option.
    session_rules? =
      Keyword.get(
        opts,
        :session_rules,
        Application.get_env(:pokex, :guardian_session_rules, true)
      )

    state = %{
      on_panic: on_panic,
      body: body,
      poll_ms: poll_ms,
      session_rules?: session_rules?,
      logout_fun: Keyword.get(opts, :logout_fun, &Pokex.Bots.Logout.request/1),
      # canto de COMANDO (superior direito): dependências injetáveis pro teste
      # nunca ligar a frota real nem ler calibração de verdade
      command_toggle: Keyword.get(opts, :command_toggle, &__MODULE__.default_command_toggle/0),
      screen_w_fun: Keyword.get(opts, :screen_w_fun, &__MODULE__.default_screen_w/0),
      # quando o cursor ENTROU no canto de comando (nil = fora dele) e se o
      # comando desta visita já disparou — exige SAIR do canto pra rearmar
      command_since: nil,
      command_fired?: false,
      fights: 0,
      hooked: 0,
      clears: 0,
      # o vigia do minigame está rodando? Enquanto nunca ouvimos falar dele,
      # assumimos que NÃO — o padrão seguro, porque é ele que faz a fisgada
      # voltar a contar como sinal de vida.
      mini_game_running?: false,
      # last time a REAL sign of life was SEEN (monotonic ms; nil = none
      # yet this run) — the anti-stagnation rule measures silence from here
      last_activity_at: nil
    }

    case name do
      nil -> GenServer.start_link(__MODULE__, state)
      name -> GenServer.start_link(__MODULE__, state, name: name)
    end
  end

  @impl true
  def init(state) do
    # kills (stop condition + stagnation) and hooked fish (stagnation) ride
    # the snapshots the workers already broadcast
    Phoenix.PubSub.subscribe(Pokex.PubSub, @combat_topic)
    Phoenix.PubSub.subscribe(Pokex.PubSub, @fishing_topic)
    # o peixe DE VERDADE (minigame vencido) e se o vigia está de pé
    Phoenix.PubSub.subscribe(Pokex.PubSub, Pokex.Bots.MiniGame.Worker.topic())
    schedule_poll(state.poll_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    state =
      case Body.cursor(state.body) do
        {:ok, point} ->
          in_corner? = Corner.in_kill_corner?(point)
          # The gate closes the moment the cursor enters the corner, so it ALSO suppresses the
          # always-on PlayerSupport's revive/potion — not just the Start/Stop workers on_panic
          # halts. It reopens when the cursor leaves, so manual-play protection comes right back.
          InputGate.set_corner_ok(not in_corner?)
          if in_corner?, do: panic(state)

          check_command_corner(state, point)

        _error ->
          state
      end

    state = check_session_limits(state)
    schedule_poll(state.poll_ms)
    {:noreply, state}
  end

  def handle_info({:combat, snapshot}, state),
    do: {:noreply, track_counter(state, :fights, get_in(snapshot, [:counters, :fights]))}

  # Uma FISGADA é o puxão da vara, não o peixe. Com o vigia do minigame rodando,
  # o peixe de verdade é o `clears`: um minigame travado fisga a noite inteira e
  # pega nada — foi exatamente assim que uma madrugada de estamina foi embora.
  # Com o vigia desligado (o Lucas jogando o minigame na mão) a fisgada volta a
  # ser o melhor sinal que temos; sem esse recuo, a regra deslogaria ele no meio
  # de uma pescaria que ia bem.
  def handle_info({:fishing, snapshot}, state) do
    hooked = get_in(snapshot, [:counters, :hooked])

    if state.mini_game_running?,
      do: {:noreply, store_counter(state, :hooked, hooked)},
      else: {:noreply, track_counter(state, :hooked, hooked)}
  end

  def handle_info({:mini_game, snapshot}, state) do
    state = %{state | mini_game_running?: Map.get(snapshot, :state) != :off}
    {:noreply, track_counter(state, :clears, get_in(snapshot, [:counters, :clears]))}
  end

  # the subscribed topics also carry {:*_log, ...} / {:panic, ...} chatter — not ours
  def handle_info(_msg, state), do: {:noreply, state}

  # A counter INCREASE is activity; a decrease is the run-start reset (workers
  # zero their counters on run) — store it silently so the next real kill/hook
  # still reads as an increase.
  defp track_counter(state, key, value) do
    cond do
      not is_integer(value) ->
        state

      value > Map.fetch!(state, key) ->
        state
        |> Map.put(key, value)
        |> Map.put(:last_activity_at, System.monotonic_time(:millisecond))

      true ->
        Map.put(state, key, value)
    end
  end

  # Guarda o contador SEM marcar atividade. Existe para que desligar o vigia do
  # minigame no meio de uma sessão não faça o salto acumulado de fisgadas passar
  # por um sinal de vida que nunca houve.
  defp store_counter(state, key, value) when is_integer(value), do: Map.put(state, key, value)
  defp store_counter(state, _key, _value), do: state

  defp panic(state) do
    # LATCH FIRST, halt second: the latch is what forbids every auto-resume path (the Focus
    # poller's refocus resume) from restarting workers over this human order — set it before
    # anything else so no resume can slip in between. Only Iniciar bot clears it.
    InputGate.set_panic_latch(true)
    state.on_panic.()
    Phoenix.PubSub.broadcast(Pokex.PubSub, @fishing_topic, {:panic, "kill corner"})
    Phoenix.PubSub.broadcast(Pokex.PubSub, @combat_topic, {:panic, "kill corner"})
  end

  # O canto de COMANDO (superior direito): segurar o mouse ali por
  # command_corner_dwell_ms liga/desliga o último modo usado — de DENTRO do
  # jogo. Existe porque clicar Iniciar no navegador TIRA o foco do jogo, e o
  # portão (fail-closed, certo) engolia os primeiros passos da frota — a
  # regressão real de 2026-07-29. Mover o mouse não muda foco.
  #
  # Anti-acidente em três camadas: a DEMORA (passar o mouse pelo canto não
  # dispara), o REARME (é preciso SAIR do canto antes de outro comando) e o
  # canto OPOSTO ao do pânico (os dois nunca se confundem — pânico continua
  # sendo instantâneo e soberano).
  defp check_command_corner(state, point) do
    enabled? = Settings.get(:command_corner) == true
    screen_w = state.screen_w_fun.()

    cond do
      not enabled? or screen_w == nil ->
        %{state | command_since: nil, command_fired?: false}

      not Corner.in_command_corner?(point, screen_w) ->
        %{state | command_since: nil, command_fired?: false}

      state.command_fired? ->
        state

      state.command_since == nil ->
        %{state | command_since: System.monotonic_time(:millisecond)}

      System.monotonic_time(:millisecond) - state.command_since >=
          Settings.get(:command_corner_dwell_ms) ->
        state.command_toggle.()
        %{state | command_fired?: true}

      true ->
        state
    end
  end

  @doc false
  # Liga se está tudo parado; para se algo roda. O start vai num Task porque o
  # preflight faz capturas (segundos) e o poll do canto de pânico NUNCA pode
  # ficar surdo esperando — a lição do Logout.
  def default_command_toggle do
    status = Pokex.Bots.BotSupervisor.status()

    if Pokex.Bots.BotSupervisor.any_active?([
         status.fishing,
         status.combat,
         status.cavebot,
         status.mini_game
       ]) do
      Phoenix.PubSub.broadcast(
        Pokex.PubSub,
        @combat_topic,
        {:rule_alarm, :comando, "🕹️ canto de comando: parando o bot"}
      )

      Pokex.Bots.BotSupervisor.stop_all("canto de comando")
    else
      Phoenix.PubSub.broadcast(
        Pokex.PubSub,
        @combat_topic,
        {:rule_alarm, :comando, "🕹️ canto de comando: ligando o modo #{Pokex.Modes.current()}"}
      )

      {:ok, _pid} = Task.start(fn -> Pokex.Bots.BotSupervisor.start_all() end)
      :ok
    end
  end

  @doc false
  # A largura da tela vem da calibração (o canto de pânico não precisa — {0,0}
  # é universal; o canto oposto não é). Sem calibração → canto desligado.
  def default_screen_w do
    case Pokex.Calibration.load() do
      {:ok, calib} -> Map.get(calib, :screen_w)
      _sem_calibracao -> nil
    end
  end

  # No running session (no fact) = nothing to measure; 0 = condition off.
  # A fired stop halts the fleet, which forgets :session — self-disarming.
  defp check_session_limits(%{session_rules?: false} = state), do: state

  defp check_session_limits(state) do
    now = System.monotonic_time(:millisecond)

    case WorldState.get(:session, @session_max_age_ms, now) do
      {:ok, %{started_at: started_at}} ->
        minutes = Settings.get(:stop_after_minutes)
        kills = Settings.get(:stop_after_kills)

        cond do
          is_integer(minutes) and minutes > 0 and now - started_at >= minutes * 60_000 ->
            session_end(state, "tempo de caçada atingido (#{minutes}min)")
            state

          is_integer(kills) and kills > 0 and state.fights >= kills ->
            session_end(state, "meta de kills atingida (#{state.fights}/#{kills})")
            state

          true ->
            check_stagnation(state, started_at, now)
        end

      _no_session ->
        state
    end
  end

  # Uma meta batida ENCERRA a sessão. "parar" trava tudo como sempre;
  # "deslogar" encerra a conta, que é o que de fato economiza estamina — parar
  # o bot não economiza nada, o personagem segue online queimando.
  # O Logout trava o latch e para a frota por conta própria; aqui não se duplica
  # nenhum dos dois.
  defp session_end(state, reason) do
    case Settings.get(:stop_after_action) do
      "deslogar" ->
        Logger.info("Guardian: #{reason} — deslogando")
        state.logout_fun.(reason)

      _parar ->
        session_stop(state, reason)
    end
  end

  # The anti-stagnation rule: silence (no kill, no won mini-game) measured from
  # the LATER of session start / last activity / last ring — so the alarm
  # action re-rings only after ANOTHER full silent window (its own cooldown),
  # and a fresh session never inherits old silence.
  defp check_stagnation(state, started_at, now) do
    minutes = Settings.get(:stagnation_minutes)
    baseline = max(state.last_activity_at || started_at, started_at)

    if is_integer(minutes) and minutes > 0 and now - baseline >= minutes * 60_000 do
      reason = "estagnação: sem kills nem peixes há #{minutes}min"

      case Settings.get(:stagnation_action) do
        "parar" ->
          session_stop(state, reason)
          state

        "deslogar" ->
          Logger.info("Guardian: #{reason} — deslogando")
          state.logout_fun.(reason)
          state

        _alarme ->
          Logger.info("Guardian: #{reason}")
          Phoenix.PubSub.broadcast(Pokex.PubSub, @combat_topic, {:rule_alarm, :sessao, reason})
          %{state | last_activity_at: now}
      end
    else
      state
    end
  end

  defp session_stop(state, reason) do
    Logger.info("Guardian: parada por condição — #{reason}")
    # same order as panic: latch first, halt second — nothing may auto-resume
    # a finished hunt; only Iniciar clears it.
    InputGate.set_panic_latch(true)
    state.on_panic.()
    Phoenix.PubSub.broadcast(Pokex.PubSub, @combat_topic, {:session_stop, reason})
  end

  defp schedule_poll(poll_ms), do: Process.send_after(self(), :poll, poll_ms)
end
