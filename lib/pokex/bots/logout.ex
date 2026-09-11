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

  The witness is the CHARACTER's own health bar (`player_hp_region` of the
  calibration), read straight off the screen: in the world it is a bar, on the
  character-select screen the same pixels are whatever the client draws there.
  It used to be the `:hud` WorldState fact (level, food and fishing numbers of
  the bottom bar) — a PXG region. On Poké Alliance that feed never captured
  again after 24/08, so every logout since read `:unreadable` and ended as
  "logout FALHOU (ilegivel)" — six of six in the diary of 10-11/09, with the
  character actually out of the game each time (he watched the one of 12:40 of
  11/09). Read directly, never through a feed: the bots and their feeds'
  consumers are already stopped when this runs.

  When the character-select screen becomes a calibrated region, `read_fun`
  switches from a NEGATIVE check ("the bar vanished") to a POSITIVE one ("I see
  the character list"). The `:gone | :present | :unreadable` contract stays.
  """
  use GenServer
  require Logger

  alias Pokex.Bots.{Body, BotSupervisor, Capture, Focus, InputGate}
  alias Pokex.Bots.Logout.Logic
  alias Pokex.{Calibration, Settings, Vision}

  @topic "logout"
  @combat_topic "combat"
  # Gap between reads AFTER the first (the first waits logout_verify_delay_ms,
  # the screen-switch time).
  @read_gap_ms 400

  def topic, do: @topic

  @doc """
  Portuguese wording of a failure reason. The reason atoms are internal, but the
  alarm and the panel print them to Lucas — this is the boundary where they turn
  back into the words he already knows.
  """
  def failure_text(:no_witness), do: "sem_testemunha"
  def failure_text(:still_logged_in), do: "ainda_logado"
  def failure_text(:unreadable), do: "ilegivel"
  def failure_text(other), do: to_string(other)

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    state = %{
      # Same pattern as :shiny_guard_active — the app instance never acts
      # during the suite; test instances opt in.
      active?: Keyword.get(opts, :active, Application.get_env(:pokex, :logout_active, true)),
      perform_fun: Keyword.get(opts, :perform_fun, &Body.perform(&1, &2)),
      stop_fun: Keyword.get(opts, :stop_fun, fn -> BotSupervisor.stop_all("deslogando") end),
      front_fun: Keyword.get(opts, :front_fun, &Focus.ensure_front/0),
      read_fun: Keyword.get(opts, :read_fun, &__MODULE__.read_witness/0),
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

  @doc """
  The default screen reading: the character's own health bar, captured now.

  `:present` — a plausible bar (the same judge the support uses on it every
  tick); `:gone` — a frame that is not a bar (the character-select screen, or a
  window over the corner); `:unreadable` — no calibrated region, or the capture
  itself failed. Injectable for tests; the app passes nothing.
  """
  @spec read_witness(({integer, integer, integer, integer}, String.t() -> term), term) ::
          Logic.reading()
  def read_witness(capture \\ &Capture.frame/2, calib \\ Calibration.load()) do
    with {:ok, %Calibration{player_hp_region: {_, _, _, _} = region}} <- calib,
         {:ok, %Vision.Frame{} = frame} <- capture.(region, "logout_witness.raw") do
      if Vision.hp_region_plausible?(frame, hp_opts()), do: :present, else: :gone
    else
      _no_region_or_no_frame -> :unreadable
    end
  catch
    _kind, _reason -> :unreadable
  end

  defp hp_opts do
    [
      min_brightness: Settings.get(:pokemon_hp_min_brightness),
      min_saturation: Settings.get(:pokemon_hp_min_saturation),
      min_known_pct: Settings.get(:pokemon_hp_min_known_pct),
      min_bright_pct: Settings.get(:pokemon_hp_min_bright_pct),
      max_track_brightness: Settings.get(:pokemon_hp_max_track_brightness)
    ]
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
    # The WITNESS, read before touching anything: if the character's bar isn't
    # readable NOW, it won't be later either, and a "vanished" would prove
    # nothing. A region that is not marked, or a window already over the
    # corner, reads as no bar for "logged out" as well as for "nothing
    # happened". Without this differential measure a missing calibration would
    # swear a logout happened without any working key press.
    baseline = state.read_fun.()

    if baseline != :present do
      Logger.warning(
        "Logout: a barra de vida do personagem já estava ilegível ANTES de apertar (#{baseline}) — " <>
          "vou tentar mesmo assim, mas não vou conseguir confirmar"
      )
    end

    InputGate.set_panic_latch(true)
    state.stop_fun.()

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

  defp do_action({:finish, {:failed, reason}}, state) do
    text = "logout FALHOU (#{failure_text(reason)}) — #{state.logic.reason}"
    Logger.warning("Logout: #{text}")
    Phoenix.PubSub.broadcast(Pokex.PubSub, @combat_topic, {:rule_alarm, :logout, "🚪 " <> text})
    {:noreply, finish(state)}
  end

  defp finish(state) do
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
