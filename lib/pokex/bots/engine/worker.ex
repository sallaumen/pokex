defmodule Pokex.Bots.Engine.Worker do
  @moduledoc """
  The engine's eyes, and for now ONLY its eyes.

  Every 200ms it reads the blackboard, builds `Engine.Situation` and publishes
  it back as the `:situation` fact. It decides nothing, presses nothing, and
  moves nothing — the deciding half arrives in the next step, deliberately
  after a night of this one measuring.

  Two questions have to be answered with HIS data before any rule may lean on
  them, and neither is answerable from the journal as it stands today:

    * **How many monsters are actually there?** The count that is about to
      decide everything ("eu realmente mato quando tem uns três") is written
      nowhere. No line of any journal records it.
    * **Does his own pokémon occupy a row?** `interpret.ex:44` records a live
      reading saying it does NOT appear in the battle list; he says it is
      always the first row. The difference is ONE, and one is exactly the gap
      between attacking a pile and walking away from it.

  So this worker logs the count when it changes, with the names it read, and
  says out loud the first time it can tell whether his own pokémon is in there.

  ## Why it cannot hurt anything

    * No `Body`, no `Rig`, no captures of its own — it reads facts other feeds
      already publish, and ETS reads take no locks and block nobody.
    * No `GenServer.call` into any worker. Nothing waits on it, so it cannot
      wedge a hunt by being slow, and restarting it costs one tick.
    * It attaches the `:battle` and `:skill_bar` feeds because those are
      DEMAND-DRIVEN (`Perception.Feed`, "the feed only captures while at least
      one consumer is attached") — without attaching, the engine would be
      deciding over a picture nobody is painting whenever combat is idle.
    * While the fishing mini-game is on screen the feeds skip their captures on
      purpose, so every fact freezes. Publishing a picture built from frozen
      reads would be publishing a lie with a fresh timestamp — so it holds.
  """
  use GenServer

  alias Pokex.Bots.Combat
  alias Pokex.Bots.Engine.Situation
  alias Pokex.Perception
  alias Pokex.Perception.WorldState
  alias Pokex.Settings

  @topic "engine"
  @tick_ms 200

  def topic, do: @topic

  def start_link(opts \\ []) do
    state = %{
      active?: Keyword.get(opts, :active, Application.get_env(:pokex, :engine_active, true)),
      running?: false,
      timer: nil,
      picture: nil,
      # the pokémon on the field: its name is how the own row is told from an
      # enemy, its keys are what "cooldowns spent" means. Read on run and
      # refreshed on the event — never per tick, the team file is a disk read.
      loadout: nil
    }

    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, state)
      name -> GenServer.start_link(__MODULE__, state, name: name)
    end
  end

  @spec run(GenServer.server()) :: :ok
  def run(server \\ __MODULE__), do: GenServer.call(server, :run)

  @spec halt(GenServer.server()) :: :ok
  def halt(server \\ __MODULE__), do: GenServer.call(server, :halt)

  @spec status(GenServer.server()) :: map
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(state) do
    Phoenix.PubSub.subscribe(Pokex.PubSub, "combat")
    {:ok, state}
  end

  @impl true
  def handle_call(:run, _from, state) do
    attach()

    state = %{
      state
      | running?: true,
        picture: nil,
        loadout: Combat.Loadout.current()
    }

    log(:macro, "olhando a tela — contagem, vida e cooldowns viram um quadro só")
    {:reply, :ok, schedule_tick(state)}
  end

  def handle_call(:halt, _from, state) do
    detach()
    WorldState.forget(:situation)
    {:reply, :ok, %{cancel_timer(state) | running?: false, picture: nil}}
  end

  def handle_call(:status, _from, state) do
    {:reply, %{state: if(state.running?, do: :watching, else: :idle), picture: state.picture},
     state}
  end

  @impl true
  def handle_info(:tick, %{running?: false} = state), do: {:noreply, %{state | timer: nil}}

  def handle_info(:tick, state) do
    state =
      if Perception.mini_game_playing?(),
        do: state,
        else: observe(state)

    {:noreply, schedule_tick(state)}
  end

  # The team file changed under us: a swap changes both the name that identifies
  # the own row and the keys that "spent" is measured against.
  def handle_info({:team_changed}, state),
    do: {:noreply, %{state | loadout: Combat.Loadout.current()}}

  def handle_info(_msg, state), do: {:noreply, state}

  defp observe(state) do
    now = now()
    picture = Situation.build(inputs(state, now), config(), now)

    WorldState.put(:situation, picture, now)

    state
    |> narrate(picture)
    |> Map.put(:picture, picture)
    |> tap(&broadcast({:engine, &1.picture}))
  end

  defp inputs(state, now) do
    %{
      battle: battle(now),
      own_hp: own_hp(now),
      own_out?: own_out?(now),
      own_name: state.loadout && state.loadout.name,
      ready_keys: Perception.ready_skills(now),
      damage_keys: damage_keys(state.loadout),
      stun_at: nil,
      prev: state.picture
    }
  end

  defp config do
    %{
      engage_from: Settings.get(:engine_engage_from),
      stun_sleep_ms: Settings.get(:engine_stun_sleep_ms)
    }
  end

  defp battle(now) do
    case WorldState.get(:battle, Settings.get(:combat_world_max_age_ms), now) do
      {:ok, obs} -> obs
      _stale_or_missing -> nil
    end
  end

  defp own_hp(now) do
    case Perception.pokemon(now) do
      {:ok, %{hp_pct: hp}} -> hp
      _unknown -> nil
    end
  end

  defp own_out?(now) do
    match?({:ok, %{readable?: true}}, Perception.pokemon(now))
  end

  defp damage_keys(nil), do: []
  defp damage_keys(loadout), do: loadout.aoe ++ loadout.single

  # Speaking per tick would bury the fact it exists to surface — 200ms of
  # cadence is five lines a second. Only the EDGES talk.
  defp narrate(state, picture) do
    state
    |> narrate_count(picture)
    |> narrate_own_row(picture)
  end

  defp narrate_count(%{picture: %{enemies: same}} = state, %{enemies: same}), do: state

  defp narrate_count(state, %{enemies: nil}) do
    if state.picture && state.picture.enemies != nil,
      do: log(:macro, "perdi a lista de batalha — não sei quantos são")

    state
  end

  defp narrate_count(state, picture) do
    log(:macro, "#{picture.enemies} #{plural(picture.enemies)}#{named_as(picture)}")
    state
  end

  defp plural(1), do: "inimigo na tela"
  defp plural(_n), do: "inimigos na tela"

  defp named_as(%{named: []}), do: " (sem nomes — layout não localizado)"

  defp named_as(%{named: named}) do
    names =
      named
      |> Enum.map(&(&1.name || "?"))
      |> Enum.join(", ")

    " — " <> names
  end

  # THE MEASUREMENT. Said once, when it becomes knowable, and again only if it
  # ever changes its mind: whether his own pokémon takes a row in the list is
  # what decides if the ruler of three is measured against 3 rows or 4.
  defp narrate_own_row(%{picture: %{own_row_seen?: same}} = state, %{own_row_seen?: same}),
    do: state

  defp narrate_own_row(state, %{own_row_seen?: nil}), do: state

  defp narrate_own_row(state, %{own_row_seen?: seen?} = picture) do
    who = own_label(state)

    if seen? do
      log(:macro, "#{who} ocupa uma linha da lista — a contagem desconta ele")
    else
      log(:macro, "#{who} NÃO aparece na lista (#{picture.rows} linha(s), nenhuma é ele)")
    end

    state
  end

  defp own_label(%{loadout: nil}), do: "o pokémon em campo"
  defp own_label(%{loadout: loadout}), do: "o #{loadout.name}"

  defp attach do
    safe(fn -> Perception.attach(:battle) end)
    safe(fn -> Perception.attach(:skill_bar) end)
  end

  defp detach do
    safe(fn -> Perception.detach(:battle) end)
    safe(fn -> Perception.detach(:skill_bar) end)
  end

  # A feed that is down must never take the engine with it: it reads facts, and
  # a fact it cannot get is an unknown the picture already knows how to say.
  defp safe(fun) do
    fun.()
  catch
    _kind, _reason -> :ok
  end

  defp schedule_tick(%{active?: false} = state), do: state
  defp schedule_tick(%{running?: false} = state), do: state

  defp schedule_tick(state) do
    state = cancel_timer(state)
    %{state | timer: Process.send_after(self(), :tick, @tick_ms)}
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | timer: nil}
  end

  defp log(level, text), do: broadcast({:engine_log, level, "quadro: " <> text})

  defp broadcast(message), do: Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, message)

  defp now, do: System.monotonic_time(:millisecond)
end
