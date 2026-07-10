// Pure decision module for the fishing mini-game autopilot.
//
// No DOM, no canvas, no timers — every input arrives as an argument, so the
// future Elixir port (the bot playing the REAL mini-game) is a 1:1
// transcription of this file with the constants validated in the lab.
//
// observations: accepted vision readings, oldest -> newest (caller caps the
//   length): [{y, at}, ...] — `at` is the CAPTURE timestamp in ms.
// bar: {y, vy, pressing}
// config: {pilot: "reactive" | "predictive", deadbandPx, trackTop, trackBottom}
// returns {desired: boolean, targetY: number | null, ageMs: number | null}

const STALE_MS = 1500
const LEAD_SECONDS = 0.11
const LEAD_MAX_PX = 34
const VELOCITY_DECAY_PER_SECOND = 0.25

const clamp = (value, min, max) => Math.min(max, Math.max(min, value))

const pairwiseVelocity = (older, newer) => {
  const elapsed = Math.max(16, newer.at - older.at)
  return ((newer.y - older.y) / elapsed) * 1000
}

// Reactive uses ONLY the newest pair — today's lab logic verbatim.
const lastPairVelocity = observations => {
  if (observations.length < 2) return 0
  return pairwiseVelocity(observations[observations.length - 2], observations[observations.length - 1])
}

// Predictive blends the last up-to-3 observations: pairwise slopes with the
// most recent pair weighted 2:1 (it knows the fish's current intent best).
const blendedVelocity = observations => {
  if (observations.length < 2) return 0

  const recent = observations.slice(-3)
  const newestPair = pairwiseVelocity(recent[recent.length - 2], recent[recent.length - 1])
  if (recent.length < 3) return newestPair

  const olderPair = pairwiseVelocity(recent[0], recent[1])
  return (newestPair * 2 + olderPair) / 3
}

const targetFor = (config, observations, now) => {
  const newest = observations[observations.length - 1]
  const ageMs = now - newest.at

  if (config.pilot === "reactive") {
    const lead = clamp(lastPairVelocity(observations) * LEAD_SECONDS, -LEAD_MAX_PX, LEAD_MAX_PX)
    return {targetY: clamp(newest.y + lead, config.trackTop, config.trackBottom), ageMs}
  }

  // Predictive: extrapolate to `now`, trusting old velocity less — the fish
  // reverses on a ~0.5-1.5s scale, so a stale slope is worse than a small one.
  const ageSeconds = ageMs / 1000
  const decayedVelocity = blendedVelocity(observations) * Math.pow(VELOCITY_DECAY_PER_SECOND, ageSeconds)
  const predictedY = clamp(newest.y + decayedVelocity * ageSeconds, config.trackTop, config.trackBottom)
  const lead = clamp(decayedVelocity * LEAD_SECONDS, -LEAD_MAX_PX, LEAD_MAX_PX)

  return {targetY: clamp(predictedY + lead, config.trackTop, config.trackBottom), ageMs}
}

export const decide = (config, observations, bar, now) => {
  if (observations.length === 0) return {desired: false, targetY: null, ageMs: null}

  const {targetY, ageMs} = targetFor(config, observations, now)

  // Stale fail-safe (both pilots): never chase a ghost.
  if (ageMs > STALE_MS) return {desired: false, targetY, ageMs}

  // Shared actuation rule — the current lab hysteresis verbatim. Positive
  // error = bar below the target (canvas y grows downward; pressing thrusts up).
  const error = bar.y - targetY
  const deadband = config.deadbandPx
  let desired = bar.pressing

  if (error > deadband || (bar.vy > 120 && error > -deadband * 0.7)) {
    desired = true
  } else if (error < -deadband || (bar.vy < -135 && error < deadband * 0.7)) {
    desired = false
  }

  return {desired, targetY, ageMs}
}

export default {decide}
