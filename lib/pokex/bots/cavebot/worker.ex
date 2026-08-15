defmodule Pokex.Bots.Cavebot.Worker do
  @moduledoc """
  Driver for the pure `Cavebot.Logic`, constant-hunt style: a short tick reads
  the world (position from the `:minimap` fact, enemy count from `:battle`, the
  last combat state heard on the "combat" topic), calls `Logic.step/3` and
  translates ONE action at a time.

  A PEER of the other workers, never a change to them:

    * actuation ONLY through the Body — `Body.arrow_step/3` is the only way
      to walk (one arrow key = one sqm in the right direction — Lucas's
      2026-08-10 direction; minimap clicks are retired: hovering covers the
      map's edges with CONTROLS, and pressing also makes the coordinate
      label render, so walking feeds its own position reading). The Rig is
      never touched from here.
    * Combat.Worker is driven exclusively via `run/1` and
      `BotSupervisor.safe_halt/1` — the Logic starts it and it fights on its
      own; the cavebot only yields while enemies are on screen. The BOUNDED
      halt, because this runs inside the cavebot's own loop, which is itself
      halted on a budget: a worker that stopped answering must never wedge the
      hunt that is stopping it.

  Layered fail-safe: unknown position (missing/stale fact, unread anchor) holds
  the step — never walk blind; and a `{:block, _}` from the Logic has TWO
  levels (see `translate/2`): the dangerous one, the fleet's full handbrake,
  and the local one, stopping only this hunt.

  Every stop has a NAME: each step's result lands in `last_step` and becomes
  the snapshot's `hold_reason` (with the blindness the Logic marks and the
  `hold_note` of reasons born outside the tick). A cavebot stopped without a
  written reason is indistinguishable from a broken one — that is how a
  gate-suppressed click once killed the fleet in silence.

  Two screen outputs, deliberately different: the SNAPSHOT (`{:cavebot, map}`)
  is the full current state, re-emitted when a FACT changes; LOGS
  (`{:cavebot_log, level, text}`) are the edge narrative — route loaded,
  waypoint reached, block, a hold reason appearing. Nothing here may speak per
  tick: the cadence is 200ms and a line per tick is noise that buries the fact.
  The single exception is `log_walk_decision/4`, which is an INSTRUMENT and
  emits NOTHING AT ALL until `cavebot_measure_walk` is switched on — see its
  doc.

  The injected `body` is a MODULE (production: `Pokex.Bots.Body`; tests: a fake
  with the same signature), because `arrow_step/3` is a module function — the
  key geometry lives in the Body, not here. `combat` is a server (production:
  the named `Combat.Worker`), because `run/1`/`halt/1` take the server.
  `active: false` (tests) prepares everything on `run` but does NOT schedule
  the automatic tick — tests send `:tick` by hand, each step deterministic.
  """
  use GenServer
  require Logger

  alias Pokex.Bots.BotSupervisor
  alias Pokex.Bots.Catcher
  alias Pokex.Bots.Cavebot.{Logic, Route, Store}
  alias Pokex.Bots.Combat
  alias Pokex.Bots.InputGate
  alias Pokex.Bots.PlayerSupport
  alias Pokex.Calibration
  alias Pokex.Perception
  alias Pokex.Perception.{Feed, WorldState}
  alias Pokex.Pokedex.SkillProfile
  alias Pokex.Pokedex.Team
  alias Pokex.Settings

  @topic "cavebot"
  @tick_ms 200
  @no_route_error "nenhuma rota de caçada configurada"
  @max_reattach 20
  @feed_lost "perdi o feed do minimapa e desisti de reconectar"

  # Blocks where the character may be somewhere the route does not describe, or
  # fighting with nobody to fight — see `translate/2`.
  @dangerous_blocks [:floor_changed, :combat_preflight_failed]

  @config_keys %{
    arrival_tolerance: :cavebot_arrival_tolerance_tiles,
    blind_kick_ms: :cavebot_blind_kick_ms,
    walk_timeout_ms: :cavebot_walk_timeout_ms,
    stuck_max_retries: :cavebot_stuck_max_retries,
    clear_debounce_ms: :cavebot_clear_debounce_ms,
    fight_timeout_ms: :cavebot_fight_timeout_ms,
    post_kill_dwell_ms: :cavebot_post_kill_dwell_ms,
    capture_wait_ms: :cavebot_capture_wait_ms,
    sweep_grace_ms: :cavebot_sweep_grace_ms,
    stop_wait_ms: :cavebot_stop_wait_ms,
    gather_wait_ms: :cavebot_gather_wait_ms,
    fight_only_at_stops: :cavebot_fight_only_at_stops,
    stair_probe_ms: :cavebot_stair_probe_ms,
    stair_max_probes: :cavebot_stair_max_probes,
    hp_abort_pct: :cavebot_hp_abort_pct,
    hp_resume_pct: :cavebot_hp_resume_pct,
    stair_step_ms: :cavebot_stair_step_ms,
    stair_step_taps: :cavebot_stair_step_taps
  }

  def topic, do: @topic

  def start_link(opts \\ []) do
    state = %{
      body: Keyword.get(opts, :body, Pokex.Bots.Body),
      combat: Keyword.get(opts, :combat, Combat.Worker),
      catcher: Keyword.get(opts, :catcher, Catcher.Worker),
      active?: Keyword.get(opts, :active, Application.get_env(:pokex, :cavebot_active, true)),
      logic: nil,
      timer: nil,
      attached?: false,
      feed_ref: nil,
      reattach_attempts: 0,
      combat_state: :idle,
      combat_scenery: 0,
      # what the hunt last ASKED of combat — kept only to narrate the edge
      posture: :free_fight,
      held_keys: [],
      # the pokémon on the field, so a category the route ordered can become a
      # key. Kept here and refreshed on the event, never read per tick:
      # `Loadout.current/0` reads the team file.
      loadout: Combat.Loadout.current(),
      capture_pending: 0,
      capture_changed_at: nil,
      # the BLIND sweep's queue, same progress rule as the capture's
      sweep_pending: 0,
      sweep_changed_at: nil,
      last_step: nil,
      pos: nil,
      pos_at: nil,
      # how old the :minimap fact was on the tick that decided — see observe/2
      pos_age: nil,
      # comebacks already spent on local blocks tonight; reaching a waypoint
      # gives them all back (see note_arrival/3)
      block_retries: 0,
      counters: %{waypoints: 0, steps: 0},
      last_action: nil,
      hold_note: nil,
      logged_holds: []
    }

    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, state)
      name -> GenServer.start_link(__MODULE__, state, name: name)
    end
  end

  @spec run(GenServer.server()) :: :ok | {:error, [String.t()]}
  def run(server \\ __MODULE__), do: GenServer.call(server, :run)

  @spec halt(GenServer.server()) :: :ok
  def halt(server \\ __MODULE__), do: GenServer.call(server, :halt)

  @typedoc """
  What the screen needs to narrate the whole hunt without guessing: where he
  is, where he is going, how far is left, what held him, and his last action.
  """
  @type snapshot :: %{
          state: atom,
          route: String.t() | nil,
          wp_index: non_neg_integer,
          wp_total: non_neg_integer,
          wp_target: Route.waypoint() | nil,
          pos: {integer, integer, integer} | nil,
          pos_age_ms: non_neg_integer | nil,
          distance_tiles: %{dx: integer, dy: integer} | nil,
          hold_reason: String.t() | nil,
          comeback?: boolean,
          luring?: boolean,
          last_action: %{text: String.t(), at: integer} | nil,
          counters: %{waypoints: non_neg_integer, steps: non_neg_integer}
        }

  @spec status(GenServer.server()) :: snapshot
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(state) do
    Phoenix.PubSub.subscribe(Pokex.PubSub, Combat.Worker.topic())
    # The Catcher's queue decides when the route may resume — heard, never
    # asked: a `call` to the Catcher parks behind its multi-second captures
    # (the 2026-07-30 timeout that killed a page), and this worker ticks 5x a
    # second.
    Phoenix.PubSub.subscribe(Pokex.PubSub, Catcher.Worker.topic())
    Phoenix.PubSub.subscribe(Pokex.PubSub, Team.topic())
    {:ok, state}
  end

  @impl true
  def handle_call(:run, _from, state) do
    case active_route() do
      nil ->
        {:reply, {:error, [@no_route_error]}, state}

      route ->
        Logger.info("Cavebot: rota \"#{route.name}\" (#{length(route.waypoints)} waypoints)")
        log(:macro, "rota \"#{route.name}\": #{length(route.waypoints)} waypoints")
        warn_unarmed_safety()

        # The per-dungeon combo gate reads this fact (Combos.Runner). Published
        # even with nil dungeon — the Runner treats nil as "global combos only".
        WorldState.put(:dungeon, %{id: route.dungeon}, now())

        state =
          %{cancel_timer(state) | logic: Logic.new(route, config()), block_retries: 0}
          |> reset_session()
          |> attach()
          |> schedule_tick()

        broadcast_status(state)
        {:reply, :ok, state}
    end
  end

  def handle_call(:halt, _from, %{logic: nil} = state), do: {:reply, :ok, state}

  def handle_call(:halt, _from, state) do
    state = state |> release_walk() |> free_fire()
    BotSupervisor.safe_halt(state.combat)
    WorldState.forget(:dungeon)

    state =
      %{detach(cancel_timer(state)) | logic: nil, reattach_attempts: 0}
      |> end_session()

    broadcast_status(state)
    {:reply, :ok, state}
  end

  def handle_call(:status, _from, state), do: {:reply, snapshot(state), state}

  # A stray tick after halt (or before run) is harmless.
  @impl true
  def handle_info(:tick, %{logic: nil} = state), do: {:noreply, state}

  def handle_info(:tick, state) do
    now = now()

    if InputGate.allowed?() do
      run_cavebot_tick(state, now)
    else
      # Gate closed = no step goes out (the Body refuses), but the Logic's
      # patience clocks kept running — 3s without "progress" became :stuck and
      # the hunt died BEFORE the game could be refocused after clicking Iniciar
      # in the browser (the real fail-closed regression, 2026-07-29). Freeze
      # the clocks: pin every `since` stamp to `now`, record the visible
      # reason, and wait for the gate to reopen.
      frozen = %{
        state.logic
        | since: Map.new(state.logic.since, fn {k, _at} -> {k, now} end)
      }

      state = %{
        state
        | logic: frozen,
          last_step: %{dx: 0, dy: 0, result: {:error, :input_gate_closed}, at: now}
      }

      {:noreply, schedule_tick(state)}
    end
  end

  # The comeback from a local block (see schedule_comeback/1). A halt in the
  # meantime cancelled this timer and nil'd the logic — the clause below is for
  # the message already in flight when it happened.
  def handle_info(:comeback, %{logic: nil} = state), do: {:noreply, state}

  def handle_info(:comeback, state) do
    cond do
      # "panic/Stop nunca são revertidos automaticamente": the Guardian may
      # have latched while this hunt was waiting, and a timer fired from before
      # must never be what undoes it. Said out loud, because a silent refusal
      # is indistinguishable from a broken comeback.
      InputGate.panic_latched?() ->
        log(:macro, "não retomo: o pânico está travado — solte pelo painel")
        {:noreply, %{state | timer: nil}}

      route = active_route() ->
        {:noreply, resume_hunt(state, route)}

      true ->
        log(:macro, "não retomo: nenhuma rota armada agora")
        {:noreply, %{state | timer: nil}}
    end
  end

  def handle_info({:combat, %{state: combat_state} = snapshot}, state) do
    {:noreply,
     %{state | combat_state: combat_state, combat_scenery: Map.get(snapshot, :scenery, 0)}}
  end

  # Corpses queued for capture — and ONLY those. The blind sweep's own queue is
  # deferred by design outside the standing mode ("varredura adiada — a
  # varredura é do modo Parado", all over Lucas's log), so counting it made the
  # hunt wait on work nobody was going to do: after every kill it sat until the
  # cap, then again, and again.
  def handle_info({:catcher, snapshot}, state) do
    sweep_pending = snapshot |> Map.get(:sweep, %{}) |> Map.get(:pending, 0)

    {:noreply,
     state
     |> note_capture(Map.get(snapshot, :pending_corpses, 0))
     |> note_sweep(sweep_pending)}
  end

  # Changing pokémon changes which key is the aura — the route stores the
  # category and this is where it becomes a key, so this copy has to keep up.
  def handle_info({:team_changed}, state),
    do: {:noreply, %{state | loadout: Combat.Loadout.current()}}

  # The minimap feed died (its consumers map dies with it; a restarted feed
  # starts with nobody attached). Without reattaching, the :minimap fact ages,
  # the position becomes :unknown and the cavebot stays stopped FOREVER —
  # short bounded retry, the Catcher's mold.
  def handle_info({:DOWN, ref, :process, _obj, _reason}, %{feed_ref: ref} = state) do
    state = %{state | attached?: false, feed_ref: nil}
    state = if running?(state), do: schedule_reattach(state), else: state
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _obj, _reason}, state), do: {:noreply, state}

  def handle_info(:reattach_minimap, state) do
    if running?(state) and not state.attached? do
      {:noreply, reattach_minimap(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # The read position is KEPT with its read time: during a blind spell the
  # world the Logic gets has `pos: nil` (it must not walk on a guess), but the
  # screen keeps showing the last known coordinate WITH its age — "was at
  # 100,100 4s ago" is diagnosis, "no position" is not.
  defp run_cavebot_tick(state, now) do
    {world, state} = observe(state, now)
    before = broadcast_key(state, now)
    wp_before = state.logic.wp_index
    state_before = state.logic.state
    recovering_before = state.logic.recovering?
    # taps are reset by the arrival itself, so the count has to be read BEFORE
    # the step that arrives — see `note_stair_taken/5`
    taps_before = state.logic.stair_taps

    {logic, action} = Logic.step(state.logic, world, now)

    state =
      %{state | logic: logic}
      # BEFORE the action, always: the tick that STARTS Combat is the tick that
      # must already have said what to do with the fire. Published after, the
      # first thing Combat read was an absent posture fact — which it correctly
      # takes for free fire — and it opened up on the crowd the hunt was about
      # to gather.
      |> publish_posture(now)
      |> translate(action)
      |> note_arrival(wp_before, now)
      |> note_stair_taken(wp_before, state_before, taps_before, now)
      |> note_search(state_before, now)
      |> note_recovery(recovering_before, now)
      |> log_hold_edge(now)

    if broadcast_key(state, now) != before, do: broadcast_status(state)
    {:noreply, schedule_tick(state)}
  end

  # What the hunt asks of Combat, republished EVERY tick.
  #
  # It is a fact on the blackboard, not a message, and that is the whole
  # design: facts carry their age, so a hunt that dies (or blocks, or is
  # stopped) simply stops refreshing this one and Combat reads it as stale —
  # which it treats as free fire. A pacifist bot left behind by a dead cavebot
  # is the failure this shape makes impossible; the heartbeat is what buys it.
  defp publish_posture(state, now) do
    posture = if Logic.hold_fire?(state.logic, now), do: :hold_fire, else: :free_fight

    # …and WHAT to open with when the fire is released: his own combo from
    # this kill spot, so the area damage lands on the whole pile instead of one
    # straggler at a time, plus the categories he ORDERED there — already
    # resolved to keys, because Combat has no business asking which pokémon is
    # out.
    WorldState.put(
      :posture,
      %{
        posture: posture,
        combo: Logic.combo(state.logic),
        orders: skill_keys(state.loadout, Logic.orders(state.logic))
      },
      now
    )

    if posture != state.posture do
      log(:macro, posture_text(posture))
      %{state | posture: posture}
    else
      state
    end
  end

  defp posture_text(:hold_fire),
    do: "🕊️ mobando: sem atacar — o combate está segurando o fogo"

  defp posture_text(:free_fight), do: "⚔️ o bolo se juntou: o combate está liberado"

  # Stopping for ANY reason frees Combat at once, instead of leaving it holding
  # fire for as long as the fact takes to age out.
  defp free_fire(state) do
    WorldState.put(:posture, %{posture: :free_fight}, now())
    %{state | posture: :free_fight}
  end

  # The combat snapshot, kept the Combos.Runner way: the Logic receives the
  # last heard state as world.combat_state.
  defp observe(state, now) do
    pos = position(now)

    # How old the reading the decision is about to be made ON is. `get/3` hides
    # the age of a fresh fact on purpose, so ask for it directly: a decision
    # taken on an 800ms-old position (`cavebot_minimap_fact_max_age_ms`) is a
    # decision taken about where he WAS. Kept on both paths — the blind kick is
    # a decision too, and there the age is the whole story.
    state = %{state | pos_age: WorldState.age(:minimap, now)}

    world = %{
      pos: pos,
      enemies: fightable(state, now),
      combat_state: state.combat_state,
      capture_pending: state.capture_pending,
      capture_changed_at: state.capture_changed_at,
      sweep_pending: state.sweep_pending,
      sweep_changed_at: state.sweep_changed_at,
      hp_pct: own_hp(now),
      fainted?: own_fainted?(now)
    }

    if pos, do: {world, %{state | pos: pos, pos_at: now}}, else: {world, state}
  end

  # The :pokemon fact PlayerSupport already publishes 8x a second — read, never
  # asked. Absent, stale and unreadable all come out nil: without a running
  # health monitor the HP guard is inert (fail-open, like every fact), and
  # inside a recovery the Logic reads nil as "still down" — a recalled pokémon
  # has no bar, and the revive is exactly the wait.
  defp own_hp(now) do
    case Perception.pokemon(now) do
      {:ok, %{hp_pct: pct}} when is_integer(pct) -> pct
      _unreadable_or_unknown -> nil
    end
  end

  # A pokémon on the floor is not a threshold question: whatever percentages
  # the guard was given, walking on with nothing in front of the character
  # walks him into the next pile alone.
  defp own_fainted?(now), do: match?({:ok, %{fainted?: true}}, Perception.pokemon(now))

  defp position(now) do
    case Perception.minimap(now) do
      {:ok, %{pos: pos}} -> pos
      :unknown -> nil
    end
  end

  # Fail-safe 0: a missing/stale :battle fact reads as "screen clear" — the
  # cavebot keeps the route; a real enemy is still fought by Combat (always
  # running) and the next fresh fact corrects the count.
  # What the hunt YIELDS the road to: rows Combat might still fight, never the
  # ones it has given up on. Lucas's own pokémon shows in the battle list
  # (2026-08-10): Combat tabbed at it, failed three times, called it scenery
  # and moved on — while the hunt, counting raw rows, stood still forever
  # waiting for a fight that could never start.
  defp fightable(state, now) do
    max(enemy_count(now) - state.combat_scenery, 0)
  end

  defp enemy_count(now) do
    case WorldState.get(:battle, Settings.get(:combat_world_max_age_ms), now) do
      {:ok, obs} -> length(Map.get(obs, :enemies) || [])
      _stale_or_missing -> 0
    end
  end

  # Public (@doc false) on purpose: covers the Logic's COMPLETE action
  # vocabulary, but the constant style doesn't emit :halt_combat yet (today only
  # {:block, _} turns combat off — the mob style will emit it). As a private
  # function the compiler proves the dead clause and --warnings-as-errors kills
  # the build; public, the whole contract stays implemented and testable.
  @doc false
  # `last_step` describes THIS tick's step attempt: when the Logic asks for no
  # step there is no attempt — and a stale error must not hang on screen
  # explaining a stop that already has another reason.
  def translate(state, :none), do: %{release_walk(state) | last_step: nil}

  # Walking HOLDS the direction — both axes at once when the waypoint is
  # diagonal — and keeps holding while the intent is unchanged. Tapping one
  # arrow per tile was the client's slowest gear (Lucas, 2026-08-10: "está
  # dando pequenos cliques, o personagem tá andando muito lento").
  #
  # Measured AFTER the choice, never before: "how many tiles did that decision
  # actually buy" is the number the instrument exists for, and `{:walk, 4, -3}`
  # reads identically whether it then held two keys, held one, tapped one or
  # pressed nothing. What went out is the half that differs.
  def translate(state, {:walk, dx, dy}) do
    {stepped, went_out} =
      if precise?(dx, dy),
        do: state |> release_walk() |> arrow_step(dx, dy),
        else: hold_walk(state, dx, dy)

    log_walk_decision({:walk, dx, dy}, state.pos, state.pos_age, went_out)
    stepped
  end

  # A nudge is ONE tile on purpose (the blind kick, the stall breaker): it taps,
  # and lets go of whatever was held first — a kick under a held key is not a
  # kick, it is the same walk continuing.
  def translate(state, {:nudge, dx, dy}) do
    {stepped, went_out} = state |> release_walk() |> arrow_step(dx, dy)
    log_walk_decision({:nudge, dx, dy}, state.pos, state.pos_age, went_out)
    stepped
  end

  # "varrer aqui": the pile the hunt gathered died on this tile, and its
  # corpses are worth a ball each. A cast, never a call — the Catcher parks on
  # multi-second captures and this worker ticks five times a second.
  def translate(state, {:sweep, around}) do
    point = spot_point(around)
    Catcher.Worker.sweep_now(state.catcher, point)
    log(:macro, sweep_text(point))
    release_walk(state)
  end

  # The middle click he makes himself when he finishes gathering: it parks the
  # active pokémon on a chosen tile so the pile closes in AROUND IT. Recorded
  # from his own hand (Cavebot.Recording.mark_park/4), replayed here.
  def translate(state, {:park, spot}) do
    state = release_walk(state)

    case spot_point(spot) do
      nil ->
        log(:macro, "🖱️ não mandei o pokémon: falta calibrar onde o personagem fica na tela")
        state

      point ->
        park_click(state, point)
    end
  end

  # The skill HE put at this corner — the aura in the middle of the pile,
  # almost always. The category becomes a key here and not in the Logic,
  # because the process that knows which pokémon is on the field is this one.
  # A tap, never a hold, and only after the arrows are let go: a stuck key is
  # the worst bug this system can produce.
  def translate(state, {:skills, categories}) do
    state = release_walk(state)

    case skill_keys(state.loadout, categories) do
      [] ->
        log(
          :macro,
          "✨ não apertei nada aqui: #{Combat.Loadout.describe(state.loadout)} não tem #{skills_text(categories)}"
        )

        state

      keys ->
        fire_skills(state.body, keys)
        state
    end
  end

  # "Cooldown Ressurect" (Lucas, 2026-08-10): recall, max-revive on the
  # portrait, release. Reviving resets every skill cooldown, so the next fight
  # starts with a full bar instead of a wait. The sequence is PlayerSupport's,
  # calibrated and proven there — this only borrows it, at :high so it lands
  # ahead of ordinary walking.
  def translate(state, :cooldown_revive) do
    state = release_walk(state)

    case revive_combo() do
      nil ->
        log(:macro, "⚡ não resetei o cooldown: falta calibrar a foto do pokémon")
        state

      actions ->
        fire_revive(state.body, actions)
        state
    end
  end

  # Starting combat CAN fail preflight (no calibration, e.g.). On failure we
  # cannot keep walking blind into enemies nobody will kill — the Logic would
  # believe combat is up. Better to block via the same brake, immediately, with
  # a clear reason, than degrade via fight_stalled seconds later.
  def translate(state, :run_combat) do
    case Combat.Worker.run(state.combat) do
      :ok ->
        log(:debug, "combate ligado")
        state

      {:error, messages} ->
        Logger.warning("Cavebot: combate recusou o arranque (#{inspect(messages)})")
        translate(state, {:block, :combat_preflight_failed})
    end
  end

  def translate(state, :halt_combat) do
    BotSupervisor.safe_halt(state.combat)
    release_walk(state)
  end

  # DANGEROUS BLOCK vs LOCAL BLOCK — the split exists because treating both as
  # emergencies is what erased the whole hunt in silence: a wall (:stuck) took
  # the ENTIRE fleet down and set the panic latch, which vetoes even Focus's
  # auto-resume — capture and support only came back with a human "Iniciar",
  # over a one-tile obstacle.
  #
  # DANGEROUS (@dangerous_blocks) is when the world stopped matching the route:
  # the character changed floors (the route describes ANOTHER map) or combat
  # refused to start (following the route would collect enemies nobody kills).
  # Then the full handbrake applies, in emergency_escape order: latch FIRST
  # (nothing may auto-resume over it), then the combat this worker drives, then
  # the whole fleet.
  def translate(state, {:block, reason}) when reason in @dangerous_blocks do
    state = release_walk(state)
    Logger.warning("Cavebot: BLOQUEADO (#{inspect(reason)}) — parando a frota")
    InputGate.set_panic_latch(true)
    BotSupervisor.safe_halt(state.combat)
    BotSupervisor.stop_all("caçada — " <> block_text(reason))
    stop_hunt(state, reason)
  end

  # LOCAL (:stuck, :fight_stalled) is the cavebot hitting a wall or a fight
  # that won't end: ITS problem, not the character's. Nothing there threatens
  # capture or support, and a stopped bot alive beats a dead fleet — so no
  # latch (Focus can still resume on its own) and no `stop_all`. Only this hunt
  # stops: the tick, the feeds, and the combat — which in a hunt is driven from
  # here and would fight alone forever if it outlived its owner.
  def translate(state, {:block, reason}) do
    state = release_walk(state)
    Logger.warning("Cavebot: parei (#{inspect(reason)}) — o resto da frota segue")
    BotSupervisor.safe_halt(state.combat)

    state
    |> stop_hunt(reason)
    |> schedule_comeback()
  end

  # The night is the product ("ele vai estar lá a madrugada inteira farmando"),
  # and a one-tile obstacle used to end it: the hunt stopped and waited for a
  # human until morning. A LOCAL block now stands down and comes back — a fresh
  # Logic re-enters at the nearest corner, which is exactly what unsticks a
  # knockback, a closed door, or a player who has since walked off.
  #
  # Everything stays as it was WHILE it waits (blocked, alarmed, reason on
  # screen): the comeback is an extra, never a reason to be quieter about the
  # stop. Two things it never does — retry a dangerous block (that one latched
  # the panic, and auto-resuming over a latch is the one thing this codebase
  # refuses), and retry without a budget: `cavebot_block_retries` bounds the
  # loop, and reaching a waypoint refills it.
  defp schedule_comeback(state) do
    budget = Settings.get(:cavebot_block_retries)

    if state.block_retries < budget do
      ms = Settings.get(:cavebot_block_retry_ms)
      attempt = state.block_retries + 1
      note = "tento de novo em #{div(ms, 1000)}s (tentativa #{attempt} de #{budget})"

      log(:macro, note)

      state = %{
        state
        | timer: Process.send_after(self(), :comeback, ms),
          block_retries: attempt,
          hold_note: "#{block_text_of(state)} — #{note}"
      }

      broadcast_status(state)
      state
    else
      state
    end
  end

  defp block_text_of(%{hold_note: note}) when is_binary(note), do: note
  defp block_text_of(_state), do: "parei"

  # Re-entering, not resuming: a brand-new Logic homes in at the nearest corner
  # on the current floor, which is the whole point — wherever the character
  # ended up, the route restarts from there instead of from where it gave up.
  # The session COUNTERS survive: it is the same night, and "12 waypoints" that
  # resets to zero on every hiccup answers nothing in the morning.
  defp resume_hunt(state, route) do
    log(:macro, "🔁 retomando a caçada: reentro pela rota \"#{route.name}\"")
    WorldState.put(:dungeon, %{id: route.dungeon}, now())
    counters = state.counters

    state =
      %{cancel_timer(state) | logic: Logic.new(route, config())}
      |> reset_session()
      |> Map.put(:counters, counters)
      |> attach()
      |> schedule_tick()

    broadcast_status(state)
    state
  end

  # What both levels share: alarm, reason written on screen, tick cancelled,
  # feeds released (capturing for nobody only loads the broker). The Logic is
  # forced to :blocked because the block can come from it (floor change) OR the
  # Worker (combat refused to start) — either way the reported state must be
  # :blocked while it lasts.
  defp stop_hunt(state, reason) do
    state = state |> release_walk() |> free_fire()
    broadcast({:cavebot_alarm, reason})
    log(:macro, block_text(reason))

    state =
      %{
        cancel_timer(detach(state))
        | logic: %{state.logic | state: :blocked},
          hold_note: block_text(reason)
      }
      |> mark_logged(:note)

    broadcast_status(state)
    state
  end

  defp block_text(:floor_changed), do: "BLOQUEADO: mudou de andar"
  defp block_text(:combat_preflight_failed), do: "BLOQUEADO: o combate recusou o arranque"
  defp block_text(:stuck), do: "parei: travado, sem sair do lugar"

  defp block_text(:stairs),
    do: "parei: não achei a escada — corrija o ponto da rota (o andar não mudou)"

  defp block_text(:fight_stalled), do: "parei: a luta não termina"
  defp block_text(reason), do: "parei: #{inspect(reason)}"

  # A step failure (e.g. {:error, :no_layout} with no HUD located) takes
  # nothing down: the next tick rereads the world and retries. But it is
  # RECORDED — a step that never left counting as taken is exactly what killed
  # the fleet silently on 2026-07-23 (gate closed → click swallowed → Logic
  # believed the step → frozen position → :stuck → panic). A Logger.debug is
  # not visibility: nobody reads the log when the bot stops.
  # The keys a direction asks for: one per non-zero axis, so a diagonal
  # waypoint is walked diagonally instead of in two straight legs. The game's
  # y grows SOUTH.
  # WHEN the queue last changed, not just how big it is: a queue that shrinks is
  # the capture working, and one frozen at 2 is work that will never happen.
  # OFF the tick, on purpose. `Body.perform/2` is a call with an :infinity
  # timeout, and the Body may be several seconds deep in a capture when this
  # goes out — blocking the tick would freeze the hunt AND time out the page's
  # own `status` call, which is how a LiveView died once before (2026-07-30).
  # The Body's queue keeps the ordering; the answer is only worth a log line,
  # and a refusal must SAY so instead of narrating a revive that never
  # happened.
  defp fire_revive(body, actions) do
    spawn(fn ->
      case body.perform(actions, :high) do
        :ok -> log(:macro, "⚡ resetei os cooldowns no revive")
        {:error, reason} -> log(:macro, "⚡ o corpo recusou o revive: #{inspect(reason)}")
        other -> log(:macro, "⚡ revive respondeu #{inspect(other)}")
      end
    end)
  end

  # OFF the tick, like every other `perform` here: it is a call with an
  # :infinity timeout and the Body may be several seconds deep in a capture —
  # blocking this tick would freeze the hunt AND time out the page's own
  # `status` call. The arrows are already down before the spawn (release_walk/1
  # is synchronous), so letting go still happens strictly before the press.
  #
  # :high, not :normal, and the ORDERING is why: `hold/1` is answered inline by
  # the Body loop while a `perform` sequence waits its turn in the queue. A
  # press parked in the normal queue could still be pending when the NEXT tick
  # holds the arrows back down — a press under a hold, exactly the bug the
  # release above exists to prevent. :high preempts the queue and narrows that
  # window to near-zero; it is the same trade `park_click/2` already takes.
  #
  # The answer is worth a log line: a refusal must SAY so instead of narrating
  # a skill that never went out.
  defp fire_skills(body, keys) do
    actions = Enum.map(keys, &{:press, &1})
    text = Enum.join(keys, ", ")

    spawn(fn ->
      case body.perform(actions, :high) do
        :ok -> log(:macro, "✨ skill da rota: #{text}")
        {:error, reason} -> log(:macro, "✨ o corpo recusou a skill: #{inspect(reason)}")
        other -> log(:macro, "✨ a skill respondeu #{inspect(other)}")
      end
    end)
  end

  # The categories in their canonical order, deduplicated by KEY: two
  # categories can land on the same key, and pressing it twice is not what he
  # asked for.
  defp skill_keys(loadout, categories) do
    categories
    |> Enum.flat_map(&Combat.Loadout.keys(loadout, &1))
    |> Enum.uniq()
  end

  defp skills_text(categories),
    do: Enum.map_join(categories, ", ", &"#{SkillProfile.icon(&1)} #{SkillProfile.label(&1)}")

  defp park_click(state, point) do
    times = Settings.get(:cavebot_park_clicks)
    gap = Settings.get(:cavebot_park_gap_ms)

    # "ele mandou, mas mandou 1x só, e as vezes buga mesmo, nao vai, tem que
    # mandar algumas vezes, umas 4x, pra ter certeza" (Lucas, 2026-08-11). The
    # client drops the order when it is busy; the click is idempotent (the
    # pokémon walks to the same tile) so repeating it costs nothing and is the
    # difference between "andou" and "às vezes andou".
    #
    # Off the tick, like every other Body.perform here: it is a call with an
    # :infinity timeout and the Body may be seconds deep in a capture.
    clicks = List.duplicate({:click, :middle, point}, times)
    actions = Enum.intersperse(clicks, {:wait, gap})
    body = state.body
    spawn(fn -> body.perform(actions, :high) end)

    log(:macro, "🖱️ pokémon posicionado em #{elem(point, 0)}, #{elem(point, 1)} (#{times}x)")
    state
  end

  # A spot the Logic named, turned into a screen point HERE — where the
  # calibration lives. A distance in tiles is measured from the character, so
  # it survives the game window moving; a recorded click is taken as it was
  # made. Nothing anchors the character = nothing is clicked, and it is said.
  defp spot_point({:point, {x, y}}), do: {x, y}

  defp spot_point({:tiles, {_dx, _dy} = tiles}) do
    case Calibration.load() do
      {:ok, calib} -> Calibration.tile_point(calib, tiles)
      _uncalibrated -> nil
    end
  end

  defp spot_point(_nothing), do: nil

  defp sweep_text({x, y}), do: "🧹 varrendo onde o pokémon estava (#{x}, #{y})"
  defp sweep_text(_character), do: "🧹 varrendo os corpos antes de seguir"

  # nil when the portrait or the neutral point was never marked: a missing
  # calibration must cost the hunt a log line, never a stuck stop.
  defp revive_combo do
    with {:ok, calib} <- Calibration.load(),
         photo when is_tuple(photo) <- Calibration.pokemon_photo_point(calib),
         neutral when is_tuple(neutral) <- calib.neutral_point || calib.player_point do
      PlayerSupport.Logic.combo(%{
        rescue_key: Settings.get(:rescue_key),
        max_revive_key: Settings.get(:max_revive_key),
        photo_point: photo,
        neutral_point: neutral,
        step_ms: Settings.get(:rescue_step_ms)
      })
    else
      _uncalibrated -> nil
    end
  end

  defp note_capture(state, pending) do
    if pending == state.capture_pending,
      do: state,
      else: %{state | capture_pending: pending, capture_changed_at: now()}
  end

  # The sweep's own queue: the hunt does not count it as work to wait for
  # UNLESS it asked for the sweep itself (see Logic.sweeping?/3), but when it
  # did, the same "is it MOVING" rule decides how long it waits.
  defp note_sweep(state, pending) do
    if pending == state.sweep_pending,
      do: state,
      else: %{state | sweep_pending: pending, sweep_changed_at: now()}
  end

  # Close in, precision beats speed: a held arrow keeps walking between
  # readings and always overshoots the last tile, which is fine on a wide
  # corner and fatal on a staircase one tile wide (Lucas, 2026-08-11). One tap
  # per tick lands exactly on it.
  defp precise?(dx, dy) do
    range = Settings.get(:cavebot_precise_tiles)
    range > 0 and abs(dx) <= range and abs(dy) <= range
  end

  defp hold_walk(state, dx, dy) do
    # An axis already inside the arrival tolerance is NOT held: with a key held
    # down the character keeps walking between readings, so correcting a
    # one-tile error overshoots it the other way — the zig-zag Lucas saw
    # (left+down → down → right+down → down, around the same corner).
    tol = Settings.get(:cavebot_arrival_tolerance_tiles)
    keys = Enum.reject([horizontal(dx, tol), vertical(dy, tol)], &is_nil/1)

    if keys == [] and {dx, dy} != {0, 0} do
      # …but a decision to WALK must never come out as no key. Both axes inside
      # the tolerance left `hold([])` as the whole step — the release, nothing
      # pressed — and the character could not close the last tile: the position
      # never changed, `walk_timeout_ms` made it `:stuck`, and the four
      # `unstick/3` retries each produced the same empty hold before the corner
      # was skipped. Reachable at `cavebot_precise_tiles: 0` (in range, and the
      # gear he asked for when the hold is the fast one), and newly SO on the
      # corner a staircase leaves from, which is now reached EXACTLY. One tap
      # closes it.
      state |> release_walk() |> arrow_step(dx, dy)
    else
      hold_keys(state, keys, dx, dy)
    end
  end

  defp hold_keys(state, keys, dx, dy) do
    at = now()
    text = "segurando #{Enum.join(keys, "+")}"
    result = step_result(state.body.hold(keys))
    stepped = %{state | last_step: %{dx: dx, dy: dy, result: result, at: at}}

    if result == :ok do
      if action_text(state) != text,
        do: log(:debug, "#{text} → wp #{stepped.logic.wp_index + 1}/#{wp_total(stepped)}")

      {%{
         stepped
         | held_keys: keys,
           counters: bump(stepped.counters, :steps),
           last_action: %{text: text, at: at}
       }, held_outcome(keys)}
    else
      Logger.debug("Cavebot: segurar (#{dx},#{dy}) falhou: #{inspect(result)}")
      {%{stepped | held_keys: []}, :nothing}
    end
  end

  defp held_outcome([]), do: :nothing
  defp held_outcome(keys), do: {:hold, keys}

  defp release_walk(%{held_keys: []} = state), do: state

  defp release_walk(state) do
    state.body.hold([])
    %{state | held_keys: []}
  end

  defp horizontal(dx, tol) when abs(dx) <= tol, do: nil
  defp horizontal(dx, _tol) when dx > 0, do: "right"
  defp horizontal(_dx, _tol), do: "left"

  defp vertical(dy, tol) when abs(dy) <= tol, do: nil
  defp vertical(dy, _tol) when dy > 0, do: "down"
  defp vertical(_dy, _tol), do: "up"

  # Returns the state AND the key that actually left the hands (`nil` when the
  # Body answered without naming one), because a refused step is not a step —
  # see `log_walk_decision/4`.
  defp arrow_step(state, dx, dy) do
    at = now()
    raw = state.body.arrow_step(dx, dy, [])
    result = step_result(raw)
    text = "passo #{dx},#{dy}"
    stepped = %{state | last_step: %{dx: dx, dy: dy, result: result, at: at}}

    if result == :ok do
      # the step is the most frequent event here (5/s): only becomes a line
      # when it CHANGES — repeating "passo 90,80" tick after tick says nothing new.
      if action_text(state) != text,
        do: log(:debug, "#{text} → wp #{stepped.logic.wp_index + 1}/#{wp_total(stepped)}")

      {%{stepped | counters: bump(stepped.counters, :steps), last_action: %{text: text, at: at}},
       {:tap, step_key(raw)}}
    else
      Logger.debug("Cavebot: passo (#{dx},#{dy}) falhou: #{inspect(result)}")
      {stepped, :nothing}
    end
  end

  defp step_key({:ok, key}) when is_binary(key), do: key
  defp step_key(_unnamed), do: nil

  defp step_result(:ok), do: :ok
  defp step_result({:ok, _point}), do: :ok
  defp step_result({:error, reason}), do: {:error, reason}
  defp step_result(other), do: {:error, other}

  # First enabled AND valid route: a route without waypoints (or with mixed
  # floors) never reaches the Logic — `current_wp` of an empty list would crash.
  defp active_route do
    Enum.find(Store.all(), fn route ->
      route.enabled? and Route.validate(route) == :ok
    end)
  end

  # Two shapes, on purpose: the scalar knobs come straight from Settings, and
  # the hunt's DEFAULT park spot is a pair — where the pokémon goes at a kill
  # spot he never marked one for. {0, 0} is "on top of me", which means don't
  # send it anywhere.
  defp config do
    @config_keys
    |> Map.new(fn {key, setting} -> {key, Settings.get(setting)} end)
    |> Map.put(
      :park_tiles,
      {Settings.get(:cavebot_park_tiles_x), Settings.get(:cavebot_park_tiles_y)}
    )
  end

  # :minimap is THIS worker's feed (monitored + reattached); :battle is already
  # monitored by Combat.Worker while it runs — here we only register demand so
  # the feed doesn't pause between fights.
  defp attach(state) do
    safe(fn -> Perception.attach(:minimap) end)
    safe(fn -> Perception.attach(:battle) end)
    demonitor_feed(state.feed_ref)
    ref = Process.monitor(Feed.name(:minimap))
    %{state | attached?: true, feed_ref: ref, reattach_attempts: 0, hold_note: nil}
  end

  defp detach(%{attached?: false} = state), do: state

  defp detach(state) do
    safe(fn -> Perception.detach(:minimap) end)
    safe(fn -> Perception.detach(:battle) end)
    demonitor_feed(state.feed_ref)
    %{state | attached?: false, feed_ref: nil}
  end

  defp reattach_minimap(state) do
    Perception.attach(:minimap)
    safe(fn -> Perception.attach(:battle) end)
    demonitor_feed(state.feed_ref)
    ref = Process.monitor(Feed.name(:minimap))
    %{state | attached?: true, feed_ref: ref, reattach_attempts: 0, hold_note: nil}
  catch
    :exit, _reason -> schedule_reattach(state)
  end

  # Giving up after 20x250ms used to be MUTE: state came back untouched and the
  # cavebot sat positionless forever with nobody knowing why. Giving up is a
  # fact — it becomes an on-screen reason and one feed line, once.
  defp schedule_reattach(%{reattach_attempts: attempts} = state) when attempts >= @max_reattach do
    unless state.hold_note == @feed_lost do
      Logger.warning("Cavebot: #{@feed_lost}")
      log(:macro, @feed_lost)
    end

    state = mark_logged(%{state | hold_note: @feed_lost}, :note)
    broadcast_status(state)
    state
  end

  defp schedule_reattach(state) do
    Process.send_after(self(), :reattach_minimap, 250)
    %{state | reattach_attempts: state.reattach_attempts + 1}
  end

  defp demonitor_feed(nil), do: :ok
  defp demonitor_feed(ref), do: Process.demonitor(ref, [:flush])

  defp safe(fun) do
    fun.()
  catch
    :exit, _reason -> :ok
  end

  # active? false = never self-schedule (tests drive with manual :tick);
  # :blocked is terminal — only a human restarts, via run.
  defp schedule_tick(%{active?: false} = state), do: state
  defp schedule_tick(%{logic: nil} = state), do: state
  defp schedule_tick(%{logic: %Logic{state: :blocked}} = state), do: state

  defp schedule_tick(state) do
    state = cancel_timer(state)
    %{state | timer: Process.send_after(self(), :tick, @tick_ms)}
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | timer: nil}
  end

  defp running?(state), do: match?(%Logic{}, state.logic) and state.logic.state != :blocked

  # A stopped hunt is the empty snapshot WITH ALL KEYS: the screen reads fields
  # directly, and a map that changes shape between stopped and running would
  # break the template at the worst moment — right after the bot stopped.
  @idle_snapshot %{
    state: :idle,
    route: nil,
    wp_index: 0,
    wp_total: 0,
    wp_target: nil,
    pos: nil,
    pos_age_ms: nil,
    distance_tiles: nil,
    hold_reason: nil,
    luring?: false,
    comeback?: false,
    last_action: nil,
    counters: %{waypoints: 0, steps: 0}
  }

  @doc """
  The COMPLETE snapshot shape with everything zeroed — the placeholder the
  `BotSupervisor` uses when the worker doesn't answer in time.
  """
  @spec idle_snapshot() :: snapshot
  def idle_snapshot, do: @idle_snapshot

  defp snapshot(%{logic: nil} = state), do: %{@idle_snapshot | counters: state.counters}

  defp snapshot(%{logic: logic} = state) do
    now = now()

    %{
      state: logic.state,
      route: logic.route.name,
      wp_index: logic.wp_index,
      wp_total: wp_total(state),
      wp_target: wp_target(state),
      pos: state.pos,
      pos_age_ms: state.pos_at && now - state.pos_at,
      distance_tiles: distance_tiles(state),
      hold_reason: hold_reason(state, now),
      # gathering mobs instead of fighting them — "andando" on a mob leg and
      # "andando" on a normal one are not the same thing to watch
      luring?: Logic.luring?(logic),
      # a stop that ENDS the night and a stop that lasts 30 seconds look
      # identical from `state: :blocked` alone, and the screen must not tell
      # him to go fix something the hunt is about to fix itself
      comeback?: logic.state == :blocked and state.timer != nil,
      last_action: state.last_action,
      counters: state.counters
    }
  end

  defp wp_total(%{logic: %Logic{route: route}}), do: length(route.waypoints)
  defp wp_total(_state), do: 0

  defp wp_target(%{logic: %Logic{} = logic}), do: Enum.at(logic.route.waypoints, logic.wp_index)
  defp wp_target(_state), do: nil

  # Remaining distance in TILES, signed — the reading that answers "is he
  # actually heading there?" across two consecutive snapshots.
  defp distance_tiles(%{pos: {x, y, _z}} = state) do
    case wp_target(state) do
      %{x: wx, y: wy} -> %{dx: wx - x, dy: wy - y}
      nil -> nil
    end
  end

  defp distance_tiles(_state), do: nil

  # The broadcast trigger compares what changes by FACT, never by clock:
  # `pos_age_ms` and last_action's `at` advance on their own and would emit 5
  # maps per second forever — noise that buries the real change.
  defp broadcast_key(state, now) do
    {logic_state(state), state.logic && state.logic.wp_index, hold_reason(state, now),
     action_text(state)}
  end

  defp logic_state(%{logic: %Logic{state: s}}), do: s
  defp logic_state(_state), do: :idle

  defp action_text(%{last_action: %{text: text}}), do: text
  defp action_text(_state), do: nil

  # "Why isn't he walking", in the other workers' mold (fishing,
  # player_support): the out-of-tick reason first (lost feed, block) as the most
  # serious; the refused step next, the tick's concrete obstacle; blindness
  # last, explaining ticks where walking isn't even attempted. All together
  # when all apply. nil = nothing holding.
  #
  # Each reason carries a TYPE, and the type decides whether it was already
  # counted in the feed: the blindness text changes every second (the counter
  # advances) with no new fact, and comparing text would log a line per second.
  defp holds(%{logic: nil}, _now), do: []

  defp holds(state, now) do
    Enum.reject(
      [
        note_hold(state.hold_note),
        step_hold(state.last_step),
        hp_hold(state.logic),
        blind_hold(state.logic, now)
      ],
      &is_nil/1
    )
  end

  defp hold_reason(state, now) do
    case holds(state, now) do
      [] -> nil
      reasons -> reasons |> Enum.map_join(" + ", &elem(&1, 1))
    end
  end

  defp note_hold(nil), do: nil
  defp note_hold(text), do: {:note, text}

  defp step_hold(%{result: {:error, reason}}), do: {{:step, reason}, step_hold_text(reason)}
  defp step_hold(_ok_or_no_step), do: nil

  defp step_hold_text(:input_gate_closed), do: "jogo sem foco (ou pânico) — nada é clicado"
  defp step_hold_text(:no_layout), do: "HUD não localizado — não sei onde fica o minimapa"
  defp step_hold_text(reason), do: "o passo no minimapa falhou: #{inspect(reason)}"

  defp hp_hold(logic) do
    case Logic.recovery(logic) do
      nil ->
        nil

      %{hp_pct: nil, resume_pct: pct} ->
        {:hp, "esperando o pokémon voltar da poké bola — a rota segue com #{pct}% de vida"}

      %{hp_pct: hp, resume_pct: pct} ->
        {:hp, "vida em #{hp}% — a rota segue quando voltar a #{pct}%"}
    end
  end

  defp blind_hold(logic, now) do
    case Logic.blind_ms(logic, now) do
      nil ->
        nil

      ms ->
        {:blind,
         "não sei onde estou há #{div(ms, 1000)}s — a coordenada do minimapa não está sendo lida"}
    end
  end

  # Reaching a waypoint is the hunt's only progress: the Logic already advanced
  # the index, so the one reached is the PREVIOUS waypoint — its number is what
  # a human recognizes in the route list.
  defp note_arrival(%{logic: %Logic{wp_index: same}} = state, same, _now), do: state

  # Reaching a corner is the proof the hunt is HEALTHY, so it hands every
  # comeback back: a ten-hour night with three unrelated hiccups must not run
  # out of budget over hiccups that were hours apart.
  defp note_arrival(state, wp_before, now) do
    text = "waypoint #{wp_before + 1}/#{wp_total(state)}"
    log(:macro, text)

    %{
      state
      | counters: bump(state.counters, :waypoints),
        last_action: %{text: text, at: now},
        block_retries: 0
    }
  end

  # The staircase that WORKED. A leg taken by tap never enters `:stairs`, so
  # the success this whole mechanism exists to create was silent while the
  # failure ("🪜 procurando a escada") was loud — and in the journal, where he
  # judges whether the tap helped, a staircase taken in one key and one nobody
  # ever found looked exactly the same.
  #
  # Once per staircase, because one arrival ends one leg. The three conditions
  # are what make it that leg: the index moved, the state before was `:walking`
  # (a skip moves the index from `:stuck`, and the ring's own find moves it from
  # `:stairs` — `note_search/3` already narrates that one), and taps had been
  # spent on the leg being finished.
  defp note_stair_taken(%{logic: %Logic{wp_index: same}} = state, same, _before, _taps, _now),
    do: state

  defp note_stair_taken(state, _wp_before, :walking, taps, now) when taps > 0 do
    log(:macro, "🪜 escada tomada no toque: uma tecla, dois tiles, sem procurar")
    %{state | last_action: %{text: "escada no toque", at: now}}
  end

  defp note_stair_taken(state, _wp_before, _before, _taps, _now), do: state

  # Looking for the step, and finding it. A hunt standing on the right tile
  # with the floor unchanged is doing something specific and invisible — the
  # only thing on screen used to be the waypoint number, which is exactly what
  # made "ele continua avançando nos waypoints" so hard to see (2026-08-11).
  defp note_search(%{logic: %Logic{state: :stairs}} = state, before, now)
       when before != :stairs do
    case wp_target(state) do
      %{x: x, y: y, z: z} ->
        log(:macro, "🪜 procurando a escada perto de #{x}, #{y} (o andar #{z} não veio)")
        %{state | last_action: %{text: "procurando a escada", at: now}}

      nil ->
        state
    end
  end

  defp note_search(%{logic: %Logic{state: :walking}, pos: {_x, _y, z}} = state, :stairs, now) do
    log(:macro, "🪜 achei a escada: agora no andar #{z}")
    %{state | last_action: %{text: "escada tomada", at: now}}
  end

  defp note_search(state, _before, _now), do: state

  # The abandon and the comeback are EDGES worth one line each; the route held
  # in between is the hold reason's job, not the feed's.
  defp note_recovery(%{logic: %Logic{recovering?: true} = logic} = state, false, now) do
    log(:macro, "🩸 vida em #{logic.last_hp}% — modo sobrevivência: mato o que veio e espero")
    %{state | last_action: %{text: "vida baixa — segurei a rota", at: now}}
  end

  defp note_recovery(%{logic: %Logic{recovering?: false, last_hp: hp}} = state, true, now)
       when is_integer(hp) do
    log(:macro, "💚 vida em #{hp}% — pokémon recuperado, a caçada segue")
    %{state | last_action: %{text: "recuperado — rota retomada", at: now}}
  end

  defp note_recovery(state, _same, _now), do: state

  # The hold reason is EDGE information: one line when it APPEARS, silence
  # while it still applies. Repeating every 200ms would drown the feed exactly
  # when it most needs reading. Gone and back = new edge, new line.
  defp log_hold_edge(state, now) do
    holds = holds(state, now)

    for {kind, text} <- holds, kind not in state.logged_holds, do: log(:macro, text)

    %{state | logged_holds: Enum.map(holds, &elem(&1, 0))}
  end

  # A reason already announced by its creator (block, lost feed) must not be
  # announced again by the edge on the next tick.
  defp mark_logged(state, kind), do: %{state | logged_holds: [kind | state.logged_holds]}

  # An overnight hunt's job is surviving unattended, and both its nets can be
  # silently missing: the revive toggle ships OFF, and the HP guard reads a
  # fact only the support worker publishes. Named at the START, in the feed he
  # reads before sleeping — discovering either at 4am costs the night.
  defp warn_unarmed_safety do
    unless Settings.get(:rescue_enabled) do
      log(:macro, "⚠️ resgate desligado: se o pokémon cair, ninguém revive — arme na Central")
    end

    if Perception.pokemon(now()) == :unknown do
      log(:macro, "⚠️ sem leitura de vida ainda — a guarda de HP só age com o suporte rodando")
    end
  end

  @typedoc """
  What actually left the hands on a walking decision: keys held down, ONE arrow
  tapped (named by the Body, `nil` when it did not name it), or nothing —
  a refusal, or a direction with no key in it.
  """
  @type walk_outcome :: {:hold, [String.t()]} | {:tap, String.t() | nil} | :nothing

  @doc """
  One line per walking decision, carrying everything a hunt cannot be read back
  from afterwards: where he WAS, how far the target was when the decision was
  taken, how old the reading it was taken on was, and what actually went out.

  The four together answer the three questions this instrument exists for —
  real speed in tiles/s (absolute positions, differenced by nobody), tiles
  covered per decision (`{:walk, 4, -3}` reads identically whether the Worker
  then held two keys, held one, tapped one or pressed nothing: what went out is
  the half that differs), and whether decisions are taken on stale readings.

  `cavebot_measure_walk` (off by default) is the whole switch, and off means
  SILENCE: the hunt decides ~5x a second, `/cavebot` keeps 8 log lines and does
  not filter by level, so a line per decision turned that box into a rolling
  1.6-second window — `waypoint 12/67`, `🪜 procurando a escada` and `BLOQUEADO`
  scrolled away before he could read them. Measuring is opt-in; off costs
  exactly zero lines.

  On, the line is `:macro`, because `:debug` is exactly what
  `Journal.persist_event/2` refuses to write: measured at `:debug` a hunt leaves
  nothing on disk and can only be read off the panel's last ~200 lines. `:macro`
  is the lowest level the journal keeps, so a whole hunt lands in
  `~/.pokex/journal/*.jsonl`. It does bury the narrative while it is on — which
  is what measuring means, and why nobody hunts with it on.

  Public because it is instrumentation: the point is to be callable from a test
  without standing up a whole hunt. "a movimentação tá muito ruim ainda"
  (Lucas, 2026-08-12) — and neither the overshoot nor the wall-pushing has ever
  been measured, only watched.
  """
  @spec log_walk_decision(
          Logic.action(),
          {integer, integer, integer} | nil,
          non_neg_integer | nil,
          walk_outcome
        ) :: :ok
  def log_walk_decision({kind, dx, dy}, pos, age_ms, went_out)
      when kind in [:walk, :nudge] do
    # Read per decision, not frozen into `config/0` at `run`: turning measuring
    # on is something he does BECAUSE the hunt is walking badly right now, and a
    # switch that only took effect on the next hunt would measure the next hunt.
    if Settings.get(:cavebot_measure_walk) do
      log(
        :macro,
        "andar #{kind} #{walk_pos_text(pos)}: faltam #{dx},#{dy} tiles · " <>
          "leitura de #{age_ms || "?"}ms atrás · #{went_out_text(went_out)}"
      )
    end

    :ok
  end

  def log_walk_decision(_other_action, _pos, _age, _went_out), do: :ok

  defp walk_pos_text({x, y, z}), do: "de #{x},#{y},#{z}"
  defp walk_pos_text(_never_read), do: "de lugar nenhum"

  defp went_out_text({:hold, keys}), do: "segurei #{Enum.join(keys, "+")}"
  defp went_out_text({:tap, nil}), do: "toquei uma seta"
  defp went_out_text({:tap, key}), do: "toquei #{key}"
  defp went_out_text(:nothing), do: "NENHUMA tecla saiu"

  defp log(level, text), do: broadcast({:cavebot_log, level, "caçada: " <> text})

  defp bump(counters, key), do: Map.update(counters, key, 1, &(&1 + 1))

  # Halting keeps only the COUNTERS: "the hunt did 12 waypoints and 340 steps"
  # is the summary that matters after halt. Reason, last action and position
  # belong to the tick — and a tick that no longer exists must not keep
  # explaining the screen.
  defp end_session(state), do: %{reset_session(state) | counters: state.counters}

  # A new hunt inherits nothing: counters, last action, reasons and the known
  # position all belong to their own session.
  defp reset_session(state) do
    %{
      state
      | last_step: nil,
        pos: nil,
        pos_at: nil,
        pos_age: nil,
        counters: %{waypoints: 0, steps: 0},
        last_action: nil,
        hold_note: nil,
        logged_holds: []
    }
  end

  defp broadcast_status(state), do: broadcast({:cavebot, snapshot(state)})

  defp broadcast(message), do: Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, message)

  defp now, do: System.monotonic_time(:millisecond)
end
