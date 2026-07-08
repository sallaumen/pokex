defmodule Pokex.Bots.Loot.Worker do
  @moduledoc """
  Driver GenServer around the pure `Loot.Logic`. Idle until combat announces a kill on
  `"combat:kill"` — then it walks to the corpse, loots, captures, and walks back to the
  fishing spot, submitting every action to the shared `Body` at `:high` (foreground with
  combat; both are quick, spaced actions, so neither starves the other).

  ONE corpse at a time: a kill that arrives while a cycle is running is DROPPED (the recorded
  corpse point is only valid while the character is at the fishing spot, which it is exactly
  when loot is idle). Loot never senses the battle — it walks by dead-reckoning — so it takes
  no screenshots; the Guardian owns the panic corner and halts a walk in progress via stop_all.
  """
  use GenServer
  require Logger

  alias Pokex.Bots.Loot.Logic
  alias Pokex.Bots.Fisher.Config
  alias Pokex.Bots.Body
  alias Pokex.{Calibration, Settings}

  @topic "loot"
  def topic, do: @topic

  # Combat announces a kill here (fire-and-forget, one-way), carrying the corpse's floating-
  # name screen point (or nil when unknown).
  @kill_topic "combat:kill"
  def kill_topic, do: @kill_topic

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    body = Keyword.get(opts, :body, Body)

    case name do
      nil -> GenServer.start_link(__MODULE__, body)
      name -> GenServer.start_link(__MODULE__, body, name: name)
    end
  end

  def run(server \\ __MODULE__), do: GenServer.call(server, :run)
  def halt(server \\ __MODULE__), do: GenServer.call(server, :halt)
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(body) do
    Phoenix.PubSub.subscribe(Pokex.PubSub, @kill_topic)
    {:ok, %{logic: nil, calib: nil, body: body, timer: nil, running?: false}}
  end

  @impl true
  def handle_call(:run, _from, state) do
    case Calibration.load() do
      {:ok, calib} ->
        config = Config.build(calib, Settings.all())
        new_state = %{state | logic: Logic.new(config), calib: calib, running?: true}
        broadcast(new_state)
        {:reply, :ok, new_state}

      {:error, other} ->
        {:reply, {:error, ["calibração ilegível: #{inspect(other)}"]}, state}
    end
  end

  def handle_call(:halt, _from, %{logic: nil} = state),
    do: {:reply, :ok, %{state | running?: false}}

  def handle_call(:halt, _from, state) do
    {logic, _} = Logic.stop(state.logic)
    new_state = %{cancel_timer(state) | logic: logic, running?: false}
    broadcast(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call(:status, _from, state), do: {:reply, snapshot(state), state}

  # Not running yet → ignore kills.
  @impl true
  def handle_info({:kill, _corpse}, %{logic: nil} = state), do: {:noreply, state}

  def handle_info({:kill, corpse}, state) do
    if Logic.busy?(state.logic) do
      # already looting a corpse → drop this one (its recorded point is stale once we moved).
      {:noreply, state}
    else
      {logic, actions} = Logic.start(state.logic, corpse, now())
      logic = submit_step(state.body, logic, actions)
      new_state = %{state | logic: logic}
      broadcast(new_state)
      {:noreply, reschedule(new_state, 0)}
    end
  end

  def handle_info(:tick, %{logic: nil} = state), do: {:noreply, state}

  def handle_info(:tick, %{logic: %Logic{state: s}} = state) when s in [:idle, :error],
    do: {:noreply, cancel_timer(state)}

  def handle_info(:tick, state) do
    previous = state.logic

    if Logic.waiting?(previous, now()) do
      {:noreply, reschedule(state, Logic.tick_interval(previous))}
    else
      {stepped, actions} = Logic.step(previous, %{}, now())
      logic = submit_step(state.body, stepped, actions)
      state = %{state | logic: logic}

      if logic.state != previous.state or logic.counters != previous.counters,
        do: broadcast(state)

      if Logic.busy?(logic),
        do: {:noreply, reschedule(state, Logic.tick_interval(logic))},
        else: {:noreply, cancel_timer(state)}
    end
  end

  # Submit the actions and, on a Body I/O error, drive Logic.io_failed (recover into idle,
  # bump failures; stop into :error past max_consecutive_failures).
  defp submit_step(body, logic, actions) do
    case submit(body, actions) do
      :ok -> logic
      {:error, reason} -> elem(Logic.io_failed(logic, inspect(reason), now()), 0)
    end
  end

  # Combat preempts by being :high too — loot's arrow presses are quick and spaced, so the
  # two interleave without starving each other. No actions → skip the Body entirely.
  defp submit(_body, []), do: :ok
  defp submit(body, actions), do: Body.perform(actions, :high, body)

  defp broadcast(state),
    do: Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:loot, snapshot(state)})

  # Display state for the panel: :off (not started), :ready (armed by Start, idle, waiting for a
  # kill), or the live loot state (:walking_to_loot/:looting/:capturing/:walking_back) while a
  # corpse is handled. `run` sets running? so :ready is distinguishable from a stopped :off.
  defp snapshot(%{logic: nil}), do: %{state: :off, counters: %Logic{}.counters, error: nil}

  defp snapshot(%{logic: logic, running?: running?}) do
    state =
      cond do
        Logic.busy?(logic) -> logic.state
        running? -> :ready
        true -> :off
      end

    %{state: state, counters: logic.counters, error: logic.error}
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp reschedule(state, delay_ms) do
    state = cancel_timer(state)
    %{state | timer: Process.send_after(self(), :tick, delay_ms)}
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | timer: nil}
  end
end
