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
  alias Pokex.Bots.Combat.Loadout
  alias Pokex.Bots.Engine.Config
  alias Pokex.Bots.Engine.Inputs
  alias Pokex.Bots.Engine.Logic
  alias Pokex.Bots.Engine.Narration
  alias Pokex.Bots.Engine.Situation
  alias Pokex.Bots.{ReviveLedger, SkillClock}
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
    # ONE config for the tick, read once. The picture needs `engage_from` and
    # the decision needs all sixteen, and building two maps from the same
    # settings was two chances to read a different value in the same tick.
    config = Config.in_force()
    picture = Situation.build(inputs(state, now, config), config, now)

    WorldState.put(:situation, picture, now)

    {logic, orders} =
      Logic.step(
        state.logic,
        %{situation: picture, hunt: hunt(now), hands: hands(state.loadout, picture, config)},
        config,
        now
      )

    # ORDERS TRAVEL AS A FACT, never as a message — the whole reason a central
    # engine is allowed to exist here. Facts carry their age, so an engine that
    # dies simply stops refreshing this one and every worker falls back to what
    # it does today. Nobody obeys it yet: this step exists to be COMPARED
    # against what the bot actually did, for a night, before anything changes.
    WorldState.put(:orders, orders, now)

    state
    |> narrate(picture, orders)
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
    reading = Vitals.reading(picture, orders, damage_keys(state.loadout, Config.in_force()))

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
  # `single` travels beside `opening` so a decision can spend the CHEAP keys
  # without spending the area — the ruler saves the area for a pile, not the
  # whole bar.
  # `crowd` viaja junto porque deixou de ser um amuleto: a R10 gasta a tecla de
  # controle numa pilha grande, em vez de guardá-la pro resgate que talvez nunca
  # venha. `Strategy.opening/1` continua sem ela — quem a escolhe é a regra.
  # …e a AURA DE DANO lidera a abertura quando a barra diz que ela está pronta.
  # A regra saiu em #357 e o cérebro não a usava: só o worker de combate passava
  # a condição, e é a ENGINE que monta a abertura que o simulador dispara. O
  # resultado era um multiplicador de 20% que nunca multiplicava nada, e uma
  # medição que não conseguia notar a diferença.
  # …e a montagem em si mora em `Engine.Inputs`, chamada também pela bancada:
  # a mesma decisão não pode ser DERIVADA de dois lados.
  defp hands(loadout, picture, config), do: Inputs.hands(loadout, picture, config)

  defp cooldowns(%Loadout{cooldowns: cooldowns}), do: cooldowns
  defp cooldowns(_no_loadout), do: %{}

  # O CONTROLE MAIS PERTO DE VOLTAR. Zero quer dizer pronto; nil, que este
  # pokémon não tem controle classificado — e aí não há o que esperar.
  defp control_back_in_ms(%Loadout{crowd: []}, _now), do: nil

  defp control_back_in_ms(%Loadout{crowd: crowd} = loadout, now) do
    crowd
    |> Enum.map(&SkillClock.assumed_cooling_ms(&1, loadout.cooldowns, now))
    |> Enum.min()
  end

  defp control_back_in_ms(_no_loadout, _now), do: nil

  defp inputs(state, now, config) do
    %{
      battle: battle(now),
      own_hp: own_hp(now),
      own_out?: own_out?(now),
      own_name: state.loadout && state.loadout.name,
      pos: pos(now),
      # A TELA CRUZADA COM O RELÓGIO. `spent?` — a pergunta que decide gastar um
      # revive pra zerar a barra — sai daqui, e ela estava sendo respondida por
      # uma foto que pode ter até `skill_bar_fact_max_age_ms` de idade.
      ready_keys:
        SkillClock.ready(
          Perception.ready_skills(now),
          Loadout.keys(state.loadout),
          cooldowns(state.loadout),
          now
        ),
      damage_keys: damage_keys(state.loadout, config),
      control_back_in_ms: control_back_in_ms(state.loadout, now),
      revive_left: ReviveLedger.remaining(),
      prev: state.picture
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

  # Where he is standing, for the distance half of the ruler (R6). Unknown is a
  # legal answer and costs nothing: a picture with no position simply never
  # accumulates steps, and the count half of the ruler still decides.
  defp pos(now) do
    case Perception.minimap(now) do
      {:ok, %{pos: pos}} -> pos
      _unknown -> nil
    end
  end

  # AS TECLAS QUE ESTA CAÇADA GASTA PRA MATAR — e é sobre elas que `spent?`
  # pergunta "acabou?".
  #
  # Precisa seguir a mesma regra que decide o que É apertado: com as de alvo
  # único fora da rotação (27/08), elas nunca esfriam, e uma tecla que está
  # sempre pronta dentro desta lista faz `spent?` nunca ser verdadeiro — a barra
  # jamais conta como gasta, e toda regra de revive que depende disso morre em
  # silêncio.
  defp damage_keys(nil, _config), do: []

  defp damage_keys(loadout, config) do
    if Map.get(config, :single_target, false) or loadout.aoe == [],
      do: loadout.aoe ++ loadout.single,
      else: loadout.aoe
  end

  # Only the EDGES talk: 200ms of cadence is five lines a second, and a feed
  # nobody can read is silence with more scrolling. WHAT to say is
  # `Engine.Narration`, a pure function of two ticks — it lived here as five
  # `defp`s that each took the whole state and gave it back unchanged after a
  # `log/2`, which made the rule only testable by starting a GenServer.
  defp narrate(state, picture, orders) do
    previous = %{picture: state.picture, orders: state.orders}
    current = %{picture: picture, orders: orders}

    previous
    |> Narration.spoken(current, own_label(state))
    |> Enum.each(fn {level, text} -> log(level, text) end)

    if changed_mind?(state, orders), do: file(state, picture, orders)

    state
  end

  defp changed_mind?(%{orders: %{why: same}}, %{why: same}), do: false
  defp changed_mind?(_state, _orders), do: true

  # …and the same moment a second time, TYPED. The sentence in the feed is what
  # he reads in the morning; this is what tells us later whether three was the
  # right ruler — a question no amount of prose can answer.
  defp file(_state, picture, orders) do
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
