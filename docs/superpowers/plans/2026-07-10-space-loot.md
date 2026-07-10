# Space Loot + Global Player Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Kill-triggered Space looting in the Catcher (independent of Pokéball capture), with `capture_mode` renamed to a global `player_mode` and independent `loot_enabled`/`capture_enabled` toggles in the panel.

**Architecture:** No new processes. The Catcher.Worker's existing `{:kill}` handlers gain a loot step (Space presses via Body `:high`) BEFORE the advance; the ball pipeline gains a `capture_enabled` gate (including the feed attach — loot-only runs zero corpse captures). Panel gets one global mode selector + two toggles. Spec: `docs/superpowers/specs/2026-07-10-space-loot-design.md`.

**Tech Stack:** Elixir 1.19 / Phoenix LiveView / ExUnit. No new deps.

## Global Constraints

- ALL tunables in `@seed_settings` (`Settings.get/1` at call sites; never `|| literal`). Portuguese UI copy; English code/comments/commits.
- Commit AND `git push` to `main` after every task; full suite green at every commit (336 tests before this plan) + `mix compile --warnings-as-errors` clean.
- Loot fires ONLY on `{:kill}` broadcasts (never on the combat-disengage edge — a timeout-ended fight has no corpse).
- Ordering invariant (by construction, verify in tests): Space presses reach the Body BEFORE any `capture_sequence` of the same kill cycle (balls need ≥2 detector frames ≈ 800ms+).
- `player_mode` replaces `capture_mode` COMPLETELY — `grep -rn capture_mode lib/ test/` must end at zero.
- The user (Lucas) edits `lib/pokex_web/live/panel_live.ex` in parallel — read the current file and integrate; never revert his changes.

---

### Task 1: Settings rename + Catcher loot + capture gate

**Files:**
- Modify: `lib/pokex/settings.ex`
- Modify: `lib/pokex/bots/catcher/worker.ex`
- Modify: `lib/pokex/bots/bot_supervisor.ex` (busy-placeholder extra references mode — check; no change expected beyond comments)
- Test: `test/pokex/bots/catcher/worker_test.exs` (append + adjust)

**Interfaces:**
- Consumes: current Catcher.Worker (read it fully — it has the combat-engagement gate, feed monitor/reattach, `seed_combat_engaged/0`, `armed_parado?/1`, `should_be_attached?/1`, `snapshot/1`); `Body.perform(actions, :high, body)`; Logic counters map `%{captures, throws, ignored}`.
- Produces (Task 2 consumes): seeds `player_mode: "parado"`, `loot_enabled: true`, `capture_enabled: true`, `loot_presses: 2`, `loot_press_gap_ms: 250` (and `capture_mode` GONE); snapshot counters now include `:loots`; `mode_changed/1` re-syncs after ANY of the three settings flips.

- [ ] **Step 1: Seeds.** In `lib/pokex/settings.ex`, replace the `capture_mode: "parado",` line with:

```elixir
    # The GLOBAL player mode: "parado" (standing still — automations that need the fixed
    # viewport may act) or "movimento" (Lucas is walking around — loot and capture are his).
    player_mode: "parado",
    # Independent switches, both only meaningful while parado:
    # loot: Space pressed after each confirmed kill — the fished pokémon fights and dies on
    # the ADJACENT melee tile, so Space reaches its corpse from standing position. Fires
    # BEFORE any Pokéball by construction (balls wait on detector confirmation), which
    # matters: the ball consumes the corpse INCLUDING its loot.
    loot_enabled: true,
    capture_enabled: true,
    # Space presses per kill and the gap between them (rapid back-to-back inputs bug the
    # game — the old walk-loot documented the same).
    loot_presses: 2,
    loot_press_gap_ms: 250,
```

- [ ] **Step 2: Write the failing worker tests.** Append to `test/pokex/bots/catcher/worker_test.exs` (reuse its setup/helpers — `world!/2`, `corpses_obs/1`, FakeBody; ADD `:player_mode`, `:loot_enabled`, `:capture_enabled` to the settings saved/restored in setup, and note the setup currently does `Settings.put(:capture_mode, "parado")` — rename that to `:player_mode`):

