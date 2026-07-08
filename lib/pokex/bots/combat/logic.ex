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
            locked_row: nil,
            enemy_count: 0,
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
         locked_row: nil,
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

  @doc """
  External wake-up: a fish was just hooked, so a new attackable pokemon is about to land in
  the Battle list. If we're SCANNING (searching or idle over an empty list), clear the idle
  latch and any pending wait so the driver looks IMMEDIATELY instead of waiting out an idle
  poll. A no-op while fighting/looting/walking — never abandons a live fight.
  """
  def rescan(%__MODULE__{state: :scanning} = logic, now) do
    %{logic | scan_idle?: false, waiting_until: nil, entered_at: now}
  end

  def rescan(logic, _now), do: logic

  def stop(logic), do: {%{logic | state: :idle, waiting_until: nil}, []}

  def io_failed(logic, reason, now), do: fail(logic, now, reason)

  # -- driver hints ----------------------------------------------------------

  def needs(%__MODULE__{state: state}, _now) when state in [:idle, :error], do: []

  # Scanning reads the ENEMY rows directly (HP bar + no own-pokemon pokeball) — no lock ring,
  # no per-row click-verify. One capture-pair (body + strip) tells us exactly which rows to
  # attack, so combat clicks the enemy on the FIRST tick it sees one instead of walking the
  # cursor down the list.
  def needs(%__MODULE__{state: :scanning}, _now),
    do: [:cursor, :enemy_rows]

  # While attacking, re-read the enemy rows EVERY tick: when our target's row leaves the enemy
  # set the target died (→ loot when the list is clear, or re-select the next survivor). Sample
  # :hostile now and then for the corpse position. Read :ready_skills ONLY when a skill is
  # actually about to fire — otherwise the paced ticks between casts would each capture the
  # skill bar for a reading Skills.decide ignores, an extra screen-read per tick that drags the
  # whole fight. On a non-firing tick the value is unused, so skipping the capture only helps.
  def needs(%__MODULE__{state: :fighting} = logic, now) do
    base = [:cursor, :enemy_rows]
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

  # Find an enemy and attack it — directly. `enemy_rows` already excludes the player's own
  # pokemon (the pokeball row), so any enemy row is safe to click. No red-ring verify, no
  # per-row walk: click the TOPMOST enemy once, slide the cursor off, and commit to fighting
  # on the SAME tick. The first skill fires on the next (fighting) tick, which reads the ready
  # skills. Nothing to fight → stay IDLE with ZERO mouse actions so fishing keeps the shared
  # mouse; log ONCE on entering idle.
  defp do_step(%{state: :scanning, targeted?: false} = logic, obs, now) do
    case enemy_rows(obs) do
      [] ->
        log =
          if logic.scan_idle?,
            do: [],
            else: [{:log, "Battle sem inimigos — combate parado (mouse livre pra pesca)"}]

        {advance(%{logic | scan_idle?: true, locked_row: nil}, :scanning, now), log}

      [target | _] = enemies ->
        {advance(
           %{
             logic
             | targeted?: true,
               locked_row: target,
               enemy_count: length(enemies),
               lost_streak: 0,
               fight_tick: 0,
               skills: nil,
               scan_idle?: false
           },
           :fighting,
           now
         ),
         [
           {:click, :left, Enum.at(logic.config.battle_rows, target)},
           {:move, logic.config.neutral_point}
         ]}
    end
  end

  # Attacking: keep hitting the enemy. Every tick re-reads `enemy_rows`. While the enemy set is
  # steady we fire the strongest READY skill (paced by the global cast window). A DROP in the
  # count means a kill: if enemies remain we bounce back to :scanning, which re-clicks the
  # topmost survivor FRESH next tick (a fresh click after the target's death can't toggle-
  # deselect a live selection, and the survivor may have re-packed into our old row index); when
  # the list is empty the strip is clear → loot. A short streak filters a 1-frame HP-bar blink.
  defp do_step(%{state: :fighting, targeted?: true} = logic, obs, now) do
    enemies = enemy_rows(obs)

    cond do
      timed_out?(logic, now, logic.config.fight_timeout_ms) ->
        # attacking this long with no kill → stuck (bad read / hopelessly tanky) → rescan.
        {advance(reselect(logic), :scanning, now),
         [{:log, "alvo não caiu a tempo — revarredura"}]}

      enemies == [] ->
        # no enemy left — confirm for target_lost_streak ticks (a dead creature's HP bar can
        # blink out for one frame), then the strip is clear → loot.
        if logic.lost_streak + 1 >= logic.config.target_lost_streak do
          logic = update_in(logic.counters.fights, &(&1 + 1))
          # Plan computed ONCE: the player is always screen-centered and the world scrolls,
          # so last_hostile goes stale the moment we move.
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
        else
          {%{logic | lost_streak: logic.lost_streak + 1}, []}
        end

      length(enemies) < logic.enemy_count ->
        # an enemy died but others remain → count the kill and re-scan for the next survivor.
        logic = update_in(logic.counters.fights, &(&1 + 1))

        {advance(reselect(logic), :scanning, now),
         [{:log, "alvo caiu — próximo inimigo na Battle"}]}

      true ->
        # enemy set steady → keep attacking the current target. Fire the strongest ready skill;
        # Skills paces one press per cast window and (with a :ready_skills reading) skips
        # cooldowns so no window is wasted, blind priority-rotation otherwise. Track the count so
        # a later drop is still detected even if a new enemy appeared in the meantime.
        logic = %{
          logic
          | last_hostile: Map.get(obs, :hostile) || logic.last_hostile,
            fight_tick: logic.fight_tick + 1,
            lost_streak: 0,
            enemy_count: length(enemies)
        }

        skills = logic.skills || Skills.new(logic.config.skill_keys)

        {skills, decision} =
          Skills.decide(skills, now, logic.config.skill_cast_ms, Map.get(obs, :ready_skills))

        actions =
          case decision do
            {:press, key} -> [{:press, key}]
            :wait -> []
          end

        {%{logic | skills: skills}, actions}
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
        locked_row: nil,
        enemy_count: 0,
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

  # Drop the current target and re-scan the Battle list from the top for the next enemy —
  # after a kill the list re-packs upward, so a survivor may now sit higher. Scanning reads
  # `enemy_rows` fresh (own pokemon already excluded), so re-selecting is safe.
  defp reselect(logic) do
    %{
      logic
      | targeted?: false,
        locked_row: nil,
        enemy_count: 0,
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

  # -- enemy rows -------------------------------------------------------------

  # The attackable rows the sensor found (HP bar present, own-pokemon pokeball absent),
  # topmost first. Absent → [] (no enemy → idle), so a unit obs that omits the key idles.
  defp enemy_rows(obs), do: Map.get(obs, :enemy_rows, [])
end
