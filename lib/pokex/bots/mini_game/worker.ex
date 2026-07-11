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

  require Logger

  alias Pokex.Bots.{Capture, Catcher, Combat, Fishing}
  alias Pokex.Bots.MiniGame.{Detector, Pilot, Track}
  alias Pokex.{Calibration, Rig, Settings}

  @topic "mini_game"
  @default_counters %{detections: 0, clears: 0, failures: 0}
  # last_toggle_at nil = never toggled — the monotonic clock is NEGATIVE on the
  # BEAM, so a 0 sentinel would read as "toggled far in the future" and mute
  # the actuator forever.
  @default_play %{fish: [], capsule: [], holding?: false, last_toggle_at: nil}
  @peer_keys [:fishing, :combat, :catcher]
  @observation_cap 4

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
      play: @default_play,
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
  def init(state) do
    # Space must never stay held: trapping exits guarantees terminate/2 runs on
    # supervisor shutdown, releasing the key.
    Process.flag(:trap_exit, true)
    {:ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.in_game? or state.play.holding?, do: safe_key_up()
    :ok
  end

  @impl true
  def handle_call(:run, _from, state) do
    case Calibration.load() do
      {:ok, calib} ->
        # re-run mid-game (panel Start while playing) must not strand a held
        # Space: the merge below forgets in_game?/play, so release FIRST.
        state =
          state
          |> release_if_holding()
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
            play: @default_play,
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
      |> force_release()
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
        {:ok, reading, frame, captured_at} ->
          {state, transition} = apply_reading(state, reading)
          {play(state, reading, frame, captured_at), transition}

        {:error, reason} ->
          # A blind tick must not leave Space held.
          {state, transition} = mark_failure(state, reason)
          {release_if_holding(state), transition}
      end

    if transition, do: broadcast(state, transition), else: :ok

    tick_ms =
      if state.in_game?,
        do: Settings.get(:mini_game_play_tick_ms),
        else: Settings.get(:mini_game_tick_ms)

    {:noreply, reschedule(state, tick_ms)}
  end

  # trap_exit is on for terminate/2; stray EXIT messages from unlinked helpers
  # must not crash the worker.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

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
    # Stamped BEFORE the capture: observations must carry the CAPTURE time, so
    # the pilot's age_ms covers the real 100-300ms capture+decode latency and
    # the predictive extrapolation compensates it (the lab's "latencia" knob).
    captured_at = System.monotonic_time(:millisecond)

    with {:ok, frame} <- Capture.frame(region, "mini_game.png") do
      reading =
        Detector.detect(frame,
          min_confidence: Settings.get(:mini_game_min_confidence),
          min_dark_ratio: Settings.get(:mini_game_min_dark_ratio),
          anchor_x: player_anchor_x(frame, state.calib, region),
          anchor_y: player_anchor_y(frame, state.calib, region),
          anchor_tolerance: anchor_tolerance(frame, region)
        )

      {:ok, reading, frame, captured_at}
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
      |> Map.put(:play, @default_play)
      |> update_in([:counters, :detections], &(&1 + 1))

    broadcast_log(:macro, "mini game detectado — jogando (bloqueando inputs e pausando workers)")
    {state, :entered}
  end

  defp leave_game(state) do
    paused_peers = state.paused_peers
    if paused_peers != [], do: resume_peers_async(state, paused_peers)

    state =
      state
      |> force_release()
      |> Map.put(:in_game?, false)
      |> Map.put(:paused_peers, [])
      |> update_in([:counters, :clears], &(&1 + 1))

    broadcast_log(:macro, "mini game saiu — retomando #{peer_label(paused_peers)}")
    {state, :left}
  end

  # --- playing ---------------------------------------------------------------

  # The play step runs on the same tick that watches presence. It talks to the
  # Rig DIRECTLY (never Body): while in_game the Body guard blocks every other
  # input — including the Catcher's loot Space — and the player must not block
  # itself behind its own guard.
  defp play(%{in_game?: true} = state, %Detector{bar: bar}, frame, captured_at)
       when is_map(bar) do
    case Track.read(frame, bar) do
      {:ok, %{fish_y: fish_y, bar_y: bar_y, bar_source: bar_source}} ->
        play = state.play
        fish = push_observation(play.fish, %{y: fish_y, at: captured_at})

        capsule =
          push_observation(play.capsule, %{y: bar_y, at: captured_at, source: bar_source})

        # Decision time is NOW, observations carry capture time: age_ms > 0 is
        # exactly the capture latency the predictive pilot extrapolates over.
        now = System.monotonic_time(:millisecond)

        decision =
          Pilot.decide(
            %{pilot: :predictive, deadband_pct: Settings.get(:mini_game_deadband_pct)},
            fish,
            %{y: bar_y, vy: capsule_velocity(capsule), pressing: play.holding?},
            now
          )

        state = %{state | play: %{play | fish: fish, capsule: capsule}}
        actuate(state, decision.desired, now)

      {:error, _reason} ->
        # One blind read at 3-7fps must fail SAFE, not stuck: let go and wait
        # for the next frame (the pilot re-decides from scratch anyway).
        release_if_holding(state)
    end
  end

  # In game but the Detector lost the overlay this tick (exit streak pending).
  defp play(%{in_game?: true} = state, _reading, _frame, _captured_at),
    do: release_if_holding(state)

  defp play(state, _reading, _frame, _captured_at), do: state

  defp push_observation(observations, observation),
    do: Enum.take(observations ++ [observation], -@observation_cap)

  # The capsule's velocity (track/s) from its last two readings — the lab read
  # this from the simulator's physics; the real pipeline estimates it. When the
  # reading SOURCE flips (blue capsule <-> occlusion fallback), the position
  # jumps by the capsule/fish centroid offset, not by real motion — that fake
  # spike would cross the hysteresis vy overrides right at the success moment,
  # so a source switch reads as vy 0.
  defp capsule_velocity(observations) when length(observations) < 2, do: 0.0

  defp capsule_velocity(observations) do
    [older, newer] = Enum.take(observations, -2)

    if older.source != newer.source do
      0.0
    else
      elapsed = max(newer.at - older.at, 16)
      (newer.y - older.y) / elapsed * 1000
    end
  end

  defp actuate(%{play: %{holding?: desired}} = state, desired, _now), do: state

  defp actuate(state, desired, now) do
    last = state.play.last_toggle_at

    if last != nil and now - last < Settings.get(:mini_game_min_toggle_ms) do
      state
    else
      apply_hold(desired)
      %{state | play: %{state.play | holding?: desired, last_toggle_at: now}}
    end
  end

  # A failed hold call desyncs holding? from the OS until the next exit-boundary
  # release — surface it instead of failing silently.
  defp apply_hold(desired) do
    result = if desired, do: Rig.impl().key_down("space"), else: Rig.impl().key_up("space")

    with {:error, reason} <- result do
      Logger.warning(
        "mini-game: espaço #{if desired, do: "down", else: "up"} falhou: #{inspect(reason)}"
      )

      result
    end
  end

  defp release_if_holding(%{play: %{holding?: true}} = state), do: force_release(state)
  defp release_if_holding(state), do: state

  # Unconditional key_up: `holding?` can desync from the OS (a failed key_down
  # report, a crash between the Rig call and the state update), so exits always
  # send the release. Bypasses the min-toggle floor — safety beats pacing.
  defp force_release(state) do
    safe_key_up()
    %{state | play: %{state.play | holding?: false}}
  end

  defp safe_key_up do
    Rig.impl().key_up("space")
  catch
    _kind, _reason -> :ok
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
