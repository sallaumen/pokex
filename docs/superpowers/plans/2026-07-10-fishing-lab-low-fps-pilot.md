# Fishing Lab Low-FPS Vision + Predictive Pilot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Fishing Lab simulates the real bot's low vision rate (~7fps vs the game's 60fps) and gains a predictive pilot so Lucas can compare pilots under identical parameters.

**Architecture:** All client-side (spec approach 1). A new pure module `assets/js/fishing_pilot.js` holds both pilots behind one `decide/4` function (the future Elixir port transcribes this file). The existing `FishingLab` hook throttles vision sampling by a clock, optionally drops reads, feeds the pilot an observation history, and renders comparison UI (scoreboard, reading age, yellow target marker). `fishing_lab_live.ex` only gains markup.

**Tech Stack:** Phoenix LiveView (markup + ExUnit render test), vanilla JS canvas hook (esbuild-bundled), Node for syntax/behavior scratch checks.

**Spec:** `docs/superpowers/specs/2026-07-10-fishing-lab-low-fps-pilot-design.md`

## Global Constraints

- Defaults: `visionFps: 7`, `lossPct: 0`, `pilot: "predictive"`.
- Pilot constants: stale fail-safe **1500ms** → release; lead `clamp(vy * 0.11, -34, 34)`; predictive velocity decay `Math.pow(0.25, ageSeconds)`; velocity from last up-to-3 observations, most recent pair weighted 2:1 (reactive uses ONLY the last pair — it is today's logic verbatim).
- Sliders: "FPS da visao" 2–60 step 1 default 7 (output `7 fps · ~143ms`); "Leituras perdidas" 0–40 step 5 default 0 (output `0%`).
- Scoreboard `XV · YD` resets on ANY parameter change (every slider, vision toggle, pilot switch) and on "Reiniciar"; NOT on "Nova cor". Win = round ends with progress ≥ 100.
- Lab copy is ASCII-only (no accents) — matches every existing string in `fishing_lab_live.ex` and `fishing_lab.js` ("Deteccao", "Confianca", "automatico"). Write "visao", "Ultima leitura".
- NEVER run `mix assets.build` or `mix esbuild` — Lucas's dev server watcher owns bundling. JS syntax checks go through `node --check` on a scratch `.mjs` copy.
- No Elixir bot/settings changes anywhere in this plan.
- Scratch dir for throwaway scripts: use the session scratchpad (or `/tmp/pokex-lab-scratch`), never the repo.

---

### Task 1: Pure pilot module (`fishing_pilot.js`)

**Files:**
- Create: `assets/js/fishing_pilot.js`
- Test: scratch Node script (NOT committed — the repo has no JS test infra by design; behavior is verified now via Node asserts and later by the Elixir port's ExUnit tests)

**Interfaces:**
- Consumes: nothing (pure module).
- Produces: `decide(config, observations, bar, now) -> {desired: boolean, targetY: number|null, ageMs: number|null}` where `config = {pilot: "reactive"|"predictive", deadbandPx, trackTop, trackBottom}`, `observations = [{y, at}, ...]` oldest→newest (caller caps length), `bar = {y, vy, pressing}`. Task 2 imports `{decide}` from `"./fishing_pilot"`.

- [ ] **Step 1: Write the failing scratch test**

Create `/tmp/pokex-lab-scratch/test_fishing_pilot.mjs`:

```js
import assert from "node:assert/strict"
import {decide} from "./fishing_pilot.mjs"

const config = {pilot: "reactive", deadbandPx: 13, trackTop: 76, trackBottom: 624}
const predictive = {...config, pilot: "predictive"}
const bar = (y, vy = 0, pressing = false) => ({y, vy, pressing})
const now = 10_000

// no observations -> released, no target
assert.deepEqual(decide(config, [], bar(400), now), {desired: false, targetY: null, ageMs: null})

// stale newest observation (>1500ms) -> released even with a far target
{
  const result = decide(config, [{y: 100, at: now - 1600}], bar(400), now)
  assert.equal(result.desired, false)
  assert.equal(result.ageMs, 1600)
}

// reactive: bar far below a fresh target -> press (error 100 > deadband 13)
{
  const result = decide(config, [{y: 300, at: now}], bar(400), now)
  assert.equal(result.desired, true)
  assert.equal(result.targetY, 300)
  assert.equal(result.ageMs, 0)
}

// reactive lead: fish rising at -200px/s -> target above the newest reading
{
  const observations = [{y: 340, at: now - 100}, {y: 320, at: now}]
  const result = decide(config, observations, bar(400), now)
  assert.ok(Math.abs(result.targetY - 298) < 0.001, `lead target ${result.targetY}`)
}

// reactive hysteresis: inside the deadband nothing changes (stays pressing)
assert.equal(decide(config, [{y: 320, at: now}], bar(310, 0, true), now).desired, true)

// reactive release: bar above target beyond the deadband
assert.equal(decide(config, [{y: 320, at: now}], bar(300, 0, false), now).desired, false)

// predictive: extrapolates PAST the newest reading in the direction of motion,
// with decayed velocity (newest is 150ms old, fish moving up at -200px/s)
{
  const observations = [{y: 340, at: now - 250}, {y: 320, at: now - 150}]
  const result = decide(predictive, observations, bar(400), now)
  assert.ok(result.targetY < 320, `expected extrapolation above 320, got ${result.targetY}`)
  assert.ok(result.targetY > 270, `expected sane extrapolation, got ${result.targetY}`)
  assert.equal(result.ageMs, 150)
}

// predictive: with THREE observations the older pair tempers the estimate 2:1
{
  const observations = [
    {y: 360, at: now - 350},
    {y: 340, at: now - 250},
    {y: 320, at: now - 150},
  ]
  const result = decide(predictive, observations, bar(400), now)
  assert.ok(result.targetY < 320 && result.targetY > 260, `got ${result.targetY}`)
}

// targets clamp to the track
{
  const observations = [{y: 90, at: now - 100}, {y: 80, at: now}]
  const result = decide(predictive, observations, bar(400), now)
  assert.ok(result.targetY >= 76, `clamped, got ${result.targetY}`)
}

console.log("fishing_pilot: all assertions passed")
```

- [ ] **Step 2: Run it to verify it fails**

```bash
mkdir -p /tmp/pokex-lab-scratch
# (write the test file above first)
cp assets/js/fishing_pilot.js /tmp/pokex-lab-scratch/fishing_pilot.mjs 2>/dev/null
cd /tmp/pokex-lab-scratch && node test_fishing_pilot.mjs
```

Expected: FAIL — `fishing_pilot.mjs` does not exist yet (cp fails / ERR_MODULE_NOT_FOUND).

- [ ] **Step 3: Write the module**

Create `assets/js/fishing_pilot.js`:

```js
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
```

- [ ] **Step 4: Run the scratch test to verify it passes**

```bash
cp assets/js/fishing_pilot.js /tmp/pokex-lab-scratch/fishing_pilot.mjs
cd /tmp/pokex-lab-scratch && node test_fishing_pilot.mjs
```

Expected: `fishing_pilot: all assertions passed`

(The `.mjs` copy exists only because Node treats bare `.js` without a `package.json` as CommonJS; `assets/` has no package.json and esbuild handles ESM natively.)

- [ ] **Step 5: Commit**

```bash
git add assets/js/fishing_pilot.js
git commit -m "lab: pure fishing pilot module (reactive + predictive)"
```

---

### Task 2: Hook integration — throttled vision, losses, pilot wiring, comparison state

**Files:**
- Modify: `assets/js/fishing_lab.js`

**Interfaces:**
- Consumes: `decide` from Task 1 (`import {decide} from "./fishing_pilot"`).
- Produces: hook behavior + DOM contracts Task 3 markup binds to: `data-lab-range="vision-fps"`, `data-lab-range="loss"`, `data-output="vision-fps"`, `data-output="loss"`, `data-lab-pilot="reactive"|"predictive"` (click → `setPilot`, active gets `btn-active`), `data-stat="score"`, `data-stat="reading-age"`. All are no-ops until the markup exists (empty querySelectorAll / null setStat).

- [ ] **Step 1: Import the pilot and extend config/state**

At the top of `assets/js/fishing_lab.js` add the import:

```js
import {decide} from "./fishing_pilot"
```

In `mounted()`, extend `this.config` and add the new state fields:

```js
    this.config = {
      difficulty: 0.65,
      latencyMs: 110,
      deadbandPx: 13,
      minToggleMs: Number(this.el.dataset.minToggleMs || 50),
      useVision: true,
      visionFps: 7,
      lossPct: 0,
      pilot: "predictive",
    }
```

Still in `mounted()`, right after `this.round = 1`, add:

```js
    this.lastSampleAt = 0
    this.score = {wins: 0, losses: 0}
    this.pilotView = {targetY: null, ageMs: null}
```

- [ ] **Step 2: Replace the AI state with an observation history**

In `resetRound(resetStats)`, replace the `this.ai = {...}` block with:

```js
    this.ai = {
      queue: [],
      history: [],
    }
```

and right after it add:

```js
    this.lastSampleAt = 0
    this.pilotView = {targetY: null, ageMs: null}
```

In `handleAction`, case `"toggle-auto"`, replace the two stale lines
(`this.ai.observedY = this.fish.y` and `this.ai.lastObservedAt = now`) so the block reads:

```js
      case "toggle-auto":
        this.auto = !this.auto
        this.ai.queue = []
        this.ai.history = []
        this.pilotView = {targetY: null, ageMs: null}
        this.forcePressing(false, now)
        this.setMessage(
          this.auto
            ? "Piloto automatico ligado. Ele usa a leitura atrasada do detector."
            : "Modo manual ligado. Clique no canvas e segure Space para subir."
        )
        break
```

In case `"toggle-vision"` add history flush and score reset so the block reads:

```js
      case "toggle-vision":
        this.config.useVision = node.checked
        this.ai.queue = []
        this.ai.history = []
        this.resetScore()
        this.setMessage(
          this.config.useVision
            ? "Deteccao por pixels ligada."
            : "Visao desligada: o piloto usa a posicao real do simulador."
        )
        break
```

In case `"reset"` add `this.resetScore()` before `this.resetRound(true)`.

- [ ] **Step 3: Clock-gate sampling + simulated losses**

Replace `sampleObservation(now)` with:

```js
  sampleObservation(now) {
    if (now - this.lastSampleAt < 1000 / this.config.visionFps) return
    this.lastSampleAt = now

    const observation = this.config.useVision
      ? this.detectFish(now)
      : {y: this.fish.y, confidence: 1, fps: this.nextFps(now)}

    // Simulated failed read: the sampling tick still happened (no early retry),
    // but nothing downstream sees it — no marker update, no queue push.
    if (Math.random() * 100 < this.config.lossPct) return

    this.vision = {
      y: observation.y,
      confidence: observation.confidence,
      fps: observation.fps,
      lastAt: now,
    }

    if (observation.y == null) return

    const jitter = rand(-18, 26)
    this.ai.queue.push({
      y: observation.y,
      at: now,
      readyAt: now + this.config.latencyMs + jitter,
    })

    if (this.ai.queue.length > 8) this.ai.queue.splice(0, this.ai.queue.length - 8)
  },

  nextFps(now) {
    const delta = Math.max(1, now - (this.vision?.lastAt || now - 16))
    return lerp(this.vision?.fps || 0, 1000 / delta, 0.08)
  },
```

In `detectFish(now)`, replace the two `delta`/`fps` lines with a single call so both
return paths use `fps: this.nextFps(now)`:

```js
    const fps = this.nextFps(now)
```

(delete the old `const delta = ...` line; both the `count < 18` return and the success
return keep passing `fps`.)

- [ ] **Step 4: Route decisions through the pilot module**

Replace `updateAi(now)` with:

```js
  updateAi(now) {
    if (!this.auto) return

    while (this.ai.queue.length > 0 && this.ai.queue[0].readyAt <= now) {
      const observation = this.ai.queue.shift()
      this.ai.history.push({y: observation.y, at: observation.at})
      if (this.ai.history.length > 4) this.ai.history.splice(0, this.ai.history.length - 4)
    }

    const result = decide(
      {
        pilot: this.config.pilot,
        deadbandPx: this.config.deadbandPx,
        trackTop: TRACK.top,
        trackBottom: TRACK.bottom,
      },
      this.ai.history,
      {y: this.bar.y, vy: this.bar.vy, pressing: this.bar.pressing},
      now
    )

    this.pilotView = {targetY: result.targetY, ageMs: result.ageMs}
    this.setPressing(result.desired, now)
  },
```

(Note: `history` keeps the CAPTURE timestamp `at`, not `readyAt` — age is measured
from when the frame was seen, exactly like the real pipeline's `captured_at`.)

- [ ] **Step 5: Pilot selector, scoreboard, new ranges**

In `bindControls()`, after the `[data-lab-range]` loop, add:

```js
    this.el.querySelectorAll("[data-lab-pilot]").forEach(node => {
      listen(node, "click", () => this.setPilot(node.dataset.labPilot))
    })
```

Add the two methods (next to `handleRange`):

```js
  setPilot(pilot) {
    if (this.config.pilot === pilot) return

    this.config.pilot = pilot
    this.ai.queue = []
    this.ai.history = []
    this.pilotView = {targetY: null, ageMs: null}
    this.resetScore()

    this.el.querySelectorAll("[data-lab-pilot]").forEach(node => {
      node.classList.toggle("btn-active", node.dataset.labPilot === pilot)
    })

    this.setMessage(
      pilot === "predictive"
        ? "Piloto preditivo: extrapola a posicao do peixe entre leituras."
        : "Piloto reativo: age sobre a ultima leitura crua."
    )
  },

  resetScore() {
    this.score = {wins: 0, losses: 0}
  },
```

In `handleRange(node)`, add the two cases and reset the scoreboard for EVERY range
(any parameter change invalidates the comparison):

```js
  handleRange(node) {
    const value = Number(node.value)

    switch (node.dataset.labRange) {
      case "difficulty":
        this.config.difficulty = value / 100
        this.setOutput("difficulty", `${value}%`)
        break
      case "latency":
        this.config.latencyMs = value
        this.setOutput("latency", `${value}ms`)
        break
      case "deadband":
        this.config.deadbandPx = value
        this.setOutput("deadband", `${value}px`)
        break
      case "vision-fps":
        this.config.visionFps = value
        this.setOutput("vision-fps", `${value} fps · ~${Math.round(1000 / value)}ms`)
        break
      case "loss":
        this.config.lossPct = value
        this.setOutput("loss", `${value}%`)
        break
      default:
        break
    }

    this.resetScore()
  },
```

In `updateProgress`, inside the round-end `if` (the one that sets `roundResetAt`),
right after `const won = this.progress >= 100`, add:

```js
      if (won) this.score.wins += 1
      else this.score.losses += 1
```

- [ ] **Step 6: Yellow target marker + new stats**

In `draw()`, after `this.drawVisionMarker(ctx)`, add `this.drawPilotMarker(ctx)`, and add the method:

```js
  drawPilotMarker(ctx) {
    if (!this.auto || this.pilotView?.targetY == null) return

    ctx.save()
    ctx.strokeStyle = "#facc15"
    ctx.lineWidth = 2
    ctx.setLineDash([8, 4])
    ctx.beginPath()
    ctx.moveTo(FISH_X - 68, this.pilotView.targetY)
    ctx.lineTo(TRACK.x + 34, this.pilotView.targetY)
    ctx.stroke()
    ctx.restore()
  },
```

In `updateUi(now)`, after the `setStat("round", ...)` line, add:

```js
    this.setStat("score", `${this.score.wins}V · ${this.score.losses}D`)
    this.setStat("reading-age", this.readingAgeLabel(now))
```

and add the helper:

```js
  readingAgeLabel(now) {
    const newest = this.ai.history[this.ai.history.length - 1]
    if (!newest) return "—"
    return `${Math.round(now - newest.at)}ms`
  },
```

- [ ] **Step 7: Syntax-check both files (no assets.build!)**

```bash
mkdir -p /tmp/pokex-lab-scratch
cp assets/js/fishing_lab.js /tmp/pokex-lab-scratch/fishing_lab.mjs
cp assets/js/fishing_pilot.js /tmp/pokex-lab-scratch/fishing_pilot.mjs
node --check /tmp/pokex-lab-scratch/fishing_lab.mjs
node --check /tmp/pokex-lab-scratch/fishing_pilot.mjs
cd /tmp/pokex-lab-scratch && node test_fishing_pilot.mjs
```

Expected: no output from the two `--check`s; `fishing_pilot: all assertions passed`.
(`--check` parses without resolving imports, so the `"./fishing_pilot"` specifier is fine.)

- [ ] **Step 8: Commit**

```bash
git add assets/js/fishing_lab.js
git commit -m "lab: throttled vision sampling, simulated losses, pilot selector state"
```

---

### Task 3: Lab markup + LiveView render test

**Files:**
- Modify: `lib/pokex_web/live/fishing_lab_live.ex`
- Test: `test/pokex_web/live/fishing_lab_live_test.exs`

**Interfaces:**
- Consumes: the Task 2 DOM contracts: `data-lab-range="vision-fps"`, `data-lab-range="loss"`, `data-output="vision-fps"`, `data-output="loss"`, `data-lab-pilot`, `data-stat="score"`, `data-stat="reading-age"` (all inside `#fishing-lab`, which has `phx-update="ignore"`).
- Produces: nothing consumed later.

- [ ] **Step 1: Extend the render test (failing)**

In `test/pokex_web/live/fishing_lab_live_test.exs`, replace the test body with:

```elixir
  test "renders the local fishing lab", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/fishing-lab")

    assert html =~ "Laboratorio do peixe"
    assert has_element?(view, "#fishing-lab[phx-hook='FishingLab']")
    assert has_element?(view, "#fishing-game-canvas")
    assert has_element?(view, ~s(button[data-lab-action="toggle-auto"]))
    assert has_element?(view, ~s(input[data-lab-range="latency"]))

    # low-fps vision simulation + pilot comparison controls
    assert html =~ "FPS da visao"
    assert html =~ "Leituras perdidas"
    assert has_element?(view, ~s(input[data-lab-range="vision-fps"][value="7"]))
    assert has_element?(view, ~s(input[data-lab-range="loss"][value="0"]))
    assert has_element?(view, ~s(button[data-lab-pilot="reactive"]))
    assert has_element?(view, ~s(button[data-lab-pilot="predictive"].btn-active))
    assert has_element?(view, ~s([data-stat="score"]))
    assert has_element?(view, ~s([data-stat="reading-age"]))
  end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
mix test test/pokex_web/live/fishing_lab_live_test.exs
```

Expected: FAIL on `html =~ "FPS da visao"`.

- [ ] **Step 3: Add the markup**

All edits in `lib/pokex_web/live/fishing_lab_live.ex` (ASCII-only copy, matching the file):

3a. Header badge — replace `<span class="badge badge-ghost">60 FPS no navegador</span>` with:

```heex
<span class="badge badge-ghost">jogo a 60 FPS · visao configuravel</span>
```

3b. Pilot selector — inside the `grid grid-cols-2 gap-2` buttons block, after the
"Nova cor" button, add a full-width segmented pair:

```heex
<div class="join col-span-2 w-full">
  <button
    type="button"
    data-lab-pilot="reactive"
    class="btn btn-outline btn-sm join-item flex-1"
  >
    Reativo
  </button>
  <button
    type="button"
    data-lab-pilot="predictive"
    class="btn btn-outline btn-sm join-item flex-1 btn-active"
  >
    Preditivo
  </button>
</div>
```

3c. New stats — in the "Estado do piloto" `grid grid-cols-2 gap-2 text-xs` block, after
the "Rodada" cell, add:

```heex
<div>
  <div class="opacity-50">Ultima leitura</div>
  <div data-stat="reading-age" class="text-lg font-semibold tabular-nums">—</div>
</div>
<div>
  <div class="opacity-50">Placar</div>
  <div data-stat="score" class="text-lg font-semibold tabular-nums">0V · 0D</div>
</div>
```

3d. New sliders — in the sliders panel, after the "Zona morta" `</label>` and before the
"Deteccao por pixels" toggle, add:

```heex
<label for="fishing-lab-vision-fps" class="block">
  <div class="mb-1 flex items-center justify-between gap-3 text-sm">
    <span>FPS da visao</span>
    <span data-output="vision-fps" class="font-mono text-xs opacity-60">7 fps · ~143ms</span>
  </div>
  <input
    id="fishing-lab-vision-fps"
    type="range"
    min="2"
    max="60"
    value="7"
    data-lab-range="vision-fps"
    class="range range-secondary range-sm"
  />
</label>

<label for="fishing-lab-loss" class="block">
  <div class="mb-1 flex items-center justify-between gap-3 text-sm">
    <span>Leituras perdidas</span>
    <span data-output="loss" class="font-mono text-xs opacity-60">0%</span>
  </div>
  <input
    id="fishing-lab-loss"
    type="range"
    min="0"
    max="40"
    value="0"
    step="5"
    data-lab-range="loss"
    class="range range-error range-sm"
  />
</label>
```

- [ ] **Step 4: Format and run the test**

```bash
mix format lib/pokex_web/live/fishing_lab_live.ex test/pokex_web/live/fishing_lab_live_test.exs
mix test test/pokex_web/live/fishing_lab_live_test.exs
```

Expected: PASS (1 test).

- [ ] **Step 5: Full suite**

```bash
mix test
```

Expected: all green (348 tests + this one's additions; no other file touched Elixir).

- [ ] **Step 6: Commit**

```bash
git add lib/pokex_web/live/fishing_lab_live.ex test/pokex_web/live/fishing_lab_live_test.exs
git commit -m "lab: vision-rate + loss sliders, pilot selector, scoreboard markup"
```

---

## Final verification (controller, after Task 3)

- `git push`.
- Lucas validates in the lab (dev server watcher picks the JS up automatically): default
  load shows Preditivo active, `7 fps · ~143ms`, yellow target line lagging/leading the
  fish, "Ultima leitura" oscillating ~0–143ms + latency, scoreboard counting rounds;
  switching pilots/params zeroes the scoreboard; 60fps slider position reproduces the old
  behavior; "Leituras perdidas" at 30–40% shows the stale fail-safe releasing the bar.
