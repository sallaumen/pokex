defmodule Pokex.Bots.GameController.Worker do
  @moduledoc """
  Watches the main Pokémon's HP and fires the survival combo when it drops below the rescue
  threshold. This is the start of the game-state hub: it reads interpreted state (v1: HP) on its
  own tick and distributes it on the `"game"` PubSub topic for the panel.

  The combo runs on the shared Body at `:critical` (above combat's `:high`) so nothing delays a
  rescue, and the pure `GameController.Logic` owns the "yellow AND off-cooldown AND enabled"
  decision. Unlike the mini-game, a rescue does NOT pause any worker — it just jumps the queue.
  """
  use GenServer

  alias Pokex.Bots.{Body, Capture}
  alias Pokex.Bots.GameController.Logic
  alias Pokex.{Calibration, Settings, Vision}

  @topic "game"
  @default_counters %{rescues: 0, reads: 0, failures: 0}

  def topic, do: @topic

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    state = %{
      calib: nil,
      body: Keyword.get(opts, :body, Body),
      timer: nil,
      running?: false,
      hp_pct: nil,
      last_rescue_at: nil,
      error: nil,
      counters: @default_counters
    }

    case name do
      nil -> GenServer.start_link(__MODULE__, state)
      name -> GenServer.start_link(__MODULE__, state, name: name)
    end
  end

  def run(server \\ __MODULE__), do: GenServer.call(server, :run)
  def halt(server \\ __MODULE__), do: GenServer.call(server, :halt)
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:run, _from, state) do
    case Calibration.load() do
      {:ok, calib} ->
        state =
          %{state | calib: calib, running?: true, error: nil, last_rescue_at: nil}
          |> cancel_timer()

        broadcast(state)
        {:reply, :ok, reschedule(state, 0)}

      {:error, reason} ->
        {:reply, {:error, ["calibração ilegível: #{inspect(reason)}"]}, state}
    end
  end

  def handle_call(:halt, _from, state) do
    state = %{cancel_timer(state) | running?: false}
    broadcast(state)
    {:reply, :ok, state}
  end

  def handle_call(:status, _from, state), do: {:reply, snapshot(state), state}

  @impl true
  def handle_info(:tick, %{running?: false} = state), do: {:noreply, state}

  def handle_info(:tick, state) do
    previous = state

    state =
      case read_hp(state) do
        {:ok, hp_pct} -> act(%{state | hp_pct: hp_pct, error: nil, counters: bump(state.counters, :reads)})
        {:error, reason} -> fail(state, reason)
      end

    # Chatter guard: only push a snapshot when the HP reading or a counter actually moved, so the
    # 120ms tick doesn't flood the panel with identical frames.
    if changed?(previous, state), do: broadcast(state)

    {:noreply, reschedule(state, Settings.get(:game_tick_ms))}
  end

  defp read_hp(state) do
    region = Calibration.pokemon_hp_region(state.calib)

    with {:ok, frame} <- Capture.frame(region, "pokemon_hp.png") do
      {:ok,
       Vision.hp_fill_pct(frame,
         min_brightness: Settings.get(:pokemon_hp_min_brightness),
         min_saturation: Settings.get(:pokemon_hp_min_saturation)
       )}
    end
  end

  defp act(state) do
    case Logic.decide(decision_input(state)) do
      :rescue -> fire_combo(state)
      :hold -> state
    end
  end

  defp decision_input(state) do
    %{
      hp_pct: state.hp_pct,
      threshold_pct: Settings.get(:pokemon_hp_rescue_pct),
      enabled?: Settings.get(:rescue_enabled),
      cooldown_ms: Settings.get(:rescue_cooldown_ms),
      last_rescue_at: state.last_rescue_at,
      now: now()
    }
  end

  # Mark the attempt time BEFORE dispatching, so the cooldown holds even if the combo errors —
  # a dying-Pokémon loop must never re-fire and burn the expensive revives.
  defp fire_combo(state) do
    at = now()
    combo = Logic.combo(combo_config(state))
    Body.perform(combo, :critical, state.body)

    state = %{state | last_rescue_at: at, counters: bump(state.counters, :rescues)}
    broadcast_log(:macro, "🚑 combo de sobrevivência — Pokémon com #{state.hp_pct}% de vida")
    state
  end

  defp combo_config(state) do
    %{
      rescue_key: Settings.get(:rescue_key),
      max_revive_key: Settings.get(:max_revive_key),
      photo_point: Calibration.pokemon_photo_point(state.calib),
      neutral_point: state.calib.neutral_point,
      step_ms: Settings.get(:rescue_step_ms)
    }
  end

  defp fail(state, reason) do
    broadcast_log(:debug, "erro ao ler a vida: #{inspect(reason)}")
    %{state | error: inspect(reason), counters: bump(state.counters, :failures)}
  end

  defp changed?(previous, state),
    do: previous.hp_pct != state.hp_pct or previous.counters != state.counters

  defp bump(counters, key), do: Map.update!(counters, key, &(&1 + 1))

  defp snapshot(%{running?: false} = state),
    do: %{state: :off, hp_pct: state.hp_pct, enabled?: enabled?(), counters: state.counters, error: state.error}

  defp snapshot(state),
    do: %{
      state: :monitoring,
      hp_pct: state.hp_pct,
      enabled?: enabled?(),
      last_rescue_at: state.last_rescue_at,
      counters: state.counters,
      error: state.error
    }

  defp enabled?, do: Settings.get(:rescue_enabled)

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
