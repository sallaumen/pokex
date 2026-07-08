# Loot.Worker extraction — design

**Goal:** Move loot/capture/walk out of `Combat.Logic` into a separate, event-driven `Loot.Worker`, so combat keeps attacking the next enemy while a second process walks to the corpse, loots, captures, and returns to the fishing spot.

**Why:** Today the loot chain (`walking_to_loot → looting → capturing → walking_back`) lives inside `Combat.Logic`, so after a kill the bot stops attacking to go loot, then resumes. It also sometimes fails to return to the original position. Loot and walking don't affect attacking (attacking depends only on the fixed side battle panel), so they should run in parallel.

## Architecture

A new OTP worker `Pokex.Bots.Loot.Worker` (driver) around a pure `Pokex.Bots.Loot.Logic` (state machine), added under `BotSupervisor` alongside `Fishing.Worker` and `Combat.Worker`, all sharing the one `Body`.

Coordination is one-way via PubSub, mirroring the existing `"fishing:caught"` pattern:

- **Combat** on a kill broadcasts `{:kill, corpse_point}` on topic `"combat:kill"`, then immediately re-scans for the next enemy (never blocks on loot).
- **Loot.Worker** subscribes to `"combat:kill"`. When IDLE it accepts the event and runs the walk→loot→capture→walk-back cycle; while BUSY it DROPS further kill events (decided: skip corpses killed mid-walk — keeps the recorded corpse position valid, since the character is at the fishing spot whenever loot is idle).

Both attacking (battle-panel clicks + skill keys) and walking/looting/capture are character-position-independent vs. each other: the battle panel is fixed UI, and the corpse capture is player-relative (player is screen-centered). So they interleave safely on the shared `Body`.

**Body priority:** combat and loot both submit at `:high` (foreground); fishing stays `:normal`. Combat's skills are sparse (~one per `skill_cast_ms`) and loot's arrow presses are spaced by `walk_step_ms` (between ticks, not within a perform), so the Body is mostly idle and neither starves the other. Loot at `:high` keeps a walk from being interleaved by a fishing cast.

**Fishing during loot:** unchanged for now (decided). Fishing is `:normal`, below combat+loot; an occasional mis-cast while the character is away is cheap. Revisit later if needed.

## Components

### `Pokex.Bots.Loot.Logic` (pure)
Moved verbatim from `Combat.Logic`: the `walking_to_loot`, `looting`, `capturing`, `walking_back` `do_step` clauses and the helpers `plan_walk/1`, `corpse_point/1`, `opposite/1`, `clamp_unit/1`.

- Struct: `state` (`:idle | :walking_to_loot | :looting | :capturing | :walking_back`), `config`, `entered_at`, `waiting_until`, `walk_plan`, `walk_taken`, `loot_offset`, `loot_presses_left`, `last_corpse`, `counters: %{loots, captures}`.
- `new(config)` → `%Logic{state: :idle}`.
- `start(logic, corpse_point, now)` → plans the walk from `corpse_point` (or loots in place when the point is `nil`/beyond `max_walk_tiles`), → `:walking_to_loot`, returns `{logic, actions}`.
- `busy?(logic)` → `state != :idle`.
- `step(logic, obs, now)` → advances the chain; walking_back with an empty plan → `:idle`.
- `needs/2`, `tick_interval/1`, `waiting?/2`, `stop/1` — same contracts as `Combat.Logic`. `needs` is `[]`: loot walks by dead-reckoning and never senses the battle (no screencapture per tick). The Guardian owns the panic corner — its `on_panic` (`stop_all`, now including loot) halts a walk in progress — so loot needs no cursor read of its own.
- **Walk-back correctness:** each executed outbound step is prepended to `walk_taken`; on capture the return plan is `Enum.map(walk_taken, &opposite/1)` (exact reverse). A test asserts out-and-back nets zero displacement so the character returns to the fishing spot. Extracting loot into its own worker also removes the real cause of "doesn't return": combat re-scan/rescan can no longer interrupt the walk-back — only a panic/halt stops loot mid-walk.