```elixir
  @tag :tmp_dir
  test "a kill triggers the Space loot presses before any ball", %{worker: worker} do
    # a corpse is already detectable — the ball WOULD fire on the kill's re-read
    obs = corpses_obs([{130, 224}])
    WorldState.put(:corpses, obs, obs.captured_at)

    Phoenix.PubSub.broadcast(Pokex.PubSub, Worker.kill_topic(), {:kill})

    # FIRST perform must be the loot (2 presses with the configured gap), ball second
    assert_receive {:performed, :high, loot_actions}, 1_000
    assert loot_actions == [{:press, "space"}, {:wait, 250}, {:press, "space"}]

    assert_receive {:performed, :high, [{:capture_sequence, {130, 224}}]}, 1_000
    assert Worker.status(worker).counters.loots == 1
  end

  @tag :tmp_dir
  test "loot_enabled false: kills loot nothing (balls unaffected)", %{worker: worker} do
    Settings.put(:loot_enabled, false)

    obs = corpses_obs([{130, 224}])
    WorldState.put(:corpses, obs, obs.captured_at)
    Phoenix.PubSub.broadcast(Pokex.PubSub, Worker.kill_topic(), {:kill})

    assert_receive {:performed, :high, actions}, 1_000
    assert actions == [{:capture_sequence, {130, 224}}]
    assert Worker.status(worker).counters.loots == 0
  end

  @tag :tmp_dir
  test "capture_enabled false: loot still fires, balls never, feed never attaches",
       %{worker: worker} do
    Settings.put(:capture_enabled, false)
    :ok = Worker.mode_changed(worker)

    obs = corpses_obs([{130, 224}])
    WorldState.put(:corpses, obs, obs.captured_at)
    Phoenix.PubSub.broadcast(Pokex.PubSub, Worker.kill_topic(), {:kill})

    assert_receive {:performed, :high, [{:press, "space"} | _]}, 1_000
    refute_receive {:performed, _, [{:capture_sequence, _} | _]}, 400

    # a direct corpse event is also gated
    world!(worker, corpses_obs([{140, 230}]))
    refute_receive {:performed, _, [{:capture_sequence, _} | _]}, 300
  end

  @tag :tmp_dir
  test "movimento: kills loot nothing", %{worker: worker} do
    Settings.put(:player_mode, "movimento")
    :ok = Worker.mode_changed(worker)

    Phoenix.PubSub.broadcast(Pokex.PubSub, Worker.kill_topic(), {:kill})
    refute_receive {:performed, _p, _a}, 300
  end
```

- [ ] **Step 3: Run to verify failure** — `mix test test/pokex/bots/catcher/worker_test.exs` → failures (unknown `:player_mode`/`loots` etc.).

- [ ] **Step 4: Implement in `lib/pokex/bots/catcher/worker.ex`:**

1. RENAME every `Settings.get(:capture_mode)` → `Settings.get(:player_mode)` (in `advance/2`, `armed_parado?/1`, `snapshot/1`) and update the module doc + `mode_changed/1` doc ("capture_mode" → "player_mode / the loot & capture toggles").
2. Add `loots: 0` to the init state map, reset it in `handle_call(:run, ...)` (`%{state | logic: logic, loots: 0, combat_engaged?: ...}`).
3. Both `{:kill}` handler clauses become:

```elixir
  def handle_info({:kill}, %{logic: %Logic{state: :armed}} = state) do
    state = loot_kill(state)
    {:noreply, advance(state, current_obs())}
  end

  def handle_info({:kill, _corpse}, %{logic: %Logic{state: :armed}} = state) do
    state = loot_kill(state)
    {:noreply, advance(state, current_obs())}
  end
```

4. Add the loot step + helper:

```elixir
  # A confirmed kill just dropped a corpse on the ADJACENT melee tile — Space reaches it from
  # standing position. Runs BEFORE the advance so the presses hit the Body ahead of any ball
  # of this cycle (the ball additionally waits on detector confirmation, ≥800ms later — and
  # the ball consumes the corpse WITH its loot, so the order is load-bearing).
  defp loot_kill(state) do
    if Settings.get(:player_mode) == "parado" and Settings.get(:loot_enabled) do
      presses = max(Settings.get(:loot_presses), 1)
      gap = Settings.get(:loot_press_gap_ms)

      actions =
        [{:press, "space"}]
        |> List.duplicate(presses)
        |> Enum.intersperse([{:wait, gap}])
        |> List.flatten()

      Body.perform(actions, :high, state.body)

      Phoenix.PubSub.broadcast(
        Pokex.PubSub,
        @topic,
        {:catcher_log, :macro, "captura: 🧰 saqueando (espaço ×#{presses})"}
      )

      state = %{state | loots: state.loots + 1}
      broadcast(state)
      state
    else
      state
    end
  end
```

