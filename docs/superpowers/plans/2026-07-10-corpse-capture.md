# Corpse Capture (parado/movimento) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automatic Pokéball capture for a stationary player: a stateful `:corpses` perception feed (ground baseline + variance mask + stationary-blob detection) drives a new Catcher worker (queue → ball → vanish-confirmation → retry → ignore list), replacing the walk-to-corpse Loot subsystem entirely, with parado/movimento modes in the panel.

**Architecture:** `Perception.Feed` gains optional stateful (arity-4) interpreters. `Interpret.Corpses` learns the empty ground during a warmup, masks self-changing pixels (water/sparkles/character), and publishes stationary new blobs as corpse screen-points. `Catcher.Worker` (event+poll driven, same shape as Combat.Worker) throws one confirmed ball at a time via the Body. `Loot.Worker`/`Loot.Logic` die. Spec: `docs/superpowers/specs/2026-07-10-corpse-capture-design.md`.

**Tech Stack:** Elixir 1.19 / OTP 27, Phoenix LiveView, ExUnit. No new deps.

## Global Constraints

- ALL tunables live in `@seed_settings` in `lib/pokex/settings.ex`; call sites use `Settings.get/1` (process) or `Settings.value/2` (pure, takes the settings map). NEVER `settings[:x] || literal`.
- Portuguese for user-facing copy; English for code/comments/commits.
- Commit AND `git push` to `main` after every task; the full suite (`mix test`, 321 tests before this plan) must be green at every commit.
- The perception invariants hold: feeds capture ONLY while ≥1 consumer is attached; observations always carry `:captured_at` (monotonic ms); broadcast `{:world, key, obs}` on `"world"` topic ONLY on content change (`:captured_at` excluded); the ETS entry is RE-PUT with a fresh `captured_at` every tick regardless — consumers that need progress on a static screen POLL WorldState (the Combat.Worker wake pattern).
- Consumers treat `WorldState.get` `:stale`/`:missing` as unknown → fail-safe (no throws).
- Event-driven workers MUST frame-dedup (`captured_at <= last seen` = no vote) — the worker may feed the same ETS frame twice (event + racing wake).
- Body priorities unchanged; `{:capture_sequence, point}` is an existing Body action (mouse move + F1) — throws go at `:high`.
- Tests touching global `Pokex.Settings`/`Pokex.Rig.Fake`/ETS `:pokex_world` are `async: false`, restore settings in `on_exit`, and clean their ETS keys.
- Do NOT touch `body.ex`, `game_controller/*`, `fishing/*` (except where this plan names them).

---

### Task 1: Stateful (arity-4) Feed interpreters

**Files:**
- Modify: `lib/pokex/perception/feed.ex`
- Test: `test/pokex/perception/feed_test.exs` (append)

**Interfaces:**
- Consumes: existing Feed internals — `observe/1` calls `state.spec.interpret.(frame, calib, Settings.all())`; feed state map; `handle_call({:attach, pid}, ...)` with its `was_idle?` transition.
- Produces: spec field `interpret` may now be arity 4: `(frame, calib, settings, prev_state) -> {obs_map, next_state}`. `prev_state` starts `nil`; it RESETS to `nil` when the feed resumes from idle (all consumers detached → someone attaches). Arity-3 interpreters keep working unchanged. Task 2 consumes this.

