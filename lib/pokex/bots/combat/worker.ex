defmodule Pokex.Bots.Combat.Worker do
  @moduledoc """
  Driver GenServer around the pure Combat.Logic: senses the battle panel,
  steps the state machine, and submits every resulting action list to the
  shared Body at `:high` priority (combat preempts fishing). Broadcasts
  snapshots on PubSub. Does NOT check the panic corner (the Guardian owns
  that) and does NOT touch fishing.
  """
  use GenServer
  require Logger

  alias Pokex.Bots.Combat.Logic
  alias Pokex.Bots.Fisher.{Config, Sensors}
  alias Pokex.Bots.Body
  alias Pokex.{Calibration, Preflight, Settings}

  @topic "combat"

  def topic, do: @topic

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
  def init(body), do: {:ok, %{logic: nil, calib: nil, body: body, timer: nil}}

  @impl true
  def handle_call(:run, _from, state) do
    with :ok <- Preflight.run(),
         {:ok, calib} <- Calibration.load() do
      config = Config.build(calib, Settings.all())
      {logic, actions} = Logic.start(Logic.new(config), now())
      submit(state.body, actions)
      broadcast(logic)
      {:reply, :ok, %{state | logic: logic, calib: calib} |> reschedule(0)}
    else
      {:error, messages} when is_list(messages) -> {:reply, {:error, messages}, state}
      {:error, other} -> {:reply, {:error, ["calibração ilegível: #{inspect(other)}"]}, state}
    end
  end

  def handle_call(:halt, _from, %{logic: nil} = state), do: {:reply, :ok, state}

  def handle_call(:halt, _from, state) do
    {logic, _actions} = Logic.stop(state.logic)
    broadcast(logic)
    {:reply, :ok, %{cancel_timer(state) | logic: logic}}
  end

  def handle_call(:status, _from, state), do: {:reply, snapshot(state.logic), state}

  @impl true
  def handle_info(:tick, %{logic: nil} = state), do: {:noreply, state}

  def handle_info(:tick, %{logic: %Logic{state: s}} = state) when s in [:idle, :error],
    do: {:noreply, state}

  def handle_info(:tick, state) do
    previous = state.logic

    # In a post-action pause there's nothing to sense — skip the capture (and
    # the panic corner, which is the Guardian's concern here, not ours) and
    # just wait out the pause.
    if Logic.waiting?(previous, now()) do
      {:noreply, reschedule(state, Logic.tick_interval(previous))}
    else
      run_tick(state, previous)
    end
  end

  defp run_tick(state, previous) do
    settings = Settings.all()

    {logic, actions, obs} =
      case Sensors.impl().observe(Logic.needs(previous), state.calib, settings) do
        {:ok, observations} ->
          {stepped, actions} = Logic.step(previous, observations, now())

          logic =
            case submit(state.body, actions) do
              :ok -> stepped
              {:error, reason} -> elem(Logic.io_failed(stepped, inspect(reason), now()), 0)
            end

          {logic, actions, observations}

        {:error, reason} ->
          {elem(Logic.io_failed(previous, inspect(reason), now()), 0), [], %{}}
      end

    broadcast_activity(previous, obs, actions)
    if logic.state != previous.state or logic.counters != previous.counters, do: broadcast(logic)

    state = %{state | logic: logic}

    if logic.state in [:idle, :error] do
      {:noreply, cancel_timer(state)}
    else
      {:noreply, reschedule(state, Logic.tick_interval(logic))}
    end
  end

  # Every action list is one atomic Body.perform at :high — combat preempts
  # fishing, and the whole sequence (e.g. select click + move-off) runs
  # without an interleaved fishing action splitting it.
  defp submit([], _body), do: :ok
  defp submit(body, actions), do: Body.perform(actions, :high, body)

  defp broadcast(logic),
    do: Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:combat, snapshot(logic)})

  defp broadcast_activity(logic, obs, actions) do
    case describe_activity(logic, obs, actions) do
      nil -> :ok
      text -> Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:combat_log, text})
    end
  end

  defp describe_activity(logic, obs, actions) do
    acts = actions |> Enum.map(&describe_action/1) |> Enum.reject(&is_nil/1) |> Enum.join(" · ")

    case {state_desc(logic, obs), acts} do
      {nil, ""} -> nil
      {nil, a} -> a
      {s, ""} -> s
      {s, a} -> "#{s} → #{a}"
    end
  end

  defp state_desc(
         %Logic{state: :scanning, targeted?: false, pending_verify?: true, select_idx: i} =
           logic,
         obs
       ),
       do:
         "combate: linha #{i} travou? #{Enum.at(Map.get(obs, :battle_lock, []), i, 0)}px (limiar #{logic.config.target_locked_min_pixels})"

  defp state_desc(%Logic{state: :scanning, targeted?: false, select_idx: i}, _obs),
    do: "combate: mirando linha #{i}"

  defp state_desc(%Logic{state: :fighting, targeted?: true, locked_row: row} = logic, obs),
    do:
      "combate: atacando linha #{row} — #{Enum.at(Map.get(obs, :battle_lock, []), row, 0)}px (mín #{logic.config.target_locked_min_pixels})"

  defp state_desc(%Logic{state: :walking_to_loot, walk_plan: plan}, _obs),
    do: "andando até o loot (#{length(plan)} passos restantes)"

  defp state_desc(%Logic{state: :looting}, _obs), do: "coletando loot (espaço)"

  defp state_desc(%Logic{state: :walking_back, walk_plan: plan}, _obs),
    do: "voltando ao ponto de combate (#{length(plan)} passos restantes)"

  defp state_desc(%Logic{state: :capturing}, _obs), do: "capturando"

  defp state_desc(_, _obs), do: nil

  defp describe_action({:press, key}), do: "tecla #{key}"
  defp describe_action({:click, :left, {x, y}}), do: "clique esq (#{x},#{y})"
  defp describe_action({:click, :right, {x, y}}), do: "clique dir (#{x},#{y})"
  defp describe_action({:move, {x, y}}), do: "mover mouse (#{x},#{y})"
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
