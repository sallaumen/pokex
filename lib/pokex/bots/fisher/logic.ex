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
            select_idx: 0,
            pending_verify?: false,
            fallback_idx: 0,
            glow_streak: 0,
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

  def needs(%__MODULE__{state: :fighting, targeted?: false, pending_verify?: true}),
    do: [:cursor, :target_locked]

  def needs(%__MODULE__{state: :fighting, targeted?: false}), do: [:cursor]

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

    {advance(%{logic | glow_streak: 0}, :watching, now),
     [{:click, :left, logic.config.water_point}]}
  end

  # Require N consecutive glow frames so the line landing (a one-frame flash)
  # doesn't fake a bite — only a sustained glow (the real bite) hooks.
  defp do_step(%{state: :watching} = logic, %{glow: true}, now) do
    streak = logic.glow_streak + 1

    if streak >= logic.config.glow_streak_needed do
      logic = update_in(logic.counters.hooked, &(&1 + 1))

      {advance(%{logic | glow_streak: 0}, :assessing, now, wait: logic.config.wait_assess_ms),
       [{:press, "shift+z"}]}
    else
      {%{logic | glow_streak: streak}, []}
    end
  end

  defp do_step(%{state: :watching} = logic, _obs, now) do
    logic = %{logic | glow_streak: 0}

    if timed_out?(logic, now, logic.config.watch_timeout_ms) do
      {advance(logic, :casting, now), [{:log, "sem brilho a tempo — arremessando de novo"}]}
    else
      {logic, []}
    end
  end

  defp do_step(%{state: :assessing} = logic, %{wild: true}, now) do
    logic = %{
      logic
      | targeted?: false,
        select_idx: 0,
        pending_verify?: false,
        fight_tick: 0,
        skill_idx: 0,
        last_hostile: nil
    }

    {advance(logic, :fighting, now), []}
  end

  defp do_step(%{state: :assessing} = logic, _obs, now) do
    {advance(logic, :equipping, now), [{:log, "nada fisgado — recomeçando"}]}
  end

  # Target selection: click a Battle row, then verify a FIXED red border locked
  # onto it. If it only blinked (own pokemon / player), try the next row down.
  defp do_step(%{state: :fighting, targeted?: false, pending_verify?: false} = logic, _obs, now) do
    rows = logic.config.battle_rows

    if logic.select_idx >= length(rows) do
      {advance(%{logic | select_idx: 0}, :equipping, now),
       [{:log, "nenhum alvo atacável na Battle — recomeçando"}]}
    else
      {advance(%{logic | pending_verify?: true}, :fighting, now,
         wait: logic.config.wait_target_verify_ms
       ), [{:click, :left, Enum.at(rows, logic.select_idx)}]}
    end
  end

  defp do_step(%{state: :fighting, targeted?: false, pending_verify?: true} = logic, obs, _now) do
    if Map.get(obs, :target_locked) do
      {%{logic | targeted?: true, pending_verify?: false}, []}
    else
      {%{logic | select_idx: logic.select_idx + 1, pending_verify?: false}, []}
    end
  end

  defp do_step(%{state: :fighting} = logic, %{wild: false}, now) do
    logic = update_in(logic.counters.fights, &(&1 + 1))
    {advance(%{logic | fallback_idx: 0}, :looting, now), []}
  end

  defp do_step(%{state: :fighting} = logic, obs, now) do
    if timed_out?(logic, now, logic.config.fight_timeout_ms) do
      fail(logic, now, "luta estourou o tempo")
    else
      logic = %{
        logic
        | last_hostile: Map.get(obs, :hostile) || logic.last_hostile,
          fight_tick: logic.fight_tick + 1
      }

      key =
        Enum.at(logic.config.skill_keys, rem(logic.skill_idx, length(logic.config.skill_keys)))

      logic = %{logic | skill_idx: logic.skill_idx + 1}
      {logic, [{:press, key}]}
    end
  end

  defp do_step(%{state: :looting} = logic, _obs, now) do
    corpse = corpse_point(logic)

    cond do
      corpse != nil ->
        logic = update_in(logic.counters.loots, &(&1 + 1))

        {advance(logic, :capturing, now, wait: logic.config.wait_loot_ms),
         [{:click, :right, corpse}]}

      logic.fallback_idx < length(logic.config.fallback_points) ->
        point = Enum.at(logic.config.fallback_points, logic.fallback_idx)
        {%{logic | fallback_idx: logic.fallback_idx + 1}, [{:click, :right, point}]}

      true ->
        logic = update_in(logic.counters.loots, &(&1 + 1))
        {advance(logic, :capturing, now, wait: logic.config.wait_loot_ms), []}
    end
  end

  defp do_step(%{state: :capturing} = logic, _obs, now) do
    target = corpse_point(logic) || logic.config.water_point
    logic = %{logic | failures: 0, last_hostile: nil}

    {logic, actions} =
      if logic.config.auto_capture do
        {update_in(logic.counters.captures, &(&1 + 1)), [{:capture_sequence, target}]}
      else
        {logic, [{:log, "auto-captura desligada — sem pokébola"}]}
      end

    {advance(logic, :equipping, now, wait: logic.config.wait_after_capture_ms), actions}
  end

  defp corpse_point(%{last_hostile: nil}), do: nil

  defp corpse_point(%{last_hostile: {x, y}, config: config}),
    do: {x, y + config.tile_size}

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