- [ ] **Step 1: Write the failing test** — append to `test/pokex/perception/feed_test.exs` (reuse the file's existing `png!/3`, `save_calibration/0` helpers and setup style):

```elixir
  defp stateful_spec do
    %{
      key: :feed_stateful_test,
      region: fn _calib -> {0, 0, 10, 10} end,
      interval_setting: :feed_battle_ms,
      filename: "feed_stateful_test.png",
      # counts how many frames this ATTACHMENT has seen — resets when the feed resumes
      interpret: fn _frame, _calib, _settings, prev ->
        n = (prev || 0) + 1
        {%{frames_seen: n}, n}
      end
    }
  end

  @tag :tmp_dir
  test "arity-4 interpreters thread state and reset when the feed resumes from idle",
       %{tmp_dir: tmp} do
    a = png!(tmp, "a.png", 8)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, a}]})
    on_exit(fn -> :ets.delete(:pokex_world, :feed_stateful_test) end)

    Phoenix.PubSub.subscribe(Pokex.PubSub, "world")
    {:ok, feed} = Feed.start_link(spec: stateful_spec(), name: nil)

    :ok = Feed.attach(feed)
    # state threads across ticks: 1, 2, ...
    assert_receive {:world, :feed_stateful_test, %{frames_seen: 1}}, 1_000
    assert_receive {:world, :feed_stateful_test, %{frames_seen: 2}}, 1_000

    # pause (last consumer detaches), then resume → the counter restarts at 1
    :ok = Feed.detach(feed)
    refute_receive {:world, :feed_stateful_test, _}, 300

    :ok = Feed.attach(feed)
    assert_receive {:world, :feed_stateful_test, %{frames_seen: 1}}, 1_000
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/pokex/perception/feed_test.exs`
Expected: FAIL — `BadArityError` (the feed calls interpret with 3 args).

- [ ] **Step 3: Implement.** In `lib/pokex/perception/feed.ex`:

Add `interp_state: nil` to the state map in `init/1`.

In `handle_call({:attach, pid}, ...)`, the `was_idle?` branch resets interpreter state before rescheduling — change the line that reschedules on the idle→non-idle transition to:

```elixir
        state = %{state | consumers: Map.put(state.consumers, pid, ref)}
        if was_idle?, do: reschedule(%{state | interp_state: nil, last_obs: nil}, 0), else: state
```

In `observe/1`, replace the interpret call with an arity dispatch (the rest of the `with` stays identical):

```elixir
      {obs_body, interp_state} = run_interpret(state, frame, calib)

      obs = Map.put(obs_body, :captured_at, at)
```

(keep `at = now()` computed before, as today) and store the new state on the success path:

```elixir
      %{state | last_obs: obs, interp_state: interp_state}
```

Add the private helper:

```elixir
  # Interpreters come in two shapes: pure (arity 3) and stateful (arity 4 — e.g. the corpse
  # detector's warmup baseline). State lives here in the feed and resets whenever the feed
  # resumes from idle, so every fresh attachment relearns from scratch.
  defp run_interpret(state, frame, calib) do
    settings = Settings.all()

    case Function.info(state.spec.interpret, :arity) do
      {:arity, 4} -> state.spec.interpret.(frame, calib, settings, state.interp_state)
      {:arity, 3} -> {state.spec.interpret.(frame, calib, settings), state.interp_state}
    end
  end
```

NOTE: a failed tick (capture error) must NOT advance or reset `interp_state` — verify the error path leaves it untouched (it does if you only set it on the success path).

- [ ] **Step 4: Run the feed tests and the full suite**

Run: `mix test test/pokex/perception/feed_test.exs && mix test`
Expected: PASS, suite green (arity-3 feeds unaffected).

- [ ] **Step 5: Commit**

```bash
git add lib/pokex/perception/feed.ex test/pokex/perception/feed_test.exs
git commit -m "perception: optional stateful (arity-4) feed interpreters"
git push
```

---

### Task 2: `Interpret.Corpses` detector + `:corpses` feed spec + seeds

**Files:**
- Create: `lib/pokex/perception/interpret/corpses.ex`
- Modify: `lib/pokex/perception.ex` (add the feed spec)
- Modify: `lib/pokex/settings.ex` (detector seeds)
- Test: `test/pokex/perception/interpret_corpses_test.exs`

**Interfaces:**
- Consumes: Task 1's arity-4 contract; `Pokex.Vision.Frame` struct (`width`, `height`, `rgba` — 4 bytes/pixel, row-major); `Calibration.frame_to_screen(calib, region, {px, py})` → screen point; `Settings.value(settings, key)` (pure).
- Produces: `Interpret.Corpses.interpret(frame, calib, settings, state)` → `{%{scanning?: boolean, corpses: [{x, y}]}, state}` with corpses in SCREEN points sorted ascending. Task 4 consumes the observation shape.

- [ ] **Step 1: Seeds.** Append to `@seed_settings` in `lib/pokex/settings.ex` (after the focus-guard block):

```elixir
    # --- Corpse capture (parado mode) -------------------------------------------------------------
    # The :corpses feed learns the EMPTY ground at attach: the first warmup frame is the baseline
    # and any 16px cell that deviates during the remaining warmup frames (animated water, sparkles,
    # the character) is masked out forever. After warmup, a masked-diff blob that holds still for
    # corpse_stationary_frames consecutive frames is a corpse (a wandering pet never qualifies).
    # Start the bot with the ground CLEAN — a corpse present at attach becomes part of the baseline.
    feed_corpses_ms: 400,
    corpse_warmup_frames: 20,
    corpse_cell_px: 16,
    # per-channel delta for a sample to count as changed (warmup: mask a cell; scanning: heat it)
    corpse_noise_threshold: 40,
    corpse_diff_threshold: 40,
    # samples per 16px cell = 16 (stride 4); a cell is HOT when this many changed
    corpse_cell_min_samples: 6,
    # a blob needs this many connected hot cells (a corpse sprite spans ~2-3 cells)
    corpse_min_cells: 2,
    corpse_stationary_frames: 2,
    corpse_stationary_tolerance_px: 24,
```

- [ ] **Step 2: Write the failing tests**

```elixir
# test/pokex/perception/interpret_corpses_test.exs
defmodule Pokex.Perception.Interpret.CorpsesTest do
  use ExUnit.Case, async: true

  alias Pokex.Perception.Interpret.Corpses
  alias Pokex.{Calibration, Settings}
  alias Pokex.Vision.Frame

  # 64x64 frame = 4x4 grid of 16px cells at scale 1.0.
  defp calib do
    %Calibration{
      scale: 1.0,
      screen_w: 1000,
      screen_h: 700,
      water_point: {1, 1},
      glow_region: {0, 0, 8, 8},
      battle_region: {900, 0, 80, 400},
      arena_region: {100, 200, 64, 64},
      neutral_point: {500, 500}
    }
  end

  defp settings(overrides \\ %{}) do
    Map.merge(Settings.defaults(), Map.merge(%{corpse_warmup_frames: 3}, overrides))
  end

  # A frame painted by fun.(x, y) -> {r, g, b}.
  defp frame(paint) do
    rgba =
      for y <- 0..63, x <- 0..63, into: <<>> do
        {r, g, b} = paint.(x, y)
        <<r, g, b, 255>>
      end

    %Frame{width: 64, height: 64, rgba: rgba}
  end

  defp ground(_x, _y), do: {100, 90, 60}

  # Paint a 16x16 "corpse" whose top-left is the given cell (cx, cy).
  defp with_corpse(cx, cy) do
    fn x, y ->
      if div(x, 16) in [cx, cx + 1] and div(y, 16) == cy, do: {230, 40, 40}, else: ground(x, y)
    end
  end

  defp warm_up(settings) do
    {_obs, st} = Corpses.interpret(frame(&ground/2), calib(), settings, nil)

    Enum.reduce(1..2, st, fn _i, acc ->
      {obs, next} = Corpses.interpret(frame(&ground/2), calib(), settings, acc)
      refute obs.scanning? and obs.corpses != []
      next
    end)
  end

  test "warmup publishes scanning?: false, then flips to scanning" do
    s = settings()
    {obs, st} = Corpses.interpret(frame(&ground/2), calib(), s, nil)
    assert obs == %{scanning?: false, corpses: []}

    {_obs, st} = Corpses.interpret(frame(&ground/2), calib(), s, st)
    {obs, _st} = Corpses.interpret(frame(&ground/2), calib(), s, st)
    assert obs.scanning?
  end

  test "a new static blob becomes a corpse only after the stationary frames, in screen points" do
    s = settings()
    st = warm_up(s)

    # frame 1 with the blob: tracked but not yet confirmed (stationary_frames: 2)
    {obs, st} = Corpses.interpret(frame(with_corpse(1, 1)), calib(), s, st)
    assert obs.corpses == []

    # frame 2, same place: confirmed. Blob spans cells {1,1},{2,1} → center ~x=32..48,y=24
    {obs, _st} = Corpses.interpret(frame(with_corpse(1, 1)), calib(), s, st)
    assert [{sx, sy}] = obs.corpses
    # screen point = arena_region origin {100, 200} + frame px (scale 1.0)
    assert sx in 130..148
    assert sy in 220..232
  end

  test "a blob that moves every frame never becomes a corpse" do
    s = settings()
    st = warm_up(s)

    {obs, st} = Corpses.interpret(frame(with_corpse(0, 0)), calib(), s, st)
    assert obs.corpses == []
    {obs, st} = Corpses.interpret(frame(with_corpse(2, 2)), calib(), s, st)
    assert obs.corpses == []
    {obs, _st} = Corpses.interpret(frame(with_corpse(0, 2)), calib(), s, st)
    assert obs.corpses == []
  end

  test "cells that flicker during warmup are masked and never produce corpses" do
    s = settings()

    # 'water' in the bottom row of cells flickers during warmup
    water = fn phase ->
      fn x, y ->
        if div(y, 16) == 3 and rem(x + phase, 2) == 0, do: {30, 60, 200}, else: ground(x, y)
      end
    end

    {_obs, st} = Corpses.interpret(frame(water.(0)), calib(), s, nil)
    {_obs, st} = Corpses.interpret(frame(water.(1)), calib(), s, st)
    {_obs, st} = Corpses.interpret(frame(water.(0)), calib(), s, st)

    # a "corpse" painted INSIDE the masked water row is invisible…
    still_water = fn x, y ->
      if div(y, 16) == 3 and div(x, 16) in [1, 2], do: {230, 40, 40}, else: water.(0).(x, y)
    end

    {obs, st} = Corpses.interpret(frame(still_water), calib(), s, st)
    {obs2, _st} = Corpses.interpret(frame(still_water), calib(), s, st)
    assert obs.corpses == []
    assert obs2.corpses == []
  end

  test "a blob smaller than corpse_min_cells is noise" do
    # min 2 cells; paint a single-cell blob
    s = settings()
    st = warm_up(s)

    one_cell = fn x, y ->
      if div(x, 16) == 1 and div(y, 16) == 1, do: {230, 40, 40}, else: ground(x, y)
    end

    {_obs, st} = Corpses.interpret(frame(one_cell), calib(), s, st)
    {obs, _st} = Corpses.interpret(frame(one_cell), calib(), s, st)
    # a 16px cell has 16 samples all changed → hot, but 1 cell < corpse_min_cells 2
    assert obs.corpses == []
  end
end
```

- [ ] **Step 3: Run to verify failure**

Run: `mix test test/pokex/perception/interpret_corpses_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 4: Implement**

```elixir
# lib/pokex/perception/interpret/corpses.ex
defmodule Pokex.Perception.Interpret.Corpses do
  @moduledoc """
  Stateful corpse detector for a STATIONARY player (spec
  docs/superpowers/specs/2026-07-10-corpse-capture-design.md).

  Warmup: the first frame is the ground BASELINE; any cell that deviates during the remaining
  warmup frames (animated water, sparkles, the breathing character) joins the variance MASK and
  is ignored forever. Scanning: cells whose sampled pixels moved beyond the diff threshold heat
  up; connected hot cells form blobs; a blob only becomes a CORPSE after holding the same spot
  for consecutive frames — a wandering pet never qualifies. Corpses are reported as SCREEN
  points. All knobs are seeds (see the corpse-capture block in Settings).

  Pure given its inputs: the Feed threads the state (arity-4 interpreter) and resets it when
  the feed resumes from idle, so every bot start relearns the ground.
  """

  alias Pokex.{Calibration, Settings}
  alias Pokex.Vision.Frame

  # Sample every 4th pixel in both axes: a 16px cell yields 16 samples — plenty to vote a cell
  # hot while scanning ~16x fewer pixels than the full frame.
  @stride 4

  def interpret(%Frame{} = frame, _calib, settings, nil) do
    {%{scanning?: false, corpses: []},
     %{phase: :warmup, baseline: grid(frame, cell_px(settings)), bad: MapSet.new(), frames: 1}}
  end

  def interpret(%Frame{} = frame, _calib, settings, %{phase: :warmup} = st) do
    grid = grid(frame, cell_px(settings))
    noise = Settings.value(settings, :corpse_noise_threshold)
    min_samples = Settings.value(settings, :corpse_cell_min_samples)

    bad =
      Enum.reduce(grid, st.bad, fn {cell, samples}, acc ->
        if changed_samples(Map.get(st.baseline, cell), samples, noise) >= min_samples,
          do: MapSet.put(acc, cell),
          else: acc
      end)

    frames = st.frames + 1

    if frames >= Settings.value(settings, :corpse_warmup_frames) do
      {%{scanning?: true, corpses: []},
       %{phase: :scanning, baseline: st.baseline, bad: bad, tracks: %{}}}
    else
      {%{scanning?: false, corpses: []}, %{st | bad: bad, frames: frames}}
    end
  end

  def interpret(%Frame{} = frame, calib, settings, %{phase: :scanning} = st) do
    cell_px = cell_px(settings)
    diff = Settings.value(settings, :corpse_diff_threshold)
    min_samples = Settings.value(settings, :corpse_cell_min_samples)
    min_cells = Settings.value(settings, :corpse_min_cells)
    tolerance = Settings.value(settings, :corpse_stationary_tolerance_px)
    needed = Settings.value(settings, :corpse_stationary_frames)

    hot =
      for {cell, samples} <- grid(frame, cell_px),
          not MapSet.member?(st.bad, cell),
          changed_samples(Map.get(st.baseline, cell), samples, diff) >= min_samples,
          into: MapSet.new(),
          do: cell

    centers =
      hot
      |> clusters()
      |> Enum.filter(&(MapSet.size(&1) >= min_cells))
      |> Enum.map(&center_px(&1, cell_px))

    {tracks, confirmed} = advance_tracks(st.tracks, centers, tolerance, needed)

    corpses =
      confirmed
      |> Enum.map(&Calibration.frame_to_screen(calib, calib.arena_region, &1))
      |> Enum.sort()

    {%{scanning?: true, corpses: corpses}, %{st | tracks: tracks}}
  end

  # -- sampling ---------------------------------------------------------------

  # %{ {cx, cy} => [{r, g, b}] } — samples in deterministic order, so baseline and current
  # lists zip positionally.
  defp grid(%Frame{width: w, height: h, rgba: rgba}, cell_px) do
    for y <- 0..(h - 1)//@stride, x <- 0..(w - 1)//@stride, reduce: %{} do
      acc ->
        offset = (y * w + x) * 4
        <<_::binary-size(offset), r, g, b, _a, _::binary>> = rgba
        Map.update(acc, {div(x, cell_px), div(y, cell_px)}, [{r, g, b}], &[{r, g, b} | &1])
    end
  end

  defp changed_samples(nil, _samples, _threshold), do: 0

  defp changed_samples(baseline, samples, threshold) do
    baseline
    |> Enum.zip(samples)
    |> Enum.count(fn {{br, bg, bb}, {r, g, b}} ->
      abs(r - br) > threshold or abs(g - bg) > threshold or abs(b - bb) > threshold
    end)
  end

  # -- blobs ------------------------------------------------------------------

  # 4-connectivity connected components over the hot-cell set.
  defp clusters(hot) do
    {clusters, _seen} =
      Enum.reduce(hot, {[], MapSet.new()}, fn cell, {clusters, seen} ->
        if MapSet.member?(seen, cell) do
          {clusters, seen}
        else
          cluster = flood(hot, [cell], MapSet.new())
          {[cluster | clusters], MapSet.union(seen, cluster)}
        end
      end)

    clusters
  end

  defp flood(_hot, [], acc), do: acc

  defp flood(hot, [cell | rest], acc) do
    if MapSet.member?(acc, cell) do
      flood(hot, rest, acc)
    else
      {cx, cy} = cell

      neighbors =
        [{cx + 1, cy}, {cx - 1, cy}, {cx, cy + 1}, {cx, cy - 1}]
        |> Enum.filter(&MapSet.member?(hot, &1))

      flood(hot, neighbors ++ rest, MapSet.put(acc, cell))
    end
  end

  defp center_px(cluster, cell_px) do
    n = MapSet.size(cluster)
    {sx, sy} = Enum.reduce(cluster, {0, 0}, fn {cx, cy}, {ax, ay} -> {ax + cx, ay + cy} end)
    half = div(cell_px, 2)
    {div(sx * cell_px, n) + half, div(sy * cell_px, n) + half}
  end

  # -- stationary tracking ------------------------------------------------------

  # tracks: %{center => consecutive_frames_seen}. A center inherits (count + 1) from the
  # nearest previous track within tolerance; otherwise starts at 1. Confirmed at `needed`.
  defp advance_tracks(prev, centers, tolerance, needed) do
    tracks =
      Map.new(centers, fn center ->
        inherited =
          prev
          |> Enum.filter(fn {point, _count} -> near?(point, center, tolerance) end)
          |> Enum.map(fn {_point, count} -> count end)
          |> Enum.max(fn -> 0 end)

        {center, inherited + 1}
      end)

    confirmed = for {center, count} <- tracks, count >= needed, do: center
    {tracks, confirmed}
  end

  defp near?({ax, ay}, {bx, by}, tolerance),
    do: abs(ax - bx) <= tolerance and abs(ay - by) <= tolerance

  defp cell_px(settings), do: Settings.value(settings, :corpse_cell_px)
end
```

- [ ] **Step 5: Register the feed.** In `lib/pokex/perception.ex`, add to `feed_specs/0`:

```elixir
      %{
        key: :corpses,
        region: fn calib -> calib.arena_region end,
        interval_setting: :feed_corpses_ms,
        filename: "feed_corpses.png",
        interpret: &Interpret.Corpses.interpret/4
      }
```

(alias stays `Interpret` — reference the submodule as `Interpret.Corpses`.)

- [ ] **Step 6: Run tests and full suite**

Run: `mix test test/pokex/perception/interpret_corpses_test.exs && mix test`
Expected: PASS, suite green (the new feed is dormant — no consumers).

- [ ] **Step 7: Commit**

```bash
git add lib/pokex/perception/interpret/corpses.ex lib/pokex/perception.ex lib/pokex/settings.ex test/pokex/perception/interpret_corpses_test.exs
git commit -m "perception: stateful corpse detector feed (ground baseline + variance mask)"
git push
```

---

### Task 3: `Catcher.Logic` (pure)

**Files:**
- Create: `lib/pokex/bots/catcher/logic.ex`
- Modify: `lib/pokex/settings.ex` (catcher seeds)
- Test: `test/pokex/bots/catcher/logic_test.exs`

**Interfaces:**
- Consumes: config map with keys `corpse_match_tolerance_px`, `corpse_max_balls`, `corpse_ignore_ttl_ms`, `corpse_confirm_after_ms`, `feed_corpses_ms`.
- Produces (Task 4 consumes): `Logic.new(config)`, `start(logic, now)` → `:armed`, `stop(logic)` → `:idle`, `step(logic, obs_or_nil, now)` → `{logic, actions}` with actions `{:capture_sequence, point}` | `{:log, msg}`; `next_wake(logic, now)` → ms | nil; counters `%{captures: 0, throws: 0, ignored: 0}`; snapshot-friendly fields `state`, `counters`, `error`.

- [ ] **Step 1: Seeds.** Append to the corpse-capture block in `lib/pokex/settings.ex`:

```elixir
    # Catcher: one ball in flight at a time, confirmed against the next observations. A hit
    # consumes the corpse instantly (game rule), so a blob that SURVIVES corpse_max_balls
    # throws is not a corpse (a parked pet) → ignored for corpse_ignore_ttl_ms. Confirmation
    # only counts observations captured at least corpse_confirm_after_ms after the throw (the
    # ball needs flight time — an instant re-read would read the pre-hit frame).
    capture_mode: "parado",
    corpse_match_tolerance_px: 32,
    corpse_max_balls: 2,
    corpse_ignore_ttl_ms: 120_000,
    corpse_confirm_after_ms: 800,
    catcher_world_max_age_ms: 1_200,
```

- [ ] **Step 2: Write the failing tests**

```elixir
# test/pokex/bots/catcher/logic_test.exs
defmodule Pokex.Bots.Catcher.LogicTest do
  use ExUnit.Case, async: true

  alias Pokex.Bots.Catcher.Logic

  defp config do
    %{
      corpse_match_tolerance_px: 32,
      corpse_max_balls: 2,
      corpse_ignore_ttl_ms: 120_000,
      corpse_confirm_after_ms: 800,
      feed_corpses_ms: 400
    }
  end

  defp armed do
    {logic, []} = Logic.start(Logic.new(config()), 0)
    logic
  end

  defp obs(corpses, at), do: %{scanning?: true, corpses: corpses, captured_at: at}

  test "a corpse observation throws ONE ball and awaits confirmation" do
    {logic, actions} = Logic.step(armed(), obs([{100, 200}], 10), 10)
    assert {:capture_sequence, {100, 200}} in actions
    assert logic.counters.throws == 1

    # more corpses queue but nothing else is thrown while one is in flight
    {logic, actions} = Logic.step(logic, obs([{100, 200}, {300, 300}], 900), 900)
    refute Enum.any?(actions, &match?({:capture_sequence, _}, &1))
    assert logic.queue == [{300, 300}]
  end

  test "the corpse vanishing after the flight window confirms the capture and throws the next" do
    {logic, _} = Logic.step(armed(), obs([{100, 200}], 10), 10)
    {logic, _} = Logic.step(logic, obs([{100, 200}, {300, 300}], 900), 900)

    # gone (only the queued one remains) on a frame past confirm_after → captured
    {logic, actions} = Logic.step(logic, obs([{300, 300}], 1_000), 1_000)
    assert logic.counters.captures == 1
    # and the next queued corpse is thrown at in the same step
    assert {:capture_sequence, {300, 300}} in actions
  end

  test "an observation captured BEFORE the flight window never confirms nor retries" do
    {logic, _} = Logic.step(armed(), obs([{100, 200}], 10), 10)
    # captured_at 500 < throw at 10 + confirm_after 800 → too early, no verdict
    {logic, actions} = Logic.step(logic, obs([], 500), 500)
    assert logic.counters.captures == 0
    assert logic.throw != nil
    assert actions == []
  end

  test "a persisting blob gets one retry then joins the ignore list" do
    {logic, _} = Logic.step(armed(), obs([{100, 200}], 10), 10)

    # still there after the window → retry (ball 2)
    {logic, actions} = Logic.step(logic, obs([{104, 196}], 900), 900)
    assert {:capture_sequence, {100, 200}} in actions
    assert logic.throw.balls == 2

    # STILL there → ignored, no more balls
    {logic, actions} = Logic.step(logic, obs([{100, 200}], 1_800), 1_800)
    refute Enum.any?(actions, &match?({:capture_sequence, _}, &1))
    assert logic.counters.ignored == 1
    assert logic.throw == nil

    # while ignored, the same point is never re-admitted
    {logic, actions} = Logic.step(logic, obs([{102, 198}], 2_400), 2_400)
    assert actions == []
    assert logic.queue == []

    # after the TTL it is fair game again
    {_logic, actions} = Logic.step(logic, obs([{100, 200}], 130_000), 130_000)
    assert {:capture_sequence, {100, 200}} in actions
  end

  test "stale/nil observations do nothing" do
    assert {%Logic{}, []} = Logic.step(armed(), nil, 50)
  end

  test "frame dedup: the same captured_at never double-confirms" do
    {logic, _} = Logic.step(armed(), obs([{100, 200}], 10), 10)
    {logic, _} = Logic.step(logic, obs([], 900), 900)
    assert logic.counters.captures == 1

    # same frame again (event + wake race) → no second verdict, no crash
    {logic, actions} = Logic.step(logic, obs([], 900), 901)
    assert logic.counters.captures == 1
    assert actions == []
  end

  test "next_wake polls while a throw or queue is pending, sleeps when idle-empty" do
    logic = armed()
    assert Logic.next_wake(logic, 0) == nil

    {logic, _} = Logic.step(logic, obs([{100, 200}], 10), 10)
    assert Logic.next_wake(logic, 10) == 400

    {logic, _} = Logic.step(logic, obs([], 900), 900)
    assert Logic.next_wake(logic, 900) == nil
  end
end
```

- [ ] **Step 3: Run to verify failure** — `mix test test/pokex/bots/catcher/logic_test.exs` → module undefined.

- [ ] **Step 4: Implement**

```elixir
# lib/pokex/bots/catcher/logic.ex
defmodule Pokex.Bots.Catcher.Logic do
  @moduledoc """
  Pure decision core for corpse capture (spec 2026-07-10-corpse-capture-design.md): admit
  detected corpses into a queue, keep exactly ONE ball in flight, confirm each throw against
  observations captured after the ball's flight window (a hit consumes the corpse instantly —
  game rule), retry once, and ignore persistent non-corpses (a parked pet) for a TTL. No I/O,
  no clock: the driver supplies observations and monotonic `now`.
  """

  defstruct state: :idle,
            config: nil,
            queue: [],
            throw: nil,
            ignored: %{},
            last_obs_at: nil,
            error: nil,
            counters: %{captures: 0, throws: 0, ignored: 0}

  def new(config), do: %__MODULE__{config: config}

  def start(%__MODULE__{} = logic, _now) do
    {%{logic | state: :armed, queue: [], throw: nil, ignored: %{}, last_obs_at: nil, error: nil},
     []}
  end

  def stop(logic), do: {%{logic | state: :idle, queue: [], throw: nil}, []}

  @doc "Observation step. obs = %{corpses: [{x,y}], captured_at: ms} | nil (nothing fresh)."
  def step(%__MODULE__{state: :idle} = logic, _obs, _now), do: {logic, []}
  def step(logic, nil, _now), do: {logic, []}

  def step(%{last_obs_at: last} = logic, %{captured_at: at}, _now)
      when is_integer(last) and at <= last,
      do: {logic, []}

  def step(logic, obs, now) do
    logic = %{prune_ignored(logic, now) | last_obs_at: obs.captured_at}

    {logic, confirm_actions} = confirm(logic, obs, now)
    logic = admit(logic, obs.corpses)
    {logic, throw_actions} = maybe_throw(logic, now)

    {logic, confirm_actions ++ throw_actions}
  end

  @doc "Poll cadence while work is pending; nil when there is nothing to watch."
  def next_wake(%__MODULE__{state: :idle}, _now), do: nil
  def next_wake(%__MODULE__{throw: nil, queue: []}, _now), do: nil
  def next_wake(%__MODULE__{config: config}, _now), do: max(config.feed_corpses_ms, 1)

  # -- confirmation -------------------------------------------------------------

  defp confirm(%{throw: nil} = logic, _obs, _now), do: {logic, []}

  defp confirm(%{throw: throw, config: config} = logic, obs, now) do
    cond do
      # the ball is still flying — this frame proves nothing
      obs.captured_at < throw.at + config.corpse_confirm_after_ms ->
        {logic, []}

      # gone → captured
      not Enum.any?(obs.corpses, &near?(&1, throw.point, config.corpse_match_tolerance_px)) ->
        logic = update_in(logic.counters.captures, &(&1 + 1))
        {%{logic | throw: nil}, [{:log, "capturado em #{point_str(throw.point)}"}]}

      # survived with balls left → one more
      throw.balls < config.corpse_max_balls ->
        logic = update_in(logic.counters.throws, &(&1 + 1))

        {%{logic | throw: %{throw | balls: throw.balls + 1, at: now}},
         [{:capture_sequence, throw.point}, {:log, "bola #{throw.balls + 1} em #{point_str(throw.point)}"}]}

      # survived everything → not a corpse; ignore it for the TTL
      true ->
        logic = update_in(logic.counters.ignored, &(&1 + 1))
        ignored = Map.put(logic.ignored, throw.point, now + config.corpse_ignore_ttl_ms)

        {%{logic | throw: nil, ignored: ignored},
         [{:log, "não é corpo (#{point_str(throw.point)}); ignorando"}]}
    end
  end

  # -- admission ---------------------------------------------------------------

  defp admit(logic, corpses) do
    tolerance = logic.config.corpse_match_tolerance_px

    known =
      logic.queue ++
        Map.keys(logic.ignored) ++ if logic.throw, do: [logic.throw.point], else: []

    fresh = Enum.reject(corpses, fn c -> Enum.any?(known, &near?(&1, c, tolerance)) end)
    %{logic | queue: logic.queue ++ fresh}
  end

  defp maybe_throw(%{throw: nil, queue: [point | rest]} = logic, now) do
    logic = update_in(logic.counters.throws, &(&1 + 1))

    {%{logic | throw: %{point: point, balls: 1, at: now}, queue: rest},
     [{:capture_sequence, point}, {:log, "bola em #{point_str(point)}"}]}
  end

  defp maybe_throw(logic, _now), do: {logic, []}

  defp prune_ignored(logic, now) do
    %{logic | ignored: Map.filter(logic.ignored, fn {_point, expiry} -> expiry > now end)}
  end

  defp near?({ax, ay}, {bx, by}, tolerance),
    do: abs(ax - bx) <= tolerance and abs(ay - by) <= tolerance

  defp point_str({x, y}), do: "#{x},#{y}"
end
```

- [ ] **Step 5: Run tests and the full suite** — both green. NOTE: the "vanishing confirms AND throws the next in the same step" test depends on confirm running BEFORE maybe_throw in `step/3` — that ordering is intentional; don't reorder.

- [ ] **Step 6: Commit**

```bash
git add lib/pokex/bots/catcher/logic.ex lib/pokex/settings.ex test/pokex/bots/catcher/logic_test.exs
git commit -m "catcher: pure capture logic (queue, confirmed throws, ignore list)"
git push
```

---

### Task 4: `Catcher.Worker` (event+poll driven)

**Files:**
- Create: `lib/pokex/bots/catcher/worker.ex`
- Test: `test/pokex/bots/catcher/worker_test.exs`

**Interfaces:**
- Consumes: `Catcher.Logic` (Task 3); `Perception.attach/detach(:corpses)`; `WorldState.get(:corpses, max_age, now)`; `Body.perform(actions, :high, body)`; `Settings.get/1`. Kill topic: subscribe to `"combat:kill"` and tolerate BOTH `{:kill}` and `{:kill, _corpse}` shapes (combat still sends the old shape until Task 5).
- Produces: `Catcher.Worker.run/1, halt/1, status/1, topic/0` ("catcher"), `kill_topic/0` ("combat:kill"), `mode_changed/1` (panel pokes it when capture_mode flips), `relearn/1` (detach+attach → fresh warmup). Snapshot `%{state: :idle | :armed | :manual, mode: "parado" | "movimento", counters, error}`. Broadcasts `{:catcher, snapshot}` and `{:catcher_log, level, text}` on "catcher".

- [ ] **Step 1: Write the failing tests**

```elixir
# test/pokex/bots/catcher/worker_test.exs
defmodule Pokex.Bots.Catcher.WorkerTest.FakeBody do
  use GenServer
  def start_link(test), do: GenServer.start_link(__MODULE__, test)
  @impl true
  def init(test), do: {:ok, test}
  @impl true
  def handle_call({:perform, actions, priority, _at}, _from, test) do
    send(test, {:performed, priority, actions})
    {:reply, :ok, test}
  end
end

defmodule Pokex.Bots.Catcher.WorkerTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.Catcher.Worker
  alias Pokex.Bots.Catcher.WorkerTest.FakeBody
  alias Pokex.Perception.WorldState
  alias Pokex.{Calibration, Settings}

  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    mode = Settings.get(:capture_mode)

    on_exit(fn ->
      Application.delete_env(:pokex, :home_dir)
      Settings.put(:capture_mode, mode)
      :ets.delete(:pokex_world, :corpses)
    end)

    Settings.put(:capture_mode, "parado")

    Calibration.save(%Calibration{
      scale: 1.0,
      screen_w: 1000,
      screen_h: 700,
      water_point: {400, 300},
      glow_region: {0, 0, 20, 20},
      battle_region: {900, 0, 80, 400},
      arena_region: {100, 200, 64, 64},
      neutral_point: {500, 500}
    })

    {:ok, _} = Pokex.Rig.Fake.start_link(%{})
    {:ok, body} = FakeBody.start_link(self())
    worker = start_supervised!({Worker, name: nil, body: body})
    :ok = Worker.run(worker)
    %{worker: worker}
  end

  defp corpses_obs(points) do
    %{scanning?: true, corpses: points, captured_at: System.monotonic_time(:millisecond)}
  end

  defp world!(worker, obs) do
    WorldState.put(:corpses, obs, obs.captured_at)
    send(worker, {:world, :corpses, obs})
  end

  @tag :tmp_dir
  test "a corpse observation makes it throw a ball at :high", %{worker: worker} do
    world!(worker, corpses_obs([{130, 224}]))
    assert_receive {:performed, :high, [{:capture_sequence, {130, 224}}]}, 1_000
    assert Worker.status(worker).counters.throws == 1
  end

  @tag :tmp_dir
  test "polling alone confirms a vanished corpse (no further events)", %{worker: worker} do
    world!(worker, corpses_obs([{130, 224}]))
    assert_receive {:performed, :high, _}, 1_000

    # the feed keeps RE-PUTTING fresh empty observations without broadcasting (no change);
    # simulate that and let the worker's wake polling find them
    spawn(fn ->
      for _i <- 1..8 do
        Process.sleep(150)
        obs = corpses_obs([])
        WorldState.put(:corpses, obs, obs.captured_at)
      end
    end)

    assert eventually(fn -> Worker.status(worker).counters.captures == 1 end, 3_000)
  end

  @tag :tmp_dir
  test "a kill event triggers an immediate world re-read", %{worker: worker} do
    obs = corpses_obs([{140, 230}])
    WorldState.put(:corpses, obs, obs.captured_at)
    # no {:world,...} event — only the kill accelerator
    Phoenix.PubSub.broadcast(Pokex.PubSub, Worker.kill_topic(), {:kill})

    assert_receive {:performed, :high, [{:capture_sequence, {140, 230}}]}, 1_000
  end

  @tag :tmp_dir
  test "movimento mode never acts", %{worker: worker} do
    Settings.put(:capture_mode, "movimento")
    :ok = Worker.mode_changed(worker)
    assert Worker.status(worker).state == :manual

    world!(worker, corpses_obs([{130, 224}]))
    refute_receive {:performed, _p, _a}, 300

    # flipping back re-arms
    Settings.put(:capture_mode, "parado")
    :ok = Worker.mode_changed(worker)
    assert Worker.status(worker).state == :armed
  end

  defp eventually(fun, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      if fun.(), do: true, else: (Process.sleep(20) && false)
    end)
    |> Enum.find(fn done -> done or System.monotonic_time(:millisecond) > deadline end)
  end
end
```

- [ ] **Step 2: Run to verify failure** — module undefined.

- [ ] **Step 3: Implement** (mirror Combat.Worker's driver shape — event step + `next_wake` polling + frame dedup already inside the Logic):

```elixir
# lib/pokex/bots/catcher/worker.ex
defmodule Pokex.Bots.Catcher.Worker do
  @moduledoc """
  Driver for the pure Catcher.Logic: consumes `:corpses` observations from the perception
  blackboard, throws confirmed Pokéballs through the Body (`:high`), and follows the capture
  mode LIVE — `parado` attaches the feed and acts; `movimento` detaches and idles (Lucas
  captures manually while moving). Combat's kill broadcast is only an accelerator: it forces
  an immediate world re-read; detection never depends on it.
  """
  use GenServer

  alias Pokex.Bots.Body
  alias Pokex.Bots.Catcher.Logic
  alias Pokex.Perception
  alias Pokex.Perception.WorldState
  alias Pokex.Settings

  @topic "catcher"
  @kill_topic "combat:kill"

  @config_keys [
    :corpse_match_tolerance_px,
    :corpse_max_balls,
    :corpse_ignore_ttl_ms,
    :corpse_confirm_after_ms,
    :feed_corpses_ms
  ]

  def topic, do: @topic
  def kill_topic, do: @kill_topic

  def start_link(opts \\ []) do
    body = Keyword.get(opts, :body, Body)

    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, body)
      name -> GenServer.start_link(__MODULE__, body, name: name)
    end
  end

  def run(server \\ __MODULE__), do: GenServer.call(server, :run)
  def halt(server \\ __MODULE__), do: GenServer.call(server, :halt)
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "The panel pokes this after flipping capture_mode — attach/detach applies live."
  def mode_changed(server \\ __MODULE__), do: GenServer.call(server, :mode_changed)

  @doc "Force a fresh ground warmup (detach + attach): use after moving to a new spot."
  def relearn(server \\ __MODULE__), do: GenServer.call(server, :relearn)

  @impl true
  def init(body) do
    Phoenix.PubSub.subscribe(Pokex.PubSub, @kill_topic)
    Phoenix.PubSub.subscribe(Pokex.PubSub, Perception.topic())
    {:ok, %{logic: nil, body: body, timer: nil, attached?: false}}
  end

  @impl true
  def handle_call(:run, _from, state) do
    {logic, _} = Logic.start(Logic.new(config()), now())
    state = sync_mode(%{state | logic: logic})
    broadcast(state)
    {:reply, :ok, state}
  end

  def handle_call(:halt, _from, %{logic: nil} = state), do: {:reply, :ok, state}

  def handle_call(:halt, _from, state) do
    {logic, _} = Logic.stop(state.logic)
    state = detach(%{state | logic: logic})
    broadcast(state)
    {:reply, :ok, cancel_timer(state)}
  end

  def handle_call(:status, _from, state), do: {:reply, snapshot(state), state}

  def handle_call(:mode_changed, _from, %{logic: nil} = state), do: {:reply, :ok, state}

  def handle_call(:mode_changed, _from, state) do
    state = sync_mode(state)
    broadcast(state)
    {:reply, :ok, state}
  end

  def handle_call(:relearn, _from, state) do
    state = state |> detach() |> sync_mode()
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:world, :corpses, obs}, %{logic: %Logic{state: :armed}} = state),
    do: {:noreply, advance(state, obs)}

  def handle_info({:world, _key, _obs}, state), do: {:noreply, state}

  def handle_info(:wake, %{logic: %Logic{state: :armed}} = state),
    do: {:noreply, advance(state, current_obs())}

  def handle_info(:wake, state), do: {:noreply, state}

  # kill = accelerator (both shapes: Task 5 drops the payload; tolerate the old one meanwhile)
  def handle_info({:kill}, %{logic: %Logic{state: :armed}} = state),
    do: {:noreply, advance(state, current_obs())}

  def handle_info({:kill, _corpse}, %{logic: %Logic{state: :armed}} = state),
    do: {:noreply, advance(state, current_obs())}

  def handle_info(_msg, state), do: {:noreply, state}

  # -- step pipeline -------------------------------------------------------------

  # The mode gate lives HERE, not only in attach/detach: a late in-flight {:world,...} event
  # (or a test-injected one) right after flipping to movimento must never throw a ball.
  defp advance(state, obs) do
    if Settings.get(:capture_mode) == "parado", do: do_advance(state, obs), else: state
  end

  defp do_advance(state, obs) do
    {logic, actions} = Logic.step(state.logic, obs, now())

    performs = Enum.filter(actions, &match?({:capture_sequence, _}, &1))
    if performs != [], do: Body.perform(performs, :high, state.body)

    for {:log, text} <- actions do
      Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:catcher_log, :macro, "captura: #{text}"})
    end

    if logic.counters != state.logic.counters or actions != [],
      do: broadcast(%{state | logic: logic})

    schedule_wake(%{state | logic: logic})
  end

  defp current_obs do
    case WorldState.get(:corpses, Settings.get(:catcher_world_max_age_ms), now()) do
      {:ok, obs} -> obs
      _stale_or_missing -> nil
    end
  end

  # parado + running → attached; movimento or halted → detached.
  defp sync_mode(state) do
    case {Settings.get(:capture_mode), state.logic} do
      {"parado", %Logic{}} -> attach(state)
      {_mode, _logic} -> cancel_timer(detach(state))
    end
  end

  defp attach(%{attached?: true} = state), do: state

  defp attach(state) do
    safe(fn -> Perception.attach(:corpses) end)
    %{state | attached?: true}
  end

  defp detach(%{attached?: false} = state), do: state

  defp detach(state) do
    safe(fn -> Perception.detach(:corpses) end)
    %{state | attached?: false}
  end

  defp safe(fun) do
    fun.()
  catch
    :exit, _reason -> :ok
  end

  defp schedule_wake(state) do
    state = cancel_timer(state)

    case Logic.next_wake(state.logic, now()) do
      nil -> state
      ms -> %{state | timer: Process.send_after(self(), :wake, ms)}
    end
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | timer: nil}
  end

  defp config, do: Settings.all() |> Map.take(@config_keys)

  defp mode_state(nil, _mode), do: :idle
  defp mode_state(_logic, "movimento"), do: :manual
  defp mode_state(%Logic{state: s}, _mode), do: s

  defp snapshot(state) do
    mode = Settings.get(:capture_mode)

    %{
      state: mode_state(state.logic, mode),
      mode: mode,
      counters: (state.logic && state.logic.counters) || %Logic{}.counters,
      error: state.logic && state.logic.error
    }
  end

  defp broadcast(state),
    do: Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:catcher, snapshot(state)})

  defp now, do: System.monotonic_time(:millisecond)
