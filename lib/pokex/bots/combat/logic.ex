defmodule Pokex.Bots.Combat.Logic do
  @moduledoc """
  Pure Tab-targeting state machine. No side effects, no captures, no clock of its own: the
  driver feeds it battle OBSERVATIONS from the perception blackboard (or nil on a timer
  wake) plus monotonic `now`, and executes the returned keyboard-only actions.

  hunting  — enemies visible in the battle list → press Tab (the game selects the first
             attackable enemy) → tabbing. A hunt hold (after exhausted Tab attempts)
             throttles retries against an unattackable-but-visible row; N held hunts in a
             row promote those rows to PRESUMED SCENERY (see give_up_hunt/2) — they stop
             being a reason to Tab, like the player's own row, until the list grows, the
             presumption expires, or it shrinks.
  tabbing  — wait for the lock ring on a frame captured AFTER the Tab (the confirm window
             counts from the press, so capture latency can't eat it — the old click flow's
             500ms window expired before its first read). No lock in tab_confirm_ms →
             re-Tab (cycles to the next candidate) up to tab_max_attempts, then hunt-hold.
  fighting — lock up → fire the next skill burst, throttled by skill_burst_every_ms
             (observations arrive faster than keys should). When the observation carries a
             fresh :skill_bar reading (obs[:ready_skills], merged in by the driver), only
             READY skills fire, in skill_keys priority order; without one (nil/empty/none
             of ours) the blind rotation runs unchanged — a bad read may waste presses,
             never stop the attack. Lock gone
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
            # post-Tab frames WITHOUT a lock actually SEEN — the evidence that
            # authorizes a re-Tab (blind re-Tab cycles the target; see :tabbing)
            post_tab_frames: 0,
            hold_until: nil,
            probe_until: nil,
            last_obs_at: nil,
            skill_idx: 0,
            last_burst_at: nil,
            lost_streak: 0,
            locked_row: nil,
            # SCENERY learning (2026-07-30: unattackable mob in the list = Tab
            # loop believing it fights): consecutive hunts that exhausted Tabs
            # with frame evidence and no lock (failed_hunts), the target count
            # seen when the hunt opened (hunt_enemies; 0 = blind probe, never
            # learns), and the "presumed scenery" — scenery_rows targets treated
            # as allies (like the own position) until scenery_until.
            failed_hunts: 0,
            hunt_enemies: 0,
            scenery_rows: nil,
            scenery_until: nil,
            failures: 0,
            error: nil,
            # What the HUNT asked of combat: `:free_fight` (always, historically
            # and by default) or `:hold_fire` while it walks a mob stretch
            # gathering enemies instead of fighting them. Set from the
            # `:posture` fact by the Worker; a stale or missing fact reads as
            # free fire, so a dead hunt can never leave combat pacifist.
            posture: :free_fight,
            # `captures` stays 0 here forever — captures live on Catcher.Logic since the
            # Catcher extraction — but the panel's merged_counters/3 still folds combat's
            # counters map into its merge (fishing → combat → catcher, last write wins), so
            # keep the key rather than let a missing key change that merge's shape.
            # `loots` was Loot.Logic's; Loot is deleted and nothing reads it here anymore.
            counters: %{fights: 0, captures: 0, failures: 0}

  def new(config), do: %__MODULE__{config: config}

  def start(%__MODULE__{state: state} = logic, now) when state in [:idle, :error] do
    {%{
       logic
       | state: :hunting,
         entered_at: now,
         tabbed_at: nil,
         tab_attempts: 0,
         hold_until: nil,
         probe_until: nil,
         skill_idx: 0,
         last_burst_at: nil,
         lost_streak: 0,
         locked_row: nil,
         # a new Start may be a new spot — presumed scenery does not travel
         failed_hunts: 0,
         hunt_enemies: 0,
         scenery_rows: nil,
         scenery_until: nil,
         failures: 0,
         error: nil
     }, []}
  end

  def start(logic, _now), do: {logic, []}

  def stop(logic), do: {%{logic | state: :idle}, []}

  def io_failed(logic, reason, now), do: fail(logic, now, reason)

  @doc """
  A fish was hooked → an attackable enemy is imminent: drop any hunt hold and open the Tab
  probe window (the new enemy may land before the HP-bar detector picks its row up).
  """
  def rescan(%__MODULE__{state: :hunting} = logic, now),
    do: %{logic | hold_until: nil, entered_at: now, probe_until: probe_deadline(logic, now)}

  def rescan(logic, _now), do: logic

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

  # Holding fire: no Tab, no probe, no skill at anything. A fight already under
  # way is DROPPED rather than finished — the hunt is walking away with a crowd
  # behind it, and skills landing on one of them is precisely what "andar sem
  # atacar ninguém" rules out.
  defp do_step(%__MODULE__{state: state, posture: :hold_fire} = logic, _obs, now)
       when state in [:tabbing, :fighting],
       do: {stand_down(logic, now), [{:log, "🕊️ segurando o fogo — a caçada está mobando"}]}

  defp do_step(%__MODULE__{state: :hunting, posture: :hold_fire} = logic, _obs, _now),
    do: {logic, []}

  defp do_step(%{state: :hunting} = logic, obs, now) do
    logic = refresh_scenery(logic, obs, now)

    cond do
      logic.hold_until != nil and now < logic.hold_until ->
        {logic, []}

      # Only targets BEYOND the presumed scenery justify a Tab — presumed ones
      # are de facto allies (like the own position). With no active presumption
      # any target counts, as always.
      length(enemies(obs)) > (logic.scenery_rows || 0) ->
        {tab(%{logic | hold_until: nil, hunt_enemies: length(enemies(obs))}, now),
         [{:tab}, {:log, "alvo na lista; Tab"}]}

      # Probe window (opened by a kill/timeout rehunt or a fish hook): press Tab even with NO
      # detected enemy. The HP-bar row detector going momentarily blind right after a kill left
      # 2-3 fished enemies standing unattacked — the worst possible idle. Tab is free: on an
      # empty list the game selects nothing, and the lock RING (the most reliable read we have)
      # is what confirms a real target in :tabbing. The window bounds the extra presses; probes
      # are naturally throttled by the tab-confirm/hunt-hold cycle itself.
      logic.probe_until != nil and now < logic.probe_until ->
        {tab(%{logic | hold_until: nil, hunt_enemies: 0}, now),
         [{:tab}, {:log, "sonda pós-kill; Tab às cegas"}]}

      true ->
        {%{logic | hold_until: nil, probe_until: nil, locked_row: nil}, []}
    end
  end

  defp do_step(%{state: :tabbing} = logic, obs, now) do
    logic = count_post_tab_frame(logic, obs)

    cond do
      fresh_lock?(obs, logic.tabbed_at) ->
        # confirmed on a post-Tab frame → fight, and don't waste this event: first burst now.
        # A real lock resets scenery learning — and disproves a presumption
        # covering the whole list (disprove_scenery/2).
        logic = %{
          disprove_scenery(logic, obs)
          | state: :fighting,
            entered_at: now,
            lost_streak: 0,
            locked_row: obs.locked_row,
            last_burst_at: nil,
            failed_hunts: 0
        }

        press_next_skill(logic, now, obs[:ready_skills])

      # Re-Tab ONLY with evidence: the window expired AND post-Tab frame(s)
      # without a lock were seen. Each extra Tab CYCLES the target to the next
      # enemy — clock-based re-Tab with no frame at all (slow/stuck capture)
      # was the endless-Tab-never-focusing failure with a full list.
      now - logic.tabbed_at > logic.config.tab_confirm_ms and
        logic.post_tab_frames >= logic.config.tab_confirm_frames and
          logic.tab_attempts < tab_attempts_allowed(logic, obs) ->
        {tab(logic, now), [{:tab}, {:log, "sem lock; Tab #{logic.tab_attempts + 1}"}]}

      now - logic.tabbed_at > logic.config.tab_confirm_ms and
          logic.post_tab_frames >= logic.config.tab_confirm_frames ->
        give_up_hunt(logic, obs, now)

      # The window expired but the evidence never CAME (no post-Tab frame): we
      # don't cycle targets blind — but we also don't wait forever on a capture
      # that may be dead. 4x the window without a frame → retreat to the
      # hunt-hold saying why, and the hunt retries later.
      now - logic.tabbed_at > logic.config.tab_confirm_ms * 4 ->
        {%{
           logic
           | state: :hunting,
             entered_at: now,
             tabbed_at: nil,
             tab_attempts: 0,
             hold_until: now + logic.config.hunt_cooldown_ms
         }, [{:log, "sem frame pós-Tab (captura lenta?); pausa na caça"}]}

      true ->
        {logic, []}
    end
  end

  defp do_step(%{state: :fighting} = logic, obs, now) do
    cond do
      now - logic.entered_at > logic.config.fight_timeout_ms ->
        {rehunt(logic, now), [{:log, "timeout do alvo; recaçando"}]}

      locked?(obs) ->
        logic = %{disprove_scenery(logic, obs) | lost_streak: 0, locked_row: obs.locked_row}
        press_next_skill(logic, now, obs[:ready_skills])

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

  # A genuinely new frame (dedup already filtered repeats), captured AFTER the
  # Tab and lock-free — the witness that the game had a chance to paint the
  # ring and didn't. Only that authorizes cycling the target.
  defp count_post_tab_frame(logic, obs) do
    if obs != nil and is_integer(obs[:captured_at]) and obs[:captured_at] > logic.tabbed_at and
         obs[:locked?] != true,
       do: %{logic | post_tab_frames: logic.post_tab_frames + 1},
       else: logic
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

  # A hunt exhausted WITH frame evidence and no lock — the visible mob that
  # won't lock (2026-07-30: SCENERY pokémon in the list; combat kept Tabbing an
  # unattackable enemy believing it fought). A blind probe (hunt_enemies=0)
  # learns nothing — an empty list has no scenery. A real hunt counts; on the
  # scenery_hunts_needed-th in a row (each costing tab_max_attempts Tabs), that
  # count's targets become PRESUMED SCENERY: no longer a reason to Tab, like
  # the own position. One EXTRA target hunts immediately; a shrinking list
  # clears it; the TTL re-probes periodically (self-corrects a wrong
  # presumption). A real lock resets the count (fresh_lock clause).
  defp give_up_hunt(logic, obs, now) do
    hold = %{
      logic
      | state: :hunting,
        entered_at: now,
        tabbed_at: nil,
        tab_attempts: 0,
        hold_until: now + logic.config.hunt_cooldown_ms
    }

    needed = hunts_needed(logic, obs)

    cond do
      logic.hunt_enemies == 0 or needed == 0 ->
        {hold, [{:log, "Tab não lockou; pausa na caça"}]}

      logic.failed_hunts + 1 >= needed ->
        ttl = Map.get(logic.config, :scenery_ttl_ms, 60_000)

        {%{
           hold
           | failed_hunts: 0,
             scenery_rows: logic.hunt_enemies,
             scenery_until: now + ttl
         },
         [
           {:log, scenery_log(logic.hunt_enemies, needed, ttl)}
         ]}

      true ->
        {%{hold | failed_hunts: logic.failed_hunts + 1},
         [{:log, "Tab não lockou; pausa na caça (#{logic.failed_hunts + 1}/#{needed})"}]}
    end
  end

  defp scenery_log(1, 1, ttl),
    do:
      "🗿 o único alvo da lista não lockou e teu pokémon está fora — presumo que é ELE " <>
        "(por #{div(ttl, 1000)}s); Tab só com alvo novo"

  defp scenery_log(rows, needed, ttl),
    do:
      "🗿 #{rows} alvo(s) sem lock em #{needed} caçadas — " <>
        "cenário presumido por #{div(ttl, 1000)}s; Tab só com alvo novo"

  # Every extra Tab CYCLES to the next enemy — which is the whole point with a
  # crowded list, and pure waste with ONE row: the same row is selected again,
  # three times, for two seconds (Lucas, 2026-08-10: "ainda tá bem lento").
  # With a single row, one Tab is the whole question.
  defp tab_attempts_allowed(logic, obs) do
    if length(enemies(obs)) == 1, do: 1, else: logic.config.tab_max_attempts
  end

  # How many failed hunts it takes to call a row scenery.
  #
  # The default (3) exists for a real question: is that mob unreachable, or did
  # the Tab merely miss? But when the list holds exactly ONE row AND his own
  # pokémon is out of its ball, the question is nearly answered before it is
  # asked — that row is almost certainly his own pokémon, which can never be
  # locked. Nine Tabs over ten seconds to learn it (Lucas, 2026-08-10) is the
  # bot standing still for nothing: ONE Tab settles the suspicion, and the
  # presumption still self-corrects (it expires, and a growing list drops it).
  defp hunts_needed(logic, obs) do
    needed = Map.get(logic.config, :scenery_hunts_needed, 0)

    cond do
      needed == 0 or logic.hunt_enemies != 1 -> needed
      # his pokémon is out and there is exactly one row: it is almost certainly
      # that pokémon, and one lockless hunt settles it
      own_out?(obs) -> 1
      # a lone row that will not lock, twice in a row — still far quicker than
      # the three hunts written for a crowded list, and one hunt is now a
      # single Tab, so this costs ~2s instead of ~10s
      true -> min(needed, 2)
    end
  end

  defp own_out?(obs), do: obs != nil and obs[:own_out?] == true

  # A held lock is the one fact a presumption cannot argue with: at least one
  # row on screen is being fought RIGHT NOW, so a presumption covering the
  # WHOLE list is disproved — clamp it to leave the locked row out. Before
  # this, a presumption survived into a real fight for its whole TTL: one row
  # on screen, one held lock, scenery_rows = 1 — the hunt read "0 fightable"
  # and strolled off mid-fight (Lucas, 2026-08-10).
  defp disprove_scenery(%{scenery_rows: nil} = logic, _obs), do: logic

  defp disprove_scenery(logic, obs) do
    case min(logic.scenery_rows, max(length(enemies(obs)) - 1, 0)) do
      0 -> %{logic | scenery_rows: nil, scenery_until: nil, failed_hunts: 0}
      clamped -> %{logic | scenery_rows: clamped}
    end
  end

  # The presumption self-corrects: it expires at the TTL (re-probe), and a list
  # SMALLER than it means the composition changed (the scenery left) — forget
  # and hunt normally again. Only real frames vote on the shrink.
  defp refresh_scenery(%{scenery_rows: nil} = logic, _obs, _now), do: logic

  defp refresh_scenery(logic, obs, now) do
    if now >= logic.scenery_until or
         (observed?(obs) and length(enemies(obs)) < logic.scenery_rows) do
      %{logic | scenery_rows: nil, scenery_until: nil, failed_hunts: 0}
    else
      logic
    end
  end

  defp tab(logic, now),
    do: %{
      logic
      | state: :tabbing,
        entered_at: now,
        tabbed_at: now,
        tab_attempts: logic.tab_attempts + 1,
        post_tab_frames: 0
    }

  # Every rehunt (kill landed, fight timed out, io failure) opens the probe window: "not
  # attacking while something is attackable" is the one state this machine must never rest in.
  @doc """
  What the hunt is asking of combat right now: `:free_fight` or `:hold_fire`.

  The Worker sets it from the `:posture` fact before every step. Anything else
  is ignored — an unreadable posture must mean "carry on", never "stop
  fighting".
  """
  @spec set_posture(%__MODULE__{}, :free_fight | :hold_fire) :: %__MODULE__{}
  def set_posture(%__MODULE__{} = logic, posture) when posture in [:free_fight, :hold_fire],
    do: %{logic | posture: posture}

  def set_posture(%__MODULE__{} = logic, _unknown), do: %{logic | posture: :free_fight}

  # Back to hunting with nothing pending: no target, no Tab window, and no
  # probe (a probe is a blind Tab, which is the one thing holding fire forbids).
  defp stand_down(logic, now) do
    %{
      logic
      | state: :hunting,
        entered_at: now,
        tabbed_at: nil,
        tab_attempts: 0,
        post_tab_frames: 0,
        lost_streak: 0,
        locked_row: nil,
        last_burst_at: nil,
        probe_until: nil,
        hold_until: nil
    }
  end

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
        locked_row: nil,
        probe_until: probe_deadline(logic, now)
    }
  end

  defp probe_deadline(%{config: config}, now),
    do: now + Map.get(config, :hunt_probe_window_ms, 8_000)

  # One skill burst, throttled: observations arrive at feed cadence (~120ms) but keys should
  # fire at skill cadence (~300ms) — without the throttle the feed would triple the key rate.
  #
  # INFORMED mode (a fresh :skill_bar reading rode in on the observation): fire only the
  # READY skills, in skill_keys PRIORITY order, each at most once per burst — no rotation
  # index needed, because pressing a skill puts it on cooldown and it leaves the ready set
  # by itself (self-balancing). BLIND mode (no reading / empty / none of ours): the
  # round-robin rotation, unchanged — FAIL-OPEN, because a wrong or missing read may waste
  # presses (a cooling key is a no-op in game — today's behavior) but must never stop the
  # attack: not attacking while something is attackable is the one idle this machine
  # exists to prevent.
  defp press_next_skill(%{config: %{skill_keys: []}} = logic, _now, _ready), do: {logic, []}

  defp press_next_skill(%{config: config} = logic, now, ready) do
    cond do
      logic.last_burst_at != nil and now - logic.last_burst_at < config.skill_burst_every_ms ->
        {logic, []}

      keys = ready_in_priority(config.skill_keys, ready) ->
        burst = max(config.combat_skill_burst_size, 1)
        actions = keys |> Enum.take(burst) |> Enum.map(&{:press, &1})
        {%{logic | last_burst_at: now}, actions}

      true ->
        burst = max(config.combat_skill_burst_size, 1)
        len = length(config.skill_keys)

        actions =
          for offset <- 0..(burst - 1) do
            {:press, Enum.at(config.skill_keys, rem(logic.skill_idx + offset, len))}
          end

        {%{logic | skill_idx: logic.skill_idx + burst, last_burst_at: now}, actions}
    end
  end

  # The ready keys in skill_keys priority order, or nil (→ blind rotation) when the
  # reading is absent or names none of ours.
  defp ready_in_priority(skill_keys, ready) when is_list(ready) do
    case Enum.filter(skill_keys, &(&1 in ready)) do
      [] -> nil
      keys -> keys
    end
  end

  defp ready_in_priority(_skill_keys, _unknown), do: nil

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
