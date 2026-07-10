# Fishing Lab: Low-FPS Vision Simulation + Predictive Pilot — Design

**Date:** 2026-07-10
**Status:** approved by Lucas (approach 1: everything client-side in the lab)
**Context:** the real vision pipeline sees the game at ~6.7–10 fps (mini_game feed tick 150ms;
SCK capped at 10fps after the pool-starvation fix), while the game animates at 60fps. The lab's
autopilot currently samples the canvas EVERY rAF frame (~60fps), so it validates nothing about
real conditions. This task makes the lab the proving ground for the pilot that will later play
the real mini-game: simulate the low vision rate, expose it as a parameter, and add a
predictive pilot to compare against the current reactive one. The follow-up task ports the
validated pilot to Elixir; nothing in this task touches Elixir bot code or settings.

## 1. Low-FPS vision simulation (`assets/js/fishing_lab.js`)

- `sampleObservation` becomes clock-gated: sample only when
  `now - vision.lastSampleAt >= 1000 / config.visionFps`. Between samples the pilot receives
  nothing new — exactly like the real feed. The 60fps rAF loop (physics, drawing, pilot
  decisions) is unchanged; only OBSERVING is throttled.
- New slider **"FPS da visão"**: range 2–60, step 1, default **7** (≈ the real 150ms tick).
  Output label shows both units: `7 fps · ~143ms`.
- New slider **"Leituras perdidas"**: 0–40%, step 5, default **0%**. Each sampled frame is
  discarded with this probability BEFORE entering the queue (no queue push, no vision-marker
  update) — simulates a failed/low-confidence read. A lost frame still counts as a sampling
  tick (the next attempt waits the full interval).
- The existing **latency slider keeps its exact semantics** (capture→decision delay,
  `latencyMs + jitter rand(-18, 26)` on queue delivery). Two independent realities: how OFTEN
  we see × how OLD each reading is.
- The "FPS visão" stat now reflects the effective accepted-sample rate (same lerp smoothing,
  updated per accepted sample), so throttling to 7 reads ~7, and losses lower it visibly.
- Header copy: the "60 FPS no navegador" badge becomes "jogo a 60 FPS · visão configurável".

## 2. Pilot module (`assets/js/fishing_pilot.js`, new file)

Pure decision module — no DOM, no canvas, no timers — so the future Elixir port is a 1:1
transcription with the lab-validated constants.

```js
// observations: accepted readings, oldest→newest, capped at 4: [{y, at}, ...]
// bar: {y, vy, pressing}
// config: {pilot: "reactive" | "predictive", deadbandPx}
// returns {desired: boolean, targetY: number|null, ageMs: number|null}
decide(config, observations, bar, now)
```

- **Reactive (atual)** — the current `updateAi` logic moved verbatim (plus the shared stale
  fail-safe below, which never fired at 60fps anyway): latest observation as
  position, velocity from the last pair, `lead = clamp(vy * 0.11, -34, 34)`,
  `targetY = clamp(y + lead, TRACK.top, TRACK.bottom)`, deadband hysteresis with the existing
  bar-velocity terms (±120/135 thresholds, 0.7 deadband factors). This is the baseline.
- **Predictive (novo)** — same actuation rule, better target:
  - velocity from the last up-to-3 observations (average of pairwise slopes, weighted 2:1
    toward the most recent pair);
  - `ageS = (now - newest.at) / 1000`;
  - velocity trust decays with age: `vyEff = vy * Math.pow(0.25, ageS)` (the fish reverses on
    a ~0.5–1.5s scale — old velocity is worse than less velocity);
  - `predictedY = clamp(newest.y + vyEff * ageS, TRACK.top, TRACK.bottom)`;
  - `targetY = clamp(predictedY + clamp(vyEff * 0.11, -34, 34), TRACK.top, TRACK.bottom)`
    (the lead now covers only actuation response, since extrapolation already covers age).
- **Stale fail-safe (both pilots):** newest observation older than **1500ms** → `desired:
  false` (release, don't chase a ghost). No observations at all → `{desired: false,
  targetY: null, ageMs: null}`.
- The hook keeps owning the queue/latency machinery and the 50ms min-toggle; it feeds the
  module the accepted-observation history and applies `desired` through the existing
  `setPressing`.

## 3. Comparison UI (`fishing_lab_live.ex` markup + hook wiring)

- **Pilot selector**: segmented pair of buttons "Reativo | Preditivo" beside the Auto toggle
  (`data-lab-pilot="reactive|predictive"`), active one highlighted; default **predictive**.
  Only meaningful while Auto is on (selector stays visible regardless).
- **Scoreboard**: `data-stat="score"` shows `3V · 1D`. Win = round ends with progress ≥ 100;
  anything else (−30 floor or 45s timeout) is a loss. Resets to `0V · 0D` when ANY parameter
  changes (any slider, vision toggle, pilot switch) or on "Reiniciar". "Nova cor" does NOT
  reset it. This lets Lucas run N rounds per pilot at identical parameters and compare numbers.
- **Pilot target marker**: a dashed **yellow** line at the pilot's current `targetY` whenever
  Auto is on (both pilots). The existing white dashed line stays = last raw vision reading.
  The gap between yellow (belief) and the fish (truth) IS the low-fps story, live.
- **New stats** in the pilot grid: "Leitura há" (`data-stat="reading-age"`, ms since the
  newest accepted observation, updated with the UI throttle) joins the existing four; the
  scoreboard takes the sixth cell.

## 4. Untouched + testing

- Fish physics, bar physics, progress rules, manual mode, pixel-detection toggle, fish colors:
  unchanged. No Elixir bot/settings changes; `fishing_lab_live.ex` only gains markup.
- No JS test infra exists (consistent with the current lab) — validation is Lucas in the lab.
  The real pilot tests come with the Elixir port in the follow-up task.
- `test/pokex_web/live/fishing_lab_live_test.exs` extends to assert the new controls render
  (FPS da visão slider, Leituras perdidas slider, pilot selector, scoreboard stat).
- Never run `mix assets.build` while the dev server runs — the esbuild watcher picks up the
  JS changes (see preview live-reload rule).
