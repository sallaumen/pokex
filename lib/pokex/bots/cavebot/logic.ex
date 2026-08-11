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
            # which of this stop's actions already ran — one each, not one per tick
            stops_done: [],
            # how long to let the pile close in HERE: his own measured pause
            # when the recording caught it, the configured default otherwise
            gather_wait: nil

  @type state :: :walking | :fighting | :post_fight | :stuck | :fight_stalled | :blocked

  @type action ::
          :none
          | {:walk, integer, integer}
          | :run_combat
          | :halt_combat
          | {:nudge, integer, integer}
          | {:sweep, {integer, integer} | nil}
          | :cooldown_revive
          | {:park, {integer, integer}}
          | {:block, atom}

  @type world :: %{
          pos: {integer, integer, integer} | nil,
          enemies: non_neg_integer,
          combat_state: atom,
          capture_pending: non_neg_integer,
          capture_changed_at: integer | nil,
          sweep_pending: non_neg_integer,
          sweep_changed_at: integer | nil
        }

  @type config :: %{
          arrival_tolerance: non_neg_integer,
          walk_timeout_ms: non_neg_integer,
          stuck_max_retries: non_neg_integer,
          clear_debounce_ms: non_neg_integer,
          fight_timeout_ms: non_neg_integer,
          post_kill_dwell_ms: non_neg_integer,
          blind_kick_ms: non_neg_integer,
          capture_wait_ms: non_neg_integer,
          sweep_grace_ms: non_neg_integer,
          stop_wait_ms: non_neg_integer,
          gather_wait_ms: non_neg_integer
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
          last_enemies: non_neg_integer | nil,
          homed?: boolean,
          skips: non_neg_integer,
          stops_done: [Route.stop()],
          gather_wait: non_neg_integer | nil
        }

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

  # A floor the route KNOWS is a floor it meant to reach — a hunt with stairs
  # is an ordinary hunt (2026-08-10). Any OTHER floor is what this guard was
  # always really about: a hole, a teleport, a character somewhere the route
  # cannot describe.
  def step(%__MODULE__{} = logic, %{pos: pos} = world, now) when is_tuple(pos) do
    if elem(pos, 2) in Route.floors(logic.route) do
      dispatch(logic, world, now)
    else
      {%{logic | state: :blocked}, {:block, :floor_changed}}
    end
  end

  def step(%__MODULE__{} = logic, world, now), do: dispatch(logic, world, now)

  defp dispatch(%__MODULE__{combat_running?: false} = logic, _world, _now) do
    {%{logic | combat_running?: true}, :run_combat}
  end

  defp dispatch(%__MODULE__{state: :walking} = logic, world, now), do: walk(logic, world, now)
  defp dispatch(%__MODULE__{state: :stuck} = logic, world, now), do: stuck(logic, world, now)
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
  """
  @spec luring?(t) :: boolean
  def luring?(%__MODULE__{state: :walking, route: %Route{waypoints: waypoints}, wp_index: index})
      when waypoints != [] do
    Route.lure_leg?(waypoints, Integer.mod(index - 1, length(waypoints)))
  end

  def luring?(%__MODULE__{}), do: false

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
    if Map.has_key?(since, :gather), do: kill_spot_combo(logic), else: []
  end

  defp kill_spot_combo(%__MODULE__{route: %Route{waypoints: []}}), do: []

  defp kill_spot_combo(%__MODULE__{route: %Route{waypoints: waypoints}} = logic) do
    index = Integer.mod(logic.wp_index - 1, length(waypoints))
    Recording.combo_intent(Enum.at(waypoints, index)[:combo] || [])
  end

  defp gather_wait(%__MODULE__{gather_wait: measured}) when is_integer(measured), do: measured
  defp gather_wait(%__MODULE__{config: config}), do: Map.get(config, :gather_wait_ms, 0)

  # Parking the pokémon is the FIRST thing that happens on arrival, before the
  # huddle clock has run: he middle-clicks a spot so the pile closes in around
  # the pokémon instead of around him, and the four seconds are counted from
  # that click.
  defp on_arrival(%{action: :lure_end, park_point: {_x, _y} = point}), do: {:park, point}
  defp on_arrival(_plain_arrival), do: :none

  # Arriving at "até aqui" starts the huddle clock; arriving anywhere else
  # clears it, so a stale stamp can never hold fire on a plain corner.
  # His own measured pause wins over the configured one: the recording watched
  # him park the pokémon and counted to his first skill, which is the real
  # answer for THIS spot ("quatro segundos" was his estimate of it).
  defp arrived(logic, %{action: :lure_end} = wp, now),
    do: %{logic | since: Map.put(logic.since, :gather, now), gather_wait: wp[:gather_ms]}

  defp arrived(logic, _plain_corner, _now),
    do: %{logic | since: Map.delete(logic.since, :gather), gather_wait: nil}

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
      luring?(logic) -> follow_route(logic, world, now)
      world.enemies > 0 -> enter_fight(logic, now)
      # The COUNT can lie — `enemies` is rows minus presumed scenery, and a
      # stale presumption once swallowed the only real enemy (2026-08-10:
      # fightable read 0 over a live lock, and the hunt strolled off
      # mid-fight) — but an engaged Combat cannot: :tabbing/:fighting hold the
      # road, whatever the subtraction says.
      engaged?(world) -> enter_fight(logic, now)
      true -> follow_route(logic, world, now)
    end
  end

  defp enter_fight(logic, now) do
    since = logic.since |> Map.delete(:clear) |> Map.put(:fight, now)
    {%{logic | state: :fighting, since: since}, :none}
  end

  # What "engaged" means comes from the Combat snapshot the Worker relays:
  # acquiring a target and holding a lock are both a claim on the road.
  defp engaged?(world), do: Map.get(world, :combat_state) in [:tabbing, :fighting]

  defp home_if_sighted(logic, %{pos: pos}) when is_tuple(pos), do: home_in(logic, pos)
  defp home_if_sighted(logic, _blind), do: logic

  # Unknown position: hold — never walk FAR blind. MARK the blindness so the
  # Worker can say how long it has lasted, and after blind_kick_ms KICK one
  # step toward the waypoint: the client only draws the coordinate while the
  # position changes, so one moved tile is what brings the reading back.
  defp follow_route(logic, %{pos: nil}, now), do: logic |> blind(now) |> maybe_kick(now)

  defp follow_route(logic, %{pos: {x, y, z} = pos}, now) do
    logic = sighted(logic)
    wp = current_wp(logic)
    dx = wp.x - x
    dy = wp.y - y
    tol = logic.config.arrival_tolerance

    cond do
      # ARRIVING means standing there, floor included: the tile at the top of
      # the stairs has the same x/y as the one at their foot, and "arriving"
      # from below would tick the waypoint off without ever climbing.
      abs(dx) <= tol and abs(dy) <= tol and wp.z == z ->
        next = rem(logic.wp_index + 1, length(logic.route.waypoints))
        logic = note_progress(logic, pos, now)
        {%{arrived(logic, wp, now) | wp_index: next, skips: 0}, on_arrival(wp)}

      pos != logic.last_pos ->
        {note_progress(logic, pos, now), {:walk, dx, dy}}

      now - Map.get(logic.since, :walk_progress, now) >= logic.config.walk_timeout_ms ->
        {%{logic | state: :stuck, retries: 0}, {:walk, dx, dy}}

      true ->
        {logic, {:walk, dx, dy}}
    end
  end

  # A hunt does not begin at waypoint 1: it begins at the CLOSEST corner of the
  # route. Restarting mid-route used to send the character back to the first
  # waypoint — across the map, through walls it cannot path around with arrow
  # keys (Lucas, 2026-08-10: "voltou pro começo e travou numa parede"). Done
  # once per run, on the first sighting.
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
      {_wp, index} -> %{logic | wp_index: index, homed?: true}
      nil -> %{logic | homed?: true}
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
        retries <= logic.config.stuck_max_retries ->
          {dx, dy} = unstick(logic, pos, retries)
          {%{logic | retries: retries}, {:walk, dx, dy}}

        # A corner walled on every side is not the end of the hunt: the route
        # is a LOOP, and the next corner is usually reachable from here. Only a
        # full lap of unreachable corners means the character is somewhere the
        # route cannot describe.
        logic.skips < length(logic.route.waypoints) - 1 ->
          {skip_waypoint(logic, now), :none}

        true ->
          {%{logic | state: :blocked}, {:block, :stuck}}
      end
    end
  end

  defp skip_waypoint(logic, now) do
    next = rem(logic.wp_index + 1, length(logic.route.waypoints))

    %{
      logic
      | state: :walking,
        wp_index: next,
        retries: 0,
        skips: logic.skips + 1,
        last_pos: nil,
        since: Map.put(logic.since, :walk_progress, now)
    }
  end

  # Screen clear AND Combat disengaged: sustain the debounce before declaring
  # the fight over. Clear rows alone are not enough — see `engaged?/1`: a held
  # lock is a live fight the count cannot see, and the debounce must not even
  # start under one.
  defp fight(logic, %{enemies: 0} = world, now) do
    if engaged?(world), do: fight_on(logic, 0, now), else: fight_clear(logic, now)
  end

  defp fight(logic, %{enemies: enemies}, now), do: fight_on(logic, enemies, now)

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

  # Enemy still alive: reset the clear and watch the fight timeout — but the
  # timeout measures a fight going NOWHERE, not a fight taking long. Lucas's
  # first real hunt (2026-08-10) died right here: combat killed its target and
  # said "caçando o próximo", the spot had more pokémon, and 20 seconds of
  # honest work were declared "a luta não termina" — the hunt blocked while
  # everything else was working. A changing enemy count IS progress (one died,
  # or one arrived), so it restarts the clock; only a screen that stays
  # identical for the whole timeout is a stall.
  defp fight_on(logic, enemies, now) do
    since = Map.delete(logic.since, :clear)
    progress? = logic.last_enemies != nil and logic.last_enemies != enemies
    logic = %{logic | last_enemies: enemies}

    case Map.get(since, :fight) do
      fight_since when fight_since != nil and not progress? ->
        stall_or_wait(logic, since, fight_since, now)

      _fresh_or_progressing ->
        {%{logic | since: Map.put(since, :fight, now)}, :none}
    end
  end

  defp stall_or_wait(logic, since, fight_since, now) do
    if now - fight_since >= logic.config.fight_timeout_ms do
      {%{logic | state: :fight_stalled, since: since, retries: 0}, :none}
    else
      {%{logic | since: since}, :none}
    end
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
      # single-axis route leg: nothing to slide onto, keep pushing
      true -> {dx, dy}
    end
  end

  # The nudge exists to unstick a fight that won't end — so it must MOVE the
  # character. `{:nudge, 0, 0}` didn't: the Worker translates a nudge into
  # `Body.minimap_step/3`, which clicks the minimap center — the tile the
  # character already occupies. A guaranteed no-op that burned the retries into
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

  # The corpse belongs to the CAPTURE, and a sweep is seconds of Body time
  # against a 1.2s dwell: resuming the route on the clock alone walked away
  # mid-catch and made both workers fight over the same hands. So the dwell
  # ends when the Catcher has nothing queued — capped, because a stuck Catcher
  # must never freeze the hunt.
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
      sweeping?(logic, world, now) -> {logic, :none}
      standing_by?(logic, now) -> {logic, :none}
      next_stop(logic) -> run_stop(logic, next_stop(logic), now)
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

  # The sweep is centred where the corpses ARE: after a gathered fight they lie
  # around the tile the pokémon was parked on, several tiles from him.
  defp run_stop(logic, :sweep, now) do
    {mark_done(logic, :sweep, :sweep, now), {:sweep, park_point(logic)}}
  end

  # Reviving resets every cooldown: the fastest way back to a full bar is to
  # recall the pokémon and bring it back, not to stand still waiting.
  defp run_stop(logic, :cooldown_revive, now) do
    {mark_done(logic, :cooldown_revive, nil, now), :cooldown_revive}
  end

  defp run_stop(logic, :wait, now) do
    {mark_done(logic, :wait, :stop_wait, now), :none}
  end

  defp park_point(%__MODULE__{route: %Route{waypoints: []}}), do: nil

  defp park_point(%__MODULE__{route: %Route{waypoints: waypoints}} = logic) do
    index = Integer.mod(logic.wp_index - 1, length(waypoints))
    Enum.at(waypoints, index)[:park_point]
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

  # Waiting on the sweep follows the same rule as waiting on the capture: a
  # queue that is not MOVING is a queue nobody is working, and the hunt must
  # never be held by one. The first tick after the request has no queue yet, so
  # a short grace lets the Catcher build one before the wait can end.
  defp sweeping?(logic, world, now) do
    case Map.get(logic.since, :sweep) do
      nil ->
        false

      asked_at ->
        pending = Map.get(world, :sweep_pending, 0)
        changed_at = Map.get(world, :sweep_changed_at)
        cap = logic.config.capture_wait_ms

        cond do
          now - asked_at < logic.config.sweep_grace_ms -> true
          pending > 0 and changed_at != nil and now - changed_at < cap -> true
          true -> false
        end
    end
  end

  # Waiting on a queue that is not MOVING is waiting forever: the sweep is
  # deferred outside the standing mode, and a corpse the Catcher gave up on
  # never leaves the count. So the hunt waits while the queue is non-empty AND
  # still changing — the same rule that told a long fight from a stalled one.
  defp capturing?(world, now, wait_ms) do
    pending = Map.get(world, :capture_pending, 0)
    changed_at = Map.get(world, :capture_changed_at)

    pending > 0 and changed_at != nil and now - changed_at < wait_ms
  end

  defp resume_after_dwell(logic, dwell_since, now) do
    if now - dwell_since >= logic.config.post_kill_dwell_ms do
      since =
        logic.since
        |> Map.drop([:dwell, :sweep, :stop_wait])
        |> Map.put(:walk_progress, now)

      {%{logic | state: :walking, since: since, last_pos: nil, stops_done: []}, :none}
    else
      {logic, :none}
    end
  end

  defp current_wp(logic), do: Enum.at(logic.route.waypoints, logic.wp_index)

  defp note_progress(logic, pos, now) do
    since = logic.since |> Map.put(:walk_progress, now) |> Map.delete(:step)
    %{logic | last_pos: pos, since: since}
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
