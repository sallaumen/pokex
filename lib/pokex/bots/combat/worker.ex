defmodule Pokex.Bots.Combat.Worker do
  @moduledoc """
  Event-driven driver around the pure Tab-targeting Combat.Logic. Consumes battle
  observations from the perception blackboard ("world" PubSub + WorldState), presses Tab
  and skill bursts through the DIRECT keyboard path (never the Body, never the mouse — the
  select-click died with the click-targeting flow), and broadcasts snapshots/kills exactly
  like before. The Guardian owns the panic corner; this worker reads no cursor.

  A fallback timer wakes the logic for its time-based deadlines (tab confirm window, fight
  timeout, hunt hold) even when the battle picture isn't changing — Logic.next_wake says
  when.
  """
  use GenServer
  require Logger

  alias Pokex.Bots.Combat.Logic
  alias Pokex.Bots.MiniGame
  alias Pokex.Perception
  alias Pokex.Perception.WorldState
  alias Pokex.{Preflight, Settings}

  @topic "combat"
  @catch_topic "fishing:caught"

  @config_keys [
    :tab_confirm_ms,
    :tab_max_attempts,
    :hunt_cooldown_ms,
    :skill_burst_every_ms,
    :fight_timeout_ms,
    :target_lost_streak,
    :skill_keys,
    :combat_skill_burst_size,
    :max_consecutive_failures
  ]

  def topic, do: @topic
  def catch_topic, do: @catch_topic

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, :ok)
      name -> GenServer.start_link(__MODULE__, :ok, name: name)
    end
  end

  def run(server \\ __MODULE__), do: GenServer.call(server, :run)
  def halt(server \\ __MODULE__), do: GenServer.call(server, :halt)
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(:ok) do
    Phoenix.PubSub.subscribe(Pokex.PubSub, @catch_topic)
    Phoenix.PubSub.subscribe(Pokex.PubSub, Perception.topic())
    {:ok, %{logic: nil, timer: nil, arena_attached?: false}}
  end

  @impl true
  def handle_call(:run, _from, state) do
    case Preflight.run() do
      :ok ->
        config = Settings.all() |> Map.take(@config_keys)
        {logic, _actions} = Logic.start(Logic.new(config), now())
        Perception.attach(:battle)
        broadcast(logic)
        # step immediately against whatever the world already knows
        {:reply, :ok, advance(%{state | logic: logic}, current_obs())}

      {:error, messages} when is_list(messages) ->
        {:reply, {:error, messages}, state}

      {:error, other} ->
        {:reply, {:error, [inspect(other)]}, state}
    end
  end

  def handle_call(:halt, _from, %{logic: nil} = state), do: {:reply, :ok, state}

  def handle_call(:halt, _from, state) do
    {logic, _} = Logic.stop(state.logic)
    Perception.detach(:battle)
    state = detach_arena(%{state | logic: logic})
    broadcast(logic)
    {:reply, :ok, cancel_timer(state)}
  end

  def handle_call(:status, _from, state), do: {:reply, snapshot(state.logic), state}

  @impl true
  def handle_info({:world, :battle, obs}, %{logic: %Logic{}} = state),
    do: {:noreply, advance(state, obs)}

  def handle_info({:world, _key, _obs}, state), do: {:noreply, state}

  def handle_info(:wake, %{logic: %Logic{}} = state),
    do: {:noreply, advance(state, current_obs())}

  def handle_info(:wake, state), do: {:noreply, state}

  def handle_info({:fish_caught}, %{logic: %Logic{}} = state) do
    {:noreply, advance(%{state | logic: Logic.rescan(state.logic, now())}, current_obs())}
  end

  def handle_info({:fish_caught}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  # -- the step pipeline -------------------------------------------------------

  defp advance(%{logic: %Logic{state: s}} = state, _obs) when s in [:idle, :error],
    do: cancel_timer(state)

  defp advance(state, obs) do
    previous = state.logic
    {logic, actions} = Logic.step(previous, obs, now())

    dispatch(actions)
    broadcast_activity(logic, actions)

    if logic.state != previous.state or logic.counters != previous.counters,
      do: broadcast(logic)

    if logic.counters.fights > previous.counters.fights,
      do: broadcast_kill(corpse())

    state = sync_arena(%{state | logic: logic})
    schedule_wake(state)
  end

  # Tab + skills are keys → the direct fire-and-forget path (a key must never wait behind a
  # mouse sequence holding the Body). Logs are broadcast, not typed.
  defp dispatch(actions) do
    keys =
      Enum.flat_map(actions, fn
        {:tab} -> [Settings.get(:tab_key)]
        {:press, key} -> [key]
        {:log, _} -> []
      end)

    if keys != [], do: spawn(fn -> tap_keys(keys) end)
    :ok
  end

  defp tap_keys(keys) do
    opts = [
      tap_count: Settings.get(:combat_skill_tap_count) |> positive_int(1),
      gap_ms: Settings.get(:combat_skill_gap_ms) |> non_neg_int(0),
      jitter_ms: Settings.get(:combat_skill_jitter_ms) |> non_neg_int(0)
    ]

    with :ok <- MiniGame.Worker.guard_before_input(),
         :ok <- Pokex.Rig.impl().press_many(keys, opts),
         :ok <- MiniGame.Worker.guard_after_input() do
      :ok
    else
      {:blocked, :mini_game_active} -> :ok
      {:error, reason} -> Logger.debug("combat key burst failed: #{inspect(reason)}")
    end
  catch
    kind, reason -> Logger.debug("combat key burst crashed: #{inspect({kind, reason})}")
  end

  # The freshest battle picture, or nil (stale/missing → Logic acts time-only, fail-safe).
  defp current_obs do
    case WorldState.get(:battle, Settings.get(:combat_world_max_age_ms), now()) do
      {:ok, obs} -> obs
      _stale_or_missing -> nil
    end
  end

  # The corpse point for loot: the arena feed's last hostile, if reasonably fresh.
  defp corpse do
    case WorldState.get(:arena, Settings.get(:feed_arena_ms) * 5, now()) do
      {:ok, %{hostile: point}} -> point
      _stale_or_missing -> nil
    end
  end

  # The arena feed (corpse position) only needs to run while fighting.
  defp sync_arena(%{logic: %Logic{state: :fighting}, arena_attached?: false} = state) do
    Perception.attach(:arena)
    %{state | arena_attached?: true}
  end

  defp sync_arena(%{logic: %Logic{state: s}, arena_attached?: true} = state)
       when s != :fighting,
       do: detach_arena(state)

  defp sync_arena(state), do: state

  defp detach_arena(%{arena_attached?: true} = state) do
    Perception.detach(:arena)
    %{state | arena_attached?: false}
  end

  defp detach_arena(state), do: state

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

  # -- broadcasts ---------------------------------------------------------------

  defp broadcast(logic),
    do: Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:combat, snapshot(logic)})

  defp broadcast_kill(corpse),
    do:
      Phoenix.PubSub.broadcast(
        Pokex.PubSub,
        Pokex.Bots.Loot.Worker.kill_topic(),
        {:kill, corpse}
      )

  defp broadcast_activity(logic, actions) do
    texts = for {:log, msg} <- actions, do: msg

    if texts != [] do
      level = if logic.state == :fighting or logic.counters.fights > 0, do: :macro, else: :debug

      Enum.each(texts, fn text ->
        Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:combat_log, level, "combate: #{text}"})
      end)
    end
  end

  defp snapshot(nil),
    do: %{state: :idle, counters: %Logic{}.counters, error: nil, locked_row: nil}

  defp snapshot(logic),
    do: %{
      state: logic.state,
      counters: logic.counters,
      error: logic.error,
      locked_row: logic.locked_row
    }

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, default), do: default

  defp non_neg_int(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_neg_int(_value, default), do: default

  defp now, do: System.monotonic_time(:millisecond)
end
