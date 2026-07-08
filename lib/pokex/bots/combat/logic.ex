defmodule Pokex.Bots.Combat.Logic do
  @moduledoc """
  Pure state machine for the combat sub-cycle (spec §5, combat half). No side
  effects: the driver gathers observations, calls step/3, and executes the
  returned actions. Times are monotonic milliseconds supplied by the caller.

  Starts by SCANNING the battle list for an attackable row; when a lock is
  found it attacks, and once the strip is clear after a kill it loots,
  captures, walks back, and loops to scanning again to check for more
  enemies. Contains no fishing logic — a row that never locks stays in
  `:scanning` (idle-loop) rather than recasting.
  """

  alias Pokex.Bots.Fisher.Skills

  defstruct state: :idle,
            config: nil,
            entered_at: 0,
            waiting_until: nil,
            last_hostile: nil,
            skills: nil,
            fight_tick: 0,
            targeted?: false,
            select_idx: 0,
            locked_row: nil,
            pending_verify?: false,
            target_streak: 0,
            verify_attempts: 0,
            lost_streak: 0,
            walk_plan: [],
            walk_taken: [],
            loot_offset: nil,
            loot_presses_left: 0,
            scan_idle?: false,
            failures: 0,
            error: nil,
            counters: %{fights: 0, loots: 0, captures: 0, failures: 0}

  # -- lifecycle ------------------------------------------------------------

  def new(config), do: %__MODULE__{config: config}

  def start(%__MODULE__{state: state} = logic, now) when state in [:idle, :error] do
    {%{
       logic
       | state: :scanning,
         targeted?: false,
         select_idx: 0,
         locked_row: nil,
         pending_verify?: false,
         target_streak: 0,
         verify_attempts: 0,
         lost_streak: 0,
         fight_tick: 0,
         skills: nil,
         last_hostile: nil,
         walk_plan: [],
         walk_taken: [],
         loot_offset: nil,
         loot_presses_left: 0,
         entered_at: now,
         waiting_until: nil,
         failures: 0,
         error: nil
     }, []}
  end

  def start(logic, _now), do: {logic, []}

  def stop(logic), do: {%{logic | state: :idle, waiting_until: nil}, []}

  def io_failed(logic, reason, now), do: fail(logic, now, reason)

  # -- driver hints ----------------------------------------------------------

  def needs(%__MODULE__{state: state}, _now) when state in [:idle, :error], do: []

  # Both selection ticks read the lock: the pre-click tick so it can notice a
  # target that's ALREADY locked (and attack instead of clicking again, which
  # would deselect it), and the verify tick to confirm the click landed a lock.
  def needs(%__MODULE__{state: :scanning}, _now),
    do: [:cursor, :battle_lock, :battle_creatures?]

  # While attacking, the red target border IS the fight: keep re-reading the
  # per-row lock EVERY tick so the committed row's vanished band (target dead)
  # ends the fight; sample :hostile now and then for the corpse position. But read
  # :ready_skills ONLY when a skill is actually about to fire — otherwise 3 of every
  # 4 fighting ticks (150ms tick vs 600ms cast) would capture the skill bar for a
  # reading Skills.decide ignores (it's paced), an extra screen-read per tick that
  # drags the whole fight (slower kills + slower lock detection). On a non-firing
  # tick the value is unused anyway, so skipping the capture changes nothing but speed.
  def needs(%__MODULE__{state: :fighting} = logic, now) do
    base = [:cursor, :battle_lock]
    base = if scan_tick?(logic), do: base ++ [:hostile], else: base
    if skill_ready_to_fire?(logic, now), do: base ++ [:ready_skills], else: base
  end

  def needs(_logic, _now), do: [:cursor]

  # True when the skill pacing window has elapsed (or no skill has fired yet) — i.e.
  # the next fighting tick will actually cast, so it's worth reading the skill bar.
  defp skill_ready_to_fire?(%__MODULE__{skills: nil}, _now), do: true
  defp skill_ready_to_fire?(%__MODULE__{skills: %Skills{last_cast_at: nil}}, _now), do: true

  defp skill_ready_to_fire?(%__MODULE__{skills: %Skills{last_cast_at: last}} = logic, now),
    do: now - last >= logic.config.skill_cast_ms

  @doc "True while in a post-action pause: the driver skips sensing (no screen capture) until it ends."
  def waiting?(%__MODULE__{waiting_until: nil}, _now), do: false
  def waiting?(%__MODULE__{waiting_until: until}, now), do: now < until

  def tick_interval(%__MODULE__{state: :fighting, config: c}), do: c.tick_ms_fighting
  def tick_interval(%__MODULE__{config: c}), do: c.tick_ms_default

  # -- stepping ---------------------------------------------------------------

  def step(%__MODULE__{state: state} = logic, _obs, _now) when state in [:idle, :error],
    do: {logic, []}

  def step(logic, obs, now) do
    cond do
      kill_corner?(obs) ->
        {%{logic | state: :idle, waiting_until: nil}, [{:log, "kill corner — parado"}]}

      logic.waiting_until != nil and now < logic.waiting_until ->
        {logic, []}

      true ->
        do_step(%{logic | waiting_until: nil}, obs, now)
    end
  end

  # Target selection: click a Battle row, then verify a FIXED red border locked
  # onto it. If it only blinked (own pokemon / player), try the next row down.
  defp do_step(%{state: :scanning, targeted?: false, pending_verify?: false} = logic, obs, now) do
    rows = logic.config.battle_rows
    min = logic.config.target_locked_min_pixels

    cond do
      # Empty Battle list → stay IDLE with ZERO mouse actions, so fishing keeps the
      # shared mouse. Detected by a capture-only HP-bar read (no click), so combat
      # never thrashes the mouse over black space. Log ONCE on entering idle.
      not battle_creatures?(obs) ->
        log =
          if logic.scan_idle?,
            do: [],
            else: [{:log, "Battle vazia — combate parado (mouse livre pra pesca)"}]

        {advance(%{logic | select_idx: 0, scan_idle?: true}, :scanning, now), log}

      # THIS row's ring is ALREADY up (this click's lock rendered late, or the row
      # is still selected) → attack it. Clicking again here would deselect it and
      # cancel the fight. Attributing strictly to select_idx's OWN band means a
      # sibling row's ring can no longer short-circuit us onto the wrong row (the
      # double-lure fix); a foreign lock just falls through and we click select_idx.
      row_locked?(obs, logic.select_idx, min) ->
        {advance(
           %{
             logic
             | targeted?: true,
               locked_row: logic.select_idx,
               target_streak: 0,
               lost_streak: 0,
               verify_attempts: 0,
               scan_idle?: false
           },
           :fighting,
           now
         ), []}

      logic.select_idx >= length(rows) ->
        {%{logic | select_idx: 0, scan_idle?: false} |> advance(:scanning, now),
         [{:log, "nenhum alvo atacável na Battle — recomeçando"}]}

      # This row reads ~no red — no name/creature to lock (an empty slot below the
      # last creature). Skip it WITHOUT clicking: clicking black space just moves the
      # mouse for nothing and deselects the current target. The enemy always has a red
      # name (≥9px) so it's never skipped. Guarded on the config knob (0 = never skip).
      row_red(obs, logic.select_idx) < Map.get(logic.config, :scan_min_red_to_click, 0) ->
        {%{logic | select_idx: logic.select_idx + 1, scan_idle?: false}, []}

      true ->
        # Click the row (this SELECTS + starts attacking), then slide the cursor OFF
        # to the neutral point. The game paints a selected row PINK while the cursor
        # hovers it and RED when it doesn't; the lock reader only knows red, so a
        # cursor left on the row reads as "not locked" and the bot skips a live
        # target — the "nenhum alvo atacável" bug. Moving away restores pure red.
        {advance(
           %{
             logic
             | pending_verify?: true,
               verify_attempts: 0,
               target_streak: 0,
               scan_idle?: false
           },
           :scanning,
           now,
           wait: logic.config.wait_target_verify_ms
         ),
         [
           {:click, :left, Enum.at(rows, logic.select_idx)},
           {:move, logic.config.neutral_point}
         ]}
    end
  end

  defp do_step(%{state: :scanning, targeted?: false, pending_verify?: true} = logic, obs, now) do
    # Read select_idx's OWN band, NOT the aggregate — a neighbor's late ring can no
    # longer satisfy locked? and mis-commit the wrong row ("marked row 2, was row 1").
    locked? = row_locked?(obs, logic.select_idx, logic.config.target_locked_min_pixels)

    cond do
      locked? and logic.target_streak + 1 >= logic.config.target_lock_streak ->
        # red PERSISTED on THIS row → a real fixed border, target locked. Reset
        # entered_at so the fight timeout measures the attack itself (a lock that
        # never kills → bail). Commit locked_row to the row we verified.
        {advance(
           %{
             logic
             | targeted?: true,
               pending_verify?: false,
               locked_row: logic.select_idx,
               target_streak: 0,
               verify_attempts: 0,
               lost_streak: 0
           },
           :fighting,
           now
         ), []}

      locked? ->
        # red is there, but check again after a beat — a blink shows once then vanishes
        {advance(%{logic | target_streak: logic.target_streak + 1}, :scanning, now,
           wait: logic.config.wait_target_verify_ms
         ), []}

      logic.verify_attempts + 1 < logic.config.target_verify_attempts ->
        # pre-ring frame: the ring renders ~200ms after the click + capture latency —
        # re-read the SAME row; clicking the next row now would LURE a second monster
        {advance(
           %{logic | verify_attempts: logic.verify_attempts + 1, target_streak: 0},
           :scanning,
           now,
           wait: logic.config.wait_target_verify_ms
         ), []}

      true ->
        # every verify attempt read below threshold — this row really didn't lock → next row
        {%{
           logic
           | select_idx: logic.select_idx + 1,
             pending_verify?: false,
             target_streak: 0,
             verify_attempts: 0
         }, []}
    end
  end

  # Attacking: commit to the LOCKED target. Every tick re-reads the red border —
  # while it's there we keep hitting THIS one (never re-select). When it vanishes
  # for enough consecutive checks, the target died/deselected → go loot. This is
  # per-target, so area attacks don't fake a "fight over" (spec: real lock only).
  defp do_step(%{state: :fighting, targeted?: true} = logic, obs, now) do
    min = logic.config.target_locked_min_pixels
    # Read the COMMITTED row's OWN band — a sibling's ring in another row no longer
    # masks this target's death, and death is attributed to the row we're on.
    alive? = row_locked?(obs, logic.locked_row, min)

    cond do
      timed_out?(logic, now, logic.config.fight_timeout_ms) ->
        # locked this long with no kill → not a real hostile (our own pokemon) or
        # hopelessly tanky → drop THIS one and move on to the next battle row.
        {advance(next_target(logic), :scanning, now),
         [{:log, "alvo não caiu a tempo — próxima linha"}]}

      alive? ->
        logic = %{
          logic
          | last_hostile: Map.get(obs, :hostile) || logic.last_hostile,
            fight_tick: logic.fight_tick + 1,
            lost_streak: 0
        }

        # Delegate skill choice + PACING to Skills: one skill per global cast
        # window. With a skill-bar reading (:ready_skills) it fires the highest-priority
        # READY skill and skips cooldowns, so no window is wasted on a swallowed press;
        # with no reading (nil) it falls back to blind priority-rotation. Auto-attack
        # keeps hitting between casts.
        skills = logic.skills || Skills.new(logic.config.skill_keys)

        {skills, decision} =
          Skills.decide(skills, now, logic.config.skill_cast_ms, Map.get(obs, :ready_skills))

        actions =
          case decision do
            {:press, key} -> [{:press, key}]
            :wait -> []
          end

        {%{logic | skills: skills}, actions}

      logic.lost_streak + 1 >= logic.config.target_lost_streak ->
        # committed band gone for enough checks → THIS target died. KILL-ALL: if
        # ANY other row still locks, more hooked mobs are alive → re-select the next
        # survivor and DO NOT loot yet (leaving them would keep attacking the player).
        # Only when the strip is clear do we run the existing loot chain.
        logic = update_in(logic.counters.fights, &(&1 + 1))

        if any_locked?(obs, min) do
          {advance(reselect(logic), :scanning, now),
           [{:log, "alvo caiu — próximo alvo na Battle"}]}
        else
          # The plan is computed ONCE here: the player is always screen-centered
          # and the world scrolls, so last_hostile goes stale the moment we move.
          {plan, offset} = plan_walk(logic)

          {advance(
             %{
               logic
               | lost_streak: 0,
                 locked_row: nil,
                 walk_plan: plan,
                 walk_taken: [],
                 loot_offset: offset,
                 loot_presses_left: logic.config.loot_presses
             },
             :walking_to_loot,
             now
           ), []}
        end

      true ->
        # border blinked out once — could be a hit animation; wait a tick, re-check
        {%{logic | lost_streak: logic.lost_streak + 1}, []}
    end
  end

  # One arrow press per tick, each SPACED by walk_step_ms — rapid back-to-back
  # movement inputs bug the pokemon out and he doesn't move at all. Every
  # executed step is prepended to walk_taken so the walk-back is an exact retrace.
  defp do_step(%{state: :walking_to_loot, walk_plan: [dir | rest]} = logic, _obs, now) do
    {advance(
       %{logic | walk_plan: rest, walk_taken: [dir | logic.walk_taken]},
       :walking_to_loot,
       now,
       wait: logic.config.walk_step_ms
     ), [{:press, dir}]}
  end

  defp do_step(%{state: :walking_to_loot, walk_plan: []} = logic, _obs, now) do
    {advance(logic, :looting, now), []}
  end

  # SPACE picks up the loot of any ADJACENT corpse — no aiming needed. A couple
  # of spaced presses covers a slow corpse-drop animation.
  defp do_step(%{state: :looting, loot_presses_left: n} = logic, _obs, now) when n > 0 do
    {advance(%{logic | loot_presses_left: n - 1}, :looting, now, wait: logic.config.wait_loot_ms),
     [{:press, "space"}]}
  end

  defp do_step(%{state: :looting} = logic, _obs, now) do
    logic = update_in(logic.counters.loots, &(&1 + 1))
    {advance(logic, :capturing, now), []}
  end

  defp do_step(%{state: :capturing} = logic, _obs, now) do
    # We stopped adjacent to the corpse: click one tile toward it (or one tile
    # below the player when the corpse position was unknown).
    {ox, oy} = logic.loot_offset || {0, 1}
    {px, py} = logic.config.player_point
    target = {px + ox * logic.config.tile_px, py + oy * logic.config.tile_px}
    logic = %{logic | failures: 0, last_hostile: nil}

    {logic, actions} =
      if logic.config.auto_capture do
        {update_in(logic.counters.captures, &(&1 + 1)), [{:capture_sequence, target}]}
      else
        {logic, [{:log, "auto-captura desligada — sem pokébola"}]}
      end

    # walk_taken is most-recent-first, so mapping to opposites IS the exact
    # retrace back to the fight spot (arrow presses are 1 tile regardless of
    # a slightly-wrong tile_px, so the return can never drift).
    {advance(
       %{
         logic
         | walk_plan: Enum.map(logic.walk_taken, &opposite/1),
           walk_taken: [],
           loot_offset: nil
       },
       :walking_back,
       now,
       wait: logic.config.wait_after_capture_ms
     ), actions}
  end

  defp do_step(%{state: :walking_back, walk_plan: [dir | rest]} = logic, _obs, now) do
    {advance(%{logic | walk_plan: rest}, :walking_back, now, wait: logic.config.walk_step_ms),
     [{:press, dir}]}
  end

  defp do_step(%{state: :walking_back, walk_plan: []} = logic, _obs, now) do
    {continue_combat(logic, now), []}
  end

  # Always loop back to scanning: re-check the battle list for more enemies.
  # This module contains ZERO fishing logic — recasting is the driver's concern.
  defp continue_combat(logic, now, opts \\ []) do
    fresh = %{
      logic
      | targeted?: false,
        select_idx: 0,
        locked_row: nil,
        pending_verify?: false,
        target_streak: 0,
        verify_attempts: 0,
        lost_streak: 0,
        fight_tick: 0,
        skills: nil,
        last_hostile: nil,
        walk_plan: [],
        walk_taken: [],
        loot_offset: nil,
        loot_presses_left: 0
    }

    advance(fresh, :scanning, now, opts)
  end

  # Abandon the current lock and reset to selecting the NEXT battle row down.
  defp next_target(logic) do
    %{
      logic
      | targeted?: false,
        locked_row: nil,
        pending_verify?: false,
        target_streak: 0,
        verify_attempts: 0,
        lost_streak: 0,
        fight_tick: 0,
        skills: nil,
        select_idx: logic.select_idx + 1
    }
  end

  # After a kill, re-scan from row 0 for the NEXT survivor. Distinct from
  # next_target/1 (which does select_idx+1): fished corpses vanish and the battle
  # list re-packs upward, so a live mob may now sit at row 0. The per-row verify
  # won't double-click (it reads select_idx's own band), so re-scanning is safe.
  defp reselect(logic) do
    %{
      logic
      | targeted?: false,
        pending_verify?: false,
        locked_row: nil,
        select_idx: 0,
        target_streak: 0,
        verify_attempts: 0,
        lost_streak: 0,
        fight_tick: 0,
        skills: nil
    }
  end

  # The hostile point is the floating red NAME; the body lies one tile below it.
  defp corpse_point(%{last_hostile: nil}), do: nil

  defp corpse_point(%{last_hostile: {x, y}, config: config}),
    do: {x, y + config.tile_px}

  # Turn the corpse's screen offset into an arrow-key plan, computed ONCE at
  # fight end (the player is always screen-centered; the world scrolls, so the
  # plan can't be re-derived mid-walk from the stale last_hostile). Stops
  # ADJACENT to the corpse (one step short per axis) — SPACE loots from there.
  defp plan_walk(%{last_hostile: nil}), do: {[], nil}

  defp plan_walk(%{config: config} = logic) do
    {cx, cy} = corpse_point(logic)
    {px, py} = config.player_point
    dx = round((cx - px) / config.tile_px)
    dy = round((cy - py) / config.tile_px)

    if abs(dx) > config.max_walk_tiles or abs(dy) > config.max_walk_tiles do
      # a corpse that far is a bad hostile read → loot in place
      {[], nil}
    else
      plan =
        List.duplicate(if(dx > 0, do: "right", else: "left"), max(abs(dx) - 1, 0)) ++
          List.duplicate(if(dy > 0, do: "down", else: "up"), max(abs(dy) - 1, 0))

      {plan, {clamp_unit(dx), clamp_unit(dy)}}
    end
  end

  defp clamp_unit(d), do: d |> max(-1) |> min(1)

  defp opposite("up"), do: "down"
  defp opposite("down"), do: "up"
  defp opposite("left"), do: "right"
  defp opposite("right"), do: "left"

  # -- shared helpers ---------------------------------------------------------

  defp fail(%__MODULE__{} = logic, now, reason) do
    failures = logic.failures + 1
    logic = update_in(logic.counters.failures, &(&1 + 1))
    reason = to_string(reason)

    if failures >= logic.config.max_consecutive_failures do
      {%{
         logic
         | state: :error,
           failures: failures,
           waiting_until: nil,
           error: "#{reason} (#{failures}x seguidas)"
       }, [{:log, reason}]}
    else
      {advance(%{logic | failures: failures}, :scanning, now), [{:log, reason}]}
    end
  end

  defp advance(logic, state, now, opts \\ []) do
    wait = Keyword.get(opts, :wait)
    %{logic | state: state, entered_at: now, waiting_until: wait && now + wait}
  end

  defp timed_out?(logic, now, ms), do: now - logic.entered_at > ms

  defp kill_corner?(%{cursor: cursor}), do: Pokex.Bots.Corner.in_kill_corner?(cursor)
  defp kill_corner?(_obs), do: false

  defp scan_tick?(%__MODULE__{fight_tick: tick, config: c}),
    do: rem(tick, max(c.hostile_scan_every, 1)) == 0

  # -- per-row lock reads -----------------------------------------------------

  defp battle_lock(obs), do: Map.get(obs, :battle_lock, [])
  defp row_locked?(obs, idx, min), do: Enum.at(battle_lock(obs), idx, 0) >= min
  defp row_red(obs, idx), do: Enum.at(battle_lock(obs), idx, 0)

  # Default TRUE when the observation is absent (unit tests that don't set it) so
  # existing scan/click behavior is unchanged; only an explicit false idles combat.
  defp battle_creatures?(obs), do: Map.get(obs, :battle_creatures?, true)
  defp any_locked?(obs, min), do: Enum.any?(battle_lock(obs), &(&1 >= min))
end
