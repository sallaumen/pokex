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

  alias Pokex.Bots.Cavebot.Route

  @enforce_keys [:route, :config]
  defstruct state: :walking,
            route: nil,
            wp_index: 0,
            combat_running?: false,
            since: %{},
            retries: 0,
            config: nil,
            last_pos: nil

  @type state :: :walking | :fighting | :post_fight | :stuck | :fight_stalled | :blocked

  @type action ::
          :none
          | {:walk, integer, integer}
          | :run_combat
          | :halt_combat
          | {:nudge, integer, integer}
          | {:block, atom}

  @type world :: %{
          pos: {integer, integer, integer} | nil,
          enemies: non_neg_integer,
          combat_state: atom,
          capture_pending: non_neg_integer
        }

  @type config :: %{
          arrival_tolerance: non_neg_integer,
          walk_timeout_ms: non_neg_integer,
          stuck_max_retries: non_neg_integer,
          clear_debounce_ms: non_neg_integer,
          fight_timeout_ms: non_neg_integer,
          post_kill_dwell_ms: non_neg_integer,
          blind_kick_ms: non_neg_integer,
          capture_wait_ms: non_neg_integer
        }

  @type t :: %__MODULE__{
          state: state,
          route: Route.t(),
          wp_index: non_neg_integer,
          combat_running?: boolean,
          since: %{optional(atom) => integer},
          retries: non_neg_integer,
          config: config,
          last_pos: {integer, integer, integer} | nil
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
  2. Floor change (non-nil `pos` with z differing from the route) blocks in any
     state: `{:block, :floor_changed}`. Safety first.
  3. Startup: with `combat_running?` false, start Combat (`:run_combat`) and
     nothing else this tick.
  4. Dispatch by state.
  """
  @spec step(t, world, integer) :: {t, action}
  def step(%__MODULE__{state: :blocked} = logic, _world, _now), do: {logic, :none}

  def step(%__MODULE__{route: %Route{z: route_z}} = logic, %{pos: pos}, _now)
      when is_tuple(pos) and elem(pos, 2) != route_z do
    {%{logic | state: :blocked}, {:block, :floor_changed}}
  end

  def step(%__MODULE__{combat_running?: false} = logic, _world, _now) do
    {%{logic | combat_running?: true}, :run_combat}
  end

  def step(%__MODULE__{state: :walking} = logic, world, now), do: walk(logic, world, now)
  def step(%__MODULE__{state: :stuck} = logic, world, now), do: stuck(logic, world, now)
  def step(%__MODULE__{state: :fighting} = logic, world, now), do: fight(logic, world, now)

  def step(%__MODULE__{state: :fight_stalled} = logic, world, now),
    do: fight_stalled(logic, world, now)

  def step(%__MODULE__{state: :post_fight} = logic, world, now), do: post_fight(logic, world, now)

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

  # Enemy on screen: Combat (always running) already fights — just change state.
  defp walk(logic, %{enemies: enemies}, now) when enemies > 0 do
    since = logic.since |> Map.delete(:clear) |> Map.put(:fight, now)
    {%{logic | state: :fighting, since: since}, :none}
  end

  # Unknown position: hold — never walk FAR blind. MARK the blindness so the
  # Worker can say how long it has lasted, and after blind_kick_ms KICK one
  # step toward the waypoint: the client only draws the coordinate while the
  # position changes, so one moved tile is what brings the reading back.
  defp walk(logic, %{pos: nil}, now), do: logic |> blind(now) |> maybe_kick(now)

  defp walk(logic, %{pos: {x, y, _} = pos}, now) do
    logic = sighted(logic)
    wp = current_wp(logic)
    dx = wp.x - x
    dy = wp.y - y
    tol = logic.config.arrival_tolerance

    cond do
      abs(dx) <= tol and abs(dy) <= tol ->
        next = rem(logic.wp_index + 1, length(logic.route.waypoints))
        {%{note_progress(logic, pos, now) | wp_index: next}, :none}

      pos != logic.last_pos ->
        {note_progress(logic, pos, now), {:walk, dx, dy}}

      now - Map.get(logic.since, :walk_progress, now) >= logic.config.walk_timeout_ms ->
        {%{logic | state: :stuck, retries: 0}, {:walk, dx, dy}}

      true ->
        {logic, {:walk, dx, dy}}
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

      if retries > logic.config.stuck_max_retries do
        {%{logic | state: :blocked}, {:block, :stuck}}
      else
        {dx, dy} = unstick(logic, pos, retries)
        {%{logic | retries: retries}, {:walk, dx, dy}}
      end
    end
  end

  # Screen clear: sustain the debounce before declaring the fight over.
  defp fight(logic, %{enemies: 0}, now) do
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

  # Enemy still alive: reset the clear and watch the fight timeout.
  defp fight(logic, _world, now) do
    since = Map.delete(logic.since, :clear)

    case Map.get(since, :fight) do
      nil ->
        {%{logic | since: Map.put(since, :fight, now)}, :none}

      fight_since ->
        if now - fight_since >= logic.config.fight_timeout_ms do
          {%{logic | state: :fight_stalled, since: since, retries: 0}, :none}
        else
          {%{logic | since: since}, :none}
        end
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
    waiting? = Map.get(world, :capture_pending, 0) > 0

    if waiting? and now - dwell_since < logic.config.capture_wait_ms do
      {logic, :none}
    else
      resume_after_dwell(logic, dwell_since, now)
    end
  end

  defp resume_after_dwell(logic, dwell_since, now) do
    if now - dwell_since >= logic.config.post_kill_dwell_ms do
      since =
        logic.since
        |> Map.delete(:dwell)
        |> Map.put(:walk_progress, now)

      {%{logic | state: :walking, since: since, last_pos: nil}, :none}
    else
      {logic, :none}
    end
  end

  defp current_wp(logic), do: Enum.at(logic.route.waypoints, logic.wp_index)

  defp note_progress(logic, pos, now) do
    %{logic | last_pos: pos, since: Map.put(logic.since, :walk_progress, now)}
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
