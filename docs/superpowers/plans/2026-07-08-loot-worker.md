# Loot.Worker Extraction — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract loot/capture/walk out of `Combat.Logic` into a separate event-driven `Loot.Worker`, so combat keeps attacking while loot runs in parallel and reliably returns to the fishing spot.

**Architecture:** New pure `Pokex.Bots.Loot.Logic` (the four loot states moved verbatim from `Combat.Logic`) driven by a new `Pokex.Bots.Loot.Worker` under `BotSupervisor`. Combat broadcasts `{:kill, corpse_point}` on `"combat:kill"` and re-scans immediately; the loot worker consumes those events (dropping any that arrive while it's busy) and walks→loots→captures→walks back.

**Tech Stack:** Elixir/OTP, Phoenix.PubSub, ExUnit. Existing `Body` (`:high`/`:normal`), `Sensors`, `Config`, `Calibration`.

## Global Constraints
- Combat and loot both submit to `Body` at `:high`; fishing stays `:normal`.
- Loot processes ONE corpse at a time; kill events arriving while busy are DROPPED.
- Fishing behavior is unchanged.
- `mix compile --warnings-as-errors` and `mix format --check-formatted` must stay clean; full suite green after each task.
- No `Settings`/`Config` key changes — `Config.build` already produces every key loot consumes (`player_point`, `tile_px`, `walk_step_ms`, `loot_presses`, `max_walk_tiles`, `wait_loot_ms`, `wait_after_capture_ms`, `auto_capture`, `fight_timeout_ms`, `max_consecutive_failures`).

---

### Task 1: `Loot.Logic` (pure state machine)

**Files:**
- Create: `lib/pokex/bots/loot/logic.ex`
- Test: `test/pokex/bots/loot/logic_test.exs`

**Interfaces:**
- Produces: `Loot.Logic.new(config)` → `%Logic{state: :idle}`; `start(logic, corpse_point | nil, now)` → `{logic, actions}` (plans the walk, → `:walking_to_loot`); `busy?(logic)` → boolean (`state != :idle`); `step(logic, obs, now)` → `{logic, actions}`; `stop(logic)` → `{logic, []}`; `io_failed(logic, reason, now)`; `needs(logic, now)` → `[]`; `tick_interval(logic)`; `waiting?(logic, now)`.
- Struct: `state, config, entered_at, waiting_until, walk_plan, walk_taken, loot_offset, loot_presses_left, failures, error, counters: %{loots: 0, captures: 0, failures: 0}`.

**What moves from `Combat.Logic` verbatim:** the `do_step` clauses for `:walking_to_loot` (both), `:looting` (both), `:capturing`, `:walking_back` (both); helpers `plan_walk/1`, `corpse_point/1` (renamed to take the corpse point directly), `opposite/1`, `clamp_unit/1`, `advance/4`, `timed_out?/3`, `fail/3`. `start/3` runs `plan_walk` on the passed corpse point (not on `last_hostile`).

- [ ] **Step 1 — failing test** `test/pokex/bots/loot/logic_test.exs`: the full cycle + out-and-back nets zero.

```elixir
defmodule Pokex.Bots.Loot.LogicTest do
  use ExUnit.Case, async: true
  alias Pokex.Bots.Loot.Logic

  def config do
    %{player_point: {600, 300}, tile_px: 50, walk_step_ms: 5, loot_presses: 2,
      max_walk_tiles: 7, wait_loot_ms: 400, wait_after_capture_ms: 2000, auto_capture: true,
      fight_timeout_ms: 90_000, max_consecutive_failures: 3}
  end

  def obs, do: %{cursor: {500, 500}}

  test "known corpse: walk adjacent, space-loot, capture, walk back to origin, idle" do
    # corpse {700,400} (hostile+tile below is done by caller; here pass the corpse point),
    # player {600,300}, tile 50 → dx=2 dy=2 → stop adjacent = ["right","down"], offset {1,1}
    {l, []} = Logic.start(Logic.new(config()), {700, 400}, 0)
    assert l.state == :walking_to_loot
    assert l.walk_plan == ["right", "down"]
    assert l.loot_offset == {1, 1}
    assert Logic.busy?(l)

    {l, [{:press, "right"}]} = Logic.step(l, obs(), 100)
    {l, [{:press, "down"}]} = Logic.step(l, obs(), 200)
    assert l.walk_taken == ["down", "right"]
    {l, []} = Logic.step(l, obs(), 300)
    assert l.state == :looting
    {l, [{:press, "space"}]} = Logic.step(l, obs(), 400)
    {l, [{:press, "space"}]} = Logic.step(l, obs(), 900)
    {l, []} = Logic.step(l, obs(), 1400)
    assert l.state == :capturing
    assert l.counters.loots == 1
    {l, [{:capture_sequence, {650, 350}}]} = Logic.step(l, obs(), 1900)
    assert l.state == :walking_back
    assert l.walk_plan == ["up", "left"]           # exact reverse → nets to origin
    assert l.counters.captures == 1
    {l, [{:press, "up"}]} = Logic.step(l, obs(), 4000)
    {l, [{:press, "left"}]} = Logic.step(l, obs(), 4100)
    {l, []} = Logic.step(l, obs(), 4200)
    assert l.state == :idle
    refute Logic.busy?(l)
  end

  test "unknown corpse (nil): loot in place, capture one tile below, no walking" do
    {l, []} = Logic.start(Logic.new(config()), nil, 0)
    assert l.state == :looting          # empty walk plan skips straight to looting
    assert l.walk_plan == []
    {l, [{:press, "space"}]} = Logic.step(l, obs(), 100)
    {l, [{:press, "space"}]} = Logic.step(l, obs(), 600)
    {l, []} = Logic.step(l, obs(), 1100)
    {l, [{:capture_sequence, {600, 350}}]} = Logic.step(l, obs(), 1600)
    assert l.state == :walking_back
    assert l.walk_plan == []
    {l, []} = Logic.step(l, obs(), 3700)
    assert l.state == :idle
  end

  test "corpse farther than max_walk_tiles is treated as unknown (loot in place)" do
    {l, []} = Logic.start(Logic.new(config()), {1200, 300}, 0)  # dx=12 > 7
    assert l.state == :looting
    assert l.walk_plan == []
    assert l.loot_offset == nil
  end

  test "auto_capture disabled throws no pokeball" do
    cfg = Map.put(config(), :auto_capture, false)
    logic = %Logic{state: :capturing, config: cfg, loot_offset: {0, 1}}
    {l, [{:log, _}]} = Logic.step(logic, obs(), 100)
    assert l.state == :walking_back
    refute Enum.any?([{:log, ""}], &match?({:capture_sequence, _}, &1))
    assert l.counters.captures == 0
  end

  test "start on a busy logic is ignored (idempotent guard belongs to the worker)" do
    {l, _} = Logic.start(Logic.new(config()), {700, 400}, 0)
    assert Logic.busy?(l)
  end
end
```

- [ ] **Step 2 — run, expect FAIL** (`Loot.Logic` undefined): `mix test test/pokex/bots/loot/logic_test.exs`
- [ ] **Step 3 — implement** `Loot.Logic` by moving the loot clauses + helpers out of `Combat.Logic`. `new/1` → idle. `start(logic, corpse, now)` computes `{plan, offset} = plan_walk(corpse, config)` and advances to `:walking_to_loot` with `loot_presses_left: 0` (set on entering `:looting`) — reproduce the current field flow. `plan_walk(nil, _)` → `{[], nil}`; `plan_walk({cx,cy}, cfg)` uses the current dx/dy math against `player_point` (NOTE: the corpse point passed in is already the body position; combat passed `last_hostile + tile below` — so the caller/worker passes the corpse body point, and `plan_walk` no longer adds a tile. Keep the `+tile below` inside `Combat`'s event emission OR inside `start`; put it in `start` so the event carries raw `last_hostile` and loot owns the geometry). `:walking_back` empty plan → `:idle` (not `continue_combat`).
- [ ] **Step 4 — run, expect PASS**
- [ ] **Step 5 — `mix format`, `mix compile --warnings-as-errors`, commit** `feat(loot): pure Loot.Logic (walk → loot → capture → walk-back → idle)`

---

### Task 2: `Loot.Worker` (driver)

**Files:**
- Create: `lib/pokex/bots/loot/worker.ex`
- Test: `test/pokex/bots/loot/worker_test.exs`

**Interfaces:**
- Produces: `Loot.Worker.start_link(opts)` (`:name`, `:body`); `run/1`, `halt/1`, `status/1`; `kill_topic/0` → `"combat:kill"`; subscribes to it in `init`.
- Consumes: `Loot.Logic`, `Body.perform(actions, :high, body)`, `Config.build`, `Calibration.load`, `Preflight.run`.

Model on `Combat.Worker`: `run` loads calib + builds config + `Loot.Logic.new`; `handle_info({:kill, corpse}, ...)` starts the cycle only when `logic != nil` and `not Loot.Logic.busy?(logic)` (else drop, log-drop optional); `handle_info(:tick, ...)` senses `Loot.Logic.needs` (`[]`), steps, submits at `:high`, and cancels the timer when the logic returns to `:idle`; `halt` stops + cancels the timer. Broadcast snapshots on `"loot"` topic.

- [ ] **Step 1 — failing test** `test/pokex/bots/loot/worker_test.exs` (fake Rig; setup mirrors `combat/worker_test.exs`): (a) a `{:kill, {410,320}}` runs a full cycle and the recorded `Rig.Fake.calls()` include a `{:press, "space"}` and a `{:capture_sequence, _}` and the worker returns to idle; (b) a second `{:kill, _}` broadcast WHILE busy leaves the cycle running once (assert only one capture) — drop verified; (c) `halt` mid-walk stops.
- [ ] **Step 2 — run, expect FAIL**
- [ ] **Step 3 — implement** `Loot.Worker`.
- [ ] **Step 4 — run, expect PASS**
- [ ] **Step 5 — format, warnings-as-errors, commit** `feat(loot): event-driven Loot.Worker (drops kills while busy)`

---

### Task 3: Wire `Loot.Worker` into `BotSupervisor`

**Files:**
- Modify: `lib/pokex/bots/bot_supervisor.ex`
- Test: `test/pokex/bots/bot_supervisor_test.exs`

**Interfaces:**
- `start_link` accepts `:loot` (default `Pokex.Bots.Loot.Worker`); adds it as a child; `on_panic = fn -> stop_all(fishing, combat, loot) end`; `start_all/stop_all/status` fan out to loot too (`start_all` runs loot after combat; if loot's `run` fails, stop all).

- [ ] **Step 1 — failing test:** in `bot_supervisor_test.exs`, extend `start_isolated_supervisor` to pass a `loot:` name and assert `status` includes a `loot` key and that `stop_all` halts it. (Loot needs no sensor script — it idles with no kill events.)
- [ ] **Step 2 — run, expect FAIL**
- [ ] **Step 3 — implement** the supervisor wiring.
- [ ] **Step 4 — run, expect PASS**
- [ ] **Step 5 — format, warnings-as-errors, commit** `feat(loot): supervise Loot.Worker alongside fishing/combat`

---

### Task 4: Combat emits `{:kill}` and drops its inline loot chain (the switchover)

**Files:**
- Modify: `lib/pokex/bots/combat/logic.ex`, `lib/pokex/bots/combat/worker.ex`
- Test: `test/pokex/bots/combat/logic_test.exs`, `test/pokex/bots/combat/worker_test.exs`

**Interfaces:**
- `Combat.Logic` states drop to `:idle | :scanning | :confirming | :fighting | :error`. Kill (fighting, ring gone past `target_lost_streak`): `counters.fights + 1` + `reselect → :scanning`, preserving `last_hostile`. Remove the four loot `do_step` clauses + `plan_walk`/`corpse_point`/`opposite`/`clamp_unit`/`continue_combat` and their config usage. Remove loot fields from the struct (`walk_plan, walk_taken, loot_offset, loot_presses_left`) and from `start`/`reselect`.
- `Combat.Worker`: after `run_tick` steps, if `logic.counters.fights > previous.counters.fights`, `Phoenix.PubSub.broadcast(Pokex.PubSub, Pokex.Bots.Loot.Worker.kill_topic(), {:kill, logic.last_hostile})`. Remove loot `state_desc`/`describe_action` clauses that no longer occur.

- [ ] **Step 1 — update combat logic test:** replace the whole `loot / capture / walk-back` describe block with: "a kill returns to :scanning and increments counters.fights, preserving last_hostile" (from `advance_to_attacking`, set `last_hostile`, ring gone → assert `l.state == :scanning`, `l.counters.fights == 1`, `l.last_hostile` preserved). Keep the scanning/confirming/fighting describes.
- [ ] **Step 2 — run, expect FAIL** (combat still has loot states).
- [ ] **Step 3 — implement** the combat changes.
- [ ] **Step 4 — update combat worker test:** the full-cycle test becomes "on a kill, broadcasts `{:kill, {410,320}}` on the kill topic and keeps scanning" (subscribe to `Loot.Worker.kill_topic()`; script `battle` candidate→ring→ring-gone; `assert_receive {:kill, {410, 320}}`; the loot `space`/`capture_sequence` assertions move to the Loot.Worker test). Run, expect PASS.
- [ ] **Step 5 — full suite, warnings-as-errors, format, commit** `refactor(combat): emit {:kill} and hand loot to Loot.Worker`

---

## Self-Review
- **Spec coverage:** Loot.Logic (Task 1), Loot.Worker + drop-while-busy (Task 2), supervisor + panic (Task 3), combat emits events + drops loot + walk-back-can't-be-interrupted (Task 4). Body `:high` for loot (Task 2). No settings change (constraint). ✓
- **Corpse geometry:** the `+ tile below` that combat's `corpse_point/1` applied to `last_hostile` moves into `Loot.Logic.start` so the event carries raw `last_hostile` and loot owns all walk geometry — called out in Task 1 Step 3 and Task 4 interface. ✓
- **Ordering:** loot exists and is supervised (1→2→3) BEFORE combat flips to emitting events and dropping its inline loot (4), so there is no window where kills fire with no consumer AND combat has stopped looting. ✓
