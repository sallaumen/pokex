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
  def needs(%__MODULE__{state: :watching}), do: [:cursor, :glow]
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
    {advance(logic, :equipping, now, wait: logic.config.wait_focus_ms),
     [{:click, :left, logic.config.neutral_point}]}
  end

  defp do_step(%{state: :equipping} = logic, _obs, now) do
    {advance(logic, :casting, now, wait: logic.config.wait_after_equip_ms),
     [{:press, logic.config.rod_key}]}
  end

  defp do_step(%{state: :casting} = logic, _obs, now) do
    logic = update_in(logic.counters.cycles, &(&1 + 1))

    # Enter watching NOT settled: the cast splash also flashes cyan, so we must
    # first see the water go calm (splash gone) before a cyan spike counts as a
    # real bite. Settling now requires N CONSECUTIVE calm frames (not one), so an
    # oscillating splash can't latch it. The settle-wait skips the bulk of the
    # splash up front.
    {advance(
       %{logic | glow_streak: 0, calm_streak: 0, dead_streak: 0, settled?: false},
       :watching,
       now, wait: logic.config.wait_cast_settle_ms), [{:click, :left, logic.config.water_point}]}
  end

  # Bubbles AND the water already settled (splash gone) → a real bite. Require N
  # consecutive frames so a lone flicker doesn't hook. A real bite always yields
  # a pokemon (there's no "caught nothing"), so once hooked we trust the catch
  # and loop straight back to :casting — no combat here. The hooked fish lands
  # on the battle list on its own; Combat.Logic picks it up independently.
  defp do_step(%{state: :watching, settled?: true} = logic, %{glow: true}, now) do
    streak = logic.glow_streak + 1

    if streak >= logic.config.glow_streak_needed do
      logic = update_in(logic.counters.hooked, &(&1 + 1))

      {advance(%{logic | glow_streak: 0}, :casting, now, wait: logic.config.wait_assess_ms),
       [{:press, logic.config.rod_key}]}
    else
      # a bite signal, even mid-debounce, means the line is live → clear dead_streak
      {%{logic | glow_streak: streak, dead_streak: 0}, []}
    end
  end

  # Cyan while NOT yet settled = a splash crest → ignore it AND reset the calm
  # run, so an oscillating splash can never accumulate toward "settled". Bubble
  # activity is a live line, so the dead-frame streak resets too.
  defp do_step(%{state: :watching, settled?: false} = logic, %{glow: true}, now) do
    recast_if_dead(%{logic | glow_streak: 0, calm_streak: 0, dead_streak: 0}, now)
  end

  # Calm frame while ALREADY settled → normal calm during the watch: keep
  # settled, reset only the bite debounce. No bubble → count a dead frame.
  defp do_step(%{state: :watching, settled?: true} = logic, _obs, now) do
    recast_if_dead(%{logic | glow_streak: 0, dead_streak: logic.dead_streak + 1}, now)
  end

  # Calm frame while NOT yet settled → accumulate the consecutive-calm run;
  # latch settled? only once it reaches calm_streak_needed (splash gone). Still no
  # bubble → count a dead frame toward the recast backstop.
  defp do_step(%{state: :watching, settled?: false} = logic, _obs, now) do
    calm = logic.calm_streak + 1
    settled? = calm >= logic.config.calm_streak_needed

    recast_if_dead(
      %{
        logic
        | glow_streak: 0,
          calm_streak: calm,
          settled?: settled?,
          dead_streak: logic.dead_streak + 1
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
      {advance(%{logic | failures: failures}, :equipping, now), [{:log, reason}]}
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
  # elapses (backstop). Recasting routes through :equipping so the rod is RE-ARMED
  # (press the rod key) and RE-THROWN — a bare re-click of the water can't recover
  # a cast whose rod was never used. A real/building bite resets dead_streak (see
  # the glow:true clauses), so an active bite is never cut short.
  defp recast_if_dead(logic, now) do
    cond do
      logic.dead_streak >= logic.config.watch_dead_streak_needed ->
        {advance(logic, :equipping, now),
         [{:log, "sem bolha por #{logic.dead_streak} frames — re-lançando a vara"}]}

      timed_out?(logic, now, logic.config.watch_timeout_ms) ->
        {advance(logic, :equipping, now), [{:log, "sem bolha a tempo — re-lançando a vara"}]}

      true ->
        {logic, []}
    end
  end

  defp timed_out?(logic, now, ms), do: now - logic.entered_at > ms

  @doc "True when the cursor point sits in the top-left panic corner (mouse-to-corner = emergency stop)."
  def in_kill_corner?({x, y}) when x <= 10 and y <= 10, do: true
  def in_kill_corner?(_), do: false

  defp kill_corner?(%{cursor: cursor}), do: in_kill_corner?(cursor)
  defp kill_corner?(_obs), do: false
end
