defmodule Pokex.Bots.Combat.Logic do
  @moduledoc """
  Pure Tab-targeting state machine. No side effects, no captures, no clock of its own: the
  driver feeds it battle OBSERVATIONS from the perception blackboard (or nil on a timer
  wake) plus monotonic `now`, and executes the returned keyboard-only actions.

  hunting  — enemies visible in the battle list → press Tab (the game selects the first
             attackable enemy) → tabbing. A hunt hold (after exhausted Tab attempts)
             throttles retries against an unattackable-but-visible row.
  tabbing  — wait for the lock ring on a frame captured AFTER the Tab (the confirm window
             counts from the press, so capture latency can't eat it — the old click flow's
             500ms window expired before its first read). No lock in tab_confirm_ms →
             re-Tab (cycles to the next candidate) up to tab_max_attempts, then hunt-hold.
  fighting — lock up → fire the next blind-rotation skill burst, throttled by
             skill_burst_every_ms (observations arrive faster than keys should). Lock gone
             target_lost_streak OBSERVED frames in a row → the target died: count the kill
             and hunt the next one (a nil/timer wake never counts — only real frames vote).

  There is NO mouse anywhere: Tab and skills are keys, the Guardian owns the panic corner,
  and the Body is not involved.
  """

  defstruct state: :idle,
            config: nil,
            entered_at: 0,
            tabbed_at: nil,
            tab_attempts: 0,
            hold_until: nil,
            last_obs_at: nil,
            skill_idx: 0,
            last_burst_at: nil,
            lost_streak: 0,
            locked_row: nil,
            failures: 0,
            error: nil,
            counters: %{fights: 0, loots: 0, captures: 0, failures: 0}

  # -- lifecycle ------------------------------------------------------------

  def new(config), do: %__MODULE__{config: config}

  def start(%__MODULE__{state: state} = logic, now) when state in [:idle, :error] do
    {%{
       logic
       | state: :hunting,
         entered_at: now,
         tabbed_at: nil,
         tab_attempts: 0,
         hold_until: nil,
         skill_idx: 0,
         last_burst_at: nil,
         lost_streak: 0,
         locked_row: nil,
         failures: 0,
         error: nil
     }, []}
  end

  def start(logic, _now), do: {logic, []}

  def stop(logic), do: {%{logic | state: :idle}, []}

  def io_failed(logic, reason, now), do: fail(logic, now, reason)

  @doc "A fish was hooked → an attackable enemy is imminent: drop any hunt hold."
  def rescan(%__MODULE__{state: :hunting} = logic, now),
    do: %{logic | hold_until: nil, entered_at: now}

  def rescan(logic, _now), do: logic

  # -- stepping ---------------------------------------------------------------

  @doc """
  Step on a battle observation (map with :enemies/:locked?/:locked_row/:captured_at) or nil
  (timer wake — only time-based rules apply). Returns {logic, actions}.

  Frame dedup: an observation whose `:captured_at` is not strictly newer than the last one
  this machine actually consumed is normalized to nil (no vote, no burst — time-based rules
  still apply). That makes it safe to feed the SAME WorldState entry twice — once from the
  "world" PubSub event, once from a racing `:wake` poll — without double-counting things
  like the lost streak or firing a redundant burst.
  """
  def step(%__MODULE__{} = logic, obs, now) do
    {logic, obs} = dedup(logic, obs)
    do_step(logic, obs, now)
  end

  defp do_step(%__MODULE__{state: state} = logic, _obs, _now) when state in [:idle, :error],
    do: {logic, []}

  defp do_step(%{state: :hunting} = logic, obs, now) do
    cond do
      logic.hold_until != nil and now < logic.hold_until ->
        {logic, []}

      enemies(obs) != [] ->
        {tab(%{logic | hold_until: nil}, now), [{:tab}, {:log, "alvo na lista; Tab"}]}

      true ->
        {%{logic | hold_until: nil, locked_row: nil}, []}
    end
  end

  defp do_step(%{state: :tabbing} = logic, obs, now) do
    cond do
      fresh_lock?(obs, logic.tabbed_at) ->
        # confirmed on a post-Tab frame → fight, and don't waste this event: first burst now.
        logic = %{
          logic
          | state: :fighting,
            entered_at: now,
            lost_streak: 0,
            locked_row: obs.locked_row,
            last_burst_at: nil
        }

        press_next_skill(logic, now)

      now - logic.tabbed_at > logic.config.tab_confirm_ms and
          logic.tab_attempts < logic.config.tab_max_attempts ->
        {tab(logic, now), [{:tab}, {:log, "sem lock; Tab #{logic.tab_attempts + 1}"}]}

      now - logic.tabbed_at > logic.config.tab_confirm_ms ->
        {%{
           logic
           | state: :hunting,
             entered_at: now,
             tabbed_at: nil,
             tab_attempts: 0,
             hold_until: now + logic.config.hunt_cooldown_ms
         }, [{:log, "Tab não lockou; pausa na caça"}]}

      true ->
        {logic, []}
    end
  end

  defp do_step(%{state: :fighting} = logic, obs, now) do
    cond do
      now - logic.entered_at > logic.config.fight_timeout_ms ->
        {rehunt(logic, now), [{:log, "timeout do alvo; recaçando"}]}

      locked?(obs) ->
        logic = %{logic | lost_streak: 0, locked_row: obs.locked_row}
        press_next_skill(logic, now)

      observed?(obs) and logic.lost_streak + 1 >= logic.config.target_lost_streak ->
        logic = update_in(logic.counters.fights, &(&1 + 1))
        {rehunt(logic, now), [{:log, "alvo morto; caçando o próximo"}]}

      observed?(obs) ->
        {%{logic | lost_streak: logic.lost_streak + 1}, []}

      true ->
        # timer wake without a fresh frame: only the timeout above may act.
        {logic, []}
    end
  end

  @doc """
  When the driver must wake us even if no observation arrives: in :tabbing/:fighting, poll
  at the burst cadence (capped by the terminal deadline — window expiry / fight timeout) so
  a STATIC screen still makes progress (the lost streak advances, skill bursts keep firing)
  even though the feed only broadcasts on content CHANGE — `WorldState.get/3` still hands
  the wake a fresh `:captured_at` every capture tick, and `step/3`'s dedup keeps a repeat
  read (same frame, no new tick yet) from double-counting. In :hunting with a hold, wake
  when the hold clears. Free :hunting ALSO polls (at the burst cadence): after a
  kill/timeout/io_failed rehunt the battle list can be non-empty but pixel-STATIC (the row
  the previous target vacated stays put, nothing else changes), and the feed only
  broadcasts on content change — a purely event-driven free hunt would then wait forever
  for a "world" event that never comes. :idle/:error need no timer (purely event-driven).
  """
  def next_wake(%__MODULE__{state: :tabbing} = logic, now) do
    max(
      min(
        max(logic.tabbed_at + logic.config.tab_confirm_ms - now, 1),
        logic.config.skill_burst_every_ms
      ),
      1
    )
  end

  def next_wake(%__MODULE__{state: :fighting} = logic, now) do
    max(
      min(
        max(logic.entered_at + logic.config.fight_timeout_ms - now, 1),
        logic.config.skill_burst_every_ms
      ),
      1
    )
  end

  def next_wake(%__MODULE__{state: :hunting, hold_until: until}, now) when is_integer(until),
    do: max(until - now, 1)

  def next_wake(%__MODULE__{state: :hunting} = logic, _now),
    do: max(logic.config.skill_burst_every_ms, 1)

  def next_wake(_logic, _now), do: nil

  # -- helpers ----------------------------------------------------------------

  defp tab(logic, now),
    do: %{
      logic
      | state: :tabbing,
        entered_at: now,
        tabbed_at: now,
        tab_attempts: logic.tab_attempts + 1
    }

  defp rehunt(logic, now) do
    %{
      logic
      | state: :hunting,
        entered_at: now,
        tabbed_at: nil,
        tab_attempts: 0,
        lost_streak: 0,
        skill_idx: 0,
        last_burst_at: nil,
        locked_row: nil
    }
  end

  # Blind rotation, throttled: observations arrive at feed cadence (~120ms) but keys should
  # fire at skill cadence (~300ms) — without the throttle the feed would triple the key rate.
  defp press_next_skill(%{config: %{skill_keys: []}} = logic, _now), do: {logic, []}

  defp press_next_skill(%{config: config} = logic, now) do
    if logic.last_burst_at != nil and now - logic.last_burst_at < config.skill_burst_every_ms do
      {logic, []}
    else
      burst = max(config.combat_skill_burst_size, 1)
      len = length(config.skill_keys)

      actions =
        for offset <- 0..(burst - 1) do
          {:press, Enum.at(config.skill_keys, rem(logic.skill_idx + offset, len))}
        end

      {%{logic | skill_idx: logic.skill_idx + burst, last_burst_at: now}, actions}
    end
  end

  defp fail(%__MODULE__{} = logic, now, reason) do
    failures = logic.failures + 1
    logic = update_in(logic.counters.failures, &(&1 + 1))
    reason = to_string(reason)

    if failures >= logic.config.max_consecutive_failures do
      {%{logic | state: :error, failures: failures, error: "#{reason} (#{failures}x seguidas)"},
       [{:log, reason}]}
    else
      {%{rehunt(logic, now) | failures: failures}, [{:log, reason}]}
    end
  end

  defp enemies(nil), do: []
  defp enemies(obs), do: obs[:enemies] || []

  defp observed?(obs), do: obs != nil

  defp locked?(nil), do: false
  defp locked?(obs), do: obs[:locked?] == true

  defp fresh_lock?(nil, _tabbed_at), do: false

  # Strict > : the confirm window counts from the press, so a frame captured AT OR BEFORE
  # the Tab (stale — it was already in flight, or is the very frame the press itself reacted
  # to) must not confirm. Only a frame captured strictly AFTER proves the lock landed.
  defp fresh_lock?(obs, tabbed_at),
    do: obs[:locked?] == true and is_integer(obs[:captured_at]) and obs[:captured_at] > tabbed_at

  # Normalizes a repeat/stale observation to nil so every state clause above sees only
  # genuinely new frames. `obs[:captured_at] <= last_obs_at` catches the SAME WorldState
  # entry read twice (a "world" event and a racing `:wake` poll landing on the same
  # unbroadcast tick) — it does NOT catch a fresh entry the feed just wrote, since that
  # carries a newer `:captured_at` even when its content is unchanged.
  defp dedup(logic, nil), do: {logic, nil}

  defp dedup(logic, obs) do
    if logic.last_obs_at != nil and obs[:captured_at] <= logic.last_obs_at do
      {logic, nil}
    else
      {%{logic | last_obs_at: obs[:captured_at]}, obs}
    end
  end
end
