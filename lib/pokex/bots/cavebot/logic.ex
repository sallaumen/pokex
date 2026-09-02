defmodule Pokex.Bots.Cavebot.Logic do
  @moduledoc """
  PURE cavebot state machine, constant-hunt style.

  Combat runs the whole time: the Logic turns it on at startup (`:run_combat` on
  the first tick) and only off when it blocks — the Worker stops everything on
  the first `{:block, _}`. Between waypoints the Logic walks, confirms progress
  by position, yields when an enemy appears, and resumes after sustained clear
  plus dwell.

  Fully pure: no process, clock, screen or Settings — `config` and `now`
  (monotonic ms) come as parameters, which is what makes the whole machine
  testable without the game running.

  States: `:walking` → `:fighting` → `:post_fight` → `:walking`, with detours
  `:stuck` (no walking progress), `:fight_stalled` (fight that won't end) and
  `:blocked` (terminal: floor change or retries exhausted).

  Blindness (unknown position) is NOT a state: holding the step is right, and a
  second of bad reads is routine — turning it into `{:block, _}` would be worse
  than the disease. But it is MARKED in `since[:blind]` and readable via
  `blind_ms/2`: "stopped because I don't know where I am" and "stopped because
  stuck" look identical from outside and must not be.

  A STANDING blind bot, though, would stay blind forever: the client only
  renders the coordinate while the position CHANGES (or under a hovering
  mouse) — so after `blind_kick_ms` of walking-state blindness the machine
  KICKS one `{:nudge, _, _}` toward the waypoint, throttled to one kick per
  interval. Movement is what restores sight.
  """

  alias Pokex.Bots.Cavebot.{Recording, Route}

  @enforce_keys [:route, :config]
  defstruct state: :walking,
            route: nil,
            wp_index: 0,
            combat_running?: false,
            since: %{},
            retries: 0,
            config: nil,
            last_pos: nil,
            last_enemies: nil,
            # the route is ENTERED at the nearest waypoint, once per run
            homed?: false,
            skips: 0,
            # the tile the last skip happened FROM.
            skip_pos: nil,
            # which of this stop's actions already ran — one each, not one per tick
            stops_done: [],
            # how long to let the pile close in HERE, resolved on arrival by
            # `Route.gather_wait/3`: the corner's own ruler, else the route's,
            # else the global number
            gather_wait: nil,
            # where in the ring around a staircase the search is, and how many
            # steps it has actually taken (a ring tile the character already
            # stands on costs a cursor move, never a step)
            probe: 0,
            probe_steps: 0,
            # the previous tick's HP reading: the guard trips on TWO agreeing
            # reads, same rule PlayerSupport uses — one garbage frame must not
            # abort a gathering
            last_hp: nil,
            # o pokémon está NO CHÃO (fainted): a rota espera o revive de chão levantar ele.
            recovering?: false,
            # WHY the last waypoint changed — the Worker turns it into the line
            # that makes a route readable after the fact
            advance: nil,
            # how many taps this staircase has already been given — spent, the
            # ring search gets its turn
            stair_taps: 0

  # Quantas vezes o `fight_timeout_ms` uma luta pode durar esperando cooldown
  # antes de ser chamada de empate assim mesmo. Com os 15s dele, isso dá 90s —
  # dois ciclos inteiros da barra, e o suficiente pra qualquer bolo que ele
  # ainda pretenda matar.
  @stall_slack 6

  @type state ::
          :walking | :fighting | :post_fight | :stuck | :fight_stalled | :stairs | :blocked

  @type action ::
          :none
          | {:walk, integer, integer}
          | :run_combat
          | :halt_combat
          | {:nudge, integer, integer}
          | :cooldown_revive
          | {:park, Route.spot()}
          | {:skills, [Route.skill()]}
          | {:block, atom}

  @type world :: %{
          :pos => {integer, integer, integer} | nil,
          :enemies => non_neg_integer,
          :combat_state => atom,
          :capture_pending => non_neg_integer,
          :capture_changed_at => integer | nil,
          # own pokémon's HP — nil when the bar is unreadable (recalled into
          # the ball, covered) or the :pokemon fact is stale/absent
          :hp_pct => integer | nil,
          :fainted? => boolean,
          # What the engine asks of the road.
          optional(:engine?) => boolean,
          optional(:route_hold?) => boolean,
          optional(:bar_spent?) => boolean,
          optional(:reset_worth?) => boolean | :unknown,
          optional(:reset_note) => String.t() | nil
        }

  @type config :: %{
          optional(:pinned_probe_ms) => non_neg_integer,
          arrival_tolerance: non_neg_integer,
          walk_timeout_ms: non_neg_integer,
          stuck_max_retries: non_neg_integer,
          clear_debounce_ms: non_neg_integer,
          fight_timeout_ms: non_neg_integer,
          post_kill_dwell_ms: non_neg_integer,
          blind_kick_ms: non_neg_integer,
          capture_wait_ms: non_neg_integer,
          stop_wait_ms: non_neg_integer,
          gather_wait_ms: non_neg_integer,
          stair_probe_ms: non_neg_integer,
          stair_max_probes: non_neg_integer,
          stair_step_ms: non_neg_integer,
          stair_step_taps: non_neg_integer,
          fight_only_at_stops: boolean,
          # the hunt's DEFAULT park spot, in tiles from the character — the
          # only pair in here, because it is the only knob that is a place
          park_tiles: {integer, integer} | nil
        }

  @type t :: %__MODULE__{
          state: state,
          route: Route.t(),
          wp_index: non_neg_integer,
          combat_running?: boolean,
          since: %{optional(atom) => integer},
          retries: non_neg_integer,
          config: config,
          last_pos: {integer, integer, integer} | nil,
          skip_pos: {integer, integer, integer} | nil,
          last_enemies: non_neg_integer | nil,
          homed?: boolean,
          skips: non_neg_integer,
          stops_done: [Route.stop()],
          gather_wait: non_neg_integer | nil,
          probe: non_neg_integer,
          probe_steps: non_neg_integer,
          last_hp: integer | nil,
          recovering?: boolean,
          stair_taps: non_neg_integer
        }

  # The ring the search walks around a staircase, in offsets from the recorded
  # corner: the corner itself, then its four sides, then its four diagonals —
  # with the corner between each, because a staircase is TAKEN by stepping onto
  # it, and stepping back off is what makes the next step onto it possible.
  @stair_ring [
    {0, 0},
    {0, -1},
    {0, 0},
    {0, 1},
    {0, 0},
    {-1, 0},
    {0, 0},
    {1, 0},
    {0, 0},
    {-1, -1},
    {0, 0},
    {1, -1},
    {0, 0},
    {-1, 1},
    {0, 0},
    {1, 1}
  ]

  @doc """
  Creates the machine for a route: `state: :walking`, `wp_index: 0`,
  `combat_running?: false`. `config` is stored on the struct.
  """
  @spec new(Route.t(), config) :: t
  def new(%Route{} = route, config) when is_map(config) do
    %__MODULE__{route: route, config: config}
  end

  @doc """
  One tick: takes the observed world and the clock, returns the updated machine
  and ONE action for the Worker to translate.

  Decision order:

  1. `:blocked` is terminal — always `{logic, :none}`.
  2. A position on a floor the route does NOT know blocks in any state:
     `{:block, :floor_changed}`. Safety first.
  3. Startup: with `combat_running?` false, start Combat (`:run_combat`) and
     nothing else this tick.
  4. Dispatch by state.
  """
  @spec step(t, world, integer) :: {t, action}
  def step(%__MODULE__{state: :blocked} = logic, _world, _now), do: {logic, :none}

  # O CÉREBRO DESISTIU DO REVIVE.
  def step(%__MODULE__{} = logic, %{stranded?: true} = world, _now),
    do: {%{track_hp(logic, world) | state: :blocked}, {:block, :revive_dead}}

  # A floor the route KNOWS is a floor it meant to reach — a hunt with stairs is an ordinary
  # hunt (2026-08-10).
  def step(%__MODULE__{} = logic, %{pos: pos} = world, now) when is_tuple(pos) do
    logic = track_hp(logic, world)

    if elem(pos, 2) in Route.floors(logic.route) do
      dispatch(logic, world, now)
    else
      {%{logic | state: :blocked}, {:block, :floor_changed}}
    end
  end

  def step(%__MODULE__{} = logic, world, now), do: dispatch(track_hp(logic, world), world, now)

  # Combat starts only once the hunt knows WHERE IT IS.
  defp dispatch(%__MODULE__{combat_running?: false} = logic, world, now) do
    logic = home_if_sighted(logic, world)

    if logic.homed? or waited_for_sight?(logic, now) do
      {%{logic | combat_running?: true}, :run_combat}
    else
      {blind(logic, now), :none}
    end
  end

  defp dispatch(%__MODULE__{state: :walking} = logic, world, now), do: walk(logic, world, now)
  defp dispatch(%__MODULE__{state: :stuck} = logic, world, now), do: stuck(logic, world, now)
  defp dispatch(%__MODULE__{state: :stairs} = logic, world, now), do: stairs(logic, world, now)
  defp dispatch(%__MODULE__{state: :fighting} = logic, world, now), do: fight(logic, world, now)

  defp dispatch(%__MODULE__{state: :fight_stalled} = logic, world, now),
    do: fight_stalled(logic, world, now)

  defp dispatch(%__MODULE__{state: :post_fight} = logic, world, now),
    do: post_fight(logic, world, now)

  @doc """
  Is the hunt walking a MOB stretch right now?

  The leg being walked is the one LEAVING the previous waypoint — `wp_index` is
  where the character is heading, not where it stands — so arriving at "mobar
  daqui" starts the gathering and arriving at "até aqui" ends it, both on the
  tick of the arrival. Read around the loop, because the route is a loop.

  The Worker turns this into the `:posture` fact Combat obeys; only a `:walking`
  hunt gathers, and a hunt that is fighting or stuck is doing something else.

  Searching for a staircase counts — for ONE lap of the ring. A step usually
  takes two or three probes, and interrupting the gathering for those would
  waste the whole stretch. A full lap without finding it means the hunt is not
  gathering any more, it is stuck at a door: the fire is released, because
  standing still holding it while a pile hits him is the worst of both, and
  because a mob standing ON the step is the commonest reason it cannot be
  taken.
  """
  @spec luring?(t) :: boolean
  def luring?(%__MODULE__{state: :stairs, probe_steps: steps}) when steps > length(@stair_ring),
    do: false

  def luring?(%__MODULE__{state: state, route: %Route{waypoints: waypoints}, wp_index: index})
      when waypoints != [] and state in [:walking, :stairs] do
    Route.lure_leg?(waypoints, Integer.mod(index - 1, length(waypoints)))
  end

  def luring?(%__MODULE__{}), do: false

  @doc """
  Should Combat hold its fire right now?

  His rule, 2026-08-11: "se não tá lutando, ele tá no modo mobado, onde ele não
  deveria atacar NUNCA usando a tecla tab — só quando parar de andar e realmente
  entrar no modo de luta". Every fight is a STOP on the route, so the fire is
  free in exactly one state — `:fighting` — and held everywhere else: walking
  (marked as a gathering or not), searching for a staircase, standing on a stop.
  A hunt walking past a pokémon no longer collects a fight it never chose.

  Holding also outlives the walking: after arriving at "até aqui" the pile is
  still closing in, and hitting the first straggler wastes the gathering
  (`gathering?/2`) — that one applies even in `:fighting`.

  `cavebot_fight_only_at_stops: false` goes back to the old rule, where only a
  marked mob stretch held the fire.
  """
  @spec hold_fire?(t, integer) :: boolean
  def hold_fire?(%__MODULE__{} = logic, now) do
    cond do
      # Survival outranks the huddle: with the pokémon this low, waiting the gather_wait out is
      # exactly the wait that kills it.
      logic.recovering? -> false
      gathering?(logic, now) -> true
      not Map.get(logic.config, :fight_only_at_stops, true) -> luring?(logic)
      true -> logic.state != :fighting
    end
  end

  @doc """
  Is the pile still walking in?

  "Quando termino de mobar, eu geralmente dá quatro segundos até todos os
  bichos se agruparem ao redor do meu para daí eu voltar a mobar e matar todo
  mundo" (Lucas, 2026-08-11). When he stops at "até aqui" the pile is BEHIND
  him, strung out along the way he came — attacking the first one to arrive
  throws away everything the gathering was for. So the fire stays held for
  `gather_wait_ms` after arriving, and THEN the area damage lands on a crowd
  instead of on a straggler.

  The Worker keeps publishing `:hold_fire` while this is true.
  """
  @spec gathering?(t, integer) :: boolean
  def gathering?(%__MODULE__{since: since} = logic, now) do
    case Map.get(since, :gather) do
      nil -> false
      at -> now - at < gather_wait(logic)
    end
  end

  @doc """
  The combo HE recorded at the kill spot the hunt is standing on, as intent
  (consecutive mashing collapsed) — `[]` anywhere else.

  The Worker publishes it with the posture, and Combat fires it the moment the
  fire is released: "quando você fica tentando matar de um em um, ele é
  extremamente mais lento" (Lucas, 2026-08-11). The pile is around the pokémon
  and the area damage has to land on all of it at once.
  """
  @spec combo(t) :: [String.t()]
  def combo(%__MODULE__{since: since} = logic) do
    cond do
      Map.has_key?(since, :gather) -> kill_spot_combo(logic)
      # An aborted gather never reached its kill spot, but the combo he meant
      # for this pile is recorded THERE — publish it so the freed fire opens
      # with the full-mob answer, not one straggler at a time.
      logic.recovering? -> destination_combo(logic)
      true -> []
    end
  end

  defp destination_combo(%__MODULE__{route: %Route{waypoints: []}}), do: []

  defp destination_combo(%__MODULE__{route: %Route{waypoints: waypoints}} = logic) do
    len = length(waypoints)

    0..(len - 1)//1
    |> Enum.map(&Enum.at(waypoints, Integer.mod(logic.wp_index + &1, len)))
    |> Enum.find(&(&1.action == :lure_end))
    |> case do
      nil -> []
      wp -> Recording.combo_intent(wp[:combo] || [])
    end
  end

  defp kill_spot_combo(%__MODULE__{route: %Route{waypoints: []}}), do: []

  defp kill_spot_combo(%__MODULE__{route: %Route{waypoints: waypoints}} = logic) do
    index = Integer.mod(logic.wp_index - 1, length(waypoints))
    Recording.combo_intent(Enum.at(waypoints, index)[:combo] || [])
  end

  @doc """
  The categories HE ordered at the kill spot the hunt is standing on — `[]`
  anywhere else.

  Pair of `combo/1` and delivered by the same road (the `:posture` fact), for a
  reason the `{:skills, _}` action could not solve: there is a burst here, and
  an aura that comes out AFTER the area damage did nothing for anyone.
  Travelling with the posture, Combat builds one list and the Body runs it in
  order — the same solution that made the posture key work.

  Category, never key: whoever has the pokémon on the field is the Worker.
  """
  @spec orders(t) :: [Route.skill()]
  def orders(%__MODULE__{since: since} = logic) do
    if Map.has_key?(since, :gather), do: kill_spot_skills(logic), else: []
  end

  defp kill_spot_skills(%__MODULE__{route: %Route{waypoints: []}}), do: []

  defp kill_spot_skills(%__MODULE__{route: %Route{waypoints: waypoints}} = logic) do
    Route.skills_at(waypoints, Integer.mod(logic.wp_index - 1, length(waypoints)))
  end

  # His ruler, resolved on arrival: the corner, else the route, else the global number
  # (`Route.gather_wait/3`).
  defp gather_wait(%__MODULE__{gather_wait: ms}) when is_integer(ms), do: ms
  defp gather_wait(%__MODULE__{} = logic), do: config_gather_wait(logic)

  defp config_gather_wait(%__MODULE__{config: config}), do: Map.get(config, :gather_wait_ms, 0)

  # Parking the pokémon is the FIRST thing that happens on arrival, before the
  # huddle clock has run: he middle-clicks a spot so the pile closes in around
  # the pokémon instead of around him, and the four seconds are counted from
  # that click. WHERE is the waypoint's business (its own distance, its own
  # recorded click) with the hunt's default distance behind it — and it stays a
  # spec, never a screen point: this module has no calibration and no screen.
  #
  # A kill spot's own skills do NOT come out here: there is a burst to get in
  # front of, so they travel with the posture (`orders/1`) instead.
  defp on_arrival(logic, %{action: :lure_end} = wp) do
    case Route.park_spot(wp, default_park(logic)) do
      nil -> :none
      spot -> {:park, spot}
    end
  end

  # A walking corner carrying skills: the aura he presses himself in the middle
  # of a mob stretch. Nothing is fighting here, so nobody is competing for the
  # keyboard — the order goes out as an action and the Worker taps it. Once per
  # arrival, like every other thing a corner does.
  defp on_arrival(_logic, %{skills: [_ | _] = skills}), do: {:skills, skills}

  defp on_arrival(_logic, _plain_arrival), do: :none

  defp default_park(%__MODULE__{config: config}), do: Map.get(config, :park_tiles)

  # Arriving at "até aqui" starts the huddle clock; arriving anywhere else clears it, so a stale
  # stamp can never hold fire on a plain corner.
  defp arrived(logic, wp, now) when is_map(wp) do
    logic = arrived_at(logic, wp, now)

    %{
      logic
      | stops_done: [],
        stair_taps: 0,
        since: Map.delete(logic.since, :stair_tap)
    }
  end

  defp arrived_at(logic, %{action: :lure_end} = wp, now),
    do: %{
      logic
      | since: Map.put(logic.since, :gather, now),
        gather_wait: Route.gather_wait(logic.route, wp, config_gather_wait(logic))
    }

  defp arrived_at(logic, _plain_corner, _now),
    do: %{logic | since: Map.delete(logic.since, :gather), gather_wait: nil}

  @doc """
  Why the route is held by a pokémon on the FLOOR — `nil` while it is not.

  `hp_pct: nil` inside the wait is the revive itself: the rescue RECALLS the
  pokémon, and a recalled pokémon has no readable bar. Waiting through it is
  the point; the Worker turns this into a visible reason either way.
  """
  @spec recovery(t) :: %{hp_pct: integer | nil} | nil
  def recovery(%__MODULE__{recovering?: true} = logic), do: %{hp_pct: logic.last_hp}
  def recovery(%__MODULE__{}), do: nil

  # ONLY the floor holds the route now: there is nothing on the field, so walking on would drag
  # the character alone into the next pile.
  defp track_hp(%__MODULE__{} = logic, world) do
    %{logic | last_hp: Map.get(world, :hp_pct), recovering?: Map.get(world, :fainted?, false)}
  end

  @doc """
  How many ms the machine has gone without knowing where the character is —
  `nil` while the coordinate is being read. The Worker turns this into a
  visible reason.
  """
  @spec blind_ms(t, integer) :: non_neg_integer | nil
  def blind_ms(%__MODULE__{since: since}, now) do
    case Map.get(since, :blind) do
      nil -> nil
      at -> max(now - at, 0)
    end
  end

  # Gathering: the whole point of a mob stretch is walking THROUGH what shows
  # up, so neither a full battle list nor an engaged Combat stops the leg. The
  # not-attacking half is Combat's, told by the `:posture` fact the Worker
  # publishes — here the hunt simply keeps its feet moving.
  defp walk(logic, world, now) do
    # Enter the route BEFORE judging the leg: until the hunt has homed,
    # `wp_index` is 0 by default and says nothing about where the character
    # actually stands, so a restart inside a mob stretch read the posture off
    # a leg it was not on.
    logic = home_if_sighted(logic, world)

    cond do
      # A mob a bit bigger than the stretch expected: the pokémon is dying UNDER the pile being
      # gathered, and finishing the leg finishes it.
      luring?(logic) and logic.recovering? -> enter_fight(logic, now)
      luring?(logic) -> follow_route(logic, world, now)
      world.enemies > 0 -> enter_fight(logic, now)
      # The COUNT can lie — `enemies` is rows minus presumed scenery, and a stale presumption
      # once swallowed the only real enemy (2026-08-10: fightable read 0 over a
      engaged?(world) -> enter_fight(logic, now)
      # The pokémon is on the FLOOR: walking on drags the character alone into the next pile.
      logic.recovering? -> {hold_patience(logic, now), :none}
      # The ENGINE asking the road to wait.
      Map.get(world, :route_hold?, false) -> {hold_patience(logic, now), :none}
      true -> follow_route(logic, world, now)
    end
  end

  # A deliberate stop does not spend the walk's patience — the same shape as
  # the Worker's frozen clocks under a closed input gate.
  defp hold_patience(logic, now),
    do: %{logic | since: Map.put(logic.since, :walk_progress, now)}

  defp enter_fight(logic, now) do
    since =
      logic.since
      |> Map.delete(:clear)
      |> Map.put(:fight, now)
      # O RELÓGIO QUE NÃO REINICIA.
      |> Map.put_new(:fight_from, now)

    {%{logic | state: :fighting, since: since}, :none}
  end

  # What "engaged" means comes from the Combat snapshot the Worker relays:
  # acquiring a target and holding a lock are both a claim on the road.
  defp engaged?(world), do: Map.get(world, :combat_state) in [:tabbing, :fighting]

  defp home_if_sighted(logic, %{pos: pos}) when is_tuple(pos), do: home_in(logic, pos)
  defp home_if_sighted(logic, _blind), do: logic

  # …but never pacifist FOREVER: a hunt that cannot read its coordinate at all still gets its
  # combat, just late.
  defp waited_for_sight?(%__MODULE__{since: since, config: config}, now) do
    case Map.get(since, :blind) do
      nil -> false
      at -> now - at >= Map.get(config, :blind_kick_ms, 0)
    end
  end

  # Unknown position: hold — never walk FAR blind. MARK the blindness so the
  # Worker can say how long it has lasted, and after blind_kick_ms KICK one
  # step toward the waypoint: the client only draws the coordinate while the
  # position changes, so one moved tile is what brings the reading back.
  defp follow_route(logic, %{pos: nil}, now), do: logic |> blind(now) |> maybe_kick(now)

  defp follow_route(logic, %{pos: {x, y, z} = pos} = world, now) do
    logic = sighted(logic)
    wp = current_wp(logic)
    dx = wp.x - x
    dy = wp.y - y
    tol = logic.config.arrival_tolerance

    # Computed ONCE, because a `cond` cannot bind.
    stair = stair_ahead(logic, pos, wp)
    tap = stair_step_due(logic, stair, now)

    cond do
      # ARRIVING means standing there, floor included: the tile at the top of the stairs has the
      # same x/y as the one at their foot, and "arriving" from below would tick the waypoint off
      # without ever climbing.
      arrived_here?(logic, dx, dy, z, wp, tol) ->
        next =
          chain_past_plain(logic, pos, rem(logic.wp_index + 1, length(logic.route.waypoints)))

        logic = note_progress(logic, pos, now)

        {%{arrived(logic, wp, now) | wp_index: next, skips: 0, advance: :arrived},
         on_arrival(logic, wp)}

      # A staircase is ONE key that moves TWO tiles. Holding the arrow takes the
      # step on the first press and keeps walking on the floor above until the
      # next tick — so this leg taps, waits for the client to answer, and taps
      # again. The ring search below is the NET for the legs his marking left
      # crooked, not the road.
      tap != nil ->
        tap_stair(logic, tap, now)

      # Between taps: the client is still answering the last one, and a second
      # key on top of it is a second staircase.
      waiting_for_step?(logic, stair) ->
        {logic, :none}

      # The right tile on the WRONG floor: the staircase is here somewhere and
      # was not taken. Standing on it asks for nothing — dx and dy are zero —
      # so this used to time out into :stuck and then skip the corner. Search
      # for the step instead. A stair leg whose taps are spent comes here too,
      # however far off the tolerance it is: the marking has extra walking
      # folded into it, and the ring is what finds the step anyway.
      searching_stairs?(stair, dx, dy, z, wp, tol) ->
        stairs(enter_stairs(logic, pos, now), world, now)

      pos != logic.last_pos ->
        {note_progress(logic, pos, now), {:walk, dx, dy}}

      now - Map.get(logic.since, :walk_progress, now) >= walk_timeout(logic, pos) ->
        {%{logic | state: :stuck, retries: 0}, {:walk, dx, dy}}

      true ->
        {logic, {:walk, dx, dy}}
    end
  end

  # How long standing still means "stuck".
  defp walk_timeout(%__MODULE__{skip_pos: pos, config: config}, pos) when pos != nil,
    do: min(config.walk_timeout_ms, Map.get(config, :pinned_probe_ms, 1_000))

  defp walk_timeout(%__MODULE__{config: config}, _pos), do: config.walk_timeout_ms

  # The staircase is only still AHEAD of the character while the floor disagrees with the corner
  # he is heading to.
  defp stair_ahead(_logic, {_x, _y, z}, %{z: z}), do: nil

  defp stair_ahead(logic, {x, y, _z}, _wp) do
    if on_stair_corner?(logic, x, y), do: stair_leg(logic), else: nil
  end

  # Standing on the waypoint the leg LEAVES — the one before the target, same
  # convention as `stair_leg/1`.
  defp on_stair_corner?(%__MODULE__{route: %Route{waypoints: []}}, _x, _y), do: false

  defp on_stair_corner?(%__MODULE__{route: %Route{waypoints: waypoints}, wp_index: index}, x, y) do
    case Enum.at(waypoints, Integer.mod(index - 1, length(waypoints))) do
      %{x: ^x, y: ^y} -> true
      _elsewhere -> false
    end
  end

  # The leg the character is walking RIGHT NOW is the one leaving the waypoint
  # before the target — same convention as `lure_leg?/2`.
  defp stair_leg(%__MODULE__{route: %Route{waypoints: []}}), do: nil

  defp stair_leg(%__MODULE__{route: %Route{waypoints: waypoints}, wp_index: index}) do
    Route.stair_leg(waypoints, Integer.mod(index - 1, length(waypoints)))
  end

  # ONE key toward the step, and the stamp that keeps the next tick from
  # pressing a second one on top of it.
  defp tap_stair(logic, {sx, sy}, now) do
    {%{logic | stair_taps: logic.stair_taps + 1, since: Map.put(logic.since, :stair_tap, now)},
     {:nudge, sx, sy}}
  end

  defp waiting_for_step?(logic, stair),
    do: stair != nil and logic.stair_taps < stair_step_taps(logic)

  # The ring gets its turn on the WRONG floor only: standing off the exact tile
  # with the floor already right is plain walking, not a staircase nobody found.
  defp searching_stairs?(stair, dx, dy, z, wp, tol) do
    z != wp.z and ((abs(dx) <= tol and abs(dy) <= tol) or stair != nil)
  end

  # A tap is due when this leg is a staircase, the taps are not spent, and the
  # client has had `stair_step_ms` to answer the last one.
  defp stair_step_due(logic, stair, now) do
    with {:stair, sx, sy} <- stair,
         true <- logic.stair_taps < stair_step_taps(logic),
         true <- tap_settled?(logic, now) do
      {sx, sy}
    else
      _not_due -> nil
    end
  end

  defp tap_settled?(%__MODULE__{since: since} = logic, now) do
    case Map.get(since, :stair_tap) do
      nil -> true
      at -> now - at >= Map.get(logic.config, :stair_step_ms, 700)
    end
  end

  defp stair_step_taps(%__MODULE__{config: config}),
    do: Map.get(config, :stair_step_taps, 3)

  # Arrival, with the one exception the staircase forces: the corner a stair
  # leaves from is reached EXACTLY, because the tap only works from that tile.
  defp arrived_here?(logic, dx, dy, z, wp, tol) do
    exact? = Route.stair_leg(logic.route.waypoints, logic.wp_index) != nil
    reach = if exact?, do: 0, else: tol

    abs(dx) <= reach and abs(dy) <= reach and wp.z == z
  end

  # Corners the character is ALREADY standing on, taken in one tick instead of one each.
  defp chain_past_plain(logic, pos, index), do: chain_past_plain(logic, pos, index, 0)

  defp chain_past_plain(logic, _pos, index, hops)
       when hops >= length(logic.route.waypoints),
       do: index

  defp chain_past_plain(logic, {x, y, z} = pos, index, hops) do
    tol = logic.config.arrival_tolerance
    wp = Enum.at(logic.route.waypoints, index)

    if plain?(wp) and wp.z == z and abs(wp.x - x) <= tol and abs(wp.y - y) <= tol do
      next = rem(index + 1, length(logic.route.waypoints))
      chain_past_plain(logic, pos, next, hops + 1)
    else
      index
    end
  end

  # `park_tiles` conta como marca pelo mesmo motivo do `park_point`: os dois são "o pokémon fica
  # AQUI", só ditos em línguas diferentes — e uma esquina com a
  defp plain?(%{action: :walk} = wp),
    do: Map.get(wp, :stops, []) == [] and wp[:park_point] == nil and wp[:park_tiles] == nil

  defp plain?(_marked), do: false

  # A hunt does not begin at waypoint 1: it begins at the CLOSEST corner of the route.
  defp home_in(%__MODULE__{homed?: true} = logic, _pos), do: logic

  defp home_in(logic, {x, y, z}) do
    # Only corners on THIS floor: tile distance across floors is a number with
    # no meaning, and entering at a waypoint one floor up sends the character
    # walking into a wall that is actually a ceiling.
    nearest =
      logic.route.waypoints
      |> Enum.with_index()
      |> Enum.filter(fn {wp, _index} -> wp.z == z end)
      |> Enum.min_by(fn {wp, _index} -> abs(wp.x - x) + abs(wp.y - y) end, fn -> nil end)

    case nearest do
      {_wp, index} -> %{logic | wp_index: index, homed?: true, advance: :homed}
      nil -> %{logic | homed?: true}
    end
  end

  # Searching for the step. Entering resets the ring AND the clock, so a search
  # interrupted by a fight starts over instead of resuming three probes from
  # giving up.
  #
  # `probe_steps` is the half that actually decides giving up (`stairs/3` blocks
  # on it), so leaving it behind made the comment a lie: the cursor restarted
  # while the budget resumed, and `{:block, :stairs}` fired well before the 32
  # probes `cavebot_stair_max_probes` documents.
  defp enter_stairs(logic, pos, now) do
    %{
      note_progress(logic, pos, now)
      | state: :stairs,
        probe: 0,
        probe_steps: 0,
        stair_taps: 0,
        since: Map.drop(logic.since, [:probe, :stair_tap])
    }
  end

  # A staircase is taken by STEPPING on it, and the corner the recording left behind is where he
  # LANDED — which on the floor above may be the step, or beside it,
  defp stairs(logic, %{pos: nil}, now), do: {blind(logic, now), :none}

  defp stairs(logic, %{pos: {_x, _y, z} = pos} = world, now) do
    logic = sighted(logic)
    wp = current_wp(logic)

    cond do
      # the step was found: the position itself says so
      z == wp.z ->
        walk(%{logic | state: :walking, retries: 0, probe: 0, probe_steps: 0}, world, now)

      search_interrupted?(logic, world) ->
        enter_fight(logic, now)

      # recovering, and nothing came: stand still until the support fixes it
      logic.recovering? ->
        {logic, :none}

      logic.probe_steps >= stair_max_probes(logic) ->
        {%{logic | state: :blocked}, {:block, :stairs}}

      not probe_due?(logic, now) ->
        {logic, :none}

      true ->
        probe_stairs(logic, pos, wp, now)
    end
  end

  # What ENDS the staircase search and sends the machine to fight, in the two
  # moods it can be in. Recovering, the abandon rule of the walking state
  # applies — a dying pokémon ends the search, and even a mob leg counts,
  # because standing in a gathering with no health is how it dies. Healthy, a
  # mob leg walks THROUGH what shows up, so only an unlured fight interrupts.
  #
  # One predicate rather than three `cond` arms: the two moods answer the same
  # question and used to be spelled out separately, which is what pushed this
  # function past its complexity budget when the two were merged.
  defp search_interrupted?(logic, world) do
    fight? = world.enemies > 0 or engaged?(world)

    if logic.recovering?,
      do: fight? or luring?(logic),
      else: fight? and not luring?(logic)
  end

  defp probe_due?(%__MODULE__{since: since} = logic, now) do
    case Map.get(since, :probe) do
      nil -> true
      at -> now - at >= Map.get(logic.config, :stair_probe_ms, 400)
    end
  end

  defp stair_max_probes(%__MODULE__{config: config}),
    do: Map.get(config, :stair_max_probes, 32)

  # ONE tile toward the ring's current tile. A probe whose tile is the one the
  # character already stands on is not a step — it is skipped, never issued as
  # `{:nudge, 0, 0}`, which the Body would turn into no key at all.
  defp probe_stairs(logic, pos, wp, now, hops \\ 0)

  defp probe_stairs(logic, _pos, _wp, _now, hops) when hops >= length(@stair_ring),
    do: {logic, :none}

  defp probe_stairs(logic, {x, y, _z} = pos, wp, now, hops) do
    {ox, oy} = Enum.at(@stair_ring, Integer.mod(logic.probe, length(@stair_ring)))
    logic = %{logic | probe: logic.probe + 1}

    case {wp.x + ox - x, wp.y + oy - y} do
      {0, 0} ->
        probe_stairs(logic, pos, wp, now, hops + 1)

      {dx, dy} ->
        {sx, sy} = one_tile(dx, dy)
        logic = %{logic | probe_steps: logic.probe_steps + 1}
        {%{logic | since: Map.put(logic.since, :probe, now)}, {:nudge, sx, sy}}
    end
  end

  defp stuck(logic, %{pos: nil}, now), do: {blind(logic, now), :none}

  defp stuck(logic, %{pos: pos} = world, now) do
    logic = sighted(logic)

    if pos != logic.last_pos do
      # Moving again: resume the route with retries reset.
      walk(%{logic | state: :walking, retries: 0}, world, now)
    else
      retries = logic.retries + 1

      cond do
        # Stuck on the very tile the last skip gave up FROM: the corner was never the problem,
        # the CHARACTER cannot move — the full round of nudges already ran from this exact tile
        # and moved nothing.
        logic.skip_pos == pos ->
          {%{logic | state: :blocked}, {:block, :pinned}}

        retries <= logic.config.stuck_max_retries ->
          {dx, dy} = unstick(logic, pos, retries)
          {%{logic | retries: retries}, {:walk, dx, dy}}

        # A corner on ANOTHER floor is never skipped.
        crossing_floor?(logic, pos) ->
          {%{logic | state: :blocked}, {:block, :stairs}}

        # A corner walled on every side is not the end of the hunt: the route
        # is a LOOP, and the next corner is usually reachable from here. Only a
        # full lap of unreachable corners means the character is somewhere the
        # route cannot describe.
        logic.skips < length(logic.route.waypoints) - 1 ->
          {skip_waypoint(logic, pos, now), :none}

        true ->
          {%{logic | state: :blocked}, {:block, :stuck}}
      end
    end
  end

  defp crossing_floor?(logic, {_x, _y, z}) do
    case current_wp(logic) do
      %{z: target} -> target != z
      _no_waypoint -> false
    end
  end

  # Giving up on a corner is LEAVING it, so everything that belongs to it goes out with it — the
  # same thing `arrived_at/3` does on a plain corner.
  defp skip_waypoint(logic, pos, now) do
    next = rem(logic.wp_index + 1, length(logic.route.waypoints))

    %{
      logic
      | state: :walking,
        wp_index: next,
        advance: :skipped,
        retries: 0,
        skips: logic.skips + 1,
        skip_pos: pos,
        last_pos: nil,
        gather_wait: nil,
        stair_taps: 0,
        probe_steps: 0,
        stops_done: Route.stops(),
        since: logic.since |> Map.drop([:gather, :stair_tap]) |> Map.put(:walk_progress, now)
    }
  end

  # Screen clear AND Combat disengaged: sustain the debounce before declaring the fight over.
  defp fight(logic, world, now) do
    cond do
      clear?(world) -> stand_and_fight(logic, world, now)
      retreat_ordered?(world) -> retreat(fight_clocks(logic, world, now), world, now)
      walk_ordered?(world) -> follow_route(fight_clocks(logic, world, now), world, now)
      true -> stand_and_fight(logic, world, now)
    end
  end

  defp retreat_ordered?(world),
    do: Map.get(world, :engine?, false) and Map.get(world, :route_back?, false)

  # A RETIRADA: UM waypoint pra trás, e o índice da rota NÃO se mexe.
  defp retreat(logic, %{pos: nil}, _now), do: {logic, :none}

  defp retreat(logic, %{pos: {x, y, z}}, now) do
    count = length(logic.route.waypoints)
    prev_index = rem(logic.wp_index - 1 + count, count)
    wp = Enum.at(logic.route.waypoints, prev_index)
    tol = logic.config.arrival_tolerance

    cond do
      wp == nil or wp.z != z ->
        {logic, :none}

      # Chegou no anterior: acabou o recuo. Nada de encadear pro anterior dele,
      # e o índice fica onde estava — a rota tem um sentido só.
      abs(wp.x - x) <= tol and abs(wp.y - y) <= tol ->
        {note_progress(logic, {x, y, z}, now), :none}

      true ->
        {note_progress(logic, {x, y, z}, now), {:walk, wp.x - x, wp.y - y}}
    end
  end

  defp clear?(world), do: Map.get(world, :enemies) == 0 and not engaged?(world)

  # A ordem é uma só e vem com idade: `route_hold?` é `false` tanto quando o
  # cérebro manda andar quanto quando não há cérebro nenhum, e as duas coisas
  # não podem se parecer. `engine?` é o que separa.
  defp walk_ordered?(world),
    do: Map.get(world, :engine?, false) and not Map.get(world, :route_hold?, false)

  # ANDANDO, o relógio do travamento não corre — e não é descuido. Ele mede uma
  # luta que não sai do lugar, e quem está andando tem outro guarda: o da rota,
  # que já reclama de um pé que não anda (`:stuck`). Deixar os dois correrem
  # juntos fazia a caçada ser declarada travada por estar fazendo exatamente o
  # que foi mandada fazer.
  #
  # Zerado, e não pausado: quando o cérebro parar a estrada, a janela do
  # travamento começa do instante em que ela realmente parou.
  # `:clear` sai junto, e por um motivo próprio: só se chega aqui com bicho na
  # tela (ou sem leitura), e uma tela com bicho não está limpa. Um carimbo velho
  # sobrevivia à caminhada inteira, e então um tique curto de `:hold` com a tela
  # limpa caía direto em `:post_fight` numa esquina arbitrária — `next_stop/1`
  # lê `wp_index - 1`, a esquina onde ela por acaso está, não onde a pilha
  # morreu.
  defp fight_clocks(logic, world, _now) do
    %{
      logic
      | since: logic.since |> Map.delete(:fight) |> Map.delete(:clear),
        last_enemies: Map.get(world, :enemies)
    }
  end

  defp stand_and_fight(logic, %{enemies: 0} = world, now) do
    if engaged?(world), do: fight_on(logic, 0, world, now), else: fight_clear(logic, now)
  end

  defp stand_and_fight(logic, %{enemies: enemies} = world, now),
    do: fight_on(logic, enemies, world, now)

  defp fight_clear(logic, now) do
    logic = %{logic | last_enemies: 0}

    case Map.get(logic.since, :clear) do
      nil ->
        {%{logic | since: Map.put(logic.since, :clear, now)}, :none}

      clear_since ->
        if now - clear_since >= logic.config.clear_debounce_ms do
          since =
            logic.since
            |> Map.drop([:clear, :fight])
            |> Map.put(:dwell, now)

          {%{logic | state: :post_fight, since: since}, :none}
        else
          {logic, :none}
        end
    end
  end

  # Enemy still alive: reset the clear and watch the fight timeout — but the timeout measures a
  # fight going NOWHERE, not a fight taking long.
  defp fight_on(logic, enemies, world, now) do
    since = Map.delete(logic.since, :clear)
    progress? = logic.last_enemies != nil and logic.last_enemies != enemies
    logic = %{logic | last_enemies: enemies}

    case Map.get(since, :fight) do
      fight_since when fight_since != nil and not progress? ->
        stall_or_wait(logic, since, fight_since, world, now)

      _fresh_or_progressing ->
        {%{logic | since: Map.put(since, :fight, now)}, :none}
    end
  end

  # ESPERAR COOLDOWN NÃO É TRAVAR.
  defp stall_or_wait(logic, since, fight_since, world, now) do
    cond do
      now - fight_since < logic.config.fight_timeout_ms ->
        {%{logic | since: since}, :none}

      esperando_cooldown?(logic, since, world, now) ->
        {%{logic | since: Map.put(since, :fight, now)}, :none}

      true ->
        {%{logic | state: :fight_stalled, since: since, retries: 0}, :none}
    end
  end

  # O cérebro diz que a barra está gasta, e a luta ainda cabe no teto duro.
  defp esperando_cooldown?(logic, since, world, now) do
    dentro_do_teto? =
      case Map.get(since, :fight_from) do
        nil -> true
        from -> now - from < logic.config.fight_timeout_ms * @stall_slack
      end

    Map.get(world, :bar_spent?, false) and dentro_do_teto?
  end

  # Arrow walking does NOT pathfind: the client routed around obstacles when
  # the step was a minimap click, and one key press just walks into the wall.
  # Repeating the same direction burns the retries and blocks the hunt at the
  # first corner, so a stuck retry SLIDES: odd retries drop the axis that is
  # stuck and push the other one (the classic wall-follow), even retries try
  # the straight line again in case the obstacle moved — a player standing in
  # the way is the common case, and it walks off on its own.
  defp unstick(logic, {x, y, _z}, retries) do
    wp = current_wp(logic)
    {dx, dy} = {wp.x - x, wp.y - y}

    cond do
      rem(retries, 2) == 0 -> {dx, dy}
      abs(dx) >= abs(dy) and dy != 0 -> {0, dy}
      abs(dy) > abs(dx) and dx != 0 -> {dx, 0}
      # Single-axis leg: the wall is ON the axis, and "keep pushing" was four presses into the
      # same bricks.
      dx == 0 -> {sidestep(retries), 0}
      true -> {0, sidestep(retries)}
    end
  end

  # retries 1, 3 are the odd (sliding) rounds: first one side, then the other.
  defp sidestep(retries), do: if(rem(retries, 4) == 1, do: 1, else: -1)

  # The nudge exists to unstick a fight that won't end — so it must MOVE the
  # character. `{:nudge, 0, 0}` didn't: the Worker translates a nudge into
  # `Body.arrow_step/3` (a TAP of one arrow key, after letting go of whatever
  # was held — minimap clicks are retired), and (0,0) is no direction, so no key
  # is pressed at all. A guaranteed no-op that burned the retries into
  # `{:block, :fight_stalled}` without ever trying anything.
  defp fight_stalled(logic, world, _now) do
    retries = logic.retries + 1

    if retries > logic.config.stuck_max_retries do
      {%{logic | state: :blocked}, {:block, :fight_stalled}}
    else
      {dx, dy} = nudge_step(logic, world)
      {%{logic | retries: retries}, {:nudge, dx, dy}}
    end
  end

  # ONE tile toward the current waypoint. Without a position read — or already
  # on the waypoint — tie-break on the x axis: any direction works, (0,0) doesn't.
  defp nudge_step(logic, %{pos: {x, y, _}}) do
    wp = current_wp(logic)
    one_tile(wp.x - x, wp.y - y)
  end

  defp nudge_step(_logic, _world), do: {1, 0}

  defp one_tile(0, 0), do: {1, 0}
  defp one_tile(dx, dy), do: {sign(dx), sign(dy)}

  defp sign(0), do: 0
  defp sign(n) when n > 0, do: 1
  defp sign(_n), do: -1

  defp maybe_kick(logic, now) do
    interval = logic.config.blind_kick_ms
    blind_for = now - Map.fetch!(logic.since, :blind)

    # nil check, never a 0 sentinel: the monotonic clock can be NEGATIVE.
    kick_due? =
      case Map.get(logic.since, :kick) do
        nil -> true
        at -> now - at >= interval
      end

    if blind_for >= interval and kick_due? do
      {%{logic | since: Map.put(logic.since, :kick, now)}, kick_nudge(logic)}
    else
      {logic, :none}
    end
  end

  defp kick_nudge(logic) do
    wp = current_wp(logic)

    case logic.last_pos do
      {x, y, _z} ->
        {dx, dy} = one_tile(wp.x - x, wp.y - y)
        {:nudge, dx, dy}

      nil ->
        {:nudge, 1, 0}
    end
  end

  # The corpse belongs to the CAPTURE, and picking one up is seconds of Body
  # time against a 1.2s dwell: resuming the route on the clock alone walked
  # away mid-catch and made both workers fight over the same hands. So the
  # dwell ends when the Catcher has nothing queued — capped, because a stuck
  # Catcher must never freeze the hunt.
  defp post_fight(logic, world, now) do
    dwell_since = Map.get(logic.since, :dwell, now)

    cond do
      # A mob walking in during the stop is a FIGHT, not something to push
      # through: the revive RECALLS the pokémon, and doing that while
      # something is hitting it is the worst possible moment. What already ran
      # stays done — the stop picks up where it left off once the screen is
      # clear again.
      world.enemies > 0 or engaged?(world) -> enter_fight(logic, now)
      capturing?(world, now, logic.config.capture_wait_ms) -> {logic, :none}
      standing_by?(logic, now) -> {logic, :none}
      next_stop(logic) -> run_stop(logic, next_stop(logic), world, now)
      # The stops above still ran — a :cooldown_revive IS the recovery — but the route does not
      # resume until the pokémon is back on its feet: the next leg is the next
      logic.recovering? -> {logic, :none}
      true -> resume_after_dwell(logic, dwell_since, now)
    end
  end

  # What this waypoint asks for, minus what already ran, in the canonical
  # order — see `Route.stop/0`. The waypoint that decides is the one the hunt
  # last REACHED (the pile it gathered died right there), same convention as
  # the mob stretch.
  defp next_stop(%__MODULE__{route: %Route{waypoints: []}}), do: nil

  defp next_stop(%__MODULE__{route: %Route{waypoints: waypoints}} = logic) do
    wanted = Route.stops_at(waypoints, Integer.mod(logic.wp_index - 1, length(waypoints)))

    Enum.find(Route.stops(), &(&1 in wanted and &1 not in logic.stops_done))
  end

  # Reviving resets every cooldown: the fastest way back to a full bar is to recall the pokémon
  # and bring it back, not to stand still waiting.
  defp run_stop(logic, :cooldown_revive, world, now) do
    done = mark_done(logic, :cooldown_revive, nil, now)

    case Map.get(world, :reset_worth?, :unknown) do
      false -> {done, {:skip_reset, Map.get(world, :reset_note)}}
      _worth_it_or_unknown -> {done, :cooldown_revive}
    end
  end

  defp run_stop(logic, :wait, _world, now) do
    {mark_done(logic, :wait, :stop_wait, now), :none}
  end

  defp mark_done(logic, stop, since_key, now) do
    since = if since_key, do: Map.put(logic.since, since_key, now), else: logic.since
    %{logic | stops_done: [stop | logic.stops_done], since: since}
  end

  # The plain wait: seconds standing still, which is what cooldowns need when
  # there is no revive to short-circuit them.
  defp standing_by?(logic, now) do
    case Map.get(logic.since, :stop_wait) do
      nil -> false
      at -> now - at < logic.config.stop_wait_ms
    end
  end

  # Waiting on a queue that is not MOVING is waiting forever: a corpse the
  # Catcher gave up on never leaves the count. So the hunt waits while the
  # queue is non-empty AND still changing — the same rule that told a long
  # fight from a stalled one.
  defp capturing?(world, now, wait_ms) do
    pending = Map.get(world, :capture_pending, 0)
    changed_at = Map.get(world, :capture_changed_at)

    pending > 0 and changed_at != nil and now - changed_at < wait_ms
  end

  defp resume_after_dwell(logic, dwell_since, now) do
    if now - dwell_since >= logic.config.post_kill_dwell_ms do
      since =
        logic.since
        |> Map.drop([:dwell, :stop_wait])
        |> Map.put(:walk_progress, now)

      # `stops_done` is NOT cleared here: it belongs to the WAYPOINT, not to this episode.
      {%{logic | state: :walking, since: since, last_pos: nil}, :none}
    else
      {logic, :none}
    end
  end

  defp current_wp(logic), do: Enum.at(logic.route.waypoints, logic.wp_index)

  # Progress is also the proof the character CAN move, so it clears the pinned
  # alert a skip leaves behind — but only REAL progress: a skip wipes
  # `last_pos`, so the first tick after one lands here without a tile walked,
  # and the alert must survive exactly while he still stands where he skipped.
  defp note_progress(logic, pos, now) do
    since = logic.since |> Map.put(:walk_progress, now) |> Map.delete(:step)
    skip_pos = if pos == logic.skip_pos, do: logic.skip_pos, else: nil
    %{logic | last_pos: pos, skip_pos: skip_pos, since: since}
  end

  # The blindness clock marks the FIRST read without a position and does not
  # restart on later ticks — total time in the dark is what matters.
  defp blind(%__MODULE__{since: since} = logic, now) do
    if Map.has_key?(since, :blind),
      do: logic,
      else: %{logic | since: Map.put(since, :blind, now)}
  end

  defp sighted(%__MODULE__{since: since} = logic) do
    if Map.has_key?(since, :blind),
      do: %{logic | since: Map.drop(since, [:blind, :kick])},
      else: logic
  end
end
