defmodule Pokex.Bots.Cavebot.Worker do
  @moduledoc """
  Driver for the pure `Cavebot.Logic`, constant-hunt style: a short tick reads
  the world (position from the `:minimap` fact, enemy count from `:battle`, the
  last combat state heard on the "combat" topic), calls `Logic.step/3` and
  translates ONE action at a time.

  A PEER of the other workers, never a change to them:

    * actuation ONLY through the Body — `Body.minimap_step/3` is the only way
      to walk (the minimap click; the client routes around obstacles itself).
      The Rig is never touched from here.
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
  alias Pokex.Bots.Capture
  alias Pokex.Bots.Cavebot.{Logic, Route, Store}
  alias Pokex.Bots.Combat
  alias Pokex.Bots.InputGate
  alias Pokex.Perception
  alias Pokex.Perception.{Feed, WorldState}
  alias Pokex.Settings
  alias Pokex.Vision.Frame

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
    walk_timeout_ms: :cavebot_walk_timeout_ms,
    stuck_max_retries: :cavebot_stuck_max_retries,
    clear_debounce_ms: :cavebot_clear_debounce_ms,
    fight_timeout_ms: :cavebot_fight_timeout_ms,
    post_kill_dwell_ms: :cavebot_post_kill_dwell_ms
  }

  def topic, do: @topic

  def start_link(opts \\ []) do
    state = %{
      body: Keyword.get(opts, :body, Pokex.Bots.Body),
      combat: Keyword.get(opts, :combat, Combat.Worker),
      active?: Keyword.get(opts, :active, Application.get_env(:pokex, :cavebot_active, true)),
      logic: nil,
      timer: nil,
      attached?: false,
      feed_ref: nil,
      reattach_attempts: 0,
      combat_state: :idle,
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
          last_action: %{text: String.t(), at: integer} | nil,
          counters: %{waypoints: non_neg_integer, steps: non_neg_integer}
        }

  @spec status(GenServer.server()) :: snapshot
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(state) do
    Phoenix.PubSub.subscribe(Pokex.PubSub, Combat.Worker.topic())
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

    if not InputGate.allowed?() do
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
    else
      run_cavebot_tick(state, now)
    end
  end

  def handle_info({:combat, %{state: combat_state}}, state),
    do: {:noreply, %{state | combat_state: combat_state}}

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

    if broadcast_key(state, now) != before, do: broadcast_status(state)
    {:noreply, schedule_tick(state)}
  end

  # The combat snapshot, kept the Combos.Runner way: the Logic receives the
  # last heard state as world.combat_state.
  defp observe(state, now) do
    pos = position(now)
    world = %{pos: pos, enemies: enemy_count(now), combat_state: state.combat_state}

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
  def translate(state, :none), do: %{state | last_step: nil}

  def translate(state, {:walk, dx, dy}), do: minimap_step(state, dx, dy)
  def translate(state, {:nudge, dx, dy}), do: minimap_step(state, dx, dy)

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
    state
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
  defp minimap_step(state, dx, dy) do
    at = now()
    raw = state.body.minimap_step(dx, dy, [])
    result = step_result(raw)
    text = "passo #{dx},#{dy}"
    stepped = %{state | last_step: %{dx: dx, dy: dy, result: result, at: at}}

    if result == :ok do
      with {:ok, point} <- raw, do: warn_if_unexplored(point)

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

  # Chosen behavior for BLACK minimap areas (undiscovered map): click anyway
  # and only WARN (2026-07-30). The probe is a 3x3 crop at the clicked point,
  # AFTER the click — it never delays or blocks a step; the journal's dedup
  # holds the spam if the route insists on the edge. Any capture failure is
  # silence: the warning is bonus, the step is the service.
  defp warn_if_unexplored({x, y}) do
    case Capture.frame_uncached({x - 1, y - 1, 3, 3}, "cavebot_step_probe.png") do
      {:ok, frame} ->
        if dark_frame?(frame),
          do: log(:macro, "🕳️ passo caiu em área não descoberta do minimapa")

      _falhou ->
        :ok
    end
  end

  defp warn_if_unexplored(_no_point), do: :ok

  defp dark_frame?(frame) do
    coords = for i <- 0..(frame.width - 1), j <- 0..(frame.height - 1), do: {i, j}

    Enum.all?(coords, fn {i, j} ->
      {r, g, b} = Frame.at(frame, i, j)
      max(r, max(g, b)) < 12
    end)
  end

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