### `Pokex.Bots.Loot.Worker` (driver)
- `init`: subscribe to `"combat:kill"`; state `%{logic: nil, calib: nil, body: body, timer: nil}`.
- `run/1`: `Preflight.run` + `Calibration.load` + `Config.build` → `Loot.Logic.new` (idle). Ready to receive kills.
- `handle_info({:kill, corpse}, ...)`: if `logic` is nil (not running) → ignore; if `Loot.Logic.busy?` → ignore (drop); else `Loot.Logic.start(logic, corpse, now)` → submit actions at `:high` → schedule tick.
- `handle_info(:tick, ...)`: honor `Loot.Logic.waiting?` (skip sensing during a pause); else sense `needs` (cursor for the kill corner), `step`, submit at `:high`; when the logic returns to `:idle`, cancel the timer (wait for the next kill); else reschedule `tick_interval`.
- `halt/1`: `Loot.Logic.stop` (→ idle) + cancel timer. Used by panic + stop_all.
- Broadcasts snapshots/activity on a `"loot"` topic for the panel (mirrors combat/fishing).

### `Combat.Logic` / `Combat.Worker` changes
- Remove the four loot states and their helpers from `Combat.Logic`. States become `:idle | :scanning | :confirming | :fighting | :error`.
- On a kill (fighting, ring gone past `target_lost_streak`): `counters.fights + 1` + `reselect → :scanning` (keep `last_hostile` so the worker can read it). No loot chain.
- `Combat.Worker`: after stepping, if `logic.counters.fights > previous.counters.fights`, broadcast `{:kill, logic.last_hostile}` on `"combat:kill"` (same shape as the fishing `{:fish_caught}` broadcast).
- Combat no longer needs `loot_presses`, `wait_loot_ms`, `wait_after_capture_ms`, `tile_px`, `walk_step_ms`, `max_walk_tiles`, `player_point` for its own logic — but `Config.build` keeps producing them (Loot.Logic consumes them). No settings change.

### `BotSupervisor`
- Add `Loot.Worker` as a 5th child (`loot` name, default `Pokex.Bots.Loot.Worker`).
- `start_all` runs loot after combat; `stop_all` / `on_panic` halt it too; `status` includes `loot`.
- `start_link` accepts a `:loot` name for isolated test instances.

## Data flow

```
Combat kill → counters.fights+1 → Combat.Worker broadcasts {:kill, corpse} on "combat:kill"
                                 → Combat re-scans (attacks next enemy)

Loot.Worker (idle) receives {:kill, corpse}
   → Loot.Logic.start: plan walk from corpse
   → walking_to_loot (arrow presses, spaced) → looting (space × loot_presses)
   → capturing (capture_sequence at player+offset) → walking_back (reverse steps)
   → idle (back at the fishing spot; waits for the next kill)
Loot.Worker (busy) receives {:kill, _} → dropped
```

## Error handling
- `Loot.Worker` mirrors `Combat.Worker`: a Body `{:error, _}` drives `Loot.Logic.io_failed` (recover into idle, bump a failures counter; stop into error past `max_consecutive_failures`). A capture/walk failure never crashes the worker.
- Panic corner: the Guardian's `on_panic` (already `stop_all`) now also halts loot mid-walk.
- Unknown/too-far corpse: loots in place, captures one tile below the player (existing behavior, moved).

## Testing
- `Loot.Logic` test: the full chain (start → walk → loot → capture → walk-back → idle) with concrete points; the **out-and-back nets zero displacement** assertion; unknown corpse (loot in place); corpse beyond `max_walk_tiles`; `busy?` true mid-cycle and false when idle.
- `Loot.Worker` test (fake Rig + fake sensor): a `{:kill, corpse}` runs the full cycle and submits to the Body at `:high`; a second `{:kill, _}` while busy is dropped; `halt` stops mid-walk.
- `Combat.Logic` test: a kill increments `counters.fights` and returns to `:scanning` (no loot state); `last_hostile` is preserved for the worker to broadcast.
- `Combat.Worker` test: a kill broadcasts `{:kill, last_hostile}` on `"combat:kill"`; combat keeps scanning.
- `BotSupervisor` test: loot is started/halted with the others.

## Out of scope (v1)
- Queuing corpses killed mid-walk (dropped instead).
- Pausing fishing while looting.
- A third Body priority level (loot and combat share `:high`).
