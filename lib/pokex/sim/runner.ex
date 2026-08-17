defmodule Pokex.Sim.Runner do
  @moduledoc """
  The only process the simulator has: it gives the fake world a clock.

  Every tick it advances `Pokex.Sim.World` by the time that REALLY passed and
  writes the facts onto the same blackboard the real feeds write to. From there
  the fleet is unchanged — `Engine.Worker`, `Cavebot.Worker`, `Combat.Worker`
  and `PlayerSupport.Worker` read exactly what they read today, at exactly the
  cadence they read it.

  ## The clock is real, the world is not

  The world advances by `now - last_at`, never by the nominal tick. The fleet
  measures fact ages against `System.monotonic_time`, so a world that walked
  50ms while the machine walked 80 would hand the engine a `stable_for_ms` made
  of fiction — and that number is the one deciding whether a pile is worth
  fighting.

  ## Each fact keeps its own cadence

  `:battle` every 120ms, `:skill_bar` every 400ms, `:minimap` every 500ms — the
  same numbers the real feeds use, read from `Settings`. Publishing everything
  each tick would erase the most interesting problem the bot has: facts of
  different ages, arriving out of step.

  `:mini_game` is published on purpose as `playing?: false`. Without it,
  `Perception.mini_game_playing?/1` finds no fact and the engine stops deciding,
  believing the fishing capsule is on screen.

  ## It is registered under its own name for a reason

  `Pokex.Rig.Sim` reports every key to whatever is registered as
  `Pokex.Sim.Runner`. That name IS the wiring between the fleet's hands and this
  world.
  """
  use GenServer

  require Logger

  alias Pokex.Bots.Cavebot.Route
  alias Pokex.Perception.WorldState
  alias Pokex.Settings
  alias Pokex.Sim.World

  @topic "sim"
  @tick_ms 50

  @fallback_cadences %{
    battle: 120,
    pokemon: 120,
    skill_bar: 400,
    minimap: 500,
    mini_game: 1_000
  }

  def topic, do: @topic

  def start_link(opts \\ []) do
    state = %{
      world: nil,
      playing?: false,
      timer: nil,
      tick_ms: Keyword.get(opts, :tick_ms, @tick_ms),
      clock: Keyword.get(opts, :clock, &monotonic_ms/0),
      last_at: nil,
      published: %{},
      cadences: cadences(),
      route: Keyword.get(opts, :route),
      seed: Keyword.get(opts, :seed, 42),
      knobs: Keyword.get(opts, :knobs, %{}),
      loadout: Keyword.get(opts, :loadout)
    }

    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, state)
      name -> GenServer.start_link(__MODULE__, state, name: name)
    end
  end

  @doc """
  Replaces the world with a fresh one on `route`.

  Two arities and no default on the server, deliberately. Written as
  `load(server \\\\ __MODULE__, route, opts \\\\ [])` it compiles, and then a
  two-argument call binds the ROUTE to `server` — which reaches
  `GenServer.whereis/1` as a struct and takes the caller down. Defaults on both
  sides of a required argument are a trap, not a convenience; this one cost a
  crashed LiveView on the first click.
  """
  @spec load(Route.t(), keyword) :: :ok
  def load(route, opts) when is_struct(route, Route),
    do: GenServer.call(__MODULE__, {:load, route, opts})

  @spec load(GenServer.server(), Route.t(), keyword) :: :ok
  def load(server, route, opts) when is_struct(route, Route),
    do: GenServer.call(server, {:load, route, opts})

  @spec play(GenServer.server()) :: :ok
  def play(server \\ __MODULE__), do: GenServer.call(server, :play)

  @spec pause(GenServer.server()) :: :ok
  def pause(server \\ __MODULE__), do: GenServer.call(server, :pause)

  @spec playing?(GenServer.server()) :: boolean
  def playing?(server \\ __MODULE__), do: GenServer.call(server, :playing?)

  @doc "The world right now — what the screen draws."
  @spec world(GenServer.server()) :: World.t() | nil
  def world(server \\ __MODULE__), do: GenServer.call(server, :world)

  @doc """
  Runs one tick synchronously.

  Exists so a test can advance the simulation by asking instead of by waiting:
  a suite that sleeps for cadences is a suite that goes red on a busy laptop.
  """
  @spec tick_now(GenServer.server()) :: :ok
  def tick_now(server \\ __MODULE__), do: GenServer.call(server, :tick_now)

  @impl true
  def init(state) do
    {:ok, load_world(state, state.route, seed: state.seed)}
  end

  @impl true
  def handle_call({:load, route, opts}, _from, state) do
    {:reply, :ok, load_world(state, route, opts)}
  end

  def handle_call(:play, _from, state) do
    {:reply, :ok, schedule(%{state | playing?: true, last_at: state.clock.()})}
  end

  def handle_call(:pause, _from, state) do
    {:reply, :ok, cancel(%{state | playing?: false})}
  end

  def handle_call(:playing?, _from, state), do: {:reply, state.playing?, state}
  def handle_call(:world, _from, state), do: {:reply, state.world, state}
  def handle_call(:tick_now, _from, state), do: {:reply, :ok, advance(state)}

  @impl true
  def handle_info(:tick, %{playing?: false} = state), do: {:noreply, %{state | timer: nil}}

  def handle_info(:tick, state), do: {:noreply, state |> advance() |> schedule()}

  # The fleet's hands, arriving from Pokex.Rig.Sim. A key the world does not
  # model is dropped by World.press/2 rather than crashing the only process the
  # simulator has.
  def handle_info({:sim_rig, _action}, %{world: nil} = state), do: {:noreply, state}

  def handle_info({:sim_rig, action}, state),
    do: {:noreply, %{state | world: World.press(state.world, action)}}

  def handle_info(_ignored, state), do: {:noreply, state}

  defp load_world(state, nil, _opts), do: %{state | world: nil}

  defp load_world(state, route, opts) do
    world =
      World.new(route,
        seed: Keyword.get(opts, :seed, state.seed),
        knobs: Keyword.get(opts, :knobs, state.knobs),
        loadout: Keyword.get(opts, :loadout, state.loadout)
      )

    %{state | world: world, published: %{}, last_at: state.clock.(), route: route}
  end

  defp advance(%{world: nil} = state), do: state
  defp advance(%{playing?: false} = state), do: state

  defp advance(state) do
    now = state.clock.()
    elapsed = max(now - (state.last_at || now), 0)
    world = World.step(state.world, elapsed)

    state = publish(%{state | world: world, last_at: now}, now)
    Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:sim, world})
    state
  end

  defp publish(state, now) do
    published =
      Enum.reduce(state.cadences, state.published, fn {key, every_ms}, acc ->
        if due?(acc, key, now, every_ms) do
          WorldState.put(key, World.observe(state.world, key), now)
          Map.put(acc, key, now)
        else
          acc
        end
      end)

    publish_hunt(state.world, now)
    %{state | published: published}
  end

  # The engine answers "sem caçada rodando" to a missing `:hunt` and decides
  # nothing — correct in the real game (no cavebot, nothing to decide about) and
  # useless here, where the simulation IS the hunt. So the runner publishes the
  # fact the cavebot publishes (`cavebot/worker.ex:414`), in its shape: standing
  # on a nest is `:fighting`, which is what makes the ruler run; walking between
  # them is `:walking`.
  #
  # It says `luring?: false` on purpose. The gathering leg is a cavebot decision
  # about a recorded route, and claiming it here would put words in its mouth.
  defp publish_hunt(world, now) do
    WorldState.put(
      :hunt,
      %{
        state: if(on_nest?(world), do: :fighting, else: :walking),
        luring?: false,
        gathering?: false,
        wp_index: 0,
        waypoints: length(world.route.waypoints),
        recovering?: false
      },
      now
    )
  end

  defp on_nest?(world) do
    Enum.any?(world.mobs, fn mob -> World.reachable?(mob, world) end)
  end

  defp due?(published, key, now, every_ms) do
    case Map.get(published, key) do
      nil -> true
      at -> now - at >= every_ms
    end
  end

  defp schedule(state) do
    %{cancel(state) | timer: Process.send_after(self(), :tick, state.tick_ms)}
  end

  defp cancel(%{timer: nil} = state), do: state

  defp cancel(state) do
    Process.cancel_timer(state.timer)
    %{state | timer: nil}
  end

  # The cadences are HIS, read from the same settings the real feeds use. A
  # Settings server that is not up (a bare unit test) falls back to the numbers
  # those settings ship with, rather than inventing a rhythm.
  defp cadences do
    %{
      battle: setting(:feed_battle_ms, :battle),
      pokemon: setting(:feed_battle_ms, :pokemon),
      skill_bar: setting(:feed_skill_bar_ms, :skill_bar),
      minimap: setting(:feed_minimap_ms, :minimap),
      mini_game: @fallback_cadences.mini_game
    }
  end

  defp setting(name, key) do
    Settings.get(name) || @fallback_cadences[key]
  catch
    :exit, _no_settings_server -> @fallback_cadences[key]
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
