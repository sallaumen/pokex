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

  alias Pokex.Bots.{Body, Capture, InputGate}
  alias Pokex.Bots.PlayerSupport.Logic
  alias Pokex.Perception.{Interpret, WorldState}
  alias Pokex.{Calibration, Settings, Vision}

  @topic "game"
  @default_counters %{rescues: 0, potions: 0, reads: 0, failures: 0, repositions: 0}

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

  @impl true
  def init(state) do
    # The catcher's snapshots carry pending_corpses — the post-fight order
    # policy (support_waits_capture) reads it from here.
    Phoenix.PubSub.subscribe(Pokex.PubSub, Pokex.Bots.Catcher.Worker.topic())

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

  @impl true
  # A late tick after a halt (the timer fired before the cancel landed) must NOT resurrect the
  # loop — the running? flag is the source of truth, not the timer.
  def handle_info(:tick, %{running?: false} = state), do: {:noreply, state}

  def handle_info(:tick, state) do
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

  # Uncrashable: this monitor runs forever, so a transient capture failure (the broker or the Rig
  # momentarily down/restarting) must come back as {:error}, not take the whole worker down with it.
  defp read_hp(calib) do
    region = Calibration.pokemon_hp_region(calib)
    min_b = Settings.get(:pokemon_hp_min_brightness)
    min_s = Settings.get(:pokemon_hp_min_saturation)

    with {:ok, frame} <- Capture.frame(region, "pokemon_hp.png") do
      # A frame that doesn't LOOK like the bar (party window minimized → the region shows game
      # world) is UNKNOWN, not a reading: a garbage fill% here read as "low HP" and fired the
      # combo in an open/close loop, burning potions and revives.
      if Vision.hp_region_plausible?(frame,
           min_brightness: min_b,
           min_saturation: min_s,
           min_known_pct: Settings.get(:pokemon_hp_min_known_pct)
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
        :rescue -> fire_combo(state, calib)
        :hold -> maybe_potion(state, calib)
      end
    else
      state
    end
  end

  # The combat read costs a screen capture, so it only happens when a potion is otherwise due.
  # ONE clear read is NOT "out of battle": fished enemies re-aggress in the post-kill gap and
  # the game cancels the heal channel, wasting the potion (Lucas, live 2026-07-20) — so the
  # potion only fires after a CONTINUOUS battle-free window (potion_battle_clear_ms). Any
  # in-combat/unknown read — or the potion not being due — resets the streak.
  defp maybe_potion(state, calib) do
    if Logic.potion_wanted?(potion_input(state)) do
      case in_combat?(calib) do
        {:ok, false} -> potion_after_clear_window(state)
        _in_combat_or_unknown -> %{state | battle_clear_since: nil}
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
  defp maybe_reposition(state) do
    with true <- Settings.get(:reposition_enabled),
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

  # "In combat" for the potion gate is the GAME's notion, not ours: the heal channel is
  # interrupted the moment anything is fighting you — with or without a lock ring (the ring
  # only exists after a target is SELECTED, but fished enemies aggress you before any Tab,
  # and the post-kill gap has no ring either; the old ring-only read drank potions exactly
  # there). Engaged = lock ring present OR any enemy row in the battle list.
  #
  # The :battle feed already interprets this every ~120ms while combat runs — read the
  # blackboard first (zero extra capture); fall back to a direct capture+interpret when the
  # entry is stale/missing (manual play, bots off).
  defp in_combat?(calib) do
    case WorldState.get(:battle, Settings.get(:combat_world_max_age_ms), now()) do
      {:ok, obs} -> {:ok, engaged?(obs)}
      _stale_or_missing -> direct_battle_read(calib)
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp direct_battle_read(calib) do
    with {:ok, frame} <- Capture.frame(calib.battle_region, "potion_battle.png") do
      {:ok, engaged?(Interpret.battle(frame, calib, Settings.all()))}
    end
  end

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
    Body.perform(Logic.combo(combo_config(calib)), :critical, state.body)

    state = %{
      state
      | last_rescue_at: at,
        counters: bump(state.counters, :rescues),
        last_action: %{text: "combo de sobrevivência", at: at}
    }

    broadcast_log(:macro, "🚑 combo de sobrevivência — Pokémon com #{state.hp_pct}% de vida")
    state
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

  # The support worker's "why am I waiting": each armed clear-window clock is a
  # reason; both waiting at once join in one text. nil = nothing pending. The
  # capture wait only shows while something is actually due (a bare pending
  # count with nothing to do isn't a hold).
  defp hold_reason(state) do
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

  # The post-fight ORDER policy (loot → bola → suporte): with the toggle on, a
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
