defmodule Pokex.Bots.Focus do
  @moduledoc """
  Ties actuation to the game window having focus. Polls the frontmost macOS app on a timer and,
  the instant the game is NOT frontmost, closes the `InputGate` (so no key/click can leak into
  whatever stole focus) AND halts the automated workers; when the game is frontmost again it
  reopens the gate and resumes whatever was running before.

  This is the safety net for the overnight failure mode: a menu/dialog opened by itself, the
  game lost focus, the old "re-front then fire" guard could not re-front it, and the bot typed
  hundreds of stray keystrokes into random windows. Here the model is fail-safe — unfocused
  means DON'T ACT, no attempt to force focus back.

  The frontmost reader is injected (`:frontmost_fun`, default: an osascript one-liner) so it is
  trivially testable. Auto-start is gated by `:focus_auto_monitor` (false in test) so the poll
  never shells out during unrelated tests. `pause_when_unfocused` (a setting) is the live
  master switch: off → the gate stays open and workers are never touched.
  """
  use GenServer
  require Logger

  alias Pokex.Bots.{BotSupervisor, InputGate}
  alias Pokex.Settings

  @topic "focus"

  def topic, do: @topic

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    state = %{
      frontmost_fun: Keyword.get(opts, :frontmost_fun, &default_frontmost/0),
      # A pausa é um HOLD com identidade: para a frota e devolve a geração da
      # ordem — que fica guardada em resume_generation.
      hold_fun: Keyword.get(opts, :hold_fun, &BotSupervisor.hold_for_focus/0),
      start_all: Keyword.get(opts, :start_all, &BotSupervisor.start_all/0),
      running_fun: Keyword.get(opts, :running_fun, &default_running?/0),
      generation_fun: Keyword.get(opts, :generation_fun, &Pokex.Bots.Session.generation/0),
      poll_ms: Keyword.get(opts, :poll_ms, nil),
      # tests inject their own frontmost reader, so they opt into polling explicitly rather than
      # via the env gate that keeps the app-wide instance quiet during unrelated tests.
      auto_start: Keyword.get(opts, :auto_start, nil),
      focused?: true,
      # A geração da MINHA pausa, ou nil (nada pra retomar). Um booleano aqui já
      # religou a frota por cima de um Stop manual dado entre a perda e a volta
      # do foco — a ordem dele não tinha como invalidar a retomada pendente.
      # Agora tem: qualquer ordem posterior muda a geração, e a retomada só vale
      # se a geração atual ainda for a da pausa.
      resume_generation: nil
    }

    case name do
      nil -> GenServer.start_link(__MODULE__, state)
      name -> GenServer.start_link(__MODULE__, state, name: name)
    end
  end

  @doc "Current focus verdict + whether pausing is enabled — for the panel."
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(state) do
    start? =
      case state.auto_start do
        nil -> Application.get_env(:pokex, :focus_auto_monitor, true)
        override -> override
      end

    if start?, do: {:ok, schedule(state, 0)}, else: {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state),
    do: {:reply, %{focused?: state.focused?, enabled?: enabled?()}, state}

  @impl true
  def handle_info(:poll, state) do
    state =
      if enabled?() do
        evaluate(state)
      else
        # Master switch off: never hold input for focus. Leave the gate open and forget any
        # pending resume so flipping the switch on later starts from a clean slate.
        InputGate.set_focus_ok(true)
        %{state | focused?: true, resume_generation: nil}
      end

    {:noreply, schedule(state, Settings.get(:focus_poll_ms))}
  end

  # An uncrashable poll: a flaky osascript read must not take the safety monitor down. On an
  # unreadable frontmost, HOLD the last verdict (don't flap the gate on a transient error).
  defp evaluate(state) do
    case read_frontmost(state) do
      {:ok, frontmost} -> apply_focus(state, game?(frontmost))
      :error -> state
    end
  end

  defp apply_focus(%{focused?: true} = state, false) do
    # focus just LOST → shut the gate, halt the workers, remember to resume them.
    # A lembrança carrega a GERAÇÃO da pausa: só uma frota que estava rodando
    # merece retomada, e só se nenhuma ordem chegar no meio.
    InputGate.set_focus_ok(false)
    running? = safe_running?(state)
    generation = safe_hold(state)
    broadcast(false)
    Logger.info("focus lost — input suppressed and workers halted")
    %{state | focused?: false, resume_generation: if(running?, do: generation)}
  end

  defp apply_focus(%{focused?: false} = state, true) do
    # focus just REGAINED → open the gate, resume what was running — se a retomada
    # ainda VALE. Duas coisas a invalidam, e as duas vêm de incidente real:
    #
    #   * o latch do pânico (2026-07-11): retomar por cima do mouse-no-canto
    #     matou o Pokémon do Lucas. O latch continua aqui como cinto E
    #     suspensório, mesmo o pânico também mudando a geração;
    #   * QUALQUER ordem entre a perda e a volta do foco (Frente 1): um Stop
    #     manual do painel, um logout, um freio do cavebot — todos mudam a
    #     geração, e a retomada só religa a geração da PRÓPRIA pausa. Antes,
    #     um booleano esquecia a ordem do humano e religava por cima.
    #
    # A retomada inválida é DESCARTADA, nunca adiada.
    resume? =
      state.resume_generation != nil and
        safe_generation(state) == state.resume_generation and
        not InputGate.panic_latched?()

    InputGate.set_focus_ok(true)
    if resume?, do: safe_resume(state)
    broadcast(true)

    Logger.info(
      "focus regained — input allowed" <> if(resume?, do: " and workers resumed", else: "")
    )

    %{state | focused?: true, resume_generation: nil}
  end

  # steady state (no edge): keep the gate consistent with the verdict, nothing else.
  defp apply_focus(state, focused?) do
    InputGate.set_focus_ok(focused?)
    state
  end

  defp read_frontmost(state) do
    state.frontmost_fun.()
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp safe_running?(state) do
    state.running_fun.()
  catch
    _kind, _reason -> false
  end

  # A pausa nunca pode falhar em PARAR por causa da geração — se o hold quebrar
  # no meio, devolve nil e a retomada simplesmente não existe (o lado seguro).
  defp safe_hold(state) do
    state.hold_fun.()
  catch
    _kind, _reason -> nil
  end

  # Geração ilegível → retomada descartada (compara contra :unavailable, que
  # nunca é igual a uma geração guardada). Falhar pro lado de NÃO religar.
  defp safe_generation(state) do
    state.generation_fun.()
  catch
    _kind, _reason -> :unavailable
  end

  defp safe_resume(state) do
    state.start_all.()
  catch
    _kind, _reason -> :ok
  end

  defp game?(frontmost) when is_binary(frontmost),
    do: String.downcase(frontmost) == String.downcase(Settings.get(:game_app_name))

  defp game?(_frontmost), do: false

  defp enabled?, do: Settings.get(:pause_when_unfocused) == true

  defp broadcast(focused?),
    do: Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:focus, %{focused?: focused?}})

  # `state.poll_ms` (injected) overrides the cadence in tests; otherwise use the caller's delay
  # (0 for the first poll, the setting thereafter).
  defp schedule(state, delay_ms) do
    ms = state.poll_ms || delay_ms || 250
    Process.send_after(self(), :poll, max(ms, 20))
    state
  end

  @doc """
  Bring the GAME to the front NOW (System Events), for deliberate flows that
  must act while something else holds focus — the emergency escape is the
  first: its click/keys would be swallowed by the Rig's focus gate otherwise
  (Lucas, live 2026-07-20: "quando ta fora do foco no jogo nao vai").
  Env-gated off in tests (`:front_game_cmd`) so suites never shell out.
  """
  def front_game do
    if Application.get_env(:pokex, :front_game_cmd, true) do
      app = Settings.get(:game_app_name)

      System.cmd(
        "osascript",
        [
          "-e",
          ~s(tell application "System Events" to set frontmost of application process "#{app}" to true)
        ],
        stderr_to_stdout: true
      )
    end

    :ok
  rescue
    _oascript_unavailable -> :ok
  end

  @doc """
  Garante que o jogo pode receber uma sequência DELIBERADA de teclas: recusa se
  o canto do pânico está acionado (a ordem humana vence tudo), passa direto se o
  jogo já está na frente, e senão traz o jogo para a frente e abre a porteira
  na hora.

  Abrir a porteira aqui, em vez de esperar o poller notar, é o ponto: o poller
  levaria um tick, e nesse meio-tempo o Rig engoliria a tecla EM SILÊNCIO. Se o
  fronting falhar de verdade, o poller fecha a porteira de volta no tick
  seguinte e o Rig volta a engolir — a rede de segurança continua valendo.
  """
  @spec ensure_front() :: :ok | {:error, :panic_corner}
  def ensure_front do
    cond do
      not InputGate.state().corner_ok ->
        {:error, :panic_corner}

      InputGate.state().focus_ok ->
        :ok

      true ->
        front_game()
        Process.sleep(Settings.get(:calibration_front_delay_ms))
        InputGate.set_focus_ok(true)
        :ok
    end
  end

  # Frontmost process name via System Events. `{:ok, name}` or `:error` (unreadable → hold).
  defp default_frontmost do
    case System.cmd(
           "osascript",
           [
             "-e",
             ~s(tell application "System Events" to name of first application process whose frontmost is true)
           ],
           stderr_to_stdout: true
         ) do
      {out, 0} -> {:ok, String.trim(out)}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp default_running? do
    %{fishing: f, combat: c, catcher: cat, cavebot: cv} = BotSupervisor.status()
    active?(f) or active?(c) or active?(cat) or active?(cv)
  catch
    _kind, _reason -> false
  end

  defp active?(%{state: state}), do: state not in [:idle, :error, :manual, nil]
  defp active?(_), do: false
end
