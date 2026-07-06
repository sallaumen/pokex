defmodule Pokex.Bots.Fisher.Logic do
  @moduledoc """
  Pure state machine for the full fishing cycle (spec §5). No side effects:
  the driver gathers observations, calls step/3, and executes the returned
  actions. Times are monotonic milliseconds supplied by the caller.
  """

  defstruct state: :idle,
            config: nil,
            entered_at: 0,
            waiting_until: nil,
            last_hostile: nil,
            skill_idx: 0,
            fight_tick: 0,
            targeted?: false,
            fallback_idx: 0,
            failures: 0,
            error: nil,
            counters: %{cycles: 0, hooked: 0, fights: 0, loots: 0, captures: 0, failures: 0}

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
  def needs(%__MODULE__{state: :assessing}), do: [:cursor, :wild]

  def needs(%__MODULE__{state: :fighting} = logic) do
    if scan_tick?(logic), do: [:cursor, :wild, :hostile], else: [:cursor, :wild]
  end

  def needs(_logic), do: [:cursor]

  def tick_interval(%__MODULE__{state: :watching, config: c}), do: c.tick_ms_watching
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

  defp do_step(%{state: :focusing} = logic, _obs, now) do
    {advance(logic, :equipping, now, wait: logic.config.wait_focus_ms),
     [{:click, :left, logic.config.neutral_point}]}
  end

  defp do_step(%{state: :equipping} = logic, _obs, now) do
    {advance(logic, :casting, now, wait: logic.config.wait_after_equip_ms), [{:press, "shift+z"}]}
  end

  defp do_step(%{state: :casting} = logic, _obs, now) do
    logic = update_in(logic.counters.cycles, &(&1 + 1))
    {advance(logic, :watching, now), [{:click, :left, logic.config.water_point}]}
  end

  defp do_step(%{state: :watching} = logic, %{glow: true}, now) do
    logic = update_in(logic.counters.hooked, &(&1 + 1))
    {advance(logic, :assessing, now, wait: logic.config.wait_assess_ms), [{:press, "shift+z"}]}
  end

  defp do_step(%{state: :watching} = logic, _obs, now) do
    if timed_out?(logic, now, logic.config.watch_timeout_ms) do
      {advance(logic, :casting, now), [{:log, "sem brilho a tempo — arremessando de novo"}]}
    else
      {logic, []}
    end
  end

  defp do_step(%{state: :assessing} = logic, %{wild: true}, now) do
    logic = %{logic | targeted?: false, fight_tick: 0, skill_idx: 0, last_hostile: nil}
    {advance(logic, :fighting, now), []}
  end

  defp do_step(%{state: :assessing} = logic, _obs, now) do
    {advance(logic, :equipping, now), [{:log, "nada fisgado — recomeçando"}]}
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

  defp timed_out?(logic, now, ms), do: now - logic.entered_at > ms

  defp kill_corner?(%{cursor: {x, y}}) when x <= 10 and y <= 10, do: true
  defp kill_corner?(_obs), do: false

  defp scan_tick?(%__MODULE__{fight_tick: tick, config: c}),
    do: rem(tick, max(c.hostile_scan_every, 1)) == 0
end
