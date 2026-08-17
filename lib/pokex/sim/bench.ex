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

  alias Pokex.Bots.Engine.Logic
  alias Pokex.Bots.Engine.Situation
  alias Pokex.Sim.Scenario
  alias Pokex.Sim.World

  @tick_ms 100
  @default_duration_ms 60_000

  @default_config %{
    engage_from: 3,
    pile_settle_ms: 1_500,
    size_ceiling_ms: 4_000,
    band_yellow_pct: 60,
    band_red_pct: 30,
    resume_pct: 80,
    recover_timeout_ms: 20_000,
    closing_timeout_ms: 15_000
  }

  @doc "The decision knobs a run uses when the caller names none — his own defaults."
  def default_config, do: @default_config

  @doc """
  Runs `scenario` and answers what happened.

  `opts` takes `:duration_ms` (default 60s of simulated time), `:config` (the
  decision knobs, merged over `default_config/0`), `:routes` (his real routes,
  for a scenario that names one) and `:loadout`.
  """
  @spec run(Scenario.t(), keyword) :: map
  def run(%Scenario{} = scenario, opts \\ []) do
    duration = Keyword.get(opts, :duration_ms, @default_duration_ms)
    config = Map.merge(@default_config, Keyword.get(opts, :config, %{}))
    routes = Keyword.get(opts, :routes, [])

    world =
      scenario
      |> Scenario.route(routes)
      |> World.new(
        seed: scenario.seed,
        knobs: scenario.knobs,
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
      died_at: nil
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
    world = state.world |> World.step(@tick_ms) |> apply_script(state.scenario, was)
    picture = Situation.build(inputs(world, state.picture), state.config, world.clock)

    {logic, orders} =
      Logic.step(state.logic, decision_world(world, picture), state.config, world.clock)

    world = obey(world, orders, state.leg)
    leg = advance_leg(world, state.leg)

    %{state | world: world, logic: logic, picture: picture, leg: leg}
    |> record(orders, picture)
    |> mark(orders, world)
  end

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
      own_out?: world.own.out?,
      own_name: world.own.name,
      ready_keys: World.observe(world, :skill_bar).ready_keys,
      damage_keys: damage_keys(world),
      prev: previous
    }
  end

  # A hunt is always running here — the scenario IS the hunt. Standing where
  # monsters are on screen is `:fighting`, which is what makes the ruler run.
  defp decision_world(world, picture) do
    %{
      situation: picture,
      hunt: %{state: hunt_state(world), luring?: false},
      hands: %{opening: opening(world)}
    }
  end

  defp hunt_state(world) do
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

  defp fire(world, %{fire: :free, opening: keys}) when keys != [],
    do: Enum.reduce(keys, world, &World.press(&2, {:press, &1}))

  defp fire(world, _holding), do: world

  defp revive(world, %{revive: :now}) do
    %{
      world
      | own: %{world.own | hp_pct: 100, out?: true, alive?: true},
        keys: Map.new(world.keys, fn {key, skill} -> {key, %{skill | ready_at: 0}} end)
    }
  end

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

  # The pokémon on the field decides what the keys do. Falls back to a plain
  # loadout when the team file is not readable, so a bench run never depends on
  # which pokémon happens to be out.
  defp loadout do
    Pokex.Bots.Combat.Loadout.current() || fallback_loadout()
  catch
    _kind, _reason -> fallback_loadout()
  end

  defp fallback_loadout do
    %Pokex.Bots.Combat.Loadout{
      name: "Simulado",
      aoe: ["3", "4", "5"],
      single: ["6"],
      buffs: ["2"],
      heal: [],
      crowd: ["1"]
    }
  end
end
