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
  alias Pokex.Bots.Catcher.{Ball, Logic}
  alias Pokex.Perception
  alias Pokex.Perception.Feed
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
      scanner: Keyword.get(opts, :scanner, &Pokex.Bots.Catcher.SpotScan.scan/0)
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

  @impl true
  def init(%{body: body, scanner: scanner}) do
    Phoenix.PubSub.subscribe(Pokex.PubSub, @kill_topic)
    Phoenix.PubSub.subscribe(Pokex.PubSub, Perception.topic())
    Phoenix.PubSub.subscribe(Pokex.PubSub, Pokex.Bots.Combat.Worker.topic())
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
       segurada?: false,
       # rescans scheduled after a kill that found nothing: the corpse stays on
       # the ground for MINUTES, and the first frame is usually dirty (death
       # animation, loot, the own pokémon on top)
       repiques: [],
       # Combat.Worker monitor: if it dies, combat_engaged? must not stay stuck
       # true — that would be a mute catcher until the next broadcast
       combat_ref: nil,
       # how many of each corpse were FOUND this session, plus the set seen in
       # the previous scan (consecutive dedup)
       contagem: %{},
       vistos: MapSet.new(),
       # session scoreboard (reset on each start): scans done, scans with a
       # target, and blind scans
       varreduras: 0,
       com_alvo: 0,
       cegas: 0,
       # a shiny was just seen: the NEXT ball ignores capture_enabled
       shiny_pending?: false,
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
        varreduras: 0,
        com_alvo: 0,
        cegas: 0,
        contagem: %{},
        vistos: MapSet.new(),
        combat_engaged?: seed_combat_engaged()
    }

    state = state |> monitorar_combate() |> sync_mode()
    announce_library()
    broadcast(state)
    {:reply, :ok, state}
  end

  def handle_call(:halt, _from, %{logic: nil} = state), do: {:reply, :ok, state}

  def handle_call(:halt, _from, state) do
    {logic, _} = Logic.stop(state.logic)
    state = detach(%{state | logic: logic})
    broadcast(state)
    {:reply, :ok, cancel_timer(%{state | reattach_attempts: 0})}
  end

  def handle_call(:status, _from, state), do: {:reply, snapshot(state), state}

  def handle_call(:mode_changed, _from, %{logic: nil} = state), do: {:reply, :ok, state}

  def handle_call(:mode_changed, _from, state) do
    state = %{state | combat_engaged?: seed_combat_engaged()}
    state = sync_mode(state)
    broadcast(state)
    {:reply, :ok, state}
  end

  def handle_call(:relearn, _from, state) do
    state = state |> reset_logic() |> detach() |> sync_mode()
    {:reply, :ok, state}
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
  # of waiting for the next event/poll, and let a parado+armed+detached worker re-attach now
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
    state = if armed_parado?(state), do: schedule_reattach(state), else: state
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
      not armed_parado?(state) or state.attached? ->
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

  def handle_info(_msg, state), do: {:noreply, state}

  # capture_enabled OR a pending shiny (never lose a shiny to a toggle).
  defp capture_allowed?(state),
    do:
      Settings.get(:capture_enabled) or
        (state.shiny_pending? and Settings.get(:shiny_always_ball))

  # The mode gate lives HERE, not only in attach/detach: a late in-flight {:world,...} event
  # (or a test-injected one) right after flipping to movimento must never throw a ball.
  # The mini-game gate comes first: no admissions, throws or confirms while it
  # plays. The catcher is event-driven — the next corpse/kill/combat event after
  # the fact clears resumes the flow on its own.
  defp advance(state, obs) do
    state = contar(state, obs)

    state =
      cond do
        Perception.mini_game_playing?() -> state
        Settings.get(:player_mode) == "parado" -> do_advance(state, obs)
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

      _sem_pendencia ->
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

  # The whole session in three card counters. `com_alvo` rises when SOME library
  # corpse passed the threshold — the varreduras:com_alvo ratio is the aim
  # thermometer (measured 2026-07-30: 242 kills → 1 recognition).
  defp contar(state, %{scanning?: true} = obs) do
    achou? = Map.get(obs, :corpses, []) != []

    state
    |> Map.merge(%{
      varreduras: state.varreduras + 1,
      com_alvo: state.com_alvo + if(achou?, do: 1, else: 0)
    })
    |> contar_por_corpo(obs)
  end

  defp contar(state, %{scanning?: false}), do: %{state | cegas: state.cegas + 1}
  defp contar(state, _sem_varredura), do: state

  # Per-corpse session count ("how many Kingler this session?"). CONSECUTIVE
  # dedup (same idea as the Journal): a ball's confirmation rescans the same
  # tiles, and a corpse sitting there would count again every scan — only what
  # ENTERED since the previous scan adds. Deliberately not derived from
  # `counters.captures`: that number measures "the point stopped matching",
  # not capture.
  defp contar_por_corpo(state, obs) do
    vistos =
      obs
      |> Map.get(:known, %{})
      |> MapSet.new(fn {ponto, %{name: nome}} -> {nome, ponto} end)

    novos = MapSet.difference(vistos, state.vistos)

    contagem =
      Enum.reduce(novos, state.contagem, fn {nome, _ponto}, acc ->
        Map.update(acc, nome, 1, &(&1 + 1))
      end)

    if contagem != state.contagem, do: broadcast_contagem(contagem)

    %{state | vistos: vistos, contagem: contagem}
  end

  defp broadcast_contagem(contagem),
    do: Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:catcher_contagem, contagem})

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
        segurar(state)

      true ->
        run_step(%{state | segurada?: false}, obs)
    end
  end

  defp gate_aberto? do
    Pokex.Bots.InputGate.allowed?()
  catch
    :exit, _reason -> false
  end

  # One line per EDGE, not per event: with the browser focused the gate stays
  # closed for minutes, and one alarm per kill would be a siren.
  defp segurar(%{segurada?: true} = state), do: state

  defp segurar(state) do
    log(:macro, "🔒 bola SEGURADA — o jogo não está em foco (ou o pânico está armado)")
    %{state | segurada?: true}
  end

  defp run_step(state, obs) do
    {logic, actions} = Logic.step(state.logic, obs, now())

    performs = Enum.filter(actions, &match?({:capture_sequence, _}, &1))

    # Logic says "throw at X"; Catcher.Ball knows HOW (position, settle, hit the
    # configured hotkey, hold the cursor). Each step passes the input and
    # mini-game gates instead of an opaque Rig primitive.
    resultado =
      if performs != [] do
        performs
        |> Enum.flat_map(fn {:capture_sequence, ponto} -> Ball.sequence(ponto) end)
        |> Body.perform(:high, state.body)
      end

    # The return used to be DISCARDED — a real actuation error vanished and the
    # feed wrote "bola arremessada" anyway.
    logic =
      case resultado do
        {:error, motivo} ->
          log(:macro, "⚠️ a bola não saiu: #{inspect(motivo)}")
          logic

        :ok when performs != [] ->
          # the confirmation window counts from ACTUATION (the sequence takes
          # ~200ms), not decision — else the first read judges too early
          Logic.ball_flown(logic, now())

        _sem_bola ->
          logic
      end

    # the dry-ball alarm goes out under :captura (mutable in the bell)
    for {:alarm, msg} <- actions do
      Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:rule_alarm, :captura, msg})
    end

    state =
      if performs != [] do
        # a ball that flew because a SHINY was seen closes that log entry
        if state.shiny_pending?, do: Pokex.Pokedex.ShinyLog.resolve_last("bola")

        %{
          state
          | last_action: %{text: "bola arremessada (#{Ball.key()})", at: now()},
            shiny_pending?: false
        }
      else
        state
      end

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

    # pending_corpses joins the change condition: suporte holds on that number,
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
  # palette equals its taught corpse's); movimento/capture-off don't even look;
  # the mini-game owns the moment. nil = a step that proves nothing (Logic
  # ignores it), never a false confirmation.
  defp scan_obs(state) do
    if state.combat_engaged? or Settings.get(:player_mode) != "parado" or
         not capture_allowed?(state) or Perception.mini_game_playing?(),
       do: nil,
       else: state.scanner |> safe_scan() |> narrar()
  end

  # A dying scanner (capture failed, corrupted calibration) becomes a blind
  # step — never takes the worker down mid-fleet. But the exception is LOGGED:
  # a silent rescue is exactly how a scan that never happened becomes
  # indistinguishable from one that found nothing.
  defp safe_scan(scanner) do
    scanner.()
  rescue
    erro ->
      Logger.warning("captura: varredura explodiu — #{Exception.message(erro)}")
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
  defp narrar(nil), do: nil

  defp narrar(%{scanning?: false} = obs) do
    # blindness is rare and must survive restarts → :macro (goes to the JSONL)
    log(:macro, "🔎 cego: #{motivo_texto(Map.get(obs, :motivo))}")
    obs
  end

  defp narrar(%{janelas: janelas} = obs) do
    # routine at :debug — lives in the feed, doesn't bloat the on-disk history
    log(:debug, "🔎 varri #{janelas} janelas#{quadro_texto(obs)} · " <> melhor_texto(obs))
    obs
  end

  defp narrar(obs), do: obs

  defp quadro_texto(%{regiao: {_x, _y, w, h}}), do: " (#{w}×#{h})"
  defp quadro_texto(_sem_regiao), do: ""

  defp melhor_texto(%{melhor: nil}), do: "acervo vazio"

  defp melhor_texto(%{melhor: %{name: nome, score: score, ponto: {x, y}}, limiar: limiar}) do
    veredicto = if score >= limiar, do: "✓", else: "✗"
    "melhor: #{nome} #{fmt(score)} #{veredicto} em #{x},#{y} (limiar #{fmt(limiar)})"
  end

  defp melhor_texto(_sem_campo), do: "sem leitura"

  defp fmt(n) when is_number(n), do: :erlang.float_to_binary(n / 1, decimals: 2)
  defp fmt(_outro), do: "?"

  defp motivo_texto(:sem_calibracao), do: "sem calibração"
  defp motivo_texto(:sem_ancora), do: "sem personagem nem ponto do pokémon calibrados"
  defp motivo_texto(:sem_arena), do: "sem arena calibrada"

  defp motivo_texto(:fora_da_arena),
    do: "os tiles ao redor do personagem caem FORA da arena calibrada — recalibre a arena"

  defp motivo_texto({:captura_falhou, motivo}), do: "captura falhou (#{inspect(motivo)})"
  defp motivo_texto(outro), do: inspect(outro)

  defp log(level, texto),
    do: Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:catcher_log, level, "captura: #{texto}"})

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
        {:rule_alarm, :captura,
         "🔒 captura DESLIGADA (só saque) — ligue o botão Captura no painel; " <>
           "nenhuma Pokébola será arremessada"}
      )
    end

    announce_corpses()
  end

  defp announce_corpses do
    case length(Pokex.Bots.Catcher.CorpseLibrary.list()) do
      0 ->
        Phoenix.PubSub.broadcast(
          Pokex.PubSub,
          @topic,
          {:rule_alarm, :captura,
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

  defp armed_parado?(state),
    do: Settings.get(:player_mode) == "parado" and match?(%Logic{state: :armed}, state.logic)

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
  defp mode_state(_logic, "movimento"), do: :manual

  defp mode_state(%Logic{state: :armed}, _mode) do
    if Settings.get(:capture_enabled), do: :armed, else: :saqueando
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
        |> Map.put(:varreduras, state.varreduras)
        |> Map.put(:com_alvo, state.com_alvo)
        |> Map.put(:cegas, state.cegas),
      error: state.logic && state.logic.error,
      hold_reason: hold_reason(state),
      last_action: state.last_action,
      pending_corpses: (state.logic && Logic.pending(state.logic)) || 0
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

    case Process.whereis(Pokex.Bots.Combat.Worker) do
      pid when is_pid(pid) -> %{state | combat_ref: Process.monitor(pid)}
      nil -> %{state | combat_ref: nil}
    end
  end

  defp seed_combat_engaged do
    %{state: s} = Pokex.Bots.Combat.Worker.status()
    s in [:tabbing, :fighting]
  catch
    :exit, _reason -> false
  end

  defp now, do: System.monotonic_time(:millisecond)
end
