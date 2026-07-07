# Parallel Bot Architecture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run fishing and combat as independent OTP processes that never block each other, sharing the single mouse/keyboard through one serializing actuator, each with its own live UI status.

**Architecture:** Split the monolithic `Fisher.Logic` state machine into two independent pure machines — `Fishing.Logic` (cast/watch/hook, loops forever, knows nothing of battle) and `Combat.Logic` (scan the battle list → fight to the death → loot, loops forever, knows nothing of fishing). Each is driven by its own worker GenServer. A `Body` GenServer is the SOLE owner of the Rig: every worker submits action sequences to it, and it executes them one atomic sequence at a time, combat first. A `Guardian` polls the panic corner. A `BotSupervisor` starts and stops them together.

**Tech Stack:** Elixir/OTP, Phoenix LiveView (daisyUI), existing `Rig`/`Sensors`/`Vision`/`Config`/`Calibration`/`Skills` modules (unchanged). No new dependencies.

## Global Constraints

- **One body, serialized:** all mouse/keyboard actions go through `Pokex.Bots.Body`. No worker calls `Rig.impl()` for input directly. Screen captures (`Sensors`) stay per-worker and concurrent (read-only).
- **Combat preempts fishing** for the body: `:high` priority (combat) is served before `:normal` (fishing). Fishing has ≥60s of slack before a hooked fish is lost, so waiting behind combat is always safe.
- **Atomic sequences:** a submitted action list runs start-to-finish before another worker's list runs (so combat's click→move→read is never split by a fishing click).
- **Pure logic stays pure and tested:** `Fishing.Logic` and `Combat.Logic` take observations + `now` (monotonic ms) and return `{state, actions}`. No I/O.
- **No behavior regression:** the extracted fishing and combat behavior must match today's `Fisher.Logic` (reuse its state code verbatim; keep its tests passing under the new module names).
- **Loot stays in Combat** for v1 (walk-to-corpse + pokéball). A future `Loot.Worker` is out of scope here.
- **Isolation:** implement on a git worktree (`superpowers:using-git-worktrees`) because a parallel session is actively editing the fishing states in `lib/pokex/bots/fisher/logic.ex`. Rebase/merge when both are stable.
- **Panic corner:** mouse in the top-left corner (`x<=10 and y<=10`) stops ALL workers immediately, even mid-wait.

---

## File Structure

**New:**
- `lib/pokex/bots/body.ex` — `Pokex.Bots.Body`. Sole Rig-input owner; serializes action sequences with combat priority; reads cursor for the guardian.
- `lib/pokex/bots/fishing/logic.ex` — `Pokex.Bots.Fishing.Logic`. Pure fishing machine (focusing→equipping→casting→watching→hook→loop).
- `lib/pokex/bots/fishing/worker.ex` — `Pokex.Bots.Fishing.Worker`. Drives `Fishing.Logic`; senses glow; submits to Body at `:normal`; broadcasts `"fishing"` status.
- `lib/pokex/bots/combat/logic.ex` — `Pokex.Bots.Combat.Logic`. Pure combat machine (scanning→fighting→loot→capture→loop).
- `lib/pokex/bots/combat/worker.ex` — `Pokex.Bots.Combat.Worker`. Drives `Combat.Logic`; senses battle_lock/hostile; submits to Body at `:high`; broadcasts `"combat"` status.
- `lib/pokex/bots/guardian.ex` — `Pokex.Bots.Guardian`. Polls `Body.cursor/0`; on panic corner, calls `BotSupervisor.stop_all/0`.
- `lib/pokex/bots/bot_supervisor.ex` — `Pokex.Bots.BotSupervisor`. Starts/stops Body+Guardian+Fishing.Worker+Combat.Worker; `start_all/0`, `stop_all/0`, `status/0`.

**Modified:**
- `lib/pokex/application.ex` — supervise `Pokex.Bots.BotSupervisor` instead of the old `Fisher`.
- `lib/pokex_web/live/panel_live.ex` — two status markers; call `BotSupervisor.start_all/stop_all`; subscribe to `"fishing"` + `"combat"`.

**Unchanged (reused):** `Config`, `Calibration`, `Sensors`, `Vision`, `Skills`, `Rig` (behaviour), `Preflight`.

