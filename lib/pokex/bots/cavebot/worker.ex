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
    * Combat.Worker is driven exclusively via `run/1` and `halt/1` — the Logic
      starts it and it fights on its own; the cavebot only yields while
      enemies are on screen.

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

  The injected `body` is a MODULE (production: `Pokex.Bots.Body`; tests: a fake
  with the same signature), because `minimap_step/3` is a module function — the
  click geometry lives in the Body, not here. `combat` is a server (production:
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
    gather_wait_ms: :cavebot_gather_wait_ms
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
      capture_pending: 0,
      capture_changed_at: nil,
      # the BLIND sweep's queue, same progress rule as the capture's
      sweep_pending: 0,
      sweep_changed_at: nil,
      last_step: nil,
      pos: nil,
      pos_at: nil,
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

        # The per-dungeon combo gate reads this fact (Combos.Runner). Published
        # even with nil dungeon — the Runner treats nil as "global combos only".
        WorldState.put(:dungeon, %{id: route.dungeon}, now())

        state =
          %{cancel_timer(state) | logic: Logic.new(route, config())}
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
    Combat.Worker.halt(state.combat)
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

    {logic, action} = Logic.step(state.logic, world, now)

    state =
      %{state | logic: logic}
      |> translate(action)
      |> note_arrival(wp_before, now)
      |> log_hold_edge(now)
      |> publish_posture(now)

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
    # Holding fire outlives the walking: after arriving at "até aqui" the pile
    # is still closing in, and hitting the first straggler wastes the whole
    # gathering (Logic.gathering?/2).
    holding? = Logic.luring?(state.logic) or Logic.gathering?(state.logic, now)
    posture = if holding?, do: :hold_fire, else: :free_fight
    WorldState.put(:posture, %{posture: posture}, now)

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

    world = %{
      pos: pos,
      enemies: fightable(state, now),
      combat_state: state.combat_state,
      capture_pending: state.capture_pending,
      capture_changed_at: state.capture_changed_at,
      sweep_pending: state.sweep_pending,
      sweep_changed_at: state.sweep_changed_at
    }

    if pos, do: {world, %{state | pos: pos, pos_at: now}}, else: {world, state}
  end

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
  def translate(state, {:walk, dx, dy}), do: hold_walk(state, dx, dy)

  # A nudge is ONE tile on purpose (the blind kick, the stall breaker): it taps,
  # and lets go of whatever was held first — a kick under a held key is not a
  # kick, it is the same walk continuing.
  def translate(state, {:nudge, dx, dy}) do
    state |> release_walk() |> arrow_step(dx, dy)
  end

  # "varrer aqui": the pile the hunt gathered died on this tile, and its
  # corpses are worth a ball each. A cast, never a call — the Catcher parks on
  # multi-second captures and this worker ticks five times a second.
  def translate(state, {:sweep, around}) do
    Catcher.Worker.sweep_now(state.catcher, around)
    log(:macro, sweep_text(around))
    release_walk(state)
  end

  # The middle click he makes himself when he finishes gathering: it parks the
  # active pokémon on a chosen tile so the pile closes in AROUND IT. Recorded
  # from his own hand (Cavebot.Recording.mark_park/4), replayed here.
  def translate(state, {:park, point}) do
    state = release_walk(state)
    state.body.perform([{:click, :middle, point}], :high)
    log(:macro, "🖱️ pokémon posicionado em #{elem(point, 0)}, #{elem(point, 1)}")
    state
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
    Combat.Worker.halt(state.combat)
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
    Combat.Worker.halt(state.combat)
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
    Combat.Worker.halt(state.combat)
    stop_hunt(state, reason)
  end

  # What both levels share: alarm, reason written on screen, tick cancelled,
  # feeds released (capturing for nobody only loads the broker). The Logic is
  # forced to :blocked because the block can come from it (floor change) OR the
  # Worker (combat refused to start) — either way the reported state must be
  # :blocked, terminal until a human restarts.
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

  defp hold_walk(state, dx, dy) do
    # An axis already inside the arrival tolerance is NOT held: with a key held
    # down the character keeps walking between readings, so correcting a
    # one-tile error overshoots it the other way — the zig-zag Lucas saw
    # (left+down → down → right+down → down, around the same corner).
    tol = Settings.get(:cavebot_arrival_tolerance_tiles)
    keys = Enum.reject([horizontal(dx, tol), vertical(dy, tol)], &is_nil/1)
    at = now()
    text = "segurando #{Enum.join(keys, "+")}"
    result = step_result(state.body.hold(keys))
    stepped = %{state | last_step: %{dx: dx, dy: dy, result: result, at: at}}

    if result == :ok do
      if action_text(state) != text,
        do: log(:debug, "#{text} → wp #{stepped.logic.wp_index + 1}/#{wp_total(stepped)}")

      %{
        stepped
        | held_keys: keys,
          counters: bump(stepped.counters, :steps),
          last_action: %{text: text, at: at}
      }
    else
      Logger.debug("Cavebot: segurar (#{dx},#{dy}) falhou: #{inspect(result)}")
      %{stepped | held_keys: []}
    end
  end

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

      %{stepped | counters: bump(stepped.counters, :steps), last_action: %{text: text, at: at}}
    else
      Logger.debug("Cavebot: passo (#{dx},#{dy}) falhou: #{inspect(result)}")
      stepped
    end
  end

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

  defp config do
    Map.new(@config_keys, fn {key, setting} -> {key, Settings.get(setting)} end)
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
      [note_hold(state.hold_note), step_hold(state.last_step), blind_hold(state.logic, now)],
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

  defp note_arrival(state, wp_before, now) do
    text = "waypoint #{wp_before + 1}/#{wp_total(state)}"
    log(:macro, text)
    %{state | counters: bump(state.counters, :waypoints), last_action: %{text: text, at: now}}
  end

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
