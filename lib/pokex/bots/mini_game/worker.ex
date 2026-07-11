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
  # the actuator forever. strip = the narrow capture region around the bar,
  # armed on enter (the overlay never moves within one game).
  @default_play %{
    fish: [],
    capsule: [],
    holding?: false,
    last_toggle_at: nil,
    strip: nil,
    bar_width: 14
  }
  # Half-width (screen points) of the playing-time capture strip around the
  # bar: wide enough for the track + the fish poking past it, and ~8x cheaper
  # to capture and scan than the whole arena.
  @strip_half_pt 40
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
    {state, transition} = if state.in_game?, do: play_tick(state), else: watch_tick(state)

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

  # Watching: full arena capture + Detector, exactly as before. On the enter
  # edge the bar geometry arms the playing-time capture strip.
  defp watch_tick(state) do
    case read_presence(state) do
      {:ok, reading} ->
        {state, transition} = apply_reading(state, reading)
        state = if transition == :entered, do: arm_strip(state, reading), else: state
        {state, transition}

      {:error, reason} ->
        mark_failure(state, reason)
    end
  end

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

  # The overlay never moves within one game, so the playing loop only captures
  # a narrow strip around the bar — much cheaper than arena + Detector, which
  # is what lets the play tick run at 80ms.
  defp arm_strip(state, %Detector{bar: bar}) when is_map(bar) do
    {rx, ry, _rw, rh} = mini_game_region(state.calib)
    scale = state.calib.scale || 1.0
    center = rx + round(bar.x / scale)

    strip = {max(center - @strip_half_pt, 0), ry, @strip_half_pt * 2, rh}
    %{state | play: %{state.play | strip: strip, bar_width: bar.width}}
  end

  defp arm_strip(state, _reading), do: state

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

  # The play tick captures ONLY the armed strip and reads presence from the
  # Track itself (:no_track = overlay gone). It talks to the Rig DIRECTLY
  # (never Body): while in_game the Body guard blocks every other input —
  # including the Catcher's loot Space — and the player must not block itself
  # behind its own guard.
  defp play_tick(%{play: %{strip: nil}} = state) do
    # Defensive: entered without a bar candidate — nothing to play from.
    leave_game(state)
  end

  defp play_tick(%{play: %{strip: strip}} = state) do
    # Stamped BEFORE the capture: observations must carry the CAPTURE time, so
    # the pilot's age_ms covers the real capture+decode latency and the
    # predictive extrapolation compensates it (the lab's "latencia" knob).
    captured_at = System.monotonic_time(:millisecond)

    case Capture.frame(strip, "mini_game_strip.png") do
      {:ok, frame} ->
        play_frame(state, frame, strip, captured_at)

      {:error, reason} ->
        # A blind tick must not leave Space held.
        {state, transition} = mark_failure(state, reason)
        {release_if_holding(state), transition}
    end
  end

  defp play_frame(state, frame, {_sx, _sy, sw, _sh}, captured_at) do
    # The bar sits at the strip's center; scale point-geometry to frame px.
    track_bar = %{x: round(@strip_half_pt * frame.width / sw), width: state.play.bar_width}

    case Track.read(frame, track_bar) do
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
            %{
              pilot: :predictive,
              deadband_pct: Settings.get(:mini_game_deadband_pct),
              actuation_ms: actuation_ms(),
              brake_up: Settings.get(:mini_game_brake_up),
              brake_down: Settings.get(:mini_game_brake_down)
            },
            fish,
            %{
              y: bar_y,
              vy: capsule_velocity(capsule),
              pressing: play.holding?,
              at: captured_at
            },
            now
          )

        state = %{state | play: %{play | fish: fish, capsule: capsule}, absent_streak: 0}
        {actuate(state, decision.desired, now), nil}

      {:error, :no_fish} ->
        # Track still there, fish unreadable this frame: blind ticks fail SAFE
        # (release), but the overlay is present — not an exit signal.
        {release_if_holding(%{state | absent_streak: 0}), nil}

      {:error, :no_track} ->
        state = release_if_holding(%{state | absent_streak: state.absent_streak + 1})

        if state.absent_streak >= Settings.get(:mini_game_exit_streak),
          do: leave_game(state),
          else: {state, nil}
    end
  end

  defp push_observation(observations, observation),
    do: Enum.take(observations ++ [observation], -@observation_cap)

  # The capsule's velocity (track/s) — the lab read this from the simulator's
  # physics; the real pipeline estimates it from readings. Two protections:
  # only the trailing run of SAME-SOURCE readings counts (a blue<->occlusion
  # source flip jumps by the centroid offset, not real motion — that fake spike
  # crossed the hysteresis overrides right at the success moment), and up to 3
  # readings blend 2:1 toward the newest pair (single-pair estimates were too
  # noisy from row quantization, feeding the overshoot Lucas saw live).
  defp capsule_velocity(observations) do
    case observations |> trailing_same_source() |> Enum.take(-3) do
      run when length(run) < 2 ->
        0.0

      [older, newer] ->
        capsule_pair_velocity(older, newer)

      [first, second, third] ->
        (capsule_pair_velocity(second, third) * 2 + capsule_pair_velocity(first, second)) / 3
    end
  end

  defp trailing_same_source([]), do: []

  defp trailing_same_source(observations) do
    source = List.last(observations).source

    observations
    |> Enum.reverse()
    |> Enum.take_while(&(&1.source == source))
    |> Enum.reverse()
  end

  # Physically impossible jumps are misreads, not motion (the lab bar tops out
  # at ~1.2 track/s) — a mis-tracked capsule must not command a braking slam.
  @max_capsule_speed 1.5

  defp capsule_pair_velocity(older, newer) do
    elapsed = max(newer.at - older.at, 16)
    velocity = (newer.y - older.y) / elapsed * 1000

    if abs(velocity) > @max_capsule_speed, do: 0.0, else: velocity
  end

  # ~2ms CGEvent post + port hop when the native key helper is up; the seeded
  # value models the osascript fallback (~90ms). Auto-switching keeps the bar
  # prediction honest on whichever path is live.
  @native_actuation_ms 15

  defp actuation_ms do
    if Rig.Mac.KeyEvents.status() == :ready,
      do: @native_actuation_ms,
      else: Settings.get(:mini_game_actuation_ms)
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