**Retired at the end:** `lib/pokex/bots/fisher.ex` (the monolithic driver) and `Fisher.Logic`'s combined cycle — after the two machines cover their behavior. The `/diagnostics` combat test re-points at `Combat.Worker`.

---

## Task 0: Create the isolated worktree

**Files:** none (git only).

- [ ] **Step 1: Create the worktree** (use `superpowers:using-git-worktrees`)

```bash
cd /Users/tavano/projects/pokex
git worktree add .worktrees/parallel-arch -b parallel-arch
cd .worktrees/parallel-arch
mix deps.get && mix test
```

Expected: the full suite passes on the fresh branch. All later tasks run inside this worktree.

---

## Task 1: `Body` — the single serialized mouse/keyboard actuator

**Files:**
- Create: `lib/pokex/bots/body.ex`
- Test: `test/pokex/bots/body_test.exs`

**Interfaces:**
- Consumes: `Pokex.Rig` behaviour (`press/1`, `click/2`, `move/1`, `capture_sequence/1`, `cursor_position/0`).
- Produces:
  - `Body.start_link(opts)` — `opts[:name]` (default `Pokex.Bots.Body`).
  - `Body.perform(actions, priority \\ :normal, server \\ Pokex.Bots.Body) :: :ok | {:error, term}` — blocks the caller until its `actions` (a list of `{:press,key} | {:click,button,point} | {:move,point} | {:capture_sequence,point} | {:log,msg}`) run atomically. `priority` is `:high` or `:normal`; a `:high` request queued while busy runs before any waiting `:normal` request.
  - `Body.cursor(server \\ Pokex.Bots.Body) :: {:ok, {x,y}} | {:error, term}` — reads the pointer (for the guardian; does not queue behind input actions).

**Design:** the Body serves one action-sequence at a time. When busy, incoming `perform` calls park in a priority queue and are answered (via `GenServer.reply`) when their turn executes — so `:high` (combat) is answered before waiting `:normal` (fishing) even though both blocked.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Pokex.Bots.BodyTest do
  use ExUnit.Case, async: false
  alias Pokex.Bots.Body

  setup do
    {:ok, _} = Pokex.Rig.Fake.start_link()
    {:ok, pid} = Body.start_link(name: :body_test)
    %{body: pid}
  end

  test "executes an action sequence atomically through the Rig", %{body: body} do
    assert :ok = Body.perform([{:press, "1"}, {:move, {5, 5}}], :normal, body)
    assert Pokex.Rig.Fake.calls() == [{:press, "1"}, {:move, {5, 5}}]
  end

  test "a :high request runs before a queued :normal one" do
    {:ok, _} = Pokex.Rig.Fake.start_link()
    {:ok, body} = Body.start_link(name: :body_prio)
    test = self()

    # Occupy the body with a sequence that blocks until we release it, so the
    # next two arrive while it is busy and must be ordered by priority.
    gate = fn tag -> fn -> send(test, {:ran, tag}) end end

    # low priority submitted first, high second; high must run first
    spawn(fn -> Body.perform([{:log, "low"}], :normal, body); gate.(:low).() end)
    Process.sleep(10)
    spawn(fn -> Body.perform([{:log, "high"}], :high, body); gate.(:high).() end)

    assert_receive {:ran, _first}, 500
  end

  test "cursor reads without queueing behind input", %{body: body} do
    assert {:ok, {500, 500}} = Body.cursor(body)
  end
