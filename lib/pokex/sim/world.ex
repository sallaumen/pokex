defmodule Pokex.Sim.World do
  @moduledoc """
  The game, as a pure function.

  `new/2` builds a world from one of his REAL recorded routes, `step/2` advances
  it by a number of milliseconds, and `press/2` turns a key into an effect. No
  process, no ETS, no clock, no randomness that is not seeded — the time comes
  in as a parameter and the luck lives in the struct.

  That is what makes a hunt a table test, and what makes the same seed replay
  the same hunt.

  ## Walking is HELD, not tapped

  The cavebot walks with `Body.hold/1` (`cavebot/worker.ex:968`), which becomes
  `key_down`/`key_up` on the rig. So movement here is continuous while a key is
  down, not one tile per event, and two keys down walk both axes — the diagonal
  is real in the game.

  The sign convention is the cavebot's, not a choice: `cavebot/worker.ex:1025-1030`
  reads `dx > 0` as "right" and `dy > 0` as "down", with `dx` being target minus
  current. So **right raises x and down raises y**. Getting it backwards would
  walk away from every corner, and no unit test of the cavebot would notice.

  ## The remainder is kept, in integers

  At 320ms per tile a 50ms tick is a fraction of a tile. Rounding per tick would
  turn 320ms/tile into 350ms/tile and the error would compound across a whole
  leg, so the leftover is carried in `walk_debt_ms`.

  It carries MILLISECONDS, not a fraction of a tile, and that is not cosmetic:
  accumulating `dt / ms_per_tile` as a float loses tiles outright. Ten ticks of
  30ms at 100ms/tile sum to 2.9999999999999996 and walk two tiles where three
  were owed. Integer milliseconds with `div`/`rem` cannot drift.

  ## Every number carries a label

  `@default_knobs` marks each value `measured` (from his own recordings),
  `inherited` (from Settings/team.json) or `invented` (a guess of mine). A
  simulator tuned by eye teaches what I think, not what the game does — so the
  guesses are named as guesses, here and on the screen.
  """

  alias Pokex.Bots.Cavebot.Route

  @default_knobs %{
    # invented — nobody has ever measured tiles/s in this game. `cavebot_measure_walk`
    # exists in /config for exactly this and has never been run, so every conclusion
    # about ROUTE TIMING drawn from this simulator is worth what this guess is worth.
    ms_per_tile: 320,
    # invented — how many per nest and how far they wander. The PLACE is not
    # invented: nests sit on the corners his own hand marked with gather_ms or
    # fight_ms, which is the only trustworthy spatial data that exists.
    # invented — but the SHAPE is his, in his own words: "geralmente tem 1 ou 2
    # espalhados, alguns locais têm 3 ou 4". Weights, not a fixed count. A nest
    # that was ALWAYS exactly four taught a tidiness this game does not have,
    # and he spotted it on the screen the first time he looked.
    nest_sizes: %{1 => 3, 2 => 4, 3 => 2, 4 => 1},
    # A SCENARIO is a controlled experiment and must be able to pin the pile:
    # "pilha que pinga" means nothing if the pile is sometimes four. Setting
    # this to a number replaces the draw entirely AND turns strays off, so a
    # scenario keeps behaving exactly as it did before the distribution existed.
    nest_size: nil,
    nest_radius: 3,
    # invented — the corners his hand did NOT mark are not empty either: "1, 2
    # ou 3 espalhados, de um local ao outro que eu marquei". One roll per
    # unmarked corner, so the road between piles stops being a safe corridor.
    stray_chance_pct: 22,
    aggro_tiles: 8,
    # DELE, e não mais um chute: "reduz um pouco a velocidade dos monstros e do
    # meu próprio pokémon? eles geralmente são mais lentos, por isso que disse
    # uns 5 segundos" (27/08). A 900ms por tile um bicho cruza cinco tiles e
    # meio em cinco segundos — que é mais ou menos a distância da borda da tela
    # até o pokémon, e é de onde a intuição dos 5s dele sai.
    mob_ms_per_tile: 900,
    # HIS account of the game, tiles counted by his eye: the pokemon trails him
    # at about two tiles, walks a little slower than he does, and a long march
    # stretches that gap — until it leaves his screen and the game snaps it to
    # his side. The tile numbers are his; the speed is mine.
    pet_follow_tiles: 2,
    # …e o pokémon dele junto, pelo mesmo relato: ele anda um pouco mais devagar
    # que o personagem, e o personagem não mudou.
    pet_ms_per_tile: 700,
    # Tibia's viewport is 15x11 tiles: seven across from the centre. Leaving
    # that box is what triggers the snap.
    screen_tiles: 7,
    # HIS rule, and it INVERTS what this file used to do: while the pokemon is
    # on the field the character cannot be hurt at all. The danger starts when
    # it falls — which is what finally puts a price on a slow revive.
    player_bite_dmg: 6,
    # invented number, HIS rule (R2): "fazer eles andarem muito longe de onde eles
    # nasceram faz eles sumirem". The ceiling exists here as physics, not policy.
    leash_tiles: 12,
    # invented — the route does not record what lives in it
    mob_name: "Venonat",
    # MEDIDO NO VÍDEO DELE (26/08, gravação de 53s da hunt elétrica): o cliente
    # desenha os segundos que faltam sobre o ícone, então a barra é um
    # cronômetro. As teclas 1, 2 e 3 saem com **40**; as teclas 4, 5 e 6 com
    # **50**. Este número era 8_000 — um chute que fazia a barra voltar seis
    # vezes mais rápido do que volta, e com ele TODA conclusão sobre "tempo sem
    # cooldown", sobre a R7 e sobre o valor do revive estava medida no jogo
    # errado.
    #
    # 45s é a média das duas famílias; a diferença entre 40 e 50 não muda a
    # economia, a diferença entre 8 e 45 muda tudo.
    skill_cooldown_ms: 45_000,
    # E O COOLDOWN DE CADA TECLA, quando ele escreveu — `%{"4" => 12_000}`. O
    # número acima é o chute para quem não tem: uma barra inteira com o MESMO
    # cooldown não tem ordem preferida, e foi assim que este simulador nasceu.
    # A fonte de verdade é o /time (`Loadout.cooldowns`), que é a mesma que o
    # bot de verdade lê; esta chave existe pro /sim poder experimentar com
    # números que ele ainda não gravou no time.
    skill_cooldowns: %{},
    # His to calibrate: how much health a monster of this hunt carries. Damage
    # is in the SAME unit, so both numbers move together and neither is a
    # percentage of something invisible.
    mob_hp: 100,
    # measured BY HIM — which keys, put together, kill one monster ("com a
    # Vespiquen, 3, 4 e 5 garantem"). A shortcut that DERIVES a damage for
    # every key in it, so he can start from the fact he holds.
    kill_combo: [],
    # ...and his override on top, per key: `%{"3" => {28, 41}}`. Whatever is
    # here wins over the combo, because a real bar does not have nine identical
    # skills.
    skill_damage: %{},
    # NOTHING lands as a fixed number. Every press draws inside a band, because
    # a fixed number made "three skills kill" a law of physics — and the game
    # leaves survivors on a sliver. Deciding what to do about THAT survivor is
    # exactly the behaviour he wants to be able to watch and judge.
    damage_spread_pct: 15,
    # invented — the fallback for a key he has neither named nor tuned, as a
    # percentage of whatever `mob_hp` he set
    aoe_damage_pct: 34,
    aoe_radius: 4,
    single_damage_pct: 22,
    # A AURA DELE, em duas metades que ele descreveu juntas (26/08): "a aura de
    # dano tb dá um dano fraco" e "a aura de aumentar dano não dá dano por si só
    # mas aumenta o dano das outras skills em 20%".
    #
    # O dano fraco sai como qualquer outro — pela faixa gravada, ou por esta
    # porcentagem quando ele não gravou nenhuma. O aumento é o que este mundo
    # não sabia fazer de jeito nenhum: uma tecla que não tira vida e ainda assim
    # muda o valor de todas as outras.
    # ZERO por padrão, e não por timidez: "a aura de dano tb dá um dano fraco" é
    # uma frase sobre a barra DELE, não sobre toda aura que existe. Quem tem uma
    # aura que bate diz quanto com um nível — e assim nenhum cenário antigo
    # ganha dano que ninguém pediu.
    buff_damage_pct: 0,
    # …e ZERO pelo mesmo motivo: "aumenta o dano das outras skills em 20%" é uma
    # medida da barra DELE. Ligado por padrão, ele deixaria todo cenário 20%
    # mais forte de uma vez — inclusive os que existem pra provar que o pokémon
    # CAI, que passariam a sobreviver por uma mudança que ninguém pediu ali.
    # Ele põe o 20 na mesa; o mundo só sabe fazer a conta.
    aura_boost_pct: 0,
    aura_boost_ms: 20_000,
    # A OUTRA AURA: "uma hora que deixa ele indestrutível". Enquanto vale, a
    # mordida não encosta — é a diferença entre uma pilha que mata e uma pilha
    # que espera.
    shield_ms: 8_000,
    # The game window is a RECTANGLE: 15 tiles across, 11 down. A Chebyshev
    # radius of 7 made it a 15x15 SQUARE, so the engine was handed creatures
    # sitting six and seven tiles above and below him. Measured on his real
    # Meganium route: 32 of 346 sightings — 9.2% — were things no screen ever
    # showed. A bot deciding on information the game does not give is a bot
    # whose good decisions cannot be trusted either.
    screen_w: 15,
    screen_h: 11,
    bite_dmg: 4,
    bite_every_ms: 900,
    # THE PRICE OF A REVIVE, which is the whole question behind using it as a
    # cooldown reset. A revive that is free and instant makes "aperta F4 sempre"
    # the right answer to everything, which is not an answer — it is a model
    # with no cost in it.
    #
    #   * `revive_settle_ms` — MEDIDO no vídeo dele (26/08): a barra de skills
    #     pertence ao pokémon, então ela SOME enquanto ele está na bola. A 10
    #     quadros por segundo ela fica ausente por cinco quadros — **~500ms**,
    #     não os 1200 que este arquivo chutava. Durante ela nada é causado e as
    #     mordidas passam a ser dele; é o preço de verdade, e ele é menor do
    #     que eu supunha.
    #   * `revive_cooldown_ms` — HIS: `rescue_cooldown_ms` in settings, the floor
    #     the PlayerSupport keeps between two RESCUES of a pokemon that is still
    #     standing. It is a MINUTE, and this file said 2 seconds until
    #     2026-08-25 — thirty times more often than the bot has ever been able
    #     to press it, which is how a bench run reported 174 revives in 25
    #     minutes and called the hunt sustainable.
    #   * `fainted_revive_cooldown_ms` — HIS too, the much shorter floor that
    #     governs the OTHER press: the one at a pokemon already on the floor,
    #     where every second is the character being bitten instead.
    #
    # Both are measurable in the game with a stopwatch and should be. The
    # authority is `Settings`, not this map — see `Bench.world_knobs/0`.
    # THE TWO CHEAP RUNGS of the support ladder, both invented: how much one
    # press of the pokemon's own healing skill gives back, and how much one
    # potion does. `PlayerSupport.Logic` documents the ladder — heal skill is
    # free and works in combat, the potion costs money and only out of it, the
    # revive is the last resort — and this world modelled only the last one,
    # which is what made every hurt run look like a revive treadmill.
    heal_skill_pct: 25,
    potion_heal_pct: 40,
    # O STUN, que é a metade do revive que este mundo nunca teve. "Com o revive e
    # stun em área antes de usar o revive tudo se resolve" (Lucas, 2026-08-25) —
    # e ele está certo: o preço do revive é o campo vazio, e uma pilha dormindo
    # não cobra esse preço. Modelar a prensa sem o sono fazia todo revive parecer
    # um convite pra morrer.
    #
    # Ambos INVENTADOS, e dos mais dignos de um cronômetro: quanto tempo a
    # skill de controle dele derruba a pilha, e a que distância.
    stun_ms: 4_000,
    stun_radius: 4,
    revive_settle_ms: 500,
    revive_cooldown_ms: 60_000,
    fainted_revive_cooldown_ms: 15_000,
    # How long a cleared nest takes to be worth walking past again. `nil` means
    # never, which is what a SCENARIO wants: a controlled experiment must not
    # have monsters arriving from off-stage. A HUNT wants a number — no rate
    # per minute means anything on a map that empties once and stays empty.
    # INVENTED, and one of the numbers most worth measuring in his own hunts.
    respawn_ms: nil,
    # HIS open measurement, not a knob I get to settle: interpret.ex:44 records a
    # live reading saying his pokemon does NOT take a row; he says it always does.
    # The difference is 1, and 1 is the distance between attacking a pile and
    # walking away from it — so the world can do both and the screen compares.
    own_row?: false,
    # the world can go blind on purpose; INJECTING blindness is phase 2, being
    # ABLE to is phase 1, because nil and [] are opposite facts
    readable?: true
  }

  @directions %{"right" => {1, 0}, "left" => {-1, 0}, "down" => {0, 1}, "up" => {0, -1}}

  defstruct route: nil,
            stairs: [],
            unsimulated_stairs: [],
            pos: nil,
            held: [],
            walk_debt_ms: 0,
            mobs: [],
            own: nil,
            player: %{hp_pct: 100, alive?: true},
            keys: %{},
            clock: 0,
            failures: MapSet.new(),
            # `casts`/`reached` answer the question he actually asks of an area
            # skill: "quanta gente cada tiro pega". A cast that reaches nobody
            # is the whole difference between a bar on cooldown and damage done,
            # and nothing was counting it.
            stats: %{killed: 0, vanished: 0, casts: 0, reached: 0},
            # QUANDO O CONTROLE SAIU. A regra dele é uma janela — "SEMPRE usar o
            # revive dentro da range de 5 segundos no máximo depois de usar a
            # skill de controle" — e até 26/08 nada aqui registrava a ponta de
            # baixo dela: a bancada media revives e nunca soube se um stun os
            # precedeu.
            stunned_at: nil,
            # QUANDO O ÚLTIMO REVIVE CAIU. O mundo já sabia disso e não contava:
            # é o instante em que a barra inteira volta, e a tela do simulador
            # precisa poder acender por um momento pra ele VER acontecer.
            revived_at: nil,
            # AS PAREDES E AS PEDRAS. Um `MapSet` de `{x, y, z}` que o
            # personagem não atravessa — o mesmo caminho que já desviava de
            # criatura desde #348, agora com o cenário dentro dele.
            #
            # "uns pontos de obstáculo no caminho pra ele tropeçar e vermos como
            # ele lida" (26/08). Um circuito de chão liso responde sobre a régua
            # e sobre o dano; não responde nada sobre a rota, que é onde a caçada
            # de verdade trava.
            blocked: MapSet.new(),
            # A revive in flight (`revive_at`) and the floor before the next one
            # may be pressed — TWO of them, because the bot keeps two: a pokémon
            # still standing waits `rescue_cooldown_ms` between two presses, one
            # already on the floor waits the much shorter
            # `fainted_revive_cooldown_ms`. Sharing one clock made a rescue
            # spent while standing block the revive of the FALL that followed
            # it, and the pokémon lay there for the long floor: 45% of a dense
            # run on the ground, measured 2026-08-25.
            revive_at: nil,
            rescue_ready_at: 0,
            fainted_ready_at: 0,
            nests: [],
            next_id: 1,
            rand: nil,
            knobs: %{}

  @type t :: %__MODULE__{}

  @doc """
  A world standing on the route's first waypoint.

  `opts` takes `:seed` (default 42) and `:knobs`, which overrides
  `@default_knobs` key by key.
  """
  @spec new(Route.t(), keyword) :: t
  def new(%Route{} = route, opts \\ []) do
    seed = Keyword.get(opts, :seed, 42)
    knobs = @default_knobs |> Map.merge(Keyword.get(opts, :knobs, %{})) |> coherent_aggro()
    start = List.first(route.waypoints)

    {stairs, refused} = stairs_of(route)

    loadout = Keyword.get(opts, :loadout)

    world = %__MODULE__{
      route: route,
      blocked: Keyword.get(opts, :blocked, MapSet.new()),
      stairs: stairs,
      unsimulated_stairs: refused,
      pos: {start.x, start.y, start.z},
      own: %{
        name: loadout && loadout.name,
        hp_pct: 100,
        out?: true,
        alive?: true,
        pos: beside({start.x, start.y, start.z}),
        walk_debt_ms: 0,
        # Os dois efeitos que a barra dele tem e este mundo nunca modelou. Zero
        # é "nunca" no relógio do mundo, o mesmo jeito que `asleep_until` diz
        # que um monstro está acordado.
        boost_until: 0,
        shield_until: 0
      },
      keys: keys_of(loadout),
      rand: :rand.seed_s(:exsss, {seed, seed, seed}),
      knobs: knobs
    }

    spawn_nests(world)
  end

  # A creature cannot NOTICE from farther than its rope lets it come. Left free
  # of each other, the two numbers built a monster that starts chasing 20 tiles
  # away and gives up at 12 — one that can never touch the pokemon. Measured
  # 2026-08-25, before this line existed: "Ele cai" ended every run at 100%
  # health, "Vida caindo" never left green, and half of every pile was counted
  # as vanished without a single bite being thrown.
  defp coherent_aggro(knobs),
    do: %{knobs | aggro_tiles: min(knobs.aggro_tiles, knobs.leash_tiles)}

  # What each key DOES comes from his real team.json, through the same Loadout
  # the Combat worker reads. Only the damage numbers are mine.
  defp keys_of(nil), do: %{}

  defp keys_of(loadout) do
    cooldowns = Map.get(loadout, :cooldowns, %{})

    for {kind, keys} <- [
          aoe: loadout.aoe,
          single: loadout.single,
          buffs: loadout.buffs,
          shield: loadout.shield,
          heal: loadout.heal,
          crowd: loadout.crowd
        ],
        key <- keys,
        into: %{},
        do: {key, %{kind: kind, ready_at: 0, cooldown_ms: Map.get(cooldowns, key)}}
  end

  # Nests sit where HIS HAND stopped: a corner carrying `gather_ms` (he waited
  # for a pile) or `fight_ms` (he killed something). The recorded route already
  # IS the map of where the monsters are, and inventing spawn points would throw
  # away the only trustworthy spatial data in the whole simulator.
  defp spawn_nests(world) do
    nests = Enum.map(world.route.waypoints, &%{waypoint: &1, cleared_at: nil})

    world.route.waypoints
    |> Enum.with_index()
    |> Enum.reduce(%{world | nests: nests}, fn {waypoint, index}, acc ->
      {count, rand} = population_of(acc, waypoint)
      spawn_mobs(%{acc | rand: rand}, waypoint, index, count)
    end)
  end

  # A map that empties once and stays empty is not a hunt, it is a single
  # fight — and no rate per minute means anything on it. A cleared corner comes
  # back after `respawn_ms`, redrawing its population, so a long run walks the
  # ring and meets the piles again exactly the way a night does.
  #
  # `nil` (the default) keeps every SCENARIO a controlled experiment: monsters
  # arriving from off-stage would ruin the one question it exists to ask.
  defp repopulate(%{knobs: %{respawn_ms: nil}} = world), do: world

  defp repopulate(world) do
    live = MapSet.new(world.mobs, & &1.nest)

    world.nests
    |> Enum.with_index()
    |> Enum.reduce(world, fn {nest, index}, acc ->
      cond do
        MapSet.member?(live, index) -> mark_nest(acc, index, nil)
        is_nil(nest.cleared_at) -> mark_nest(acc, index, acc.clock)
        acc.clock - nest.cleared_at < acc.knobs.respawn_ms -> acc
        true -> refill(acc, nest.waypoint, index)
      end
    end)
  end

  defp refill(world, waypoint, index) do
    {count, rand} = population_of(world, waypoint)

    %{world | rand: rand}
    |> spawn_mobs(waypoint, index, count)
    |> mark_nest(index, if(count == 0, do: world.clock))
  end

  defp mark_nest(world, index, at),
    do: %{world | nests: List.update_at(world.nests, index, &%{&1 | cleared_at: at})}

  # Two different questions, one per corner. A corner his hand marked draws its
  # size from his distribution; an unmarked one rolls a much smaller chance of
  # holding a single stray. That is what fills the road between the piles.
  defp population_of(world, waypoint) do
    nest? = !!(waypoint[:gather_ms] || waypoint[:fight_ms])

    case {world.knobs.nest_size, nest?} do
      {nil, true} -> draw_weighted(world.knobs.nest_sizes, world.rand)
      {nil, false} -> stray_roll(world)
      {pinned, true} -> {pinned, world.rand}
      {_pinned, false} -> {0, world.rand}
    end
  end

  defp stray_roll(world) do
    {roll, rand} = :rand.uniform_s(100, world.rand)
    {if(roll <= world.knobs.stray_chance_pct, do: 1, else: 0), rand}
  end

  # Weights, not probabilities: the map says how OFTEN each size shows up
  # relative to the others, so he can retune one number without having to make
  # the rest add back up to a hundred.
  defp draw_weighted(weights, rand) do
    {roll, rand} = :rand.uniform_s(weights |> Map.values() |> Enum.sum(), rand)

    size =
      weights
      |> Enum.sort()
      |> Enum.reduce_while(roll, fn {size, weight}, left ->
        if left <= weight, do: {:halt, size}, else: {:cont, left - weight}
      end)

    {size, rand}
  end

  defp spawn_mobs(world, waypoint, nest, count) do
    Enum.reduce(1..count//1, world, fn _mob, acc ->
      {pos, rand} = free_spot(acc, {waypoint.x, waypoint.y, waypoint.z})

      mob = %{
        id: acc.next_id,
        name: acc.knobs.mob_name,
        # which corner it belongs to, so a cleared corner can be told from a
        # corner whose pile simply walked away
        nest: nest,
        pos: pos,
        hp: acc.knobs.mob_hp,
        max_hp: acc.knobs.mob_hp,
        spawn: pos,
        # A mob that never noticed anything is not "keeping its distance" — it
        # is asleep, and sleeping at home can never count as being dragged away.
        woke?: false,
        walk_debt_ms: 0,
        bite_debt_ms: 0,
        # Dorme até: uma pilha dormindo não anda e não morde, que é o que faz o
        # campo vazio do revive sair de graça.
        asleep_until: 0
      }

      %{acc | mobs: acc.mobs ++ [mob], rand: rand, next_id: acc.next_id + 1}
    end)
  end

  # Nothing is born on top of anything either. With `nest_radius: 0` the scatter
  # has exactly one tile to offer and a pile of five to place, so the search
  # widens until it finds ground. Without this, tile exclusivity would quietly
  # drop four of the five monsters a scenario explicitly asked for — a scenario
  # that lies about its own size is worse than no scenario.
  defp free_spot(world, centre) do
    taken = occupied(world)
    {pos, rand} = scatter(centre, world.knobs.nest_radius, world.rand)

    if MapSet.member?(taken, pos), do: {nearest_free(centre, taken), rand}, else: {pos, rand}
  end

  defp nearest_free({x, y, z}, taken) do
    Stream.iterate(1, &(&1 + 1))
    |> Stream.flat_map(fn ring ->
      for dx <- -ring..ring,
          dy <- -ring..ring,
          max(abs(dx), abs(dy)) == ring,
          do: {x + dx, y + dy, z}
    end)
    |> Enum.find(&(not MapSet.member?(taken, &1)))
  end

  # Every draw threads the state: the struct owns the luck, so the same seed
  # replays the same hunt and a test never depends on the global generator.
  defp scatter({x, y, z}, 0, rand), do: {{x, y, z}, rand}

  defp scatter({x, y, z}, radius, rand) do
    {dx, rand} = :rand.uniform_s(radius * 2 + 1, rand)
    {dy, rand} = :rand.uniform_s(radius * 2 + 1, rand)
    {{x + dx - radius - 1, y + dy - radius - 1, z}, rand}
  end

  @doc "Advances the world by `dt_ms`."
  @spec step(t, non_neg_integer) :: t
  def step(world, dt_ms), do: run(world, dt_ms)

  defp run(world, dt_ms) do
    world
    |> walk(dt_ms)
    |> follow(dt_ms)
    |> move_mobs(dt_ms)
    |> bite(dt_ms)
    |> Map.update!(:clock, &(&1 + dt_ms))
    |> land_revive()
    |> repopulate()
  end

  @doc """
  Turns one key event into an effect.

  The shapes are exactly what `Pokex.Rig.Sim` reports, so the simulated hands
  need no translation layer between them and the world.
  """
  @spec press(t, tuple) :: t
  def press(world, {:key_down, key}) when is_map_key(@directions, key),
    do: %{world | held: Enum.uniq(world.held ++ [key])}

  def press(world, {:key_up, key}), do: %{world | held: world.held -- [key]}

  def press(world, {:press, key}), do: fire(world, key)
  def press(world, {:tap, key}), do: fire(world, key)

  def press(world, {:press_many, keys, _opts}),
    do: Enum.reduce(keys, world, &fire(&2, &1))

  def press(world, _nothing_the_world_models), do: world

  @doc """
  Breaks something on purpose, the way the game breaks it.

  These are the four failures he named, and each is modelled where it actually
  bites rather than as a flag the screen merely displays:

    * `:blind` — the screen cannot be read. `enemies` goes `nil`, NEVER `[]`:
      an empty list is "nothing is there" and a `nil` is "I cannot see", and the
      whole point of the distinction is that they have opposite right answers.
    * `{:dead_key, key}` — the key leaves the hand, the bar changes, the receipt
      confirms, and NOTHING HAPPENS IN THE GAME. This is the bug open in his
      journal on 2026-08-17 (6 openings, 6 `🔁 não saiu`, zero `alvo morto`),
      modelled so the pattern can be compared instead of guessed at.
    * `{:hp, pct}` — puts the health where the scenario needs it, so a band can
      be reached without waiting to be bitten there.
    * `:dead_revive` — the revive is ordered, the key leaves the hand and the
      pokemon STAYS DOWN. Without it every fall is survivable and the fainted
      path is never exercised at all.
  """
  @spec fail(t, term) :: t
  def fail(world, {:hp, pct}),
    do: %{world | own: hurt(world.own, world.own.hp_pct - pct)}

  def fail(world, failure), do: %{world | failures: MapSet.put(world.failures, failure)}

  @spec recover(t, term) :: t
  def recover(world, failure), do: %{world | failures: MapSet.delete(world.failures, failure)}

  @spec broken?(t, term) :: boolean
  def broken?(world, failure), do: MapSet.member?(world.failures, failure)

  @doc """
  R3 in one function: the revive heals, stands the pokemon back up, zeroes every
  cooldown — and puts it back at HIS side, because it comes out of the ball
  where he is standing, not where it fell. It lives here rather than in the
  runner so the bench and the live world cannot drift apart on what it does.
  """
  @spec revive(t) :: t
  # The revive that does not land. In the game the key leaves the hand, the
  # order is obeyed, and the pokemon stays down — the failure he hit on
  # 2026-08-24. Modelled here so a scenario can watch what the hunt does when
  # its only way out stops working, instead of assuming it always works.
  #
  # And a revive COSTS. The order does not heal on the spot: the pokemon goes
  # off the field for `revive_settle_ms` — bar gone, no damage dealt, and every
  # bite landing on HIM instead — and no second press is accepted for
  # `revive_cooldown_ms`. Without that price the model answers "press F4 always"
  # to every question, which is not an answer.
  def revive(%__MODULE__{} = world) do
    cond do
      broken?(world, :dead_revive) -> world
      world.clock < floor_of(world) -> world
      world.revive_at != nil -> world
      true -> start_revive(world)
    end
  end

  @doc "Would a revive ordered right now actually be accepted?"
  @spec revive_ready?(t) :: boolean
  def revive_ready?(%__MODULE__{} = world),
    do: world.clock >= floor_of(world) and world.revive_at == nil

  # The floor is stamped on the state the press was made IN, and only then does
  # the body leave the field — reading it afterwards would call every press a
  # fallen revive, including the rescue of a pokémon that was standing.
  defp start_revive(world) do
    world
    |> stamp_floor()
    |> Map.put(:own, %{world.own | out?: false})
    |> Map.put(:revive_at, world.clock + world.knobs.revive_settle_ms)
  end

  # WHICH floor, decided by the state the press was made in — and stamped on
  # that clock alone. The bot keeps the two independently (`last_rescue_at` and
  # `last_faint_at` in `PlayerSupport`), so a rescue spent on a standing pokémon
  # must not be able to hold down the revive of the fall that follows it.
  defp floor_of(%{own: %{out?: false}} = world), do: world.fainted_ready_at
  defp floor_of(world), do: world.rescue_ready_at

  defp stamp_floor(%{own: %{out?: false}} = world) do
    %{world | fainted_ready_at: world.clock + fainted_floor(world)}
  end

  defp stamp_floor(world),
    do: %{world | rescue_ready_at: world.clock + world.knobs.revive_cooldown_ms}

  defp fainted_floor(world),
    do: Map.get(world.knobs, :fainted_revive_cooldown_ms, world.knobs.revive_cooldown_ms)

  # R3, landed: full health, back on its feet, every cooldown at zero — and back
  # at HIS side, because it comes out of the ball where he is standing, not
  # where it fell.
  defp land_revive(%{revive_at: nil} = world), do: world

  defp land_revive(%{revive_at: at, clock: clock} = world) when clock < at, do: world

  defp land_revive(world) do
    own = %{
      world.own
      | hp_pct: 100,
        out?: true,
        alive?: true,
        pos: snap_beside(world, MapSet.delete(occupied(world), world.own.pos)),
        walk_debt_ms: 0
    }

    %{
      world
      | own: own,
        revive_at: nil,
        revived_at: world.clock,
        keys: Map.new(world.keys, fn {key, skill} -> {key, %{skill | ready_at: 0}} end)
    }
  end

  # A key on cooldown fires NOTHING — that is the closed loop the whole
  # simulator is worth: the press changes the bar, the bar is what the Combat
  # worker's SkillReceipt confirms against, and a receipt that never arrives is
  # exactly the bug open in the real game today.
  # A fallen pokemon casts nothing: the bar belongs to IT, not to him. Every key
  # pressed between the fall and the revive does nothing — which is most of what
  # makes a revive urgent instead of optional. The same clause is what puts the
  # PRICE on a revive spent for its cooldown reset: while the body is in the
  # ball, the fight deals no damage at all.
  defp fire(%{own: %{out?: false}} = world, _key), do: world

  defp fire(world, key) do
    case world.keys[key] do
      nil -> world
      %{ready_at: at} when at > world.clock -> world
      skill -> world |> maybe_damage(key, skill.kind) |> spend(key)
    end
  end

  # The receipt loop still closes — the bar changes and the confirm succeeds —
  # and the monster does not bleed. That is exactly the shape of the failure he
  # is living with, and it is invisible to every log he has.
  defp maybe_damage(world, key, kind) do
    if broken?(world, {:dead_key, key}), do: world, else: damage(world, key, kind)
  end

  defp spend(world, key) do
    %{world | keys: put_in(world.keys, [key, :ready_at], world.clock + cooldown_ms(world, key))}
  end

  @doc """
  O cooldown desta tecla, em ms — o que a tela precisa pra desenhar a contagem.
  """
  @spec cooldown_of(t, String.t()) :: pos_integer
  def cooldown_of(world, key), do: cooldown_ms(world, key)

  @doc """
  Quanto falta pra `key` voltar, em ms, e a fração já recuperada (0.0 a 1.0).
  """
  @spec cooling(t, String.t()) :: {non_neg_integer, float}
  def cooling(world, key) do
    ready_at = get_in(world.keys, [key, :ready_at]) || 0
    total = cooldown_ms(world, key)
    falta = max(ready_at - world.clock, 0)

    {falta, if(total > 0, do: 1.0 - falta / total, else: 1.0)}
  end

  # O COOLDOWN DESTA TECLA, na ordem em que as fontes mandam: o que ele digitou
  # no /sim, o que ele gravou no /time, e por último o chute único de 45s.
  #
  # A ordem importa porque a mesa do /sim é o experimento e o time é a verdade:
  # ele mexe na mesa pra perguntar "e se a área voltasse em 12s?", e não quer
  # que isso apague o que ele mediu no jogo.
  defp cooldown_ms(world, key) do
    Map.get(world.knobs.skill_cooldowns, key) ||
      get_in(world.keys, [key, :cooldown_ms]) ||
      world.knobs.skill_cooldown_ms
  end

  defp damage(world, key, :aoe),
    do: hit(world, world.knobs.aoe_radius, band(world, key, world.knobs.aoe_damage_pct))

  defp damage(world, key, :single),
    do: hit(world, 1, band(world, key, world.knobs.single_damage_pct))

  # A AURA DE DANO faz DUAS coisas, e ele disse as duas na mesma frase: tira um
  # pouco de vida e, enquanto vale, multiplica o que as outras teclas tiram. Uma
  # aura que só multiplicasse seria metade dela; uma que só batesse seria a
  # outra metade, e nenhuma das duas é o que está na barra dele.
  defp damage(world, key, :buffs) do
    world
    |> hit(world.knobs.aoe_radius, band(world, key, world.knobs.buff_damage_pct))
    |> boost()
  end

  # A AURA DE DEFESA: nada de dano, e a mordida não encosta enquanto vale.
  # `Strategy.reserved/1` a mantém fora de toda rajada — ela existe pro momento
  # em que a pilha ia matar, e uma invulnerabilidade gasta na abertura é uma
  # invulnerabilidade que não existe quando ele precisa.
  defp damage(world, _key, :shield),
    do: put_in(world.own.shield_until, world.clock + world.knobs.shield_ms)

  # THE CONTROL KEY, reserved from every ordinary fight by `Strategy.reserved/1`
  # for exactly one moment: the prefix of the rescue. It buys the seconds the
  # revive needs — the pile is asleep while the field is empty.
  defp damage(world, _key, :crowd),
    do: %{sleep(world, world.knobs.stun_radius) | stunned_at: world.clock}

  # THE FIRST RUNG of the ladder his support has always had and this world never
  # modelled: a healing skill is free, instant, and works mid-fight. Only the
  # third rung — the revive — existed here, which is why every hurt run looked
  # like a revive treadmill.
  defp damage(world, _key, :heal), do: %{world | own: mend(world.own, world.knobs.heal_skill_pct)}

  defp damage(world, _key, _no_damage), do: world

  defp boost(world), do: put_in(world.own.boost_until, world.clock + world.knobs.aura_boost_ms)

  @doc """
  THE SECOND RUNG: a potion. Costs money, is a channel, and so only ever
  happens out of combat — the caller owns that gate, exactly as
  `PlayerSupport` does.
  """
  @spec potion(t) :: t
  def potion(%__MODULE__{own: %{out?: true}} = world),
    do: %{world | own: mend(world.own, world.knobs.potion_heal_pct)}

  def potion(world), do: world

  defp mend(own, amount), do: %{own | hp_pct: min(own.hp_pct + amount, 100)}

  @doc """
  What a key would do right now, as `{min, max}`.

  Public so the calibration screen can SHOW the effective band beside every
  key instead of computing its own. Two implementations of "how much does this
  hurt" is the exact split that made the bench and the live world disagree
  about which pokemon was fighting.
  """
  @spec damage_band(t, String.t()) :: {integer, integer} | :no_damage
  def damage_band(world, key) do
    case world.keys[key] do
      %{kind: :aoe} -> band(world, key, world.knobs.aoe_damage_pct)
      %{kind: :single} -> band(world, key, world.knobs.single_damage_pct)
      _nothing_that_hurts -> :no_damage
    end
  end

  # Three sources, most specific first: the range he tuned for THIS key, the
  # share implied by the combo he declared, or the invented percentage. The
  # screen says which one every key is running on, so a number he never chose
  # is never mistaken for one he did.
  defp band(world, key, fallback_pct) do
    case world.knobs.skill_damage[key] do
      {lo, hi} -> {lo, hi}
      _not_tuned -> spread(world, nominal(world, key, fallback_pct))
    end
  end

  defp nominal(%{knobs: %{kill_combo: []}} = world, _key, fallback_pct),
    do: div(world.knobs.mob_hp * fallback_pct, 100)

  defp nominal(world, key, fallback_pct) do
    combo = world.knobs.kill_combo

    if key in combo,
      do: ceil_div(world.knobs.mob_hp, length(combo)),
      else: div(world.knobs.mob_hp * fallback_pct, 100)
  end

  # The share rounds UP: three keys at a third of 100 is 33.333 each, and three
  # presses of a rounded-DOWN 33 leave the monster alive on 1hp. That reads as
  # the combo failing when it is really the arithmetic.
  defp ceil_div(total, parts), do: div(total + parts - 1, parts)

  # A band around the nominal, never a point. `spread_pct: 0` gives back the
  # fixed number for anyone who wants the old certainty.
  defp spread(world, nominal) do
    margin = div(nominal * world.knobs.damage_spread_pct, 100)
    {max(nominal - margin, 1), nominal + margin}
  end

  # The area comes out of the POKEMON, not out of him: keys 1-9 are its bar,
  # which is the entire point of calibrating a bar per pokemon. Combined with it
  # trailing two tiles behind, this alone moves where a pile has to be standing
  # for an area skill to be worth pressing.
  defp sleep(world, radius) do
    until = world.clock + world.knobs.stun_ms

    mobs =
      Enum.map(world.mobs, fn mob ->
        if in_reach?(mob, world.own.pos, radius),
          do: %{mob | asleep_until: max(mob.asleep_until, until), bite_debt_ms: 0},
          else: mob
      end)

    %{world | mobs: mobs}
  end

  @doc "Is this creature asleep right now?"
  @spec asleep?(map, t) :: boolean
  def asleep?(mob, %__MODULE__{} = world), do: world.clock < Map.get(mob, :asleep_until, 0)

  defp hit(world, radius, {lo, hi}) do
    {lo, hi} = boosted(world, {lo, hi})

    {mobs, {rand, reached}} =
      Enum.map_reduce(world.mobs, {world.rand, 0}, fn mob, {r, n} ->
        if in_reach?(mob, world.own.pos, radius) do
          {roll, r} = draw(lo, hi, r)
          {%{mob | hp: mob.hp - roll}, {r, n + 1}}
        else
          {mob, {r, n}}
        end
      end)

    {alive, dead} = Enum.split_with(mobs, &(&1.hp > 0))

    stats =
      world.stats
      |> bump(:killed, length(dead))
      |> bump(:casts, 1)
      |> bump(:reached, reached)

    %{world | mobs: alive, rand: rand, stats: stats}
  end

  # O aumento da aura multiplica a FAIXA, não o sorteio: um bônus aplicado
  # depois do dado achataria a variação que a faixa existe pra ter.
  defp boosted(%{own: %{boost_until: until}} = world, band) when until > 0 do
    if world.clock < until, do: scale(band, 100 + world.knobs.aura_boost_pct), else: band
  end

  defp boosted(_world, band), do: band

  defp scale({lo, hi}, pct), do: {div(lo * pct, 100), div(hi * pct, 100)}

  # Every target rolls its OWN number, the way the game does. That is the whole
  # point of the band: one volley kills four and leaves the fifth on a sliver,
  # and what the engine does about that fifth is the behaviour under test.
  defp draw(lo, hi, rand) when hi > lo do
    {n, rand} = :rand.uniform_s(hi - lo + 1, rand)
    {lo + n - 1, rand}
  end

  defp draw(lo, _hi, rand), do: {lo, rand}

  @doc "A monster's health as a percentage, for a screen or a log to show."
  @spec hp_pct(map) :: integer
  def hp_pct(%{hp: hp, max_hp: max}), do: round(100 * hp / max)

  defp in_reach?(%{pos: {_x, _y, mz}}, {_px, _py, pz}, _radius) when mz != pz, do: false
  defp in_reach?(mob, pos, radius), do: distance(mob.pos, pos) <= radius

  @doc """
  What a feed would have read, in the shape the real interpreter produces.

  The shapes are checked against `perception/interpret.ex:78-90` and `:129`, and
  they are a CONTRACT: if the game ever changes shape the simulator has to break
  along with it, rather than keep answering confidently in a format nobody reads
  any more.

  Two subtleties carry most of the bugs:

    * `enemies` is a list of ROW INDICES, not creatures — `Situation.read_battle`
      counts it with `length/1`. Publishing names there would work by accident
      and lie on the first change.
    * `nil` is a legal answer. An unreadable screen is not an empty one:
      `enemies: nil` and `enemies: []` are opposite facts, and the consumer's
      fail-open rule is what tells them apart.
  """
  @spec observe(t, atom) :: map
  def observe(world, :battle) do
    if unreadable?(world), do: blind_battle(), else: readable_battle(world)
  end

  def observe(world, :pokemon) do
    cond do
      unreadable?(world) -> %{hp_pct: nil, readable?: false, fainted?: false}
      # A fallen pokemon does not read as "health nil on a readable bar": the bar
      # is GONE, because the window changes shape when it goes down. That is how
      # PlayerSupport tells a death from a live reading
      # (`player_support/worker.ex:308` publishes exactly this), and answering
      # `readable?: true` would leave the death scenario untestable while looking
      # correct.
      not world.own.out? -> %{hp_pct: nil, readable?: false, fainted?: true}
      true -> %{hp_pct: world.own.hp_pct, readable?: true, fainted?: false}
    end
  end

  def observe(world, :skill_bar), do: %{ready_keys: ready_keys(world)}

  def observe(world, :minimap), do: %{pos: world.pos}

  # Two ways to not be reading the screen, and they are the same fact to every
  # consumer: the knob (a world built blind) and the injection (a scenario
  # turning the lights off mid-run). Frozen facts are what `:blind` models; the
  # fishing capsule used to be the third way and is gone with it — a hunt never
  # sees one.
  defp unreadable?(world) do
    world.knobs.readable? == false or broken?(world, :blind)
  end

  defp readable_battle(world) do
    rows = own_row(world) ++ visible(world)

    %{
      enemies: Enum.to_list(0..(length(rows) - 1)//1),
      enemies_detail: Enum.with_index(rows, fn row, index -> Map.put(row, :row, index) end),
      red: nil,
      hp: [],
      locked?: false,
      locked_row: nil,
      shiny_rows: [],
      shiny_star_run: 0
    }
  end

  defp blind_battle do
    %{
      enemies: nil,
      enemies_detail: [],
      red: nil,
      hp: [],
      locked?: false,
      locked_row: nil,
      shiny_rows: [],
      shiny_star_run: 0
    }
  end

  # He says his pokemon is always the first row; interpret.ex:44 recorded a
  # reading saying it is not there at all. The world does not settle that — it
  # makes it a switch, so the same hunt can be run both ways and the difference
  # measured instead of argued.
  defp own_row(%{knobs: %{own_row?: true}, own: %{out?: true} = own}),
    do: [%{name: own.name, hp_pct: own.hp_pct / 100, shiny?: false}]

  defp own_row(_off_or_down), do: []

  @doc """
  Is this mob inside the battle list's radius, on the same floor?

  Public because the runner needs the same answer to say whether the character
  is standing in a fight, and two implementations of "is it on screen" is
  exactly the split this project has been closing.
  """
  @spec reachable?(map, t) :: boolean
  def reachable?(mob, world), do: on_screen?(mob, world.pos, world.knobs)

  # The ONLY door through which a creature reaches the engine, and it is a
  # rectangle because the game window is one. Everything the bot decides has to
  # come through here.
  defp on_screen?(%{pos: {_x, _y, mz}}, {_px, _py, pz}, _knobs) when mz != pz, do: false

  defp on_screen?(%{pos: {mx, my, _mz}}, {px, py, _pz}, knobs),
    do: abs(mx - px) <= div(knobs.screen_w, 2) and abs(my - py) <= div(knobs.screen_h, 2)

  defp visible(world) do
    world.mobs
    |> Enum.filter(&on_screen?(&1, world.pos, world.knobs))
    |> Enum.map(&%{name: &1.name, hp_pct: &1.hp / &1.max_hp, shiny?: false})
  end

  defp ready_keys(world) do
    world.keys
    |> Enum.filter(fn {_key, skill} -> skill.ready_at <= world.clock end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp walk(%{held: []} = world, _dt_ms), do: world

  defp walk(world, dt_ms) do
    owed = world.walk_debt_ms + dt_ms
    per_tile = world.knobs.ms_per_tile
    tiles = div(owed, per_tile)

    %{world | pos: advance(world, tiles), walk_debt_ms: rem(owed, per_tile)}
  end

  # The pokemon is a body, not a number on a card. Three things, all his: it
  # trails him at about two tiles, it walks SLOWER than he does — so a long
  # march stretches the gap instead of holding it — and when it finally leaves
  # his screen the game snaps it to his side. The drift is the interesting part:
  # it means the pokemon is not standing where he is when a pile closes, and
  # every area skill is measured from the pokemon.
  defp follow(%{own: %{out?: false}} = world, _dt_ms), do: world

  defp follow(world, dt_ms) do
    own = world.own
    owed = own.walk_debt_ms + dt_ms
    tiles = div(owed, world.knobs.pet_ms_per_tile)

    blocked = MapSet.delete(occupied(world), own.pos)

    pos =
      cond do
        off_screen?(own.pos, world.pos, world.knobs.screen_tiles) ->
          snap_beside(world, blocked)

        distance(own.pos, world.pos) > world.knobs.pet_follow_tiles ->
          chase(own.pos, world.pos, tiles, blocked)

        true ->
          own.pos
      end

    %{world | own: %{own | pos: pos, walk_debt_ms: rem(owed, world.knobs.pet_ms_per_tile)}}
  end

  # Off screen means off the viewport OR on another floor: a staircase leaves
  # the pokemon a whole floor behind, and the game does not make it walk back.
  defp off_screen?({_x, _y, pz}, {_cx, _cy, cz}, _tiles) when pz != cz, do: true
  defp off_screen?(pos, char, tiles), do: distance(pos, char) > tiles

  # Snapped to his SIDE, never on top of him: sharing a tile would read as
  # distance zero and quietly break every "what is next to what" question.
  defp beside({x, y, z}), do: {x - 1, y, z}

  # And never on top of a monster either — the snap lands on the first free
  # square it can reach, which on a crowded corner is not the one to his left.
  defp snap_beside(world, blocked) do
    spot = beside(world.pos)
    if MapSet.member?(blocked, spot), do: nearest_free(world.pos, blocked), else: spot
  end

  # O PERSONAGEM TAMBÉM É UM CORPO, e até 26/08 não era: ele atravessava a pilha
  # inteira. Isso fazia a fuga da R7 sempre funcionar no banco — e no jogo dele
  # a caçada tropeçou em `:stuck` no meio de uma fuga, cercada, quinze segundos
  # depois de começar. Uma regra medida num mundo onde escapar é sempre possível
  # é uma regra medida em outro jogo.
  #
  # E ele DESLIZA, como o cavebot: bater de frente e parar transformaria
  # qualquer bicho parado no caminho numa rota travada, que é o oposto do que o
  # jogo faz (`Cavebot.Logic.unstick/3` já escorrega pelo mesmo motivo).
  defp advance(world, tiles) do
    heading = heading(world.held)

    Enum.reduce(1..tiles//1, world.pos, fn _tile, pos ->
      step(pos, heading, world, impassable(world))
    end)
  end

  defp step(pos, heading, world, blocked) do
    heading
    |> slides()
    |> Enum.map(&one_tile(pos, &1, world.stairs))
    |> Enum.find(pos, &(&1 not in blocked))
  end

  # A reta primeiro; depois cada eixo sozinho, que é o escorregão do cavebot.
  defp slides({0, 0}), do: []
  defp slides({dx, 0}), do: [{dx, 0}]
  defp slides({0, dy}), do: [{0, dy}]
  defp slides({dx, dy}), do: [{dx, dy}, {dx, 0}, {0, dy}]

  # O que o personagem não atravessa: as criaturas E o cenário.
  defp impassable(world), do: MapSet.union(occupied_by_creatures(world), world.blocked)

  # A EXCLUSÃO é das criaturas: o pokémon dele e os monstros. `occupied/1`
  # inclui a própria posição do personagem, que aqui seria bloquear a si mesmo.
  defp occupied_by_creatures(world) do
    world.mobs
    |> Enum.map(& &1.pos)
    |> then(&if(world.own.out?, do: [world.own.pos | &1], else: &1))
    |> MapSet.new()
  end

  defp heading(held) do
    Enum.reduce(held, {0, 0}, fn key, {ax, ay} ->
      {kx, ky} = Map.fetch!(@directions, key)
      {ax + kx, ay + ky}
    end)
  end

  # Landing on the step WITH the stair's own heading spends one key on two tiles
  # and changes floor. Any other heading crosses the same ground normally — the
  # tile is only a staircase from the direction it was recorded from.
  defp one_tile({x, y, z}, {dx, dy}, stairs) do
    next = {x + dx, y + dy, z}

    case Enum.find(stairs, &(&1.at == next and &1.dir == {dx, dy})) do
      nil -> next
      stair -> {x + dx * 2, y + dy * 2, stair.to_z}
    end
  end

  # A staircase is ONE key that walks TWO tiles and changes floor. He marks the
  # corner right before and right after, so the step is the MIDPOINT of the pair
  # — and only a clean pair (±2 on one axis, 0 on the other) still carries it. A
  # dirty pair lost the real position at recording time, and offering a
  # correction for one is exactly what must never happen here.
  #
  # But refusing SILENTLY is its own lie: measured against his real routes,
  # `Meganium and Venoss` and `Meganium 1` are 2/2 clean, `Xatu easy` is 4 of 8,
  # and `Azumaril easy` has ZERO — simulating that one, the character would cross
  # the stair tile and stay on the floor, looking like a bug in the bot. So every
  # refusal is reported, and the screen says which routes cannot fully be walked.
  defp stairs_of(%Route{waypoints: waypoints}) do
    waypoints
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce({[], []}, fn [a, b], {stairs, refused} ->
      case stair_between(a, b) do
        :same_floor -> {stairs, refused}
        {:ok, stair} -> {stairs ++ [stair], refused}
        :dirty -> {stairs, refused ++ [%{from: point(a), to: point(b)}]}
      end
    end)
  end

  defp stair_between(%{z: z}, %{z: z}), do: :same_floor

  defp stair_between(a, b) do
    dx = b.x - a.x
    dy = b.y - a.y

    if {abs(dx), abs(dy)} in [{2, 0}, {0, 2}] do
      {:ok,
       %{at: {a.x + div(dx, 2), a.y + div(dy, 2), a.z}, dir: {sign(dx), sign(dy)}, to_z: b.z}}
    else
      :dirty
    end
  end

  defp point(%{x: x, y: y, z: z}), do: {x, y, z}

  defp sign(0), do: 0
  defp sign(n) when n > 0, do: 1
  defp sign(_negative), do: -1

  defp move_mobs(world, dt_ms) do
    {moved, _taken} =
      Enum.map_reduce(world.mobs, occupied(world), fn mob, taken ->
        next = walk_mob(mob, world, dt_ms, MapSet.delete(taken, mob.pos))
        {next, taken |> MapSet.delete(mob.pos) |> MapSet.put(next.pos)}
      end)

    {kept, gone} = Enum.split_with(moved, &(not leashed?(&1, world)))

    %{world | mobs: kept, stats: bump(world.stats, :vanished, length(gone))}
  end

  # Creatures do not share a tile in this engine. That is what makes a square a
  # real POSITION rather than a dot, and leaving it out hid a monster of a bug:
  # five mobs spawned on one corner all bit from the same square, so a pile was
  # deadlier than any pile the game can actually build. Tile exclusivity is also
  # what caps how many things can touch the pokemon at once — eight, not five
  # hundred — which is half of what "parar no local ideal" even means.
  defp occupied(world) do
    world.mobs
    |> Enum.map(& &1.pos)
    |> then(&if(world.own.out?, do: [world.own.pos | &1], else: &1))
    |> MapSet.new()
    |> MapSet.put(world.pos)
  end

  # Vanished and killed are NOT the same outcome and must never be counted
  # together: one is R2 (greed dragged them too far from where they spawned) and
  # the other is the fight working. A report that adds them up would read a
  # ruined mob as a successful one.
  defp bump(stats, _key, 0), do: stats
  defp bump(stats, key, n), do: Map.update!(stats, key, &(&1 + n))

  # R2 as physics, not policy: drag a mob far enough from where it spawned and
  # it does not stop and does not turn back — it is GONE. That is what puts a
  # ceiling on greed, and the engine gets to discover it instead of being told.
  #
  # WHO is measured matters, and it took a day of impossible fights to see it.
  # Measuring the MOB's own walk charged it for the trip TOWARDS the fight: it
  # burned its rope crossing the room and evaporated three tiles short of the
  # pokemon, every time, in every scenario. Measuring the POKEMON charges it for
  # a body that trails two to five tiles behind — the mob gave up because of
  # where the pet was standing. The reference is HIM: greed is his, the walking
  # away is his, and R2 says "you dragged them too far from home".
  #
  # And a mob that never woke is never leashed: at the top of a run he is
  # already outside every nest he has not reached yet.
  defp leashed?(%{woke?: false}, _world), do: false

  defp leashed?(mob, world), do: distance(world.pos, mob.spawn) > world.knobs.leash_tiles

  defp walk_mob(%{pos: {_x, _y, mz}} = mob, %{pos: {_px, _py, pz}}, _dt_ms, _blocked)
       when mz != pz,
       do: mob

  defp walk_mob(mob, world, dt_ms, blocked) do
    target = target_of(mob, world)

    if asleep?(mob, world),
      do: dozing(mob),
      else: walk_awake(mob, world, dt_ms, blocked, target)
  end

  # Dorme parado, e sem dívida de passo: acordar não pode devolver os tiles que
  # ele teria andado dormindo.
  defp dozing(mob), do: %{mob | walk_debt_ms: 0}

  defp walk_awake(mob, world, dt_ms, blocked, target) do
    if distance(mob.pos, target) > world.knobs.aggro_tiles do
      mob
    else
      owed = mob.walk_debt_ms + dt_ms
      per_tile = world.knobs.mob_ms_per_tile
      tiles = div(owed, per_tile)

      %{
        mob
        | pos: chase(mob.pos, target, tiles, blocked),
          walk_debt_ms: rem(owed, per_tile),
          woke?: true
      }
    end
  end

  # HIS rule, in his words: a monster that can see the pokemon focuses the
  # pokemon. Only when the pokemon is down, or too far away to be seen, does the
  # monster come for him instead.
  defp target_of(mob, %{own: %{out?: true} = own} = world) do
    if in_reach?(mob, own.pos, world.knobs.aggro_tiles), do: own.pos, else: world.pos
  end

  defp target_of(_mob, world), do: world.pos

  # Stops ADJACENT, never on top: a mob standing on the character would read as
  # distance zero and quietly break every "is it next to me" question later.
  defp chase(pos, target, tiles, blocked) do
    Enum.reduce(1..tiles//1, pos, fn _tile, {x, y, z} = current ->
      {tx, ty, _tz} = target
      step = {x + sign(tx - x), y + sign(ty - y), z}

      cond do
        distance(current, target) <= 1 -> current
        MapSet.member?(blocked, step) -> sidestep(current, target, blocked)
        true -> step
      end
    end)
  end

  # Blocked head-on, a monster walks AROUND: it takes the free neighbour that
  # gets it closest, and refuses any step that would put it further away than it
  # already is. Anything less deadlocks — coming down a straight line into his
  # square, the two halves of the diagonal are "the blocked step" and "no step
  # at all", so the monster parks behind him and never bites. That was a live
  # bug, not a test being old: a pile could sit one tile away for a whole hunt.
  defp sidestep({x, y, z} = current, target, blocked) do
    candidates = for dx <- -1..1, dy <- -1..1, {dx, dy} != {0, 0}, do: {x + dx, y + dy, z}

    case Enum.reject(candidates, &MapSet.member?(blocked, &1)) do
      [] ->
        current

      free ->
        best = Enum.min_by(free, &distance(&1, target))
        if distance(best, target) <= distance(current, target), do: best, else: current
    end
  end

  # Chebyshev: the game is a grid WITH diagonals, so {0,0} to {3,3} is three
  # tiles, not 4.24. Euclidean distance here would make every radius wrong.
  defp distance({x1, y1, _z1}, {x2, y2, _z2}), do: max(abs(x1 - x2), abs(y1 - y2))

  # Who gets bitten is HIS rule, and it is the reverse of what this file used to
  # do. While the pokemon is on the field it absorbs everything and the
  # character cannot be touched at all. When it falls it stops being bitten —
  # health dropping past zero is a number no screen could show — and the bites
  # land on HIM instead. So a slow revive stops being free: it is the only
  # stretch of the whole hunt where he can actually die.
  defp bite(world, dt_ms) do
    {mobs, on_pet, on_player} =
      Enum.reduce(world.mobs, {[], 0, 0}, fn mob, {kept, pet, player} ->
        {mob, bites} = chew(mob, world, dt_ms)

        cond do
          bites == 0 -> {kept ++ [mob], pet, player}
          world.own.out? -> {kept ++ [mob], pet + bites, player}
          true -> {kept ++ [mob], pet, player + bites}
        end
      end)

    %{
      world
      | mobs: mobs,
        own: hurt(world.own, bitten_for(world, on_pet)),
        player: wound(world.player, on_player * world.knobs.player_bite_dmg)
    }
  end

  # A monster bites whatever it is standing next to: the pokemon while that is
  # what it came for, him once the pokemon is gone.
  defp chew(mob, world, dt_ms) do
    victim = if world.own.out?, do: world.own.pos, else: world.pos

    if in_reach?(mob, victim, 1) and not asleep?(mob, world) do
      owed = mob.bite_debt_ms + dt_ms
      per_bite = world.knobs.bite_every_ms
      {%{mob | bite_debt_ms: rem(owed, per_bite)}, div(owed, per_bite)}
    else
      {%{mob | bite_debt_ms: 0}, 0}
    end
  end

  # A AURA DE DEFESA no único lugar em que ela importa: enquanto vale, a mordida
  # não encosta. É por isso que ela é reservada — "uma hora que deixa ele
  # indestrutível" só é uma hora se ninguém a gastou antes.
  defp bitten_for(%{own: %{shield_until: until}, clock: clock}, _bites) when clock < until, do: 0
  defp bitten_for(world, bites), do: bites * world.knobs.bite_dmg

  defp hurt(own, 0), do: own

  defp hurt(own, amount) do
    hp = max(own.hp_pct - amount, 0)
    %{own | hp_pct: hp, alive?: hp > 0, out?: hp > 0}
  end

  # Perception has no fact for this. There is a pokemon-health feed and no
  # player-health feed anywhere, so the world knows he is dying and the bot
  # cannot see it. That blindness is a finding, not a gap to paper over.
  defp wound(player, 0), do: player

  defp wound(player, amount) do
    hp = max(player.hp_pct - amount, 0)
    %{player | hp_pct: hp, alive?: hp > 0}
  end
end