end
```

NOTE: in `movimento` the logic stays `:armed` internally but the worker is detached, `snapshot.state` reports `:manual`, and the `advance/2` mode gate makes every event/kill/wake a no-op — the movimento test injects a `{:world, ...}` event directly and must see zero performs.

- [ ] **Step 4: Run tests and the full suite** — green.

- [ ] **Step 5: Commit**

```bash
git add lib/pokex/bots/catcher test/pokex/bots/catcher
git commit -m "catcher: event+poll driven worker with live capture modes"
git push
```

---

### Task 5: Wire in Catcher, delete Loot, panel modes

**Files:**
- Modify: `lib/pokex/bots/bot_supervisor.ex` (child + start_all/stop_all/status + panic + MiniGame peers)
- Modify: `lib/pokex/bots/mini_game/worker.ex` (peers map key `loot` → `catcher` — grep every `loot` reference)
- Modify: `lib/pokex/bots/combat/worker.ex` (kill payload drop + arena attach removal)
- Modify: `lib/pokex_web/live/panel_live.ex` (pill, mode selector, relearn button, counters, handlers)
- Delete: `lib/pokex/bots/loot/worker.ex`, `lib/pokex/bots/loot/logic.ex`, `test/pokex/bots/loot/`
- Modify: `lib/pokex/settings.ex` (remove dead seeds)
- Test: `test/pokex/bots/bot_supervisor_test.exs`, `test/pokex_web/live/panel_live_test.exs` (update)

This task lands as ONE commit (the tree must never reference a deleted module).

- [ ] **Step 1: Combat.** In `lib/pokex/bots/combat/worker.ex`:
  - `broadcast_kill/1` → `broadcast_kill/0` sending `{:kill}` (no payload) to `Pokex.Bots.Catcher.Worker.kill_topic()`; delete `corpse/0` and the `sync_arena`/`detach_arena`/`arena_attached?` machinery (grep `arena` in the file — combat no longer attaches it; the `:arena` FEED stays registered in Perception).
  - Update `test/pokex/bots/combat/worker_test.exs`: the kill test asserts `assert_receive {:kill}` (no payload, no arena seeding).

- [ ] **Step 2: BotSupervisor.** In `lib/pokex/bots/bot_supervisor.ex`, replace every `Loot` with `Catcher` (alias, child spec `{Catcher.Worker, name: catcher, body: body}`, `start_all`/`stop_all`/`status` parameter names, the panic `on_panic` list, the `peers` map: `%{fishing: fishing, combat: combat, catcher: catcher}`). Keep arities identical (the loot slot becomes the catcher slot; status key `:loot` → `:catcher`).

- [ ] **Step 3: MiniGame.** `grep -n "loot" lib/pokex/bots/mini_game/worker.ex` and rename every peers reference to `catcher` (the value is a worker module exposing `run/halt/status` — Catcher.Worker conforms).

- [ ] **Step 4: Panel.** In `lib/pokex_web/live/panel_live.ex`:
  - `@loot_topic "loot"` → `@catcher_topic "catcher"`; subscribe accordingly; `handle_info({:loot, snapshot}, ...)` → `{:catcher, snapshot}` assigning `:catcher`; add `handle_info({:catcher_log, level, text}, ...)` appending with source `"🎯"`.
  - Mount assigns: `loot: status.loot` → `catcher: status.catcher`; add `capture_mode: Settings.get(:capture_mode)`.
  - The loot pill (`data-testid=loot-pill`) becomes `data-testid=catcher-pill` reading `@catcher.state` (labels: `:idle` → "parado", `:armed` → "capturando", `:manual` → "manual", catch-all `to_string`); its counter shows `@catcher.counters.captures`.
  - Remove the "Pegar loot" automation row (`toggle_loot` event and `automation_count`'s loot slot — the row list drops to 5: fishing, combat, capture-parado, rescue, potion; capture counts as ON when `@capture_mode == "parado"`; update the "X/5 on" literal and its test).
  - Replace the "Auto-captura" row with a "Captura (Pokébola)" row containing a two-button mode selector (follow the file's existing button idiom):

```elixir
  def handle_event("set_capture_mode", %{"mode" => mode}, socket) when mode in ~w(parado movimento) do
    Settings.put(:capture_mode, mode)
    Catcher.Worker.mode_changed()
    {:noreply, assign(socket, capture_mode: mode)}
  end

  def handle_event("relearn_ground", _params, socket) do
    Catcher.Worker.relearn()
    {:noreply, socket}
  end
