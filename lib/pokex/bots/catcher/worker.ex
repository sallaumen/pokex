defmodule Pokex.Bots.Catcher.Worker do
  @moduledoc """
  Driver for the pure Catcher.Logic: consumes `:corpses` observations from the perception
  blackboard, throws confirmed Pokéballs through the Body (`:high`), and follows the player
  mode LIVE — `parado` attaches the feed and acts; `movimento` detaches and idles (Lucas
  captures manually while moving). Combat's kill broadcast is only an accelerator: it forces
  an immediate world re-read; detection never depends on it. A confirmed kill also triggers a
  `capture_enabled` gates the entire ball pipeline (and the feed attach), so a hunt that
  only kills never throws.

  Combat-engagement gate: PokeTibia combat is tile-locked — a FIGHTING sprite stands still,
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
  alias Pokex.Bots.Catcher.Balls
  alias Pokex.Bots.Catcher.CorpseLibrary
  alias Pokex.Bots.Catcher.Logic
  alias Pokex.Bots.Catcher.ShinyAim
  alias Pokex.Bots.Catcher.SpotScan
  alias Pokex.Bots.Catcher.Sweep
  alias Pokex.Bots.Combat.Worker
  alias Pokex.Bots.Engine
  alias Pokex.Bots.InputGate
  alias Pokex.Calibration
  alias Pokex.Perception
  alias Pokex.Perception.WorldState
  alias Pokex.Pokedex.ShinyLog
  alias Pokex.Settings

  @topic "catcher"

  # Quanto tempo o lugar onde um bicho estava de pé continua valendo como lugar
  # de corpo. A rodada leva da corrente ao revive e à hora da bola uns 4-8 s; 20 s
  # cobre isso sem deixar o chão da pilha anterior valer pra próxima.
  @standing_memory_ms 20_000
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
      scanner: Keyword.get(opts, :scanner, &SpotScan.scan/0),
      # the shiny's corpse by colour (Catcher.ShinyAim); injectable like the scanner
      aimer: Keyword.get(opts, :aimer, &ShinyAim.scan/0),
      # Entry door, like every sibling in this family. The env used to be read RAW inside
      # `arm_sweep/1`, so in the suite the `sweep_timer` stayed nil forever and re-arming
      # could not be exercised: the rule written right above it (must not go quiet until
      # the next Start) passed green even when narrowed.
      auto_tick?:
        Keyword.get(opts, :auto_tick, Application.get_env(:pokex, :sweep_auto_tick, true))
    }

    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, init_arg)
      name -> GenServer.start_link(__MODULE__, init_arg, name: name)
    end
  end

  def run(server \\ __MODULE__), do: GenServer.call(server, :run)
  def halt(server \\ __MODULE__), do: GenServer.call(server, :halt)
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "The panel pokes this after flipping player_mode / the capture toggle — attach/detach applies live."
  def mode_changed(server \\ __MODULE__), do: GenServer.call(server, :mode_changed)

  @doc "Force a fresh ground warmup (detach + attach): use after moving to a new spot."
  def relearn(server \\ __MODULE__), do: GenServer.call(server, :relearn)

  @doc """
  Sweeps NOW, ignoring `sweep_enabled` — the settings screen's test button.

  A CAST, deliberately. It was a call and it took the panel down (2026-08-05):
  this process parks on captures that the broker can hold for seconds, so any
  synchronous ask from the LiveView is a timeout waiting to happen, and a
  timeout in a `handle_event` kills the page. Worse, a timed-out call still
  runs later, so "deu tempo" on screen would be a lie about a sweep that did
  start. The answer comes back as a `{:sweep_result, text}` broadcast on this
  worker's topic instead — the panel already listens there.

  Centred on `around` (a screen point) when given, else on the character. The
  hunt passes the tile his pokémon was parked on: after a gathered fight the
  corpses lie around the POKÉMON, not around him ("esses corpos de pokémons
  não estão ao redor do meu personagem" — 2026-08-11), and a sweep centred on
  the character throws every ball at empty ground.
  """
  def sweep_now(server \\ __MODULE__, around \\ nil),
    do: GenServer.cast(server, {:sweep_now, around})

  @impl true
  def init(%{body: body, scanner: scanner, aimer: aimer, auto_tick?: auto_tick?}) do
    Phoenix.PubSub.subscribe(Pokex.PubSub, @kill_topic)
    Phoenix.PubSub.subscribe(Pokex.PubSub, Engine.Worker.topic())
    Phoenix.PubSub.subscribe(Pokex.PubSub, Perception.topic())
    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    # a SHINY sighting overrides capture_enabled for the next ball
    Phoenix.PubSub.subscribe(Pokex.PubSub, "shiny")

    {:ok,
     %{
       logic: nil,
       body: body,
       scanner: scanner,
       aimer: aimer,
       # the AIM SESSION opened by a shiny sighting: when it opened, the
       # candidates of the previous look (two photos confirm a corpse) and the
       # points already announced. nil = no shiny to look for.
       aim: nil,
       aim_timer: nil,
       auto_tick?: auto_tick?,
       timer: nil,
       combat_engaged?: false,
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
       # onde o olho viu bicho de pé: %{{pos, ponto} => quando}. Um corpo só
       # pode estar num desses lugares (`Catcher.Logic.admissible/1`).
       standing: %{},
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
        scans: 0,
        with_target: 0,
        blind: 0,
        count: %{},
        vistos: MapSet.new(),
        sweeps: 0,
        sweep_balls: 0,
        combat_engaged?: seed_combat_engaged()
    }

    state = %{state | shiny_pending?: false}
    state = state |> monitorar_combate() |> cancel_timer() |> arm_sweep()
    announce_library()
    broadcast(state)
    {:reply, :ok, state}
  end

  def handle_call(:halt, _from, %{logic: nil} = state), do: {:reply, :ok, disarm_sweep(state)}

  def handle_call(:halt, _from, state) do
    {logic, _} = Logic.stop(state.logic)
    state = state |> Map.put(:logic, logic) |> disarm_sweep() |> close_aim()
    broadcast(state)
    {:reply, :ok, cancel_timer(state)}
  end

  def handle_call(:status, _from, state), do: {:reply, snapshot(state), state}

  def handle_call(:mode_changed, _from, %{logic: nil} = state), do: {:reply, :ok, state}

  def handle_call(:mode_changed, _from, state) do
    state = %{state | combat_engaged?: seed_combat_engaged()}
    # the sweep re-arms HERE too: flipping its switch (or its cadence) in the
    # settings screen has to apply to a bot already running, not at the next start
    state = state |> cancel_timer() |> arm_sweep()
    broadcast(state)
    {:reply, :ok, state}
  end

  def handle_call(:relearn, _from, state) do
    state = state |> reset_logic() |> cancel_timer()
    {:reply, :ok, state}
  end

  @impl true
  # The test button: sweeps even with the switch off (that is what makes it a
  # test), but never past a gate — the reasons a sweep is held are the reasons
  # it would be wrong or invisible, not paperwork. The verdict goes out as a
  # broadcast because the caller is a LiveView that must not wait on us.
  def handle_cast({:sweep_now, around}, state) do
    case sweep_hold_reason(state) do
      nil ->
        case begin_sweep(state, around) do
          {:ok, state} ->
            sweep_result("varrendo #{length(state.sweep_queue)} tile(s)…")
            {:noreply, state}

          {:error, reason} ->
            sweep_result("não varreu: #{reason}")
            {:noreply, state}
        end

      reason ->
        sweep_result("não varreu: #{reason}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:world, _key, _obs}, state), do: {:noreply, state}

  # O OLHO DIZ ONDE CADA BICHO ESTÁ (`CrowdWatch`, a cada ~250 ms, no tópico do
  # cérebro). Quando a hora da bola chega eles já morreram e sumiram da leitura,
  # por isso o lugar é guardado enquanto estão de pé.
  def handle_info({:crowd, %{read?: true, hostiles: hostiles}}, state),
    do: {:noreply, remember_standing(state, hostiles)}

  def handle_info(:wake, %{logic: %Logic{state: :armed}} = state),
    do: {:noreply, advance(state, scan_obs(state))}

  def handle_info(:wake, state), do: {:noreply, state}

  # A HORA DA BOLA, dita pelo cérebro. O `{:kill}` do Combat só sai quando a
  # LISTA DE BATALHA ZERA (`Combat.Logic`, o contador `counters.fights`), e no
  # Auto Combo a tela dele quase nunca zera: o diário de 09/09 tem 5 desses numa
  # noite de 299 aberturas de luta, e por isso a captura simplesmente não
  # acontecia na caçada — funcionava pescando, onde é um peixe por vez e a lista
  # esvazia entre as fisgadas. Agora o cérebro avisa no fim da rodada, que é
  # quando os corpos estão no chão e a estrada já está parada.
  def handle_info({:capture_now}, %{logic: %Logic{state: :armed}} = state) do
    obs = scan_obs(state)
    announce_cue(obs)
    {:noreply, advance(%{state | repiques: @repiques}, obs)}
  end

  # kill = accelerator (both shapes: Task 5 drops the payload; tolerate the old one meanwhile).
  # Vision is ANCHORED HERE: the kill says a corpse just fell on an adjacent
  # tile — SpotScan asks the library which one (see Catcher.SpotScan).
  def handle_info({:kill}, %{logic: %Logic{state: :armed}} = state) do
    {:noreply, advance(%{state | repiques: @repiques}, scan_obs(state))}
  end

  def handle_info({:kill, _corpse}, %{logic: %Logic{state: :armed}} = state) do
    {:noreply, advance(%{state | repiques: @repiques}, scan_obs(state))}
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
  # Combat.Worker died: FAIL-OPEN on the engagement mirror. A crash between
  # engage and disengage would leave combat_engaged? stuck true — a mute catcher
  # until a broadcast that may never come. The supervisor recreates combat,
  # which re-broadcasts; until then, better to risk one contaminated scan (the
  # library filters) than none.
  def handle_info({:DOWN, ref, :process, _obj, _reason}, %{combat_ref: ref} = state) do
    {:noreply, monitorar_combate(%{state | combat_engaged?: false})}
  end

  def handle_info({:DOWN, _ref, :process, _obj, _reason}, state), do: {:noreply, state}

  # A shiny is on screen: arm the override so the ball flies even with capture
  # off, and open the aim session — its corpse is looked for by COLOUR on its
  # own timer, in any player_mode (the guard's palette is the only aim a hunt
  # has; see Catcher.ShinyAim).
  def handle_info({:shiny_seen, _info}, %{logic: %Logic{state: :armed}} = state) do
    state = %{state | shiny_pending?: true}
    {:noreply, if(state.aim == nil, do: open_aim(state), else: state)}
  end

  def handle_info({:shiny_seen, _info}, state), do: {:noreply, %{state | shiny_pending?: true}}

  def handle_info(:aim, %{aim: nil} = state), do: {:noreply, state}

  # One look per tick: candidates confirmed by the previous look become the
  # Logic's corpses. The session closes when the ball's story ends (nothing
  # pending and the shiny no longer waiting), or when the corpse never shows.
  def handle_info(:aim, %{aim: %{since: since}} = state) do
    ttl = aim_ttl_ms()

    cond do
      not match?(%Logic{state: :armed}, state.logic) ->
        {:noreply, close_aim(state)}

      now() - since >= ttl ->
        log(:macro, "🌟 shiny visto, corpo não achado em #{div(ttl, 1000)}s — bola guardada")
        {:noreply, close_aim(state)}

      true ->
        {state, obs} = aim_look(state)
        state = advance(state, obs)

        if aim_done?(state) do
          {:noreply, close_aim(state)}
        else
          publish_capture(state)
          {:noreply, schedule_aim(state)}
        end
    end
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

  defp begin_sweep(state, around \\ nil) do
    case sweep_points(around) do
      {:ok, []} ->
        {:error, "nenhum tile sobrou dentro da tela"}

      {:ok, points} ->
        log(:macro, "🧹 varredura cega em #{length(points)} tile(s)#{around_text(around)}")
        send(self(), :sweep_tile)
        {:ok, broadcast_and_return(%{state | sweep_queue: points, sweeps: state.sweeps + 1})}

      {:error, reason} ->
        {:error, reason_text(reason)}
    end
  end

  # Loaded from disk on every sweep, like the rest of the fleet: recalibrating
  # applies without a restart.
  defp sweep_points(around) do
    case Calibration.load() do
      {:ok, calib} -> Sweep.points(calib, around)
      _no_calibration -> {:error, :no_calibration}
    end
  end

  defp around_text({x, y}), do: " em volta do pokémon (#{x}, #{y})"
  defp around_text(_character), do: " (#{Ball.key()} em cada um)"

  defp sweep_hold_reason(state) do
    cond do
      # "Captura desligada" has to mean NO BALL, full stop. The sweep consulted
      # only its own switch, so with capture off the panel alarmed "nenhuma
      # Pokébola será arremessada" while the sweep kept throwing one at every
      # tile around him. Found the day its switch moved next to capture's in the
      # quick strip (2026-08-11): a promise on screen the code did not keep.
      not Settings.get(:capture_enabled) ->
        "a captura está desligada"

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

  # A HEARTBEAT, not a switch-driven timer: while the bot runs, the tick always
  # exists and it is the TICK that reads `sweep_enabled` and the cadence. That
  # is what lets the settings screen flip the switch without asking this process
  # anything — and asking it synchronously is exactly what took the panel down
  # (2026-08-05), because a worker parked on a capture answers nothing for
  # seconds. A disabled sweep costs one no-op message per cadence.
  defp arm_sweep(state) do
    state = cancel_sweep(state)

    # The heartbeat is an ACTUATOR loop on an app-global process: left armed in
    # the suite it fires a ball into whatever shared Rig another test is
    # asserting on (it did — a stray "f1" in Bots.BodyTest, 2026-08-06). Same
    # reasoning as :player_support_auto_monitor; tests that exercise the cadence
    # drive `:sweep` themselves.
    if state.auto_tick? do
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

  defp sweep_result(text),
    do: Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:sweep_result, text})

  # capture_enabled OR um shiny NA HISTÓRIA — e a história é a sessão de mira,
  # que nasce no avistamento e morre em 90s.
  #
  # `shiny_pending?` sozinho não serve de porta: ele só era limpo quando uma
  # bola voava, então um avistamento durante o jogo manual (a guarda é filha
  # sempre-viva da aplicação) ficava armado por horas e dava bola no PRIMEIRO
  # corpo comum da sessão seguinte, com a captura desligada — e ainda carimbava
  # aquele avistamento velho como capturado.
  defp capture_allowed?(state),
    do: Settings.get(:capture_enabled) or (state.aim != nil and Settings.get(:shiny_always_ball))

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
        # the shiny's corpse is aimed by colour on a fresh frame: no mode owns it
        match?(%{source: :shiny_aim}, obs) -> do_advance(state, obs)
        # PARADO É PARADO: modo Parado, ou caçada com a estrada segurada pelo
        # cérebro. Este era o SEGUNDO portão do mesmo modo — consertar só o
        # `scan_obs/1` deixava a varredura rodar e o resultado morrer aqui.
        standing?() -> do_advance(state, obs)
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
  # …except the shiny aim, whose "no living body within a tile" test is the
  # answer to that very worry (Catcher.ShinyAim).
  defp do_advance(%{combat_engaged?: true} = state, %{source: :shiny_aim} = obs),
    do: advance_gated(state, obs)

  # …e com a captura DESLIGADA, só a mira do shiny passa: a sessão aberta não
  # pode virar licença pra jogar bola em corpo comum.
  defp do_advance(state, obs) when not is_map_key(obs, :source) do
    if Settings.get(:capture_enabled), do: advance_gated(state, obs), else: state
  end

  defp do_advance(%{combat_engaged?: true} = state, _obs), do: state

  # Capture disabled: the ball pipeline never steps — no admissions, no throws,
  # no confirms. Catches the straggler right after the toggle flip.
  defp do_advance(state, obs), do: advance_gated(state, obs)

  defp advance_gated(state, obs) do
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
    |> Enum.flat_map(fn {:capture_sequence, point, name} ->
      key = Balls.key_for(name)
      announce_special_ball(key, name)
      Ball.sequence(point, key)
    end)
    |> Body.perform(:high, body)
  end

  # Only when a RULE fired. The ordinary ball is the silent case — saying
  # "Poké Ball" on every throw would bury the one line that matters, which is
  # the good ball leaving for the creature he is actually hunting.
  defp announce_special_ball(key, name) do
    if key != Balls.default_key(),
      do: log(:macro, "🔴 #{Balls.label(key)} (#{key}) para #{name}")
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

  # QUEM LEVOU A BOLA. A linha do arremesso é a mesma pro corpo comum da
  # varredura e pro shiny, e a tela do Cave Bot só sabia separar as duas
  # procurando a palavra "bola" — pescando a caçada inteira pra dentro da
  # história do shiny. Quem sabe é a LEITURA que gerou a jogada: com a varredura
  # e a mira abertas ao mesmo tempo, olhar só pro estado do worker marcaria
  # também a bola de um corpo comum. Um passo SEM leitura (um corpo que já
  # estava na fila) fica com a sessão de mira como resposta.
  defp shiny_star(obs, state), do: if(shiny_reading?(obs, state), do: "🌟 ", else: "")

  defp note_throw(state, [], _obs), do: state

  defp note_throw(state, _performs, obs) do
    # A BOLA DO SHINY, não qualquer bola. Isto rodava em TODO arremesso: uma bola
    # em corpo comum da varredura carimbava "bola" na prateleira do shiny (uma
    # mentira: nenhuma bola foi nele) e zerava `shiny_pending?`, de modo que
    # `aim_done?/1` fechava a caçada do corpo do shiny antes de alguém tê-lo
    # visto. Quem responde é a leitura que gerou o arremesso.
    if state.shiny_pending? and shiny_reading?(obs, state) do
      ShinyLog.resolve_last("ball")

      %{
        state
        | last_action: %{text: "bola arremessada (#{Ball.key()})", at: now()},
          shiny_pending?: false
      }
    else
      %{state | last_action: %{text: "bola arremessada (#{Ball.key()})", at: now()}}
    end
  end

  defp shiny_reading?(%{source: :shiny_aim}, _state), do: true
  defp shiny_reading?(nil, %{aim: aim}), do: aim != nil
  defp shiny_reading?(_ordinary_reading, _state), do: false

  defp run_step(state, obs) do
    {logic, actions} = Logic.step(state.logic, obs, now())

    performs = Enum.filter(actions, &match?({:capture_sequence, _, _}, &1))

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

    state = note_throw(state, performs, obs)

    star = shiny_star(obs, state)

    for {:log, text} <- actions do
      Phoenix.PubSub.broadcast(
        Pokex.PubSub,
        @topic,
        {:catcher_log, :macro, "captura: #{star}#{text}"}
      )
    end

    # The ball says WHO is in the aim: the interpreter already recognized the
    # corpse via the library (only mapped corpses are targets since 2026-07-30)
    # and the name travels in the observation — dropping it meant blind validation.
    for {:capture_sequence, point, _name} <- performs,
        info = known_at(obs, point),
        info != nil do
      Phoenix.PubSub.broadcast(
        Pokex.PubSub,
        @topic,
        {:catcher_log, :macro, "captura: #{recognized(info)}"}
      )
    end

    # pending_corpses joins the change condition: support holds on that number,
    # so its transitions must reach the wire even on an action-less step
    if logic.counters != state.logic.counters or actions != [] or
         Logic.pending(logic) != Logic.pending(state.logic),
       do: broadcast(%{state | logic: logic})

    %{state | logic: logic}
  end

  # The kill-anchored observation. Gates BEFORE the capture: scanning with a
  # fight engaged would match the adjacent LIVE sprite (a standing pokémon's
  # palette equals its taught corpse's); moving/capture-off don't even look;
  # the mini-game owns the moment. nil = a step that proves nothing (Logic
  # ignores it), never a false confirmation.
  # A CHAMADA DIZ O QUE ACHOU. "Não vi log, nada a respeito" (11/09) era metade
  # da queixa: com o portão fechado o `scan_obs/1` devolvia `nil` e `advance/2`
  # engolia, então uma captura que nunca começou e uma que não achou corpo eram
  # a mesma tela em branco. `:macro` porque é o momento que ele procura no
  # diário da manhã seguinte.
  defp announce_cue(nil),
    do:
      log(:macro, "🎯 hora da bola — mas a varredura está fechada agora (luta, modo ou mini-game)")

  defp announce_cue(%{corpses: []}),
    do: log(:macro, "🎯 hora da bola — varri e não achei corpo nenhum no chão")

  defp announce_cue(%{corpses: corpses} = obs) do
    case {length(corpses), length(Logic.admissible(obs))} do
      {n, n} ->
        log(:macro, "🎯 hora da bola — #{n} corpo(s) no chão")

      {n, 0} ->
        log(
          :macro,
          "🎯 hora da bola — #{n} mancha(s) com cor de corpo, nenhuma onde o olho viu um bicho de pé: nenhuma bola"
        )

      {n, k} ->
        log(
          :macro,
          "🎯 hora da bola — #{k} corpo(s) onde um bicho estava de pé (#{n - k} mancha(s) longe da luta, sem bola)"
        )
    end
  end

  defp announce_cue(_sem_leitura), do: :ok

  defp scan_obs(state) do
    if state.combat_engaged? or not standing?() or
         not capture_allowed?(state) or Perception.mini_game_playing?(),
       do: nil,
       else: state.scanner |> safe_scan() |> narrate() |> with_pos() |> with_spots(state)
  end

  # ONDE ELE ESTAVA quando esta foto foi tirada. O juiz da captura
  # (`Catcher.Logic.confirm/3`) pergunta se o corpo continua no mesmo ponto de
  # TELA, e um passo do personagem desloca a tela inteira — sem esta âncora, uma
  # caçada andando dá toda bola por capturada. Ausente (minimapa ilegível) o
  # juiz simplesmente não usa: não saber onde ele está nunca vira "andou".
  defp with_pos(nil), do: nil

  defp with_pos(obs) do
    case current_pos() do
      nil -> obs
      pos -> Map.put(obs, :pos, pos)
    end
  end

  defp current_pos do
    case WorldState.get(:minimap, Settings.get(:cavebot_minimap_fact_max_age_ms), now()) do
      {:ok, %{pos: {_, _, _} = pos}} -> pos
      _sem_leitura -> nil
    end
  end

  # ONDE OS BICHOS ESTAVAM DE PÉ, na tela desta foto. Só na caçada: na pesca e
  # no modo Parado não há olho, e a varredura segue julgando sozinha como
  # sempre julgou. Pontos vistos de OUTRO lugar do mapa não valem — a tela andou
  # junto; sem uma das leituras de posição, não dá pra dizer que andou.
  defp with_spots(nil, _state), do: nil

  defp with_spots(obs, state) do
    if Settings.get(:player_mode) == "still",
      do: obs,
      else:
        Map.merge(obs, %{
          spots: spots_here(state.standing, Map.get(obs, :pos)),
          spot_radius: Calibration.tile_px()
        })
  end

  defp remember_standing(state, hostiles) do
    at = now()
    pos = current_pos()
    seen = Map.new(for %{point: {_, _} = point} <- hostiles, do: {{pos, point}, at})

    standing =
      state.standing
      |> Map.reject(fn {_where, seen_at} -> at - seen_at > @standing_memory_ms end)
      |> Map.merge(seen)

    %{state | standing: standing}
  end

  defp spots_here(standing, pos) do
    at = now()

    for {{seen_pos, point}, seen_at} <- standing,
        at - seen_at <= @standing_memory_ms,
        seen_pos == nil or pos == nil or seen_pos == pos,
        uniq: true,
        do: point
  end

  # PARADO É PARADO, e escolher o modo não é a única forma de estar.
  #
  # Este portão perguntava `player_mode == "still"`, herança de quando a captura
  # era só da pesca — e é por isso que ela NUNCA aconteceu numa caçada. Medido no
  # diário dele de 10/09, a caçada inteira: 84 "mira pronta" e ZERO varreduras,
  # ZERO bolas comuns. `scan_obs/1` devolvia `nil` em todo tique e `advance/2`
  # engolia em silêncio, então não havia nem log pra ele desconfiar ("não vi log,
  # nada a respeito").
  #
  # O que o detector de corpo precisa é da TELA parada, não do modo: ele acha
  # mancha que não se move, e um personagem andando move tudo. Com a estrada
  # SEGURADA pelo cérebro (`route: :hold`) ele está tão parado quanto no modo
  # Parado.
  #
  # …MAS PARADO NÃO É "A LUTA ACABOU". A estrada fica segurada a luta inteira —
  # enquanto a pilha junta, durante a corrente, no revive — e o `combat_engaged?`
  # que devia barrar bicho vivo é do Combat, que no Auto Combo nem entra em luta.
  # Duas horas de caçada em 10/09: 2.123 bolas, 1.353 com a pilha ainda chegando
  # e 272 no meio do combo; só 435 com a lista zerada. A bola comum segue a
  # mesma regra que a do shiny já seguia (`ShinyAim.screen_clear/2`).
  defp standing? do
    Settings.get(:player_mode) == "still" or (road_held?() and screen_clear?())
  end

  defp screen_clear?, do: ShinyAim.screen_clear(:ask, now()) == :ok

  defp road_held? do
    case WorldState.get(:orders, Settings.get(:engine_orders_max_age_ms), now()) do
      {:ok, %{route: :hold}} -> true
      _andando_velho_ou_ausente -> false
    end
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
  # Dois caminhos chegam aqui e cada um sabe uma coisa diferente: a foto do
  # corpo sabe QUANTO se parece com a sprite ensinada, a cor sabe QUANTOS pixels
  # da cor achou. Um número só pros dois mentia num deles.
  defp recognized(%{name: name, score: score}) when is_number(score),
    do: "🎯 #{name} reconhecido (#{trunc(score * 100)}%)"

  defp recognized(%{name: name, px: px}) when is_integer(px),
    do: "🎯 #{name} reconhecido pela cor (#{px} px)"

  defp recognized(%{name: name}), do: "🎯 #{name} reconhecido"

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

  defp reset_logic(%{logic: nil} = state), do: state

  # "Reaprender chão": a fresh Logic (not just the old one restarted) so the queue/throw/
  # ignored map from the old spot die with the old ground — a stale pending throw surviving
  # the move would confirm/retry against coordinates that mean nothing at the new spot.
  defp reset_logic(state) do
    {logic, _actions} = Logic.start(Logic.new(config()), now())
    %{state | logic: logic}
  end

  # -- a mira do shiny ---------------------------------------------------------

  defp open_aim(state) do
    log(:macro, "🌟 shiny visto — procurando o corpo pela cor")
    state = schedule_aim(%{state | aim: %{since: now(), prev: [], said: MapSet.new()}})
    broadcast(state)
    state
  end

  defp close_aim(%{aim: nil} = state), do: state

  # O AZULEJO FICAVA ACESO. Fechar a sessão corrigia o fato do quadro-negro pro
  # cérebro mas não avisava as telas: o azulejo "captura · shiny · bola no ar"
  # seguia âmbar até algum evento sem relação disparar um broadcast — entre uma
  # luta e outra, minutos anunciando um shiny que não existe mais.
  defp close_aim(state) do
    if state.aim_timer, do: Process.cancel_timer(state.aim_timer)
    state = %{state | aim: nil, aim_timer: nil, shiny_pending?: false}
    publish_capture(state)
    broadcast(state)
    state
  end

  # THE FACT FOR THE BRAIN: "I am aiming at a shiny's corpse" — the engine holds
  # the feet on it (`Engine.Logic.hold_for_capture/2`). Rewritten on every aim
  # tick and once on close, so a session that dies with its worker simply ages
  # out of the brain's belief.
  defp publish_capture(state) do
    WorldState.put(
      :capture,
      %{
        aiming?: state.aim != nil,
        pending: (state.logic && Logic.pending(state.logic)) || 0,
        corpses: if(state.aim, do: MapSet.to_list(state.aim.said), else: [])
      },
      now()
    )
  end

  defp schedule_aim(state) do
    if state.aim_timer, do: Process.cancel_timer(state.aim_timer)
    timer = Process.send_after(self(), :aim, Settings.get(:special_color_scan_ms))
    %{state | aim_timer: timer}
  end

  # The story of the ball ended: no shiny waiting for one, nothing queued or in
  # flight. A throw keeps the session alive for its own confirmation scans.
  defp aim_done?(state),
    do: not state.shiny_pending? and Logic.pending(state.logic) == 0

  # Seen by the guard, corpse not yet found: the TTL is the corpse's own life
  # on the ground (minutes) cut short — waiting longer would be waiting for
  # the ordinary kills of the whole night.
  defp aim_ttl_ms, do: Application.get_env(:pokex, :shiny_aim_ttl_ms, 90_000)

  # One look; candidates seen on the PREVIOUS look are the corpses handed to
  # the Logic. The raw candidates become the next look's `prev`.
  defp aim_look(state) do
    case safe_scan(state.aimer) do
      %{scanning?: true, candidates: candidates} = obs ->
        tolerance = Settings.get(:corpse_match_tolerance_px)
        steady = ShinyAim.steady(candidates, state.aim.prev, tolerance)
        obs = ShinyAim.obs(steady, obs.region, obs.captured_at)
        state = announce_corpses(state, steady)
        {%{state | aim: %{state.aim | prev: candidates}}, obs}

      # SEGURAR NÃO É CEGAR. A mira recusa a olhada enquanto há bicho de pé na
      # tela (é hora de matar, não de jogar bola) — contar isso como varredura
      # cega encheria o placar do painel de uma cegueira que não existe.
      %{scanning?: false, reason: {:alive_on_screen, n}} ->
        log(:debug, "🌟 mira segurada: #{n} bicho(s) de pé — primeiro mata")
        {state, nil}

      %{scanning?: false, reason: :no_picture} ->
        log(:debug, "🌟 mira segurada: sem quadro do cérebro pra saber quem está de pé")
        {state, nil}

      %{scanning?: false} = obs ->
        log(:debug, "🌟 mira cega: #{inspect(Map.get(obs, :reason))}")
        {state, obs}

      _nothing ->
        {state, nil}
    end
  end

  defp announce_corpses(state, steady) do
    Enum.reduce(steady, state, fn %{name: name, point: {x, y} = point}, state ->
      if MapSet.member?(state.aim.said, point) do
        state
      else
        log(:macro, "🌟 corpo do #{name} em #{x},#{y} — bola")
        %{state | aim: %{state.aim | said: MapSet.put(state.aim.said, point)}}
      end
    end)
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | timer: nil}
  end

  defp config, do: Settings.all() |> Map.take(@config_keys)

  defp mode_state(nil, _mode), do: :idle
  defp mode_state(_logic, "moving"), do: :manual

  # NA CAÇADA TAMBÉM SE CAPTURA, desde que o portão da varredura enxergue a
  # estrada segurada (`standing?/0`). Esta cláusula respondia `:idle` porque só
  # o shiny levava bola numa caçada — e enquanto isso foi verdade, dizer
  # "capturando" seria mentira. Agora o contrário é que seria: a tela diria
  # parado enquanto a bola sai.

  defp mode_state(%Logic{state: :armed}, _mode) do
    if Settings.get(:capture_enabled), do: :armed, else: :idle
  end

  defp mode_state(%Logic{state: s}, _mode), do: s

  defp snapshot(state) do
    mode = Settings.get(:player_mode)

    %{
      state: if(state.aim != nil, do: :armed, else: mode_state(state.logic, mode)),
      mode: mode,
      counters:
        ((state.logic && state.logic.counters) || %Logic{}.counters)
        |> Map.put(:scans, state.scans)
        |> Map.put(:with_target, state.with_target)
        |> Map.put(:blind, state.blind),
      error: state.logic && state.logic.error,
      hold_reason: hold_reason(state),
      last_action: state.last_action,
      pending_corpses: (state.logic && Logic.pending(state.logic)) || 0,
      aim?: state.aim != nil,
      # a caçada do shiny está aberta mesmo antes de o corpo aparecer
      shiny_pending?: state.shiny_pending?,
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

      state.aim != nil ->
        "mirando o corpo do shiny pela cor"

      reason = hunt_hold() ->
        reason

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

  # A CAÇADA ANDANDO NÃO VARRE — mas a caçada PARADA varre. O detector é de
  # mancha que não se move, e um personagem andando move tudo; com a estrada
  # segurada pelo cérebro ele está parado de verdade (`standing?/0`). Isto
  # dizia "na caçada só o shiny leva bola", que era verdade enquanto o
  # portão exigia o modo Parado — e era a única pista de que a captura nunca
  # rodava numa caçada. Parado ainda não basta: com bicho vivo na lista a bola
  # espera.
  defp hunt_hold do
    cond do
      Settings.get(:player_mode) == "still" -> nil
      not road_held?() -> "andando — a bola sai quando a rota parar"
      not screen_clear?() -> "bicho vivo na tela — a bola espera a lista zerar"
      true -> nil
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
