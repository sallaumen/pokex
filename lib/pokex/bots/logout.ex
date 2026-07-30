defmodule Pokex.Bots.Logout do
  @moduledoc """
  Encerra a sessão do jogo de verdade: Ctrl+Q, Enter, e então CONFERE A TELA.

  Existe porque parar o bot não economiza estamina — estamina queima enquanto o
  personagem está online. Uma madrugada inteira da conta principal do Lucas foi
  embora com o minigame travado: o bot continuou fisgando, produziu zero peixe,
  e nada tinha autoridade para encerrar a sessão.

  ## Por que um processo próprio

  O ciclo apertar → esperar → conferir → tentar de novo leva segundos. Quem
  dispara é o `Guardian`, que precisa continuar checando o canto do pânico a
  cada 100ms. Bloquear o `Guardian` por cinco segundos deixaria o canto do
  pânico surdo por cinco segundos.

  ## Por que conferir a tela não é luxo

  Com o `InputGate` fechado, `Rig.Mac.gated/1` engole a tecla e devolve `:ok` —
  de propósito, para nenhum worker confundir "segurei por segurança" com
  "falhou". Foi exatamente assim que o cavebot morreu achando que tinha andado.
  Um logout que confia no `:ok` do `Body` tem o mesmo destino: reporta
  deslogado, o Lucas vai dormir, e a estamina queima a noite toda. A tela é a
  única testemunha honesta.

  A leitura sai do fato `:hud` do `WorldState`: deslogado é nível, comida E
  pesca pararem de dar número ao mesmo tempo. Um fato VELHO devolve
  `:unreadable`, nunca `:gone` — ler `World.snapshot()` seria errado aqui,
  porque ele devolve `nil` nos três campos tanto para "tela vazia" quanto para
  "o feed parou", e essa confusão inventaria um logout que não aconteceu.

  Quando a tela de seleção de personagem virar região calibrada, `read_fun`
  troca de uma checagem NEGATIVA ("a HUD sumiu") para uma POSITIVA ("vejo a
  lista de personagens"). O contrato `:gone | :present | :unreadable` não muda.
  """
  use GenServer
  require Logger

  alias Pokex.Bots.{Body, BotSupervisor, Focus, InputGate}
  alias Pokex.Bots.Logout.Logic
  alias Pokex.Perception
  alias Pokex.Perception.WorldState
  alias Pokex.Settings

  @topic "logout"
  @combat_topic "combat"
  # O feed :hud publica a cada 250-500ms; dois segundos já é "parou de chegar".
  @hud_max_age_ms 2_000
  # Intervalo entre as leituras DEPOIS da primeira (a primeira espera
  # logout_verify_delay_ms, que é o tempo da tela trocar).
  @read_gap_ms 400

  def topic, do: @topic

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    state = %{
      # Mesmo padrão de :shiny_guard_active — a instância do app não age durante
      # a suíte; instâncias de teste optam por entrar.
      active?: Keyword.get(opts, :active, Application.get_env(:pokex, :logout_active, true)),
      perform_fun: Keyword.get(opts, :perform_fun, &Body.perform(&1, &2)),
      stop_fun: Keyword.get(opts, :stop_fun, fn -> BotSupervisor.stop_all("deslogando") end),
      front_fun: Keyword.get(opts, :front_fun, &Focus.ensure_front/0),
      read_fun: Keyword.get(opts, :read_fun, &__MODULE__.read_hud/0),
      # Sobrescrevem o número de tentativas e o ritmo entre leituras. Existem
      # só para o teste: sem eles, um caso de falha esperaria três ciclos de
      # ~3s cada. Deliberadamente NÃO são ajustes do painel — o Lucas não tem
      # o que decidir aqui, e cinco botões novos já são bastante.
      attempts_override: Keyword.get(opts, :attempts_override),
      read_gap_ms: Keyword.get(opts, :read_gap_ms, @read_gap_ms),
      logic: nil,
      finished_at: nil,
      duplicates: 0
    }

    case name do
      nil -> GenServer.start_link(__MODULE__, state)
      name -> GenServer.start_link(__MODULE__, state, name: name)
    end
  end

  @doc """
  Pede um logout. Assíncrono de propósito: quem chama (o `Guardian`) não pode
  bloquear. Idempotente — um pedido com outro em voo é ignorado e contado em
  `duplicates`, o que importa porque o `Guardian` reavalia a condição a cada
  100ms.
  """
  @spec request(String.t(), GenServer.server()) :: :ok
  def request(reason, server \\ __MODULE__), do: GenServer.cast(server, {:request, reason})

  @doc "O snapshot que o painel desenha."
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc false
  # A leitura padrão da tela. Pública para servir de `read_fun` padrão.
  @spec read_hud() :: Logic.reading()
  def read_hud do
    case WorldState.get(:hud, @hud_max_age_ms, System.monotonic_time(:millisecond)) do
      {:ok, %{level: nil, food: nil, fishing: nil}} -> :gone
      {:ok, _algum_numero} -> :present
      _sem_fato_fresco -> :unreadable
    end
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:status, _from, state), do: {:reply, snapshot(state), state}

  @impl true
  def handle_cast({:request, _reason}, %{active?: false} = state), do: {:noreply, state}

  def handle_cast({:request, reason}, state) do
    if state.logic != nil and in_flight?(state.logic) do
      Logger.info("Logout: pedido '#{reason}' ignorado — já tem um em voo")
      {:noreply, %{state | duplicates: state.duplicates + 1}}
    else
      begin(state, reason)
    end
  end

  @impl true
  def handle_info(:press, state) do
    result =
      case state.front_fun.() do
        :ok -> press_keys(state)
        {:error, _reason} = error -> error
      end

    advance(Logic.after_press(state.logic, result), state)
  end

  def handle_info(:read, state),
    do: advance(Logic.after_read(state.logic, state.read_fun.()), state)

  def handle_info(_msg, state), do: {:noreply, state}

  # -- o protocolo -------------------------------------------------------------

  # LATCH PRIMEIRO, parar depois: o latch é o que proíbe todo caminho de
  # auto-retomada (a retomada do Focus ao reganhar foco) de religar workers por
  # cima desta ordem. Ele CONTINUA travado depois de um logout bem-sucedido —
  # só o Iniciar bot limpa.
  defp begin(state, reason) do
    # A TESTEMUNHA, lida antes de mexer em qualquer coisa: se a barra de baixo
    # não está legível AGORA, ela também não estará depois, e um "sumiu" não
    # provaria nada. A HUD devolve nil nos três campos tanto para "deslogado"
    # quanto para "sub-região descalibrada" ou "atlas sem o dígito" — o "9" que
    # faltava é caso real. Sem essa medida diferencial, um atlas incompleto faria
    # o bot jurar que deslogou sem ter apertado nada que funcionasse.
    baseline = state.read_fun.()

    if baseline != :present do
      Logger.warning(
        "Logout: a barra de baixo já estava ilegível ANTES de apertar (#{baseline}) — " <>
          "vou tentar mesmo assim, mas não vou conseguir confirmar"
      )
    end

    InputGate.set_panic_latch(true)
    state.stop_fun.()
    attach_hud()

    reason
    |> Logic.start(%{attempts: attempts(state)}, baseline)
    |> advance(%{state | finished_at: nil})
  end

  defp advance({logic, action}, state), do: do_action(action, %{state | logic: logic})

  defp do_action(:press, state) do
    broadcast(state)
    # via mensagem, não direto: deixa o cast retornar antes de bloquear no Body
    send(self(), :press)
    {:noreply, state}
  end

  # Primeira leitura da tentativa espera a tela trocar; as seguintes vão no
  # ritmo curto. Só a primeira muda o estado visível, então só ela publica —
  # senão o painel receberia quatro mensagens idênticas por tentativa.
  defp do_action(:verify, state) do
    if state.logic.reads == 0 do
      broadcast(state)
      Process.send_after(self(), :read, Settings.get(:logout_verify_delay_ms))
    else
      Process.send_after(self(), :read, state.read_gap_ms)
    end

    {:noreply, state}
  end

  defp do_action({:finish, :out}, state) do
    Logger.info("Logout: deslogado — #{state.logic.reason}")
    {:noreply, finish(state)}
  end

  defp do_action({:finish, {:failed, motivo}}, state) do
    texto = "logout FALHOU (#{motivo}) — #{state.logic.reason}"
    Logger.warning("Logout: #{texto}")
    Phoenix.PubSub.broadcast(Pokex.PubSub, @combat_topic, {:rule_alarm, :logout, "🚪 " <> texto})
    {:noreply, finish(state)}
  end

  defp finish(state) do
    detach_hud()
    state = %{state | finished_at: System.monotonic_time(:millisecond)}
    broadcast(state)
    state
  end

  # UMA sequência atômica em :critical — nada se intercala entre o Ctrl+Q e o
  # Enter. O :ok daqui NÃO prova que a tecla chegou no jogo; quem prova é a tela.
  defp press_keys(state) do
    state.perform_fun.(
      [
        {:press, Settings.get(:logout_key)},
        {:wait, Settings.get(:logout_confirm_delay_ms)},
        {:press, Settings.get(:logout_confirm_key)}
      ],
      :critical
    )
  end

  defp in_flight?(%Logic{state: state}), do: state in [:pressing, :verifying]

  defp attempts(state), do: state.attempts_override || Settings.get(:logout_attempts)

  # O feed :hud já tem consumidor permanente (os alertas de estoque), mas pedir
  # a própria demanda deixa este módulo independente desse detalhe.
  defp attach_hud do
    Perception.attach(:hud)
  catch
    _kind, _reason -> :ok
  end

  defp detach_hud do
    Perception.detach(:hud)
  catch
    _kind, _reason -> :ok
  end

  defp snapshot(state) do
    logic = state.logic || %Logic{}

    %{
      state: logic.state,
      reason: logic.reason,
      attempt: logic.attempt,
      attempts: attempts(state),
      error: logic.error,
      finished_at: state.finished_at,
      duplicates: state.duplicates
    }
  end

  defp broadcast(state),
    do: Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:logout, snapshot(state)})
end