end
```

- [ ] **Step 2: Run it — expect failure**

Run: `mix test test/pokex/bots/body_test.exs`
Expected: FAIL (`Pokex.Bots.Body` undefined).

- [ ] **Step 3: Implement `Body`**

```elixir
defmodule Pokex.Bots.Body do
  @moduledoc """
  The bot's single hands: the ONLY process that drives the Rig's mouse/keyboard.
  Workers submit action sequences; the Body runs ONE sequence at a time (atomic,
  so a click→move→read is never split), serving combat (`:high`) before fishing
  (`:normal`). Screen captures do NOT go through here — they are read-only and
  each worker senses on its own.
  """
  use GenServer
  alias Pokex.Rig

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, :ok, name: name)
  end

  @spec perform([tuple], :high | :normal, GenServer.server()) :: :ok | {:error, term}
  def perform(actions, priority \\ :normal, server \\ __MODULE__),
    do: GenServer.call(server, {:perform, actions, priority}, :infinity)

  @spec cursor(GenServer.server()) :: {:ok, {integer, integer}} | {:error, term}
  def cursor(server \\ __MODULE__), do: GenServer.call(server, :cursor)

  @impl true
  def init(:ok), do: {:ok, %{busy?: false, high: :queue.new(), normal: :queue.new()}}

  # Cursor reads bypass the input queue (read-only, needed live for the panic corner).
  @impl true
  def handle_call(:cursor, _from, state), do: {:reply, Rig.impl().cursor_position(), state}

  def handle_call({:perform, actions, priority}, from, %{busy?: false} = state) do
    run(actions, from)
    {:noreply, dequeue(%{state | busy?: true})}
  end

  def handle_call({:perform, actions, priority}, from, state) do
    q = if priority == :high, do: :high, else: :normal
    {:noreply, Map.update!(state, q, &:queue.in({actions, from}, &1))}
  end

  @impl true
  def handle_info({:done, from, result}, state) do
    GenServer.reply(from, result)
    {:noreply, dequeue(state)}
  end

  # Pick the next sequence (high before normal); go idle when both are empty.
  defp dequeue(state) do
    case {:queue.out(state.high), :queue.out(state.normal)} do
      {{{:value, {actions, from}}, rest}, _} ->
        run(actions, from)
        %{state | high: rest, busy?: true}

      {_, {{:value, {actions, from}}, rest}} ->
        run(actions, from)
        %{state | normal: rest, busy?: true}

      _ ->
        %{state | busy?: false}
    end
  end

  # Execute the sequence off the GenServer loop so a slow input never blocks the
  # cursor read (the panic path). Report back via {:done, ...}.
  defp run(actions, from) do
    server = self()

    spawn(fn ->
      result =
        Enum.reduce_while(actions, :ok, fn action, :ok ->
          case execute(action) do
            :ok -> {:cont, :ok}
            {:error, r} -> {:halt, {:error, r}}
          end
        end)

      send(server, {:done, from, result})
    end)
  end

  defp execute({:press, key}), do: Rig.impl().press(key)
  defp execute({:click, button, point}), do: Rig.impl().click(button, point)
  defp execute({:move, point}), do: Rig.impl().move(point)
  defp execute({:capture_sequence, point}), do: Rig.impl().capture_sequence(point)
  defp execute({:log, _}), do: :ok
