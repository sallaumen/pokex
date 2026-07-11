# Mini-Game Player Implementation Plan

> **For agentic workers:** executed INLINE (Lucas's standing preference, 2026-07-10) with TDD
> per task and a commit per task. Steps use checkbox syntax for tracking/recovery.

**Goal:** MiniGame.Worker plays the real mini-game (hold/release Space chasing the fish) with
the lab-validated predictive pilot when the overlay is detected.

**Architecture:** three pure additions (Rig key-hold primitives, Track column reader, Pilot
Elixir port of fishing_pilot.js) wired into the existing Worker tick when `in_game?`. No new
processes; pause/resume peers machinery untouched (blackboard Phase 2 excluded).

**Tech Stack:** Elixir/OTP, osascript System Events key down/up, ExUnit + Rig.Fake +
PngFixtures + the real-frame fixture.

**Spec:** `docs/superpowers/specs/2026-07-10-minigame-player-design.md` — constants and
predicates there are binding (deadband_pct 0.011, lead 0.11s/±0.062, decay 0.25, stale 1500ms,
vy overrides +0.219/-0.246 track/s, blue predicate `b>=200 and b>=g+60 and r<=80`, space
key code 49, min-toggle 50ms, play tick 150ms).

## Global Constraints

- Player calls `Rig.impl()` directly, never Body.
- Space must never stay held: key_up on leave/halt/failure/lost-bar/terminate (trap exits).
- Normalized units everywhere in Pilot/Track (0..1 of track height; velocities per second).
- Seeds added: `mini_game_play_tick_ms: 150`, `mini_game_min_toggle_ms: 50`,
  `mini_game_deadband_pct: 0.011`. Nothing else becomes a setting.
- Full suite green + `git push` after each task (shared tree: commit only files this plan owns).

---

### Task 1: Rig key_down/key_up

**Files:** Modify `lib/pokex/rig.ex` (behaviour), `lib/pokex/rig/mac.ex`,
`lib/pokex/rig/mac/commands.ex`, `test/support/` Rig.Fake, test `test/pokex/rig/mac_commands_test.exs`
(or wherever build_key_script is pinned today — follow the existing press tests).

**Interfaces produced:** `Rig.impl().key_down("space") :: :ok | {:error, term}`, same for
`key_up/1`. Fake records `{:key_down, "space"}` / `{:key_up, "space"}` in its event log.

- [ ] Failing tests: commands build `key down (key code 49)` / `key up (key code 49)` scripts
      with the focus guard (mirror the existing press-script tests); Fake records events.
- [ ] Implement: `build_hold_script(key, :down | :up)` in commands (reuse @named_keycodes),
      Mac wrappers with the fail-open catch, behaviour callbacks, Fake support.
- [ ] Full suite, commit `rig: key_down/key_up hold primitives (space = key code 49)`.

### Task 2: Pilot port

**Files:** Create `lib/pokex/bots/mini_game/pilot.ex`, test
`test/pokex/bots/mini_game/pilot_test.exs`.

**Interfaces produced:** `Pilot.decide(config, observations, bar, now_ms)` →
`%{desired: boolean, target_y: float | nil, age_ms: non_neg_integer | nil}`;
config `%{pilot: :reactive | :predictive, deadband_pct: float}`;
observations `[%{y: float, at: integer}]` oldest→newest; bar `%{y: float, vy: float,
pressing: boolean}`. Module constants: @stale_ms 1500, @lead_s 0.11, @lead_max 0.062,
@velocity_decay 0.25, @vy_press_override 0.219, @vy_release_override -0.246,
@deadband_factor 0.7, @elapsed_floor_ms 16.

- [ ] Failing tests: the 11 lab asserts in normalized units (empty → all-nil release; stale
      1600ms → desired false with target reported; press when bar 0.18 below fresh target;
      reactive lead from a -0.365/s pair ≈ target −0.04; hysteresis hold inside deadband;
      release beyond deadband; predictive extrapolates past newest in motion direction
      (2-obs, age 150ms) and stays sane; 3-obs blend; clamp to 0..1; ghost-gap (10s-old pair +
      fresh stationary reading → target ≈ newest.y); exactly-1500ms still acts).
- [ ] Implement as spec'd (transcription of assets/js/fishing_pilot.js with the constants above).
- [ ] Full suite, commit `mini-game: predictive/reactive pilot (Elixir port of the lab module)`.

### Task 3: Track reader

**Files:** Create `lib/pokex/bots/mini_game/track.ex`, test
`test/pokex/bots/mini_game/track_test.exs`.

**Interfaces produced:** `Track.read(%Vision.Frame{}, bar_map)` →
`{:ok, %{fish_y: float, bar_y: float}} | {:error, :no_track | :no_fish}`. bar_map needs
`x`, `width` (Detector candidate). Column = `x ± (width + 2)`. Bounds = min..max y of
dark∪blue samples; fish = other-classified samples within bounds; centroids normalized;
no blue → `bar_y = fish_y`; clamp both to 0..1.

- [ ] Failing tests: synthetic frame (dark column 20..200 @x 100..112, blue capsule rows
      60..80, olive fish rows 120..140) → fish_y ≈ 0.61, bar_y ≈ 0.28; occlusion frame (no
      blue) → bar_y == fish_y; empty column → :no_track; track without fish → :no_fish;
      REAL fixture `test/fixtures/mini_game/real_open.png` with the Detector's own bar
      (detect free) → {:ok, r}, r.bar_y within 0.08 of r.fish_y (print shows them overlapping
      near the bottom), both in (0.7, 1.0).
- [ ] Implement; reuse the Detector dark predicate verbatim (duplicate the 3 comparisons —
      keep modules decoupled) + the blue predicate from the spec.
- [ ] Full suite, commit `mini-game: track reader (fish + capsule from the bar column)`.

### Task 4: Worker playing mode + seeds

**Files:** Modify `lib/pokex/bots/mini_game/worker.ex`, `lib/pokex/settings.ex`, test
`test/pokex/bots/mini_game/worker_test.exs`.

**Interfaces consumed:** Tasks 1-3. Worker state gains
`play: %{fish: [], capsule: [], holding?: false, last_toggle_at: 0}` reset on enter_game.

- [ ] Failing tests (Rig.Fake): (a) frames with overlay+fish-above-capsule → worker enters game
      and records `{:key_down, "space"}`; (b) fish below capsule → key_up follows when desired
      flips (respecting the 50ms toggle floor — use tick_ms 20 and toggle floor 0 in test
      settings); (c) overlay disappears → exit streak → final `{:key_up, "space"}` recorded
      even if already released (idempotent release on leave); (d) halt while holding →
      key_up; (e) capture failure while holding → key_up (mark_failure path).
- [ ] Implement: read_presence returns `{reading, frame}`; play step after apply_reading;
      vy estimation from last two capsule readings (normalized/s, elapsed floor 16ms);
      observations capped 4; decide with `%{pilot: :predictive, deadband_pct:
      Settings.get(:mini_game_deadband_pct)}`; actuate via Rig with min-toggle; release_space/1
      helper used by leave_game/halt/mark_failure/terminate (trap_exit in init when run);
      seeds added; play tick used when in_game?.
- [ ] Full suite, commit `mini-game: the worker plays — hold/release Space via the pilot`.

### Final: push, ledger, memory, Lucas live checklist.
