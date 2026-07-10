# Perception Blackboard + Tab Combat — Design

**Date:** 2026-07-10
**Status:** approved by Lucas (sections 1-4; section 1 amended to fold GameController's sensing in)
**Supersedes:** the per-worker sensing model (each worker capturing its own regions)

## Goal

Make the bots fast and cooperative when several automations run at once, by (a) replacing
combat's click-targeting with Tab-targeting (keyboard-only combat), and (b) centralizing ALL
screen sensing into a shared perception blackboard so each region is captured once, workers
never block on captures, and coordination happens through events instead of cross-worker
halt/run calls.

## Measured diagnosis (2026-07-10 investigation)

The numbers that drive this design:

1. **Capture funnel oversubscription.** One serialized Capture broker (correct — concurrent
   macOS `screencapture`s balloon from ~0.28s to 2-4s each). With 4 automations on, demand is
   ~28-38 captures/s across 5+ distinct region streams. On the ScreenCaptureKit backend this
   barely fits; on the `screencapture` CLI fallback (~0.28s each) the funnel is 5-8×
   oversubscribed and every worker's effective tick balloons past 1s. The battle region is
   captured by 2-3 different processes (combat `battle.png`, GameController `target.png`,
   panel reads) — the `{:frame, region}` cache can't dedupe different rects over the same area.
2. **MiniGame guard on the actuation hot path.** Every Body press/click makes 2 synchronous
   `GenServer.call`s into MiniGame.Worker, which itself blocks on its own capture every 150ms
   tick. One slow mini-game capture freezes the whole Body pipeline (all workers park on
   `perform :infinity`).
3. **Combat latency is capture-bound, not tick-bound.** Enemy-appears → attack-confirmed ≈
   0.95-1.25s; real skill cadence ≈ 0.6-0.9s (nominal tick 300ms). Bug: `battle_confirm_ms`
   (500ms) is SHORTER than the ~690ms to the first post-click ring check, so the confirm is a
   single-frame read and good candidates get abandoned spuriously.
4. **No coordination.** Fishing has zero combat/loot awareness: it casts mid-fight and — worse —
   during loot's world-scrolling walk, when its fixed `water_point`/`glow_region` are invalid.
   Combat skill keys (direct Rig path) interleave with loot's Body-routed arrow presses — the
   exact input pattern loot spaces 400ms apart to avoid. MiniGame pause/resume uses unordered
   spawns; enter→leave→enter can strand a worker halted or leave one running mid-overlay.

## Architecture

```
                       ┌─────────────────────────────────────────┐
                       │              Pokex.Perception            │
                       │  (new supervisor under Application)      │
                       │                                          │
  Capture broker ◄──── │  Feed :battle    Feed :glow              │
  (unchanged,          │  Feed :arena     Feed :pokemon_hp        │
   still serializes)   │  Feed :mini_game Feed :skill_bar         │
                       └───────┬──────────────────┬──────────────┘
                               │ writes           │ broadcasts on change
                               ▼                  ▼
                     WorldState (ETS :pokex_world)   PubSub "world"
                               ▲                  ▲
                               │ lock-free reads  │ subscriptions
        ┌──────────────┬───────┴───────┬──────────┴────┬──────────────┐
        │ Combat.Worker │ Fishing.Worker│ GameController │ MiniGame     │
        │ (Tab machine) │ (decider)     │ (decider only) │ (streaks +   │
        │               │               │                │  guard flag) │
        └──────┬────────┴──────┬────────┴──────┬─────────┴──────────────┘
               │ keyboard      │ Body :normal  │ Body :high/:critical
               │ direct (Tab,  ▼               ▼
               │ skills)      Body (unchanged: critical > high > normal)
```

Sensing (Perception) and deciding/acting (workers) are fully separated. Workers own zero
captures. The Guardian and the panic corner are untouched.

### WorldState

- ETS table `:pokex_world`, `:set`, `read_concurrency: true`, owned by a small
  `Perception.WorldState` GenServer (owner only; all reads go straight to ETS).
- Entry shape: `{key, observation, captured_at_ms}` where `captured_at_ms` is monotonic.
- Read API (pure module functions, no process hop):
  - `WorldState.get(key, max_age_ms, now)` → `{:ok, obs}` | `{:stale, obs, age_ms}` | `:missing`
  - Consumers MUST treat `:stale`/`:missing` as "unknown" and make the fail-safe choice
    (hold the cast, don't Tab, don't drink the potion, don't fire the combo on stale HP —
    but DO fire the rescue combo on a fresh low-HP read even if other keys are stale).
- This table IS "what the AI sees"; the Phase-3 `/world` page just renders it.

### Perception.Feed

One generic GenServer, started per feed spec:

```elixir
%FeedSpec{
  key: :battle,
  region: &Calibration.battle_region/1,     # calibration-derived, re-read per capture
  interval_ms_setting: :feed_battle_ms,      # cadence lives in Settings (single source)
  interpret: &Interpret.battle/2             # pure: (Frame, settings) -> observation
}
```

Behavior:
- On its interval, `Capture.frame(region)` → `interpret` → `:ets.insert` → if the observation
  differs from the previous one, `PubSub.broadcast("world", {:world, key, obs})`.
- **Demand-driven:** a feed captures ONLY while it has at least one attached consumer.
  `Perception.attach(key)` / `detach(key)` from the calling process; the feed monitors
  attachers and pauses when the set empties. A paused feed's ETS entry ages out naturally
  (staleness discipline covers it). Without this rule the blackboard would RAISE broker
  demand instead of lowering it.
- Capture/interpret failures never crash the feed: keep the last entry, count the failure,
  log at debug. The staleness gate protects consumers.
- Calibration is re-resolved on every capture (same "recalibrate applies live" property the
  GameController pioneered).

### Feed inventory and interpreters

| key | region | default cadence | observation (map) | interpreter source |
|---|---|---|---|---|
| `:battle` | `battle_region` (body+strip sliced in-memory) | `feed_battle_ms` 120 | `%{enemies: [row], red: [px/row], locked?: bool, locked_row: int\|nil}` | today's `Sensors.Real fetch(:battle)` + `red_row_counts`/`locked_row` |
| `:arena` | `arena_region` | `feed_arena_ms` 300 | `%{hostile: {x,y}\|nil}` | today's `fetch(:hostile)` |
| `:glow` | `glow_region`+margin | `feed_glow_ms` 100 | `%{signal: fishing_signal}` | today's `fetch(:glow)` |
| `:pokemon_hp` | `pokemon_hp_region` | `feed_pokemon_hp_ms` 120 | `%{hp_pct: 0..100}` | `Vision.hp_fill_pct/2` |
| `:mini_game` | `arena_region` or screen | `feed_mini_game_ms` 150 | `%{present?: bool}` | `MiniGame.Detector.detect` |
| `:skill_bar` | `skill_bar_region` | `feed_skill_bar_ms` 250 | `%{states: [:ready\|:cooldown]}` | `SkillBar` |

Cursor position is NOT a feed: it stays a direct `cliclick p` read, used only by the Guardian
(combat's per-tick cursor read is deleted — the worker moduledoc already says the Guardian
owns the panic corner).

## Combat: Tab-targeting state machine

Game facts (confirmed by Lucas): pressing Tab selects the first attackable enemy and each
further press CYCLES to the next; with no enemy, Tab does nothing; when the target dies the
lock disappears and the next target needs a fresh Tab.

States (pure `Combat.Logic`, driven by `{:world, :battle, obs}` events + a fallback timer):

- `:idle` — automation off.
- `:hunting` — attached to `:battle`; when `obs.enemies != []` → emit `{:tab}` and go
  `:tabbing`. (The `fishing:caught` PubSub accelerator stays: it just re-checks the current
  world entry immediately.)
- `:tabbing` — stamped with `tabbed_at`. On each battle observation with
  `captured_at > tabbed_at`: `locked?` → `:fighting` (and fire the first skill burst in the
  same step). Not locked and `now - tabbed_at > tab_confirm_ms` → re-Tab (cycles to the next
  candidate), up to `tab_max_attempts`; exhausted → back to `:hunting` (throttled by
  `hunt_cooldown_ms` so an unattackable-but-visible row can't cause a Tab storm).
  The confirm window counts from the first frame captured AFTER the Tab press — fixing the
  old too-short-window bug by construction.
- `:fighting` — on each battle observation: `locked?` → fire the next skill burst (blind
  rotation, unchanged) IF `skill_burst_every_ms` (default 300) has elapsed since the last
  burst — the feed observes at 120ms, so without this throttle bursts would fire ~2.5×
  faster than today's key cadence and spam the game; lock absent for `target_lost_streak`
  consecutive observations → count the kill, broadcast `{:kill, corpse}` (corpse from the
  `:arena` world entry; combat attaches `:arena` only while `:fighting`) → `:hunting`.
  `fight_timeout_ms` unchanged (drop a target that won't die).

Actuation:
- Tab and skill bursts go DIRECT to the keyboard (`Rig.press`/`press_many` in the existing
  fire-and-forget spawn path) — never through the Body. Combat no longer performs ANY mouse
  action: the select click, the slide to `neutral_point`, and the `tried`-candidate walk are
  deleted.
- The old mini-game guard calls around skill bursts become a `:persistent_term` read (see
  Coordination).

Deleted settings: `battle_confirm_ms` (replaced by `tab_confirm_ms`), select-click helpers.
New settings (seeds, single source of truth): `tab_key: "tab"`, `tab_confirm_ms: 700`,
`tab_max_attempts: 3`, `hunt_cooldown_ms: 1_500`, `skill_burst_every_ms: 300`.

Expected latency: enemy-appears → first hit ≈ one feed interval + Tab press + one confirm
frame ≈ **0.4-0.6s** (vs 0.95-1.25s measured today), with zero cursor contention.

## GameController: decider only (Lucas's section-1 amendment)

The GameController was born as the game-state hub and incorrectly grew sensing + actuation.
It splits:

- **Sensing moves to Perception:** the `:pokemon_hp` feed replaces its per-tick HP capture;
  the `:battle` feed's `locked?` replaces its private `target.png` in-combat read (the potion
  gate now costs ZERO extra captures).
- **`GameController.Worker` stays, as a pure decider:** always-on (as today), attaches to
  `:pokemon_hp` (and reads `:battle` from ETS when a potion is due), decides via the existing
  pure `Logic` (`decide/1`, `potion_wanted?/1` unchanged), actuates via Body (`:critical`
  combo / `:high` potion). Snapshot/PubSub for the panel unchanged. The rescue combo fires on
  a fresh low-HP read regardless of other feeds' staleness — survival must not wait.
- In-combat rule for the potion: `:battle` fresh AND `locked?: false` → out of combat;
  `:missing`/`:stale`/`locked?: true` → hold the sip (fail-safe, same semantics as today).
  While the combat automation is off, the GameController's potion check attaches `:battle`
  on demand (attach when a potion becomes due, detach after) so the feed doesn't run
  permanently for a rare check.

## Coordination: events + self-holds

The "workers halt/run each other" model is deleted. Every worker governs itself from events:

- **Loot broadcasts** `{:loot, :walking}` / `{:loot, :done}` on topic `"loot"` around its
  walk-loot-walk-back excursion. Fishing holds its cast while walking (world is scrolling —
  its fixed points are invalid); Combat holds Tab/skill presses (no key interleave with the
  arrow walk — the movement-bug pattern). Both resume on `:done` (or on a `loot_walk_max_ms`
  safety timeout in the subscriber, so a crashed loot can never strand them held).
- **MiniGame.Worker** becomes a consumer of the `:mini_game` feed (its enter/exit streak
  logic stays in the worker). On enter/leave it broadcasts `{:mini_game, :entered}` /
  `{:mini_game, :left}` on topic `"mini_game"`; fishing/combat/loot hold themselves while
  entered. The pause/resume machinery (`pause_peers_async`, `resume_peers_async`,
  `pause_ref`, remembered `paused_peers`) is DELETED — the race class disappears because
  nobody halts anybody.
- **Body input guard goes lock-free:** MiniGame.Worker writes
  `:persistent_term.put({Pokex.MiniGame, :in_game?}, bool)` on transitions (rare — writes
  are cheap when transitions are rare, which they are); `Body.run_guarded` reads the flag
  inline. The 2-synchronous-calls-per-input chain (and the frozen-Body failure mode) dies.
  `:critical` still bypasses the guard.
- **Body itself is unchanged** (queues, fairness, executor, panic path).

## Phases

- **Phase 0 — measure:** surface in the panel (Avançado section): active capture backend
  (SCK vs CLI fallback), captures/s through the broker, and p50/p95 capture duration (the
  `Perf` module already times shell-outs; expose it). This is the before/after yardstick.
- **Phase 1 — Perception core + Tab combat:** `WorldState`, `Perception.Feed`, `:battle` +
  `:arena` feeds, Combat rewritten as the Tab machine consuming them. Fishing/loot/mini-game
  untouched. Deliverable: visibly faster combat, alone or with fishing on.
- **Phase 2 — full migration + coordination:** `:glow`, `:pokemon_hp`, `:mini_game`,
  `:skill_bar` feeds; Fishing/GameController/MiniGame become deciders; guard via
  `:persistent_term`; loot/mini-game event holds; pause/resume deleted; combat's per-tick
  cursor read deleted.
- **Phase 3 — `/world` live view:** a LiveView page rendering the ETS table + change events:
  each feed's latest interpreted observation, its age, cadence, and error count. Basic
  version ships now (it is Lucas's long-standing "see what the AI sees" wish and it
  validates the blackboard visually).

Each phase lands as its own PR-sized commit train on main (Lucas validates against the real
game between phases; multiple AI sessions share the tree, so keep commits self-contained).

## Testing

TDD throughout (Lucas's standing preference for refactors):

- **Interpreters:** already pure and tested (Vision, Detector, SkillBar) — they only get
  thin wrapper specs.
- **Feed:** with `Rig.Fake` scripted captures — asserts: writes ETS with fresh timestamps,
  broadcasts only on observation CHANGE, pauses when the last consumer detaches, resumes on
  attach, survives capture errors (entry kept, failure counted).
- **WorldState:** `get/3` freshness math (`:ok`/`:stale`/`:missing`).
- **Combat.Logic:** table-driven pure tests for the Tab machine — hunting→tab on enemies,
  confirm-window from post-Tab frames only, re-Tab cycling, attempts exhaustion +
  hunt-cooldown, kill detection via lost-streak, fight timeout.
- **Workers:** seeded ETS + FakeBody — NO captures in any worker test (removes the
  Rig.Fake capture-queue interleaving fragility the current worker tests carry).
- **Coordination:** subscriber-side hold tests (loot walking holds fishing cast; mini-game
  entered holds combat presses; safety timeout releases a stranded hold).
- **Guard:** Body test asserting no GenServer call to MiniGame on the input path (flag
  read only).

## Risks / notes

- **SCK vs CLI:** if Phase 0 shows Lucas's live app is on the CLI fallback, the blackboard
  still helps (fewer streams, no blocked workers) but the SCK recovery robustness backlog
  (port desync, `Port.command` on a dead port, blocking recovery) becomes the next-highest
  lever — out of scope here, tracked separately.
- **Loot stays dead-reckoning** (no captures) — unchanged in all phases.
- **`tab_key` semantics:** if the game ever changes Tab behavior (e.g., cycling order), only
  `Combat.Logic` constants/settings are affected; the perception layer is oblivious.
- **Old worker tests** that script capture sequences get rewritten to seeded-ETS style in
  the same task that migrates each worker (never left broken between tasks).
