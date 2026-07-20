defmodule Pokex.Bots.MiniGame.Player do
  @moduledoc """
  The playing engine for ONE mini-game: captures the armed bar strip, reads
  the track, asks the Pilot for a decision, and holds/releases Space.

  Extracted from the Worker so the GenServer keeps only lifecycle — detection
  streaks, peer pause/resume, input guards — while everything about actually
  PLAYING (observation histories, actuation with the min-toggle floor, the
  never-leave-Space-held releases, the per-game physics trace) sits behind
  this small interface. It talks to the Rig DIRECTLY (never Body): while
  in-game the Body guard blocks every other input, including the player's own.
  """

  require Logger

  alias Pokex.Bots.Capture
  alias Pokex.Bots.MiniGame.{Detector, Pilot, Track}
  alias Pokex.{Rig, Settings}

  # last_toggle_at nil = never toggled — the monotonic clock is NEGATIVE on
  # the BEAM, so a 0 sentinel would read as "toggled far in the future" and
  # mute the actuator forever.
  defstruct fish: [],
            capsule: [],
            holding?: false,
            last_toggle_at: nil,
            strip: nil,
            bar_width: 14,
            no_capsule_streak: 0,
            trace: []

  @type t :: %__MODULE__{}

  @observation_cap 4
  # Per-game telemetry cap: at the 80ms tick this is ~5min of play — no real
  # game lasts that long, but a stuck one must not grow memory unbounded.
  @trace_cap 4000
  # Half-width (screen points) of the playing-time capture strip around the
  # bar: wide enough for the track + the fish poking past it, and ~8x cheaper
  # to capture and scan than the whole arena.
  @strip_half_pt 40

  @spec new() :: t
  def new, do: %__MODULE__{}

  @spec holding?(t) :: boolean
  def holding?(%__MODULE__{holding?: holding?}), do: holding?

  @spec armed?(t) :: boolean
  def armed?(%__MODULE__{strip: strip}), do: strip != nil

  @doc """
  Arm the capture strip from the ENTERING detection: the overlay never moves
  within one game, so the play loop can capture just a narrow strip around the
  bar — much cheaper than arena + Detector, which is what lets the play tick
  run at 80ms.
  """
  @spec arm(t, Pokex.Calibration.t(), Pokex.Rig.region(), Detector.t()) :: t
  def arm(%__MODULE__{} = player, calib, {rx, ry, _rw, rh}, %Detector{bar: bar})
      when is_map(bar) do
    scale = calib.scale || 1.0
    center = rx + round(bar.x / scale)

    strip = {max(center - @strip_half_pt, 0), ry, @strip_half_pt * 2, rh}
    %{player | strip: strip, bar_width: bar.width}
  end

  def arm(player, _calib, _region, _reading), do: player

  @doc """
  One play tick: capture the strip, read the track, decide, actuate.

    * `{:present, player}` — overlay seen, decision applied
    * `{:blind, player}` — track there but fish unreadable (released if holding)
    * `{:absent, player}` — overlay gone this tick (released if holding)
    * `{:capture_error, reason, player}` — blind tick, released if holding
  """
  @spec tick(t) ::
          {:present | :blind | :absent, t} | {:capture_error, term, t}
  def tick(%__MODULE__{strip: strip} = player) when strip != nil do
    # Stamped BEFORE the capture: observations must carry the CAPTURE time, so
    # the pilot's age_ms covers the real capture+decode latency and the
    # predictive extrapolation compensates it (the lab's "latencia" knob).
    captured_at = System.monotonic_time(:millisecond)

    case Capture.frame(strip, "mini_game_strip.png") do
      {:ok, frame} ->
        capture_ms = System.monotonic_time(:millisecond) - captured_at
        play_frame(player, frame, captured_at, capture_ms)

      {:error, reason} ->
        # A blind tick must not leave Space held.
        {:capture_error, reason, release_if_holding(player)}
    end
  end

  @doc "Release Space only when this player believes it is holding."
  @spec release_if_holding(t) :: t
  def release_if_holding(%__MODULE__{holding?: true} = player), do: force_release(player)
  def release_if_holding(player), do: player

  @doc """
  Unconditional key_up: `holding?` can desync from the OS (a failed key_down
  report, a crash between the Rig call and the state update), so exit paths
  always send the release. Bypasses the min-toggle floor — safety over pacing.
  """
  @spec force_release(t) :: t
  def force_release(%__MODULE__{} = player) do
    safe_key_up()
    %{player | holding?: false}
  end

  @doc "Best-effort Space release for terminate paths (never raises)."
  @spec safe_key_up() :: :ok
  def safe_key_up do
    Rig.impl().key_up("space")
    :ok
  catch
    _kind, _reason -> :ok
  end

  @doc """
  Dump the per-game physics trace — everything needed to FIT the real bar
  physics offline (rise/fall acceleration, terminal speeds, true actuation
  latency) instead of guessing the braking constants. One JSON per game under
  `~/.pokex/exports`. Returns `{:ok, path, samples}`, `:skip` (too short) or
  `{:error, reason}`.
  """
  @spec dump_trace(t) :: {:ok, String.t(), pos_integer} | :skip | {:error, term}
  def dump_trace(%__MODULE__{trace: trace}) when length(trace) < 5, do: :skip

  def dump_trace(%__MODULE__{trace: trace}) do
    dir = Path.join(Pokex.Home.dir(), "exports")
    File.mkdir_p!(dir)
    path = Path.join(dir, "mini_game_trace-#{System.os_time(:millisecond)}.json")

    payload = %{
      settings: %{
        play_tick_ms: Settings.get(:mini_game_play_tick_ms),
        deadband_pct: Settings.get(:mini_game_deadband_pct),
        actuation_ms: Rig.impl().hold_latency_ms(),
        brake_up: Settings.get(:mini_game_brake_up),
        brake_down: Settings.get(:mini_game_brake_down)
      },
      samples: trace
    }

    File.write!(path, JSON.encode!(payload))
    {:ok, path, length(trace)}
  rescue
    error -> {:error, error}
  end

  # --- one frame -------------------------------------------------------------

  defp play_frame(
         %__MODULE__{strip: {_sx, _sy, sw, _sh}} = player,
         frame,
         captured_at,
         capture_ms
       ) do
    # The bar sits at the strip's center; scale point-geometry to frame px.
    track_bar = %{x: round(@strip_half_pt * frame.width / sw), width: player.bar_width}

    case Track.read(frame, track_bar) do
      # Present readings with NO blue anywhere: without the capsule this is not
      # our overlay anymore — after a WIN the world behind the strip can hold a
      # fake dark "track" + clutter-fish forever (the 2026-07-20 hang: every
      # tick read present and the exit streak never fired, freezing the whole
      # self-held bot). In real play the capsule's blue pokes out on virtually
      # every tick (measured 86/86), so a streak of blue-less frames is an END
      # signal, reported as :absent for the worker's normal exit path.
      {:ok, %{bar_source: :fish}} = reading ->
        streak = player.no_capsule_streak + 1

        if streak >= Settings.get(:mini_game_no_capsule_exit_ticks) do
          {:absent, release_if_holding(%{player | no_capsule_streak: streak})}
        else
          play_reading(%{player | no_capsule_streak: streak}, reading, captured_at, capture_ms)
        end

      {:ok, _fish_and_blue} = reading ->
        play_reading(%{player | no_capsule_streak: 0}, reading, captured_at, capture_ms)

      {:error, :no_fish} ->
        # Track still there, fish unreadable this frame: blind ticks fail SAFE
        # (release), but the overlay is present — not an exit signal.
        {:blind, release_if_holding(player)}

      {:error, :no_track} ->
        {:absent, release_if_holding(player)}
    end
  end

  defp play_reading(player, {:ok, reading}, captured_at, capture_ms) do
    %{fish_y: fish_y, bar_y: bar_y, bar_source: bar_source} = reading

    # Fish readings pass the plausibility gate: a teleporting misread must
    # not re-aim the pilot (it flew the capsule to the track top while the
    # real fish sat at the bottom — live traces, 2026-07-20).
    fish =
      player.fish
      |> Pilot.accept_target(%{y: fish_y, at: captured_at},
        max_speed: Settings.get(:mini_game_fish_max_speed),
        reacquire_ms: Settings.get(:mini_game_fish_reacquire_ms)
      )
      |> Enum.take(-@observation_cap)

    capsule =
      push_observation(player.capsule, %{y: bar_y, at: captured_at, source: bar_source})

    # Decision time is NOW, observations carry capture time: age_ms > 0 is
    # exactly the capture latency the predictive pilot extrapolates over.
    now = System.monotonic_time(:millisecond)

    decision =
      Pilot.decide(
        %{
          pilot: :predictive,
          deadband_pct: Settings.get(:mini_game_deadband_pct),
          actuation_ms: Rig.impl().hold_latency_ms(),
          brake_up: Settings.get(:mini_game_brake_up),
          brake_down: Settings.get(:mini_game_brake_down)
        },
        fish,
        %{
          y: bar_y,
          vy: Pilot.capsule_velocity(capsule),
          pressing: player.holding?,
          at: captured_at
        },
        now
      )

    player =
      %{player | fish: fish, capsule: capsule}
      |> actuate(decision.desired, now)

    sample = %{
      t: captured_at,
      cap_ms: capture_ms,
      fish: Float.round(fish_y, 4),
      aim: Float.round(List.last(fish).y, 4),
      bar: Float.round(bar_y, 4),
      src: bar_source,
      target: decision.target_y && Float.round(decision.target_y, 4),
      desired: decision.desired,
      hold: player.holding?
    }

    {:present, record_trace(player, sample)}
  end

  defp push_observation(observations, observation),
    do: Enum.take(observations ++ [observation], -@observation_cap)

  defp actuate(%__MODULE__{holding?: desired} = player, desired, _now), do: player

  defp actuate(player, desired, now) do
    last = player.last_toggle_at

    if last != nil and now - last < Settings.get(:mini_game_min_toggle_ms) do
      player
    else
      apply_hold(desired)
      %{player | holding?: desired, last_toggle_at: now}
    end
  end

  # A failed hold call desyncs holding? from the OS until the next
  # exit-boundary release — surface it instead of failing silently.
  defp apply_hold(desired) do
    result = if desired, do: Rig.impl().key_down("space"), else: Rig.impl().key_up("space")

    with {:error, reason} <- result do
      Logger.warning(
        "mini-game: espaço #{if desired, do: "down", else: "up"} falhou: #{inspect(reason)}"
      )

      result
    end
  end

  defp record_trace(%__MODULE__{trace: trace} = player, sample) do
    if length(trace) >= @trace_cap,
      do: player,
      else: %{player | trace: trace ++ [sample]}
  end
end
