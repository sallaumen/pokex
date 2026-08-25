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
  alias Pokex.Bots.Combat.Strategy
  alias Pokex.Bots.Engine.Logic
  alias Pokex.Bots.Engine.Situation
  alias Pokex.Engine.Events
  alias Pokex.Engine.Vitals
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
      logic: Logic.new(),
      orders: nil,
      # the pokémon on the field: its name is how the own row is told from an
      # enemy, its keys are what "cooldowns spent" means. Read on run and
      # refreshed on the event — never per tick, the team file is a disk read.
      loadout: nil,
      # the last VITALS line written, so the next one can be written on a change
      # instead of on a clock alone
      vitals: nil
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
        orders: nil,
        logic: Logic.new(),
        loadout: Combat.Loadout.current()
    }

    log(:macro, "olhando a tela — contagem, vida e cooldowns viram um quadro só")
    {:reply, :ok, schedule_tick(state)}
  end

  def handle_call(:halt, _from, state) do
    detach()
    WorldState.forget(:situation)
    WorldState.forget(:orders)
    {:reply, :ok, %{cancel_timer(state) | running?: false, picture: nil, orders: nil}}
  end

  def handle_call(:status, _from, state) do
    snapshot = %{
      state: if(state.running?, do: :watching, else: :idle),
      picture: state.picture,
      orders: state.orders
    }

    {:reply, snapshot, state}
  end

  @impl true
  def handle_info(:tick, %{running?: false} = state), do: {:noreply, %{state | timer: nil}}

  # No mini-game branch here on purpose: the engine is the HUNT's brain and the
  # fishing capsule cannot appear over a rod nobody is holding. The gate lives
  # once, in `Perception.mini_game_playing?/1`, which answers false outside the
  # fishing mode — so a hunt tick has nothing to ask.
  def handle_info(:tick, state), do: {:noreply, state |> observe() |> schedule_tick()}

  # The team file changed under us: a swap changes both the name that identifies
  # the own row and the keys that "spent" is measured against.
  def handle_info({:team_changed}, state),
    do: {:noreply, %{state | loadout: Combat.Loadout.current()}}

  def handle_info(_msg, state), do: {:noreply, state}

  defp observe(state) do
    now = now()
    picture = Situation.build(inputs(state, now), config(), now)

    WorldState.put(:situation, picture, now)

    {logic, orders} =
      Logic.step(
        state.logic,
        %{situation: picture, hunt: hunt(now), hands: hands(state.loadout)},
        decision_config(),
        now
      )

    # ORDERS TRAVEL AS A FACT, never as a message — the whole reason a central
    # engine is allowed to exist here. Facts carry their age, so an engine that
    # dies simply stops refreshing this one and every worker falls back to what
    # it does today. Nobody obeys it yet: this step exists to be COMPARED
    # against what the bot actually did, for a night, before anything changes.
    WorldState.put(:orders, orders, now)

    state
    |> narrate(picture)
    |> narrate_orders(orders)
    |> sample_vitals(picture, orders, now)
    |> Map.merge(%{picture: picture, orders: orders, logic: logic})
    |> tap(&broadcast({:engine, &1.picture, &1.orders}))
  end

  # --- VITALS: the four numbers the simulator is still guessing at -------------
  #
  # A `decision` line is written when the engine CHANGES ITS MIND, which is the
  # right cadence for reading a night and the wrong one for measuring it: five
  # minutes of one steady fight is one line, and a rate needs samples. So the
  # same tick also files a plain reading — health, how many are on the list, how
  # many damage keys are ready, and whether the pokémon is on the field at all.
  #
  # Written on a CHANGE of the three things whose transitions carry the
  # measurement (the pokémon leaving or returning to the field, the list
  # growing or shrinking, the bar running dry) and otherwise once every
  # `engine_vitals_ms`. That keeps the transition timestamps at tick resolution
  # — 200ms — without turning a night into a hundred thousand identical lines.
  #
  # From this stream, `Pokex.Sim.Calibrate` answers all four:
  #
  #   * how fast health falls per monster on screen (`bite_dmg`/`bite_every_ms`)
  #   * how many presses and how long one monster costs (`mob_hp` vs the damage)
  #   * how long F4 leaves the pokemon in the ball (`revive_settle_ms`)
  #   * and whether coming back out resets the cooldowns at all (R3b's premise)
  defp sample_vitals(state, picture, orders, now) do
    reading = Vitals.reading(picture, orders, damage_keys(state.loadout))

    if Vitals.due?(state.vitals, reading, now, Settings.get(:engine_vitals_ms)) do
      Events.record(:vitals, reading)
      %{state | vitals: Map.put(reading, :at, now)}
    else
      state
    end
  end

  # Where the hunt is. Absent (no cavebot running, or a stale fact) is a legal
  # answer and means "nothing to decide about" — never a guess.
  defp hunt(now) do
    case WorldState.get(:hunt, Settings.get(:engine_hunt_max_age_ms), now) do
      {:ok, obs} -> obs
      _stale_or_missing -> nil
    end
  end

  # What this pokémon fights WITH, resolved once here so the orders carry keys
  # and no consumer has to ask who is on the field. The reserved control key
  # (`Strategy.reserved/1`) is deliberately absent — it belongs to
  # `PlayerSupport`'s rescue combo alone, see `Logic`'s moduledoc.
  defp hands(nil), do: %{opening: []}
  defp hands(loadout), do: %{opening: Strategy.opening(loadout)}

  defp inputs(state, now) do
    %{
      battle: battle(now),
      own_hp: own_hp(now),
      own_out?: own_out?(now),
      own_name: state.loadout && state.loadout.name,
      ready_keys: Perception.ready_skills(now),
      damage_keys: damage_keys(state.loadout),
      prev: state.picture
    }
  end

  defp config do
    %{engage_from: Settings.get(:engine_engage_from)}
  end

  defp decision_config do
    %{
      engage_from: Settings.get(:engine_engage_from),
      gather_piles: Settings.get(:engine_gather_piles),
      reset_revive: Settings.get(:engine_reset_revive),
      reset_revive_cooldown_ms: Settings.get(:engine_reset_revive_cooldown_ms),
      pile_settle_ms: Settings.get(:engine_pile_settle_ms),
      size_ceiling_ms: Settings.get(:engine_size_ceiling_ms),
      band_yellow_pct: Settings.get(:engine_band_yellow_pct),
      band_red_pct: Settings.get(:engine_band_red_pct),
      resume_pct: Settings.get(:engine_resume_pct),
      recover_timeout_ms: Settings.get(:engine_recover_timeout_ms),
      closing_timeout_ms: Settings.get(:engine_closing_timeout_ms),
      downed_retry_ms: Settings.get(:engine_downed_retry_ms)
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

  # Three answers, and the third one is the whole point: `false` here means the
  # support PROVED the fall (a live bar below the faint line, then gone for two
  # reads), never "the frame did not read". `Logic` refuses to fight on `false`,
  # so an unreadable party window answering `false` would stop the hunt on one
  # bad capture.
  defp own_out?(now) do
    case Perception.pokemon(now) do
      {:ok, %{readable?: true}} -> true
      {:ok, %{fainted?: true}} -> false
      _unreadable_or_missing -> :unknown
    end
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

  # THE SHADOW. One line per DECISION CHANGE, in the same feed as what the bot
  # actually did — so a night can be read as two columns without a second
  # screen: "🧠 quem mandaria" beside the hunt's own lines. The `why` is the
  # whole point; the phase is there so a change of mind is visible even when the
  # sentence reads similar.
  defp narrate_orders(%{orders: %{why: same}} = state, %{why: same}), do: state

  defp narrate_orders(state, orders) do
    log(:macro, "🧠 #{orders.why}#{shadow_hint(orders)}")
    file(state, orders)
    state
  end

  # …and the same moment a second time, TYPED. The sentence above is what he
  # reads in the morning; this is what tells us later whether three was the
  # right ruler — a question no amount of prose can answer.
  defp file(%{picture: nil}, _orders), do: :ok

  defp file(%{picture: picture}, orders) do
    Events.record(:decision, %{
      phase: orders.phase,
      band: orders.band,
      route: orders.route,
      fire: orders.fire,
      revive: orders.revive,
      enemies: picture.enemies,
      rows: picture.rows,
      stable_ms: picture.stable_for_ms,
      growing: picture.growing?,
      hp: picture.own_hp,
      why: orders.why
    })
  end

  # What it WOULD have changed, named only when it differs from just watching —
  # this is what makes the comparison against the bot's real behaviour concrete.
  # Ordered by weight, not by field: a tick that would revive AND hold the route
  # is a revive — naming the hold there would bury the expensive half.
  defp shadow_hint(%{revive: :now}), do: " [reviveria agora]"
  defp shadow_hint(%{fire: :free}), do: " [liberaria o fogo]"
  defp shadow_hint(%{route: :hold}), do: " [seguraria a rota]"
  defp shadow_hint(_watching), do: ""

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

  # A discount made on an ABSENCE must never read like one made on a name: on
  # 2026-08-18 the by-name discount silently never fired for a whole hunt, and
  # nothing on any screen said so. This line is what would have said it.
  defp narrate_own_row(state, %{own_row_seen?: :unnamed}) do
    log(
      :macro,
      "#{own_label(state)} está na lista mas o nome saiu ilegível — descontei a primeira " <>
        "linha sem nome. Ensine os glifos dele na calibração pra voltar a descontar pelo nome."
    )

    state
  end

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
