defmodule Pokex.Bots.Catcher.Worker do
  @moduledoc """
  Driver for the pure Catcher.Logic: consumes `:corpses` observations from the perception
  blackboard, throws confirmed Pokéballs through the Body (`:high`), and follows the player
  mode LIVE — `parado` attaches the feed and acts; `movimento` detaches and idles (Lucas
  captures manually while moving). Combat's kill broadcast is only an accelerator: it forces
  an immediate world re-read; detection never depends on it. A confirmed kill also triggers a
  Space loot (gated by `loot_enabled`) before any ball of that cycle — the corpse consumed by
  a ball takes its loot with it. `capture_enabled` independently gates the entire ball
  pipeline (and the feed attach) so loot-only operation never throws.

  Combat-engagement gate: PXG combat is tile-locked — a FIGHTING sprite stands still,
  indistinguishable from a corpse to the stationary-blob detector — so this worker also
  tracks Combat.Worker's "combat" snapshots. While combat is :tabbing/:fighting, observations
  are held (no admissions/throws/confirms: they would be contaminated by the live enemy) and
  the feed is never (re)attached (a mid-fight attach would warm the baseline up on the enemy
  sprite and mask the melee tile forever). The disengage edge (kill landed or the fight ended)
  immediately re-checks the world so capture stays prompt, and lets a parado+armed+detached
  worker re-attach right away — the ground is back to normal.
  """
  use GenServer
  require Logger

  alias Pokex.Bots.Body
  alias Pokex.Bots.Catcher.Ball
  alias Pokex.Bots.Catcher.CorpseLibrary
  alias Pokex.Bots.Catcher.Logic
  alias Pokex.Bots.Catcher.SpotScan
  alias Pokex.Bots.Catcher.Sweep
  alias Pokex.Bots.Combat.Worker
  alias Pokex.Bots.InputGate
  alias Pokex.Calibration
  alias Pokex.Perception
  alias Pokex.Perception.Feed
  alias Pokex.Pokedex.ShinyLog
  alias Pokex.Settings

  @topic "catcher"
  @kill_topic "combat:kill"

  # After a kill whose scan found nothing, re-look at these delays. Not a knob:
  # corpse physics — it lasts minutes on the ground, and the FIRST post-kill
  # frame is usually dirty (death animation, the loot, the own pokémon walking
  # over it). Three chances in 2s suffice; more is capture burned for nothing.
  @repiques [400, 1_000, 2_000]

  @config_keys [
    :corpse_match_tolerance_px,
    :corpse_max_balls,
    :corpse_ignore_ttl_ms,
    :corpse_confirm_after_ms,
    :dry_balls_alarm,
    :feed_corpses_ms
  ]

  def topic, do: @topic
  def kill_topic, do: @kill_topic

  def start_link(opts \\ []) do
    init_arg = %{
      body: Keyword.get(opts, :body, Body),
      # kill-anchored vision; injectable in tests like the Body
      scanner: Keyword.get(opts, :scanner, &SpotScan.scan/0)
    }

    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, init_arg)
      name -> GenServer.start_link(__MODULE__, init_arg, name: name)
    end
  end

  def run(server \\ __MODULE__), do: GenServer.call(server, :run)
  def halt(server \\ __MODULE__), do: GenServer.call(server, :halt)
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "The panel pokes this after flipping player_mode / the loot & capture toggles — attach/detach applies live."
  def mode_changed(server \\ __MODULE__), do: GenServer.call(server, :mode_changed)

  @doc "Force a fresh ground warmup (detach + attach): use after moving to a new spot."
  def relearn(server \\ __MODULE__), do: GenServer.call(server, :relearn)

  @doc """
  Sweeps NOW, ignoring `sweep_enabled` — the settings screen's test button.

  `{:ok, tiles}` once the balls are queued, or `{:error, reason}` (a sentence
  for the screen) when a gate is holding it or the calibration cannot say where
  the character is.
  """
  def sweep_now(server \\ __MODULE__), do: GenServer.call(server, :sweep_now)

  @impl true
  def init(%{body: body, scanner: scanner}) do
    Phoenix.PubSub.subscribe(Pokex.PubSub, @kill_topic)
    Phoenix.PubSub.subscribe(Pokex.PubSub, Perception.topic())
    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    # a SHINY sighting overrides capture_enabled for the next ball
    Phoenix.PubSub.subscribe(Pokex.PubSub, "shiny")

    {:ok,
     %{
       logic: nil,
       body: body,
       scanner: scanner,
       timer: nil,
       attached?: false,
       combat_engaged?: false,
       feed_ref: nil,
       reattach_attempts: 0,
       loots: 0,
       # has the closed gate been announced this round? (edge-triggered log)
       held?: false,
       # rescans scheduled after a kill that found nothing: the corpse stays on
       # the ground for MINUTES, and the first frame is usually dirty (death
       # animation, loot, the own pokémon on top)
       repiques: [],
       # Combat.Worker monitor: if it dies, combat_engaged? must not stay stuck
       # true — that would be a mute catcher until the next broadcast
       combat_ref: nil,
       # how many of each corpse were FOUND this session, plus the set seen in
       # the previous scan (consecutive dedup)
       count: %{},
       vistos: MapSet.new(),
       # session scoreboard (reset on each start): scans done, scans with a
       # target, and blind scans
       scans: 0,
       with_target: 0,
       blind: 0,
       # a shiny was just seen: the NEXT ball ignores capture_enabled
       shiny_pending?: false,
       # BLIND sweep (see Catcher.Sweep): its own cadence timer, the tiles still
       # owed by the sweep in progress, and the session counters. Deliberately a
       # separate timer from `timer` (the Logic's deadline wake) — they mean
       # different things and one must never cancel the other.
       sweep_timer: nil,
       sweep_queue: [],
       sweeps: 0,
       sweep_balls: 0,
       # last performed actuation as %{text, at} (monotonic ms; nil until the first) — panel-facing
       last_action: nil
     }}
  end

  @impl true
  def handle_call(:run, _from, state) do
    {logic, _} = Logic.start(Logic.new(config()), now())

    state = %{
      state
      | logic: logic,
        loots: 0,
        scans: 0,
        with_target: 0,
        blind: 0,
        count: %{},
        vistos: MapSet.new(),
        sweeps: 0,
        sweep_balls: 0,
        combat_engaged?: seed_combat_engaged()
    }

    state = state |> monitorar_combate() |> sync_mode() |> arm_sweep()
    announce_library()
    broadcast(state)
    {:reply, :ok, state}
  end

  def handle_call(:halt, _from, %{logic: nil} = state), do: {:reply, :ok, disarm_sweep(state)}

  def handle_call(:halt, _from, state) do
    {logic, _} = Logic.stop(state.logic)
    state = state |> Map.put(:logic, logic) |> detach() |> disarm_sweep()
    broadcast(state)
    {:reply, :ok, cancel_timer(%{state | reattach_attempts: 0})}
  end

  def handle_call(:status, _from, state), do: {:reply, snapshot(state), state}

  def handle_call(:mode_changed, _from, %{logic: nil} = state), do: {:reply, :ok, state}

  def handle_call(:mode_changed, _from, state) do
    state = %{state | combat_engaged?: seed_combat_engaged()}
    # the sweep re-arms HERE too: flipping its switch (or its cadence) in the
    # settings screen has to apply to a bot already running, not at the next start
    state = state |> sync_mode() |> arm_sweep()
    broadcast(state)
    {:reply, :ok, state}
  end

  def handle_call(:relearn, _from, state) do
    state = state |> reset_logic() |> detach() |> sync_mode()
    {:reply, :ok, state}
  end

  # The test button: sweeps even with the switch off (that is what makes it a
  # test), but never past a gate — the reasons a sweep is held are the reasons
  # it would be wrong or invisible, not paperwork.
  def handle_call(:sweep_now, _from, state) do
    case sweep_hold_reason(state) do
      nil ->
        case begin_sweep(state) do
          {:ok, state} -> {:reply, {:ok, length(state.sweep_queue)}, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      reason ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:world, :corpses, obs}, %{logic: %Logic{state: :armed}} = state),
    do: {:noreply, advance(state, obs)}

  def handle_info({:world, _key, _obs}, state), do: {:noreply, state}

  def handle_info(:wake, %{logic: %Logic{state: :armed}} = state),
    do: {:noreply, advance(state, scan_obs(state))}

  def handle_info(:wake, state), do: {:noreply, state}

  # kill = accelerator (both shapes: Task 5 drops the payload; tolerate the old one meanwhile).
  # loot_kill runs BEFORE advance: the Space presses must land ahead of any ball this cycle.
  # Vision is ANCHORED HERE: the kill says a corpse just fell on an adjacent
  # tile — SpotScan asks the library which one (see Catcher.SpotScan).
  def handle_info({:kill}, %{logic: %Logic{state: :armed}} = state) do
    state = loot_kill(%{state | repiques: @repiques})
    {:noreply, advance(state, scan_obs(state))}
  end

  def handle_info({:kill, _corpse}, %{logic: %Logic{state: :armed}} = state) do
    state = loot_kill(%{state | repiques: @repiques})
    {:noreply, advance(state, scan_obs(state))}
  end

  # Combat-engagement gate: track the live fight so a stationary enemy sprite never gets
  # balled/ignore-poisoned like a corpse. On the engaged→disengaged edge (kill landed or the
  # fight ended) the corpse track is already mature — re-check the world immediately instead
  # of waiting for the next event/poll, and let a idle+armed+detached worker re-attach now
  # (the ground is back to normal, so a fresh warmup here is safe).
  def handle_info({:combat, %{state: combat_state}}, state) do
    engaged? = combat_state in [:tabbing, :fighting]
    disengaged? = state.combat_engaged? and not engaged?
    edge? = engaged? != state.combat_engaged?
    state = %{state | combat_engaged?: engaged?}

    # The engage/disengage EDGE broadcasts so the panel's "esperando fim da luta"
    # reason appears and clears in real time, not only on the next corpse event.
    if edge? and state.logic != nil, do: broadcast(state)

    # combat_engaged? tracks regardless of our own state (so a :run mid-fight starts correctly
    # gated); the disengage ACTION (attach + advance) only applies once there is a real armed
    # logic to drive — nil/halted must never reach Logic.step/3.
    state =
      if disengaged? and match?(%Logic{state: :armed}, state.logic) do
        # the kill may have arrived with the fight still "engaged" in our mirror
        # (broadcast ordering) — the disengage edge rescans immediately
        advance(state, scan_obs(state))
      else
        state
      end

    {:noreply, state}
  end

  # The :corpses feed died (its consumers map — and this worker's registration — dies with
  # it; a restarted feed starts with nobody attached). Manual/halted: nothing to blind, do not
  # schedule a reattach. Otherwise a silently-detached catcher would stop capturing forever the
  # moment the feed restarts — retry-attach on a short timer instead (mirrors Combat.Worker's
  # battle-feed monitor).
  def handle_info({:DOWN, ref, :process, _obj, _reason}, %{feed_ref: ref} = state) do
    state = %{state | attached?: false, feed_ref: nil}
    state = if armed_idle?(state), do: schedule_reattach(state), else: state
    {:noreply, state}
  end

  # Combat.Worker died: FAIL-OPEN on the engagement mirror. A crash between
  # engage and disengage would leave combat_engaged? stuck true — a mute catcher
  # until a broadcast that may never come. The supervisor recreates combat,
  # which re-broadcasts; until then, better to risk one contaminated scan (the
  # library filters) than none.
  def handle_info({:DOWN, ref, :process, _obj, _reason}, %{combat_ref: ref} = state) do
    {:noreply, monitorar_combate(%{state | combat_engaged?: false})}
  end

  def handle_info({:DOWN, _ref, :process, _obj, _reason}, state), do: {:noreply, state}

  def handle_info(:reattach_corpses, state) do
    cond do
      not armed_idle?(state) or state.attached? ->
        {:noreply, state}

      state.combat_engaged? ->
        # a fight is in progress — attaching now would warm up on the live sprite; retry later
        {:noreply, schedule_reattach(state)}

      true ->
        {:noreply, reattach_corpses(state)}
    end
  end

  # A shiny is on screen: arm the override so the ball flies even with capture
  # off, and make sure the corpse feed is attached to see its body.
  def handle_info({:shiny_seen, _info}, state) do
    state = %{state | shiny_pending?: true}
    {:noreply, if(should_be_attached?(state), do: attach(state), else: state)}
  end

  # A tick that outran its own cancellation (halt races the timer message that
  # was already in the mailbox). The bot is stopped: nothing may fly. The manual
  # sweep_now is the deliberate exception — it is a human pressing a button.
  def handle_info(:sweep, %{logic: nil} = state), do: {:noreply, %{state | sweep_timer: nil}}

  # The sweep's cadence. Re-arming happens whether or not this pass ran: a held
  # sweep must try again next cycle, not go quiet until the next Iniciar.
  def handle_info(:sweep, state) do
    state = if Settings.get(:sweep_enabled), do: run_sweep(state), else: state
    {:noreply, arm_sweep(%{state | sweep_timer: nil})}
  end

  # ONE tile per message, deliberately. A sweep is up to 80 throws — ~15s of
  # Body time — and doing it as one long sequence would park this process for
  # all of it: the kill that arrives mid-sweep, the panel's halt, the
  # combat-engagement edge would all wait behind it. Re-sending to self() puts
  # the next tile at the END of the mailbox, so everything already queued is
  # served first, and the gates are re-read at every tile.
  def handle_info(:sweep_tile, %{sweep_queue: []} = state), do: {:noreply, state}

  def handle_info(:sweep_tile, %{sweep_queue: [point | rest]} = state) do
    case sweep_hold_reason(state) do
      nil ->
        # :normal, NOT :high — the sweep is a background guarantee and must
        # never get ahead of the rod or the aimed ball behind a real corpse.
        Body.perform(Ball.sequence(point), :normal, state.body)
        state = %{state | sweep_queue: rest, sweep_balls: state.sweep_balls + 1}
        if rest == [], do: send(self(), :sweep_done), else: send(self(), :sweep_tile)
        {:noreply, state}

      reason ->
        log(
          :macro,
          "🧹 varredura interrompida com #{length(state.sweep_queue)} tile(s) — #{reason}"
        )

        {:noreply, broadcast_and_return(%{state | sweep_queue: []})}
    end
  end

  def handle_info(:sweep_done, state) do
    log(:macro, "🧹 varredura concluída — #{state.sweep_balls} bola(s) nesta sessão")
    {:noreply, broadcast_and_return(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Varredura cega ---------------------------------------------------------
  # The safety net UNDER the aimed capture (see Catcher.Sweep for the geometry
  # and the why). It lives in THIS process, rather than a worker of its own,
  # because every gate it needs is already computed here — the
  # combat-engagement mirror, the mini-game fact, the player mode and the input
  # gate — and a second process would have to rebuild all four to reach the
  # same answer, then disagree with this one the first time they drifted.

  defp run_sweep(state) do
    case sweep_hold_reason(state) do
      nil ->
        case begin_sweep(state) do
          {:ok, state} ->
            state

          {:error, reason} ->
            # a LOG, never an alarm: this repeats every cadence, and a siren
            # every 30s is a siren nobody hears
            log(:macro, "🧹 varredura não saiu — #{reason}")
            state
        end

      reason ->
        log(:debug, "🧹 varredura adiada — #{reason}")
        state
    end
  end

  defp begin_sweep(state) do
    case sweep_points() do
      {:ok, []} ->
        {:error, "nenhum tile sobrou dentro da tela"}

      {:ok, points} ->
        log(:macro, "🧹 varredura cega em #{length(points)} tile(s) (#{Ball.key()} em cada um)")
        send(self(), :sweep_tile)
        {:ok, broadcast_and_return(%{state | sweep_queue: points, sweeps: state.sweeps + 1})}

      {:error, reason} ->
        {:error, reason_text(reason)}
    end
  end

  # Loaded from disk on every sweep, like the rest of the fleet: recalibrating
  # applies without a restart.
  defp sweep_points do
    case Calibration.load() do
      {:ok, calib} -> Sweep.points(calib)
      _no_calibration -> {:error, :no_calibration}
    end
  end

  defp sweep_hold_reason(state) do
    cond do
      Perception.mini_game_playing?() ->
        "mini-game em jogo"

      state.combat_engaged? ->
        "luta em andamento"

      # The whole grid hangs off the character standing where the calibration
      # says he stands. Walking, every point is stale by the time the ball flies.
      Settings.get(:player_mode) != "still" ->
        "a varredura é do modo Parado"

      not gate_aberto?() ->
        "o jogo não está em foco (ou o pânico está armado)"

      true ->
        nil
    end
  end

  defp arm_sweep(%{logic: nil} = state), do: cancel_sweep(state)

  defp arm_sweep(state) do
    state = cancel_sweep(state)

    if Settings.get(:sweep_enabled) do
      ms = max(Settings.get(:sweep_interval_ms), 1_000)
      %{state | sweep_timer: Process.send_after(self(), :sweep, ms)}
    else
      state
    end
  end

  # Halting drops the tiles still owed as well as the timer: a pending
  # :sweep_tile lands on the empty-queue clause and dies quietly.
  defp disarm_sweep(state), do: cancel_sweep(%{state | sweep_queue: []})

  defp cancel_sweep(%{sweep_timer: nil} = state), do: state

  defp cancel_sweep(%{sweep_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | sweep_timer: nil}
  end

  defp broadcast_and_return(state) do
    broadcast(state)
    state
  end

  # capture_enabled OR a pending shiny (never lose a shiny to a toggle).
  defp capture_allowed?(state),
    do:
      Settings.get(:capture_enabled) or
        (state.shiny_pending? and Settings.get(:shiny_always_ball))

  # The mode gate lives HERE, not only in attach/detach: a late in-flight {:world,...} event
  # (or a test-injected one) right after flipping to moving must never throw a ball.
  # The mini-game gate comes first: no admissions, throws or confirms while it
  # plays. The catcher is event-driven — the next corpse/kill/combat event after
  # the fact clears resumes the flow on its own.
  defp advance(state, obs) do
    state = contar(state, obs)

    state =
      cond do
        Perception.mini_game_playing?() -> state
        Settings.get(:player_mode) == "still" -> do_advance(state, obs)
        true -> state
      end

    reagendar(state, obs)
  end

  # Rescheduling lives HERE, not inside run_step: the branches that held the
  # step (engaged fight, closed gate, mini-game) returned without scheduling,
  # and a ball in flight stayed pending forever if no new event arrived.
  # Priority: (1) Logic has pending work → wake at its real deadline; (2) the
  # kill scan found nothing and rescans remain → re-look at the ground.
  defp reagendar(state, obs) do
    case state.logic && Logic.next_wake(state.logic, now()) do
      ms when is_integer(ms) ->
        agendar(%{state | repiques: []}, ms)

      _no_pending ->
        repicar(state, obs)
    end
  end

  # Only a REAL empty scan consumes a rescan — nil obs (gate/fight) or a blind
  # one doesn't spend the chance: the emptiness wasn't "the ground is clean".
  defp repicar(%{repiques: [ms | resto]} = state, %{scanning?: true, corpses: []}),
    do: agendar(%{state | repiques: resto}, ms)

  defp repicar(state, _obs_sem_repique), do: state

  defp agendar(state, ms) do
    state = cancel_timer(state)
    %{state | timer: Process.send_after(self(), :wake, max(ms, 1))}
  end

  # The whole session in three card counters. `with_target` rises when SOME library
  # corpse passed the threshold — the scans:with_target ratio is the aim
  # thermometer (measured 2026-07-30: 242 kills → 1 recognition).
  defp contar(state, %{scanning?: true} = obs) do
    achou? = Map.get(obs, :corpses, []) != []

    state
    |> Map.merge(%{
      scans: state.scans + 1,
      with_target: state.with_target + if(achou?, do: 1, else: 0)
    })
    |> count_per_corpse(obs)
  end

  defp contar(state, %{scanning?: false}), do: %{state | blind: state.blind + 1}
  defp contar(state, _no_scan), do: state

  # Per-corpse session count ("how many Kingler this session?"). CONSECUTIVE
  # dedup (same idea as the Journal): a ball's confirmation rescans the same
  # tiles, and a corpse sitting there would count again every scan — only what
  # ENTERED since the previous scan adds. Deliberately not derived from
  # `counters.captures`: that number measures "the point stopped matching",
  # not capture.
  defp count_per_corpse(state, obs) do
    vistos =
      obs
      |> Map.get(:known, %{})
      |> MapSet.new(fn {point, %{name: name}} -> {name, point} end)

    novos = MapSet.difference(vistos, state.vistos)

    count =
      Enum.reduce(novos, state.count, fn {name, _ponto}, acc ->
        Map.update(acc, name, 1, &(&1 + 1))
      end)

    if count != state.count, do: broadcast_count(count)

    %{state | vistos: vistos, count: count}
  end

  defp broadcast_count(count),
    do: Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:catcher_count, count})

  # A fight is on: everything reaching here is contaminated by the live enemy sprite
  # (tile-locked, stands still — indistinguishable from a corpse). No admissions, no throws,
  # no confirms until combat disengages (see the {:combat,...} handler above).
  defp do_advance(%{combat_engaged?: true} = state, _obs), do: state

  # Capture disabled (loot-only operation): the ball pipeline never steps — no admissions,
  # no throws, no confirms. The feed is also detached (see should_be_attached?/1); this
  # gate only catches stragglers (a late event right after the toggle flip).
  defp do_advance(state, obs) do
    cond do
      not capture_allowed?(state) ->
        state

      # Ask the GATE before deciding — the cavebot's lesson (Body.step_minimap):
      # `Rig.Mac.gated/1` answers `:ok` when it SUPPRESSES, so acting and then
      # checking the return would make Logic count a ball that never left, spend
      # the queue and open a confirmation window against an untouched corpse.
      # Skipping the whole step leaves the corpse there for the next kill.
      not gate_aberto?() ->
        hold(state)

      true ->
        run_step(%{state | held?: false}, obs)
    end
  end

  defp gate_aberto? do
    InputGate.allowed?()
  catch
    :exit, _reason -> false
  end

  # One line per EDGE, not per event: with the browser focused the gate stays
  # closed for minutes, and one alarm per kill would be a siren.
  defp hold(%{held?: true} = state), do: state

  defp hold(state) do
    log(:macro, "🔒 bola SEGURADA — o jogo não está em foco (ou o pânico está armado)")
    %{state | held?: true}
  end

  # Logic says "throw at X"; Catcher.Ball knows HOW (position, settle, hit the
  # configured hotkey, hold the cursor). nil when nothing was thrown.
  defp throw_balls([], _body), do: nil

  defp throw_balls(performs, body) do
    performs
    |> Enum.flat_map(fn {:capture_sequence, point} -> Ball.sequence(point) end)
    |> Body.perform(:high, body)
  end

  # The return used to be DISCARDED — a real actuation error vanished and the
  # feed wrote "bola arremessada" anyway.
  defp after_throw(logic, {:error, reason}, _performs) do
    log(:macro, "⚠️ a bola não saiu: #{inspect(reason)}")
    logic
  end

  # The confirmation window counts from ACTUATION (the sequence takes ~200ms),
  # not from the decision — else the first read judges too early.
  defp after_throw(logic, :ok, performs) when performs != [], do: Logic.ball_flown(logic, now())
  defp after_throw(logic, _result, _no_ball), do: logic

  defp note_throw(state, []), do: state

  defp note_throw(state, _performs) do
    # a ball that flew because a SHINY was seen closes that log entry
    if state.shiny_pending?, do: ShinyLog.resolve_last("ball")

    %{
      state
      | last_action: %{text: "bola arremessada (#{Ball.key()})", at: now()},
        shiny_pending?: false
    }
  end

  defp run_step(state, obs) do
    {logic, actions} = Logic.step(state.logic, obs, now())

    performs = Enum.filter(actions, &match?({:capture_sequence, _}, &1))

    # Logic says "throw at X"; Catcher.Ball knows HOW (position, settle, hit the
    # configured hotkey, hold the cursor). Each step passes the input and
    # mini-game gates instead of an opaque Rig primitive.
    result = throw_balls(performs, state.body)

    # The return used to be DISCARDED — a real actuation error vanished and the
    # feed wrote "bola arremessada" anyway.
    logic = after_throw(logic, result, performs)

    # the dry-ball alarm goes out under :capture (mutable in the bell)
    for {:alarm, msg} <- actions do
      Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:rule_alarm, :capture, msg})
    end

    state = note_throw(state, performs)

    for {:log, text} <- actions do
      Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:catcher_log, :macro, "captura: #{text}"})
    end

    # The ball says WHO is in the aim: the interpreter already recognized the
    # corpse via the library (only mapped corpses are targets since 2026-07-30)
    # and the name travels in the observation — dropping it meant blind validation.
    for {:capture_sequence, point} <- performs, info = known_at(obs, point), info != nil do
      Phoenix.PubSub.broadcast(
        Pokex.PubSub,
        @topic,
        {:catcher_log, :macro,
         "captura: 🎯 #{info.name} reconhecido (#{trunc(info.score * 100)}%)"}
      )
    end

    # pending_corpses joins the change condition: support holds on that number,
    # so its transitions must reach the wire even on an action-less step
    if logic.counters != state.logic.counters or actions != [] or
         Logic.pending(logic) != Logic.pending(state.logic),
       do: broadcast(%{state | logic: logic})

    %{state | logic: logic}
  end

  # A confirmed kill just dropped a corpse on the ADJACENT melee tile — Space reaches it from
  # standing position. Runs BEFORE the advance so the presses hit the Body ahead of any ball
  # of this cycle (the ball additionally waits on detector confirmation, ≥800ms later — and
  # the ball consumes the corpse WITH its loot, so the order is load-bearing).
  defp loot_kill(state) do
    # Looting works in BOTH modes: Space reaches the corpse on the tile where the
    # kill just happened, wherever he is standing at that instant. Only the BALL
    # needs him still — it is aimed from a ground baseline learned while standing
    # — and that is gated separately in advance/2. The mode check that used to
    # sit here was inherited from the capture design and silently cost him every
    # drop while walking.
    #
    # Space is the MINI-GAME's control key: looting mid-game would drive the
    # capsule (the Body gate also blocks it — this keeps the log honest too).
    if not Perception.mini_game_playing?() and Settings.get(:loot_enabled) do
      presses = max(Settings.get(:loot_presses), 1)
      gap = Settings.get(:loot_press_gap_ms)

      actions =
        [{:press, "space"}]
        |> List.duplicate(presses)
        |> Enum.intersperse([{:wait, gap}])
        |> List.flatten()

      Body.perform(actions, :high, state.body)

      Phoenix.PubSub.broadcast(
        Pokex.PubSub,
        @topic,
        {:catcher_log, :macro, "captura: 🧰 saqueando (espaço ×#{presses})"}
      )

      state = %{
        state
        | loots: state.loots + 1,
          last_action: %{text: "saque (espaço ×#{presses})", at: now()}
      }

      broadcast(state)
      state
    else
      state
    end
  end

  # The kill-anchored observation. Gates BEFORE the capture: scanning with a
  # fight engaged would match the adjacent LIVE sprite (a standing pokémon's
  # palette equals its taught corpse's); moving/capture-off don't even look;
  # the mini-game owns the moment. nil = a step that proves nothing (Logic
  # ignores it), never a false confirmation.
  defp scan_obs(state) do
    if state.combat_engaged? or Settings.get(:player_mode) != "still" or
         not capture_allowed?(state) or Perception.mini_game_playing?(),
       do: nil,
       else: state.scanner |> safe_scan() |> narrate()
  end

  # A dying scanner (capture failed, corrupted calibration) becomes a blind
  # step — never takes the worker down mid-fleet. But the exception is LOGGED:
  # a silent rescue is exactly how a scan that never happened becomes
  # indistinguishable from one that found nothing.
  defp safe_scan(scanner) do
    scanner.()
  rescue
    error ->
      Logger.warning("captura: varredura explodiu — #{Exception.message(error)}")
      nil
  catch
    :exit, reason ->
      Logger.warning("captura: varredura morreu — #{inspect(reason)}")
      nil
  end

  # Every scan becomes ONE feed line. Before, the three possible outcomes —
  # didn't scan, scanned and found nothing, scanned and found — produced the
  # same silence for hours (2026-07-30). The best candidate's score goes along
  # even when FAILING: distance to the threshold is the aim diagnostic.
  defp narrate(nil), do: nil

  defp narrate(%{scanning?: false} = obs) do
    # blindness is rare and must survive restarts → :macro (goes to the JSONL)
    log(:macro, "🔎 cego: #{reason_text(Map.get(obs, :reason))}")
    obs
  end

  defp narrate(%{windows: windows} = obs) do
    # routine at :debug — lives in the feed, doesn't bloat the on-disk history
    log(:debug, "🔎 varri #{windows} janelas#{frame_text(obs)} · " <> best_text(obs))
    obs
  end

  defp narrate(obs), do: obs

  defp frame_text(%{region: {_x, _y, w, h}}), do: " (#{w}×#{h})"
  defp frame_text(_no_region), do: ""

  defp best_text(%{best: nil}), do: "acervo vazio"

  defp best_text(%{best: %{name: name, score: score, point: {x, y}}, threshold: threshold}) do
    verdict = if score >= threshold, do: "✓", else: "✗"
    "melhor: #{name} #{fmt(score)} #{verdict} em #{x},#{y} (limiar #{fmt(threshold)})"
  end

  defp best_text(_no_field), do: "sem leitura"

  defp fmt(n) when is_number(n), do: :erlang.float_to_binary(n / 1, decimals: 2)
  defp fmt(_outro), do: "?"

  defp reason_text(:no_calibration), do: "sem calibração"
  defp reason_text(:no_anchor), do: "sem personagem nem ponto do pokémon calibrados"
  defp reason_text(:no_arena), do: "sem arena calibrada"
  defp reason_text(:no_screen), do: "a calibração não tem as medidas da tela"

  defp reason_text(:outside_arena),
    do: "os tiles ao redor do personagem caem FORA da arena calibrada — recalibre a arena"

  defp reason_text({:capture_failed, reason}), do: "captura falhou (#{inspect(reason)})"
  defp reason_text(outro), do: inspect(outro)

  defp log(level, text),
    do: Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:catcher_log, level, "captura: #{text}"})

  # The library IS the aim — a start with an empty library will aim at NOTHING
  # all session, which deserves a siren, not silence ("looks on but does
  # nothing" is exactly what eroded trust).
  defp announce_library do
    # If the ball is off, the library is irrelevant and THAT is the message. An
    # alarm, not a whisper — capture once ran "on" for hours (bot running, loot
    # flowing) with the key false and nothing on screen said so out loud.
    if not Settings.get(:capture_enabled) do
      Phoenix.PubSub.broadcast(
        Pokex.PubSub,
        @topic,
        {:rule_alarm, :capture,
         "🔒 captura DESLIGADA (só saque) — ligue o botão Captura no painel; " <>
           "nenhuma Pokébola será arremessada"}
      )
    end

    announce_corpses()
  end

  defp announce_corpses do
    case length(CorpseLibrary.list()) do
      0 ->
        Phoenix.PubSub.broadcast(
          Pokex.PubSub,
          @topic,
          {:rule_alarm, :capture,
           "🎯 acervo de corpos VAZIO — a captura não vai mirar nada; fotografe corpos na calibração"}
        )

      n ->
        # "N pokémon taught", not "N corpses" — "acervo com 10 corpos" was read
        # as "10 corpses on screen right now" (2026-07-30)
        Phoenix.PubSub.broadcast(
          Pokex.PubSub,
          @topic,
          {:catcher_log, :macro,
           "captura: 🎯 mira pronta — #{n} pokémon ensinado(s) no acervo da calibração"}
        )
    end
  end

  # The ball flies at a point ADMITTED in an earlier observation; the track
  # center may have drifted a few px since — the nearest neighbor within
  # tolerance is the same corpse.
  defp known_at(%{known: known}, {px, py}) when is_map(known) and map_size(known) > 0 do
    tolerance = Settings.get(:corpse_match_tolerance_px)

    known
    |> Enum.filter(fn {{x, y}, _info} ->
      abs(x - px) <= tolerance and abs(y - py) <= tolerance
    end)
    |> Enum.min_by(
      fn {{x, y}, _info} -> (x - px) * (x - px) + (y - py) * (y - py) end,
      fn -> nil end
    )
    |> case do
      {_point, info} -> info
      nil -> nil
    end
  end

  defp known_at(_obs, _point), do: nil

  # The ground-detector feed is RETIRED (2026-07-30): vision is now the
  # kill-anchored SpotScan — real operation never has the quiet window the
  # baseline warmup required. The attach/reattach machinery below stays inert
  # (nothing ever attaches); removing Interpret.Corpses/the feed is separate
  # cleanup.
  defp sync_mode(state) do
    if should_be_attached?(state), do: attach(state), else: cancel_timer(detach(state))
  end

  defp armed_idle?(state),
    do: Settings.get(:player_mode) == "still" and match?(%Logic{state: :armed}, state.logic)

  defp should_be_attached?(_state), do: false

  defp attach(%{attached?: true} = state), do: state

  defp attach(state) do
    safe(fn -> Perception.attach(:corpses) end)
    demonitor_feed(state.feed_ref)
    ref = Process.monitor(Feed.name(:corpses))
    %{state | attached?: true, feed_ref: ref, reattach_attempts: 0}
  end

  defp detach(%{attached?: false} = state), do: state

  defp detach(state) do
    safe(fn -> Perception.detach(:corpses) end)
    demonitor_feed(state.feed_ref)
    %{state | attached?: false, feed_ref: nil}
  end

  defp demonitor_feed(nil), do: :ok
  defp demonitor_feed(ref), do: Process.demonitor(ref, [:flush])

  defp schedule_reattach(%{reattach_attempts: attempts} = state) when attempts >= 20, do: state

  defp schedule_reattach(state) do
    Process.send_after(self(), :reattach_corpses, 250)
    %{state | reattach_attempts: state.reattach_attempts + 1}
  end

  # The bounded, catch-guarded reattach fired from :reattach_corpses. Unlike attach/1 (used by
  # the normal run/mode_changed/relearn/disengage paths, which must never crash on a feed that
  # isn't registered yet), this one is only reached once we already know the feed just went
  # down — a still-dead feed schedules another bounded retry instead of optimistically marking
  # itself attached.
  defp reattach_corpses(state) do
    Perception.attach(:corpses)
    demonitor_feed(state.feed_ref)
    ref = Process.monitor(Feed.name(:corpses))
    %{state | attached?: true, feed_ref: ref, reattach_attempts: 0}
  catch
    :exit, _ -> schedule_reattach(state)
  end

  defp reset_logic(%{logic: nil} = state), do: state

  # "Reaprender chão": a fresh Logic (not just the old one restarted) so the queue/throw/
  # ignored map from the old spot die with the old ground — a stale pending throw surviving
  # the move would confirm/retry against coordinates that mean nothing at the new spot.
  defp reset_logic(state) do
    {logic, _actions} = Logic.start(Logic.new(config()), now())
    %{state | logic: logic}
  end

  defp safe(fun) do
    fun.()
  catch
    :exit, _reason -> :ok
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | timer: nil}
  end

  defp config, do: Settings.all() |> Map.take(@config_keys)

  defp mode_state(nil, _mode), do: :idle
  defp mode_state(_logic, "moving"), do: :manual

  defp mode_state(%Logic{state: :armed}, _mode) do
    if Settings.get(:capture_enabled), do: :armed, else: :looting
  end

  defp mode_state(%Logic{state: s}, _mode), do: s

  defp snapshot(state) do
    mode = Settings.get(:player_mode)

    %{
      state: mode_state(state.logic, mode),
      mode: mode,
      counters:
        ((state.logic && state.logic.counters) || %Logic{}.counters)
        |> Map.put(:loots, state.loots)
        |> Map.put(:scans, state.scans)
        |> Map.put(:with_target, state.with_target)
        |> Map.put(:blind, state.blind),
      error: state.logic && state.logic.error,
      hold_reason: hold_reason(state),
      last_action: state.last_action,
      pending_corpses: (state.logic && Logic.pending(state.logic)) || 0,
      sweep: %{
        enabled?: Settings.get(:sweep_enabled),
        pending: length(state.sweep_queue),
        sweeps: state.sweeps,
        balls: state.sweep_balls
      }
    }
  end

  # Computed at broadcast time from live state — the engage/disengage edge above
  # guarantees the fight reason appears/clears promptly; the mini-game one rides
  # on whatever event broadcasts while the game plays (the catcher is passive then).
  defp hold_reason(%{logic: nil}), do: nil

  defp hold_reason(state) do
    cond do
      Perception.mini_game_playing?() ->
        "mini-game em jogo"

      state.combat_engaged? ->
        "esperando fim da luta"

      # The gate that stayed shut all day without saying its name (2026-07-30:
      # 1015 kills, 1015 loots, zero scans — the key was false and the only clue
      # was the "só saque" pill). The reason now heads the hold list instead of
      # reading as normal state.
      not Settings.get(:capture_enabled) ->
        "captura DESLIGADA — só saque"

      true ->
        nil
    end
  end

  defp broadcast(state),
    do: Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:catcher, snapshot(state)})

  # combat only broadcasts on transitions — a catcher arming MID-FIGHT would otherwise
  # believe the field is clear. Best-effort: an unreachable combat reads as not engaged
  # (fail-open matches the boot default; the next transition broadcast corrects it).
  defp monitorar_combate(state) do
    if state.combat_ref, do: Process.demonitor(state.combat_ref, [:flush])

    case Process.whereis(Worker) do
      pid when is_pid(pid) -> %{state | combat_ref: Process.monitor(pid)}
      nil -> %{state | combat_ref: nil}
    end
  end

  defp seed_combat_engaged do
    %{state: s} = Worker.status()
    s in [:tabbing, :fighting]
  catch
    :exit, _reason -> false
  end

  defp now, do: System.monotonic_time(:millisecond)
end
