defmodule Pokex.Bots.Fishing.Logic do
  alias Pokex.Bots.Corner

  @moduledoc """
  Pure state machine for the fishing sub-cycle (spec §5, fishing half). No side
  effects: the driver gathers observations, calls step/3, and executes the
  returned actions. Times are monotonic milliseconds supplied by the caller.

  Fishes forever: a confirmed bite presses the rod (counts the hook) and loops
  straight back to :casting — it never touches the battle list. The hooked
  fish appears there on its own; Combat.Logic/Combat.Worker picks it up
  independently. Contains ZERO combat logic.
  """

  defstruct state: :idle,
            config: nil,
            entered_at: 0,
            waiting_until: nil,
            glow_streak: 0,
            calm_streak: 0,
            dead_streak: 0,
            settled?: false,
            # true while a confirmed bite is being HELD because require_cooldowns is on
            # and the kill-skills aren't ready yet — used only to announce the hold once.
            holding?: false,
            # when the current hold STARTED (not refreshed per peak) — drives the
            # hook_hold_max_ms bail so one bite can never be held forever.
            holding_since: nil,
            # the user-facing WHY of the current hold (nil when not holding) — the
            # panel renders it straight from the snapshot.
            hold_reason: nil,
            # last PERFORMED actuation as %{text: String.t(), at: monotonic_ms} —
            # nil until the first cast (never a 0 sentinel).
            last_action: nil,
            # The cast's WITNESS: did the LINE ever show up in the water this
            # cycle? It used to be "was a BITE seen", which made every ordinary
            # fishless cycle look like a swallowed rod key — a cast that lands
            # and waits is the normal case, not a dry one. Born true on purpose:
            # the first cast must not inherit dryness from a cycle that never
            # existed. Each cast resets it to false.
            line_seen?: true,
            # CONSECUTIVE casts whose line NEVER appeared — at
            # config.dry_casts_alarm the cast emits {:alarm, _} (the rod key is
            # probably not reaching the game) and the count restarts.
            dry_casts: 0,
            failures: 0,
            error: nil,
            counters: %{cycles: 0, hooked: 0, failures: 0}

  def new(config), do: %__MODULE__{config: config}

  def start(%__MODULE__{state: state} = logic, now) when state in [:idle, :error] do
    {%{logic | state: :focusing, entered_at: now, waiting_until: nil, failures: 0, error: nil},
     []}
  end

  def start(logic, _now), do: {logic, []}

  def stop(logic), do: {%{logic | state: :idle, waiting_until: nil, hold_reason: nil}, []}

  def io_failed(logic, reason, now), do: fail(logic, now, reason)

  def needs(%__MODULE__{state: state}) when state in [:idle, :error], do: []

  # Only ask for the (capture-costly) cooldown reading when the gate is actually on —
  # otherwise fishing never touches the skill bar.
  def needs(%__MODULE__{state: :watching, config: config}) do
    if Map.get(config, :require_cooldowns, false),
      do: [:cursor, :glow, :cooldowns_ready?],
      else: [:cursor, :glow]
  end

  # :glow too, so the very first frame can already see a LIVE line and skip the
  # recast (see the :focusing steps below).
  def needs(%__MODULE__{state: :focusing}), do: [:cursor, :glow]

  def needs(_logic), do: [:cursor]

  @doc "True while in a post-action pause: the driver skips sensing (no screen capture) until it ends."
  def waiting?(%__MODULE__{waiting_until: nil}, _now), do: false
  def waiting?(%__MODULE__{waiting_until: until}, now), do: now < until

  def tick_interval(%__MODULE__{state: :watching, config: c}), do: c.tick_ms_watching
  def tick_interval(%__MODULE__{config: c}), do: c.tick_ms_default

  def step(%__MODULE__{state: state} = logic, _obs, _now) when state in [:idle, :error],
    do: {logic, []}

  def step(logic, obs, now) do
    cond do
      kill_corner?(obs) ->
        {%{logic | state: :idle, waiting_until: nil}, [{:log, "kill corner — parado"}]}

      logic.waiting_until != nil and now < logic.waiting_until ->
        {logic, []}

      true ->
        logic = maybe_settle_by_time(%{logic | waiting_until: nil}, now)
        do_step(witness_the_cast(logic, obs), obs, now)
    end
  end

  # One place decides that this cycle's cast really happened: any frame showing
  # the line (or a bite, which implies it). Every clause below used to set this
  # by hand on a BITE only.
  defp witness_the_cast(logic, obs) do
    if line_present?(obs) or Map.get(obs, :glow) == true,
      do: %{logic | line_seen?: true},
      else: logic
  end

  # FRAME-based settling (calm_streak) assumes ~150ms ticks. With a starved
  # capture, frames arrive SECONDS apart: the fish bites before
  # calm_streak_needed calm frames and every bite peak RESETS calm — settled?
  # never latches, the rod never pulls, and watch_timeout recasts over a live
  # fish (logs 2026-07-30: bubbles 2843/1150 for 16s, eternal "settle", timeout,
  # burned fish). But the splash is PHYSICS, not frames: it lasts ~1-1.5s and is
  # over. Past settle_max_ms from the cast (entered_at is only touched again
  # after settled), the water settled by TIME — the same late frame may already
  # be the bite that hooks.
  defp maybe_settle_by_time(%{state: :watching, settled?: false} = logic, now) do
    if now - logic.entered_at >= Map.get(logic.config, :settle_max_ms, 2_500),
      do: %{logic | settled?: true},
      else: logic
  end

  defp maybe_settle_by_time(logic, _now), do: logic

  # Resuming over a LIVE line (the Focus pause-and-return, a re-Start right
  # after a cast): the resting line's indicator ring pulses continuously, so
  # `line?` on the very first frame means the previous cast is still in the
  # water. Recasting would reset the whole cycle and lose the live bait
  # (Lucas, 2026-07-20) — skip the neutral click AND the cast, and watch it:
  # settled (any cast splash is long gone) with clean streaks. No cycle count:
  # nothing was cast.
  defp do_step(%{state: :focusing} = logic, %{line?: true}, now) do
    logic = %{
      logic
      | glow_streak: 0,
        calm_streak: 0,
        dead_streak: 0,
        settled?: true,
        holding?: false,
        holding_since: nil,
        hold_reason: nil,
        last_action: %{text: "retomada sobre a isca viva", at: now}
    }

    {advance(logic, :watching, now), [{:log, "isca já na água — vigiando sem re-lançar"}]}
  end

  defp do_step(%{state: :focusing} = logic, _obs, now) do
    {advance(logic, :casting, now, wait: logic.config.wait_focus_ms),
     [{:click, :left, logic.config.neutral_point}]}
  end

  # The cast is ONE ATOMIC Body sequence: move the cursor to the water, a short pause so the
  # game registers the cursor there, then press the rod key. The rod is bound to Quick Cast, so
  # pressing it throws AT THE CURSOR — no click needed (Lucas). It MUST still be atomic: if the
  # move and the press were split across performs, a combat action at :high could move the cursor
  # between them, casting the rod onto the battle panel instead of the water (the "usando a vara
  # no campo de batalha" bug). One perform means nothing can land between positioning and casting.
  defp do_step(%{state: :casting} = logic, _obs, now) do
    cast(logic, now)
  end

  # Bubbles AND the water already settled (splash gone) → a real bite. Require N
  # consecutive frames so a lone flicker doesn't hook. A real bite always yields
  # a pokemon (there's no "caught nothing"), so once hooked we trust the catch
  # and loop straight back to :casting — no combat here. The hooked fish lands
  # on the battle list on its own; Combat.Logic picks it up independently.
  defp do_step(%{state: :watching, settled?: true} = logic, %{glow: true} = obs, now) do
    streak = logic.glow_streak + 1

    cond do
      streak < logic.config.glow_streak_needed ->
        # a bite signal, even mid-debounce, means the line is live → clear dead_streak
        {%{
           logic
           | glow_streak: streak,
             dead_streak: 0,
             holding?: false,
             holding_since: nil,
             hold_reason: nil
         }, []}

      hold_gate?(logic, obs) and not hold_expired?(logic, now) ->
        # Bite confirmed, but a hook gate is closed (skills on cooldown and/or the
        # Pokémon can't take the fight) → HOLD the fish: keep the line live and the
        # bite debounce saturated, DON'T press the rod and DON'T count a hook (the
        # bubbles keep flashing until we pull, so the bite window never closes).
        # Announce the hold ONCE, not per frame.
        #
        # A real bite OSCILLATES across the threshold (raw 2..1513), so a hold is a run
        # of peaks (this clause) interleaved with troughs (the settled/no-glow clause).
        # REFRESH entered_at on every peak so the watch_timeout_ms backstop measures
        # time-since-last-bite, not time-since-cast — otherwise a >30s hold (hook skills
        # are ~40s) would trip the timeout on a trough frame and abandon a live fish.
        log = if logic.holding?, do: [], else: [{:log, hold_log(logic, obs)}]

        {%{
           logic
           | glow_streak: streak,
             dead_streak: 0,
             holding?: true,
             holding_since: logic.holding_since || now,
             # refreshed per peak, so a reason that changes mid-hold (cooldown
             # cleared, HP still low) stays current on the panel.
             hold_reason: hold_reason(logic, obs),
             entered_at: now
         }, log}

      true ->
        logic = update_in(logic.counters.hooked, &(&1 + 1))

        # A hold that outlived hook_hold_max_ms falls through to here and pulls anyway —
        # the loud log is the tell that either the watched cooldowns are longer than the
        # ceiling or the skill-bar read is stuck. This bail (NOT a fail-open on a missing
        # reading) is the only "don't hold forever" protection.
        bail_log =
          if hold_gate?(logic, obs),
            do: [{:log, "⏳ fisga segurada até o teto com gate fechado — puxando mesmo assim"}],
            else: []

        {advance(
           %{
             logic
             | glow_streak: 0,
               holding?: false,
               holding_since: nil,
               hold_reason: nil,
               last_action: %{text: "fisgada", at: now}
           },
           :casting,
           now,
           wait: logic.config.wait_assess_ms
         ), bail_log ++ [{:press, logic.config.rod_key}]}
    end
  end

  # Cyan while NOT yet settled = a splash crest → ignore it AND reset the calm
  # run, so an oscillating splash can never accumulate toward "settled". Bubble
  # activity is a live line, so the dead-frame streak resets too.
  defp do_step(%{state: :watching, settled?: false} = logic, %{glow: true}, now) do
    recast_if_dead(%{logic | glow_streak: 0, calm_streak: 0, dead_streak: 0}, now)
  end

  # No bite while ALREADY settled → normal watch: keep settled, reset the bite
  # debounce. The dead-frame streak only climbs on NEAR-EMPTY water (see
  # next_dead_streak) — a line pulsing below the bite threshold still counts as
  # present and resets it.
  defp do_step(%{state: :watching, settled?: true} = logic, obs, now) do
    # PRESERVE holding? here (don't reset it): a trough between bite peaks must not
    # clear the hold, or the next peak re-announces "🔒 fisga segurada" every frame.
    # holding? is cleared only on a real hook or a fresh cast. dead_streak stays 0
    # while the line pulses (line? true) and entered_at was refreshed on the last
    # peak, so recast_if_dead is a no-op during a genuine hold and only recovers if
    # the bite truly dies.
    recast_if_dead(%{logic | glow_streak: 0, dead_streak: next_dead_streak(logic, obs, now)}, now)
  end

  # No bite while NOT yet settled → accumulate the consecutive-calm run; latch
  # settled? only once it reaches calm_streak_needed (splash gone). The dead-frame
  # streak follows line presence, not calm (see next_dead_streak).
  defp do_step(%{state: :watching, settled?: false} = logic, obs, now) do
    calm = logic.calm_streak + 1
    settled? = calm >= logic.config.calm_streak_needed

    recast_if_dead(
      %{
        logic
        | glow_streak: 0,
          calm_streak: calm,
          settled?: settled?,
          dead_streak: next_dead_streak(logic, obs, now)
      },
      now
    )
  end

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
      {advance(%{logic | failures: failures}, :casting, now), [{:log, reason}]}
    end
  end

  defp advance(logic, state, now, opts \\ []) do
    wait = Keyword.get(opts, :wait)
    %{logic | state: state, entered_at: now, waiting_until: wait && now + wait}
  end

  # Auto-recovery when the water shows no bite for too long — a dropped rod press
  # or a cast that never put a line in the water leaves us watching empty water,
  # reading 0 forever. Re-throw when EITHER the consecutive no-bubble streak hits
  # watch_dead_streak_needed (the fast path) OR the absolute watch_timeout_ms
  # elapses (backstop). Recasting RE-ARMS the rod (press the rod key) and
  # RE-THROWS atomically in the same step — a bare re-click of the water
  # can't recover a cast whose rod was never used. A real/building bite resets
  # dead_streak (see the glow:true clauses), so an active bite is never cut short.
  defp recast_if_dead(logic, now) do
    cond do
      logic.dead_streak >= logic.config.watch_dead_streak_needed ->
        cast(logic, now, [
          {:log, "sem bolha #{logic.dead_streak}f — re-lançando"}
        ])

      timed_out?(logic, now, logic.config.watch_timeout_ms) ->
        cast(logic, now, [{:log, "timeout bolha — re-lançando"}])

      true ->
        {logic, []}
    end
  end

  defp cast(logic, now, prefix_actions \\ []) do
    logic = update_in(logic.counters.cycles, &(&1 + 1))

    # The DRY CAST: a whole cycle in which the LINE never showed up. A swallowed
    # rod key (gate, focus, key helper) returns :ok and the water simply stays
    # empty — the screen is the only witness the cast happened. N dry cycles in a
    # row → alarm, and the count restarts (re-alarms if still dry). Casting
    # continues: the alarm wakes the human, it doesn't stop the rod.
    #
    # The witness is the LINE, not a BITE. Waiting a whole cycle without a bite
    # is what fishing IS — counting that as dry made the alarm cry "a tecla da
    # vara não está chegando no jogo" over a rod that was working perfectly.
    dry = if logic.line_seen?, do: 0, else: logic.dry_casts + 1
    threshold = Map.get(logic.config, :dry_casts_alarm, 0)

    {dry, alarm_actions} =
      if threshold > 0 and dry >= threshold do
        {0,
         [
           {:alarm,
            "🎣 #{dry} arremessos sem a isca aparecer na água — a tecla da vara pode não " <>
              "estar chegando no jogo (foco? portão? helper de teclas?)"}
         ]}
      else
        {dry, []}
      end

    logic = %{logic | line_seen?: false, dry_casts: dry}

    # Enter watching NOT settled: the cast splash also flashes cyan, so we must
    # first see the water go calm (splash gone) before a cyan spike counts as a
    # real bite. Settling now requires N CONSECUTIVE calm frames (not one), so an
    # oscillating splash can't latch it. The settle-wait skips the bulk of the
    # splash up front.
    logic =
      advance(
        %{
          logic
          | glow_streak: 0,
            calm_streak: 0,
            dead_streak: 0,
            settled?: false,
            holding?: false,
            holding_since: nil,
            hold_reason: nil,
            last_action: %{text: "arremesso da isca", at: now}
        },
        :watching,
        now,
        wait: logic.config.wait_cast_settle_ms
      )

    actions =
      prefix_actions ++
        alarm_actions ++
        [
          {:move, logic.config.water_point},
          {:wait, logic.config.wait_after_equip_ms},
          {:press, logic.config.rod_key}
        ]

    {logic, actions}
  end

  # A no-bite frame only counts toward the dead-frame streak when the water is
  # NEAR-EMPTY (no line? flag = bubble px below line_present_min_px). A cast line
  # resting between bites still pulses well above that floor, so it reads line? and
  # RESETS the streak — a live line is never recast. Only genuinely empty water (a
  # dropped rod / a cast that never landed, reading ~0) counts up toward re-throw.
  #
  # ...and only AFTER the bait has had time to land. The rod key does not put the
  # lure in the water: the throw arcs, and the lure appears seconds later (MEASURED
  # on Lucas's 3440×1440, journal 2026-08-10: 2-5s from the key to the first frame
  # with any lure pixel, on every cast). The streak used to start at the instant of
  # the cast, so "o cast falhou" was decided while the bait was still in the air —
  # and the recast's key press yanked the bait that had just landed back OUT of the
  # water. Empty water inside cast_grace_ms is EXPECTED, not evidence.
  defp next_dead_streak(logic, obs, now) do
    cond do
      line_present?(obs) -> 0
      within_cast_grace?(logic, now) -> 0
      true -> logic.dead_streak + 1
    end
  end

  # Measured from entered_at, which the cast sets — and which only a bite peak
  # refreshes (a bite resets the streak anyway, so a hold never re-opens the grace).
  defp within_cast_grace?(logic, now),
    do: now - logic.entered_at < Map.get(logic.config, :cast_grace_ms, 5_000)

  defp line_present?(%{line?: present?}), do: present?
  defp line_present?(_obs), do: false

  # Every hook gate in one place: the pull is held while ANY of them is closed.
  # Casting is never gated — only this clause (the confirmed-bite pull) consults it.
  defp hold_gate?(logic, obs),
    do: hold_for_cooldowns?(logic, obs) or hold_for_pokemon?(obs)

  defp hold_log(logic, obs), do: "🔒 fisga segurada — " <> hold_reason(logic, obs)

  # One text for the WHY of a hold, shared by the once-only log and the struct
  # field the panel snapshot carries — the two can never disagree.
  defp hold_reason(logic, obs) do
    [
      if(hold_for_cooldowns?(logic, obs), do: "skills em cooldown"),
      if(hold_for_pokemon?(obs),
        do: Map.get(obs, :pokemon_hold_reason, "pokémon sem condição")
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" + ")
  end

  # The fishing→combat cooldown gate: hold the fish when require_cooldowns is on and
  # NOT ONE kill-skill is ready (the sensor computes cooldowns_ready? as ANY-ready over
  # hook_skill_keys). An UNKNOWN reading (nil — capture failed / bar unreadable) HOLDS:
  # treating unknown as ready pulled fish with nothing to kill them the moment one read
  # glitched. The hook_hold_max_ms bail (not a fail-open) is what prevents a softlock.
  # An observation WITHOUT the key (gate off → sensor never asked) still reads ready.
  defp hold_for_cooldowns?(logic, obs),
    do: require_cooldowns?(logic) and not cooldowns_ready?(obs)

  defp require_cooldowns?(logic), do: Map.get(logic.config, :require_cooldowns, false)

  defp cooldowns_ready?(%{cooldowns_ready?: ready?}), do: ready? == true
  defp cooldowns_ready?(_obs), do: true

  # The fishing→support HP gate: the WORKER computes pokemon_ok? per tick from the
  # :pokemon blackboard fact + the require_pokemon_hp/pokemon_hp_fishing_pct settings
  # (so the panel toggle applies instantly, no restart). Absent key = gate off or no
  # opinion (fact stale/missing) — never hold on a dead monitor.
  defp hold_for_pokemon?(obs), do: Map.get(obs, :pokemon_ok?, true) == false

  defp hold_expired?(%{holding_since: nil}, _now), do: false

  defp hold_expired?(logic, now),
    do: now - logic.holding_since > Map.get(logic.config, :hook_hold_max_ms, 180_000)

  defp timed_out?(logic, now, ms), do: now - logic.entered_at > ms

  defp kill_corner?(%{cursor: cursor}), do: Corner.in_kill_corner?(cursor)
  defp kill_corner?(_obs), do: false
end