5. `capture_enabled` gates — restructure `do_advance/2` (the engaged clause stays first; the
   ball pipeline becomes `run_step/2`, gated):

```elixir
  defp do_advance(%{combat_engaged?: true} = state, _obs), do: state

  # Capture disabled (loot-only operation): the ball pipeline never steps — no admissions,
  # no throws, no confirms. The feed is also detached (see should_be_attached?/1); this
  # gate only catches stragglers (a late event right after the toggle flip).
  defp do_advance(state, obs) do
    if Settings.get(:capture_enabled), do: run_step(state, obs), else: state
  end

  defp run_step(state, obs) do
    {logic, actions} = Logic.step(state.logic, obs, now())
    # (the ENTIRE existing body of the old do_advance follows here, unchanged: performs,
    # catcher_log broadcasts, conditional broadcast, schedule_wake)
  end
```

and `should_be_attached?/1` becomes:

```elixir
  defp should_be_attached?(state),
    do: armed_parado?(state) and not state.combat_engaged? and Settings.get(:capture_enabled)
```

(the panel pokes `mode_changed/1` after flipping ANY of the three settings, which re-runs `sync_mode` → attach/detach applies live).

6. `snapshot/1` merges the worker-level counter:

```elixir
      counters:
        ((state.logic && state.logic.counters) || %Logic{}.counters)
        |> Map.put(:loots, state.loots),
```

and reads `Settings.get(:player_mode)` for `mode`.

