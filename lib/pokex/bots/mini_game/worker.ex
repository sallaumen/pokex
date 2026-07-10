defmodule Pokex.Bots.MiniGame.Worker do
  @moduledoc """
  Watches the arena for the fishing mini-game overlay.

  On entry it pauses the regular fishing/combat/catcher workers and remembers
  which ones were active. On exit it starts only those remembered workers again.
  For now this worker does not play the mini-game; it only coordinates the
  transition and keeps the panel informed.

  Detection runs ONLY on this worker's own watch tick. The Body's input guards
  (`guard_before_input`/`guard_after_input`) are a pure, non-blocking read of the cached
  `in_game?` flag — they never capture, so an input never pays a synchronous screencapture.
  """
  use GenServer

  alias Pokex.Bots.{Capture, Catcher, Combat, Fishing}
  alias Pokex.Bots.MiniGame.Detector
  alias Pokex.{Calibration, Settings}

  @topic "mini_game"
  @default_counters %{detections: 0, clears: 0, failures: 0}
  @peer_keys [:fishing, :combat, :catcher]

  def topic, do: @topic

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    state = %{
      calib: nil,
      timer: nil,
      running?: false,
      in_game?: false,
      pause_ref: nil,
      present_streak: 0,
      absent_streak: 0,
      confidence: 0.0,
      error: nil,
      counters: @default_counters,
      paused_peers: [],
      peers:
        Keyword.get(opts, :peers, %{
          fishing: Fishing.Worker,
          combat: Combat.Worker,
          catcher: Catcher.Worker
        }),
      pause_peers: Keyword.get(opts, :pause_peers, &default_pause_peers/1),
      resume_peers: Keyword.get(opts, :resume_peers, &default_resume_peers/2)
    }

    case name do
      nil -> GenServer.start_link(__MODULE__, state)
      name -> GenServer.start_link(__MODULE__, state, name: name)
    end
  end

  def run(server \\ __MODULE__), do: GenServer.call(server, :run)
  def halt(server \\ __MODULE__), do: GenServer.call(server, :halt)
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  def guard_before_input(server \\ __MODULE__), do: guard(server, :guard_before_input)
  def guard_after_input(server \\ __MODULE__), do: guard(server, :guard_after_input)

  defp guard(nil, _message), do: :ok

  defp guard(server, message) do
    case GenServer.whereis(server) do
      nil ->
        :ok

      _pid ->
        GenServer.call(server, message, :infinity)
    end
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:run, _from, state) do
    case Calibration.load() do
      {:ok, calib} ->
        state =
          state
          |> cancel_timer()
          |> Map.merge(%{
            calib: calib,
            running?: true,
            in_game?: false,
            pause_ref: nil,
            present_streak: 0,
            absent_streak: 0,
            confidence: 0.0,
            error: nil,
            paused_peers: []
          })

        broadcast(state)
        {:reply, :ok, reschedule(state, 0)}

      {:error, reason} ->
        {:reply, {:error, ["calibração ilegível: #{inspect(reason)}"]}, state}
    end
  end

  def handle_call(:halt, _from, state) do
    state =
      state
      |> cancel_timer()
      |> Map.merge(%{
        running?: false,
        in_game?: false,
        pause_ref: nil,
        present_streak: 0,
        absent_streak: 0,
        confidence: 0.0,
        error: nil,
        paused_peers: []
      })

    broadcast(state)
    {:reply, :ok, state}
  end

  def handle_call(:status, _from, state), do: {:reply, snapshot(state), state}

  def handle_call(:guard_before_input, _from, state) do
    {:reply, guard_reply(state), state}
  end

  # PURE, non-blocking read of the cached in_game? flag — it must NEVER capture, because it runs
  # inside the Body's input path (Body.run_guarded wraps every click/press in it). Detection is
  # the watch tick's job; the mini-game is a sustained overlay, so one tick's latency to notice it
  # is fine and keeps the actuator off a synchronous screencapture per input.
  def handle_call(:guard_after_input, _from, state) do
    {:reply, guard_reply(state), state}
  end

  @impl true
  def handle_info(:tick, %{running?: false} = state), do: {:noreply, state}

  def handle_info(:tick, state) do
    {state, transition} =
      case read_presence(state) do
        {:ok, reading} -> apply_reading(state, reading)
        {:error, reason} -> mark_failure(state, reason)
      end

    if transition, do: broadcast(state, transition), else: :ok
    {:noreply, reschedule(state, Settings.get(:mini_game_tick_ms))}
  end

  def handle_info({:paused_peers, ref, paused_peers}, %{pause_ref: ref} = state) do
    state =
      if state.in_game? do
        %{state | paused_peers: paused_peers, pause_ref: nil}
      else
        resume_peers_async(state, paused_peers)
        %{state | paused_peers: [], pause_ref: nil}
      end

    {:noreply, state}
  end

  def handle_info({:paused_peers, _stale_ref, _paused_peers}, state), do: {:noreply, state}

  defp read_presence(state) do
    region = mini_game_region(state.calib)

    with {:ok, frame} <- Capture.frame(region, "mini_game.png") do
      {:ok,
       Detector.detect(frame,
         min_confidence: Settings.get(:mini_game_min_confidence),
         min_dark_ratio: Settings.get(:mini_game_min_dark_ratio),
         anchor_x: player_anchor_x(frame, state.calib, region),
         anchor_y: player_anchor_y(frame, state.calib, region),
         anchor_tolerance: anchor_tolerance(frame, region)
       )}
    end
  end

  defp apply_reading(state, %Detector{} = reading) do
    state =
      state
      |> Map.put(:confidence, reading.confidence)
      |> Map.put(:error, nil)
      |> update_streaks(reading.present?)

    cond do
      not state.in_game? and state.present_streak >= Settings.get(:mini_game_enter_streak) ->
        enter_game(state)

      state.in_game? and state.absent_streak >= Settings.get(:mini_game_exit_streak) ->
        leave_game(state)

      true ->
        {state, nil}
    end
  end

  defp update_streaks(state, true),
    do: %{state | present_streak: state.present_streak + 1, absent_streak: 0}

  defp update_streaks(state, false),
    do: %{state | present_streak: 0, absent_streak: state.absent_streak + 1}

  defp enter_game(state) do
    ref = make_ref()
    pause_peers_async(state, ref)

    state =
      state
      |> Map.put(:in_game?, true)
      |> Map.put(:pause_ref, ref)
      |> Map.put(:paused_peers, [])
      |> update_in([:counters, :detections], &(&1 + 1))

    broadcast_log(:macro, "mini game detectado — bloqueando inputs e pausando workers")
    {state, :entered}
  end

  defp leave_game(state) do
    paused_peers = state.paused_peers
    if paused_peers != [], do: resume_peers_async(state, paused_peers)

    state =
      state
      |> Map.put(:in_game?, false)
      |> Map.put(:paused_peers, [])
      |> update_in([:counters, :clears], &(&1 + 1))

    broadcast_log(:macro, "mini game saiu — retomando #{peer_label(paused_peers)}")
    {state, :left}
  end

  defp guard_reply(%{running?: true, in_game?: true}), do: {:blocked, :mini_game_active}
  defp guard_reply(_state), do: :ok

  defp pause_peers_async(state, ref) do
    owner = self()
    peers = state.peers
    pause_peers = state.pause_peers

    spawn(fn ->
      paused_peers = pause_peers.(peers)
      send(owner, {:paused_peers, ref, paused_peers})
    end)
  end

  defp resume_peers_async(state, paused_peers) do
    peers = state.peers
    resume_peers = state.resume_peers
    spawn(fn -> resume_peers.(peers, paused_peers) end)
    :ok
  end

  defp mark_failure(state, reason) do
    state =
      state
      |> Map.put(:error, inspect(reason))
      |> update_in([:counters, :failures], &(&1 + 1))

    broadcast_log(:debug, "erro ao observar mini game: #{inspect(reason)}")
    {state, nil}
  end

  defp mini_game_region(%Calibration{arena_region: region}) when is_tuple(region), do: region

  defp mini_game_region(%Calibration{screen_w: w, screen_h: h})
       when is_integer(w) and is_integer(h),
       do: {0, 0, w, h}

  defp player_anchor_x(frame, calib, {rx, _ry, rw, _rh}) when rw > 0 do
    {px, _py} = Calibration.player_point(calib)
    round((px - rx) * frame.width / rw)
  end

  defp player_anchor_y(frame, calib, {_rx, ry, _rw, rh}) when rh > 0 do
    {_px, py} = Calibration.player_point(calib)
    round((py - ry) * frame.height / rh)
  end

  # The game draws the bar OFFSET (~40px right of the sprite), so the search window must be
  # wider than the sprite itself. Seeded in screen points; scaled to frame px like the anchor.
  defp anchor_tolerance(frame, {_rx, _ry, rw, _rh}) when rw > 0,
    do: round(Settings.get(:mini_game_anchor_tolerance) * frame.width / rw)

  defp snapshot(%{running?: false} = state),
    do: %{
      state: :off,
      in_game?: false,
      confidence: state.confidence,
      counters: state.counters,
      error: state.error
    }

  defp snapshot(%{in_game?: true} = state),
    do: %{
      state: :playing,
      in_game?: true,
      confidence: state.confidence,
      counters: state.counters,
      error: state.error
    }

  defp snapshot(state),
    do: %{
      state: :watching,
      in_game?: false,
      confidence: state.confidence,
      counters: state.counters,
      error: state.error
    }

  defp broadcast(state, transition \\ nil) do
    snapshot =
      state
      |> snapshot()
      |> Map.put(:transition, transition)

    Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:mini_game, snapshot})
  end

  defp broadcast_log(level, text),
    do: Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:mini_game_log, level, text})

  defp reschedule(state, delay_ms) do
    state = cancel_timer(state)
    %{state | timer: Process.send_after(self(), :tick, max(delay_ms || 250, 10))}
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | timer: nil}
  end

  defp default_pause_peers(peers) do
    statuses = %{
      fishing: Fishing.Worker.status(peers.fishing),
      combat: Combat.Worker.status(peers.combat),
      catcher: Catcher.Worker.status(peers.catcher)
    }

    paused =
      @peer_keys
      |> Enum.filter(fn key -> resumable?(key, statuses[key]) end)

    Fishing.Worker.halt(peers.fishing)
    Combat.Worker.halt(peers.combat)
    Catcher.Worker.halt(peers.catcher)

    paused
  end

  defp default_resume_peers(peers, paused_peers) do
    if :fishing in paused_peers, do: Fishing.Worker.run(peers.fishing)
    if :combat in paused_peers, do: Combat.Worker.run(peers.combat)
    if :catcher in paused_peers, do: Catcher.Worker.run(peers.catcher)
    :ok
  end

  defp resumable?(:fishing, %{state: state}), do: state not in [:idle, :error]
  defp resumable?(:combat, %{state: state}), do: state not in [:idle, :error]
  defp resumable?(:catcher, %{state: state}), do: state != :idle
  defp resumable?(_key, _snapshot), do: false

  defp peer_label([]), do: "nenhum worker"

  defp peer_label(peers) do
    peers
    |> Enum.map(fn
      :fishing -> "pesca"
      :combat -> "combate"
      :catcher -> "captura"
    end)
    |> Enum.join(", ")
  end
end
