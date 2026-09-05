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
  alias Pokex.Bots.HuntMode
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
  @dangerous_blocks [:floor_changed, :combat_preflight_failed, :revive_dead, :brain_gone]

  # The night's tally: corners and steps are progress, the other three are the INCIDENTS,
  # without which the morning question "what happened" has no answer.
  @zero_counters %{waypoints: 0, steps: 0, aborts: 0, comebacks: 0, blocks: 0}

  @config_keys %{
    arrival_tolerance: :cavebot_arrival_tolerance_tiles,
    blind_kick_ms: :cavebot_blind_kick_ms,
    walk_timeout_ms: :cavebot_walk_timeout_ms,
    stuck_max_retries: :cavebot_stuck_max_retries,
    clear_debounce_ms: :cavebot_clear_debounce_ms,
    fight_timeout_ms: :cavebot_fight_timeout_ms,
    post_kill_dwell_ms: :cavebot_post_kill_dwell_ms,
    capture_wait_ms: :cavebot_capture_wait_ms,
    pinned_probe_ms: :cavebot_pinned_probe_ms,
    stop_wait_ms: :cavebot_stop_wait_ms,
    gather_wait_ms: :cavebot_gather_wait_ms,
    fight_only_at_stops: :cavebot_fight_only_at_stops,
    stair_probe_ms: :cavebot_stair_probe_ms,
    stair_max_probes: :cavebot_stair_max_probes,
    stair_step_ms: :cavebot_stair_step_ms,
    stair_step_taps: :cavebot_stair_step_taps
  }

  def topic, do: @topic

  def start_link(opts \\ []) do
    state = %{
      body: Keyword.get(opts, :body, Pokex.Bots.Body),
      combat: Keyword.get(opts, :combat, Combat.Worker),
      # A ceiling on starting combat, because that call runs the whole
      # `Preflight` inline and the preflight queues behind the capture broker.
      # Without one the tick took the default 5s and EXITED — see
      # `safe_combat_run/1`.
      combat_run_timeout_ms: Keyword.get(opts, :combat_run_timeout_ms, 5_000),
      active?: Keyword.get(opts, :active, Application.get_env(:pokex, :cavebot_active, true)),
      logic: nil,
      timer: nil,
      attached?: false,
      # when this worker last saw the brain publishing (see `brain_gone?/3`); nil while it
      # never showed up
      brain_seen_at: nil,
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
      last_step: nil,
      pos: nil,
      pos_at: nil,
      # how old the :minimap fact was on the tick that decided — see observe/2
      pos_age: nil,
      # comebacks already spent on local blocks tonight; reaching a waypoint
      # gives them all back (see note_arrival/3)
      block_retries: 0,
      counters: @zero_counters,
      # The night clock in wall time (`system_time`), not monotonic: the reader is a
      # screen that wants to say "since 22:14" as well as "for 6h12", and the monotonic
      # clock does not know the time of day.
      started_at: nil,
      ended_at: nil,
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
          started_at: integer | nil,
          ended_at: integer | nil,
          counters: %{
            waypoints: non_neg_integer,
            steps: non_neg_integer,
            aborts: non_neg_integer,
            comebacks: non_neg_integer,
            blocks: non_neg_integer
          }
        }

  @spec status(GenServer.server()) :: snapshot
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(state) do
    Phoenix.PubSub.subscribe(Pokex.PubSub, Combat.Worker.topic())
    # The Catcher's queue decides when the route may resume — heard, never asked: a `call` to
    # the Catcher parks behind its multi-second captures (the 2026-07-30
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

        state =
          %{cancel_timer(state) | logic: Logic.new(route, config()), block_retries: 0}
          |> reset_session()
          |> start_clock()
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
      # Gate closed = no step goes out (the Body refuses), but the Logic's patience clocks kept
      # running — 3s without "progress" became :stuck and the hunt died BEFORE
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
      # panic/Stop are never reverted automatically: the Guardian may have latched while
      # this hunt was waiting, and a timer fired from before must never be what undoes it.
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

  # Corpses queued for capture — and ONLY those.
  def handle_info({:catcher, snapshot}, state) do
    {:noreply, note_capture(state, Map.get(snapshot, :pending_corpses, 0))}
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

  # The read position is KEPT with its read time: during a blind spell the world the Logic gets
  # has `pos: nil` (it must not walk on a guess), but the screen keeps
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
      |> publish_hunt(now)
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

  # WHERE the hunt is, as a fact, for whoever needs to reason about the leg rather than about
  # the screen.
  defp publish_hunt(state, now) do
    logic = state.logic

    WorldState.put(
      :hunt,
      %{
        state: logic.state,
        luring?: Logic.luring?(logic),
        wp_index: logic.wp_index,
        waypoints: length(logic.route.waypoints),
        recovering?: logic.recovering?,
        # The mode is resolved ONCE, here. The route THIS hunt walks chooses it, and
        # from here it travels as a fact: the brain reads the same value combat received
        # at start, so the two cannot disagree mid-tick.
        mode: HuntMode.in_force(logic.route.mode)
      },
      now
    )

    state
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

  # The combat snapshot, HEARD and remembered: the Logic receives the last
  # broadcast state as world.combat_state — never a call into Combat.
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
      hp_pct: own_hp(now),
      fainted?: own_fainted?(now)
    }

    asks = engine_asks(now)
    state = remember_brain(state, asks, now)
    world = Map.merge(world, Map.put(asks, :brain_gone?, brain_gone?(state, asks, now)))

    if pos, do: {world, %{state | pos: pos, pos_at: now}}, else: {world, state}
  end

  # The mute brain, and why it became a brake.
  #
  # The brain once stopped publishing mid-hunt and the hunt went on for eight minutes without
  # it (no road hold in the mob, no revive request, no `:stranded` brake) until the pokémon
  # fell and the character died alone in front of the pile. Nothing warned: a dead brain only
  # delayed the hunt by a tick back when nobody obeyed its orders; today it is who sends the
  # revive.
  #
  # The memory is the WORKER's, not the fact's: what signs the death is the TRANSITION (this
  # hunt saw the brain, and it went silent). A hunt that never had a brain (engine off) goes
  # on as always. `engine_asks/1` answers an EMPTY map when no brain publishes, hence the
  # question is the absence of the key, not `engine?: false`.
  defp remember_brain(state, %{engine?: true}, now), do: %{state | brain_seen_at: now}
  defp remember_brain(state, _sem_cerebro, _now), do: state

  defp brain_gone?(%{brain_seen_at: at}, asks, now) when is_integer(at),
    do: Map.get(asks, :engine?) != true and now - at >= Settings.get(:cavebot_brain_gone_ms)

  defp brain_gone?(_nunca_visto, _asks, _now), do: false

  # What the ENGINE asks of the road, read as a fact with an age like everything
  # else here. Missing or stale means it asks nothing: the route walks, and the
  # route's own `cooldown_revive` mark runs exactly as it always did. An engine
  # that dies can slow this hunt down by not more than one tick.
  defp engine_asks(now) do
    with {:ok, orders} <- WorldState.get(:orders, Settings.get(:engine_orders_max_age_ms), now),
         {:ok, picture} <-
           WorldState.get(:situation, Settings.get(:engine_orders_max_age_ms), now) do
      %{
        engine?: true,
        route_hold?: Map.get(orders, :route) == :hold,
        # The retreat (fenced R7): the spent bar backs off over ground already cleared
        # instead of collecting fresh spawn ahead; see `Logic.retreat/3`.
        route_back?: Map.get(orders, :route) == :back,
        # The brain gave up on the revive (phase :stranded): not a wait but the end of
        # the night. Logic turns it into a DANGEROUS block that stops the fleet and does
        # not come back on its own; see `Engine.Logic`, the floor brake.
        stranded?: Map.get(orders, :phase) == :stranded,
        # Waiting for cooldown is not a stall: with the bar spent the screen stays
        # identical for tens of seconds, and the stalemate clock must not count that as
        # a stalled fight; see `Logic.stall_or_wait/5`.
        bar_spent?: Map.get(picture, :spent?) == true,
        reset_worth?: reset_worth?(picture),
        reset_note: reset_note(picture)
      }
    else
      _no_engine -> %{}
    end
  end

  # A revive does two jobs — it heals AND it clears every cooldown — so it is worth spending
  # when either one is actually needed.
  defp reset_worth?(picture) do
    # The budget at the corner: a reset corner is convenience, and with the count in the
    # reserve the last revives belong to the emergency and the fainted.
    if reserve_reached?(picture), do: false, else: reset_useful?(picture)
  end

  defp reserve_reached?(picture) do
    case Map.get(picture, :revive_left) do
      left when is_integer(left) -> left <= Settings.get(:engine_revive_reserve)
      _sem_conta -> false
    end
  end

  defp reset_useful?(%{own_hp: hp} = picture) do
    prepared? = Map.get(picture, :prepared?, :unknown)

    cond do
      is_integer(hp) and hp < Settings.get(:engine_band_yellow_pct) -> true
      prepared? == false -> true
      is_integer(hp) and hp < 100 -> true
      prepared? == true and is_integer(hp) -> false
      true -> :unknown
    end
  end

  defp reset_note(%{own_hp: hp, prepared?: true}) when is_integer(hp),
    do: "vida #{hp}%, cooldowns prontos"

  defp reset_note(%{own_hp: hp}) when is_integer(hp), do: "vida #{hp}%"
  defp reset_note(_no_reading), do: nil

  # The :pokemon fact PlayerSupport already publishes 8x a second — read, never asked.
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

  # Fail-safe 0: a missing/stale :battle fact reads as "screen clear" — the cavebot keeps the
  # route; a real enemy is still fought by Combat (always running) and the next fresh fact
  # corrects the count.
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

  # Walking HOLDS the direction — both axes at once when the waypoint is diagonal — and keeps
  # holding while the intent is unchanged.
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

  # "Cooldown Ressurect" (Lucas, 2026-08-10): reviving resets every skill cooldown, so the next
  # fight starts with a full bar instead of a wait — and it still does in this client (confirmed
  # 2026-08-24).
  def translate(state, :cooldown_revive) do
    state = release_walk(state)
    fire_revive(state.body, revive_combo())
    state
  end

  # The corner asked for a reset and the moment answered no. Said out loud with
  # the reading that decided it: a stop that silently did not happen is
  # indistinguishable from a broken one, and this one is a NEW refusal — he has
  # to be able to disagree with it.
  def translate(state, {:skip_reset, note}) do
    log(:macro, "⚡ pulei o reset#{if note, do: ": " <> note, else: ""}")
    state
  end

  # Starting combat CAN fail preflight (no calibration, e.g.). On failure we
  # cannot keep walking blind into enemies nobody will kill — the Logic would
  # believe combat is up. Better to block via the same brake, immediately, with
  # a clear reason, than degrade via fight_stalled seconds later.
  def translate(state, :run_combat) do
    case safe_combat_run(state) do
      :ok ->
        log(:debug, "combate ligado")
        state

      # NOT a block, and deliberately not the dangerous one.
      :timeout ->
        log(:macro, "⏳ o combate está demorando pra arrancar — tento de novo")
        state

      {:error, messages} ->
        # The reason travels along.
        Logger.warning("Cavebot: combate recusou o arranque (#{inspect(messages)})")
        translate(state, {:block, {:combat_preflight_failed, messages}})
    end
  end

  def translate(state, :halt_combat) do
    BotSupervisor.safe_halt(state.combat)
    release_walk(state)
  end

  # DANGEROUS BLOCK vs LOCAL BLOCK — the split exists because treating both as emergencies is
  # what erased the whole hunt in silence: a wall (:stuck) took the
  def translate(state, {:block, reason}) do
    if dangerous?(reason),
      do: dangerous_block(state, reason),
      else: local_block(state, reason)
  end

  # The reason may come ALONE (`:floor_changed`) or with what needs fixing
  # (`{:combat_preflight_failed, messages}`). The name decides the severity, not the shape;
  # before this a new shape fell silently into the local block, with no latch and without
  # stopping the fleet.
  #
  # The mode travels with the start. The route chooses, and combat keeps the choice for the
  # length of the fight, so the hand and the brain (which reads the same mode from the `:hunt`
  # fact) cannot disagree mid-tick.
  defp safe_combat_run(state) do
    Combat.Worker.run(state.combat, state.combat_run_timeout_ms, hunt_mode(state))
  catch
    :exit, _reason -> :timeout
  end

  defp hunt_mode(%{logic: %Logic{route: %Route{mode: mode}}}), do: HuntMode.in_force(mode)
  defp hunt_mode(_no_route), do: HuntMode.in_force()

  defp dangerous?({name, _detail}), do: name in @dangerous_blocks
  defp dangerous?(name), do: name in @dangerous_blocks

  defp dangerous_block(state, reason) do
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
  defp local_block(state, reason) do
    state = release_walk(state)
    Logger.warning("Cavebot: parei (#{inspect(reason)}) — o resto da frota segue")
    BotSupervisor.safe_halt(state.combat)

    state
    |> stop_hunt(reason)
    |> schedule_comeback()
  end

  # The night is the product, and a one-tile obstacle used to end it: the hunt stopped and
  # waited for a human until morning.
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
          hold_note: "#{state.hold_note} — #{note}"
      }

      broadcast_status(state)
      state
    else
      state
    end
  end

  # Re-entering, not resuming: a brand-new Logic homes in at the nearest corner on the current
  # floor, which is the whole point — wherever the character ended up,
  defp resume_hunt(state, route) do
    log(:macro, "🔁 retomando a caçada: reentro pela rota \"#{route.name}\"")
    counters = bump(state.counters, :comebacks)

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
    state = %{release_walk(state) | counters: bump(state.counters, :blocks)} |> free_fire()
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

  defp block_text(:revive_dead),
    do:
      "BLOQUEADO: o revive não devolve o pokémon há minutos — estoque no fim? " <>
        "Repõe os revives e solta a caçada de novo"

  defp block_text(:brain_gone),
    do:
      "BLOQUEADO: o cérebro parou de decidir — sem ele não há revive nem freio na mobada. " <>
        "Pare e inicie a caçada de novo (e me mande o log do servidor)"

  defp block_text({:combat_preflight_failed, messages}) when is_list(messages) and messages != [],
    do: "BLOQUEADO: o combate recusou o arranque — " <> Enum.join(messages, " · ")

  defp block_text({:combat_preflight_failed, _none}), do: block_text(:combat_preflight_failed)
  defp block_text(:combat_preflight_failed), do: "BLOQUEADO: o combate recusou o arranque"
  defp block_text(:stuck), do: "parei: travado, sem sair do lugar"

  defp block_text(:pinned),
    do:
      "parei: o personagem está PRESO no lugar — pulei uma esquina e continuei sem andar, " <>
        "mesmo tentando os lados. Parede, cerca ou coisa em cima?"

  defp block_text(:stairs),
    do: "parei: não achei a escada — corrija o ponto da rota (o andar não mudou)"

  defp block_text(:fight_stalled), do: "parei: a luta não termina"
  defp block_text(reason), do: "parei: #{inspect(reason)}"

  # A step failure (e.g.
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

  # The categories in their canonical order, deduplicated by KEY: two categories can land on the
  # same key, and pressing it twice is not what he asked for.
  defp skill_keys(loadout, categories) do
    categories
    |> Enum.reject(&(&1 == :single and not Settings.get(:combat_single_target)))
    |> Enum.flat_map(&Combat.Loadout.keys(loadout, &1))
    |> Enum.uniq()
  end

  defp skills_text(categories),
    do: Enum.map_join(categories, ", ", &"#{SkillProfile.icon(&1)} #{SkillProfile.label(&1)}")

  defp park_click(state, point) do
    times = Settings.get(:cavebot_park_clicks)
    gap = Settings.get(:cavebot_park_gap_ms)

    # One press is not enough: the game sometimes ignores the click, so it is sent a few
    # times (about 4) to be sure.
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

  # One key, and no calibration to be missing: the choreography this borrowed
  # used to need the portrait marked, and a hunt could reach the corner only to
  # log that it could not revive.
  defp revive_combo,
    do: PlayerSupport.Logic.revive(%{rescue_key: Settings.get(:rescue_key)})

  defp note_capture(state, pending) do
    if pending == state.capture_pending,
      do: state,
      else: %{state | capture_pending: pending, capture_changed_at: now()}
  end

  # Close in, precision beats speed: a held arrow keeps walking between readings and always
  # overshoots the last tile, which is fine on a wide corner and fatal on a
  defp precise?(dx, dy) do
    range = Settings.get(:cavebot_precise_tiles)
    range > 0 and abs(dx) <= range and abs(dy) <= range
  end

  defp hold_walk(state, dx, dy) do
    # An axis already inside the arrival tolerance is NOT held: with a key held down the
    # character keeps walking between readings, so correcting a one-tile error
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

  # Two shapes, on purpose: the scalar knobs come straight from Settings, and the hunt's DEFAULT
  # park spot is a pair — where the pokémon goes at a kill spot he never marked one for.
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
    started_at: nil,
    ended_at: nil,
    counters: @zero_counters
  }

  @doc """
  The COMPLETE snapshot shape with everything zeroed — the placeholder the
  `BotSupervisor` uses when the worker doesn't answer in time.
  """
  @spec idle_snapshot() :: snapshot
  def idle_snapshot, do: @idle_snapshot

  defp snapshot(%{logic: nil} = state),
    do: %{
      @idle_snapshot
      | counters: state.counters,
        started_at: state.started_at,
        ended_at: state.ended_at
    }

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
      started_at: state.started_at,
      ended_at: state.ended_at,
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

  # "Why isn't he walking", in the other workers' mold (fishing, player_support): the out-of-
  # tick reason first (lost feed, block) as the most serious; the refused
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

      %{hp_pct: nil} ->
        {:hp, "esperando o pokémon voltar da poké bola"}

      %{hp_pct: hp} ->
        {:hp,
         "o pokémon está no chão (vida lida em #{hp}%) — a rota espera o revive levantar ele"}
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

  # ENTERING the route is not walking it.
  defp note_arrival(%{logic: %Logic{advance: :homed} = logic} = state, _before, now) do
    text = "🏁 entrei na rota pelo canto #{logic.wp_index + 1}/#{wp_total(state)}"
    log(:macro, text)
    %{state | last_action: %{text: text, at: now}}
  end

  # Reaching a corner is the proof the hunt is HEALTHY, so it hands every comeback back: a ten-
  # hour night with three unrelated hiccups must not run out of budget over hiccups that were
  # hours apart.
  defp note_arrival(state, wp_before, now) do
    # WHY it moved on, and from WHERE.
    text =
      "waypoint #{wp_before + 1}/#{wp_total(state)}#{advance_mark(state.logic)}#{where(state.pos)}"

    log(:macro, text)

    state = %{
      state
      | counters: bump(state.counters, :waypoints),
        last_action: %{text: text, at: now}
    }

    if state.logic.advance == :arrived, do: %{state | block_retries: 0}, else: state
  end

  defp advance_mark(%Logic{advance: :skipped}), do: " ⏭ pulei (não cheguei)"
  defp advance_mark(_arrived_or_unknown), do: ""

  defp where({x, y, z}), do: " · #{x},#{y} andar #{z}"
  defp where(_blind), do: " · sem coordenada"

  # The staircase that WORKED.
  defp note_stair_taken(%{logic: %Logic{wp_index: same}} = state, same, _before, _taps, _now),
    do: state

  defp note_stair_taken(state, _wp_before, :walking, taps, now) when taps > 0 do
    log(:macro, "🪜 escada tomada no toque: uma tecla, dois tiles, sem procurar")
    %{state | last_action: %{text: "escada no toque", at: now}}
  end

  defp note_stair_taken(state, _wp_before, _before, _taps, _now), do: state

  # Looking for the step, and finding it.
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
  defp note_recovery(%{logic: %Logic{recovering?: true}} = state, false, now) do
    log(:macro, "🩸 o pokémon caiu — segurei a rota até o revive levantar ele")

    %{
      state
      | last_action: %{text: "pokémon no chão — segurei a rota", at: now},
        counters: bump(state.counters, :aborts)
    }
  end

  defp note_recovery(%{logic: %Logic{recovering?: false, last_hp: hp}} = state, true, now)
       when is_integer(hp) do
    log(:macro, "💚 pokémon de pé (#{hp}%) — a caçada segue")
    %{state | last_action: %{text: "de pé — rota retomada", at: now}}
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
  One line per walking decision, carrying everything a hunt cannot be read back from afterwards:
  where he WAS, how far the target was when the decision was taken, how old the reading it was
  taken on was, and what actually went out.

  The four together answer the three questions this instrument exists for: real speed in tiles/s
  (absolute positions, differenced by nobody), tiles covered per decision (`{:walk, 4, -3}`
  reads identically whether the Worker then held two keys, held one, tapped one or pressed
  nothing, so what went out is the half that differs), and whether decisions are taken on stale
  readings.

  `cavebot_measure_walk` (off by default) is the whole switch, and off means SILENCE: the hunt
  decides ~5x a second, `/cavebot` keeps 8 log lines and does not filter by level, so a line per
  decision turned that box into a rolling 1.6-second window and the waypoint counter, the
  staircase search and the BLOCKED lines scrolled away before he could read them. Measuring is
  opt-in; off costs exactly zero lines.

  On, the line is `:macro`, because `:debug` is exactly what `Journal.persist_event/2` refuses
  to write: measured at `:debug` a hunt leaves nothing on disk and can only be read off the
  panel's last ~200 lines. `:macro` is the lowest level the journal keeps, so a whole hunt lands
  in `~/.pokex/journal/*.jsonl`. It does bury the narrative while it is on, which is what
  measuring means, and why nobody hunts with it on.

  Public because it is instrumentation: the point is to be callable from a test without standing
  up a whole hunt. He has said the movement is still bad, and neither the overshoot nor the
  wall-pushing has ever been measured, only watched.
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

  # Halting keeps only the COUNTERS: "the hunt did 12 waypoints and 340 steps" is the summary
  # that matters after halt.
  defp end_session(state) do
    log(:macro, "📋 a caçada deu: " <> tally(state.counters))

    %{
      reset_session(state)
      | counters: state.counters,
        started_at: state.started_at,
        ended_at: wall_now()
    }
  end

  # The clock starts at `run` and only at `run`: re-entry inherits the night.
  defp start_clock(state), do: %{state | started_at: wall_now(), ended_at: nil}

  defp wall_now, do: System.system_time(:millisecond)

  defp tally(counters) do
    [
      {:waypoints, "waypoint(s)"},
      {:steps, "passo(s)"},
      {:aborts, "mobada(s) abandonada(s) por vida"},
      {:comebacks, "volta(s) depois de tropeço"},
      {:blocks, "parada(s) com motivo"}
    ]
    |> Enum.map_join(", ", fn {key, label} -> "#{Map.get(counters, key, 0)} #{label}" end)
  end

  # A new hunt inherits nothing: counters, last action, reasons and the known
  # position all belong to their own session.
  defp reset_session(state) do
    %{
      state
      | last_step: nil,
        pos: nil,
        pos_at: nil,
        pos_age: nil,
        counters: @zero_counters,
        last_action: nil,
        hold_note: nil,
        logged_holds: []
    }
  end

  defp broadcast_status(state), do: broadcast({:cavebot, snapshot(state)})

  defp broadcast(message), do: Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, message)

  defp now, do: System.monotonic_time(:millisecond)
end
