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

  defstruct leg: 0,
            prev_hp: nil,
            last_heal_at: nil,
            last_potion_at: nil,
            # o resgate em duas partes: o stun já saiu e o revive sai em
            # `revive_at` — ver `rescue/3`
            revive_at: nil,
            # A RAJADA QUE AINDA ESTÁ SAINDO: `[{tecla, quando}]`, uma entrada por
            # tecla que ainda não foi apertada. Este mundo tratava seis teclas
            # como um evento instantâneo, e no jogo dele elas custam
            # `combat_skill_gap_ms` uma da outra — com o intervalo em 500ms, uma
            # rajada de seis são dois segundos e meio em que o corpo não faz mais
            # nada. A própria Central já avisa que "é isso que limita o dano da
            # caçada", e a bancada não sabia disso: media um bot que aperta a
            # barra inteira de graça.
            #
            # Cobrar o TEMPO e entregar o DANO todo no instante zero ainda media
            # um bot parecido: a última tecla de uma rajada de sete sai 1,8s
            # depois da primeira, e nesse intervalo o bicho pode já ter morrido.
            # Cada tecla sai quando chega a vez dela, no mundo que existir então.
            firing: [],
            # ONDE ELE ESTAVA E QUANDO ANDOU A ÚLTIMA VEZ. Este caminhante
            # segura setas na direção do waypoint e não tinha nada equivalente
            # ao `unstick/3` do cavebot: com todo candidato do escorregão
            # bloqueado, `World.step/4` devolve a mesma posição e nada mais no
            # mundo mexe o personagem. Uma corrida encostada num canto seguia
            # reportando mortos/min — de uma caçada que nunca andou.
            last_pos: nil,
            moved_at: 0,
            # a direção do desvio enquanto ele está travado (nil = seguir a rota)
            sidestep: nil

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
    {world, hands} = fire_due(world, hands)
    world = if busy?(hands), do: release(world), else: world

    obeying(world, orders, hands, config)
  end

  @doc "Até quando a rajada em voo ainda está saindo; 0 com a mão livre."
  @spec busy_until(t) :: non_neg_integer
  def busy_until(%__MODULE__{firing: []}), do: 0
  def busy_until(%__MODULE__{firing: firing}), do: firing |> Enum.map(&elem(&1, 1)) |> Enum.max()

  defp busy?(%{firing: firing}), do: firing != []

  # As teclas cuja vez chegou saem AGORA, no mundo que existe agora — o resto
  # continua esperando. É aqui que uma rajada longa pode acertar um corpo.
  defp fire_due(world, %{firing: firing} = hands) do
    {due, pending} = Enum.split_with(firing, fn {_key, at} -> at <= world.clock end)

    {Enum.reduce(due, world, fn {key, _at}, acc -> World.press(acc, {:press, key}) end),
     %{hands | firing: pending}}
  end

  # A RAJADA OCUPA O CORPO — mas não a escada de segurança. No bot de verdade o
  # resgate e a cura vão pelo Body com prioridade `:high`
  # (`PlayerSupport.Worker`), e furam a fila justamente porque esperar uma
  # rajada terminar é como se perde um pokémon. Bloquear os dois aqui derrubou o
  # invariante "com stun na frente do revive, nada cai" na primeira rodada — e
  # esse invariante estava certo; o modelo é que estava errado.
  defp obeying(world, orders, hands, config) do
    {world, hands} =
      if busy?(hands),
        do: {world, hands},
        else: world |> walk(orders, hands) |> fire(orders, hands, config)

    {world, hands} = rescue_combo(world, orders, hands, config)
    {world, hands} = support(world, hands, config)

    {world, %{advance(hands, world, config) | prev_hp: world.own.hp_pct}}
  end

  @doc """
  Finishes a rescue that is mid-combo, with no orders involved.

  The stun and the revive are two ticks apart, and the order that started them
  is gone by the second one — the engine enters `:recovering` immediately. A
  caller that only acts while a fresh `:orders` fact exists (the live runner
  does exactly that) would leave the pokémon stunned and never recalled.
  """
  @spec finish_rescue(World.t(), t) :: {World.t(), t}
  def finish_rescue(world, %__MODULE__{} = hands) do
    if due?(hands, world),
      do: {World.revive(world), %{hands | revive_at: nil}},
      else: {world, hands}
  end

  @doc "Where the route is heading, after a load that changed it."
  @spec at_leg(t, non_neg_integer) :: t
  def at_leg(%__MODULE__{} = hands, leg), do: %{hands | leg: leg}

  # `route: :go` walks toward the current waypoint; `:hold` lets go of the keys.
  # It goes through the same `key_down`/`key_up` the cavebot uses, so the world
  # walks at the same pace and by the same rules — stairs included.
  defp walk(world, %{route: :hold}, _hands), do: release(world)

  defp walk(world, _going, %{sidestep: dir}) when is_binary(dir),
    do: World.press(release(world), {:key_down, dir})

  defp walk(world, _going, %{leg: leg}) do
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

  # ANDOU, OU DESISTE DESTE CANTO. Chegar tem prioridade; um pé parado além do
  # `walk_timeout_ms` — o mesmo teto que o cavebot usa antes do `unstick` —
  # pula pro waypoint seguinte, que é o equivalente barato do que ele faz na
  # parede. Sem isto o simulador media uma noite inteira de uma caçada travada.
  defp advance(hands, world, config) do
    cond do
      world.pos != hands.last_pos ->
        %{
          hands
          | last_pos: world.pos,
            moved_at: world.clock,
            sidestep: nil,
            leg: next_leg(world, hands.leg)
        }

      travado?(hands, world, config) ->
        %{hands | moved_at: world.clock, sidestep: sidestep(world, hands.leg)}

      true ->
        %{hands | leg: next_leg(world, hands.leg)}
    end
  end

  defp travado?(hands, world, config) do
    case Map.get(config, :walk_timeout_ms) do
      ms when is_integer(ms) and ms > 0 -> world.clock - hands.moved_at >= ms
      _sem_teto -> false
    end
  end

  # O DESVIO, no molde do `unstick/3` do cavebot: um passo PERPENDICULAR ao eixo
  # que travou. Sozinho ele não contorna nada; o que ele faz é tirar o
  # personagem do alinhamento, e daí o escorregão do próprio mundo (`slides/1`,
  # a reta e depois cada eixo sozinho) volta a ter candidato. Pular o waypoint
  # não serve: o seguinte costuma estar do outro lado da MESMA pedra.
  defp sidestep(world, leg) do
    target = Enum.at(world.route.waypoints, leg)
    {x, _y, _z} = world.pos

    if axis(target.x - x, "right", "left"), do: "down", else: "right"
  end

  # A waypoint counts as reached inside one tile, the same tolerance the cavebot
  # uses; the route loops, because a simulated run has no end of route to reach.
  defp next_leg(world, leg) do
    target = Enum.at(world.route.waypoints, leg)
    {x, y, _z} = world.pos

    if max(abs(target.x - x), abs(target.y - y)) <= 1,
      do: rem(leg + 1, length(world.route.waypoints)),
      else: leg
  end

  # O PREÇO DA RAJADA. As teclas saem uma a cada `combat_skill_gap_ms`, então N
  # teclas ocupam o corpo por (N-1) intervalos — e cada uma sai NA SUA VEZ, não
  # todas no instante em que a rajada foi decidida.
  #
  # E SÓ AS PRONTAS ENTRAM NO PLANO. O bot de verdade faz isso desde sempre —
  # `Combat.Logic.ready_in_priority/2` filtra a ordem pela leitura da barra, e o
  # moduledoc dele diz "only READY skills fire". Estas mãos foram escritas sem
  # esse passo, e o resultado foi um bot PARALISADO: com a barra gasta ele pedia
  # quatro teclas, ocupava o corpo pelos (N-1) intervalos das quatro, nenhuma
  # saía, e no tique seguinte pedia de novo.
  #
  # MEDIDO num traço de 40s (26/08): ocupado em 79% dos tiques, e em 77% ocupado
  # SEM ter apertado nada. Quis atirar 296 vezes, saiu tecla em 6 — parado no
  # meio de 21 monstros com a vida caindo trinta pontos em cinco segundos.
  # Depois do filtro: 9% e 8%.
  #
  # A ordem de prioridade é preservada: filtrar não é reordenar.
  defp fire(world, %{fire: :free, opening: keys}, hands, config) when keys != [] do
    case Enum.filter(keys, &ready_key?(world, &1)) do
      [] ->
        {world, hands}

      prontas ->
        gap = Map.get(config, :skill_gap_ms, 0)

        plan =
          prontas
          |> Enum.with_index()
          |> Enum.map(fn {key, idx} -> {key, world.clock + idx * gap} end)

        fire_due(world, %{hands | firing: plan})
    end
  end

  defp fire(world, _holding, hands, _config), do: {world, hands}

  defp ready_key?(world, key) do
    case world.keys[key] do
      nil -> false
      %{ready_at: at} -> at <= world.clock
    end
  end

  # THE RESCUE IS A COMBO, NOT A KEY — and modelling only the key made every
  # revive look like an invitation to die. `PlayerSupport` fires the reserved
  # CONTROL skill first, confirms it, waits `rescue_stun_settle_ms` with the
  # pokémon still out and tanking, and only then recalls: "com o revive e stun
  # em área antes de usar o revive tudo se resolve" (Lucas, 2026-08-25). The
  # price of a revive is the empty field, and a sleeping pile does not charge
  # it.
  #
  # Two ticks, because the wait is real: the stun goes out now and the revive
  # goes out when the settle has passed. It finishes on its own — the engine
  # drops `revive: :now` the moment it enters `:recovering`, and a rescue that
  # needed the order to still be there would be a rescue that never lands.
  defp rescue_combo(world, orders, hands, config) do
    cond do
      pending?(hands, world) -> {world, hands}
      due?(hands, world) -> {World.revive(world), %{hands | revive_at: nil}}
      orders.revive != :now -> {world, hands}
      stun_first?(world, config) -> stun(world, hands, config)
      true -> {World.revive(world), hands}
    end
  end

  defp pending?(%{revive_at: at}, world) when is_integer(at), do: world.clock < at
  defp pending?(_none, _world), do: false

  defp due?(%{revive_at: at}, world) when is_integer(at), do: world.clock >= at
  defp due?(_none, _world), do: false

  # No stun for a pokémon already on the floor: there is nobody left to press it
  # and nobody left to protect (`PlayerSupport.dispatch_fallen/1` says the same).
  # And no stun without a control key ready — every failure falls toward SAVING.
  defp stun_first?(world, config) do
    Map.get(config, :rescue_stun_first, false) and world.own.out? and
      ready_crowd_keys(world) != []
  end

  defp stun(world, hands, config) do
    [key | _] = ready_crowd_keys(world)
    settle = Map.get(config, :rescue_stun_settle_ms, 0)

    {World.press(world, {:press, key}), %{hands | revive_at: world.clock + settle}}
  end

  defp ready_crowd_keys(world) do
    for {key, %{kind: :crowd, ready_at: at}} <- world.keys, at <= world.clock, do: key
  end

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
