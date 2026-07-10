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
    {:ok, %{spec: spec, consumers: %{}, timer: nil, last_obs: nil, failures: 0}}
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
        if was_idle?, do: reschedule(state, 0), else: state
      end

    {:reply, :ok, state}
  end

  def handle_call({:detach, pid}, _from, state), do: {:reply, :ok, drop_consumer(state, pid)}

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state),
    do: {:noreply, drop_consumer(state, pid)}

  def handle_info(:tick, %{consumers: consumers} = state) when consumers == %{},
    do: {:noreply, %{state | timer: nil}}

  def handle_info(:tick, state) do
    state = state |> observe() |> reschedule(Settings.get(state.spec.interval_setting))
    {:noreply, state}
  end

  defp observe(state) do
    with {:ok, calib} <- Calibration.load(),
         region = state.spec.region.(calib),
         {:ok, frame} <- Capture.frame(region, state.spec.filename) do
      at = now()

      obs =
        frame
        |> state.spec.interpret.(calib, Settings.all())
        |> Map.put(:captured_at, at)

      WorldState.put(state.spec.key, obs, at)

      if changed?(state.last_obs, obs),
        do: Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:world, state.spec.key, obs})

      %{state | last_obs: obs}
    else
      error ->
        Logger.debug("feed #{state.spec.key} tick failed: #{inspect(error)}")
        %{state | failures: state.failures + 1}
    end
  catch
    kind, reason ->
      Logger.debug("feed #{state.spec.key} crashed a tick: #{inspect({kind, reason})}")
      %{state | failures: state.failures + 1}
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
    %{state | timer: Process.send_after(self(), :tick, max(delay_ms || 100, 10))}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
