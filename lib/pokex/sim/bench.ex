defmodule Pokex.Sim.Bench do
  @moduledoc """
  A whole hunt, decided and resolved, with no process and no clock.

  This is the proof the engine's design promised and never collected: *"a regra
  é função pura — `(quadro, config, agora) → ordens`. A árvore inteira do Lucas
  vira tabela de teste, sem abrir o jogo."* `Engine.Situation` and `Engine.Logic`
  are pure, and so is `Sim.World`, so a scenario can be run by simply calling
  them in a loop — thousands of ticks in milliseconds, the same answer every
  time.

  What that buys, in order of value:

    * **A verdict instead of an impression.** "Did the revive fire, and at what
      health, with how many monsters still up?" is a number here and a memory in
      the game.
    * **A knob swept instead of guessed.** `sweep/4` runs the same scenario
      across a range and lays the outcomes side by side — which is how
      `pile_settle_ms` stops being a number I made up.
    * **A regression that costs no night.** Any of these can go in the suite.

  ## The loop obeys, which the shadow engine never did

  In the real bot the orders are published and — for `route`, `fire`, `revive` —
  obeyed by three workers. Here one function obeys all three, so the loop is
  closed: the fire spends cooldowns, the kills empty the pile, the revive heals
  AND resets the cooldowns (R3, the whole reason it is worth saving), and the
  next decision sees the consequences of the last one.

  ## What it deliberately does NOT model

  The Body, the receipts, the key latency, and the mini-game gate. Those live
  between the decision and the hand, and they are exactly what the live
  simulator on `/sim` exists to exercise. This bench answers "was the DECISION
  right", never "did the key land".
  """

  alias Pokex.Bots.Cavebot.Route
  alias Pokex.Bots.Engine.Config
  alias Pokex.Bots.Engine.Logic
  alias Pokex.Bots.Engine.Situation
  alias Pokex.Bots.PlayerSupport.Logic, as: Support
  alias Pokex.Settings
  alias Pokex.Sim.Scenario
  alias Pokex.Sim.World

  @tick_ms 100
  @default_duration_ms 60_000

  # The world knobs whose authority is `Settings`: the two floors between two
  # revives belong to `PlayerSupport`, and a bench that keeps its own copy of
  # them answers about a bot that cannot exist. Same lesson as the decision
  # knobs — which is why those now live in `Engine.Config` and not here — and it
  # cost the same way: 2s here against 60s in the seeds made a run report 174
  # revives in 25 minutes without anybody noticing the hunt could never afford
  # them.
  @world_knobs %{
    revive_cooldown_ms: :rescue_cooldown_ms,
    fainted_revive_cooldown_ms: :fainted_revive_cooldown_ms
  }

  # …and the SUPPORT's ladder, which the loop obeys too. Not the engine's
  # decision, but what keeps a pokémon alive between two revives: a bench that
  # models only the last rung answers about a hunt with no first aid at all.
  @support_knobs %{
    heal_skill_enabled: :heal_skill_enabled,
    heal_pct: :pokemon_hp_heal_pct,
    heal_skill_cooldown_ms: :heal_skill_cooldown_ms,
    potion_enabled: :potion_enabled,
    potion_pct: :pokemon_hp_potion_pct,
    potion_cooldown_ms: :potion_cooldown_ms
  }

  @doc "The world knobs whose authority is `Settings`, at their seeded values."
  def world_knobs, do: Map.new(@world_knobs, fn {knob, setting} -> {knob, seed(setting)} end)

  # THE RIVAL BRAIN: the one question about this hunt that is still open, run
  # side by side with what he has in force. It is R3b — his own idea, "usar o
  # revive no F4 rapidinho pra luta seguir firme e forte" — because everything
  # else the bench swept, he already runs (ruler of one, potions on), and a
  # panel comparing a brain against itself teaches nothing.
  #
  # Measured on HIS settings, 5 min x 12 seeds, 2026-08-25 — and the shape of it
  # is a dose curve, not a yes or no:
  #
  #   desligada         8,10 mortos/min · 0,38 revives/min · ele termina com 88%
  #   piso de 6s        9,17 mortos/min · 3,78 revives/min · ele termina com 0%
  #   piso de 60s       8,68 mortos/min · 1,43 revives/min · ele termina com 64%
  #   piso de 120s      8,45 mortos/min · 0,98 revives/min · ele termina com 76%
  #
  # The rule pays; the seeded floor of six seconds was a faucet. Sixty is the
  # value the panel argues for and the seed now carries.
  @tuning %{reset_revive: true, reset_revive_cooldown_ms: 60_000}

  @doc "The changes the bench found worth their price, as overrides."
  def tuning, do: @tuning

  @doc """
  The knobs a run uses when the caller names none: the SEEDS, not the values in
  force.

  Seeds keep a bench run reproducible — the same scenario answers the same on
  his machine and in CI, whatever he has tuned today. To ask "what would MY bot
  do", pass `config: Bench.config_in_force()`.
  """
  def default_config, do: Map.merge(Config.defaults(), support_seeds())

  @doc "The knobs as the bot is running them right now — his overrides included."
  def config_in_force do
    support = Map.new(@support_knobs, fn {knob, setting} -> {knob, Settings.get(setting)} end)
    Map.merge(Config.in_force(), support)
  end

  defp support_seeds,
    do: Map.new(@support_knobs, fn {knob, setting} -> {knob, seed(setting)} end)

  defp seed(setting), do: Map.fetch!(Settings.defaults(), setting)

  @doc """
  Runs `scenario` and answers what happened.

  `opts` takes `:duration_ms` (default 60s of simulated time), `:config` (the
  decision knobs, merged over `default_config/0`), `:routes` (his real routes,
  for a scenario that names one) and `:loadout`.
  """
  @spec run(Scenario.t(), keyword) :: map
  def run(%Scenario{} = scenario, opts \\ []) do
    duration = Keyword.get(opts, :duration_ms, @default_duration_ms)
    config = Map.merge(default_config(), Keyword.get(opts, :config, %{}))
    routes = Keyword.get(opts, :routes, [])

    world =
      scenario
      |> Scenario.route(routes)
      |> World.new(
        seed: scenario.seed,
        knobs: Map.merge(world_knobs(), scenario.knobs),
        loadout: Keyword.get(opts, :loadout, loadout())
      )

    state = %{
      world: world,
      logic: Logic.new(),
      picture: nil,
      scenario: scenario,
      config: config,
      timeline: [],
      leg: 0,
      revived_at: nil,
      died_at: nil,
      last_heal_at: nil,
      last_potion_at: nil,
      metrics: blank_metrics()
    }

    state
    |> loop(duration)
    |> report()
  end

  @doc """
  Runs the same scenario once per value of `knob`, and lays the outcomes side by
  side.

  This is the answer to a number nobody measured: instead of arguing about
  `pile_settle_ms`, run it at 500, 1000, 1500, 2500 and read what each one did.
  """
  @spec sweep(Scenario.t(), atom, [term], keyword) :: [map]
  def sweep(%Scenario{} = scenario, knob, values, opts \\ []) do
    Enum.map(values, fn value ->
      config = Map.put(Keyword.get(opts, :config, %{}), knob, value)
      result = run(scenario, Keyword.put(opts, :config, config))

      Map.put(result.outcome, knob, value)
    end)
  end

  defp loop(state, duration) do
    Enum.reduce_while(0..duration//@tick_ms, state, fn _tick, acc ->
      if acc.world.clock >= duration, do: {:halt, acc}, else: {:cont, step(acc)}
    end)
  end

  defp step(state) do
    was = state.world.clock
    previous = state.world
    before = previous |> World.step(@tick_ms) |> apply_script(state.scenario, was)
    picture = Situation.build(inputs(before, state.picture), state.config, before.clock)

    {logic, orders} =
      Logic.step(
        state.logic,
        decision_world(before, picture, state.leg),
        state.config,
        before.clock
      )

    acted = %{state | world: obey(before, orders, state.leg)} |> support(picture)
    world = acted.world

    %{acted | logic: logic, picture: picture, leg: advance_leg(world, state.leg)}
    |> measure(previous, before, world, orders, picture)
    |> record(orders, picture)
    |> mark(orders, world)
  end

  # --- the scoreboard ---------------------------------------------------------
  #
  # Counted on EVERY tick, not only where a decision changed: a rate per minute
  # made of decision changes would be a rate of opinions. `before` is the world
  # the decision was taken on and `world` is the world it produced, so a revive
  # can be told from a revive that was REFUSED (cooldown, in flight, dead key)
  # by whether the order moved anything.

  defp blank_metrics do
    %{
      ms: 0,
      ms_enemies: 0,
      ms_stalled: 0,
      ms_down: 0,
      ms_fighting: 0,
      kills: 0,
      vanished: 0,
      deaths: [],
      revives: [],
      piles: [],
      pile_open: nil,
      by_phase: %{},
      by_band: %{},
      min_hp: nil,
      player_hp: 100
    }
  end

  @fight_phases [:sizing, :engaged, :closing, :gathering, :emergency]

  # Three worlds, and the difference between them is the whole point.
  # `previous` ended the last tick; `decided_on` is what this tick's decision
  # saw (the bites have landed by then); `world` is what the orders produced.
  # A DEATH happens between the first two — the bite kills it — and comparing
  # the wrong pair reported zero deaths in a run whose pokemon spent 97% of
  # itself on the floor (2026-08-25).
  defp measure(state, previous, decided_on, world, orders, picture) do
    metrics =
      state.metrics
      |> tally_time(world, orders, picture)
      |> tally_risk(world, orders, picture)
      |> tally_bodies(previous, world)
      |> tally_death(previous, world)
      |> tally_revive(decided_on, world, orders, picture)
      |> tally_pile(world, picture)

    %{state | metrics: metrics}
  end

  defp tally_time(metrics, world, orders, picture) do
    # `enemies` is nil while blind and `spent?` is nil while the bar is
    # unreadable, and neither nil may be counted as a fact: a blind stretch is
    # not a stretch without monsters, and an unreadable bar is not a bar with
    # cooldowns free.
    seen? = is_integer(picture.enemies) and picture.enemies > 0
    stalled? = seen? and picture.spent? == true

    %{
      metrics
      | ms: metrics.ms + @tick_ms,
        ms_enemies: metrics.ms_enemies + if(seen?, do: @tick_ms, else: 0),
        # THE number behind "vale a pena o revive rapidinho": time standing in
        # front of monsters with nothing left to press.
        ms_stalled: metrics.ms_stalled + if(stalled?, do: @tick_ms, else: 0),
        ms_down: metrics.ms_down + if(world.own.out?, do: 0, else: @tick_ms),
        ms_fighting:
          metrics.ms_fighting + if(orders.phase in @fight_phases, do: @tick_ms, else: 0),
        # Where the minute WENT. A rate per minute says the hunt is slow; this
        # says which phase ate it, which is the only version of the number a
        # knob can be chosen from.
        by_phase: Map.update(metrics.by_phase, orders.phase, @tick_ms, &(&1 + @tick_ms))
    }
  end

  # A run with zero deaths is not the same as a safe run, and telling them apart
  # is the difference between tuning and gambling. The lowest the bar ever got,
  # how much of the run each band held, and what the CHARACTER paid — the bites
  # that land on him are the whole price of a pokemon off the field.
  defp tally_risk(metrics, world, orders, picture) do
    %{
      metrics
      | by_band: Map.update(metrics.by_band, orders.band, @tick_ms, &(&1 + @tick_ms)),
        min_hp: lowest(metrics.min_hp, picture.own_hp),
        player_hp: min(metrics.player_hp, world.player.hp_pct)
    }
  end

  defp lowest(nil, hp), do: hp
  defp lowest(low, nil), do: low
  defp lowest(low, hp), do: min(low, hp)

  defp tally_bodies(metrics, before, world) do
    %{
      metrics
      | kills: metrics.kills + (world.stats.killed - before.stats.killed),
        vanished: metrics.vanished + (world.stats.vanished - before.stats.vanished)
    }
  end

  defp tally_death(metrics, %{own: %{alive?: true}}, %{own: %{alive?: false}} = world),
    do: %{metrics | deaths: [world.clock | metrics.deaths]}

  defp tally_death(metrics, _before, _world), do: metrics

  # An ORDER is not a press that landed. `revive_ready?/1` on the world the
  # decision was taken against is the difference between "the hunt asked" and
  # "the game got it", and conflating them is how a bench would report six
  # revives from one key.
  defp tally_revive(metrics, before, world, %{revive: :now} = orders, picture) do
    accepted? = World.revive_ready?(before) and world.revive_at != before.revive_at

    event = %{
      at: world.clock,
      phase: orders.phase,
      accepted?: accepted?,
      enemies: picture.enemies,
      spent?: picture.spent?,
      ready: length(picture.ready_keys || []),
      hp: picture.own_hp
    }

    %{metrics | revives: [event | metrics.revives]}
  end

  defp tally_revive(metrics, _before, _world, _orders, _picture), do: metrics

  # A pile EPISODE: from the first monster on the list to the list being empty
  # again. How long one takes is the agility number — "matar tudo e ser ágil".
  # A blind tick (enemies nil) keeps the episode open rather than closing it,
  # because not seeing the pile is not the pile ending.
  defp tally_pile(metrics, _world, %{enemies: nil}), do: metrics

  defp tally_pile(%{pile_open: nil} = metrics, world, %{enemies: n}) when n > 0,
    do: %{metrics | pile_open: world.clock}

  defp tally_pile(%{pile_open: nil} = metrics, _world, _no_enemies), do: metrics

  defp tally_pile(%{pile_open: opened} = metrics, world, %{enemies: 0}),
    do: %{metrics | pile_open: nil, piles: [world.clock - opened | metrics.piles]}

  defp tally_pile(metrics, _world, _pile_still_up), do: metrics

  defp apply_script(world, scenario, was) do
    scenario
    |> Scenario.due(was, world.clock)
    |> Enum.reduce(world, fn
      {:fail, failure}, acc -> World.fail(acc, failure)
      {:recover, failure}, acc -> World.recover(acc, failure)
    end)
  end

  defp inputs(world, previous) do
    battle = World.observe(world, :battle)
    pokemon = World.observe(world, :pokemon)

    %{
      battle: if(battle.enemies == nil, do: nil, else: battle),
      own_hp: pokemon.hp_pct,
      own_out?: out_state(pokemon),
      own_name: world.own.name,
      ready_keys: World.observe(world, :skill_bar).ready_keys,
      damage_keys: damage_keys(world),
      prev: previous
    }
  end

  # Read off the OBSERVATION, never off `world.own.out?` — the same three answers
  # the real worker gets. A blind world hides the bar without the pokemon having
  # gone anywhere, and a bench that peeked at the truth would never exercise the
  # `:unknown` the engine has to survive.
  defp out_state(%{readable?: true}), do: true
  defp out_state(%{fainted?: true}), do: false
  defp out_state(_unreadable), do: :unknown

  # A hunt is always running here — the scenario IS the hunt. Standing where
  # monsters are on screen is `:fighting`, which is what makes the ruler run.
  defp decision_world(world, picture, leg) do
    luring? = luring?(world, leg)

    %{
      situation: picture,
      hunt: %{state: hunt_state(world, luring?), luring?: luring?},
      hands: %{opening: opening(world), single: keys_of_kind(world, :single)}
    }
  end

  defp keys_of_kind(world, kind) do
    for {key, %{kind: ^kind}} <- world.keys, do: key
  end

  # THE MOBBING LEG, which this bench could not see until 2026-08-25 and
  # therefore could not measure: `luring?` was hard-coded false, so the whole
  # `:gathering` branch of the decision — and `engine_gather_piles` with it —
  # was answered by unit tests alone. A sweep of a knob the bench cannot reach
  # is a sweep of nothing, and one was reported.
  #
  # The leg being walked is the one LEAVING the previous waypoint, exactly as
  # `Cavebot.Logic.luring?/1` reads it.
  defp luring?(world, leg) do
    count = length(world.route.waypoints)

    count > 0 and Route.lure_leg?(world.route.waypoints, Integer.mod(leg - 1, count))
  end

  # A hunt walking a mobbing stretch is NOT fighting, whatever is on screen —
  # that is the whole point of the stretch ("se não tá lutando, ele tá no modo
  # mobado, onde ele não deveria atacar NUNCA"). Conflating the two is what let
  # this bench answer `:fighting` for a leg the cavebot walks with the fire
  # held.
  defp hunt_state(_world, true = _luring?), do: :walking

  defp hunt_state(world, _not_luring) do
    if Enum.any?(world.mobs, &World.reachable?(&1, world)), do: :fighting, else: :walking
  end

  defp opening(world) do
    world.keys
    |> Enum.filter(fn {_key, skill} -> skill.kind in [:aoe, :single] end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp damage_keys(world), do: opening(world)

  # The three orders the fleet obeys, obeyed here by one function. That closure
  # is the difference between a shadow engine and a bench: the fire spends the
  # cooldowns, the kills empty the pile, and the revive does BOTH of its jobs
  # (R3) — so the next decision sees what the last one caused.
  defp obey(world, orders, leg) do
    world
    |> walk(orders, leg)
    |> fire(orders)
    |> revive(orders)
  end

  # `route: :go` walks toward the current waypoint; `:hold` lets go of the keys.
  # It goes through the same `key_down`/`key_up` the cavebot uses, so the bench
  # walks at the same pace and by the same rules — stairs included — as the live
  # simulator does.
  defp walk(world, %{route: :hold}, _leg), do: release(world)

  defp walk(world, _going, leg) do
    target = Enum.at(world.route.waypoints, leg)
    {x, y, _z} = world.pos

    wanted =
      Enum.reject(
        [axis(target.x - x, "right", "left"), axis(target.y - y, "down", "up")],
        &is_nil/1
      )

    world
    |> release()
    |> then(fn released ->
      Enum.reduce(wanted, released, &World.press(&2, {:key_down, &1}))
    end)
  end

  defp release(world), do: Enum.reduce(world.held, world, &World.press(&2, {:key_up, &1}))

  defp axis(0, _positive, _negative), do: nil
  defp axis(delta, positive, _negative) when delta > 0, do: positive
  defp axis(_delta, _positive, negative), do: negative

  # A waypoint counts as reached inside one tile, the same tolerance the cavebot
  # uses; the route loops, because a bench run has no end of route to reach.
  defp advance_leg(world, leg) do
    target = Enum.at(world.route.waypoints, leg)
    {x, y, _z} = world.pos

    if max(abs(target.x - x), abs(target.y - y)) <= 1,
      do: rem(leg + 1, length(world.route.waypoints)),
      else: leg
  end

  # The OTHER worker in the loop. `PlayerSupport.Logic` is pure, so the ladder
  # it decides by is called here directly rather than copied — the same reason
  # `Engine.Logic` is. Its two cheap rungs are what stand between a hurt pokemon
  # and the revive, and without them every health scenario answered as if the
  # revive were the only first aid in the game.
  #
  # The revive rung is NOT here: the engine already owns when it happens
  # (`orders.revive`), which is the whole reason the engine exists.
  defp support(state, picture) do
    state
    |> heal_skill(picture)
    |> potion(picture)
  end

  defp heal_skill(state, picture) do
    with true <- Support.heal_wanted?(heal_input(state, picture)),
         [key | _] <- ready_heal_keys(state.world) do
      %{
        state
        | world: World.press(state.world, {:press, key}),
          last_heal_at: state.world.clock
      }
    else
      _nothing_to_press -> state
    end
  end

  # A potion is a CHANNEL and combat cancels it — same gate the worker keeps,
  # and the reason the heal skill exists at all.
  defp potion(state, %{enemies: 0} = picture) do
    if Support.potion_wanted?(potion_input(state, picture)) do
      %{state | world: World.potion(state.world), last_potion_at: state.world.clock}
    else
      state
    end
  end

  defp potion(state, _in_combat), do: state

  defp heal_input(state, picture) do
    %{
      hp_pct: picture.own_hp,
      prev_hp_pct: state.picture && state.picture.own_hp,
      threshold_pct: state.config.heal_pct,
      enabled?: state.config.heal_skill_enabled,
      cooldown_ms: state.config.heal_skill_cooldown_ms,
      last_heal_at: state.last_heal_at,
      now: state.world.clock
    }
  end

  defp potion_input(state, picture) do
    %{
      hp_pct: picture.own_hp,
      prev_hp_pct: state.picture && state.picture.own_hp,
      threshold_pct: state.config.potion_pct,
      enabled?: state.config.potion_enabled,
      cooldown_ms: state.config.potion_cooldown_ms,
      last_potion_at: state.last_potion_at,
      now: state.world.clock
    }
  end

  defp ready_heal_keys(world) do
    for {key, %{kind: :heal, ready_at: at}} <- world.keys, at <= world.clock, do: key
  end

  defp fire(world, %{fire: :free, opening: keys}) when keys != [],
    do: Enum.reduce(keys, world, &World.press(&2, {:press, &1}))

  defp fire(world, _holding), do: world

  defp revive(world, %{revive: :now}), do: World.revive(world)

  defp revive(world, _holding), do: world

  # One line per DECISION CHANGE, not per tick: a timeline with six hundred
  # identical rows is not a timeline.
  defp record(state, orders, picture) do
    last = List.first(state.timeline)

    if last && last.phase == orders.phase && last.why == orders.why do
      state
    else
      entry = %{
        at: state.world.clock,
        phase: orders.phase,
        band: orders.band,
        why: orders.why,
        enemies: picture.enemies,
        hp: picture.own_hp
      }

      %{state | timeline: [entry | state.timeline]}
    end
  end

  defp mark(state, orders, world) do
    state
    |> mark_revive(orders, world)
    |> mark_death(world)
  end

  defp mark_revive(%{revived_at: nil} = state, %{revive: :now}, world),
    do: %{state | revived_at: world.clock}

  defp mark_revive(state, _orders, _world), do: state

  defp mark_death(%{died_at: nil} = state, %{own: %{alive?: false}} = world),
    do: %{state | died_at: world.clock}

  defp mark_death(state, _world), do: state

  defp report(state) do
    timeline = Enum.reverse(state.timeline)

    %{
      timeline: timeline,
      metrics: %{
        state.metrics
        | deaths: Enum.reverse(state.metrics.deaths),
          revives: Enum.reverse(state.metrics.revives),
          piles: Enum.reverse(state.metrics.piles)
      },
      outcome: %{
        phases: timeline |> Enum.map(& &1.phase) |> Enum.dedup(),
        revived_at: state.revived_at,
        died_at: state.died_at,
        killed: state.world.stats.killed,
        vanished: state.world.stats.vanished,
        left_alive: length(state.world.mobs),
        hp_at_end: state.world.own.hp_pct,
        ran_for_ms: state.world.clock,
        ended: ended(state)
      }
    }
  end

  defp ended(%{died_at: at}) when is_integer(at), do: :died
  defp ended(%{world: %{mobs: []}}), do: :clean
  defp ended(_still_going), do: :timeout

  defp loadout, do: Pokex.Sim.Loadout.current()
end
