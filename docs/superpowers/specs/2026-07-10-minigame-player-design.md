# Mini-Game Player — Design

**Date:** 2026-07-10
**Status:** approved by Lucas (design sections OK'd in chat)
**Context:** the lab validated the predictive pilot at real-world vision rates (Lucas: works at
3fps vision, latency 70ms, deadband 6px, predictive). This feature makes `MiniGame.Worker`
actually PLAY the real mini-game when it detects it, porting `assets/js/fishing_pilot.js` to
Elixir with the validated constants. Phase 2 of the perception blackboard (feed migration,
pause_peers removal) stays OUT of scope — the existing detect/pause/resume machinery is kept.

## Game facts (confirmed by Lucas + measured)

- Holding Space raises the blue capsule, releasing lets it fall (same physics family as the lab).
- The game starts on its own once the overlay appears — no initial Space needed.
- The fish overlaps (draws OVER) the capsule when they cross — full occlusion of the blue is
  the SUCCESS state, not an error.
- Measured on the real frame (`test/fixtures/mini_game/real_open.png`): track ~(20,23,30);
  blue capsule ~(0..12, 141..183, 254..255); fish (varies by species; the print's is olive
  (120,100,0)); "29%" label and "PRESS SPACE" text sit OUTSIDE the track column.

## 1. Rig: key hold primitives

- `Rig.impl().key_down(key)` / `key_up(key)` — new callbacks beside `press/1`.
- Mac implementation: System Events `key down " "` / `key up " "` — the CHARACTER form, inside
  the SAME osascript as the focus guard. NOT `key down (key code 49)`: a nested `key code`
  executes as a full press first (measured live 2026-07-10). Fail-open like the other paths.
- `Pokex.Rig.Fake` records `{:key_down, key}` / `{:key_up, key}` like it records presses.
- The player calls Rig DIRECTLY (not Body): while in_game the Body guard blocks third-party
  inputs (that's its job — e.g. the Catcher's loot Space), and the player must not block itself.

## 2. `Pokex.Bots.MiniGame.Track` — pure column reader

`read(frame, bar)` where `bar` is the Detector's bar map (x, width, y1, y2). Scans the bar
column (`bar.x ± bar.width`, grown 2px) full frame height, classifying each sampled pixel:

- **dark** (track): `max(r,g,b) <= 82 and b >= r - 8 and g >= r - 16` (the Detector predicate).
- **blue** (capsule): `b >= 200 and b >= g + 60 and r <= 80`.
- **fish**: anything else INSIDE the track bounds.

Track bounds = min..max y of (dark ∪ blue) — the fish interrupts the dark run (that's why the
Detector's y1..y2 understates the track), but dark-above + dark-below + blue always bracket it.
Output: `{:ok, %{fish_y: 0..1, bar_y: 0..1, bar_source: :blue | :fish}}` (centroids normalized
to the bounds) or `{:error, :no_track | :no_fish}`. Occlusion rule: no blue pixels →
`bar_y = fish_y` with `bar_source: :fish` (the worker zeroes the capsule-velocity estimate
across a source switch — the centroid jump at occlusion start/end is not real motion).
Edge rule: a fish pegged at a track END can fall outside the bounds (too little dark left to
bracket it) — a fish-SIZED other-run just past the edge, terminated by dark/blue, reads as the
fish clamped to that extreme (0.0/1.0). No fish anywhere → `{:error, :no_fish}` → release.

## 3. `Pokex.Bots.MiniGame.Pilot` — pure Elixir port of fishing_pilot.js

`decide(config, observations, bar, now_ms)` → `%{desired: bool, target_y: float | nil,
age_ms: integer | nil}` — a 1:1 transcription, in track-normalized units (lab px ÷ 548 lab
track height):

- observations `[%{y: 0..1, at: ms}]` oldest→newest, caller caps at 4.
- reactive = last-pair velocity; predictive = last-3 blend (2:1 newest), both with the 16ms
  elapsed floor. Predictive drops observations older than 1500ms relative to the newest
  (ghost-velocity rule), decays velocity `0.25^age_s`, extrapolates, then leads.
- lead `clamp(vy * 0.11, ±0.062)` (34px ÷ 548); stale fail-safe: newest older than 1500ms →
  desired false; empty observations → all-nil release.
- hysteresis: deadband from config (`deadband_pct`); bar-velocity overrides at +0.219 / -0.246
  track/s (120/135 px/s ÷ 548), factors 0.7 — verbatim.
- `bar` = `%{y: 0..1, vy: track_per_s, pressing: bool}`; vy is ESTIMATED by the worker from
  consecutive capsule readings (the lab read it from the sim).
- config: `%{pilot: :reactive | :predictive, deadband_pct: float}`. Production uses
  `:predictive` (hardcoded — the lab keeps both for comparison; the bot ships the winner).

## 4. Worker: playing mode

Same GenServer, same tick loop, same enter/exit streaks and pause/resume peers:

- Each tick already captures the arena region → after `apply_reading`, when `in_game?`:
  `Track.read(frame, reading.bar)` → push fish observation + capsule reading into play state
  (histories capped 4). Observations are stamped BEFORE the capture starts and the decision
  uses a fresh `now` — so `age_ms` covers the real 100-300ms capture latency and the
  predictive extrapolation compensates it (this is the lab's validated "latencia").
- Actuation: `desired` != current holding → `Rig.impl().key_down/up("space")`, min-toggle
  50ms (`mini_game_min_toggle_ms`), tracked in state (`holding?`, `last_toggle_at`).
- Tick cadence while in_game: `mini_game_play_tick_ms` (150 default) — same value as the
  watch tick today, but an independent knob.
- **Space is NEVER left held:** key_up fires on leave_game, halt, RE-RUN (panel Start while
  playing), any tick failure (`mark_failure`), Detector presence lost mid-read, unreadable
  track frames, and in `terminate/2` (worker traps exits) — all best-effort, fail-open. A
  failed Rig hold call is logged (holding? desync self-heals at the next exit boundary).
- Reading with no bar candidate while in_game (Detector lost the overlay but exit streak not
  yet met): skip Track/decide for that tick, release if holding.
- Play state resets on enter_game (empty histories, holding? false).
- Snapshot unchanged (`state: :playing` already exists); counters unchanged.

## 5. Settings seeds

`mini_game_play_tick_ms: 150`, `mini_game_min_toggle_ms: 50`,
`mini_game_deadband_pct: 0.011` (Lucas's validated 6px ÷ 548). Everything else is a Pilot
module constant (validated in the lab; promote to a seed only if live tuning demands it).

## 6. Testing (TDD)

- **Pilot:** ExUnit transcription of the 11 scratch Node asserts (empty, stale, press, lead,
  hysteresis both edges, predictive extrapolation 2-obs and 3-obs, clamp, ghost-gap), in
  normalized units.
- **Track:** synthetic frames (dark column + blue capsule + colored fish, occlusion case,
  no-fish case) + the REAL print fixture (asserts fish and capsule found, bar_y ≈ fish_y since
  they overlap in the print, bounds sane).
- **Worker:** Rig.Fake sequences — enters game and starts deciding; holds when fish above
  capsule (key_down recorded); releases on stale/absence; ALWAYS key_up on exit/halt; peers
  pause/resume untouched (existing tests keep passing).
