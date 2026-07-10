defmodule Pokex.Bots.Fishing.Logic do
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
            failures: 0,
            error: nil,
            counters: %{cycles: 0, hooked: 0, failures: 0}

  # -- lifecycle ------------------------------------------------------------

  def new(config), do: %__MODULE__{config: config}

  def start(%__MODULE__{state: state} = logic, now) when state in [:idle, :error] do
    {%{logic | state: :focusing, entered_at: now, waiting_until: nil, failures: 0, error: nil},
     []}
  end

  def start(logic, _now), do: {logic, []}

  def stop(logic), do: {%{logic | state: :idle, waiting_until: nil}, []}

  def io_failed(logic, reason, now), do: fail(logic, now, reason)

  # -- driver hints ----------------------------------------------------------

  def needs(%__MODULE__{state: state}) when state in [:idle, :error], do: []

  # Only ask for the (capture-costly) cooldown reading when the gate is actually on —
  # otherwise fishing never touches the skill bar.
  def needs(%__MODULE__{state: :watching, config: config}) do
    if Map.get(config, :require_cooldowns, false),
      do: [:cursor, :glow, :cooldowns_ready?],
      else: [:cursor, :glow]
  end

  def needs(_logic), do: [:cursor]

  @doc "True while in a post-action pause: the driver skips sensing (no screen capture) until it ends."
  def waiting?(%__MODULE__{waiting_until: nil}, _now), do: false
  def waiting?(%__MODULE__{waiting_until: until}, now), do: now < until

  def tick_interval(%__MODULE__{state: :watching, config: c}), do: c.tick_ms_watching
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
        {%{logic | glow_streak: streak, dead_streak: 0, holding?: false}, []}

      hold_for_cooldowns?(logic, obs) ->
        # Bite confirmed, but require_cooldowns is on and NOT ONE kill-skill is ready
        # → HOLD the fish: keep the line live and the bite debounce saturated, DON'T
        # press the rod and DON'T count a hook (the bubbles keep flashing until we
        # pull, so the bite window never closes). Announce the hold ONCE, not per frame.
        #
        # A real bite OSCILLATES across the threshold (raw 2..1513), so a hold is a run
        # of peaks (this clause) interleaved with troughs (the settled/no-glow clause).
        # REFRESH entered_at on every peak so the watch_timeout_ms backstop measures
        # time-since-last-bite, not time-since-cast — otherwise a >30s hold (hook skills
        # are ~40s) would trip the timeout on a trough frame and abandon a live fish.
        log = if logic.holding?, do: [], else: [{:log, "🔒 fisga segurada — skills em cooldown"}]
        {%{logic | glow_streak: streak, dead_streak: 0, holding?: true, entered_at: now}, log}

      true ->
        logic = update_in(logic.counters.hooked, &(&1 + 1))

        {advance(%{logic | glow_streak: 0, holding?: false}, :casting, now,
           wait: logic.config.wait_assess_ms
         ), [{:press, logic.config.rod_key}]}
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
    recast_if_dead(%{logic | glow_streak: 0, dead_streak: next_dead_streak(logic, obs)}, now)
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
          dead_streak: next_dead_streak(logic, obs)
      },
      now
    )
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
            holding?: false
        },
        :watching,
        now,
        wait: logic.config.wait_cast_settle_ms
      )

    actions =
      prefix_actions ++
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
  defp next_dead_streak(logic, obs) do
    if line_present?(obs), do: 0, else: logic.dead_streak + 1
  end

  defp line_present?(%{line?: present?}), do: present?
  defp line_present?(_obs), do: false

  # The fishing→combat cooldown gate: hold the fish when require_cooldowns is on and
  # NOT ONE kill-skill is ready (the sensor computes cooldowns_ready? as ANY-ready over
  # hook_skill_keys). Defaults to true (fail-open) so a missing observation never
  # softlocks fishing.
  defp hold_for_cooldowns?(logic, obs),
    do: require_cooldowns?(logic) and not cooldowns_ready?(obs)

  defp require_cooldowns?(logic), do: Map.get(logic.config, :require_cooldowns, false)

  defp cooldowns_ready?(%{cooldowns_ready?: ready?}), do: ready?
  defp cooldowns_ready?(_obs), do: true

  defp timed_out?(logic, now, ms), do: now - logic.entered_at > ms

  defp kill_corner?(%{cursor: cursor}), do: Pokex.Bots.Corner.in_kill_corner?(cursor)
  defp kill_corner?(_obs), do: false
end
