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

  defstruct state: :idle,
            config: nil,
            entered_at: 0,
            waiting_until: nil,
            last_hostile: nil,
            skill_idx: 0,
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
         skill_idx: 0,
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

  # Scanning just needs the candidate rows + ring (one screenshot).
  def needs(%__MODULE__{state: :scanning}, _now), do: [:cursor, :battle]

  # Confirming and fighting CYCLE the skills (press the next in order each tick) — they do NOT
  # read the skill bar. Reading the bar every tick was a 2nd screencapture (each ~0.4-0.8s on
  # Lucas's multi-monitor Mac even with -m), so skills fired ~2-5s apart, AND when the bar read
  # came back empty the verify loop got stuck re-pressing the same key. Cycling needs ONE capture
  # (:battle for the ring/liveness) and can never stall: a dropped press just comes back around
  # the rotation. :battle carries the lock ring; fighting also samples :hostile now and then for
  # the corpse point.
  def needs(%__MODULE__{state: :confirming}, _now), do: [:cursor, :battle]

  def needs(%__MODULE__{state: :fighting} = logic, _now) do
    base = [:cursor, :battle]
    if scan_tick?(logic), do: base ++ [:hostile], else: base
  end

  def needs(_logic, _now), do: [:cursor]

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
        # Click the candidate and slide the cursor off — NOTHING else in this action. Lucas: a
        # skill pressed in the SAME action as the select-click makes the game DROP the click (the
        # selection never registers). So the first skill waits for the NEXT tick (confirming),
        # once the click has landed.
        {advance(%{logic | locked_row: target, scan_idle?: false}, :confirming, now),
         [
           {:click, :left, Enum.at(logic.config.battle_rows, target)},
           {:move, logic.config.neutral_point}
         ]}
    end
  end

  # Confirm the click started a battle AND attack at the same time — don't wait for the ring to
  # start hitting. Every tick: watch the clicked row for the red lock ring, and meanwhile press
  # the NEXT skill in the rotation (so the first hit lands ~one tick after the click instead of
  # after the whole confirm). Ring up → a real target → keep hitting it in :fighting. No ring
  # within battle_confirm_ms → the click engaged nothing (a passing player's pokemon has an HP
  # bar but no pokeball, so it looked attackable but started no battle) → mark the row tried and
  # pick the next candidate; the presses did nothing on a non-target. The window also filters the
  # brief red BLINK from clicking your own pokemon.
  defp do_step(%{state: :confirming, locked_row: row} = logic, obs, now) do
    cond do
      ring?(obs, row, logic.config.target_locked_min_pixels) ->
        # ring up → real battle → keep hitting AND fire this tick's skill too (don't waste the
        # confirming→fighting tick on nothing — that's a whole capture-tick of lost attack).
        {logic, press} = press_next_skill(logic)

        {advance(
           %{logic | targeted?: true, fight_tick: 0, lost_streak: 0, tried: [], tried_for: nil},
           :fighting,
           now
         ), press}

      now - logic.entered_at > logic.config.battle_confirm_ms ->
        {advance(%{logic | locked_row: nil, tried: [row | logic.tried]}, :scanning, now),
         [{:log, "linha #{row} não entrou em batalha — próximo candidato"}]}

      true ->
        press_next_skill(logic)
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

        press_next_skill(logic)

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
        skill_idx: 0
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

  # Press the NEXT skill in the rotation this tick and advance the cursor, so consecutive ticks
  # walk the priority order (strongest first) and loop. No skill-bar read: the game silently
  # swallows a skill that's on cooldown, and cycling means every key is retried each loop — so a
  # dropped input just lands on the next pass. One capture per tick, and it can never stall on one
  # key the way the bar-verify loop did when the bar read came back empty.
  defp press_next_skill(%{config: %{skill_keys: []}} = logic), do: {logic, []}

  defp press_next_skill(%{config: %{skill_keys: order}, skill_idx: idx} = logic) do
    key = Enum.at(order, rem(idx, length(order)))
    {%{logic | skill_idx: idx + 1}, [{:press, key}]}
  end

  # Candidate enemy rows (HP bar, no own-pokemon pokeball), topmost first. Absent → [] (idle).
  defp candidates(obs), do: (obs[:battle] || %{})[:enemies] || []

  # Is the red lock ring up on `row` (>= min px)? nil row / absent reading → false.
  defp ring?(_obs, nil, _min), do: false

  defp ring?(obs, row, min),
    do: Enum.at((obs[:battle] || %{})[:red] || [], row, 0) >= min
end
