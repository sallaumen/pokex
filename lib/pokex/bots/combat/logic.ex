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
             READY skills fire, in priority order; without one (nil/empty/none
             of ours) the blind rotation runs unchanged — a bad read may waste presses,
             never stop the attack. Lock gone
             target_lost_streak OBSERVED frames in a row → the target died: count the kill
             and hunt the next one (a nil/timer wake never counts — only real frames vote).

  The PRIORITY ORDER is `Pokex.Bots.Combat.Strategy`'s when a loadout says what this
  pokémon's keys do — area first on a crowd, single-target first on one or two, the
  control skill never — and the configured `skill_keys` list otherwise. The fallback is
  not a degraded mode: it is the behaviour that existed before loadouts.

  There is NO mouse anywhere: Tab and skills are keys, the Guardian owns the panic corner,
  and the Body is not involved.
  """

  alias Pokex.Bots.Combat.{Loadout, Strategy}

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
            # THE STALEMATE (2026-08-11: um pokémon do outro lado da parede que
            # ele não consegue atacar): how much HP-bar green the locked row
            # had, and WHEN it last changed. A target being hit loses green; one
            # nobody can reach keeps every pixel while the skills go out.
            hp_seen: nil,
            hp_changed_at: nil,
            failures: 0,
            # quando foi a última — uma falha longe da anterior começa uma
            # sequência nova (ver `fail/3`)
            last_failure_at: nil,
            error: nil,
            # What the HUNT asked of combat: `:free_fight` (always, historically
            # and by default) or `:hold_fire` while it walks a mob stretch
            # gathering enemies instead of fighting them. Set from the
            # `:posture` fact by the Worker; a stale or missing fact reads as
            # free fire, so a dead hunt can never leave combat pacifist.
            posture: :free_fight,
            # WHICH STANCE the game is in, as far as this machine knows.
            # shift+1 is attack (more damage, less defence) and shift+3 is
            # defence — the keys he presses by hand, and the ones the bot never
            # touched. nil = not set yet this run.
            stance: nil,
            # WHAT the keys of the pokémon on the field do, when he has said so
            # (`Pokex.Bots.Combat.Loadout`). nil — no pokémon chosen, or one
            # whose skills are unclassified — falls back to the configured
            # `skill_keys` list, which is exactly the behaviour that existed
            # before any of this.
            loadout: nil,
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
         hp_seen: nil,
         hp_changed_at: nil,
         stance: nil,
         failures: 0,
         last_failure_at: nil,
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
       when state in [:tabbing, :fighting] do
    {logic, stance} = wear(logic, :defense)
    {stand_down(logic, now), stance ++ [{:log, "🕊️ segurando o fogo — a caçada está mobando"}]}
  end

  defp do_step(%__MODULE__{state: :hunting, posture: :hold_fire} = logic, _obs, _now),
    do: wear(logic, :defense)

  # DUAS MÁQUINAS, e a config escolhe qual: com Tab a luta começa travando um
  # alvo; sem Tab, começa por haver bicho na tela.
  #
  # "Na prática, na hunt, a gente nem precisa apertar o tab (…) eles vão
  # perseguir a gente, e apertar o tab pra ele atacar um inimigo é pior, porque
  # atrapalha a organização dos bichos — meu pokémon pode se mexer demais"
  # (27/08). Com as teclas de alvo único fora da rotação, o alvo travado não
  # move mais nada do dano: só move o pokémon.
  defp do_step(%{state: :hunting} = logic, obs, now) do
    logic = refresh_scenery(logic, obs, now)

    if tab?(logic),
      do: hunting_with_tab(logic, obs, now),
      else: hunting_by_screen(logic, obs, now)
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
            failed_hunts: 0,
            hp_seen: nil,
            hp_changed_at: now
        }

        press_next_skill(logic, now, obs)

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

  # SEM TAB a luta é sobre a TELA, não sobre um alvo: enquanto houver bicho na
  # lista há o que estourar, e a lista vazia é o fim da rodada. O
  # empate-contra-a-parede (`stalemate?`) não tem como ser lido aqui — ele olha
  # a barra da linha travada, e não há linha travada —, então quem limita uma
  # luta que não anda é o `fight_timeout_ms`.
  defp do_step(%{state: :fighting} = logic, obs, now) do
    cond do
      now - logic.entered_at > logic.config.fight_timeout_ms ->
        {rehunt(logic, now), [{:log, "timeout do alvo; recaçando"}]}

      not tab?(logic) ->
        if observed?(obs), do: fight_by_screen(logic, obs, now), else: {logic, []}

      true ->
        fighting_with_lock(logic, obs, now)
    end
  end

  # A luta que TRAVA ALVO: a barra da linha travada é o que diz se ela anda, e o
  # alvo perdido é o que a encerra.
  defp fighting_with_lock(logic, obs, now) do
    cond do
      locked?(obs) ->
        logic =
          %{disprove_scenery(logic, obs) | lost_streak: 0, locked_row: obs.locked_row}
          |> watch_damage(obs, now)

        if stalemate?(logic, now),
          do: give_up_target(logic, obs, now),
          else: press_next_skill(logic, now, obs)

      observed?(obs) and logic.lost_streak + 1 >= logic.config.target_lost_streak ->
        logic = update_in(logic.counters.fights, &(&1 + 1))
        killed(rehunt(logic, now), now)

      observed?(obs) ->
        {%{logic | lost_streak: logic.lost_streak + 1}, []}

      true ->
        # timer wake without a fresh frame: only the timeout above may act.
        {logic, []}
    end
  end

  defp hunting_by_screen(logic, obs, now) do
    cond do
      logic.hold_until != nil and now < logic.hold_until ->
        {logic, []}

      length(enemies(obs)) > (logic.scenery_rows || 0) ->
        logic |> enter_fight_without_lock(obs, now) |> press_next_skill(now, obs)

      true ->
        {%{logic | hold_until: nil, probe_until: nil, locked_row: nil}, []}
    end
  end

  defp hunting_with_tab(logic, obs, now) do
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

  # How much green the locked row's bar has RIGHT NOW, and when that last
  # CHANGED. A missing reading (no `:hp` in the observation, no locked row, row
  # out of range) is UNKNOWN and never votes — it neither restarts the clock
  # nor advances it.
  defp watch_damage(logic, obs, now) do
    case row_hp(obs, logic.locked_row) do
      nil -> logic
      hp when hp == logic.hp_seen -> logic
      hp -> %{logic | hp_seen: hp, hp_changed_at: now}
    end
  end

  defp row_hp(obs, row) when is_integer(row) do
    case obs[:hp] do
      hp when is_list(hp) -> Enum.at(hp, row)
      _absent -> nil
    end
  end

  defp row_hp(_obs, _no_row), do: nil

  # THE STALEMATE: the lock is held, skills went out, and the target's bar has
  # not moved a pixel for no_damage_ms. That is not a fight, it is a wall
  # ("bugou com um pokemon do outro lado da parede que ele nao consegue
  # atacar", Lucas, 2026-08-11). A burst must have been fired first — a target
  # nobody has hit yet has no business being called unreachable — and a bar
  # nobody could read (hp_seen nil) proves nothing either way.
  defp stalemate?(logic, now) do
    window = Map.get(logic.config, :no_damage_ms, 0)

    window > 0 and logic.last_burst_at != nil and logic.hp_seen != nil and
      logic.hp_changed_at != nil and now - logic.hp_changed_at >= window
  end

  # The same exit as a hunt whose Tabs never locked, for the same reason: this
  # row is not worth attacking. It counts toward the scenery presumption, which
  # is what eventually frees the HUNT to walk on — and walking is what actually
  # solves a wall, because it changes what the character can reach.
  defp give_up_target(logic, obs, now) do
    {given_up, actions} = give_up_hunt(logic, obs, now)
    {%{given_up | hp_seen: nil, hp_changed_at: nil}, [{:log, stalemate_log(logic)} | actions]}
  end

  defp stalemate_log(%{config: config}) do
    seconds = div(Map.get(config, :no_damage_ms, 0), 1000)

    "🧱 o alvo não perdeu vida em #{seconds}s — deve estar fora de alcance (parede?); " <>
      "deixando pra lá"
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

  @doc """
  What the keys of the pokémon on the field DO, or `nil` to go back to pressing
  the configured list.

  NOT a fact with an age, unlike the posture: this is something he configured,
  and a configuration that rotted mid-hunt would silently drop the fight back
  to a key order that cannot tell area from single-target.
  """
  @spec set_loadout(%__MODULE__{}, Loadout.t() | nil) :: %__MODULE__{}
  def set_loadout(%__MODULE__{} = logic, %Loadout{} = loadout), do: %{logic | loadout: loadout}
  def set_loadout(%__MODULE__{} = logic, _none), do: %{logic | loadout: nil}

  @doc """
  The driver threw this action list away without performing it — the
  one-burst-in-flight rule (see `Pokex.Bots.Combat.Worker`).

  Skipping a burst is free for everything the Logic re-decides from a fresher
  world on the next frame. The STANCE is the exception: it is the one decision
  this machine LATCHES the moment it makes it, so a dropped list would leave the
  fight believing it wears a stance the game never heard — and it would never
  press that key again. Forget it, and the next burst wears it for real.

  Only when the stance key was actually in the dropped list: forgetting on every
  skip would put the key back on the "one per burst" cadence the edge exists to
  avoid.
  """
  @spec dropped(%__MODULE__{}, [tuple]) :: %__MODULE__{}
  def dropped(%__MODULE__{stance: nil} = logic, _actions), do: logic

  def dropped(%__MODULE__{stance: stance} = logic, actions) do
    if {:press, stance_key(logic, stance)} in actions,
      do: %{logic | stance: nil},
      else: logic
  end

  # THE GAME'S OWN STANCE. shift+1 is attack mode — more damage, less defence —
  # and shift+3 is defence, which is the one to walk a gathering in. He presses
  # them by hand and the bot never did ("vi que quando dou play ele nao usa
  # esses comandos"), and he named the failure himself: "às vezes eu mesmo erro,
  # uso skill de dano antes de mudar o modo para ataque... uma máquina não
  # deveria falhar em algo tão simples".
  #
  # So it does not depend on timing: the stance key travels in the SAME action
  # list as the burst, ahead of the first damage key. The Body performs a list
  # in order, so the order cannot come apart.
  #
  # Only on the EDGE — pressing it before every burst would be a key per 300ms.
  # An unconfigured key changes nothing and leaves the stance unknown, so it is
  # retried rather than believed.
  defp wear(%__MODULE__{stance: stance} = logic, stance), do: {logic, []}

  defp wear(logic, wanted) do
    case stance_key(logic, wanted) do
      nil -> {logic, []}
      key -> {%{logic | stance: wanted}, [{:press, key}]}
    end
  end

  defp stance_key(%{config: config}, :attack), do: usable(Map.get(config, :attack_mode_key))
  defp stance_key(%{config: config}, :defense), do: usable(Map.get(config, :defense_mode_key))

  defp usable(key) when is_binary(key) and key != "", do: key
  defp usable(_unset), do: nil

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

  # ONE fight, then a breath — when he asks for one.
  #
  # "quando ele entra numa batalha, uma opção poderia ser só matar aquele lá e
  # não dar mais tab depois, para não entrar em outra batalha individual"
  # (Lucas, 2026-08-11). Chaining is what combat does by default: the kill
  # opens the blind probe and the next Tab goes out at once, so walking past
  # three pokémon means three fights. With a hold, the kill ends the round —
  # no probe, no Tab — and what is still around stays busy with his pokémon
  # instead of being pulled in one by one. 0 keeps the old behaviour.
  defp killed(logic, now) do
    case Map.get(logic.config, :after_kill_hold_ms, 0) do
      ms when is_integer(ms) and ms > 0 ->
        {%{logic | hold_until: now + ms, probe_until: nil},
         [{:log, "alvo morto; parando #{div(ms, 1000)}s antes de caçar outro"}]}

      _chaining ->
        {logic, [{:log, "alvo morto; caçando o próximo"}]}
    end
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
  defp press_next_skill(%{config: config} = logic, now, obs) do
    order = attack_keys(logic, obs)

    cond do
      order == [] ->
        {logic, []}

      logic.last_burst_at != nil and now - logic.last_burst_at < config.skill_burst_every_ms ->
        {logic, []}

      keys = ready_in_priority(order, obs[:ready_skills]) ->
        burst = max(config.combat_skill_burst_size, 1)
        {logic, stance} = wear(logic, :attack)
        actions = keys |> Enum.take(burst) |> Enum.map(&{:press, &1})
        {%{logic | last_burst_at: now}, stance ++ actions}

      true ->
        burst = max(config.combat_skill_burst_size, 1)
        len = length(order)
        {logic, stance} = wear(logic, :attack)

        actions =
          for offset <- 0..(burst - 1) do
            {:press, Enum.at(order, rem(logic.skill_idx + offset, len))}
          end

        {%{logic | skill_idx: logic.skill_idx + burst, last_burst_at: now}, stance ++ actions}
    end
  end

  # The order comes from what the keys DO whenever he has said so, and from the
  # hand-written list when he has not. Two things the list could never know:
  # a swap makes it wrong, and it cannot tell area from single-target — so it
  # cannot lead with area on a crowd, nor keep the control skill for the revive.
  #
  # The fallback is not a degraded mode, it IS the behaviour that existed before
  # the loadout: no pokémon chosen means nothing changes.
  defp attack_keys(%{loadout: loadout, config: config}, obs) do
    if Loadout.attacks?(loadout) do
      quantos = length(enemies(obs))
      prontas = obs[:ready_skills]

      # AS DUAS AURAS ENTRAM NA ROTAÇÃO, e não só na abertura. Elas só eram
      # consideradas em `open_with_combo`, que sai UMA vez na borda da luta: uma
      # aura que fica pronta no meio de uma luta de quarenta segundos nunca era
      # apertada. Medido no rastro dele de 27/08: a tecla 2 do Vespiquen (a aura
      # de dano) saiu 3 vezes contra 28 da tecla 7.
      #
      # "A aura de ataque vale a pena ele usar sempre que tiver em luta com um
      # pokémon e o cooldown estiver disponível; a de defesa, sempre que tem já
      # uns 2 pokémons atacando ele pelo menos" (27/08).
      Strategy.skill_order(loadout,
        enemies: quantos,
        aoe_from: Map.get(config, :combat_aoe_from_enemies, 3),
        single_target?: Map.get(config, :combat_single_target, false),
        aura_ready?: Loadout.aura_ready?(loadout, prontas),
        shield_ready?:
          quantos >= Map.get(config, :combat_shield_from_enemies, 2) and
            Loadout.shield_ready?(loadout, prontas),
        # …E O DANO PELA MESMA BARRA QUE AS AURAS. Era a única metade da rajada
        # que saía sem olhar: 81% dos apertos de dano de 29/08 foram em tecla
        # JÁ esfriando, e 74% das rajadas eram inteiramente assim — onze
        # minutos de teclado numa caçada de 82, cada tecla fria custando o
        # `combat_skill_gap_ms` inteiro e ainda comprando uma retentativa.
        #
        # SÓ NA ROTAÇÃO, e é de propósito: a mão que o CÉREBRO monta
        # (`Engine.Inputs`) continua completa, porque a engine lê `opening ==
        # []` como "nenhum pokémon configurado pra lutar" e sai da luta. As
        # duas listas parecem a mesma coisa e não são — a bancada mediu a
        # confusão: filtrar lá derrubou os mortos em 44% e jogou 55% da corrida
        # no `:handless`.
        ready_keys: prontas
      )
    else
      # Nobody chosen, or one whose ATTACKS he has not classified — a pokémon
      # can have a scheduled aura and still have nothing here.
      config.skill_keys
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

  # SEGUIDAS, como a própria mensagem promete. O contador nunca voltava a zero —
  # nem no sucesso, nem com o tempo — então cinco erros de IO espalhados por uma
  # noite inteira, um a cada duas horas, travavam o combate em `:error` para
  # sempre, com a tela dizendo "5x seguidas". Uma falha longe da anterior começa
  # sequência nova: é o que a palavra quer dizer, e é o que separa "a mão parou
  # de funcionar" (a emergência) de "a noite teve soluços" (que não é). Perto =
  # dentro de uma janela, porque o tempo é a única prova que este módulo tem —
  # o sucesso de uma rajada não volta para cá.
  @failure_streak_window_ms 60_000

  defp fail(%__MODULE__{} = logic, now, reason) do
    failures = if streak?(logic, now), do: logic.failures + 1, else: 1
    logic = update_in(logic.counters.failures, &(&1 + 1))
    reason = to_string(reason)

    if failures >= logic.config.max_consecutive_failures do
      {%{
         logic
         | state: :error,
           failures: failures,
           last_failure_at: now,
           error: "#{reason} (#{failures}x seguidas)"
       }, [{:log, reason}]}
    else
      {%{rehunt(logic, now) | failures: failures, last_failure_at: now}, [{:log, reason}]}
    end
  end

  defp streak?(%{last_failure_at: nil}, _now), do: false
  defp streak?(%{last_failure_at: at}, now), do: now - at <= @failure_streak_window_ms

  defp enemies(nil), do: []
  defp enemies(obs), do: obs[:enemies] || []

  # A luta que começa sem travar nada: os mesmos campos que o `:tabbing` zera ao
  # confirmar um lock, menos o lock.
  defp enter_fight_without_lock(logic, obs, now) do
    %{
      logic
      | hold_until: nil,
        hunt_enemies: length(enemies(obs)),
        state: :fighting,
        entered_at: now,
        lost_streak: 0,
        locked_row: nil,
        last_burst_at: nil,
        failed_hunts: 0,
        hp_seen: nil,
        hp_changed_at: now
    }
  end

  # …e a rodada que acaba pela tela: lista vazia é o fim, e qualquer bicho é
  # motivo pra seguir estourando.
  defp fight_by_screen(logic, obs, now) do
    if enemies(obs) == [] do
      logic = update_in(logic.counters.fights, &(&1 + 1))
      killed(rehunt(logic, now), now)
    else
      logic |> disprove_scenery(obs) |> press_next_skill(now, obs)
    end
  end

  # Se a caçada aperta Tab. Desligado por medição dele em campo: o alvo travado
  # não muda o dano (só a área machuca) e move o pokémon pra cima do alvo,
  # desmanchando o bolo que a régua acabou de juntar.
  defp tab?(%{config: config}), do: Map.get(config, :combat_tab_target, false) == true

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