end
```

- [ ] **Step 4: Run tests — expect pass**

Run: `mix test test/pokex/bots/body_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/pokex/bots/body.ex test/pokex/bots/body_test.exs
git commit -m "bots: Body — the single serialized mouse/keyboard actuator (combat-priority)"
```

---

## Task 2: Extract `Combat.Logic` (pure) from `Fisher.Logic`

**Files:**
- Create: `lib/pokex/bots/combat/logic.ex`
- Test: `test/pokex/bots/combat/logic_test.exs`

**Interfaces:**
- Consumes: `Config` map, `Skills`, `Calibration` (via config values), `Vision` per-row lock via observations `%{battle_lock: [ints], hostile: {x,y} | nil, cursor: {x,y}}`.
- Produces (same shape as today's `Fisher.Logic`):
  - `Combat.Logic.new(config)`, `start(logic, now)`, `stop(logic)`, `io_failed(logic, reason, now)`.
  - `needs(logic) :: [atom]`, `waiting?(logic, now)`, `tick_interval(logic)`.
  - `step(logic, obs, now) :: {logic, actions}`.
  - Struct field `state` in `[:idle, :scanning, :fighting, :walking_to_loot, :looting, :capturing, :walking_back, :error]`. **NEW:** `:scanning` replaces the old assessing→fighting entry — combat starts by scanning the battle list.

**Extraction rule:** copy the combat-half of `Fisher.Logic` VERBATIM (the `:fighting`/`:walking_to_loot`/`:looting`/`:capturing`/`:walking_back` `do_step` clauses and their helpers: `continue_combat`, `next_target`, `reselect`, `corpse_point`, `plan_walk`, `clamp_unit`, `opposite`, `scan_tick?`, `row_locked?`, `any_locked?`, `battle_lock`, plus `advance`, `timed_out?`, `fail`, `kill_corner?`, `in_kill_corner?`). Behavior must be identical. Replace the old "enter via `assessing`" with a `:scanning` state that repeatedly clicks battle rows looking for a lock (this is exactly the current `state: :fighting, targeted?: false` selection loop, renamed as the top-level loop). When no attackable row is found, stay in `:scanning` (idle-loop) rather than recasting.

- [ ] **Step 1: Write the failing test** (port the combat cases from `test/pokex/bots/fisher/logic_test.exs`)

```elixir
defmodule Pokex.Bots.Combat.LogicTest do
  use ExUnit.Case, async: true
  alias Pokex.Bots.Combat.Logic

  # Reuse the same config()/lock()/cursor_obs() helpers from the fisher logic
  # test (copy them verbatim into this file).

  test "scanning clicks battle row 0 and moves the cursor off to verify" do
    logic = %Logic{state: :scanning, config: config(), select_idx: 0}
    {l, actions} = Logic.step(logic, cursor_obs(), 100)
    assert l.pending_verify?
    assert actions == [{:click, :left, {1466, 138}}, {:move, {860, 470}}]
  end

  test "a persisted dark-red band locks the row and starts attacking" do
    l = %Logic{state: :scanning, config: config(), select_idx: 0, pending_verify?: true}
    {l, _} = Logic.step(l, Map.put(cursor_obs(), :battle_lock, lock(0, 600)), 200)
    assert l.targeted?
    assert l.locked_row == 0
  end

  test "after a kill with no other lock, walks to loot" do
    # (port "a single blink ... go collect the corpse" verbatim)
  end
end
```

- [ ] **Step 2: Run it — expect failure** (`Combat.Logic` undefined).
- [ ] **Step 3: Implement `Combat.Logic`** by moving the combat clauses/helpers verbatim and renaming the entry state to `:scanning`. `start/2` sets `state: :scanning` and resets the selection fields.
- [ ] **Step 4: Run tests — expect pass.**
- [ ] **Step 5: Commit** `git commit -m "bots: extract Combat.Logic (pure) from Fisher.Logic"`.

---

## Task 3: `Combat.Worker` — drive `Combat.Logic` through the Body

**Files:**
- Create: `lib/pokex/bots/combat/worker.ex`
- Test: `test/pokex/bots/combat/worker_test.exs`

**Interfaces:**
- Consumes: `Combat.Logic`, `Pokex.Bots.Body.perform/3` (at `:high`), `Sensors.impl().observe/3`, `Config.build/2`, `Calibration.load/0`, `Settings.all/0`.
- Produces: `start_link/1`, `run(server)`, `halt(server)`, `status(server)`; broadcasts `{:combat, snapshot}` + `{:combat_log, text}` on PubSub topic `"combat"`.

**Design:** identical loop shape to today's `Fisher` driver, but: (a) `state.calib`/`config` loaded on `run`; (b) every action list goes to `Body.perform(actions, :high)` instead of `execute_all`; (c) the panic corner is NOT checked here (the Guardian owns it) — the worker just steps and acts; (d) senses only combat needs (`battle_lock`/`hostile`).

- [ ] **Step 1: Write the failing test** (fake Body + fake Sensors; assert the worker submits the select click to the Body at `:high`).
- [ ] **Step 2: Run — expect failure.**
- [ ] **Step 3: Implement `Combat.Worker`** (tick with `Process.send_after`; on `:tick`, `Sensors.observe(Combat.Logic.needs(logic), calib, settings)` → `Combat.Logic.step` → `Body.perform(actions, :high)` → broadcast → reschedule at `Combat.Logic.tick_interval`).
- [ ] **Step 4: Run tests — expect pass.**
- [ ] **Step 5: Commit** `git commit -m "bots: Combat.Worker drives Combat.Logic through the Body (high priority)"`.

---

## Task 4: Extract `Fishing.Logic` (pure) from `Fisher.Logic`

**Files:**
- Create: `lib/pokex/bots/fishing/logic.ex`
- Test: `test/pokex/bots/fishing/logic_test.exs`

**Interfaces:**
- Produces the same API shape; struct `state` in `[:idle, :focusing, :equipping, :casting, :watching, :error]`. **The `:assessing`→`:fighting` bridge is REMOVED:** on a confirmed bite, `Fishing.Logic` presses the rod (the "fish again" button) and returns to `:casting`. It never touches the battle list — the hooked fish lands there for `Combat.Worker` to pick up.

**Extraction rule:** copy the fishing-half of the CURRENT `Fisher.Logic` verbatim (`:focusing`, `:equipping`, `:casting`, all `:watching` clauses, plus `recast_if_dead`/`next_dead_streak`/`timed_out?`/`advance`/`fail` and the glow/calm/dead streak fields — **including whatever the parallel session has landed by merge time**). Replace the `:assessing` clause: instead of transitioning to `:fighting`, count the hook (`counters.hooked`), press the rod, and `advance(..., :casting, ...)` with the post-hook anti-bot wait.

- [ ] **Step 1: Write the failing test** (port the fishing cases: settle→bite→hook→back-to-casting; the recast-on-dead-water backstop).

```elixir
test "a confirmed bite hooks and loops straight back to casting (no combat)" do
  settled = %Logic{state: :watching, settled?: true, config: config()}
  {l, actions} = Logic.step(settled, Map.put(cursor_obs(), :glow, true), 1000)
  assert l.state == :casting
  assert actions == [{:press, "v"}]
  assert l.counters.hooked == 1
