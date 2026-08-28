defmodule Pokex.Bots.PlayerSupport.Worker do
  @moduledoc """
  The player-SUPPORT worker: keeps the main Pokémon alive (survival combo at `:critical`, potion
  out of combat) independently of the fishing/combat bots. It reads the HP every tick, distributes
  it on the `"game"` PubSub topic, and acts when the respective toggles are enabled — so you can
  play MANUALLY, with every bot off, and still be protected.

  Lifecycle: auto-starts monitoring on boot, and — unlike the old always-on GameController — it IS
  part of Start/Stop and the PANIC CORNER halts it (Lucas: a stray reading must be killable by
  mouse-to-corner like everything else; re-arm via Iniciar bot or by touching a support toggle).
  It reloads the calibration each tick, so a fresh HP calibration takes effect without a restart.
  WHEN to revive is the `Engine`'s call (`orders.revive`, gated only by the `rescue_enabled`
  toggle); the pure `PlayerSupport.Logic` still owns HOW — the atomic combo, the heal/potion
  ladder above it, and the fallen/death detection, none of which the engine touches.
  """
  use GenServer

  alias Pokex.Bots.Body
  alias Pokex.Bots.Capture
  alias Pokex.Bots.Catcher.Worker
  alias Pokex.Bots.Combat.Loadout
  alias Pokex.Bots.Focus
  alias Pokex.Bots.{Logout, ReviveLedger, SkillClock}
  alias Pokex.Bots.SkillReceipt
  alias Pokex.Bots.InputGate
  alias Pokex.Bots.PlayerSupport.Logic
  alias Pokex.Calibration
  alias Pokex.Perception.Interpret
  alias Pokex.Perception.WorldState
  alias Pokex.Settings
  alias Pokex.Vision

  @topic "game"
  @default_counters %{rescues: 0, potions: 0, heals: 0, reads: 0, failures: 0, repositions: 0}

  def topic, do: @topic

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    state = %{
      body: Keyword.get(opts, :body, Body),
      # PORTA DE ENTRADA, como todo irmão desta família tem. O env estava sendo
      # lido CRU aqui dentro, então na suíte era impossível optar por voltar: o
      # arranque automático — a via que protege o jogador antes do preflight —
      # não tinha como ser exercitado em teste nenhum.
      auto_monitor?:
        Keyword.get(
          opts,
          :auto_monitor,
          Application.get_env(:pokex, :player_support_auto_monitor, true)
        ),
      timer: nil,
      # explicit lifecycle flag: a halt must stick even when a :tick was already in flight
      # (the timer fires before the cancel lands) — the flag, not the timer, decides.
      running?: false,
      hp_pct: nil,
      prev_hp_pct: nil,
      # A VIDA DO PERSONAGEM — a barra vermelha do painel "Pokémon", que apesar
      # do nome é dele, não do bicho. nil enquanto a região não for marcada na
      # calibração ou a leitura não reconhecer a barra.
      player_hp: nil,
      player_low_streak: 0,
      player_alarmed?: false,
      last_rescue_at: nil,
      # A ÚLTIMA VEZ QUE O CÉREBRO PEDIU UM REVIVE E A CHAVE DELE ESTAVA
      # DESLIGADA. Sem isto o pedido morre em silêncio: em 27/08 a engine pediu
      # 556 vezes num dia e nenhuma tecla saiu, porque `rescue_enabled` nasce
      # desligado e ninguém tinha por onde ver isso.
      last_switch_warn_at: nil,
      # true from the moment a combo is dispatched until {:rescue_done, _, _}
      # reports back — see act/2's re-entry guard.
      rescuing?: false,
      # DEATH is read from the bar's trajectory (Logic.fainted?/1): how many
      # reads in a row failed to find a bar, the last HP actually SEEN before
      # they did, and whether the fallen combo already went out for it.
      unreadable_streak: 0,
      last_seen_hp: nil,
      last_faint_at: nil,
      fainted?: false,
      last_potion_at: nil,
      # the pokémon's OWN healing skill — the rung above the potion, and the only
      # one that works while it is being hit
      last_heal_at: nil,
      # first monotonic ms of the CURRENT battle-free streak of potion-gate reads
      # (nil = last read saw combat, or the potion isn't due so nobody is watching)
      battle_clear_since: nil,
      # reposition: a battle was seen since the last reposition (something to undo)
      reposition_pending?: false,
      reposition_clear_since: nil,
      # post-fight order policy: the catcher's pending-corpse count from its
      # snapshots, and when THIS busy episode started (nil = catcher free) —
      # drives the support_waits_capture gate and its fail-open cap
      capture_pending: 0,
      capture_busy_since: nil,
      # last performed actuation as %{text, at} (monotonic ms; nil until the first) — panel-facing
      last_action: nil,
      # which guard, if any, stopped this tick from acting (nil = nothing was blocked)
      gate: nil,
      error: nil,
      counters: @default_counters
    }

    case name do
      nil -> GenServer.start_link(__MODULE__, state)
      name -> GenServer.start_link(__MODULE__, state, name: name)
    end
  end

  def status(server \\ __MODULE__), do: GenServer.call(server, :status)
  # Auto-starts on boot; run/halt participate in Start/Stop AND the panic fan-out. Both are
  # idempotent, so the panel toggles can call run/1 freely to re-arm after a panic.
  def run(server \\ __MODULE__), do: GenServer.call(server, :run)
  def halt(server \\ __MODULE__), do: GenServer.call(server, :halt)

  @doc """
  Manually drink a potion NOW — the panel button. Deliberate user intent, so no combat/threshold
  gates apply; it still stamps the cooldown so the automatic sip doesn't double up mid-channel.
  """
  def use_potion(server \\ __MODULE__), do: GenServer.call(server, :use_potion)

  @doc """
  Emergency escape: click-to-walk to the calibrated `escape_point` (a walkable
  tile BESIDE the staircase), wait out the walk, then arrow-step
  `escape_direction` × `escape_steps` to enter the stairs.
  :ok | {:error, :not_calibrated | :input_gated | term}.
  """
  def flee_to_escape(server \\ __MODULE__, timeout \\ 5_000),
    do: GenServer.call(server, :flee_to_escape, timeout)

  @impl true
  def init(state) do
    # The catcher's snapshots carry pending_corpses — the post-fight order
    # policy (support_waits_capture) reads it from here.
    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())

    # Auto-start monitoring on boot (real app). Gated off in the test env so the app-wide instance
    # doesn't tick against the shared Rig/home during unrelated tests — tests call run/1 to monitor.
    if state.auto_monitor?,
      do: {:ok, reschedule(%{state | running?: true}, 0)},
      else: {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, snapshot(state), state}

  def handle_call(:run, _from, state) do
    state = reschedule(%{state | running?: true}, 0)
    broadcast(state)
    {:reply, :ok, state}
  end

  def handle_call(:halt, _from, state) do
    state = cancel_timer(%{state | running?: false})
    broadcast(state)
    {:reply, :ok, state}
  end

  def handle_call(:use_potion, _from, state) do
    state = fire_potion(state, "🧪 poção (manual)")
    broadcast(state)
    {:reply, :ok, state}
  end

  # Emergency escape (Actions & Rules). Deliberate flee — bypasses thresholds
  # and combat logic, and FRONTS THE GAME first: the flee must work exactly
  # when the game is NOT focused (Lucas on the panel, or away — live finding
  # 2026-07-20: the focus gate swallowed the test click). The PANIC CORNER
  # still vetoes: the human kill switch outranks any flee. Rides :critical so
  # the WHOLE sequence enters the Body ahead of everything, atomically.
  def handle_call(:flee_to_escape, _from, state) do
    with {:ok, %Calibration{escape_point: point}} when is_tuple(point) <- Calibration.load(),
         :ok <- Focus.ensure_front() do
      # THE WALK GOES OFF THE LOOP, AND THIS ANSWERS AT ONCE.
      # `BotSupervisor.emergency_escape/1` is latch → flee → STOP THE FLEET, and
      # this used to sit inside `Body.perform` (which waits `:infinity`) for the
      # whole `escape_walk_wait_ms`. At his 5000 the sequence outlives the 5s
      # DEFAULT timeout of the caller's own `GenServer.call`: whoever ordered the
      # escape died of a timeout and `stop_all` NEVER RAN — the fleet kept
      # hunting beside the shiny that triggered the flee, with only the latch
      # (which forbids auto-resume, not actuation) standing.
      #
      # A safety path never waits on the fleeing party. `:ok` therefore means
      # "the escape LEFT", not "the character arrived"; the arrival is what the
      # log below announces, with its real outcome.
      #
      # UNLINKED on purpose: the halt that follows must not kill the walk.
      spawn(flee_walk(point, state.body))

      state = %{state | last_action: %{text: "fuga (escada)", at: now()}}
      broadcast(state)
      {:reply, :ok, state}
    else
      {:error, :panic_corner} -> {:reply, {:error, :panic_corner}, state}
      _no_point_or_no_calib -> {:reply, {:error, :not_calibrated}, state}
    end
  end

  defp flee_walk(point, body) do
    actions = flee_actions(point)
    steps = "#{Settings.get(:escape_steps)}× #{direction_label(escape_direction())}"

    fn ->
      case Body.perform(actions, :critical, body) do
        :ok ->
          broadcast_log(
            :macro,
            "🏃 fuga: andou até o tile calibrado e entrou na escada (#{steps})"
          )

        {:error, reason} ->
          broadcast_log(:macro, "🏃 fuga NÃO completou: #{inspect(reason)}")
      end
    end
  end

  @impl true
  # A late tick after a halt (the timer fired before the cancel landed) must NOT resurrect the
  # loop — the running? flag is the source of truth, not the timer.
  def handle_info(:tick, %{running?: false} = state), do: {:noreply, state}

  # While the fishing mini-game is being played, the Body is gated — this worker
  # cannot revive or potion anyway — so its HP capture every 120ms is pure waste
  # that queues ahead of the game's strip captures in the single serialized
  # broker and starves them (measured 2026-07-23: the game's cadence blew from
  # 80ms to ~250ms behind ~6 feed/support captures per 250ms). Skip the capture,
  # say so on the pill, and resume the instant the overlay clears.
  def handle_info(:tick, state) do
    if Pokex.Perception.mini_game_playing?() do
      handle_mini_game_tick(state)
    else
      run_tick(state)
    end
  end

  # The catcher's pending-corpse count rides its snapshots (see init/1). The
  # busy clock starts on the FIRST busy snapshot of an episode and never
  # refreshes mid-episode — that's what the fail-open cap measures.
  def handle_info({:catcher, snapshot}, state) do
    pending = Map.get(snapshot, :pending_corpses, 0)
    busy_since = if pending > 0, do: state.capture_busy_since || now(), else: nil
    {:noreply, %{state | capture_pending: pending, capture_busy_since: busy_since}}
  end

  # The rescue task reporting back (see fire_combo/2). Narrated even after a
  # halt — the attempt happened, and a revive that silently failed was exactly
  # the invisibility this message exists to end. The cooldown was stamped at
  # dispatch and stands either way: a dying-pokémon loop must never re-fire.
  def handle_info({:rescue_done, notes, outcome}, state) do
    drain_notes(notes)

    state =
      case outcome do
        :ok ->
          # O REVIVE ZERA TODOS OS COOLDOWNS (R3, medida no vídeo dele). Sem
          # isto o relógio das teclas seguraria por 45s uma barra que o jogo
          # acabou de devolver inteira — e a decisão que MAIS depende do relógio
          # é justamente a de gastar um revive pra zerar a barra.
          SkillClock.reset()
          broadcast_log(:macro, "🚑 revive despachado — as teclas saíram")
          %{state | last_action: %{text: "revive despachado", at: now()}}

        {:error, reason} ->
          Phoenix.PubSub.broadcast(
            Pokex.PubSub,
            @topic,
            {:rule_alarm, :hp,
             "🚑 o revive NÃO saiu (#{refusal_text(reason)}) — confere o pokémon"}
          )

          %{state | last_action: %{text: "revive recusado", at: now()}}
      end

    state = %{state | rescuing?: false}
    broadcast(state)
    {:noreply, state}
  end

  # The fallen revive reporting back. A refusal here is louder than the low-HP
  # one: with nobody on the field, "as teclas não saíram" means the character
  # is standing there alone.
  def handle_info({:fallen_done, :ok}, state) do
    broadcast_log(:macro, "💚 revive do caído despachado — ele volta pro campo")
    {:noreply, state}
  end

  def handle_info({:fallen_done, {:error, reason}}, state) do
    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      @topic,
      {:rule_alarm, :hp,
       "💀 o revive do caído NÃO saiu (#{refusal_text(reason)}) — sem pokémon em campo"}
    )

    {:noreply, state}
  end

  # The catcher topic also carries {:catcher_log, ...} chatter — not ours.
  def handle_info(_msg, state), do: {:noreply, state}

  # Nothing here can act (Body gated) and nothing reads our fact (peers frozen),
  # so we do NOT capture — that only starves the game's strip captures. Announce
  # once on the entering edge, then stay silent until the overlay clears.
  defp handle_mini_game_tick(state) do
    entered? = state.gate != :mini_game
    state = %{state | gate: :mini_game}
    if entered?, do: broadcast(state)
    {:noreply, reschedule(state, Settings.get(:support_tick_ms))}
  end

  defp run_tick(state) do
    previous = state

    state =
      case Calibration.load() do
        {:ok, calib} ->
          watch_player(
            case read_hp(calib) do
              {:ok, hp} ->
                publish_pokemon_fact(%{hp_pct: hp, readable?: true, fainted?: false})

                act(
                  %{
                    state
                    | prev_hp_pct: state.hp_pct,
                      hp_pct: hp,
                      error: nil,
                      # a bar that reads again is the proof he is back: the death
                      # trail resets, and only a NEW live reading can arm it
                      unreadable_streak: 0,
                      last_seen_hp: hp,
                      fainted?: false,
                      counters: bump(state.counters, :reads)
                  },
                  calib
                )

              # The region doesn't look like the bar (minimized party window, or no Pokémon
              # out of the ball): UNKNOWN — clear the reading so nothing can act on a
              # stale/garbage value, and say why in the panel. The fact says readable?: false,
              # which is exactly what the fishing gate treats as "sem pokémon ativo".
              # gate: nil here and below — these branches never reach act/2 (the
              # only other place that clears it), so a gate from a previous tick
              # used to survive the whole bad-reading stretch, explaining the
              # screen with a reason that already passed.
              :unrecognized ->
                state =
                  %{
                    state
                    | hp_pct: nil,
                      prev_hp_pct: nil,
                      gate: nil,
                      unreadable_streak: state.unreadable_streak + 1,
                      error: "barra de vida não reconhecida (janela do Pokémon minimizada?)"
                  }
                  |> maybe_revive_fallen()
                  |> maybe_retry_fallen()

                publish_pokemon_fact(%{
                  hp_pct: nil,
                  readable?: false,
                  fainted?: state.fainted?
                })

                state

              {:error, reason} ->
                fail(state, reason)
            end,
            calib
          )

        # The file exists but its numbers cannot be read (half-written, hand-edited,
        # an older schema). Says so rather than borrowing "sem calibração": that one
        # sends him to the wizard, and re-marking a screen does not repair a file
        # that is already corrupt on disk.
        {:error, {:calibracao_ilegivel, _reason}} ->
          %{state | hp_pct: nil, gate: nil, error: "calibração ilegível (arquivo corrompido?)"}

        # No calibration yet → nothing to read; keep monitoring so it starts the instant one exists.
        {:error, _reason} ->
          %{state | hp_pct: nil, gate: nil, error: "sem calibração"}
      end

    state = maybe_reposition(state)

    # Chatter guard: only push a snapshot when the HP reading or a counter actually moved, so the
    # tick doesn't flood the panel with identical frames.
    if changed?(previous, state), do: broadcast(state)

    {:noreply, reschedule(state, Settings.get(:support_tick_ms))}
  catch
    # The monitor that keeps him alive must not be killable by what it reads OR
    # by whom it calls. `read_hp/1` has been uncrashable since it was written;
    # the rest of the tick was not — and the rest of the tick includes three
    # `GenServer.call`s into the Body (potion, heal, reposition), which is the
    # exact shape the workspace rule forbids: a process that must survive never
    # depends on another answering. A Body restarting mid-perform used to take
    # this worker with it, and at a 120ms cadence three deaths in 360ms exhaust
    # BotSupervisor's default restart intensity, then the application's, and the
    # whole VM goes down (2026-08-27, via a raise in `Calibration.load/1`).
    #
    # Never silent: it lands on the panel as an error and bumps the failures
    # counter, the same surface a bad HP read uses. And it MUST reschedule — a
    # loop that stops without dying is worse than one that dies, because no
    # supervisor comes to restart it.
    kind, reason ->
      {:noreply,
       state
       |> fail({kind, reason})
       |> reschedule(Settings.get(:support_tick_ms))}
  end

  # --- a vida do PERSONAGEM ---------------------------------------------------
  #
  # A barra VERMELHA do painel "Pokémon" é a vida DELE, não do bicho — o nome do
  # painel é a armadilha que já custou dois dias de leitura errada (26/08). Até
  # 28/08 NINGUÉM olhava pra ela: o personagem apanha com o pokémon no chão (a
  # noite de 4,9h) e nada media, nada avisava, nada agia.
  #
  # A leitura usa os MESMOS leitores da Pokebar (`hp_region_plausible?` +
  # `hp_fill_pct`): o preenchimento vermelho é "quente" pro leitor de coluna do
  # mesmo jeito que o verde, o trilho vazio (56,71,71) é apagado, e o texto
  # 683/720 por cima já é descontado por desenho. Medido na foto real dele:
  # leitura 95% contra 683/720 = 94,9%.
  defp watch_player(state, calib) do
    case calib.player_hp_region do
      region when is_tuple(region) -> watch_player_at(state, region)
      _not_marked -> state
    end
  end

  defp watch_player_at(state, region) do
    case read_player_hp(region) do
      {:ok, hp} ->
        WorldState.put(:player, %{hp_pct: hp, readable?: true}, now())
        guard_player(%{state | player_hp: hp})

      _unreadable_or_error ->
        WorldState.put(:player, %{hp_pct: nil, readable?: false}, now())
        %{state | player_hp: nil, player_low_streak: 0}
    end
  end

  defp read_player_hp(region) do
    with {:ok, frame} <- Capture.frame(region, "player_hp.raw") do
      if Vision.hp_region_plausible?(frame,
           min_brightness: Settings.get(:pokemon_hp_min_brightness),
           min_saturation: Settings.get(:pokemon_hp_min_saturation),
           min_known_pct: Settings.get(:pokemon_hp_min_known_pct),
           min_bright_pct: Settings.get(:pokemon_hp_min_bright_pct),
           max_track_brightness: Settings.get(:pokemon_hp_max_track_brightness)
         ) do
        {:ok, Vision.hp_fill_pct(frame)}
      else
        :unrecognized
      end
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  # O GUARDIÃO: duas leituras seguidas abaixo do piso — nunca um frame só, a
  # mesma disciplina que protege o revive — e ele grita UMA vez por episódio.
  # O episódio fecha quando a vida volta acima do piso com folga de 10 pontos,
  # pra barra oscilando no piso não virar sirene intermitente.
  #
  # A ação forte é opcional (`player_hp_logout`): o logout é o único socorro
  # que o jogo dá pro personagem — sem pokémon em pé, fugir andando só muda
  # onde ele apanha.
  defp guard_player(state) do
    floor = Settings.get(:player_hp_floor_pct)

    cond do
      not is_integer(floor) or floor <= 0 ->
        %{state | player_low_streak: 0, player_alarmed?: false}

      state.player_hp >= floor + 10 ->
        %{state | player_low_streak: 0, player_alarmed?: false}

      state.player_hp >= floor ->
        %{state | player_low_streak: 0}

      true ->
        player_low(%{state | player_low_streak: state.player_low_streak + 1})
    end
  end

  defp player_low(%{player_low_streak: streak, player_alarmed?: false} = state)
       when streak >= 2 do
    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      @topic,
      {:rule_alarm, :hp,
       "⚠️ VOCÊ está com #{state.player_hp}% de vida — o personagem, não o pokémon"}
    )

    broadcast_log(
      :macro,
      "⚠️ a vida do PERSONAGEM caiu a #{state.player_hp}% — " <>
        if(Settings.get(:player_hp_logout),
          do: "pedindo LOGOUT agora",
          else: "confere o jogo (ligue player_hp_logout pra ele sair sozinho)"
        )
    )

    if Settings.get(:player_hp_logout),
      do: Logout.request("vida do personagem em #{state.player_hp}%")

    %{state | player_alarmed?: true}
  end

  defp player_low(state), do: state

  # Uncrashable: this monitor runs forever, so a transient capture failure (the broker or the Rig
  # momentarily down/restarting) must come back as {:error}, not take the whole worker down with it.
  defp read_hp(calib) do
    region = Calibration.pokemon_hp_region(calib)
    min_b = Settings.get(:pokemon_hp_min_brightness)
    min_s = Settings.get(:pokemon_hp_min_saturation)

    with {:ok, frame} <- Capture.frame(region, "pokemon_hp.raw") do
      # A frame that doesn't LOOK like the bar (party window minimized → the region shows game
      # world) is UNKNOWN, not a reading: a garbage fill% here read as "low HP" and fired the
      # combo in an open/close loop, burning potions and revives.
      if Vision.hp_region_plausible?(frame,
           min_brightness: min_b,
           min_saturation: min_s,
           min_known_pct: Settings.get(:pokemon_hp_min_known_pct),
           min_bright_pct: Settings.get(:pokemon_hp_min_bright_pct),
           max_track_brightness: Settings.get(:pokemon_hp_max_track_brightness)
         ) do
        {:ok,
         normalize_hp(Vision.hp_fill_pct(frame, min_brightness: min_b, min_saturation: min_s))}
      else
        :unrecognized
      end
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  # The bar's rounded tips eat the last columns of the box, so the raw fill plateaus below
  # 100 at genuinely full health (Lucas's: 95). Rescale so "full raw" reads — and gates — as
  # 100%; everything below scales proportionally.
  defp normalize_hp(raw) do
    case Settings.get(:pokemon_hp_full_at_pct) do
      full when is_integer(full) and full > 0 and full < 100 ->
        min(100, round(raw * 100 / full))

      _ ->
        raw
    end
  end

  # The always-on monitor keeps READING the HP even while actuation is gated (so the panel and
  # the resume are accurate), but it never ACTS through a closed gate: the panic corner and a
  # defocused game must stop revive AND potion, not just have the Rig silently swallow them.
  defp act(state, calib) do
    if InputGate.allowed?() do
      # rescuing? guards re-entry while the LAST combo is still in flight — the
      # engine's own orders naturally drop revive: :now once it enters
      # :recovering, but that transition costs one of ITS ticks, which can be
      # slower than this worker's, so a fresh fact can still read :now for one
      # tick after a combo has already been dispatched (measured 2026-08-17
      # writing this PR's tests: without this, the escalation/stun tests fired
      # the combo twice, mid-sequence).
      state = unlatch_stale_rescue(state)

      if not state.rescuing? and revive_decision(state) == :rescue do
        fire_rescue(%{state | gate: nil})
      else
        %{state | gate: nil} |> warn_switch_off() |> maybe_heal_skill() |> maybe_potion(calib)
      end
    else
      # Everything this worker exists for is blocked here, and until now the ONLY
      # sign was a small badge in the panel header. "revive is on and nothing
      # happened" is unanswerable when the closed gate is invisible: name it.
      %{state | gate: closed_gate()}
    end
  end

  # O PEDIDO QUE MORRE NA CHAVE. `rescue_enabled` é a mão dele no interruptor e
  # continua vencendo o cérebro — mas um cérebro pedindo revive contra uma chave
  # desligada é a coisa mais cara que este bot faz em silêncio: em 27/08 a
  # engine pediu 556 vezes num dia inteiro e nenhuma tecla saiu.
  #
  # Um aviso a cada cinco minutos, e só quando o pedido é de AGORA: barulho de
  # tique a tique seria a mesma invisibilidade com outro nome.
  @switch_warn_every_ms 300_000
  defp warn_switch_off(state) do
    if engine_revive() == :now and not Settings.get(:rescue_enabled) and
         switch_warn_due?(state) do
      Phoenix.PubSub.broadcast(
        Pokex.PubSub,
        @topic,
        {:rule_alarm, :hp,
         "o cérebro pediu revive e a chave está DESLIGADA — ligue “revive automático” " <>
           "no /config, senão nenhuma regra de revive sai do papel"}
      )

      %{state | last_switch_warn_at: now()}
    else
      state
    end
  end

  defp switch_warn_due?(%{last_switch_warn_at: nil}), do: true

  defp switch_warn_due?(%{last_switch_warn_at: at}),
    do: now() - at >= @switch_warn_every_ms

  # The pokémon FELL. Nothing is on the field, which means the character is the
  # one taking the hits — so this is the shortest path in the whole module:
  # portrait, max revive, out. No stun (there is nobody left to protect), no
  # settle (every ms is exposure), and the hands go to a task like every other
  # actuation so the monitor keeps answering `:halt` (2026-08-14).
  #
  # `last_seen_hp: nil` afterwards is the anti-loop: the next revive costs a
  # fresh sighting of a LIVE bar, so a pokémon simply stored in its ball can
  # never drain the stock.
  # THE F4 PUTS THE POKÉMON IN ITS BALL, so the unreadable ticks right after a
  # revive are the RESULT of that revive, not a death. Two of them (240ms) plus
  # the sub-35 reading that ORDERED this very revive were enough for the fallen
  # path to declare a death and fire a SECOND revive — this one with no stun
  # prefix, recalling the pokémon again in front of a wide-awake pile, which is
  # exactly what `rescue_stun_first` exists to prevent.
  #
  # The two cases are indistinguishable on screen, so this does not decide
  # between them: it WAITS. The number is the engine's own
  # `engine_revive_confirm_ms` on purpose, not a new one — "the ordinary reason
  # to be off the field is a revive already in flight, and how long one takes to
  # show itself" is a question the brain already answered, and hands that keep a
  # different clock from the brain is the bug behind every wrong number in this
  # subsystem so far. Past that window the bar is STILL gone, the revive
  # provably did not land, and the fallen path is right to fire.
  defp fresh_rescue?(%{last_rescue_at: at}) when is_integer(at),
    do: now() - at < Settings.get(:engine_revive_confirm_ms)

  defp fresh_rescue?(_never_rescued), do: false

  defp maybe_revive_fallen(state) do
    if InputGate.allowed?() and not fresh_rescue?(state) and Logic.fainted?(faint_input(state)) do
      at = now()
      dispatch_fallen(state.body)

      broadcast_log(:macro, "💀 o pokémon caiu — revive na hora (#{state.last_seen_hp}% e sumiu)")

      %{
        state
        | fainted?: true,
          last_faint_at: at,
          last_seen_hp: nil,
          unreadable_streak: 0,
          counters: bump(state.counters, :rescues),
          last_action: %{text: "revive do caído", at: at}
      }
    else
      state
    end
  end

  defp dispatch_fallen(body) do
    worker = self()
    actions = Logic.revive(revive_config())
    ReviveLedger.note()

    spawn(fn ->
      send(worker, {:fallen_done, Body.perform(actions, :critical, body)})
    end)
  end

  # The fallen revive fires exactly ONCE per death — `last_seen_hp: nil`
  # afterwards is the anti-loop that stops a pokemon merely stored in its ball
  # from draining the stock overnight, and it stays. What it cost was the other
  # half: a revive that did not LAND ended the night, because nothing ever asked
  # a second time.
  #
  # The engine is what can ask. It is the only thing watching whether a body
  # ever came back (`Logic`'s `:downed`), and it asks on its own floor. So a
  # RETRY is allowed here — never a first press — under three conditions: the
  # fall was already proven by this worker, the engine is asking right now, and
  # the same floor a first fallen revive keeps has passed.
  defp maybe_retry_fallen(%{fainted?: true} = state) do
    if InputGate.allowed?() and Settings.get(:rescue_enabled) and engine_revive() == :now and
         fallen_floor_elapsed?(state) do
      at = now()
      dispatch_fallen(state.body)
      broadcast_log(:macro, "💀 ele segue no chão e o cérebro insiste — revive de novo")

      %{
        state
        | last_faint_at: at,
          counters: bump(state.counters, :rescues),
          last_action: %{text: "revive do caído (de novo)", at: at}
      }
    else
      state
    end
  end

  defp maybe_retry_fallen(state), do: state

  defp fallen_floor_elapsed?(%{last_faint_at: nil}), do: false

  defp fallen_floor_elapsed?(%{last_faint_at: at}),
    do: now() - at >= Settings.get(:fainted_revive_cooldown_ms)

  defp faint_input(state) do
    %{
      enabled?: Settings.get(:rescue_enabled),
      unreadable_streak: state.unreadable_streak,
      last_seen_hp: state.last_seen_hp,
      faint_below_pct: Settings.get(:pokemon_hp_fainted_below_pct),
      cooldown_ms: Settings.get(:fainted_revive_cooldown_ms),
      last_faint_at: state.last_faint_at,
      now: now()
    }
  end

  # WHICH guard is closed — they mean very different things to the human: one is
  # "get back into the game", the other is "you told it to stop yourself".
  defp closed_gate do
    case InputGate.state() do
      %{corner_ok: false} -> :panic_corner
      %{focus_ok: false} -> :unfocused
      _both_open -> nil
    end
  end

  # The rung ABOVE the potion, and the only one that works mid-fight.
  #
  # No combat gate on purpose: the potion is a channel the game cancels the
  # moment something hits, which is why it only ever fires out of battle — and
  # that leaves HP falling DURING a fight with nothing between the full bar and
  # the revive. A skill is one press.
  #
  # WHICH key comes from `/time` (the `:heal` job of whoever is on the field), so
  # a pokémon with none classified simply never gets here. Cooling keys are
  # dropped against the bar and fail OPEN when there is no reading: a cooling key
  # is a no-op in game, and holding a heal waiting for a read costs HP.
  defp maybe_heal_skill(state) do
    with true <- Logic.heal_wanted?(heal_input(state)),
         [_ | _] = keys <- ready_heal_keys() do
      broadcast_log(
        :macro,
        "💚 cura do pokémon: #{Enum.join(keys, ", ")} (vida em #{state.hp_pct}%)"
      )

      # The cooldown is stamped either way — a refused press must not
      # machine-gun the queue — but the refusal is SAID: an announced heal
      # that never landed used to be indistinguishable from one that did.
      case Body.perform(Enum.map(keys, &{:press, &1}), :high, state.body) do
        :ok -> :ok
        {:error, reason} -> broadcast_log(:macro, "💚 a cura não saiu (#{refusal_text(reason)})")
      end

      %{state | last_heal_at: now(), counters: bump(state.counters, :heals)}
    else
      _no_heal_or_all_cooling -> state
    end
  end

  defp ready_heal_keys do
    case Loadout.current() do
      nil -> []
      loadout -> ready_only(loadout.heal)
    end
  end

  defp ready_only(keys) do
    case Pokex.Perception.ready_skills() do
      ready when is_list(ready) and ready != [] -> Enum.filter(keys, &(&1 in ready))
      _no_reading -> keys
    end
  end

  defp heal_input(state) do
    %{
      hp_pct: state.hp_pct,
      prev_hp_pct: state.prev_hp_pct,
      threshold_pct: Settings.get(:pokemon_hp_heal_pct),
      enabled?: Settings.get(:heal_skill_enabled),
      cooldown_ms: Settings.get(:heal_skill_cooldown_ms),
      last_heal_at: state.last_heal_at,
      now: now()
    }
  end

  # The combat read costs a screen capture, so it only happens when a potion is otherwise due.
  # ONE clear read is NOT "out of battle": fished enemies re-aggress in the post-kill gap and
  # the game cancels the heal channel, wasting the potion (Lucas, live 2026-07-20) — so the
  # potion only fires after a CONTINUOUS battle-free window (potion_battle_clear_ms). Any
  # in-combat/unknown read — or the potion not being due — resets the streak.
  defp maybe_potion(state, calib) do
    if Logic.potion_wanted?(potion_input(state)) do
      case interrupt?(state, calib) do
        {:ok, false} ->
          potion_after_clear_window(state)

        # The sip is DUE and the read says a heal would be interrupted. Without
        # this the panel showed nothing while a potion sat blocked (measured
        # 2026-07-22: HP 32%, potion on, zero sips, hold_reason nil).
        _interrupted_or_unknown ->
          %{state | battle_clear_since: nil, gate: :potion_in_combat}
      end
    else
      %{state | battle_clear_since: nil}
    end
  end

  # After every battle, send the Pokémon back to its calibrated strategic tile with a
  # MIDDLE click (the game's "step here" command) — battles drag it off the spot where
  # it hits several enemies at once. Same battle-clear caution as the potion, on its
  # own window/clock: battle presence comes from the :battle fact (a free ETS read),
  # so no combat running = no battles seen = nothing to undo. The click needs the
  # native key-event helper (cliclick has no middle button); a failed click keeps
  # reposition_pending? so the next clear window retries.
  #
  # Only while STANDING. The calibrated tile is his fishing spot: walking, this
  # would middle-click him back to it after every fight and undo the whole trip.
  # The mode bundle switches the setting off when he moves, but the check lives
  # here too — the worker must not depend on the panel having applied a preset.
  defp maybe_reposition(state) do
    with "still" <- Settings.get(:player_mode),
         true <- Settings.get(:reposition_enabled),
         {:ok, %Calibration{pokemon_spot_point: point}} when is_tuple(point) <-
           Calibration.load(),
         true <- InputGate.allowed?() do
      case battle_now() do
        :engaged -> %{state | reposition_pending?: true, reposition_clear_since: nil}
        :clear -> reposition_after_clear_window(state, point)
        :unknown -> state
      end
    else
      _off_or_uncalibrated_or_gated -> state
    end
  end

  defp battle_now do
    case WorldState.get(:battle, Settings.get(:combat_world_max_age_ms), now()) do
      {:ok, obs} -> if engaged?(obs), do: :engaged, else: :clear
      _stale_or_missing -> :unknown
    end
  end

  defp reposition_after_clear_window(%{reposition_pending?: false} = state, _point), do: state

  defp reposition_after_clear_window(state, point) do
    at = now()
    since = state.reposition_clear_since || at
    state = %{state | reposition_clear_since: since}

    cond do
      at - since < Settings.get(:reposition_battle_clear_ms) ->
        state

      # post-fight order policy — same wait as the potion, same fail-open cap
      capture_busy?(state) ->
        state

      true ->
        do_reposition(state, point, at)
    end
  end

  # Clicking ON a ladder USES it, and using only works when adjacent (Lucas,
  # live 2026-07-20) — so the flee is: click-walk to the calibrated APPROACH
  # tile, wait the walk out, then arrow-step INTO the staircase. One atomic
  # perform: nothing can interleave mid-flee.
  @escape_step_gap_ms 300

  defp flee_actions(point) do
    steps = max(Settings.get(:escape_steps), 1)

    arrow_steps =
      [{:press, escape_direction()}]
      |> List.duplicate(steps)
      |> Enum.intersperse([{:wait, @escape_step_gap_ms}])
      |> List.flatten()

    [{:click, :left, point}, {:wait, Settings.get(:escape_walk_wait_ms)}] ++ arrow_steps
  end

  # The arrow names map to REAL key events on both Rig paths (Commands'
  # @named_keycodes serves the native helper too). Corrupt value → right.
  defp escape_direction do
    case Settings.get(:escape_direction) do
      dir when dir in ["left", "right", "up", "down"] -> dir
      _corrupt -> "right"
    end
  end

  defp direction_label("left"), do: "esquerda"
  defp direction_label("right"), do: "direita"
  defp direction_label("up"), do: "cima"
  defp direction_label("down"), do: "baixo"

  # through the Body like every mouse action (serialization, cursor restore,
  # mini-game gate); :normal priority — positioning never preempts anything
  defp do_reposition(state, point, at) do
    case Body.perform([{:click, :middle, point}], :normal, state.body) do
      :ok ->
        broadcast_log(:macro, "🐾 pokémon reposicionado no ponto calibrado")

        %{
          state
          | reposition_pending?: false,
            reposition_clear_since: nil,
            counters: bump(state.counters, :repositions),
            last_action: %{text: "reposição (clique do meio)", at: at}
        }

      {:error, reason} ->
        broadcast_log(:debug, "reposicionar falhou (helper nativo?): #{inspect(reason)}")
        %{state | reposition_clear_since: nil}
    end
  end

  defp potion_after_clear_window(state) do
    at = now()
    since = state.battle_clear_since || at
    state = %{state | battle_clear_since: since}

    cond do
      at - since < Settings.get(:potion_battle_clear_ms) ->
        state

      # post-fight order policy: the window elapsed but the catcher still has
      # corpse work — keep the satisfied clock and sip the moment it frees up
      capture_busy?(state) ->
        state

      true ->
        %{fire_potion(state, "🧪 poção — vida em #{state.hp_pct}%") | battle_clear_since: nil}
    end
  end

  defp potion_input(state) do
    %{
      hp_pct: state.hp_pct,
      prev_hp_pct: state.prev_hp_pct,
      threshold_pct: Settings.get(:pokemon_hp_potion_pct),
      enabled?: Settings.get(:potion_enabled),
      cooldown_ms: Settings.get(:potion_cooldown_ms),
      last_potion_at: state.last_potion_at,
      now: now()
    }
  end

  # Would a heal be interrupted right now? Only that question matters for the
  # potion — a sip drunk mid-interrupt is wasted.
  #
  # The trigger is DAMAGE, and damage has two readable faces:
  #   * a lock ring — a selected target, i.e. a fight you are trading blows in;
  #   * the player's own HP DROPPING since the last read — the direct proof that
  #     something is hitting you, which is exactly the re-aggro the old rule was
  #     built for (a fished enemy attacks in the post-kill gap, no ring yet).
  #
  # The OLD rule counted "any enemy row in the battle list" as combat. But
  # hunting means an enemy is listed essentially always, so the potion NEVER
  # fired while hunting (measured 2026-07-22: enemy listed, not locked, nothing
  # attacking → zero sips forever). A creature merely on screen is not damage;
  # the two faces above are. The skill-bar cooldown would be a third face, but
  # its feed is demand-driven and absent during manual play — the very case this
  # worker protects — so it is deliberately not used here.
  #
  # The :battle feed interprets the ring/list every ~120ms while combat runs —
  # read the blackboard first (zero extra capture); fall back to a direct
  # capture+interpret when the entry is stale/missing (manual play, bots off).
  defp interrupt?(state, calib) do
    if taking_damage?(state) do
      {:ok, true}
    else
      case WorldState.get(:battle, Settings.get(:combat_world_max_age_ms), now()) do
        {:ok, obs} -> {:ok, locked?(obs)}
        _stale_or_missing -> direct_battle_read(calib)
      end
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  # A confirmed drop, not a single garbage frame: prev and current are both real
  # readings (the reader clears both to nil on an unrecognized bar), and any drop
  # only RESETS the clear window — the fail-safe direction, so a spurious dip
  # costs one delayed sip, never a missed interrupt.
  defp taking_damage?(%{hp_pct: hp, prev_hp_pct: prev})
       when is_integer(hp) and is_integer(prev),
       do: hp < prev

  defp taking_damage?(_no_pair), do: false

  defp direct_battle_read(calib) do
    with {:ok, frame} <- Capture.frame(calib.battle_region, "potion_battle.raw") do
      {:ok, locked?(Interpret.battle(frame, calib, Settings.all()))}
    end
  end

  defp locked?(obs), do: obs[:locked?] == true

  # Reposition keeps the BROADER notion — "any enemy nearby" — on purpose: it
  # sends the Pokémon back to its tile only when things are truly quiet, and a
  # listed-but-unlocked creature is still a reason not to walk into it. Only the
  # POTION gate narrowed to lock-ring-or-damage; the two answer different
  # questions ("would a heal be wasted?" vs "is it safe to walk?").
  defp engaged?(obs), do: obs[:locked?] == true or (obs[:enemies] || []) != []

  # Stamp last_potion_at BEFORE dispatch (same rationale as the combo): if the press errors, the
  # cooldown still holds and a glitch loop can't chug the whole potion stack.
  defp fire_potion(state, log_text) do
    at = now()
    Body.perform([{:press, Settings.get(:potion_key)}], :high, state.body)

    state = %{
      state
      | last_potion_at: at,
        counters: bump(state.counters, :potions),
        last_action: %{text: "poção", at: at}
    }

    broadcast_log(:macro, log_text)
    state
  end

  # THE ENGINE IS THE ONLY VOICE on WHEN it is tactically worth reviving — the
  # whole point of R3: a health percentage alone cannot tell a live pile with
  # every cooldown up from a cleared one with nothing left, and the old ladder
  # only ever asked the first question. "quem manda ser tomada uma poção ou
  # reviver um pokémon não deveria ser só um observador da vida, puramente"
  # (Lucas, 2026-08-17).
  #
  # `rescue_enabled` is checked FIRST and outside the engine's reach on
  # purpose: it is his own hand on the switch, and no amount of "the engine
  # says now" may override a toggle he turned off. Past that, the engine's
  # answer is obeyed literally in both directions, and a stale/missing fact
  # holds rather than guessing — including while fishing, where `hunt: nil`
  # still bands on HP and answers `:now` on yellow/red (see
  # `Engine.Logic`'s "No hunt does not mean no pokémon"), so there is no
  # health band left that only the old ladder could see.
  #
  # `rescue_cooldown_ms` still floors the PACE, independent of the tactics:
  # his own dial, still visible and editable in the panel, and a second net
  # under the engine's own — a real cooldown even if the engine's judgment on
  # WHEN it is worth reviving ever misfires into asking twice too close
  # together.
  defp revive_decision(state) do
    cond do
      not Settings.get(:rescue_enabled) -> :hold
      engine_revive() != :now -> :hold
      cooldown_elapsed?(state) -> :rescue
      true -> :hold
    end
  end

  defp cooldown_elapsed?(%{last_rescue_at: nil}), do: true

  defp cooldown_elapsed?(%{last_rescue_at: last}),
    do: now() - last >= Settings.get(:rescue_cooldown_ms)

  defp engine_revive do
    case WorldState.get(:orders, Settings.get(:engine_orders_max_age_ms), now()) do
      {:ok, %{revive: revive}} -> revive
      _stale_or_missing -> nil
    end
  end

  # Mark the attempt time BEFORE dispatching, so the cooldown holds even if the combo errors —
  # a dying-Pokémon loop must never re-fire and burn the expensive revives.
  #
  # The belt to the task's suspenders: a rescue still marked in-flight this long
  # after it was dispatched is not coming back, whatever swallowed its report.
  # The combo is a stun receipt (`rescue_confirm_ms`) plus a settle plus one
  # `Body.perform`; a minute is far past every one of them and still far below
  # "the night is over".
  @rescue_latch_max_ms 60_000

  defp unlatch_stale_rescue(%{rescuing?: true, last_rescue_at: at} = state)
       when is_integer(at) do
    if now() - at > @rescue_latch_max_ms do
      broadcast_log(:macro, "🚑 resgate sem resposta há um minuto — destravando")
      %{state | rescuing?: false}
    else
      state
    end
  end

  defp unlatch_stale_rescue(state), do: state

  # The HANDS are a spawned task's, never this GenServer's: the stun receipt
  # sleeps up to `rescue_confirm_ms` and the Body call waits `:infinity`, and
  # run inside the tick they made the worker deaf for longer than safe_halt's
  # 1s — a panic mid-rescue timed out halting the one worker guarding the
  # player. The task reports back as {:rescue_done, notes, outcome}, where a
  # refused revive finally gets NAMED instead of burning the cooldown mutely.
  defp fire_rescue(state) do
    at = now()
    {stun_steps, notes} = rescue_stun_steps()
    dispatch_rescue(state.body, stun_steps)
    drain_notes(notes)
    ReviveLedger.note()
    broadcast_log(:macro, "🚑 revive — Pokémon com #{state.hp_pct}% de vida")

    %{
      state
      | last_rescue_at: at,
        rescuing?: true,
        counters: bump(state.counters, :rescues),
        last_action: %{text: "revive", at: at}
    }
  end

  # Unlinked on purpose: a Body crash mid-rescue must not take the monitor
  # down with it — the next tick still reads the bar, and the cooldown
  # already stamped keeps the loop from re-firing.
  #
  # And it ALWAYS reports. `{:rescue_done, _, _}` is the only thing that
  # clears `rescuing?`, so a task that dies without sending it turns the
  # low-HP rescue off FOREVER: the flag is process state, nothing else writes
  # it, and the supervisor is `:one_for_one`, so neither Parar+Iniciar nor the
  # panic corner recovers. The way it dies is ordinary — the task parks inside
  # `Body.perform` (`:infinity`) and the Body goes down, so the `GenServer.call`
  # exits. Potion and heal keep firing, the panel looks healthy, and every
  # emergency after that costs a pokémon. A lost message must never be able to
  # switch off a safety path.
  defp dispatch_rescue(body, stun_steps) do
    worker = self()

    spawn(fn ->
      {notes, outcome} =
        try do
          {notes, settle_ms} = crowd_control(body, stun_steps)
          actions = Logic.revive(Map.put(revive_config(), :settle_ms, settle_ms))
          {notes, Body.perform(actions, :critical, body)}
        catch
          kind, reason -> {[], {:error, {:crashed, kind, reason}}}
        end

      send(worker, {:rescue_done, notes, outcome})
    end)
  end

  defp drain_notes(notes) do
    Enum.each(notes, fn
      {:alarm, text} -> Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:rule_alarm, :hp, text})
      {:log, text} -> broadcast_log(:macro, text)
    end)
  end

  defp refusal_text(:input_gate_closed), do: "jogo sem foco ou pânico — nada é pressionado"
  defp refusal_text(reason), do: inspect(reason)

  # The crowd control goes out FIRST, ALONE, and is CONFIRMED before the
  # pokémon leaves the field.
  #
  # "Eu uso geralmente as skills 1 e 2 para justamente silenciar os pokémons ao
  # redor, colocar eles para dormir, e aí, sim, eu tiro meu Pokémon de campo"
  # (Lucas, 2026-08-11). Riding inside the same atomic sequence as the recall,
  # the stun could silently not land — unfocused window, shut gate, no mana —
  # and the recall would strip the field anyway, in front of everything, wide
  # awake. The receipt is the cooldown (`Pokex.Bots.SkillReceipt`): a skill
  # that fired is no longer ready.
  #
  # Splitting the sequence does NOT widen the exposure: the pokémon is still
  # out, still tanking, while the confirmation is read. What it costs is one
  # skill-bar reading, and what it buys is knowing. Runs INSIDE the rescue
  # task (see dispatch_rescue/3) — the receipt wait belongs to the hands, not
  # to the monitor's loop.
  #
  # The receipt is NOT the sleep, and reading it as such is what nearly killed
  # the character on 2026-08-14: the cooldown starts the instant the key goes
  # out, so the confirmation came back in ~100ms and the recall stripped the
  # field while the pile was still awake. So the answer carries what is LEFT
  # of the settle, and the revive waits it out (see `Logic.combo/1`).
  defp crowd_control(_body, []), do: {[], 0}

  defp crowd_control(body, stun_steps) do
    keys = for {:press, key} <- stun_steps, do: key
    {verdict, at} = fire_and_confirm(body, stun_steps, keys)

    case verdict do
      # NOTHING went out. Leaving now would empty the field in front of a pile
      # that is wide awake, with skills still in hand — so everything he has
      # left is tried first, and the settle is recounted from THAT press.
      {:missed, _} ->
        {extra_notes, extra_settle} = last_resort(body, keys)
        {stun_note(verdict, keys, 0) ++ extra_notes, extra_settle}

      _landed_or_unreadable ->
        settle = settle_remaining(at)
        {stun_note(verdict, keys, settle), settle}
    end
  end

  defp fire_and_confirm(body, steps, keys) do
    before = Pokex.Perception.ready_skills()
    at = now()

    Body.perform(steps, :critical, body)

    later = Pokex.Perception.ready_skills_after(at, Settings.get(:rescue_confirm_ms))

    {SkillReceipt.verdict(SkillReceipt.check(before, later, keys)), at}
  end

  # The escalation Lucas asked for (2026-08-14): another control key may still
  # put the pile down, and plain damage may simply end it. With nothing left to
  # press there is nothing to wait for either — recall AT ONCE, because from
  # there on the clock only costs the pokémon's HP.
  defp last_resort(body, tried) do
    keys = Logic.last_resort_keys(Loadout.current(), tried, Pokex.Perception.ready_skills())

    if keys == [] do
      {[log: "🚑 não sobrou skill pra tentar — recolhendo agora"], 0}
    else
      {verdict, at} = fire_and_confirm(body, Enum.map(keys, &{:press, &1}), keys)

      case verdict do
        {:missed, _still_nothing} ->
          {[alarm: "🚑 nem #{Enum.join(keys, ", ")} saiu — recolhendo exposto"], 0}

        _landed_or_unreadable ->
          settle = settle_remaining(at)
          {[log: "🚑 última cartada: #{Enum.join(keys, ", ")}#{settle_text(settle)}"], settle}
      end
    end
  end

  # What is LEFT of the sleep's landing time, counted from the PRESS — the
  # confirmation already spent part of it, and charging the full settle again
  # would keep a low-HP pokémon on the field for nothing.
  defp settle_remaining(pressed_at),
    do: max(Settings.get(:rescue_stun_settle_ms) - (now() - pressed_at), 0)

  # Every outcome still ends in a revive — a pokémon left dead is worse than a
  # pokémon revived in the open, and that was already this module's rule
  # ("fail in the direction of SAVING"). What changes is that a stun that did
  # not land now SAYS SO, loudly, instead of being assumed.
  defp stun_note(:confirmed, keys, settle),
    do: [
      log:
        "🚑 stun confirmado (#{Enum.join(keys, ", ")})#{settle_text(settle)} — aí sim tiro o pokémon"
    ]

  defp stun_note({:missed, missed}, _keys, _settle),
    do: [
      alarm: "🚑 o stun NÃO saiu (#{Enum.join(missed, ", ")}) — revivendo exposto, confere o jogo"
    ]

  defp stun_note(:unconfirmed, _keys, settle),
    do: [
      log:
        "🚑 não consegui confirmar o stun (barra ilegível)#{settle_text(settle)} — revivendo assim mesmo"
    ]

  defp settle_text(0), do: ""
  defp settle_text(ms), do: ", esperando #{ms}ms o bolo dormir"

  # The STUN prefix: the on-field pokémon's own control keys, pressed and
  # CONFIRMED before it leaves. Off by default — this client's revive is one
  # key and the field empties for a moment only (Lucas, 2026-08-24), so the
  # prefix costs a confirmation wait that the pokémon may not have to spare.
  # Turn it on and the hunt pays that wait to have the pile asleep first.
  #
  # "Ele não está usando a skill 1, que seria a skill guardada para reviver, e
  # a skill de stun (…) eu morri já por culpa disso!" (Lucas, 2026-08-14).
  # Combat RESERVES `loadout.crowd` from every ordinary fight for exactly this
  # moment (`Strategy.reserved/1`, and /time labels the key that way) — a key
  # reserved by everyone and pressed by nobody was the bug. Every failure still
  # falls toward SAVING: no control ready, no prefix, and the revive happens.
  defp rescue_stun_steps do
    if Settings.get(:rescue_stun_first), do: control_stun(), else: {[], []}
  end

  defp control_stun do
    case ready_control_keys() do
      [] ->
        {[], [log: "🚑 sem controle pronto no pokémon — revivendo direto"]}

      keys ->
        {elem(Logic.stun_prefix(Enum.map(keys, &{:skill, &1}), nil), 0),
         [log: "🚑 stun do resgate: #{Enum.join(keys, ", ")} — o controle guardado no /time"]}
    end
  end

  defp ready_control_keys do
    case Loadout.current() do
      nil -> []
      loadout -> ready_only(loadout.crowd)
    end
  end

  defp revive_config,
    do: %{rescue_key: Settings.get(:rescue_key), step_ms: Settings.get(:rescue_step_ms)}

  # A failed read also resets the consecutive-low guard: after a gap we demand two FRESH
  # agreeing reads before acting again (garbage often comes in bursts around failures).
  defp fail(state, reason) do
    broadcast_log(:debug, "erro ao ler a vida: #{inspect(reason)}")

    %{
      state
      | prev_hp_pct: nil,
        gate: nil,
        error: inspect(reason),
        counters: bump(state.counters, :failures)
    }
  end

  defp changed?(previous, state),
    do:
      previous.hp_pct != state.hp_pct or previous.counters != state.counters or
        hold_reason(previous) != hold_reason(state) or
        previous.last_action != state.last_action

  defp bump(counters, key), do: Map.update!(counters, key, &(&1 + 1))

  # Real lifecycle state, not a constant: the panel's Suporte card shows whether the monitor is
  # actually ticking (a panic/Stop halts it → :idle until re-armed).
  defp snapshot(state),
    do: %{
      state: if(state.running?, do: :monitoring, else: :idle),
      hp_pct: state.hp_pct,
      player_hp: state.player_hp,
      enabled?: Settings.get(:rescue_enabled),
      last_rescue_at: state.last_rescue_at,
      counters: state.counters,
      error: state.error,
      hold_reason: hold_reason(state),
      last_action: state.last_action
    }

  # The support worker's "why am I waiting". A closed GATE comes first — it
  # blocks everything, so the clock reasons behind it are noise. Then each armed
  # clear-window clock; both waiting at once join in one text. nil = nothing
  # pending.
  #
  # A silent hold is the worst outcome this worker can produce: it looks exactly
  # like a broken toggle, and Lucas spent a session unable to tell them apart.
  defp hold_reason(state) do
    case gate_text(state.gate) do
      nil -> clock_reason(state)
      text -> text
    end
  end

  defp gate_text(:unfocused), do: "jogo fora de foco — nada é digitado até você voltar pra ele"
  defp gate_text(:panic_corner), do: "parado pelo canto de pânico"
  defp gate_text(:potion_in_combat), do: "poção devida, mas a leitura diz que há luta"
  defp gate_text(:mini_game), do: "minigame em jogo — retoma quando o overlay sair"
  defp gate_text(_none), do: nil

  # The capture wait only shows while something is actually due (a bare pending
  # count with nothing to do isn't a hold).
  defp clock_reason(state) do
    waiting? = state.battle_clear_since != nil or state.reposition_pending?

    reasons =
      Enum.reject(
        [
          if(state.battle_clear_since != nil, do: "poção esperando batalha limpa"),
          if(state.reposition_pending?, do: "reposição esperando fim da luta"),
          if(waiting? and capture_busy?(state), do: "esperando a captura terminar")
        ],
        &is_nil/1
      )

    if reasons == [], do: nil, else: Enum.join(reasons, " + ")
  end

  # The post-fight ORDER policy (ball → support): with the toggle on, a
  # due potion/reposition also waits for the catcher's pending corpses to hit
  # zero. The cap bails the wait so a stuck detector can never starve the heal.
  defp capture_busy?(state) do
    Settings.get(:support_waits_capture) and state.capture_pending > 0 and
      state.capture_busy_since != nil and
      now() - state.capture_busy_since < Settings.get(:support_capture_wait_max_ms)
  end

  # The :pokemon blackboard fact: the fishing hook-gate (and any future consumer)
  # reads it via Perception.pokemon/1. Published only on a conclusive read —
  # transient errors / missing calibration publish nothing, so the fact ages out
  # and readers fail open.
  defp publish_pokemon_fact(obs), do: WorldState.put(:pokemon, obs, now())

  defp broadcast(state),
    do: Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:game, snapshot(state)})

  defp broadcast_log(level, text),
    do: Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:game_log, level, text})

  defp now, do: System.monotonic_time(:millisecond)

  defp reschedule(state, delay_ms) do
    state = cancel_timer(state)
    %{state | timer: Process.send_after(self(), :tick, max(delay_ms || 120, 10))}
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | timer: nil}
  end
end
