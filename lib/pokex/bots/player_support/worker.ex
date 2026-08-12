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
  The pure `PlayerSupport.Logic` owns the "below-threshold AND off-cooldown AND enabled" decision.
  """
  use GenServer

  alias Pokex.Bots.Body
  alias Pokex.Bots.Capture
  alias Pokex.Bots.Catcher.Worker
  alias Pokex.Bots.Combat.Loadout
  alias Pokex.Bots.Focus
  alias Pokex.Bots.SkillReceipt
  alias Pokex.Bots.InputGate
  alias Pokex.Bots.PlayerSupport.Logic
  alias Pokex.Calibration
  alias Pokex.Combos.Store
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
      timer: nil,
      # explicit lifecycle flag: a halt must stick even when a :tick was already in flight
      # (the timer fires before the cancel lands) — the flag, not the timer, decides.
      running?: false,
      hp_pct: nil,
      prev_hp_pct: nil,
      last_rescue_at: nil,
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
  def flee_to_escape(server \\ __MODULE__), do: GenServer.call(server, :flee_to_escape)

  @impl true
  def init(state) do
    # The catcher's snapshots carry pending_corpses — the post-fight order
    # policy (support_waits_capture) reads it from here.
    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())

    # Auto-start monitoring on boot (real app). Gated off in the test env so the app-wide instance
    # doesn't tick against the shared Rig/home during unrelated tests — tests call run/1 to monitor.
    if Application.get_env(:pokex, :player_support_auto_monitor, true),
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
      case Body.perform(flee_actions(point), :critical, state.body) do
        :ok ->
          broadcast_log(
            :macro,
            "🏃 fuga: andou até o tile calibrado e entrou na escada " <>
              "(#{Settings.get(:escape_steps)}× #{direction_label(escape_direction())})"
          )

          state = %{state | last_action: %{text: "fuga (escada)", at: now()}}
          broadcast(state)
          {:reply, :ok, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:error, :panic_corner} -> {:reply, {:error, :panic_corner}, state}
      _no_point_or_no_calib -> {:reply, {:error, :not_calibrated}, state}
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
  #
  # A VM that does not COMMAND the machine is held for the same reason and skips the same
  # capture. This worker is the only one that arms itself with no order from anybody, so
  # without this a server opened just to look at the UI (2026-08-12) sits watching HP, ready
  # to potion the OWNER's Pokémon, with its captures queued in front of the owner's.
  def handle_info(:tick, state) do
    cond do
      not InputGate.owner_ok?() -> handle_held_tick(state, :not_owner)
      Pokex.Perception.mini_game_playing?() -> handle_held_tick(state, :mini_game)
      true -> run_tick(state)
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

  # The catcher topic also carries {:catcher_log, ...} chatter — not ours.
  def handle_info(_msg, state), do: {:noreply, state}

  # Nothing here can act (Body gated, or this VM isn't the one in command) and nothing reads
  # our fact, so we do NOT capture — that only starves the real captures. Announce once on the
  # entering edge, then stay silent. Keeps ticking, so the hold lifts by itself the moment the
  # overlay clears or this VM is promoted to owner.
  defp handle_held_tick(state, gate) do
    entered? = state.gate != gate
    state = %{state | gate: gate}
    if entered?, do: broadcast(state)
    {:noreply, reschedule(state, Settings.get(:support_tick_ms))}
  end

  defp run_tick(state) do
    previous = state

    state =
      case Calibration.load() do
        {:ok, calib} ->
          case read_hp(calib) do
            {:ok, hp} ->
              publish_pokemon_fact(%{hp_pct: hp, readable?: true})

              act(
                %{
                  state
                  | prev_hp_pct: state.hp_pct,
                    hp_pct: hp,
                    error: nil,
                    counters: bump(state.counters, :reads)
                },
                calib
              )

            # The region doesn't look like the bar (minimized party window, or no Pokémon
            # out of the ball): UNKNOWN — clear the reading so nothing can act on a
            # stale/garbage value, and say why in the panel. The fact says readable?: false,
            # which is exactly what the fishing gate treats as "sem pokémon ativo".
            :unrecognized ->
              publish_pokemon_fact(%{hp_pct: nil, readable?: false})

              %{
                state
                | hp_pct: nil,
                  prev_hp_pct: nil,
                  error: "barra de vida não reconhecida (janela do Pokémon minimizada?)"
              }

            {:error, reason} ->
              fail(state, reason)
          end

        # No calibration yet → nothing to read; keep monitoring so it starts the instant one exists.
        {:error, _reason} ->
          %{state | hp_pct: nil, error: "sem calibração"}
      end

    state = maybe_reposition(state)

    # Chatter guard: only push a snapshot when the HP reading or a counter actually moved, so the
    # tick doesn't flood the panel with identical frames.
    if changed?(previous, state), do: broadcast(state)

    {:noreply, reschedule(state, Settings.get(:support_tick_ms))}
  end

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
           min_bright_pct: Settings.get(:pokemon_hp_min_bright_pct)
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
      case Logic.decide(decision_input(state)) do
        :rescue -> fire_combo(%{state | gate: nil}, calib)
        :hold -> %{state | gate: nil} |> maybe_heal_skill() |> maybe_potion(calib)
      end
    else
      # Everything this worker exists for is blocked here, and until now the ONLY
      # sign was a small badge in the panel header. "revive is on and nothing
      # happened" is unanswerable when the closed gate is invisible: name it.
      %{state | gate: closed_gate()}
    end
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

      Body.perform(Enum.map(keys, &{:press, &1}), :high, state.body)

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
    with {:ok, frame} <- Capture.frame(calib.battle_region, "potion_battle.png") do
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

  defp decision_input(state) do
    %{
      hp_pct: state.hp_pct,
      prev_hp_pct: state.prev_hp_pct,
      threshold_pct: Settings.get(:pokemon_hp_rescue_pct),
      enabled?: Settings.get(:rescue_enabled),
      cooldown_ms: Settings.get(:rescue_cooldown_ms),
      last_rescue_at: state.last_rescue_at,
      now: now()
    }
  end

  # Mark the attempt time BEFORE dispatching, so the cooldown holds even if the combo errors —
  # a dying-Pokémon loop must never re-fire and burn the expensive revives.
  defp fire_combo(state, calib) do
    at = now()
    {stun_steps, notes} = rescue_stun_steps()
    notes = notes ++ crowd_control(state, stun_steps)

    Body.perform(Logic.combo(combo_config(calib)), :critical, state.body)

    state = %{
      state
      | last_rescue_at: at,
        counters: bump(state.counters, :rescues),
        last_action: %{text: "combo de sobrevivência", at: at}
    }

    Enum.each(notes, fn
      {:alarm, text} -> Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:rule_alarm, text})
      {:log, text} -> broadcast_log(:macro, text)
    end)

    broadcast_log(:macro, "🚑 combo de sobrevivência — Pokémon com #{state.hp_pct}% de vida")
    state
  end

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
  # skill-bar reading, and what it buys is knowing.
  defp crowd_control(_state, []), do: []

  defp crowd_control(state, stun_steps) do
    keys = for {:press, key} <- stun_steps, do: key
    before = Pokex.Perception.ready_skills()
    at = now()

    Body.perform(stun_steps, :critical, state.body)

    later = Pokex.Perception.ready_skills_after(at, Settings.get(:rescue_confirm_ms))

    keys
    |> then(&SkillReceipt.check(before, later, &1))
    |> SkillReceipt.verdict()
    |> stun_note(keys)
  end

  # Every outcome still ends in a revive — a pokémon left dead is worse than a
  # pokémon revived in the open, and that was already this module's rule
  # ("fail in the direction of SAVING"). What changes is that a stun that did
  # not land now SAYS SO, loudly, instead of being assumed.
  defp stun_note(:confirmed, keys),
    do: [log: "🚑 stun confirmado (#{Enum.join(keys, ", ")}) — pode tirar o pokémon"]

  defp stun_note({:missed, missed}, _keys),
    do: [
      alarm: "🚑 o stun NÃO saiu (#{Enum.join(missed, ", ")}) — revivendo exposto, confere o jogo"
    ]

  defp stun_note(:unconfirmed, _keys),
    do: [log: "🚑 não consegui confirmar o stun (barra ilegível) — revivendo assim mesmo"]

  # The rescue's STUN prefix (2026-07-30): in "combo" mode the chosen combo's
  # steps become presses/waits BEFORE the recall — skills on cooldown are
  # skipped against a FRESH bar reading (no reading = all in blind). Every
  # failure falls toward SAVING: missing/disabled/ineligible combo = empty
  # prefix + alarm, the revive happens anyway.
  defp rescue_stun_steps do
    case Settings.get(:rescue_mode) do
      "combo" -> compile_rescue_combo(Settings.get(:rescue_combo))
      _direto -> {[], []}
    end
  end

  defp compile_rescue_combo(name) do
    combo = Enum.find(Store.all(), &(&1.name == name))

    cond do
      combo == nil ->
        fall_back_to_control("combo de resgate \"#{name}\" não existe")

      not combo.enabled? ->
        fall_back_to_control("combo de resgate \"#{name}\" está desligado")

      not Pokex.Combos.rescue_eligible?(combo) ->
        fall_back_to_control("combo de resgate \"#{name}\" tem troca de time")

      true ->
        {actions, skipped} =
          combo.steps
          |> resolve_waits()
          |> Logic.stun_prefix(Pokex.Perception.ready_skills())

        notes =
          if skipped == [],
            do: [],
            else: [log: "🚑 stun do resgate: pulei #{Enum.join(skipped, ", ")} (cooldown)"]

        {actions, notes}
    end
  end

  # The configured combo cannot run. Before giving up on the stun entirely, ask
  # the pokémon on the field: the `:crowd` job on `/time` IS "reservada pro stun
  # antes do revive", classified per pokémon — which is the answer a globally
  # named combo cannot give after a swap.
  #
  # It never OVERRIDES his combo: this is only reached where the code used to
  # revive with no stun at all. Still fails toward SAVING — no control keys, no
  # prefix, and the revive happens either way. Like any stun prefix it goes out
  # alone and is CONFIRMED against the bar before the pokémon leaves the field.
  defp fall_back_to_control(why) do
    case ready_control_keys() do
      [] ->
        {[], [alarm: "🚑 #{why} — revivendo direto"]}

      keys ->
        {Logic.stun_prefix(Enum.map(keys, &{:skill, &1}), nil) |> elem(0),
         [log: "🚑 #{why} — usando o controle do pokémon em campo (#{Enum.join(keys, ", ")})"]}
    end
  end

  defp ready_control_keys do
    case Loadout.current() do
      nil -> []
      loadout -> ready_only(loadout.crowd)
    end
  end

  # Symbolic waits ({:wait, :setting}) become ms before the pure compile. A
  # setting that no longer exists falls back to rescue_step_ms — an old combo
  # must never take a rescue down over a wait.
  defp resolve_waits(steps) do
    Enum.map(steps, fn
      {:wait, setting} when is_atom(setting) ->
        {:wait, safe_wait_ms(setting)}

      other ->
        other
    end)
  end

  defp safe_wait_ms(setting) do
    case Settings.get(setting) do
      ms when is_integer(ms) and ms >= 0 -> ms
      _estranho -> Settings.get(:rescue_step_ms)
    end
  rescue
    _no_seed -> Settings.get(:rescue_step_ms)
  end

  defp combo_config(calib) do
    %{
      rescue_key: Settings.get(:rescue_key),
      max_revive_key: Settings.get(:max_revive_key),
      photo_point: Calibration.pokemon_photo_point(calib),
      neutral_point: calib.neutral_point,
      step_ms: Settings.get(:rescue_step_ms)
    }
  end

  # A failed read also resets the consecutive-low guard: after a gap we demand two FRESH
  # agreeing reads before acting again (garbage often comes in bursts around failures).
  defp fail(state, reason) do
    broadcast_log(:debug, "erro ao ler a vida: #{inspect(reason)}")
    %{state | prev_hp_pct: nil, error: inspect(reason), counters: bump(state.counters, :failures)}
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

  defp gate_text(:not_owner),
    do: "outro Pokex está no comando desta máquina — esta janela não age"

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

  # The post-fight ORDER policy (loot → ball → support): with the toggle on, a
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
