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

  defp pairwise_velocity(older, newer) do
    elapsed = max(@elapsed_floor_ms, newer.at - older.at)
    (newer.y - older.y) / elapsed * 1000
  end

  defp clamp(value, min, max), do: value |> max(min) |> min(max)
end
