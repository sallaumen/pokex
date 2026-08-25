defmodule Pokex.Sim.Hands do
  @moduledoc """
  What the world DOES with a set of orders — written once, for both callers.

  The orders are a fact and four workers obey them: the Cavebot walks, Combat
  fires, PlayerSupport revives and keeps the health ladder. The simulator has to
  stand in for all four, and it was standing in for them TWICE — once in
  `Sim.Bench` (pure, headless) and once in `Sim.Runner` (live, on a real clock).

  They drifted, and the drift was invisible because each half had its own tests.
  On 2026-08-25 the live tab — the one he actually plays in — had no support
  ladder at all: nothing healed, nothing drank a potion, and the only first aid
  in the world was a revive on a sixty-second floor. He watched the health bar
  fall the whole way down and the pokémon die without a single press.

  So: one obey, two callers. A rule that is not here does not exist for either.

  ## The four hands, in the order the game gives them

    * **Walk** — `route: :go` holds the direction keys toward the current
      waypoint; `:hold` lets go of them.
    * **Fire** — `fire: :free` presses the keys the orders name.
    * **Revive** — `revive: :now`, which is R3 in one key: it heals AND zeroes
      every cooldown. Modelling only the healing would make the engine look
      wrong about when to spend it.
    * **The support ladder** — the two cheap rungs the engine never orders
      because they were never its call: the pokémon's own healing skill (free,
      works mid-fight) and the potion (costs money, only out of combat).
      `PlayerSupport.Logic` decides both, and it is called here rather than
      copied, for the same reason `Engine.Logic` is.
  """

  alias Pokex.Bots.PlayerSupport.Logic, as: Support
  alias Pokex.Sim.World

  defstruct leg: 0, prev_hp: nil, last_heal_at: nil, last_potion_at: nil

  @type t :: %__MODULE__{}

  @spec new(keyword) :: t
  def new(opts \\ []), do: %__MODULE__{leg: Keyword.get(opts, :leg, 0)}

  @doc """
  Obeys `orders` in `world`, and answers the world it produced.

  `config` carries the support ladder's knobs — build it with
  `Pokex.Sim.Knobs.support/1`.
  """
  @spec obey(World.t(), map, t, map) :: {World.t(), t}
  def obey(world, orders, %__MODULE__{} = hands, config) do
    world =
      world
      |> walk(orders, hands.leg)
      |> fire(orders)
      |> revive(orders)

    {world, hands} = support(world, hands, config)

    {world, %{hands | leg: next_leg(world, hands.leg), prev_hp: world.own.hp_pct}}
  end

  @doc "Where the route is heading, after a load that changed it."
  @spec at_leg(t, non_neg_integer) :: t
  def at_leg(%__MODULE__{} = hands, leg), do: %{hands | leg: leg}

  # `route: :go` walks toward the current waypoint; `:hold` lets go of the keys.
  # It goes through the same `key_down`/`key_up` the cavebot uses, so the world
  # walks at the same pace and by the same rules — stairs included.
  defp walk(world, %{route: :hold}, _leg), do: release(world)

  defp walk(world, _going, leg) do
    target = Enum.at(world.route.waypoints, leg)
    {x, y, _z} = world.pos

    wanted =
      Enum.reject(
        [axis(target.x - x, "right", "left"), axis(target.y - y, "down", "up")],
        &is_nil/1
      )

    Enum.reduce(wanted, release(world), &World.press(&2, {:key_down, &1}))
  end

  defp release(world), do: Enum.reduce(world.held, world, &World.press(&2, {:key_up, &1}))

  defp axis(0, _positive, _negative), do: nil
  defp axis(delta, positive, _negative) when delta > 0, do: positive
  defp axis(_delta, _positive, negative), do: negative

  # A waypoint counts as reached inside one tile, the same tolerance the cavebot
  # uses; the route loops, because a simulated run has no end of route to reach.
  defp next_leg(world, leg) do
    target = Enum.at(world.route.waypoints, leg)
    {x, y, _z} = world.pos

    if max(abs(target.x - x), abs(target.y - y)) <= 1,
      do: rem(leg + 1, length(world.route.waypoints)),
      else: leg
  end

  defp fire(world, %{fire: :free, opening: keys}) when keys != [],
    do: Enum.reduce(keys, world, &World.press(&2, {:press, &1}))

  defp fire(world, _holding), do: world

  defp revive(world, %{revive: :now}), do: World.revive(world)
  defp revive(world, _holding), do: world

  # THE LADDER, cheapest rung first. The revive is NOT here: the engine owns
  # when it happens (`orders.revive`), which is the whole reason it exists.
  defp support(world, hands, config) do
    {world, hands} = heal_skill(world, hands, config)
    potion(world, hands, config)
  end

  defp heal_skill(world, hands, config) do
    with true <- Support.heal_wanted?(heal_input(world, hands, config)),
         [key | _] <- ready_heal_keys(world) do
      {World.press(world, {:press, key}), %{hands | last_heal_at: world.clock}}
    else
      _nothing_to_press -> {world, hands}
    end
  end

  # A potion is a CHANNEL and combat cancels it — the same gate the worker
  # keeps, and the reason the heal skill exists at all.
  defp potion(world, hands, config) do
    if clear?(world) and Support.potion_wanted?(potion_input(world, hands, config)) do
      {World.potion(world), %{hands | last_potion_at: world.clock}}
    else
      {world, hands}
    end
  end

  defp clear?(world), do: World.observe(world, :battle).enemies in [[], nil]

  defp heal_input(world, hands, config) do
    %{
      hp_pct: hp(world),
      prev_hp_pct: hands.prev_hp,
      threshold_pct: config.heal_pct,
      enabled?: config.heal_skill_enabled,
      cooldown_ms: config.heal_skill_cooldown_ms,
      last_heal_at: hands.last_heal_at,
      now: world.clock
    }
  end

  defp potion_input(world, hands, config) do
    %{
      hp_pct: hp(world),
      prev_hp_pct: hands.prev_hp,
      threshold_pct: config.potion_pct,
      enabled?: config.potion_enabled,
      cooldown_ms: config.potion_cooldown_ms,
      last_potion_at: hands.last_potion_at,
      now: world.clock
    }
  end

  # The bar belongs to the pokémon: with it off the field there is nothing to
  # read and nothing to heal, which is exactly what the support sees.
  defp hp(%{own: %{out?: true, hp_pct: hp}}), do: hp
  defp hp(_in_the_ball), do: nil

  defp ready_heal_keys(world) do
    for {key, %{kind: :heal, ready_at: at}} <- world.keys, at <= world.clock, do: key
  end
end
