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
  alias Pokex.Bots.Combat.Loadout
  alias Pokex.Bots.Combat.Strategy
  alias Pokex.Bots.Engine.Inputs
  alias Pokex.Pokedex.SkillProfile
  alias Pokex.Bots.Engine.Config
  alias Pokex.Bots.Engine.Logic
  alias Pokex.Bots.Engine.Situation
  alias Pokex.Sim.Hands
  alias Pokex.Sim.Knobs
  alias Pokex.Sim.Scenario
  alias Pokex.Sim.World

  @tick_ms 100
  @default_duration_ms 60_000

  @doc "The world knobs whose authority is `Settings`, at their seeded values."
  def world_knobs, do: Knobs.world(:seeds)

  # THE RIVAL BRAIN, and it is now the OLD one — because the question the panel
  # used to ask got answered.
  #
  # It asked about R3b, his own idea: spend a revive to buy the bar back when
  # every damage key is on cooldown. With the stun modelled and R7 in place the
  # rule is dead flat — 30,65 → 30,45 mortos/min no formigueiro, 8,52 → 8,17 na
  # caçada, e o tempo sem cooldown mal se move (90,77% → 90,51%). A instinto
  # estava certo sobre o problema; andar enquanto a barra recarrega captura o
  # mesmo valor DE GRAÇA.
  #
  # O que a tela precisa mostrar agora é o que o STUN compra, porque é a
  # diferença entre uma noite e um cemitério: sem o prefixo, o circuito denso
  # perde o pokémon 45 vezes por hora e mata o personagem; com ele, zero quedas
  # em 48 corridas. A coluna da direita é a configuração SEM ele, de propósito.
  @tuning %{rescue_stun_first: false}

  @doc "The changes the bench found worth their price, as overrides."
  def tuning, do: @tuning

  @doc """
  The knobs a run uses when the caller names none: the SEEDS, not the values in
  force.

  Seeds keep a bench run reproducible — the same scenario answers the same on
  his machine and in CI, whatever he has tuned today. To ask "what would MY bot
  do", pass `config: Bench.config_in_force()`.
  """
  def default_config, do: Map.merge(Config.defaults(), Knobs.support(:seeds))

  @doc "The knobs as the bot is running them right now — his overrides included."
  def config_in_force, do: Map.merge(Config.in_force(), Knobs.support(:live))

  @doc """
  Runs `scenario` and answers what happened.

  `opts` takes `:duration_ms` (default 60s of simulated time), `:config` (the
  decision knobs, merged over `default_config/0`), `:routes` (his real routes,
  for a scenario that names one) and `:loadout`.
  """
  @spec run(Scenario.t(), keyword) :: map
  def run(%Scenario{} = scenario, opts \\ []) do
    duration = Keyword.get(opts, :duration_ms, @default_duration_ms)

    config =
      default_config()
      |> Map.merge(scenario.config)
      |> Map.merge(Keyword.get(opts, :config, %{}))

    routes = Keyword.get(opts, :routes, [])

    world =
      scenario
      |> Scenario.route(routes)
      |> World.new(
        # A SEMENTE DO CHAMADOR VENCE. `Bench.run(cenario, seed: 7)` é a chamada
        # que qualquer um escreve pra varrer sementes, e até 27/08 ela era
        # ACEITA E IGNORADA: as seis corridas de uma varredura saíam idênticas
        # até o último morto, e a média de seis parecia prova. Só
        # `%{cenario | seed: n}` funcionava, e nada dizia isso.
        seed: Keyword.get(opts, :seed, scenario.seed),
        # A MESA DELE POR ÚLTIMO. Até 26/08 a bancada montava o mundo só com
        # `world_knobs/0` (duas chaves) e os knobs do cenário: a vida do monstro,
        # os níveis de dano e o raio da área que ele acabou de configurar na tela
        # não chegavam aqui. Ele clicava "Rodar" e media um mundo de 100 de vida
        # com dano em porcentagem, enquanto a tela dizia 500 com dano absoluto.
        #
        # Vem por último de propósito, e carrega SÓ o que ele escolheu (o
        # `sim_setup.json` guarda as chaves que ele tocou, não os padrões), então
        # um cenário continua dono de tudo que ele não mexeu.
        knobs:
          world_knobs()
          |> Map.merge(scenario.knobs)
          |> Map.merge(Keyword.get(opts, :knobs, %{})),
        loadout: Keyword.get(opts, :loadout, loadout()),
        blocked: Scenario.blocked(scenario)
      )

    state = %{
      world: world,
      logic: Logic.new(),
      picture: nil,
      scenario: scenario,
      config: config,
      timeline: [],
      hands: Hands.new(),
      # o que a caçada VIA quando pediu o revive: com o resgate virando combo, a
      # prensa cai um ou dois tiques depois do pedido, e julgar a prensa pela
      # foto da chegada chamava de proativo um resgate pedido no amarelo
      asked_revive: nil,
      revived_at: nil,
      died_at: nil,
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

    picture =
      Situation.build(inputs(before, state.picture, state.config), state.config, before.clock)

    {logic, orders} =
      Logic.step(
        state.logic,
        decision_world(before, picture, state.hands.leg, state.config),
        state.config,
        before.clock
      )

    {world, hands} = Hands.obey(before, orders, state.hands, state.config)
    state = remember_ask(state, orders, picture, hands)

    %{state | world: world, hands: hands, logic: logic, picture: picture}
    |> measure(previous, before, world, orders, picture, hands)
    |> forget_ask(before, world)
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
      casts: 0,
      reached: 0,
      vanished: 0,
      deaths: [],
      revives: [],
      piles: [],
      pile_open: nil,
      by_phase: %{},
      by_band: %{},
      violations: [],
      min_hp: nil,
      player_hp: 100,
      # POR ONDE ELE ANDOU — a pergunta que nenhuma métrica daqui respondia, e
      # a única que enxerga a queixa dele de 29/08: "ele vai para locais onde
      # não tem muito monstro, porque ele já matou, e vários locais do mapa
      # ficam sem monstro sendo morto".
      #
      # Mortos por minuto não vê isso: uma caçada presa oscilando entre dois
      # cantos de um bolso já limpo mata pouco POR MINUTO, mas o mesmo número
      # sai de uma caçada lenta que cobre o mapa inteiro. `legs` conta os
      # cantos DISTINTOS que a corrida visitou e `laps` as voltas fechadas —
      # juntos, eles separam andar de rodar em círculo.
      legs: MapSet.new(),
      laps: 0,
      leg_was: nil
    }
  end

  @fight_phases [:sizing, :engaged, :closing, :gathering, :emergency]

  # Three worlds, and the difference between them is the whole point.
  # `previous` ended the last tick; `decided_on` is what this tick's decision
  # saw (the bites have landed by then); `world` is what the orders produced.
  # A DEATH happens between the first two — the bite kills it — and comparing
  # the wrong pair reported zero deaths in a run whose pokemon spent 97% of
  # itself on the floor (2026-08-25).
  defp measure(state, previous, decided_on, world, orders, picture, hands) do
    metrics =
      state.metrics
      |> tally_time(world, orders, picture)
      |> tally_risk(world, orders, picture)
      |> tally_violations(world, orders, picture)
      |> tally_bodies(previous, world)
      |> tally_death(previous, world)
      |> tally_revive(decided_on, world, orders, picture, hands, state.asked_revive)
      |> tally_pile(world, picture)
      |> tally_ground(world, hands)

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

  # THE INVARIANTS — the things that must be true of EVERY tick of EVERY run,
  # which is what "is it consistent" asks for and what a rate per minute can
  # never answer. Each one is a bug this project has already shipped once:
  #
  #   * `:fire_without_body` — ordering a fight with nothing on the field. It
  #     was 71% of a run once, narrated as "estourando a área".
  #   * `:hold_while_down` — standing still with the pokémon in the ball, which
  #     is the character taking the bites for it.
  #   * `:wasted_revive` — a press with full health, a bar that is INTEIRA and
  #     an empty screen: aí ele não compra nada.
  #
  #     A regra era `spent? != true` — "não acabou tudo" — e ela dizia que
  #     reviver com a barra pela metade na tela limpa era desperdício. Ele
  #     desmentiu isso descrevendo como caça (27/08): "eu sempre uso um revive
  #     antes de matar o próximo grupo (…) mesmo que nem tenha acabado todos os
  #     cooldowns, pra já deixar preparado". Com a tela limpa, o que esse revive
  #     compra é a barra inteira no próximo grupo. Desperdício mesmo é reviver
  #     com a barra JÁ inteira.
  #   * `:mute_order` — an order with no reason. A brain that decides in silence
  #     is indistinguishable from a brain that is stopped.
  defp tally_violations(metrics, _world, orders, picture) do
    broken =
      [
        {:fire_without_body, orders.fire == :free and picture.own_out? == false},
        {:hold_while_down, orders.route == :hold and picture.own_out? == false},
        {:wasted_revive,
         orders.revive in [:now, :prepare] and picture.enemies == 0 and
           picture.own_hp == 100 and Map.get(picture, :prepared?) == true},
        {:mute_order, orders.why == ""}
      ]
      |> Enum.filter(&elem(&1, 1))
      |> Enum.map(&elem(&1, 0))

    Map.update!(metrics, :violations, &(broken ++ &1))
  end

  defp tally_bodies(metrics, before, world) do
    %{
      metrics
      | kills: metrics.kills + (world.stats.killed - before.stats.killed),
        casts: metrics.casts + (world.stats.casts - before.stats.casts),
        reached: metrics.reached + (world.stats.reached - before.stats.reached),
        vanished: metrics.vanished + (world.stats.vanished - before.stats.vanished)
    }
  end

  defp tally_death(metrics, %{own: %{alive?: true}}, %{own: %{alive?: false}} = world),
    do: %{metrics | deaths: [world.clock | metrics.deaths]}

  defp tally_death(metrics, _before, _world), do: metrics

  # AN ORDER IS NOT A PRESS THAT LANDED, and since the rescue became a COMBO the
  # two do not even happen on the same tick: the stun goes out when the order is
  # given and the revive lands `rescue_stun_settle_ms` later, with no order in
  # sight. Counting at the order said "zero revives" for a run full of them
  # (measured 2026-08-25) — which is the worst kind of wrong, because the revive
  # is the expensive half.
  #
  # So: the ACCEPTANCE is read off the world (a revive going into flight), and
  # the REFUSAL off the order (asked for, and the world did not move). The
  # picture the refusal is judged by is the one the asking was done on.
  # A PRENSA É JULGADA PELA FOTO DO PEDIDO, não pela da chegada. Desde que o
  # resgate virou combo o revive cai um ou dois tiques depois de ser pedido, e a
  # fase já mudou — um resgate pedido no amarelo aparecia como proativo, que é
  # exatamente a conta que a R3b existe pra fazer.
  # …e o RELÓGIO DO PEDIDO junto com a foto dele. Sem isso, `since_stun_ms`
  # misturava duas horas diferentes: a fase vinha do tique em que o revive foi
  # PEDIDO e o relógio do tique em que ele CHEGOU. Um revive pedido dentro da
  # janela e segurado vinte segundos pelo piso das mãos aparecia como um revive
  # sem prefixo — e foi assim que a distribuição saiu bimodal, com uma cauda em
  # 18-29s que ninguém conseguia explicar. A cauda era esta costura.
  defp remember_ask(state, orders, picture, hands) do
    cond do
      hands.revive_at != nil and state.asked_revive == nil ->
        %{state | asked_revive: ask_photo(state, orders, picture)}

      orders.revive in [:now, :prepare] and state.asked_revive == nil ->
        %{state | asked_revive: ask_photo(state, orders, picture)}

      true ->
        state
    end
  end

  defp tally_revive(metrics, before, world, orders, picture, hands, asked) do
    {asked_orders, asked_picture} = asked_or_now(asked, orders, picture)

    cond do
      landed?(before, world) ->
        file_revive(metrics, world, asked_orders, asked_picture, true)

      # The stun went out and the revive is scheduled: the order is IN FLIGHT,
      # not refused. Counting this tick as a refusal filed every rescue twice.
      hands.revive_at != nil ->
        metrics

      orders.revive in [:now, :prepare] ->
        file_revive(metrics, world, asked_orders, asked_picture, false)

      true ->
        metrics
    end
  end

  defp forget_ask(state, before, world) do
    if landed?(before, world), do: %{state | asked_revive: nil}, else: state
  end

  defp ask_photo(_state, orders, picture), do: %{orders: orders, picture: picture}

  defp asked_or_now(%{orders: o, picture: p}, _orders, _picture), do: {o, p}
  defp asked_or_now(_never_asked, orders, picture), do: {orders, picture}

  # A JANELA DELE. `world.stunned_at` é o último controle que realmente saiu;
  # `nil` quando nenhum saiu ainda.
  #
  # LIDA NA HORA DO DESPACHO, não na do pedido — e a diferença entre as duas
  # inverte a resposta. O resgate é um COMBO: no tique do pedido o stun deste
  # revive ainda não saiu, então uma foto tirada ali mede a idade do controle
  # ANTERIOR e reporta como desprotegido justamente o revive que o stun estava
  # protegendo. Medido no cenário do enxame: dez de doze revives apareciam com
  # 8,2s desde o controle quando o stun de cada um saía 800ms antes de o revive
  # ir.
  #
  # As outras colunas do evento seguem sendo a foto do PEDIDO de propósito
  # (vida, inimigos, barra gasta): elas julgam a DECISÃO, e julgar a decisão
  # pela chegada chamava de proativo um resgate pedido no amarelo. Esta julga a
  # EXECUÇÃO — se a pilha estava dormindo quando o pokémon saiu de campo — e
  # essa é uma pergunta sobre o instante em que ele sai.
  defp since_stun(%{stunned_at: nil}), do: nil
  defp since_stun(world), do: world.clock - world.stunned_at

  defp landed?(before, world), do: before.revive_at == nil and world.revive_at != nil

  defp file_revive(metrics, world, orders, picture, accepted?) do
    event = %{
      at: world.clock,
      phase: orders.phase,
      accepted?: accepted?,
      enemies: picture.enemies,
      spent?: picture.spent?,
      ready: length(picture.ready_keys || []),
      hp: picture.own_hp,
      # A REGRA DELE, medida: "SEMPRE usar o revive dentro da range de 5 segundos
      # no máximo depois de usar a skill de controle". `spent?` fala só das
      # teclas de DANO e o controle é `:crowd`, então até aqui nada na bancada
      # sabia se o stun tinha saído — a pergunta que ele fez era a única que
      # ninguém podia responder.
      since_stun_ms: since_stun(world),
      # …E SE HAVIA CONTROLE PRA GASTAR. Sem isto, dois casos OPOSTOS ficam
      # idênticos no arquivo: o revive que saiu sem stun porque o controle
      # estava FRIO — que é a ordem dele, "se não tiver livre, usar o que tem de
      # cooldown e usa o revive" — e o que saiu sem stun com a tecla de controle
      # pronta na mão, que é o desperdício de que ele reclamou. Contar os dois
      # juntos acusa o bot de desobedecer uma regra que ele está cumprindo.
      #
      # `nil` quando este pokémon não tem controle classificado: sem tecla não
      # há escolha, e portanto não há o que cobrar.
      control_ready?: control_ready?(picture)
    }

    %{metrics | revives: [event | metrics.revives]}
  end

  defp control_ready?(%{control_back_in_ms: ms}) when is_integer(ms), do: ms == 0
  defp control_ready?(_sem_controle_classificado), do: nil

  # O CHÃO COBERTO. Uma volta fecha quando a perna volta pro zero vinda de
  # outra — o mesmo teste que o `Hands` usa pra dar a volta na lista, e não uma
  # contagem de distância que confundiria andar de ir e voltar.
  defp tally_ground(metrics, _world, %{leg: leg}) do
    volta? = leg == 0 and metrics.leg_was not in [nil, 0]

    %{
      metrics
      | legs: MapSet.put(metrics.legs, leg),
        laps: metrics.laps + if(volta?, do: 1, else: 0),
        leg_was: leg
    }
  end

  defp tally_ground(metrics, _world, _sem_maos), do: metrics

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

  defp inputs(world, previous, config) do
    battle = World.observe(world, :battle)
    pokemon = World.observe(world, :pokemon)

    %{
      battle: if(battle.enemies == nil, do: nil, else: battle),
      own_hp: pokemon.hp_pct,
      own_out?: out_state(pokemon),
      pos: World.observe(world, :minimap).pos,
      own_name: world.own.name,
      ready_keys: World.observe(world, :skill_bar).ready_keys,
      damage_keys: damage_keys(world, config),
      # …e o mesmo relógio do controle que o worker entrega, lido do mundo: aqui
      # o cooldown é fato, não carimbo.
      control_back_in_ms: control_back_in_ms(world),
      # …E O BOLSO. `Engine.Worker` entrega `ReviveLedger.remaining()` desde
      # #416 e a bancada nunca entregou nada: `revive_left` chegava `nil` em
      # TODA corrida, então `affordable?` — a guarda que segura o revive quando
      # o estoque está acabando — dizia "pode" sempre. Três regras do cérebro
      # dependem dela, e nenhuma era exercida aqui.
      #
      # Consequência prática: a noite mais cara que ele já teve (o estoque
      # acabou às 23:43 e o bot moeu 4,9 horas com o pokémon no chão) não tinha
      # como acontecer numa simulação. `nil` continua sendo o orçamento
      # desligado, que é o mundo de todo cenário que não pediu um.
      revive_left: World.revive_left(world),
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
  defp decision_world(world, picture, leg, config) do
    luring? = luring?(world, leg)

    %{
      situation: picture,
      hunt: %{state: hunt_state(world, luring?), luring?: luring?},
      # CHAMADA, não derivada: é a mesma função que o `Engine.Worker` usa, e o
      # corte da cauda (declarado em `Engine.Config.bench_only/0`) vem POR CIMA
      # dela, nunca no lugar dela.
      hands: hands(world, picture, config)
    }
  end

  # NA ORDEM DA BARRA, e o `"0"` é a DÉCIMA tecla. Isto percorria o MAPA
  # `world.keys`, então por ordem de termo o `"0"` saía PRIMEIRO aqui e por
  # último no bot, onde `SkillProfile.keys/2` filtra a barra canônica. E
  # `Strategy.skill_order/2` preserva a ordem das listas: era literalmente outra
  # rajada, invisível enquanto todo dano era igual e mensurável no instante em
  # que deixa de ser. Mesma armadilha do preflight que procurava a tecla "10"
  # (#346), num lugar novo.
  defp keys_of_kind(world, kind) do
    for key <- SkillProfile.hotbar_keys(), match?(%{kind: ^kind}, world.keys[key]), do: key
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

  # A BANCADA TEM QUE MEDIR O BOT, NÃO UM PARECIDO. Até 26/08 isto era uma
  # reimplementação própria — filtrava `kind in [:aoe, :single]` do mundo e
  # ordenava por ordem alfabética — enquanto o bot de verdade passa por
  # `Strategy.opening/2`, que decide área-antes-de-alvo pela contagem e põe a
  # aura de dano na frente quando ela está pronta.
  #
  # A divergência não era teórica: a aura NUNCA saía numa corrida de bancada, e
  # com ela fora o multiplicador de 20% que ele descreveu não multiplicava nada.
  # Um sweep de `aura_boost_pct` dava a mesma linha duas vezes, e a explicação
  # não estava no knob.
  defp hands(world, picture, config) do
    hands = Inputs.hands(loadout_of(world), picture, config)

    if config[:spend_the_minimum],
      do: %{
        hands
        | opening: Strategy.enough(hands.opening, dano_por_tecla(world), falta_no_alvo(world))
      },
      else: hands
  end

  # QUANTO CADA TECLA TIRA, na mesma unidade da vida que falta: porcentagem da
  # vida do bicho. No bot de verdade quem responde isto é o `SkillMeter`, que
  # mede olhando a barra do alvo antes e depois; aqui o mundo já sabe, e usar o
  # que ele sabe é o que torna a regra mensurável antes de existir no jogo.
  #
  # O PISO da faixa, não o meio: cortar a rajada pelo dano MÉDIO deixa metade
  # dos bichos vivos com a barra gasta, que é a pior troca desta caçada.
  defp dano_por_tecla(world) do
    for {key, _skill} <- world.keys,
        {lo, _hi} <- [World.damage_band(world, key)],
        into: %{},
        do: {key, lo * 100 / max(world.knobs.mob_hp, 1)}
  end

  # A vida que falta no bicho MAIS GORDO ao alcance: uma rajada de área não mira
  # um alvo, e cortar pelo mais fraco deixaria o resto em pé.
  defp falta_no_alvo(world) do
    world.mobs
    |> Enum.filter(&World.reachable?(&1, world))
    |> Enum.map(&World.hp_pct/1)
    |> Enum.max(fn -> nil end)
  end

  @doc """
  O `%Loadout{}` que este mundo simulado representa — a barra na ordem do jogo.

  Público porque é o que o teste de contrato compara: uma entrada da decisão que
  a bancada monta é uma entrada que pode divergir da do bot, e a ordem das
  teclas é uma delas.
  """
  @spec loadout_of(World.t()) :: Loadout.t()
  def loadout_of(world) do
    %Loadout{
      name: world.own.name,
      aoe: keys_of_kind(world, :aoe),
      single: keys_of_kind(world, :single),
      buffs: keys_of_kind(world, :buffs),
      shield: keys_of_kind(world, :shield),
      heal: keys_of_kind(world, :heal),
      crowd: keys_of_kind(world, :crowd)
    }
  end

  # As teclas de DANO, do mesmo jeito que `Engine.Worker.damage_keys/2`:
  # `spent?` é sobre a barra que mata, a aura não entra — e a de alvo único só
  # entra quando a caçada realmente a usa. Uma tecla que nunca é apertada está
  # sempre pronta, e uma tecla sempre pronta dentro desta lista faz `spent?`
  # nunca ser verdadeiro.
  defp control_back_in_ms(world) do
    case keys_of_kind(world, :crowd) do
      [] -> nil
      crowd -> crowd |> Enum.map(&elem(World.cooling(world, &1), 0)) |> Enum.min()
    end
  end

  defp damage_keys(world, config) do
    area = keys_of_kind(world, :aoe)

    if Map.get(config, :single_target, false) or area == [],
      do: Enum.sort(area ++ keys_of_kind(world, :single)),
      else: Enum.sort(area)
  end

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

  defp mark_revive(%{revived_at: nil} = state, %{revive: order}, world)
       when order in [:now, :prepare],
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
        | violations: Enum.frequencies(state.metrics.violations),
          deaths: Enum.reverse(state.metrics.deaths),
          legs: MapSet.size(state.metrics.legs),
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