```

```heex
              <div class="flex items-center justify-between px-3 py-2.5">
                <span>
                  <span class="block text-xs font-semibold">Captura (Pokébola)</span>
                  <span class="mt-0.5 block text-[10px] text-[#79838b]">
                    {if @capture_mode == "parado",
                      do: "joga bola nos corpos detectados ao redor",
                      else: "você captura manualmente — em movimento o bot não joga Pokébola"}
                  </span>
                </span>
                <div class="flex gap-1">
                  <button
                    :for={{mode, label} <- [{"parado", "Parado"}, {"movimento", "Em movimento"}]}
                    phx-click="set_capture_mode"
                    phx-value-mode={mode}
                    class={[
                      "h-8 rounded-lg border px-2.5 text-[11px]",
                      if(@capture_mode == mode,
                        do: "border-[#237d4d] bg-[#0d3822] text-[#3de083]",
                        else: "border-[#293238] text-[#89939a] hover:text-white"
                      )
                    ]}
                  >{label}</button>
                </div>
              </div>
              <button
                :if={@capture_mode == "parado"}
                phx-click="relearn_ground"
                class="mx-3 mb-2 flex h-8 items-center gap-1.5 rounded-lg border border-[#293238] px-3 font-mono text-[10px] text-[#89939a] hover:text-white"
              >
                <.icon name="hero-arrow-path" class="size-3" /> Reaprender chão (mudou de spot)
              </button>
