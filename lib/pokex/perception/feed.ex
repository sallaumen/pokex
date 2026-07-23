defmodule Pokex.Perception.Feed do
  @moduledoc """
  One perception stream: capture its region on its cadence, interpret the frame with a pure
  function, write the observation into the WorldState, and broadcast on the "world" topic
  when the observation CHANGED.

  DEMAND-DRIVEN: the feed only captures while at least one consumer is attached — otherwise
  the blackboard would RAISE broker load instead of lowering it. Consumers are monitored, so
  a crashed consumer can never leave a feed running for nobody.

  Uncrashable on I/O: a failed capture/interpret keeps the last good entry (the staleness
  gate in WorldState.get protects readers) and the loop keeps ticking. Calibration is
  re-read on every capture so recalibrating applies live, and a missing calibration just
  counts as a failed tick.
  """
  use GenServer
  require Logger

  alias Pokex.Bots.Capture
  alias Pokex.Perception.WorldState
  alias Pokex.{Calibration, Settings}

  @topic "world"

  def topic, do: @topic

  def start_link(opts) do
    spec = Keyword.fetch!(opts, :spec)

    case Keyword.get(opts, :name, :default) do
      nil -> GenServer.start_link(__MODULE__, spec)
      :default -> GenServer.start_link(__MODULE__, spec, name: name(spec.key))
      name -> GenServer.start_link(__MODULE__, spec, name: name)
    end
  end

  def name(key), do: :"#{__MODULE__}.#{key}"

  def attach(server, consumer \\ self()), do: GenServer.call(server, {:attach, consumer})
  def detach(server, consumer \\ self()), do: GenServer.call(server, {:detach, consumer})

  @impl true
  def init(spec) do
    {:ok,
     %{spec: spec, consumers: %{}, timer: nil, last_obs: nil, failures: 0, interp_state: nil}}
  end

  @impl true
  def handle_call({:attach, pid}, _from, state) do
    state =
      if Map.has_key?(state.consumers, pid) do
        state
      else
        ref = Process.monitor(pid)
        was_idle? = state.consumers == %{}
        state = %{state | consumers: Map.put(state.consumers, pid, ref)}
        if was_idle?, do: reschedule(%{state | interp_state: nil, last_obs: nil}, 0), else: state
      end

    {:reply, :ok, state}
  end

  def handle_call({:detach, pid}, _from, state), do: {:reply, :ok, drop_consumer(state, pid)}

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state),
    do: {:noreply, drop_consumer(state, pid)}

  def handle_info(:tick, %{consumers: consumers} = state) when consumers == %{},
    do: {:noreply, %{state | timer: nil}}

  # While the fishing mini-game is being played, the ONE serialized capture broker
  # belongs to the game's strip captures (every ~80ms). Everything that acts is
  # frozen, so NOTHING reads this feed's fact meanwhile — capturing here only
  # queues ahead of the strip and starves it (measured 2026-07-23: the game's
  # capture cadence blew out from 80ms to ~250ms sitting behind ~6 feed/support
  # captures per 250ms). Skip the capture, keep the timer alive, resume the
  # instant the overlay clears. The fact going stale for those seconds is fine:
  # the staleness gate covers it and a resuming consumer relearns from scratch.
  def handle_info(:tick, state) do
    state =
      if Pokex.Perception.mini_game_playing?(),
        do: state,
        else: observe(state)

    {:noreply, reschedule(state, Settings.get(state.spec.interval_setting))}
  end

  defp observe(state) do
    with {:ok, calib} <- Calibration.load(),
         {:region, region} when not is_nil(region) <- {:region, state.spec.region.(calib)},
         {:ok, frame} <- Capture.frame(region, state.spec.filename) do
      at = now()

      {obs_body, interp_state} = run_interpret(state, frame, calib)

      obs = Map.put(obs_body, :captured_at, at)

      WorldState.put(state.spec.key, obs, at)

      if changed?(state.last_obs, obs),
        do: Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:world, state.spec.key, obs})

      %{state | last_obs: obs, interp_state: interp_state, failures: 0}
    else
      # no region yet: the layout has not been located (or this feed's panel is
      # gone). Holding is correct — reading a guessed rect would feed lies.
      {:region, nil} -> state
      error -> tick_failed(state, error)
    end
  catch
    kind, reason -> tick_failed(state, {kind, reason})
  end

  # A failed capture keeps the last good WorldState entry (the staleness gate in
  # WorldState.get protects readers) and the loop keeps ticking. Per-tick noise stays at
  # :debug, but a STREAK of consecutive failures (permission revoked mid-run, a region gone
  # bad, ...) is exactly the kind of thing that must NOT stay silent — escalate loudly the
  # instant the streak reaches the configured threshold. Resetting to 0 on the next success
  # (in observe/1 above) means a warning fires again if failures resume later.
  defp tick_failed(state, error) do
    failures = state.failures + 1
    threshold = Settings.get(:feed_failure_warn_streak)

    if failures == threshold do
      Logger.warning(
        "feed #{state.spec.key}: #{failures} capturas seguidas falharam — última: #{inspect(error)}"
      )

      # a capture-failure streak is what a moved/closed panel looks like from
      # here — the sentinel decides whether the HUD needs re-locating
      Pokex.Layout.Sentinel.suspect(state.spec.key)
    else
      Logger.debug("feed #{state.spec.key} tick failed: #{inspect(error)}")
    end

    %{state | failures: failures}
  end

  # Same content, different timestamp → not a change. Everything else → broadcast.
  defp changed?(nil, _obs), do: true

  defp changed?(last, obs),
    do: Map.delete(last, :captured_at) != Map.delete(obs, :captured_at)

  defp drop_consumer(state, pid) do
    case Map.pop(state.consumers, pid) do
      {nil, _} ->
        state

      {ref, consumers} ->
        Process.demonitor(ref, [:flush])
        %{state | consumers: consumers}
    end
  end

  defp reschedule(state, delay_ms) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :tick, max(delay_ms, 10))}
  end

  # Interpreters come in two shapes: pure (arity 3) and stateful (arity 4 — e.g. the corpse
  # detector's warmup baseline). State lives here in the feed and resets whenever the feed
  # resumes from idle, so every fresh attachment relearns from scratch.
  defp run_interpret(state, frame, calib) do
    settings = Settings.all()

    case Function.info(state.spec.interpret, :arity) do
      {:arity, 4} -> state.spec.interpret.(frame, calib, settings, state.interp_state)
      {:arity, 3} -> {state.spec.interpret.(frame, calib, settings), state.interp_state}
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
