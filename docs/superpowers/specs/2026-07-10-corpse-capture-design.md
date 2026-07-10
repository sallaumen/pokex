# Corpse Capture Rework — Design

**Date:** 2026-07-10
**Status:** approved by Lucas (all 4 sections)
**Replaces:** the walk-to-corpse Loot subsystem (`Loot.Worker`/`Loot.Logic`)
**Builds on:** the Perception blackboard (spec 2026-07-10-perception-blackboard-tab-combat-design.md)

## Goal

Reliable automatic Pokéball capture while Lucas fishes STANDING STILL: the bot learns what the
empty ground looks like, continuously sees every corpse on it (not just "the last kill's name
point"), throws one ball per corpse with hit confirmation, and never gets stuck. A second mode
declares capture manual while Lucas plays on the move.

## Game facts (confirmed by Lucas)

- The Pokéball is thrown at the CURSOR (existing `capture_sequence`: move mouse + F1) and works
  up to a range; in his fishing flow corpses ALWAYS fall within range of his standing spot —
  no walking, ever.
- A ball that reaches a corpse consumes it IMMEDIATELY (captured or not): one ball per corpse,
  no retry semantics needed on a hit. An untouched corpse lasts minutes.
- Ground items are rare and not worth automating: the space-loot walk is dropped entirely.
- His pet (e.g. Elekid) wanders/parks near him — a live sprite that must not eat balls forever.

## Section 1 — `:corpses` perception feed (stateful)

`Perception.Feed` gains OPTIONAL stateful interpreters. Spec field `interpret` may be:
- arity 3 (today, pure): `(frame, calib, settings) -> obs`
- arity 4 (new): `(frame, calib, settings, prev_state) -> {obs, next_state}`; `prev_state`
  starts as `nil`; state resets when the feed (re)starts capturing after being paused
  (detach-all → attach), so every "Iniciar bot" relearns the ground.

The corpses interpreter (`Perception.Interpret.Corpses`, its own module — it carries real
logic) over `arena_region` (already calibrated; covers ball range around the character):

1. **Warmup** (`corpse_warmup_frames`, default 20 × `feed_corpses_ms` 400 — ~8s): the FIRST
   warmup frame is the BASELINE; every subsequent warmup frame is compared against it, and any pixel
   that ever deviates beyond `corpse_noise_threshold` (animated water, sparkles, the breathing
   character sprite) is marked unreliable in the VARIANCE MASK and excluded from diffing
   forever. Publishes `%{scanning?: false, corpses: []}` while warming.
2. **Scanning**: per frame, diff vs baseline on reliable pixels only (per-channel delta >
   `corpse_diff_threshold`); connected pixels cluster into blobs; blobs smaller than
   `corpse_min_blob_px` are noise. A blob only becomes a CORPSE after holding (center within
   `corpse_stationary_tolerance_px`) for `corpse_stationary_frames` (default 2) consecutive
   frames — a walking pet never qualifies.
3. Observation: `%{scanning?: true, corpses: [{x, y}]}` — blob centers in SCREEN points
   (`Calibration.frame_to_screen`), sorted stable (top-left first). `captured_at` added by the
   Feed as usual.

Cadence: `feed_corpses_ms` (default 400 — corpses last minutes; ~2.5 fps is plenty and cheap
on SCK).

**Usage rules (documented in the panel hint):** the baseline is learned at bot start with the
ground CLEAN — a corpse already on the ground at start becomes invisible (part of the
baseline); changing spots requires stopping/starting the bot (or the panel's "Reaprender chão"
button, which detaches+reattaches the feed to force a fresh warmup).

## Section 2 — Catcher worker (replaces Loot)

`Pokex.Bots.Catcher.Worker` + pure `Catcher.Logic`, same driver pattern as combat:

- Armed by `run/halt` like the other workers (part of start_all/stop_all). The MODE gates what
  a running worker does, live: in `parado` it attaches `:corpses` (so warmup happens BEFORE
  corpses exist) and steps on `{:world, :corpses, obs}` events; switching to `movimento`
  mid-run detaches and idles it (and back re-attaches, forcing a fresh warmup). `halt` always
  detaches.
- Logic state: a queue of pending corpse points, `thrown` (point + at + balls_used), and an
  `ignored` map (point → expiry).
- Per observation:
  - New corpse points (not ≈ pending/thrown/ignored, tolerance `corpse_match_tolerance_px`)
    enter the queue.
  - If a throw is pending confirmation: the thrown point still present in `obs.corpses` →
    the ball missed/it isn't a corpse; after `corpse_max_balls` (default 2) total throws the
    point goes to `ignored` for `corpse_ignore_ttl_ms` (default 120_000) — the anti-stuck
    timeout: a parked pet eats at most 2 balls, then is invisible until it moves or expires.
    Point GONE from obs → capture confirmed: `counters.captures + 1`, panel log
    "🎯 capturado em {x},{y}".
  - Otherwise, if the queue has a corpse: emit ONE `{:capture_sequence, point}` (Body `:high`)
    and await the next observation — one ball in flight at a time, always confirmed between
    throws.
- Combat's `{:kill}` broadcast is only an ACCELERATOR: on receipt the worker re-reads the
  freshest `:corpses` entry immediately instead of waiting for the next event. Detection does
  not depend on it — corpses from missed events are seen anyway.
- Staleness discipline: observations older than `catcher_world_max_age_ms` (default 1_200) are
  ignored (no throws on stale data).

## Section 3 — Capture modes + panel

- Seed `capture_mode: "parado"` (values `"parado" | "movimento"`).
- Panel: the "Auto-captura" automation row becomes **"Captura (Pokébola)"** with a two-option
  selector:
  - **Parado** — automatic capture as above (worker runs, feed attached).
  - **Em movimento** — automatic capture OFF; the row shows the hint "você captura
    manualmente — em movimento o bot não joga Pokébola". The Catcher worker halts/detaches.
- The old `auto_capture` boolean seed is REPLACED by `capture_mode` (Settings.load drops
  unknown persisted keys, so stale overrides self-clean). The "Pegar loot" automation row is
  removed.
- A small "Reaprender chão" button near the row forces a baseline relearn (detach+attach).

## Section 4 — Deletions, integration, testing

**Deleted:**
- `Pokex.Bots.Loot.Worker` and `Loot.Logic` and their tests (walk planning, space-loot,
  walk-back, `:walking_to_loot`/`:looting` states).
- Loot-only settings: `walk_step_ms`, `loot_presses`, `wait_loot_ms`, `auto_capture` (replaced
  by `capture_mode`) and any other seed only the deleted code read (grep before removing).
- Combat's `:arena` attach + `corpse/0` (it existed only to hand loot a corpse point); the
  `{:kill, corpse}` broadcast becomes `{:kill}` (payload dropped; grep all subscribers). The
  `:arena` FEED stays registered in Perception (unused consumers cost nothing; future features
  may want it) — only its combat consumer goes.
- BotSupervisor/panel wiring for loot (start_all/stop_all/status arity updates, "Pegar loot"
  row, `loot` pill → replaced by a `catcher` pill showing parado/movimento + captures).
- `corpse_max_age_ms` seed (the Catcher confirms against live observations, not stale points).

**Body/priorities:** `capture_sequence` stays a Body `:high` action (mouse move + F1),
serialized against fishing casts as today. GameController's `:critical` still preempts.

**Testing (TDD):**
- `Interpret.Corpses` pure, PNG-fixture table: warmup marks animated pixels unreliable
  (synthetic "water" that flickers during warmup never produces blobs); a new static blob
  after warmup → corpse after N stationary frames; a blob that moves each frame → never a
  corpse; blob smaller than min px → ignored; corpse coordinates map to screen points.
- Feed stateful-interpret: arity-4 interpreter threads state across ticks; state resets on
  pause→resume (detach all → attach).
- `Catcher.Logic` pure table: queue admission with tolerance matching; one throw in flight;
  gone → capture counted; persists → retry once → ignored with TTL; TTL expiry re-admits;
  stale obs → no action.
- Worker: seeded ETS + FakeBody — corpse obs → capture_sequence performed at :high; kill
  event triggers immediate re-read; halt detaches; movimento mode never attaches.
- Panel: mode selector persists to Settings; movimento shows the manual-capture hint; the
  "Reaprender chão" button round-trips.

**Manual validation (Lucas):** fish parado; kill 2-3 in a row → balls confirm one by one and
the captures counter climbs; park the pet nearby → at most 2 balls, then ignored (report
whether balling your own live pokémon causes any in-game problem); walk to a new spot →
"Reaprender chão" → works there.