```

  - Grep the file for remaining `loot`/`auto_capture`/`Loot` references (e.g. `merged_counters`, `overall_active?`, `automation_count`, the status pill markup, `toggle_capture`) and convert or delete each — `Settings.get(:auto_capture)` must have zero call sites when done.
  - Add the alias: `alias Pokex.Bots.{..., Catcher, ...}` (drop `Loot`).

- [ ] **Step 5: Delete Loot.** `git rm -r lib/pokex/bots/loot test/pokex/bots/loot`. Then remove the now-dead seeds from `lib/pokex/settings.ex`: `auto_capture`, `walk_step_ms`, `wait_loot_ms`, `wait_after_capture_ms`, `corpse_max_age_ms` — but FIRST `grep -rn` each in `lib/ test/`; only remove seeds with zero remaining readers (e.g. if diagnostics or fishing reads one, leave it and note it in the commit message).

- [ ] **Step 6: Update tests.** `test/pokex/bots/bot_supervisor_test.exs` (loot slot → catcher), `test/pokex_web/live/panel_live_test.exs`: the loot-broadcast test becomes a catcher-broadcast test:

```elixir
  test "a catcher broadcast updates the catcher pill", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")

    snapshot = %{state: :armed, mode: "parado", counters: %{captures: 2, throws: 3, ignored: 0}, error: nil}
    Phoenix.PubSub.broadcast(Pokex.PubSub, "catcher", {:catcher, snapshot})

    assert render(view) =~ "capturando"
    assert has_element?(view, "[data-testid=catcher-pill][data-state=armed]")
  end

  test "capture mode selector persists and shows the manual hint", %{conn: conn} do
    mode = Pokex.Settings.get(:capture_mode)
    on_exit(fn -> Pokex.Settings.put(:capture_mode, mode) end)

    {:ok, view, _} = live(conn, ~p"/")

    view |> element(~s(button[phx-value-mode="movimento"])) |> render_click()
    assert Pokex.Settings.get(:capture_mode) == "movimento"
    assert render(view) =~ "você captura manualmente"

    view |> element(~s(button[phx-value-mode="parado"])) |> render_click()
    assert render(view) =~ "Reaprender chão"
  end