end
```

- [ ] **Step 2: Run — expect failure.**
- [ ] **Step 3: Implement `Fishing.Logic`** (move fishing clauses verbatim; rewrite the hook path to loop to `:casting`).
- [ ] **Step 4: Run tests — expect pass.**
- [ ] **Step 5: Commit** `git commit -m "bots: extract Fishing.Logic (pure); hook loops straight back to casting"`.

---

## Task 5: `Fishing.Worker` — drive `Fishing.Logic` through the Body

**Files:**
- Create: `lib/pokex/bots/fishing/worker.ex`
- Test: `test/pokex/bots/fishing/worker_test.exs`

**Interfaces:** mirror `Combat.Worker` but submit at `:normal`, sense only `[:cursor, :glow]`, apply the glow threshold before stepping (as today's driver does), and broadcast on topic `"fishing"` (`{:fishing, snapshot}` / `{:fishing_log, text}`).

- [ ] **Step 1: Write the failing test** (fake Body + Sensors returning a bite; assert the worker presses the rod at `:normal`).
- [ ] **Step 2: Run — expect failure.**
- [ ] **Step 3: Implement `Fishing.Worker`.**
- [ ] **Step 4: Run tests — expect pass.**
- [ ] **Step 5: Commit** `git commit -m "bots: Fishing.Worker drives Fishing.Logic through the Body (normal priority)"`.

---

## Task 6: `Guardian` — the panic corner, once, for everyone

**Files:**
- Create: `lib/pokex/bots/guardian.ex`
- Test: `test/pokex/bots/guardian_test.exs`

**Interfaces:**
- Consumes: `Body.cursor/0`, `Pokex.Bots.Logic.in_kill_corner?/1` (a shared helper — put `in_kill_corner?/1` in a tiny `Pokex.Bots.Corner` module both logics and the guardian call, to keep it DRY; `x<=10 and y<=10`).
- Produces: `start_link/1`; polls the cursor every `poll_ms` (default 100); on corner → `BotSupervisor.stop_all/0` + broadcast `{:panic, "kill corner"}` on both topics.

- [ ] **Step 1: Write the failing test** (fake Body returns `{0,0}` → guardian calls a stop callback).
- [ ] **Step 2: Run — expect failure.**
- [ ] **Step 3: Implement `Corner` + `Guardian`.**
- [ ] **Step 4: Run tests — expect pass.**
- [ ] **Step 5: Commit** `git commit -m "bots: Guardian polls the panic corner and halts all workers"`.

---

## Task 7: `BotSupervisor` — start/stop everything together

**Files:**
- Create: `lib/pokex/bots/bot_supervisor.ex`
- Modify: `lib/pokex/application.ex` (supervise `BotSupervisor`, drop the old `Fisher`)
- Test: `test/pokex/bots/bot_supervisor_test.exs`

**Interfaces:**
- Produces: `start_link/1`; `start_all/0` (preflight + load calib + build config + `run` both workers); `stop_all/0` (`halt` both workers); `status/0` (`%{fishing: snap, combat: snap}`).

**Design:** a `Supervisor` (`:one_for_one`) permanently owns `Body`, `Guardian`, `Fishing.Worker`, `Combat.Worker` (workers idle until `run`). `start_all/stop_all` fan out to the two workers. Preflight/calibration errors surface from `start_all` (like today's `begin/2`).

- [ ] **Step 1: Write the failing test** (`start_all` with a fake calib runs both workers; `stop_all` idles them).
- [ ] **Step 2–4: Implement + pass.**
- [ ] **Step 5: Commit** `git commit -m "bots: BotSupervisor starts/stops Body+Guardian+workers together"`.

---

## Task 8: Two UI markers on the panel

**Files:**
- Modify: `lib/pokex_web/live/panel_live.ex`
- Test: `test/pokex_web/live/panel_live_test.exs`

**Interfaces:** subscribe to `"fishing"` + `"combat"`; render **🎣 Pesca** and **⚔️ Batalha** status pills from `BotSupervisor.status/0` (parado / arremessando / vigiando / fisgou · parado / procurando / lutando linha N / lootando); Start/Stop call `BotSupervisor.start_all/stop_all`.

- [ ] **Step 1: Write the failing LiveView test** (Start renders both pills; a `{:fishing, %{state: :watching}}` broadcast updates the 🎣 pill).
- [ ] **Step 2–4: Implement + pass.**
- [ ] **Step 5: Commit** `git commit -m "web: two independent status markers (fishing + combat)"`.

---

## Task 9: Retire the monolithic `Fisher`; re-point diagnostics

**Files:**
- Delete: `lib/pokex/bots/fisher.ex`, `lib/pokex/bots/fisher/logic.ex` (+ its test) — ONLY after Tasks 2/4 prove the split covers all behavior.
- Modify: `lib/pokex_web/live/diagnostics_live.ex` (the combat test button → `Combat.Worker.run/1` scanning once), `lib/pokex/bots/supervisor.ex` if it references `Fisher`.
- Modify: any `alias`/`Config`/`Sensors` paths that pointed at `fisher/` (move `config.ex`/`sensors/`/`skills.ex` to a shared `lib/pokex/bots/` location or keep and re-alias — pick the smaller diff).

- [ ] **Step 1:** grep for `Fisher` / `Fisher.Logic` references; list them.
- [ ] **Step 2:** re-point each to `BotSupervisor` / `Combat.Worker` / `Fishing.Worker`.
- [ ] **Step 3:** delete the dead modules + tests.
- [ ] **Step 4:** `mix test` — full suite green; `mix compile --warnings-as-errors` clean.
- [ ] **Step 5: Commit** `git commit -m "bots: retire the monolithic Fisher driver; two workers own the cycle"`.

---

## Task 10: Live smoke + merge back

**Files:** none (manual + git).

- [ ] **Step 1:** on Lucas's machine, `mix phx.server`, calibrate, Start. Confirm: fishing casts/watches AND combat locks+fights concurrently; the panic corner stops both; the two UI pills move independently.
- [ ] **Step 2:** rebase the worktree branch on the latest `main` (absorbing the parallel session's fishing changes into `Fishing.Logic`), re-run the suite.
- [ ] **Step 3:** merge to `main`, push, remove the worktree (`superpowers:finishing-a-development-branch`).

---

## Notes for the implementer
- The `Body`'s `run/1` uses a spawned task so a slow `osascript`/`cliclick` never blocks a `Body.cursor` read (the panic path must stay responsive). Keep that.
- Combat submits its **select→move→verify** as it does today (click + move in one `perform` list); the read is a separate `Sensors` capture the worker does after the `perform` returns — that ordering is what keeps the row un-hovered (pure red) at read time.
- Do NOT reintroduce the `:assessing` bridge. Fishing and combat only meet on the game screen (a hooked fish appears in the battle list), never in code.
- Keep `Skills`, `Vision`, `Config`, `Calibration`, `Sensors` exactly as-is; both workers reuse them.