- [ ] **Step 5: Sweep the rename.** `grep -rn "capture_mode" lib/ test/` — fix every hit (bot_supervisor comment, worker tests setup, panel is Task 2's job — if panel hits remain, leave a note in the report; the suite may have panel failures ONLY if panel reads the deleted seed → in that case do the minimal panel rename (`Settings.get(:capture_mode)` → `:player_mode`, assign name included) in THIS task to keep the tree green, and Task 2 does the full UI rework.)

- [ ] **Step 6: Run the worker tests + full suite** — green (+ `--warnings-as-errors`).

- [ ] **Step 7: Commit**

```bash
git add -A lib test
git commit -m "catcher: kill-triggered Space loot + player_mode rename + capture gate"
git push
```

---

### Task 2: Panel — Modo global + two toggles

**Files:**
- Modify: `lib/pokex_web/live/panel_live.ex`
- Test: `test/pokex_web/live/panel_live_test.exs`

**Interfaces:**
- Consumes: Task 1's seeds (`player_mode`, `loot_enabled`, `capture_enabled`) and `Catcher.Worker.mode_changed/0` (re-syncs attach/detach after any settings flip); snapshot counters with `:loots`.
- Produces: events `set_player_mode`, `toggle_loot_enabled`, `toggle_capture_enabled`; assigns `player_mode`, `loot_enabled`, `capture_enabled`.

- [ ] **Step 1: Write the failing panel tests.** Append to `test/pokex_web/live/panel_live_test.exs` (adapt the existing capture-mode-selector test — it renders the OLD single-row selector; rework it):

```elixir
  test "the global player mode selector persists and gates the toggles' hints", %{conn: conn} do
    mode = Pokex.Settings.get(:player_mode)
    on_exit(fn -> Pokex.Settings.put(:player_mode, mode) end)

    {:ok, view, _} = live(conn, ~p"/")

    view |> element(~s(button[phx-value-mode="movimento"])) |> render_click()
    assert Pokex.Settings.get(:player_mode) == "movimento"
    assert render(view) =~ "você saqueia e captura manualmente"

    view |> element(~s(button[phx-value-mode="parado"])) |> render_click()
    assert render(view) =~ "Reaprender chão"
  end

  test "loot and capture toggles persist independently", %{conn: conn} do
    loot = Pokex.Settings.get(:loot_enabled)
    cap = Pokex.Settings.get(:capture_enabled)

    on_exit(fn ->
      Pokex.Settings.put(:loot_enabled, loot)
      Pokex.Settings.put(:capture_enabled, cap)
    end)

    {:ok, view, _} = live(conn, ~p"/")

    view |> element(~s(input[phx-click="toggle_loot_enabled"])) |> render_click()
    refute Pokex.Settings.get(:loot_enabled) == loot

    view |> element(~s(input[phx-click="toggle_capture_enabled"])) |> render_click()
    refute Pokex.Settings.get(:capture_enabled) == cap
  end
```

- [ ] **Step 2: Run to verify failure.**

- [ ] **Step 3: Implement in `lib/pokex_web/live/panel_live.ex`** (READ the current file first — Lucas co-edits it):

- Mount assigns: `capture_mode:` → `player_mode: Settings.get(:player_mode)`; add `loot_enabled: Settings.get(:loot_enabled)`, `capture_enabled: Settings.get(:capture_enabled)`.
- Events (replace `set_capture_mode`):

```elixir
  def handle_event("set_player_mode", %{"mode" => mode}, socket)
      when mode in ~w(parado movimento) do
    Settings.put(:player_mode, mode)
    Catcher.Worker.mode_changed()
    {:noreply, assign(socket, player_mode: mode)}
  end

  def handle_event("toggle_loot_enabled", _params, socket) do
    value = not Settings.get(:loot_enabled)
    Settings.put(:loot_enabled, value)
    {:noreply, assign(socket, loot_enabled: value)}
  end

  def handle_event("toggle_capture_enabled", _params, socket) do
    value = not Settings.get(:capture_enabled)
    Settings.put(:capture_enabled, value)
    Catcher.Worker.mode_changed()
    {:noreply, assign(socket, capture_enabled: value)}
  end
```

- Template: rework the "Captura (Pokébola)" block into three rows following the automation-row idiom already in the file:
  1. **"Modo"** — the existing parado/movimento button pair, `phx-click="set_player_mode"`, highlighting `@player_mode`; subtitle when movimento: "você saqueia e captura manualmente — em movimento o bot não age".
  2. **"Pegar loot (Espaço)"** — toggle (`automation_row`-style) bound to `@loot_enabled`, event `toggle_loot_enabled`, description "Espaço após cada kill (o corpo cai do teu lado)".
  3. **"Capturar (Pokébola)"** — toggle bound to `@capture_enabled`, event `toggle_capture_enabled`, description "joga bola nos corpos detectados ao redor".
  Keep "Reaprender chão" visible only when `@player_mode == "parado"`.
- Automation count: loot ON = `@loot_enabled and @player_mode == "parado"`; capture ON = `@capture_enabled and @player_mode == "parado"` — the list becomes 6 entries (fishing, combat, loot, capture, rescue, potion); update the "X/5 on" literal to "/6" and any test asserting it.
- Catcher pill: keep state label; where the pill shows the captures counter, show loots too (e.g. "3 🎯 · 2 🧰" or the file's counter idiom — match neighbors).
- Grep the file for `capture_mode` — zero left.

- [ ] **Step 4: Run panel tests + full suite** — green.

- [ ] **Step 5: Commit**

```bash
git add lib/pokex_web/live/panel_live.ex test/pokex_web/live/panel_live_test.exs
git commit -m "panel: global player mode + independent loot/capture toggles"
git push
```

---

### Task 3: Verification + docs

- [ ] **Step 1:** `mix test` green + `mix compile --warnings-as-errors` clean.
- [ ] **Step 2:** `grep -rn "capture_mode" lib/ test/` → ZERO hits. `grep -rn "loot" lib/pokex/bots/catcher/` → only the new loot_kill path.
- [ ] **Step 3:** README: update the capture section to mention the independent Space-loot toggle and the global mode.
- [ ] **Step 4:** Commit `docs: space loot + player mode in README` + push.
- [ ] **Step 5:** Report to Lucas (Portuguese): pull + restart; validate — kill com loot ligado → "🧰 saqueando" antes da bola; loot sem captura (toggle bola off) → só Espaços; movimento → nada; contadores.

## Self-review notes (applied)

- Spec coverage: kill-only trigger (Task 1 handlers), ordering test (first perform = spaces), capture_enabled gates ball pipeline AND attach, player_mode rename sweep, panel rows + count, loots counter in snapshot/pill.
- Type consistency: `loot_kill/1` returns state; `run_step/1` is the renamed old do_advance body; snapshot counters `Map.put(:loots, state.loots)`.
- The old panel `set_capture_mode` test is REWORKED in Task 2 Step 1 (not duplicated).
