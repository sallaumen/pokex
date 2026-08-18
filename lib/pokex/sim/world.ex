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
    # invented — the same unmeasured tiles/s hole as the character's step
    mob_ms_per_tile: 420,
    # HIS account of the game, tiles counted by his eye: the pokemon trails him
    # at about two tiles, walks a little slower than he does, and a long march
    # stretches that gap — until it leaves his screen and the game snaps it to
    # his side. The tile numbers are his; the speed is mine.
    pet_follow_tiles: 2,
    pet_ms_per_tile: 380,
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
    # inherited — the real cooldowns live in team.json; this is the fallback for a
    # loadout that does not name one
    skill_cooldown_ms: 8_000,
    # measured BY HIM — the one damage fact he actually holds: which keys, put
    # together, kill one monster ("com a Vespiquen, 3, 4 e 5 garantem"). The
    # damage per press is DERIVED from that, so the number stops being my
    # slider and starts being his sentence.
    kill_combo: [],
    # invented — the fallback for a key he has not named, and for a world with
    # no combo declared at all
    aoe_damage: 34,
    aoe_radius: 4,
    single_damage: 22,
    battle_radius: 7,
    bite_dmg: 4,
    bite_every_ms: 900,
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
            stats: %{killed: 0, vanished: 0},
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
    knobs = Map.merge(@default_knobs, Keyword.get(opts, :knobs, %{}))
    start = List.first(route.waypoints)

    {stairs, refused} = stairs_of(route)

    loadout = Keyword.get(opts, :loadout)

    world = %__MODULE__{
      route: route,
      stairs: stairs,
      unsimulated_stairs: refused,
      pos: {start.x, start.y, start.z},
      own: %{
        name: loadout && loadout.name,
        hp_pct: 100,
        out?: true,
        alive?: true,
        pos: beside({start.x, start.y, start.z}),
        walk_debt_ms: 0
      },
      keys: keys_of(loadout),
      rand: :rand.seed_s(:exsss, {seed, seed, seed}),
      knobs: knobs
    }

    spawn_nests(world)
  end

  # What each key DOES comes from his real team.json, through the same Loadout
  # the Combat worker reads. Only the damage numbers are mine.
  defp keys_of(nil), do: %{}

  defp keys_of(loadout) do
    for {kind, keys} <- [
          aoe: loadout.aoe,
          single: loadout.single,
          buffs: loadout.buffs,
          heal: loadout.heal,
          crowd: loadout.crowd
        ],
        key <- keys,
        into: %{},
        do: {key, %{kind: kind, ready_at: 0}}
  end

  # Nests sit where HIS HAND stopped: a corner carrying `gather_ms` (he waited
  # for a pile) or `fight_ms` (he killed something). The recorded route already
  # IS the map of where the monsters are, and inventing spawn points would throw
  # away the only trustworthy spatial data in the whole simulator.
  defp spawn_nests(world) do
    Enum.reduce(world.route.waypoints, world, fn waypoint, acc ->
      {count, rand} = population_of(acc, waypoint)
      spawn_mobs(%{acc | rand: rand}, waypoint, count)
    end)
  end

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

  defp spawn_mobs(world, waypoint, count) do
    Enum.reduce(1..count//1, world, fn _mob, acc ->
      {pos, rand} = free_spot(acc, {waypoint.x, waypoint.y, waypoint.z})

      mob = %{
        id: acc.next_id,
        name: acc.knobs.mob_name,
        pos: pos,
        hp_pct: 100,
        spawn: pos,
        walk_debt_ms: 0,
        bite_debt_ms: 0
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
  def step(world, dt_ms) do
    if broken?(world, :mini_game), do: world, else: run(world, dt_ms)
  end

  defp run(world, dt_ms) do
    world
    |> walk(dt_ms)
    |> follow(dt_ms)
    |> move_mobs(dt_ms)
    |> bite(dt_ms)
    |> Map.update!(:clock, &(&1 + dt_ms))
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
    * `:mini_game` — the capsule is on screen. Every fact freezes, because the
      real feeds skip their captures while it is up: a stale fact during the
      mini-game is not a signal of anything.
    * `{:hp, pct}` — puts the health where the scenario needs it, so a band can
      be reached without waiting to be bitten there.
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
  def revive(world) do
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
        keys: Map.new(world.keys, fn {key, skill} -> {key, %{skill | ready_at: 0}} end)
    }
  end

  # A key on cooldown fires NOTHING — that is the closed loop the whole
  # simulator is worth: the press changes the bar, the bar is what the Combat
  # worker's SkillReceipt confirms against, and a receipt that never arrives is
  # exactly the bug open in the real game today.
  # A fallen pokemon casts nothing: the bar belongs to IT, not to him. Every key
  # pressed between the fall and the revive does nothing — which is most of what
  # makes a revive urgent instead of optional.
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
    ready_at = world.clock + world.knobs.skill_cooldown_ms
    %{world | keys: put_in(world.keys, [key, :ready_at], ready_at)}
  end

  defp damage(world, key, :aoe),
    do: hit(world, world.knobs.aoe_radius, share_of(world, key, world.knobs.aoe_damage))

  defp damage(world, key, :single),
    do: hit(world, 1, share_of(world, key, world.knobs.single_damage))

  defp damage(world, _key, _no_damage), do: world

  # He names the keys that kill; each one carries its share of a whole monster.
  # The division ROUNDS UP on purpose: three keys at 100/3 is 33.333 each, and
  # three presses would leave the monster alive at a ten-billionth of a hit
  # point. This file has already lost tiles to that exact float — it will not
  # lose kills to it as well.
  defp share_of(world, key, fallback) do
    case world.knobs.kill_combo do
      [] -> fallback
      combo -> if key in combo, do: div(100 + length(combo) - 1, length(combo)), else: fallback
    end
  end

  # The area comes out of the POKEMON, not out of him: keys 1-9 are its bar,
  # which is the entire point of calibrating a bar per pokemon. Combined with it
  # trailing two tiles behind, this alone moves where a pile has to be standing
  # for an area skill to be worth pressing.
  defp hit(world, radius, amount) do
    {alive, dead} =
      world.mobs
      |> Enum.map(fn mob ->
        if in_reach?(mob, world.own.pos, radius),
          do: %{mob | hp_pct: mob.hp_pct - amount},
          else: mob
      end)
      |> Enum.split_with(&(&1.hp_pct > 0))

    %{world | mobs: alive, stats: bump(world.stats, :killed, length(dead))}
  end

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

  def observe(world, :mini_game) do
    if broken?(world, :mini_game),
      do: %{playing?: true, confidence: 1.0},
      else: %{playing?: false, confidence: 0.0}
  end

  # Three ways to not be reading the screen, and they are the same fact to every
  # consumer: the knob (a world built blind), the injection (a scenario turning
  # the lights off mid-run), and the mini-game (the feeds skip their captures
  # while the capsule is up, so every fact is frozen, not empty).
  defp unreadable?(world) do
    world.knobs.readable? == false or broken?(world, :blind) or broken?(world, :mini_game)
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
  def reachable?(mob, world), do: in_reach?(mob, world.pos, world.knobs.battle_radius)

  defp visible(world) do
    world.mobs
    |> Enum.filter(&in_reach?(&1, world.pos, world.knobs.battle_radius))
    |> Enum.map(&%{name: &1.name, hp_pct: &1.hp_pct / 100, shiny?: false})
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

  defp advance(world, tiles) do
    heading = heading(world.held)

    Enum.reduce(1..tiles//1, world.pos, fn _tile, pos ->
      one_tile(pos, heading, world.stairs)
    end)
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

    {kept, gone} = Enum.split_with(moved, &(not leashed?(&1, world.knobs.leash_tiles)))

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

  # R2 as physics, not policy: dragged far enough from where it spawned, the mob
  # does not stop and does not turn back — it is GONE. That is what puts a
  # ceiling on greed, and the engine gets to discover it instead of being told.
  defp leashed?(mob, leash_tiles), do: distance(mob.pos, mob.spawn) > leash_tiles

  defp walk_mob(%{pos: {_x, _y, mz}} = mob, %{pos: {_px, _py, pz}}, _dt_ms, _blocked)
       when mz != pz,
       do: mob

  defp walk_mob(mob, world, dt_ms, blocked) do
    target = target_of(mob, world)

    if distance(mob.pos, target) > world.knobs.aggro_tiles do
      mob
    else
      owed = mob.walk_debt_ms + dt_ms
      per_tile = world.knobs.mob_ms_per_tile
      tiles = div(owed, per_tile)

      %{mob | pos: chase(mob.pos, target, tiles, blocked), walk_debt_ms: rem(owed, per_tile)}
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
        own: hurt(world.own, on_pet * world.knobs.bite_dmg),
        player: wound(world.player, on_player * world.knobs.player_bite_dmg)
    }
  end

  # A monster bites whatever it is standing next to: the pokemon while that is
  # what it came for, him once the pokemon is gone.
  defp chew(mob, world, dt_ms) do
    victim = if world.own.out?, do: world.own.pos, else: world.pos

    if in_reach?(mob, victim, 1) do
      owed = mob.bite_debt_ms + dt_ms
      per_bite = world.knobs.bite_every_ms
      {%{mob | bite_debt_ms: rem(owed, per_bite)}, div(owed, per_bite)}
    else
      {%{mob | bite_debt_ms: 0}, 0}
    end
  end

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
