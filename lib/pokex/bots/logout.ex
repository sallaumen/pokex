defmodule Pokex.Bots.Logout do
  @moduledoc """
  Actually ends the game session: Ctrl+Q, Enter, then CHECKS THE SCREEN.

  Exists because stopping the bot saves no stamina — stamina burns while the
  character is online. A whole night on the main account was lost with the
  mini-game stuck: the bot kept hooking, produced zero fish, and nothing had
  the authority to end the session.

  Its own process because the press → wait → check → retry cycle takes seconds
  and the caller (`Guardian`) must keep checking the panic corner every 100ms —
  blocking it would leave the corner deaf that long.

  Checking the screen is not luxury: with the `InputGate` closed,
  `Rig.Mac.gated/1` swallows the key and returns `:ok` — on purpose, so no
  worker confuses "held for safety" with "failed" (exactly how the cavebot died
  believing it had walked). A logout trusting the Body's `:ok` would report
  logged out while stamina burns all night. The screen is the only honest
  witness.

  The reading comes from the `:hud` WorldState fact: logged out = level, food
  AND fishing stop yielding numbers at the same time. A STALE fact returns
  `:unreadable`, never `:gone` — reading `World.snapshot()` would be wrong
  here, since it returns nil in all three fields both for "empty screen" and
  for "the feed stopped", and that confusion would invent a logout.

  When the character-select screen becomes a calibrated region, `read_fun`
  switches from a NEGATIVE check ("the HUD vanished") to a POSITIVE one ("I see
  the character list"). The `:gone | :present | :unreadable` contract stays.
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
  # The :hud feed publishes every 250-500ms; two seconds means "stopped arriving".
  @hud_max_age_ms 2_000
  # Gap between reads AFTER the first (the first waits logout_verify_delay_ms,
  # the screen-switch time).
  @read_gap_ms 400

  def topic, do: @topic

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    state = %{
      # Same pattern as :shiny_guard_active — the app instance never acts
      # during the suite; test instances opt in.
      active?: Keyword.get(opts, :active, Application.get_env(:pokex, :logout_active, true)),
      perform_fun: Keyword.get(opts, :perform_fun, &Body.perform(&1, &2)),
      stop_fun: Keyword.get(opts, :stop_fun, fn -> BotSupervisor.stop_all("deslogando") end),
      front_fun: Keyword.get(opts, :front_fun, &Focus.ensure_front/0),
      read_fun: Keyword.get(opts, :read_fun, &__MODULE__.read_hud/0),
      # Override attempt count and read cadence. Test-only: without them a
      # failure case would wait three ~3s cycles. Deliberately NOT panel
      # settings — there is nothing for the user to decide here.
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
  Requests a logout. Async on purpose: the caller (`Guardian`) must not block.
  Idempotent — a request with another in flight is ignored and counted in
  `duplicates`, which matters because the `Guardian` re-evaluates every 100ms.
  """
  @spec request(String.t(), GenServer.server()) :: :ok
  def request(reason, server \\ __MODULE__), do: GenServer.cast(server, {:request, reason})

  @doc "The snapshot the panel draws."
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc false
  # Default screen reading. Public to serve as the default `read_fun`.
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

  # LATCH FIRST, stop second: the latch forbids every auto-resume path (Focus's
  # refocus resume) from re-arming workers over this order. It STAYS set after
  # a successful logout — only Iniciar bot clears it.
  defp begin(state, reason) do
    # The WITNESS, read before touching anything: if the bottom bar isn't
    # readable NOW, it won't be later either, and a "vanished" would prove
    # nothing. The HUD returns nil in all three fields for "logged out" as well
    # as "sub-region uncalibrated" or "atlas missing a digit" — the missing "9"
    # is a real case. Without this differential measure, an incomplete atlas
    # would swear a logout happened without any working key press.
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
    # via message, not directly: lets the cast return before blocking on the Body
    send(self(), :press)
    {:noreply, state}
  end

  # The attempt's first read waits for the screen to switch; later ones go at
  # the short cadence. Only the first changes visible state, so only it
  # publishes — else the panel would get four identical messages per attempt.
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

  # ONE atomic sequence at :critical — nothing interleaves between Ctrl+Q and
  # Enter. Its :ok does NOT prove the key reached the game; the screen does.
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

  # The :hud feed already has a permanent consumer (stock alerts), but stating
  # our own demand keeps this module independent of that detail.
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
