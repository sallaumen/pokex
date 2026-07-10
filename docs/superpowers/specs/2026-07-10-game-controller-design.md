# GameController + survival combo — design

**Goal:** A higher-level `Pokex.Bots.GameController` that (1) reads interpreted game state
(v1: the main Pokémon's HP) and distributes it over PubSub, and (2) fires a **survival combo**
at a new top priority when the main Pokémon drops below 50% HP.

## Architecture

- `GameController.Logic` — **pure** decision function. Given
  `%{hp_pct, now, last_rescue_at, enabled?, cooldown_ms, threshold_pct}` returns `:rescue | :hold`.
  Zero I/O. Owns the "yellow (<threshold) AND protection-cooldown-elapsed AND enabled" rule.
- `GameController.Worker` — GenServer. Fast tick reads the HP bar via the **Capture broker**,
  steps the Logic, and on `:rescue` enqueues the combo on the Body at `:critical`, then arms the
  cooldown. Broadcasts `%{hp_pct, hue, last_rescue_at, enabled?}` on the `"game"` topic.

## New Body priority tier `:critical` (above `:high`)

- Queue precedence becomes `critical > high > normal`. `:critical` jumps the whole queue and is
  NOT subject to the high→normal fairness step.
- The Body is atomic per sequence, so a critical action waits at most for the in-flight action to
  finish (~ms, ~30ms for a cast). That is the correct "no delay" in OTP — you cannot abort a
  running atomic action, but nothing queued gets ahead of critical.
- A `:critical` sequence BYPASSES the mini-game input guard (survival beats the mini-game). It
  does NOT pause any worker.

## The combo (one atomic Body sequence, `:critical`)

`{:press, rescue_key}` (recall) → `{:move, pokemon_photo_point}` → `{:press, max_revive_key}`
(max revive) → `{:press, rescue_key}` (release) → `{:move, neutral_point}`. Small `{:wait, ms}`
between presses so the game registers each.

## Protection

Logic gates to ONE combo per `rescue_cooldown_ms` (default 60_000), with an `rescue_enabled`
toggle (default true). While in cooldown, a yellow bar does NOT re-fire.

## HP detection

Fill fraction of `pokemon_hp_region`: count columns containing a "health" pixel
(saturated green/yellow/red) ÷ bar width → `hp_pct`. `pokemon_photo_point` is the portrait
centre used for the Shift+Q. Both calibrated on the calibration screen like the other regions.

## New config

- Settings: `rescue_key "q"`, `max_revive_key "shift+q"`, `rescue_enabled true`,
  `rescue_cooldown_ms 60_000`, `pokemon_hp_rescue_pct 50`, `game_tick_ms 120`.
- Calibration: `pokemon_hp_region`, `pokemon_photo_point`.

## Tasks (TDD, dependency order)

1. Settings keys + Calibration fields (+ overlay/calibration_live plumbing).
2. Vision: `hp_fill_pct/2` (fill fraction of a bar frame). Pure, unit-tested on synthetic frames.
3. `GameController.Logic` — pure `decide/1`. Unit-tested (yellow/cooldown/enabled/threshold).
4. Body `:critical` tier + guard bypass. Extend `body_test`.
5. `GameController.Worker` — tick → read → decide → combo at `:critical` → broadcast. Faked.
6. Supervision wiring (application + bot_supervisor run/halt/status).
7. Panel: HP + rescue state + enable toggle.

## Out of scope (v1) / future

XP, own-HP, and the "browser live-view of what the AI concluded from the screen" (the matrix
with corpse/character positions) — the state hub is designed to grow into these.

## Invariants preserved

Pure Logic (no I/O), one shared Body actuator, per-process capture via the broker, combat still
preempts fishing, fail-safe protection cannot burn revives.
