defmodule Pokex.Bots.Catcher.Worker do
  @moduledoc """
  Driver for the pure Catcher.Logic: consumes `:corpses` observations from the perception
  blackboard, throws confirmed Pokéballs through the Body (`:high`), and follows the capture
  mode LIVE — `parado` attaches the feed and acts; `movimento` detaches and idles (Lucas
  captures manually while moving). Combat's kill broadcast is only an accelerator: it forces
  an immediate world re-read; detection never depends on it.
  """
  use GenServer

  alias Pokex.Bots.Body
  alias Pokex.Bots.Catcher.Logic
  alias Pokex.Perception
  alias Pokex.Perception.WorldState
  alias Pokex.Settings

  @topic "catcher"
  @kill_topic "combat:kill"

  @config_keys [
    :corpse_match_tolerance_px,
    :corpse_max_balls,
    :corpse_ignore_ttl_ms,
    :corpse_confirm_after_ms,
    :feed_corpses_ms
  ]

  def topic, do: @topic
  def kill_topic, do: @kill_topic

  def start_link(opts \\ []) do
    body = Keyword.get(opts, :body, Body)

    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, body)
      name -> GenServer.start_link(__MODULE__, body, name: name)
    end
  end

  def run(server \\ __MODULE__), do: GenServer.call(server, :run)
  def halt(server \\ __MODULE__), do: GenServer.call(server, :halt)
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "The panel pokes this after flipping capture_mode — attach/detach applies live."
  def mode_changed(server \\ __MODULE__), do: GenServer.call(server, :mode_changed)

  @doc "Force a fresh ground warmup (detach + attach): use after moving to a new spot."
  def relearn(server \\ __MODULE__), do: GenServer.call(server, :relearn)

  @impl true
  def init(body) do
    Phoenix.PubSub.subscribe(Pokex.PubSub, @kill_topic)
    Phoenix.PubSub.subscribe(Pokex.PubSub, Perception.topic())
    {:ok, %{logic: nil, body: body, timer: nil, attached?: false}}
  end

  @impl true
  def handle_call(:run, _from, state) do
    {logic, _} = Logic.start(Logic.new(config()), now())
    state = sync_mode(%{state | logic: logic})
    broadcast(state)
    {:reply, :ok, state}
  end

  def handle_call(:halt, _from, %{logic: nil} = state), do: {:reply, :ok, state}

  def handle_call(:halt, _from, state) do
    {logic, _} = Logic.stop(state.logic)
    state = detach(%{state | logic: logic})
    broadcast(state)
    {:reply, :ok, cancel_timer(state)}
  end

  def handle_call(:status, _from, state), do: {:reply, snapshot(state), state}

  def handle_call(:mode_changed, _from, %{logic: nil} = state), do: {:reply, :ok, state}

  def handle_call(:mode_changed, _from, state) do
    state = sync_mode(state)
    broadcast(state)
    {:reply, :ok, state}
  end

  def handle_call(:relearn, _from, state) do
    state = state |> detach() |> sync_mode()
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:world, :corpses, obs}, %{logic: %Logic{state: :armed}} = state),
    do: {:noreply, advance(state, obs)}

  def handle_info({:world, _key, _obs}, state), do: {:noreply, state}

  def handle_info(:wake, %{logic: %Logic{state: :armed}} = state),
    do: {:noreply, advance(state, current_obs())}

  def handle_info(:wake, state), do: {:noreply, state}

  # kill = accelerator (both shapes: Task 5 drops the payload; tolerate the old one meanwhile)
  def handle_info({:kill}, %{logic: %Logic{state: :armed}} = state),
    do: {:noreply, advance(state, current_obs())}

  def handle_info({:kill, _corpse}, %{logic: %Logic{state: :armed}} = state),
    do: {:noreply, advance(state, current_obs())}

  def handle_info(_msg, state), do: {:noreply, state}

  # -- step pipeline -------------------------------------------------------------

  # The mode gate lives HERE, not only in attach/detach: a late in-flight {:world,...} event
  # (or a test-injected one) right after flipping to movimento must never throw a ball.
  defp advance(state, obs) do
    if Settings.get(:capture_mode) == "parado", do: do_advance(state, obs), else: state
  end

  defp do_advance(state, obs) do
    {logic, actions} = Logic.step(state.logic, obs, now())

    performs = Enum.filter(actions, &match?({:capture_sequence, _}, &1))
    if performs != [], do: Body.perform(performs, :high, state.body)

    for {:log, text} <- actions do
      Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:catcher_log, :macro, "captura: #{text}"})
    end

    if logic.counters != state.logic.counters or actions != [],
      do: broadcast(%{state | logic: logic})

    schedule_wake(%{state | logic: logic})
  end

  defp current_obs do
    case WorldState.get(:corpses, Settings.get(:catcher_world_max_age_ms), now()) do
      {:ok, obs} -> obs
      _stale_or_missing -> nil
    end
  end

  # parado + running → attached; movimento or halted → detached.
  defp sync_mode(state) do
    case {Settings.get(:capture_mode), state.logic} do
      {"parado", %Logic{state: :armed}} -> attach(state)
      {_mode, _logic} -> cancel_timer(detach(state))
    end
  end

  defp attach(%{attached?: true} = state), do: state

  defp attach(state) do
    safe(fn -> Perception.attach(:corpses) end)
    %{state | attached?: true}
  end

  defp detach(%{attached?: false} = state), do: state

  defp detach(state) do
    safe(fn -> Perception.detach(:corpses) end)
    %{state | attached?: false}
  end

  defp safe(fun) do
    fun.()
  catch
    :exit, _reason -> :ok
  end

  defp schedule_wake(state) do
    state = cancel_timer(state)

    case Logic.next_wake(state.logic, now()) do
      nil -> state
      ms -> %{state | timer: Process.send_after(self(), :wake, ms)}
    end
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | timer: nil}
  end

  defp config, do: Settings.all() |> Map.take(@config_keys)

  defp mode_state(nil, _mode), do: :idle
  defp mode_state(_logic, "movimento"), do: :manual
  defp mode_state(%Logic{state: s}, _mode), do: s

  defp snapshot(state) do
    mode = Settings.get(:capture_mode)

    %{
      state: mode_state(state.logic, mode),
      mode: mode,
      counters: (state.logic && state.logic.counters) || %Logic{}.counters,
      error: state.logic && state.logic.error
    }
  end

  defp broadcast(state),
    do: Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:catcher, snapshot(state)})

  defp now, do: System.monotonic_time(:millisecond)
end
