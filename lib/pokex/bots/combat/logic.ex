defmodule Pokex.Bots.Combat.Logic do
  @moduledoc """
  Pure state machine for the combat sub-cycle (spec §5, combat half). No side
  effects: the driver gathers observations, calls step/3, and executes the
  returned actions. Times are monotonic milliseconds supplied by the caller.

  Scans the battle list for a CANDIDATE (HP bar, no own-pokemon pokeball), clicks it, and
  CONFIRMS a real battle via the lock ring before attacking; when the ring vanishes the target
  died → it bumps `counters.fights` and re-scans for the next enemy IMMEDIATELY. Loot/capture/
  walk-back is NOT here — the driver broadcasts the kill and the `Loot.Worker` handles the
  corpse in parallel, so combat never stops attacking to loot. Contains no fishing logic.
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
        # ring gone for enough checks → target dead/deselected → count the kill and re-scan for
        # the next enemy IMMEDIATELY (never stop attacking to loot). The corpse is handed to the
        # Loot.Worker: Combat.Worker broadcasts {:kill, last_hostile} on this counter bump, and
        # last_hostile is preserved through reselect so the event carries the corpse point.
        {advance(reselect(update_in(logic.counters.fights, &(&1 + 1))), :scanning, now), []}

      true ->
        {%{logic | lost_streak: logic.lost_streak + 1}, []}
    end
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