```

Also update any test asserting the old "X/6 on" automations count or the "Pegar loot" row, and the "busy placeholder" panel test (it broadcasts on the "loot" topic — switch that line to "catcher" with the catcher snapshot shape `%{state: :ocupado, mode: "parado", counters: %{}, error: _}`; verify the pill renders "ocupado" via its catch-all).

- [ ] **Step 7: Full suite + greps**

Run: `mix test` — green. Then `grep -rn "Loot\|auto_capture\|walking_to_loot" lib/ test/` — zero hits (except possibly a seed intentionally kept per Step 5's grep rule).

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "catcher: replace the walk-to-corpse Loot with detected-corpse capture

Loot.Worker/Logic (walk, space-loot, walk-back) deleted; combat drops the
kill payload and its :arena attachment; panel gains the Captura (Pokébola)
parado/movimento selector + Reaprender chão; BotSupervisor/MiniGame peers
rewired to the Catcher."
git push
```

---

### Task 6: Whole-feature verification + docs

**Files:** verify everything; touch docs.

- [ ] **Step 1:** `mix test` green; `mix compile --warnings-as-errors` clean.
- [ ] **Step 2:** Greps return clean: `grep -rn "Loot\|auto_capture" lib/` (zero or documented exceptions); `grep -rn "kill_topic\|{:kill" lib/` shows only the Catcher subscription + combat broadcast of `{:kill}`.
- [ ] **Step 3:** README/moduledoc touch-up: grep `loot`/`walk` in README.md and update the capture description to the parado/movimento model.
- [ ] **Step 4:** Commit `docs: capture flow docs reflect corpse detection` + push.
- [ ] **Step 5:** Report the manual validation checklist (Portuguese) to Lucas:
  1. `git pull` + reinicia; chão LIMPO ao redor antes de Iniciar (o baseline nasce no start).
  2. Pescar parado; matar 2-3 seguidos → ver "🎯 capturado em x,y" um a um e o contador subir.
  3. Deixar o pet parado por perto → no máximo 2 bolas nele, depois "não é corpo; ignorando" (avisar se bola em pokémon vivo próprio causa problema no jogo).
  4. Trocar pra "Em movimento" ao vivo → aviso de captura manual, zero bolas automáticas; voltar pra "Parado" → re-aprende o chão.
  5. Mudar de spot → "Reaprender chão" → capturas funcionam no novo lugar.

---

## Self-review notes (already applied)

- Spec coverage: warmup/mask/stationary (Task 2), queue/confirm/retry/ignore + confirm-window (Task 3), modes live-switch + relearn + kill-accelerator + poll-progress (Task 4), deletions/panel/peers (Task 5). The spec's "Reaprender chão button forces detach+attach" is `Worker.relearn/1` + the panel button.
- The `{:kill}` shape migrates safely: Task 4's Catcher tolerates both shapes; Task 5 flips combat and deletes Loot in the same commit.
- Type consistency: `obs.corpses :: [{x, y}]` screen points everywhere; `Logic.step(logic, obs | nil, now)`; snapshot `state :: :idle | :armed | :manual`.
