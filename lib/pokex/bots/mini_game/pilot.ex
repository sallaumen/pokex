defmodule Pokex.Bots.MiniGame.Pilot do
  @moduledoc """
  Pure decision core for playing the fishing mini-game: hold or release Space.

  1:1 port of the lab-validated `assets/js/fishing_pilot.js` (2026-07-10 —
  Lucas validated the predictive pilot at 3fps vision, deadband 6px). All
  positions are TRACK-NORMALIZED (0.0 = track top, 1.0 = bottom) and all
  velocities are track-fractions per second, so the constants transfer from
  the lab's 548px track to the real overlay regardless of capture size.

  observations: accepted vision readings, oldest -> newest (caller caps the
    length): [%{y: 0..1, at: ms}] — `at` is the CAPTURE timestamp.
  bar: %{y: 0..1, vy: track/s (caller-estimated), pressing: boolean} plus an
    optional :at (capture timestamp): when present, the bar is extrapolated to
    decision time + the actuation delay before judging the error — deciding on
    the stale bar position is what made the real capsule overshoot up/down
    past a near-stable fish (the sim handed the EXACT bar position; reality
    hands one ~100-300ms old, and the command takes ~90ms more to land).
  config: %{pilot: :reactive | :predictive, deadband_pct: float} plus an
    optional :actuation_ms (hold/release command landing time).
  returns %{desired: boolean, target_y: float | nil, age_ms: integer | nil}
  """

  @stale_ms 1500
  @lead_s 0.11
  # lab 34px / 548
  @lead_max 0.062
  @velocity_decay 0.25
  @elapsed_floor_ms 16
  # Below this |vy| the bar is hovering: plain position control, no braking math.
  @coast_epsilon 0.02
  # Stopping-distance braking defaults (track/s²) — REAL-game physics is
  # asymmetric: thrust is strong (a fall is arrested almost instantly → brake
  # late, sink to the fish) while gravity is weak (a rise coasts far after
  # release → let go early). brake_up FIT from live traces (2026-07-11):
  # falling acceleration ≈ 0.7-0.95 track/s².
  @default_brake_up 0.8
  @default_brake_down 3.0

  @typedoc "Track-normalized vision reading: y in 0..1, at = capture timestamp (ms)."
  @type observation :: %{
          required(:y) => float,
          required(:at) => integer,
          optional(:source) => atom
        }

  @typedoc "Player bar state; :at enables extrapolation to command-landing time."
  @type bar :: %{
          required(:y) => float,
          required(:vy) => float,
          required(:pressing) => boolean,
          optional(:at) => integer
        }

  @type config :: %{
          required(:pilot) => :reactive | :predictive,
          required(:deadband_pct) => float,
          optional(:actuation_ms) => non_neg_integer,
          optional(:brake_up) => float,
          optional(:brake_down) => float
        }

  @type decision :: %{
          desired: boolean,
          target_y: float | nil,
          age_ms: non_neg_integer | nil
        }

  @spec decide(config, [observation], bar, integer) :: decision
  def decide(_config, [], _bar, _now), do: %{desired: false, target_y: nil, age_ms: nil}

  def decide(config, observations, bar, now) do
    {target_y, age_ms} = target_for(config, observations, now)

    if age_ms > @stale_ms do
      # Stale fail-safe (both pilots): never chase a ghost.
      %{desired: false, target_y: target_y, age_ms: age_ms}
    else
      %{desired: desired?(config, bar, target_y, now), target_y: target_y, age_ms: age_ms}
    end
  end

  # Actuation rule, judged at the position the bar WILL occupy when the command
  # lands (reading age + actuation delay). Positive error = bar below the target
  # (y grows downward; holding Space raises the bar). While the bar is moving,
  # braking is by STOPPING DISTANCE (v²/2a) with per-direction deceleration:
  # rising coasts far after release (weak gravity), falling stops almost
  # instantly under thrust — so a rise releases early and a fall presses only
  # at the fish.
  defp desired?(config, bar, target_y, now) do
    bar_age_s =
      case Map.get(bar, :at) do
        nil -> 0.0
        at -> (now - at) / 1000
      end

    horizon_s = bar_age_s + Map.get(config, :actuation_ms, 0) / 1000
    predicted_bar = clamp(bar.y + bar.vy * horizon_s, 0.0, 1.0)

    error = predicted_bar - target_y
    deadband = config.deadband_pct
    vy = bar.vy

    cond do
      # Rising: if releasing NOW still coasts to/above the target, release —
      # any later overshoots ("sobe demais").
      vy < -@coast_epsilon and
          predicted_bar - vy * vy / (2 * Map.get(config, :brake_up, @default_brake_up)) <=
            target_y ->
        false

      # Falling: keep falling while full thrust from NOW would still stop
      # short of the target; press only when the stop point reaches the fish —
      # the bar sinks to (a hair past) the center instead of retreating early.
      vy > @coast_epsilon and
          predicted_bar + vy * vy / (2 * Map.get(config, :brake_down, @default_brake_down)) >=
            target_y ->
        true

      error > deadband ->
        true

      error < -deadband ->
        false

      true ->
        bar.pressing
    end
  end

  defp target_for(%{pilot: :reactive}, observations, now) do
    newest = List.last(observations)
    lead = clamp(last_pair_velocity(observations) * @lead_s, -@lead_max, @lead_max)
    {clamp(newest.y + lead, 0.0, 1.0), now - newest.at}
  end

  # Predictive: extrapolate to `now`, trusting old velocity less — the fish
  # reverses on a ~0.5-1.5s scale, so a stale slope is worse than a small one.
  defp target_for(%{pilot: :predictive}, observations, now) do
    newest = List.last(observations)
    age_ms = now - newest.at
    age_s = age_ms / 1000

    decayed_velocity = blended_velocity(observations) * :math.pow(@velocity_decay, age_s)
    predicted_y = clamp(newest.y + decayed_velocity * age_s, 0.0, 1.0)
    lead = clamp(decayed_velocity * @lead_s, -@lead_max, @lead_max)

    {clamp(predicted_y + lead, 0.0, 1.0), age_ms}
  end

  @doc """
  The TARGET's estimated velocity (track/s) — the very number the predictive
  pilot aims with, exposed for diagnostics. Not a second estimator: it is the
  same `blended_velocity/1` the decision path uses, so a report can never
  disagree with the flight it is explaining.
  """
  @spec target_velocity([observation]) :: float
  def target_velocity([]), do: 0.0
  def target_velocity(observations), do: blended_velocity(observations)

  # Reactive uses ONLY the newest pair — the lab logic verbatim.
  defp last_pair_velocity(observations) when length(observations) < 2, do: 0.0

  defp last_pair_velocity(observations) do
    [older, newer] = Enum.take(observations, -2)
    pairwise_velocity(older, newer)
  end

  # Predictive blends the last up-to-3 observations: pairwise slopes with the
  # most recent pair weighted 2:1. Observations from before a long blind gap
  # are dropped first — a pre-gap slope next to one fresh reading would be
  # trusted as current and aim past a fish that already reversed.
  defp blended_velocity(observations) do
    newest = List.last(observations)
    fresh = Enum.filter(observations, fn obs -> newest.at - obs.at <= @stale_ms end)

    case Enum.take(fresh, -3) do
      recent when length(recent) < 2 ->
        0.0

      [older, newer] ->
        pairwise_velocity(older, newer)

      [first, second, third] ->
        (pairwise_velocity(second, third) * 2 + pairwise_velocity(first, second)) / 3
    end
  end

  # The fish tops out ~1.3 track/s (measured from live traces, 2026-07-20);
  # a reading implying more is a MISREAD, not motion.
  @default_max_target_speed 2.0
  # How long a held (last plausible) aim may block disagreeing readings before
  # the AIM itself is presumed wrong. Phantom episodes measured 1-3 frames
  # (~180-550ms); real re-acquisition (game restart mid-history) is rarer and
  # slower. Must stay under @stale_ms so the gate can never starve the pilot
  # into the permanent stale fail-safe.
  @default_reacquire_ms 700

  @doc """
  Plausibility gate for FISH readings — the counterpart of the capsule's
  impossible-jump protection, for the target: a reading that implies a
  physically impossible fish speed vs the last ACCEPTED reading is a misread
  (live 2026-07-20: 0.917 -> 0.000 in 182ms, ~5 track/s — the pilot chased
  the phantom to the track top while the real fish sat at the bottom), so it
  is DROPPED and the aim holds. If the disagreement outlives `:reacquire_ms`,
  the new reading is adopted and the history RESTARTS — appending would blend
  a velocity across the warp and aim at a ghost in between.

  Options: `:max_speed` (track/s, #{@default_max_target_speed}),
  `:reacquire_ms` (#{@default_reacquire_ms}).
  """
  @spec accept_target([observation], observation, keyword) :: [observation]
  def accept_target(history, obs, opts \\ []),
    do: history |> judge_target(obs, opts) |> elem(1)

  @typedoc "Why the gate did what it did — the verdict `accept_target/3` discards."
  @type verdict :: :accepted | {:rejected, :impossible_speed} | {:restarted, :reacquired}

  @doc """
  `accept_target/3` plus the REASON, for diagnostics: the gate's verdict is the
  single most informative thing about a bad game (a rejection spell means the
  aim FROZE while the fish moved), and the plain call throws it away. Same
  math, same history — `accept_target/3` is this function's second element.
  """
  @spec judge_target([observation], observation, keyword) :: {verdict, [observation]}
  def judge_target(history, obs, opts \\ []) do
    case List.last(history) do
      nil ->
        {:accepted, history ++ [obs]}

      last ->
        max_speed = opts[:max_speed] || @default_max_target_speed
        reacquire_ms = opts[:reacquire_ms] || @default_reacquire_ms
        speed = abs(pairwise_velocity(last, obs))

        cond do
          # Impossible speed: a misread. Hold the aim — each further rejection
          # widens the dt to the last ACCEPTED reading, so a PERSISTENT
          # disagreement dilutes below the ceiling by itself and lands in the
          # restart branch: blindness is bounded without trusting any phantom.
          speed > max_speed -> {{:rejected, :impossible_speed}, history}
          # Plausible, but the last accepted reading is old (a rejection spell
          # or a blind gap): restart at the new reading — appending would blend
          # a velocity across the gap and aim at a ghost in between.
          obs.at - last.at >= reacquire_ms -> {{:restarted, :reacquired}, [obs]}
          true -> {:accepted, history ++ [obs]}
        end
    end
  end

  # Estimated velocity of the PLAYER capsule (track/s) from its readings — the
  # lab read this straight from the simulator's physics; reality estimates it.
  # Three protections, all measured live: only the trailing run of SAME-SOURCE
  # readings counts (a blue<->occlusion source flip jumps by the centroid
  # offset, not real motion); up to 3 readings blend 2:1 toward the newest pair
  # (single pairs are row-quantization noisy); and physically impossible jumps
  # (the bar tops out ~1.2 track/s) read as 0 — a misread must not command a
  # braking slam. Lives HERE so the Pilot owns ALL kinematics.
  @max_capsule_speed 1.5

  @spec capsule_velocity([observation]) :: float
  def capsule_velocity(observations) do
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

  defp capsule_pair_velocity(older, newer) do
    velocity = pairwise_velocity(older, newer)

    if abs(velocity) > @max_capsule_speed, do: 0.0, else: velocity
  end

  defp pairwise_velocity(older, newer) do
    elapsed = max(@elapsed_floor_ms, newer.at - older.at)
    (newer.y - older.y) / elapsed * 1000
  end

  defp clamp(value, min, max), do: value |> max(min) |> min(max)
end
