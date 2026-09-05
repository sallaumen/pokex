defmodule Pokex.Bots.Timers.Worker do
  @moduledoc """
  Fires the scheduled actions: the aura a few seconds into a mob stretch, the berry every so
  many minutes.

  Idle until `run/1`, like every other worker: nothing presses a key because a clock ran while
  the fleet is stopped.

  ## Where the mob clock comes from

  Nowhere new. The hunt already publishes `:posture` on the blackboard every tick, and
  `:hold_fire` IS "gathering right now", so this worker watches that fact and stamps the moment
  it turned on. No message, no coupling, and it inherits the ageing for free: a hunt that dies
  stops refreshing the fact, the posture reads `:free_fight`, and the mob clock clears itself.

  ## Why the press goes through the Body

  Unlike combat, which owns its own direct keyboard path because it presses on every battle
  frame, a timer fires rarely and has no reason to cut in front of a cast or a step. The Body
  serialises it with everything else, and its InputGate is what keeps a berry from being typed
  into a browser when the game is not frontmost.

  `Body.perform/2` is an `:infinity` call, so it is dispatched OFF the tick: a press queued
  behind a long sequence would otherwise stall this worker's clock and, with it, every other
  timer.
  """
  use GenServer
  require Logger

  alias Pokex.Bots.Body
  alias Pokex.Bots.Combat.Loadout
  alias Pokex.Perception.WorldState
  alias Pokex.Pokedex.Team
  alias Pokex.Settings
  alias Pokex.Timers
  alias Pokex.Timers.{Schedule, Store}

  @topic "timers"

  def topic, do: @topic

  def start_link(opts \\ []) do
    state = %{
      body: Keyword.get(opts, :body, Body),
      active?: Keyword.get(opts, :active, Application.get_env(:pokex, :timers_active, true))
    }

    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, state)
      name -> GenServer.start_link(__MODULE__, state, name: name)
    end
  end

  def run(server \\ __MODULE__), do: GenServer.call(server, :run)
  def halt(server \\ __MODULE__), do: GenServer.call(server, :halt)

  @doc """
  What the page shows: every timer with how long until it goes off.

  `remaining` is nil for one that is not counting — disabled, or waiting on a
  mob stretch that is not happening.
  """
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "Runs one tick right now. Tests drive the clock instead of waiting for it."
  def tick(server \\ __MODULE__), do: GenServer.call(server, :tick)

  @impl true
  def init(state) do
    Phoenix.PubSub.subscribe(Pokex.PubSub, Team.topic())

    {:ok,
     Map.merge(state, %{
       running?: false,
       timer_ref: nil,
       started_at: nil,
       mob_at: nil,
       last_fired: %{},
       timers: [],
       loadout: nil
     })}
  end

  @impl true
  def handle_call(:run, _from, state) do
    now = now()

    state = %{
      state
      | running?: true,
        started_at: now,
        # a new run is a new session: yesterday's stamps would make a 55-minute
        # berry fire on the first tick
        last_fired: %{},
        mob_at: nil,
        timers: Store.all(),
        loadout: Loadout.current()
    }

    {:reply, :ok, schedule(state)}
  end

  def handle_call(:halt, _from, state) do
    {:reply, :ok, %{cancel(state) | running?: false, mob_at: nil}}
  end

  def handle_call(:status, _from, state) do
    clocks = clocks(state, now())

    rows =
      Enum.map(state.timers, fn timer ->
        %{
          timer: timer,
          remaining: Schedule.remaining(timer, clocks),
          keys: Timers.keys_for(timer, state.loadout),
          last_fired: Map.get(state.last_fired, timer.id)
        }
      end)

    {:reply, %{running?: state.running?, timers: rows, loadout: state.loadout}, state}
  end

  def handle_call(:tick, _from, state), do: {:reply, :ok, run_tick(state)}

  @impl true
  def handle_info(:tick, state), do: {:noreply, state |> run_tick() |> schedule()}

  # He re-classified a skill or swapped the pokémon on the field: a timer that
  # presses "the aura" has to mean the new one's aura from now on.
  def handle_info({:team_changed}, state), do: {:noreply, %{state | loadout: Loadout.current()}}

  def handle_info({:timers_changed}, state), do: {:noreply, %{state | timers: Store.all()}}

  def handle_info(_other, state), do: {:noreply, state}

  # -- the tick ---------------------------------------------------------------

  defp run_tick(%{running?: false} = state), do: state

  defp run_tick(state) do
    now = now()
    state = watch_mob(state, now)

    state.timers
    |> Schedule.due(clocks(state, now))
    |> Enum.reduce(state, &fire(&2, &1, now))
  end

  # The EDGE into holding fire is "começou a mobar". Reading it as a fact means
  # a dead hunt clears the clock on its own (the fact ages out and reads as
  # free fire) instead of leaving an aura armed forever.
  defp watch_mob(state, now) do
    case {mobbing?(now), state.mob_at} do
      {true, nil} -> %{state | mob_at: now}
      {false, at} when at != nil -> %{state | mob_at: nil}
      _unchanged -> state
    end
  end

  defp mobbing?(now) do
    case WorldState.get(:posture, Settings.get(:posture_max_age_ms), now) do
      {:ok, %{posture: :hold_fire}} -> true
      _free_stale_or_missing -> false
    end
  end

  # Stamped BEFORE the press is confirmed — see Schedule.fired/3. A timer with
  # nothing to press does not fire at all and keeps its clock, so classifying
  # the aura later makes it start working without touching the timer.
  defp fire(state, timer, now) do
    case Timers.keys_for(timer, state.loadout) do
      [] ->
        state

      keys ->
        dispatch(state, keys)
        log(timer, keys)
        %{state | last_fired: Schedule.fired(state.last_fired, timer, now)}
    end
  end

  # OFF the tick: Body.perform is a call with :infinity, and a press queued
  # behind a long sequence would stall every other timer's clock with it.
  defp dispatch(%{body: body}, keys) do
    actions = Enum.map(keys, &{:press, &1})

    Task.start(fn ->
      Body.perform(actions, :normal, body)
    end)
  end

  defp log(timer, keys) do
    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      @topic,
      {:timer_fired, timer.id, "⏱ #{timer.name}: #{Enum.join(keys, ", ")}"}
    )
  end

  defp clocks(state, now) do
    %{
      now: now,
      started_at: state.started_at || now,
      mob_at: state.mob_at,
      last_fired: state.last_fired
    }
  end

  defp schedule(%{active?: false} = state), do: state

  defp schedule(state) do
    state = cancel(state)

    %{
      state
      | timer_ref: Process.send_after(self(), :tick, Settings.get(:timers_tick_ms) || 1_000)
    }
  end

  defp cancel(%{timer_ref: nil} = state), do: state

  defp cancel(state) do
    Process.cancel_timer(state.timer_ref)
    %{state | timer_ref: nil}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
