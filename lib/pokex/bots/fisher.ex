defmodule Pokex.Bots.Fisher do
  @moduledoc """
  Driver GenServer around the pure Logic: gathers observations, executes
  actions through the Rig, schedules ticks, broadcasts snapshots on PubSub.
  """
  use GenServer
  require Logger

  alias Pokex.Bots.Fisher.{Config, Logic, Sensors}
  alias Pokex.{Calibration, Preflight, Rig, Settings}

  @topic "fisher"

  def topic, do: @topic

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def start_bot(server \\ __MODULE__), do: GenServer.call(server, :start_bot)
  def start_combat(server \\ __MODULE__), do: GenServer.call(server, :start_combat)
  def stop_bot(server \\ __MODULE__), do: GenServer.call(server, :stop_bot)
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(_opts), do: {:ok, %{logic: nil, calib: nil, timer: nil}}

  @impl true
  def handle_call(:start_bot, _from, state), do: begin(state, &Logic.start/2)
  def handle_call(:start_combat, _from, state), do: begin(state, &Logic.start_combat/2)

  def handle_call(:stop_bot, _from, %{logic: nil} = state), do: {:reply, :ok, state}

  def handle_call(:stop_bot, _from, state) do
    {logic, _actions} = Logic.stop(state.logic)
    broadcast(logic)
    {:reply, :ok, %{cancel_timer(state) | logic: logic}}
  end

  def handle_call(:status, _from, state), do: {:reply, snapshot(state.logic), state}

  # Shared preflight → load → build → start; differs only by the Logic starter.
  defp begin(state, start_fun) do
    with :ok <- Preflight.run(),
         {:ok, calib} <- Calibration.load() do
      config = Config.build(calib, Settings.all())
      {logic, actions} = start_fun.(Logic.new(config), now())
      execute_all(actions, config.humanize_max_ms)
      broadcast(logic)
      {:reply, :ok, %{state | logic: logic, calib: calib} |> reschedule(0)}
    else
      {:error, messages} when is_list(messages) -> {:reply, {:error, messages}, state}
      {:error, other} -> {:reply, {:error, ["calibração ilegível: #{inspect(other)}"]}, state}
    end
  end

  @impl true
  def handle_info(:tick, %{logic: nil} = state), do: {:noreply, state}

  def handle_info(:tick, %{logic: %Logic{state: s}} = state) when s in [:idle, :error],
    do: {:noreply, state}

  def handle_info(:tick, state) do
    previous = state.logic

    {logic, actions} =
      case Sensors.impl().observe(Logic.needs(previous), state.calib, Settings.all()) do
        {:ok, observations} ->
          {stepped, actions} = Logic.step(previous, observations, now())

          case execute_all(actions, previous.config.humanize_max_ms) do
            :ok -> {stepped, actions}
            {:error, reason} -> {elem(Logic.io_failed(stepped, inspect(reason), now()), 0), []}
          end

        {:error, reason} ->
          {elem(Logic.io_failed(previous, inspect(reason), now()), 0), []}
      end

    broadcast_activity(logic, actions)
    if logic.state != previous.state or logic.counters != previous.counters, do: broadcast(logic)

    state = %{state | logic: logic}

    if logic.state in [:idle, :error] do
      {:noreply, cancel_timer(state)}
    else
      {:noreply, reschedule(state, Logic.tick_interval(logic))}
    end
  end

  defp execute_all(actions, max_ms) do
    Enum.reduce_while(actions, :ok, fn action, :ok ->
      humanize(action, max_ms)

      case execute(action) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # A random 0–max ms pause before each real input, so the cadence looks human
  # instead of a metronome. Polling ticks emit no actions (only :log/empty), so
  # this never slows glow detection — only presses/clicks are humanized.
  defp humanize({:log, _}, _max), do: :ok

  defp humanize(_action, max) when is_integer(max) and max > 0,
    do: Process.sleep(:rand.uniform(max + 1) - 1)

  defp humanize(_action, _max), do: :ok

  defp execute({:press, key}), do: Rig.impl().press(key)
  defp execute({:click, button, point}), do: Rig.impl().click(button, point)
  defp execute({:capture_sequence, point}), do: Rig.impl().capture_sequence(point)

  defp execute({:log, message}) do
    Logger.info("fisher: #{message}")
    :ok
  end

  defp broadcast(logic),
    do: Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:fisher, snapshot(logic)})

  # A live, human-readable trace of what the bot is doing and WHERE it clicks —
  # so a click landing on the map (walking) instead of the Battle tab is obvious.
  defp broadcast_activity(logic, actions) do
    case describe_activity(logic, actions) do
      nil -> :ok
      text -> Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:fisher_log, text})
    end
  end

  defp describe_activity(logic, actions) do
    acts = actions |> Enum.map(&describe_action/1) |> Enum.reject(&is_nil/1) |> Enum.join(" · ")

    case {state_desc(logic), acts} do
      {nil, ""} -> nil
      {nil, a} -> a
      {s, ""} -> s
      {s, a} -> "#{s} → #{a}"
    end
  end

  defp state_desc(%Logic{
         state: :fighting,
         targeted?: false,
         pending_verify?: true,
         select_idx: i
       }),
       do: "luta: linha #{i} travou?"

  defp state_desc(%Logic{state: :fighting, targeted?: false, select_idx: i}),
    do: "luta: mirando linha #{i}"

  defp state_desc(%Logic{state: :fighting, targeted?: true}), do: "luta: atacando"
  defp state_desc(%Logic{state: :looting}), do: "coletando loot"
  defp state_desc(%Logic{state: :capturing}), do: "capturando"
  defp state_desc(_), do: nil

  defp describe_action({:press, key}), do: "tecla #{key}"
  defp describe_action({:click, :left, {x, y}}), do: "clique esq (#{x},#{y})"
  defp describe_action({:click, :right, {x, y}}), do: "clique dir (#{x},#{y})"
  defp describe_action({:capture_sequence, {x, y}}), do: "pokébola (#{x},#{y})"
  defp describe_action({:log, msg}), do: msg

  defp snapshot(nil), do: %{state: :idle, counters: %Logic{}.counters, error: nil}
  defp snapshot(logic), do: %{state: logic.state, counters: logic.counters, error: logic.error}

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
