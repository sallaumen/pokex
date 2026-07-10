defmodule Pokex.Bots.GameController.Worker do
  @moduledoc """
  ALWAYS-ON monitor of the main Pokémon's HP — independent of the fishing/combat bots. It reads the
  HP every tick from boot and distributes it on the `"game"` PubSub topic, and when the survival
  combo is enabled it fires it at `:critical` (above combat's `:high`) the moment HP drops below the
  threshold. So you can play MANUALLY, with every bot off, flip on the "Combo de sobrevivência"
  toggle, and still have it keep your Pokémon alive.

  It is NOT part of Start/Stop and the panic corner does not halt it — it just monitors. It reloads
  the calibration each tick, so a fresh HP calibration takes effect without a restart. The pure
  `GameController.Logic` owns the "below-threshold AND off-cooldown AND enabled" decision.
  """
  use GenServer

  alias Pokex.Bots.{Body, Capture}
  alias Pokex.Bots.GameController.Logic
  alias Pokex.{Calibration, Settings, Vision}

  @topic "game"
  @default_counters %{rescues: 0, potions: 0, reads: 0, failures: 0}

  def topic, do: @topic

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    state = %{
      body: Keyword.get(opts, :body, Body),
      timer: nil,
      hp_pct: nil,
      prev_hp_pct: nil,
      last_rescue_at: nil,
      last_potion_at: nil,
      error: nil,
      counters: @default_counters
    }

    case name do
      nil -> GenServer.start_link(__MODULE__, state)
      name -> GenServer.start_link(__MODULE__, state, name: name)
    end
  end

  def status(server \\ __MODULE__), do: GenServer.call(server, :status)
  # The monitor auto-starts on boot; run/halt are kept for manual control and tests.
  def run(server \\ __MODULE__), do: GenServer.call(server, :run)
  def halt(server \\ __MODULE__), do: GenServer.call(server, :halt)

  @doc """
  Manually drink a potion NOW — the panel button. Deliberate user intent, so no combat/threshold
  gates apply; it still stamps the cooldown so the automatic sip doesn't double up mid-channel.
  """
  def use_potion(server \\ __MODULE__), do: GenServer.call(server, :use_potion)

  @impl true
  def init(state) do
    # Auto-start monitoring on boot (real app). Gated off in the test env so the app-wide instance
    # doesn't tick against the shared Rig/home during unrelated tests — tests call run/1 to monitor.
    if Application.get_env(:pokex, :game_controller_auto_monitor, true),
      do: {:ok, reschedule(state, 0)},
      else: {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, snapshot(state), state}
  def handle_call(:run, _from, state), do: {:reply, :ok, reschedule(state, 0)}
  def handle_call(:halt, _from, state), do: {:reply, :ok, cancel_timer(state)}

  def handle_call(:use_potion, _from, state) do
    state = fire_potion(state, "🧪 poção (manual)")
    broadcast(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    previous = state

    state =
      case Calibration.load() do
        {:ok, calib} ->
          case read_hp(calib) do
            {:ok, hp} ->
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

            {:error, reason} ->
              fail(state, reason)
          end

        # No calibration yet → nothing to read; keep monitoring so it starts the instant one exists.
        {:error, _reason} ->
          %{state | hp_pct: nil, error: "sem calibração"}
      end

    # Chatter guard: only push a snapshot when the HP reading or a counter actually moved, so the
    # tick doesn't flood the panel with identical frames.
    if changed?(previous, state), do: broadcast(state)

    {:noreply, reschedule(state, Settings.get(:game_tick_ms))}
  end

  # Uncrashable: this monitor runs forever, so a transient capture failure (the broker or the Rig
  # momentarily down/restarting) must come back as {:error}, not take the whole worker down with it.
  defp read_hp(calib) do
    region = Calibration.pokemon_hp_region(calib)

    with {:ok, frame} <- Capture.frame(region, "pokemon_hp.png") do
      {:ok,
       Vision.hp_fill_pct(frame,
         min_brightness: Settings.get(:pokemon_hp_min_brightness),
         min_saturation: Settings.get(:pokemon_hp_min_saturation)
       )}
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp act(state, calib) do
    case Logic.decide(decision_input(state)) do
      :rescue -> fire_combo(state, calib)
      :hold -> maybe_potion(state, calib)
    end
  end

  # The combat read costs a screen capture, so it only happens when a potion is otherwise due —
  # and the potion only fires on a CONFIRMED out-of-combat read (entering a fight interrupts the
  # heal channel, so an in-combat or unknown read would just waste the potion).
  defp maybe_potion(state, calib) do
    with true <- Logic.potion_wanted?(potion_input(state)),
         {:ok, false} <- in_combat?(calib) do
      fire_potion(state, "🧪 poção — vida em #{state.hp_pct}%")
    else
      _ -> state
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

  # Same signal Combat trusts: per-row lock-ring red inside the battle body; any row at or above
  # target_locked_min_pixels means a fight is active. Mirrors Fisher.Sensors.Real fetch(:battle_lock).
  defp in_combat?(calib) do
    with {:ok, frame} <- Capture.frame(Calibration.battle_body(calib), "target.png") do
      {top, band} = Calibration.row_band_geometry(calib.scale, Settings.get(:battle_row_height))
      red = Vision.red_row_counts(frame, top: top, band: band, rows: Settings.get(:battle_max_rows))
      {:ok, Enum.any?(red, &(&1 >= Settings.get(:target_locked_min_pixels)))}
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  # Stamp last_potion_at BEFORE dispatch (same rationale as the combo): if the press errors, the
  # cooldown still holds and a glitch loop can't chug the whole potion stack.
  defp fire_potion(state, log_text) do
    at = now()
    Body.perform([{:press, Settings.get(:potion_key)}], :high, state.body)

    state = %{state | last_potion_at: at, counters: bump(state.counters, :potions)}
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

    state = %{state | last_rescue_at: at, counters: bump(state.counters, :rescues)}
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
    do: previous.hp_pct != state.hp_pct or previous.counters != state.counters

  defp bump(counters, key), do: Map.update!(counters, key, &(&1 + 1))

  defp snapshot(state),
    do: %{
      state: :monitoring,
      hp_pct: state.hp_pct,
      enabled?: Settings.get(:rescue_enabled),
      last_rescue_at: state.last_rescue_at,
      counters: state.counters,
      error: state.error
    }

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
