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
            tried: [],
            tried_for: nil,
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
         tried: [],
         tried_for: nil,
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

  # Scanning and confirming both read :battle (candidate rows + per-row lock ring) from ONE
  # screenshot: scanning to pick a candidate to click, confirming to watch for the ring that
  # proves the click started a real battle (a passing player's pokemon looks attackable but
  # engages nothing → no ring).
  def needs(%__MODULE__{state: state}, _now) when state in [:scanning, :confirming],
    do: [:cursor, :battle]

  # While attacking, re-read :battle EVERY tick: the lock ring on our row IS the fight — while
  # it holds we keep hitting, when it's gone the target died → loot. Sample :hostile now and
  # then for the corpse position. Read :ready_skills ONLY when a skill is actually about to fire
  # — otherwise the paced ticks between casts would each capture the skill bar for a reading
  # Skills.decide ignores, an extra screen-read that drags the fight; on a non-firing tick the
  # value is unused, so skipping it only helps.
  def needs(%__MODULE__{state: :fighting} = logic, now) do
    base = [:cursor, :battle]
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

  def tick_interval(%__MODULE__{state: state, config: c}) when state in [:fighting, :confirming],
    do: c.tick_ms_fighting

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

  # Find a CANDIDATE enemy (HP bar, no own-pokemon pokeball) and click it — but don't commit to
  # fighting yet. `candidates` excludes your own pokemon; the click still needs the lock ring to
  # PROVE a real battle started (a passing player's pokemon has an HP bar and no pokeball, so it
  # looks attackable, but clicking it engages nothing). Pick the topmost candidate we haven't
  # already tried-and-failed this pass, click it, slide the cursor off → :confirming. No untried
  # candidate (empty list, or every one a dud) → stay IDLE with ZERO mouse actions so fishing
  # keeps the shared mouse; log ONCE on entering idle.
  defp do_step(%{state: :scanning, targeted?: false} = logic, obs, now) do
    cands = candidates(obs)
    # a changed candidate set is a fresh pass → forget which rows we tried last time.
    logic = if cands == logic.tried_for, do: logic, else: %{logic | tried: [], tried_for: cands}

    case cands -- logic.tried do
      [] ->
        log =
          if logic.scan_idle?,
            do: [],
            else: [
              {:log, "Battle sem inimigos atacáveis — combate parado (mouse livre pra pesca)"}
            ]

        {advance(%{logic | scan_idle?: true, locked_row: nil}, :scanning, now), log}

      [target | _] ->
        {advance(%{logic | locked_row: target, scan_idle?: false}, :confirming, now),
         [
           {:click, :left, Enum.at(logic.config.battle_rows, target)},
           {:move, logic.config.neutral_point}
         ]}
    end
  end

  # Confirm the click actually started a battle: watch the clicked row for the red lock ring.
  # Ring up → a real target locked → fight it. No ring within battle_confirm_ms → the click
  # engaged nothing (a player's pokemon / not attackable) → mark this row tried and go pick the
  # next candidate. The confirm window also filters the brief red BLINK from clicking your own
  # pokemon (it fades before the first ~tick-later read, while a real ring persists).
  defp do_step(%{state: :confirming, locked_row: row} = logic, obs, now) do
    cond do
      ring?(obs, row, logic.config.target_locked_min_pixels) ->
        {advance(
           %{
             logic
             | targeted?: true,
               fight_tick: 0,
               skills: nil,
               lost_streak: 0,
               tried: [],
               tried_for: nil
           },
           :fighting,
           now
         ), []}

      now - logic.entered_at > logic.config.battle_confirm_ms ->
        {advance(%{logic | locked_row: nil, tried: [row | logic.tried]}, :scanning, now),
         [{:log, "linha #{row} não entrou em batalha — próximo candidato"}]}

      true ->
        {logic, []}
    end
  end

  # Attacking: the lock ring on our row IS the fight. Every tick re-reads it — while it holds we
  # fire the strongest READY skill (paced by the global cast window). When it's gone for
  # target_lost_streak ticks (a debounce against a 1-frame blink) the target died/deselected →
  # count the kill and go loot the corpse; continue_combat then re-scans for the next enemy.
  defp do_step(%{state: :fighting, targeted?: true} = logic, obs, now) do
    min = logic.config.target_locked_min_pixels

    cond do
      timed_out?(logic, now, logic.config.fight_timeout_ms) ->
        # attacking this long with no kill → stuck (bad read / hopelessly tanky) → rescan.
        {advance(reselect(logic), :scanning, now),
         [{:log, "alvo não caiu a tempo — revarredura"}]}

      ring?(obs, logic.locked_row, min) ->
        logic = %{
          logic
          | last_hostile: Map.get(obs, :hostile) || logic.last_hostile,
            fight_tick: logic.fight_tick + 1,
            lost_streak: 0
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

      logic.lost_streak + 1 >= logic.config.target_lost_streak ->
        # ring gone for enough checks → target dead/deselected → count the fight, go loot.
        logic = update_in(logic.counters.fights, &(&1 + 1))
        # Plan computed ONCE: the player is always screen-centered and the world scrolls, so
        # last_hostile goes stale the moment we move.
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

      true ->
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
        locked_row: nil,
        tried: [],
        tried_for: nil,
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
        tried: [],
        tried_for: nil,
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

  # -- battle view ------------------------------------------------------------

  # Candidate enemy rows (HP bar, no own-pokemon pokeball), topmost first. Absent → [] (idle).
  defp candidates(obs), do: (obs[:battle] || %{})[:enemies] || []

  # Is the red lock ring up on `row` (>= min px)? nil row / absent reading → false.
  defp ring?(_obs, nil, _min), do: false

  defp ring?(obs, row, min),
    do: Enum.at((obs[:battle] || %{})[:red] || [], row, 0) >= min
end
