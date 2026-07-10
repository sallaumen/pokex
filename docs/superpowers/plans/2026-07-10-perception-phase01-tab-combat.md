# Perception Phase 0+1: Measurement + Blackboard Core + Tab Combat — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship capture-latency measurement in the panel, the Perception blackboard core (WorldState ETS + demand-driven Feeds for `:battle`/`:arena`), and a keyboard-only Tab-targeting Combat worker consuming it.

**Architecture:** Sensing moves out of the combat worker into `Pokex.Perception` feeds that capture on their own cadence, write timestamped observations into a public ETS table, and broadcast PubSub events on change. Combat becomes a pure event-driven Tab state machine (`hunting → tabbing → fighting`) that never touches the mouse or the Body. Spec: `docs/superpowers/specs/2026-07-10-perception-blackboard-tab-combat-design.md` (phases 2-3 — remaining sensor migration, event holds, `/world` page — are separate follow-up plans).

**Tech Stack:** Elixir 1.19 / OTP 27, Phoenix LiveView, ExUnit. No new deps.

## Global Constraints

- ALL tunable values live in `@seed_settings` in `lib/pokex/settings.ex` — call sites read via `Settings.get/1` (process) or `Settings.value/2` (pure, takes the settings map). NEVER `settings[:x] || literal`.
- Portuguese for user-facing copy (logs shown in the panel, labels); English for code, comments, commit messages.
- Commit AND `git push` to `main` after every task (multiple AI sessions share this tree; repo github.com/sallaumen/pokex is private).
- Repo root: `/Users/tavano/projects/pokex`. Run tests with `mix test` from there. The full suite must stay green after every task (`mix test` — 299 tests before this plan).
- Do NOT run `mix assets.build` or `mix phx.server`; only `mix test` / `mix compile` implicitly via test.
- Tests that touch the global `Pokex.Settings` process or `Pokex.Rig.Fake` must be `async: false` and restore settings in `on_exit`.
- ETS table is named `:pokex_world`; PubSub topic is `"world"`; event shape is `{:world, key, obs}` where `obs` always contains `:captured_at` (monotonic ms).
- Existing test helpers: `Pokex.Rig.Fake.start_link(%{capture: [{:ok, png_path}]})` scripts capture returns (a 1-element list repeats forever); `Pokex.PngFixtures.write!(path, rows)` builds PNGs from `[[{r,g,b,a}]]` rows; `@tag :tmp_dir` + `Application.put_env(:pokex, :home_dir, tmp)` isolates calibration/settings files.
- Body priorities and the GameController survival combo are OUT of scope — do not touch `body.ex` or `game_controller/*`.

---

### Task 1: Perf snapshot API (queryable window stats)

`Pokex.Bots.Perf` aggregates timings but throws them away at each 5s flush (logs only). The panel needs to QUERY them. Keep the flush logging; additionally retain the flushed window and expose `snapshot/1`.

**Files:**
- Modify: `lib/pokex/bots/perf.ex`
- Test: `test/pokex/bots/perf_test.exs` (create if absent; if it exists, append the describe block)

**Interfaces:**
- Produces: `Perf.snapshot(server \\ __MODULE__)` → `%{current: stats, last_window: stats, window_ms: non_neg_integer}` where `stats` is `%{key_string => %{count: n, total: ms, max: ms}}`. Task 2 consumes this.

- [ ] **Step 1: Write the failing test**

```elixir
# test/pokex/bots/perf_test.exs
defmodule Pokex.Bots.PerfTest do
  use ExUnit.Case, async: true

  alias Pokex.Bots.Perf

  test "snapshot exposes the current window and the last flushed window" do
    {:ok, perf} = Perf.start_link(name: nil, interval_ms: 60_000)

    Perf.record("capture.backend.sck:battle.png", 42, perf)
    Perf.record("capture.backend.sck:battle.png", 58, perf)
    Perf.count("capture.backend.sck_retry:battle.png", perf)

    snap = Perf.snapshot(perf)
    assert snap.window_ms == 60_000
    assert snap.last_window == %{}
    assert %{count: 2, total: 100, max: 58} = snap.current["capture.backend.sck:battle.png"]
    assert %{count: 1} = snap.current["capture.backend.sck_retry:battle.png"]

    # a flush moves current -> last_window and clears current
    send(perf, :flush)
    snap = Perf.snapshot(perf)
    assert %{count: 2, max: 58} = snap.last_window["capture.backend.sck:battle.png"]
    assert snap.current == %{}
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/pokex/bots/perf_test.exs`
Expected: FAIL — `Perf.snapshot/1` is undefined (and `record/3` exists, so only snapshot fails).

- [ ] **Step 3: Implement**

In `lib/pokex/bots/perf.ex`:

Add below `count/2`:

```elixir
  @doc "Current-window and last-flushed-window stats, for the panel's capture metrics."
  def snapshot(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil -> %{current: %{}, last_window: %{}, window_ms: 0}
      _pid -> GenServer.call(server, :snapshot)
    end
  end
```

In `init/1`, change the state line to carry the last window:

```elixir
    state = %{interval_ms: interval, stats: %{}, last_window: %{}}
```

Add a `handle_call` (place above `handle_info`):

```elixir
  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply,
     %{current: state.stats, last_window: state.last_window, window_ms: state.interval_ms},
     state}
  end
```

In `handle_info(:flush, ...)`, change the final line from `{:noreply, %{state | stats: %{}}}` to:

```elixir
    {:noreply, %{state | stats: %{}, last_window: stats}}
```

- [ ] **Step 4: Run the test and the full suite**

Run: `mix test test/pokex/bots/perf_test.exs && mix test`
Expected: PASS, suite green.

- [ ] **Step 5: Commit**

```bash
git add lib/pokex/bots/perf.ex test/pokex/bots/perf_test.exs
git commit -m "perf: queryable snapshot of current + last flushed window"
git push
```

---

### Task 2: Capture backend info + panel "Captura" metrics block (Phase 0 deliverable)

Surface WHICH capture backend is live (ScreenCaptureKit vs `screencapture` CLI fallback) and the capture timings from Task 1 in the panel's "Avançado & calibragem" section, behind an on-demand button (no periodic re-render churn).

**Files:**
- Modify: `lib/pokex/bots/capture.ex` (add `backend_info/1`)
- Modify: `lib/pokex_web/live/panel_live.ex` (new block inside the `#advanced-panel` `<details>`, after the "Cooldowns das skills" section)
- Test: `test/pokex/bots/capture_test.exs` (append), `test/pokex_web/live/panel_live_test.exs` (append)

**Interfaces:**
- Consumes: `Perf.snapshot/0` from Task 1.
- Produces: `Capture.backend_info(server \\ __MODULE__)` → `%{backend: :screen_capture_kit | :rig, recovering?: boolean}`.

- [ ] **Step 1: Write the failing capture test**

Append to `test/pokex/bots/capture_test.exs` (inside the top-level module; match the file's existing setup style — if its tests start their own Capture instance, do the same):

```elixir
  test "backend_info reports the live backend and recovery flag" do
    {:ok, server} = Pokex.Bots.Capture.start_link(name: nil, backend: :rig)
    assert %{backend: :rig, recovering?: false} = Pokex.Bots.Capture.backend_info(server)
  end
```

NOTE for the implementer: open `test/pokex/bots/capture_test.exs` first and copy how existing tests start an isolated Capture (`name: nil` + whatever backend option the file already uses — if `start_link(name: nil, backend: :rig)` is not an existing pattern, check `capture.ex`'s `start_link`/`init` for the option that forces the `:rig` backend and use that; `config/test.exs` may already force it app-wide).

- [ ] **Step 2: Run it, verify failure**

Run: `mix test test/pokex/bots/capture_test.exs`
Expected: FAIL — `backend_info/1` undefined.

- [ ] **Step 3: Implement backend_info in `lib/pokex/bots/capture.ex`**

Public API, next to `grab/3`:

```elixir
  @doc "Which capture backend is live right now (panel diagnostics)."
  def backend_info(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil -> %{backend: :rig, recovering?: false}
      _pid -> GenServer.call(server, :backend_info)
    end
  end
```

Handler (next to the other `handle_call`s):

```elixir
  @impl true
  def handle_call(:backend_info, _from, state) do
    backend =
      case state.backend do
        {:screen_capture_kit, _b} -> :screen_capture_kit
        _other -> :rig
      end

    {:reply, %{backend: backend, recovering?: state.recovering?}, state}
  end
```

(If `state` has no `recovering?` key, grep `capture.ex` for the field the SCK recovery path sets — the agent-audit found `recovering?: false` set at the recovery site — and use that exact field.)

- [ ] **Step 4: Panel block**

In `lib/pokex_web/live/panel_live.ex`:

Mount assigns (add to the big `assign` in `mount`):

```elixir
       capture_info: nil,
```

Event handler (next to `read_cooldowns`):

```elixir
  # On-demand capture diagnostics: backend + last-window timings. A button, not a timer —
  # metrics are for humans debugging, they must not add render churn to the hot panel.
  def handle_event("read_capture_stats", _params, socket) do
    snapshot = Pokex.Bots.Perf.snapshot()

    window =
      if map_size(snapshot.last_window) > 0, do: snapshot.last_window, else: snapshot.current

    stats =
      window
      |> Enum.filter(fn {key, _v} -> String.starts_with?(key, "capture.backend.") end)
      |> Enum.sort_by(fn {key, _v} -> key end)

    info = %{backend: Pokex.Bots.Capture.backend_info(), stats: stats}
    {:noreply, assign(socket, capture_info: info)}
  end
```

Render block — inside the `#advanced-panel` `<details>`, right after the closing `</section>` of "Cooldowns das skills":

```heex
              <section class="border-t border-[#232b30] pt-4">
                <div class="flex items-center justify-between">
                  <h3 class="text-xs font-semibold">Captura de tela</h3><button
                    class="flex h-8 items-center gap-1.5 rounded-lg border border-[#293238] px-3 font-mono text-[10px] text-[#89939a] hover:text-white"
                    phx-click="read_capture_stats"
                  ><.icon name="hero-arrow-path" class="size-3" /> Medir</button>
                </div>
                <div :if={@capture_info} class="mt-2 space-y-1 font-mono text-[10px]">
                  <p class="text-[#9aa3aa]">
                    backend:
                    <span class={
                      if @capture_info.backend.backend == :screen_capture_kit,
                        do: "text-[#3de083]",
                        else: "text-[#e0b43d]"
                    }>
                      {if @capture_info.backend.backend == :screen_capture_kit,
                        do: "ScreenCaptureKit (rápido)",
                        else: "screencapture CLI (lento — fallback)"}
                    </span>
                    <span :if={@capture_info.backend.recovering?} class="text-[#79838b]">
                      · tentando recuperar o SCK…
                    </span>
                  </p>
                  <p :if={@capture_info.stats == []} class="text-[#69737b]">
                    sem capturas na última janela — ligue um bot e clique Medir de novo
                  </p>
                  <p :for={{key, stat} <- @capture_info.stats} class="text-[#79838b]">
                    {String.replace_prefix(key, "capture.backend.", "")} · n={stat.count}
                    <span :if={stat.total > 0}>
                      avg={Float.round(stat.total / stat.count, 1)}ms max={stat.max}ms
                    </span>
                  </p>
                </div>
              </section>
```

- [ ] **Step 5: Panel test**

Append to `test/pokex_web/live/panel_live_test.exs`:

```elixir
  test "capture metrics block reports the backend on demand", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")

    html = view |> element(~s(button[phx-click="read_capture_stats"])) |> render_click()
    assert html =~ "backend:"
    assert html =~ "screencapture CLI" or html =~ "ScreenCaptureKit"
  end
```

- [ ] **Step 6: Run and commit**

Run: `mix test test/pokex/bots/capture_test.exs test/pokex_web/live/panel_live_test.exs && mix test`
Expected: PASS, suite green.

```bash
git add lib/pokex/bots/capture.ex lib/pokex_web/live/panel_live.ex test/pokex/bots/capture_test.exs test/pokex_web/live/panel_live_test.exs
git commit -m "capture: expose live backend + panel capture metrics (phase 0)"
git push
```

---

### Task 3: Perception.WorldState (ETS + freshness API)

**Files:**
- Create: `lib/pokex/perception/world_state.ex`
- Test: `test/pokex/perception/world_state_test.exs`

**Interfaces:**
- Produces (Tasks 4-7 consume):
  - `WorldState.start_link(opts)` — GenServer owning named public ETS `:pokex_world`.
  - `WorldState.put(key, obs, at_ms)` → `:ok` (direct `:ets.insert`, callable from any process).
  - `WorldState.get(key, max_age_ms, now_ms)` → `{:ok, obs}` | `{:stale, obs, age_ms}` | `:missing`.
  - `WorldState.entries()` → `[{key, obs, at_ms}]` (for the future `/world` page and tests).

- [ ] **Step 1: Write the failing test**

```elixir
# test/pokex/perception/world_state_test.exs
defmodule Pokex.Perception.WorldStateTest do
  # async: false — the ETS table is a named global; tests share it with the app instance.
  use ExUnit.Case, async: false

  alias Pokex.Perception.WorldState

  setup do
    on_exit(fn -> :ets.delete(:pokex_world, :test_key) end)
    :ok
  end

  test "get is :missing before any put" do
    assert WorldState.get(:test_key, 500, 1_000) == :missing
  end

  test "a fresh entry is {:ok, obs}; an old one is {:stale, obs, age}" do
    obs = %{enemies: [0], captured_at: 1_000}
    WorldState.put(:test_key, obs, 1_000)

    assert WorldState.get(:test_key, 500, 1_400) == {:ok, obs}
    assert WorldState.get(:test_key, 500, 1_501) == {:stale, obs, 501}
  end

  test "entries lists what the world knows" do
    WorldState.put(:test_key, %{a: 1}, 42)
    assert {:test_key, %{a: 1}, 42} in WorldState.entries()
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/pokex/perception/world_state_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Implement**

```elixir
# lib/pokex/perception/world_state.ex
defmodule Pokex.Perception.WorldState do
  @moduledoc """
  The shared blackboard: one named public ETS table holding the latest interpreted
  observation per perception key, with the monotonic capture timestamp. Feeds write; anyone
  reads lock-free. Consumers MUST go through `get/3` and treat `:stale`/`:missing` as
  "unknown" — the fail-safe choice (hold, don't act) is the caller's job, the staleness
  math is ours.

  The GenServer exists only to own the table (so it survives caller crashes and dies with
  the supervision tree); reads and writes never touch the process.
  """
  use GenServer

  @table :pokex_world

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  @doc "Record the latest observation for `key`, stamped with its capture time."
  def put(key, obs, at_ms) do
    :ets.insert(@table, {key, obs, at_ms})
    :ok
  end

  @doc "The freshest observation for `key`, age-checked against `max_age_ms`."
  def get(key, max_age_ms, now_ms) do
    case :ets.lookup(@table, key) do
      [{^key, obs, at}] ->
        age = now_ms - at
        if age <= max_age_ms, do: {:ok, obs}, else: {:stale, obs, age}

      [] ->
        :missing
    end
  end

  @doc "Everything the world currently knows — the /world page's data source."
  def entries, do: :ets.tab2list(@table)
end
```

- [ ] **Step 4: Wire into the application** so the table exists app-wide. In `lib/pokex/application.ex`, add to the children list AFTER the `Capture` child and BEFORE `BotSupervisor`:

```elixir
      Pokex.Perception.WorldState,
```

(Task 4 replaces this line with the full Perception supervisor — the direct child is just to keep every task independently green.)

- [ ] **Step 5: Run and commit**

Run: `mix test test/pokex/perception/world_state_test.exs && mix test`
Expected: PASS, suite green.

```bash
git add lib/pokex/perception/world_state.ex lib/pokex/application.ex test/pokex/perception/world_state_test.exs
git commit -m "perception: WorldState ETS blackboard with freshness-gated reads"
git push
```

---

### Task 4: Perception.Feed (generic, demand-driven) + Perception supervisor

**Files:**
- Create: `lib/pokex/perception/feed.ex`
- Create: `lib/pokex/perception.ex` (supervisor + attach/detach API + feed registry)
- Modify: `lib/pokex/application.ex` (swap the WorldState child for the Perception supervisor)
- Test: `test/pokex/perception/feed_test.exs`

**Interfaces:**
- Consumes: `WorldState.put/3` (Task 3), `Pokex.Bots.Capture.frame/2`, `Pokex.Calibration.load/0`, `Pokex.Settings.all/0`.
- Produces (Tasks 5-7 consume):
  - `Perception.attach(key)` / `Perception.detach(key)` — register/unregister the CALLING process as a consumer of that feed (monitored; a dead consumer auto-detaches).
  - Feed spec shape: `%{key: atom, region: (Calibration.t() -> region_tuple), interval_setting: atom, filename: String.t(), interpret: (Frame.t(), Calibration.t(), settings_map -> map)}`.
  - Broadcast: `Phoenix.PubSub.broadcast(Pokex.PubSub, "world", {:world, key, obs})` — only when the observation CHANGED; `obs` always includes `:captured_at`.
  - `Pokex.Perception.topic()` → `"world"`.

- [ ] **Step 1: Write the failing test**

```elixir
# test/pokex/perception/feed_test.exs
defmodule Pokex.Perception.FeedTest do
  use ExUnit.Case, async: false

  alias Pokex.Perception.{Feed, WorldState}

  # A tiny deterministic spec: region is fixed, the interpreter reports the frame width so
  # different scripted PNGs produce different observations.
  defp spec do
    %{
      key: :feed_test,
      region: fn _calib -> {0, 0, 10, 10} end,
      interval_setting: :feed_battle_ms,
      filename: "feed_test.png",
      interpret: fn frame, _calib, _settings -> %{width: frame.width} end
    }
  end

  defp png!(dir, name, w) do
    rows = for _ <- 1..4, do: List.duplicate({9, 9, 9, 255}, w)
    Pokex.PngFixtures.write!(Path.join(dir, name), rows)
  end

  defp save_calibration do
    Pokex.Calibration.save(%Pokex.Calibration{
      scale: 1.0,
      screen_w: 100,
      screen_h: 75,
      water_point: {50, 30},
      glow_region: {0, 0, 20, 20},
      battle_region: {0, 0, 20, 20},
      arena_region: {0, 0, 60, 40},
      neutral_point: {52, 36}
    })
  end

  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn ->
      Application.delete_env(:pokex, :home_dir)
      :ets.delete(:pokex_world, :feed_test)
    end)

    save_calibration()
    :ok
  end

  @tag :tmp_dir
  test "captures only while attached, writes the world, broadcasts on change only",
       %{tmp_dir: tmp} do
    a = png!(tmp, "a.png", 8)
    b = png!(tmp, "b.png", 12)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, a}, {:ok, a}, {:ok, b}]})

    Phoenix.PubSub.subscribe(Pokex.PubSub, "world")
    {:ok, feed} = Feed.start_link(spec: spec(), name: nil)

    # detached → no captures, no world entry
    refute_receive {:world, :feed_test, _}, 150
    assert WorldState.get(:feed_test, 60_000, now()) == :missing

    :ok = Feed.attach(feed)

    # first observation (width 8) lands and broadcasts
    assert_receive {:world, :feed_test, %{width: 8, captured_at: _}}, 1_000
    assert {:ok, %{width: 8}} = WorldState.get(:feed_test, 60_000, now())

    # second capture repeats width 8 → NO new broadcast; third (width 12) → broadcast
    assert_receive {:world, :feed_test, %{width: 12}}, 1_000
    refute_received {:world, :feed_test, %{width: 8}}

    # detach pauses the feed: no more broadcasts
    :ok = Feed.detach(feed)
    refute_receive {:world, :feed_test, _}, 300
  end

  @tag :tmp_dir
  test "a capture error keeps the last good entry and does not crash", %{tmp_dir: tmp} do
    a = png!(tmp, "a.png", 8)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, a}, {:error, :boom}]})

    {:ok, feed} = Feed.start_link(spec: spec(), name: nil)
    :ok = Feed.attach(feed)

    Phoenix.PubSub.subscribe(Pokex.PubSub, "world")
    assert_receive {:world, :feed_test, %{width: 8}}, 1_000

    # the error tick keeps the entry and the process alive
    Process.sleep(300)
    assert Process.alive?(feed)
    assert {:ok, %{width: 8}} = WorldState.get(:feed_test, 60_000, now())
  end

  defp now, do: System.monotonic_time(:millisecond)
end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/pokex/perception/feed_test.exs`
Expected: FAIL — `Pokex.Perception.Feed` undefined.

- [ ] **Step 3: Implement the Feed**

```elixir
# lib/pokex/perception/feed.ex
defmodule Pokex.Perception.Feed do
  @moduledoc """
  One perception stream: capture its region on its cadence, interpret the frame with a pure
  function, write the observation into the WorldState, and broadcast on the "world" topic
  when the observation CHANGED.

  DEMAND-DRIVEN: the feed only captures while at least one consumer is attached — otherwise
  the blackboard would RAISE broker load instead of lowering it. Consumers are monitored, so
  a crashed consumer can never leave a feed running for nobody.

  Uncrashable on I/O: a failed capture/interpret keeps the last good entry (the staleness
  gate in WorldState.get protects readers) and the loop keeps ticking. Calibration is
  re-read on every capture so recalibrating applies live, and a missing calibration just
  counts as a failed tick.
  """
  use GenServer
  require Logger

  alias Pokex.Bots.Capture
  alias Pokex.Perception.WorldState
  alias Pokex.{Calibration, Settings}

  @topic "world"

  def topic, do: @topic

  def start_link(opts) do
    spec = Keyword.fetch!(opts, :spec)

    case Keyword.get(opts, :name, :default) do
      nil -> GenServer.start_link(__MODULE__, spec)
      :default -> GenServer.start_link(__MODULE__, spec, name: name(spec.key))
      name -> GenServer.start_link(__MODULE__, spec, name: name)
    end
  end

  def name(key), do: :"#{__MODULE__}.#{key}"

  def attach(server, consumer \\ self()), do: GenServer.call(server, {:attach, consumer})
  def detach(server, consumer \\ self()), do: GenServer.call(server, {:detach, consumer})

  @impl true
  def init(spec) do
    {:ok,
     %{spec: spec, consumers: %{}, timer: nil, last_obs: nil, failures: 0}}
  end

  @impl true
  def handle_call({:attach, pid}, _from, state) do
    state =
      if Map.has_key?(state.consumers, pid) do
        state
      else
        ref = Process.monitor(pid)
        was_idle? = state.consumers == %{}
        state = %{state | consumers: Map.put(state.consumers, pid, ref)}
        if was_idle?, do: reschedule(state, 0), else: state
      end

    {:reply, :ok, state}
  end

  def handle_call({:detach, pid}, _from, state), do: {:reply, :ok, drop_consumer(state, pid)}

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state),
    do: {:noreply, drop_consumer(state, pid)}

  def handle_info(:tick, %{consumers: consumers} = state) when consumers == %{},
    do: {:noreply, %{state | timer: nil}}

  def handle_info(:tick, state) do
    state = state |> observe() |> reschedule(Settings.get(state.spec.interval_setting))
    {:noreply, state}
  end

  defp observe(state) do
    with {:ok, calib} <- Calibration.load(),
         region = state.spec.region.(calib),
         {:ok, frame} <- Capture.frame(region, state.spec.filename) do
      at = now()

      obs =
        frame
        |> state.spec.interpret.(calib, Settings.all())
        |> Map.put(:captured_at, at)

      WorldState.put(state.spec.key, obs, at)

      if changed?(state.last_obs, obs),
        do: Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:world, state.spec.key, obs})

      %{state | last_obs: obs}
    else
      error ->
        Logger.debug("feed #{state.spec.key} tick failed: #{inspect(error)}")
        %{state | failures: state.failures + 1}
    end
  catch
    kind, reason ->
      Logger.debug("feed #{state.spec.key} crashed a tick: #{inspect({kind, reason})}")
      %{state | failures: state.failures + 1}
  end

  # Same content, different timestamp → not a change. Everything else → broadcast.
  defp changed?(nil, _obs), do: true

  defp changed?(last, obs),
    do: Map.delete(last, :captured_at) != Map.delete(obs, :captured_at)

  defp drop_consumer(state, pid) do
    case Map.pop(state.consumers, pid) do
      {nil, _} -> state
      {ref, consumers} ->
        Process.demonitor(ref, [:flush])
        %{state | consumers: consumers}
    end
  end

  defp reschedule(state, delay_ms) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :tick, max(delay_ms || 100, 10))}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
```

- [ ] **Step 4: Implement the Perception supervisor + API**

```elixir
# lib/pokex/perception.ex
defmodule Pokex.Perception do
  @moduledoc """
  The perception subsystem: the WorldState blackboard plus one demand-driven Feed per
  screen region (spec: docs/superpowers/specs/2026-07-10-perception-blackboard-tab-combat-design.md).
  Workers attach to the feeds they need and read observations from the WorldState / the
  "world" PubSub topic — no worker takes its own screenshots.
  """
  use Supervisor

  alias Pokex.Perception.{Feed, Interpret}

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children =
      [Pokex.Perception.WorldState] ++
        Enum.map(feed_specs(), fn spec ->
          Supervisor.child_spec({Feed, spec: spec}, id: Feed.name(spec.key))
        end)

    Supervisor.init(children, strategy: :one_for_one)
  end

  def topic, do: Feed.topic()

  @doc "Attach the calling process as a consumer of `key` (starts its captures if first)."
  def attach(key), do: Feed.attach(Feed.name(key))

  @doc "Detach the calling process from `key` (pauses the feed if it was the last)."
  def detach(key), do: Feed.detach(Feed.name(key))

  # Feed inventory. Task 5 fills in the :battle and :arena interpreters; later phases add
  # :glow, :pokemon_hp, :mini_game and :skill_bar here.
  def feed_specs do
    [
      %{
        key: :battle,
        region: fn calib -> calib.battle_region end,
        interval_setting: :feed_battle_ms,
        filename: "feed_battle.png",
        interpret: &Interpret.battle/3
      },
      %{
        key: :arena,
        region: fn calib -> calib.arena_region end,
        interval_setting: :feed_arena_ms,
        filename: "feed_arena.png",
        interpret: &Interpret.arena/3
      }
    ]
  end
end
```

NOTE: this module references `Interpret`, created in Task 5. To keep THIS task green on its own, create the stub now (Task 5 replaces it via TDD):

```elixir
# lib/pokex/perception/interpret.ex
defmodule Pokex.Perception.Interpret do
  @moduledoc "Pure frame → observation interpreters, one per feed. See Task 5."

  def battle(_frame, _calib, _settings), do: %{enemies: [], red: [], locked?: false, locked_row: nil}
  def arena(_frame, _calib, _settings), do: %{hostile: nil}
end
```

- [ ] **Step 5: Settings seeds for the feed cadences**

In `lib/pokex/settings.ex`, append to `@seed_settings` (after the potion block):

```elixir
    # --- Perception feeds -----------------------------------------------------------------------
    # Capture cadence per feed. A feed only captures while a consumer is attached, so these are
    # upper bounds on broker demand, not constant costs. battle is the combat hot path; arena only
    # runs while fighting (corpse position for loot).
    feed_battle_ms: 120,
    feed_arena_ms: 300,
```

- [ ] **Step 6: Swap the application child.** In `lib/pokex/application.ex`, replace the `Pokex.Perception.WorldState,` line (Task 3) with:

```elixir
      Pokex.Perception,
```

- [ ] **Step 7: Run and commit**

Run: `mix test test/pokex/perception/feed_test.exs && mix test`
Expected: PASS, suite green (the app-wide feeds are dormant — nobody attaches yet).

```bash
git add lib/pokex/perception.ex lib/pokex/perception/feed.ex lib/pokex/perception/interpret.ex lib/pokex/settings.ex lib/pokex/application.ex test/pokex/perception/feed_test.exs
git commit -m "perception: demand-driven Feed + supervisor with battle/arena specs"
git push
```

---

### Task 5: Battle + arena interpreters

Port the sensing math out of `Pokex.Bots.Fisher.Sensors.Real.battle_view/2` and `fetch(:hostile, ...)` into pure functions of `(frame, calib, settings)`. Do NOT modify `sensors/real.ex` — fishing still uses it; the combat entries there become dead code removed in phase 2.

**Files:**
- Modify: `lib/pokex/perception/interpret.ex` (replace the Task-4 stub)
- Test: `test/pokex/perception/interpret_test.exs`

**Interfaces:**
- Consumes: `Pokex.Vision` (`hp_bar_row_positions/1`, `pokeball_row_positions/2`, `red_row_counts/2`, `locked_row/2`, `find_hostile/1`), `Pokex.Calibration` (`row_band_geometry/2`, `strip_width/0`, `frame_to_screen/3`), `Pokex.Frame.crop/2`, `Pokex.Settings.value/2`.
- Produces:
  - `Interpret.battle(frame, calib, settings)` → `%{enemies: [row], red: [px_per_row], locked?: boolean, locked_row: non_neg_integer | nil}`
  - `Interpret.arena(frame, calib, settings)` → `%{hostile: {x, y} | nil}` (screen points).

- [ ] **Step 1: Study the source math.** Read `lib/pokex/bots/fisher/sensors/real.ex` lines 60-136 (`battle_view/2`, `fetch(:hostile, ...)`, `rows_of/4`, `row_index/4`) — the interpreters are that code minus the capture, plus the lock verdict.

- [ ] **Step 2: Write the failing test**

```elixir
# test/pokex/perception/interpret_test.exs
defmodule Pokex.Perception.InterpretTest do
  use ExUnit.Case, async: false

  alias Pokex.Perception.Interpret
  alias Pokex.{Calibration, Frame, Settings}

  # battle_region 80x400 at scale 1.0; strip_width points cover the pokeball column.
  defp calib do
    %Calibration{
      scale: 1.0,
      screen_w: 1000,
      screen_h: 700,
      water_point: {1, 1},
      glow_region: {0, 0, 8, 8},
      battle_region: {0, 0, 80, 400},
      arena_region: {100, 100, 60, 40},
      neutral_point: {500, 500}
    }
  end

  defp settings, do: Settings.all()

  # A battle frame: `w` x `h`, dark everywhere except the painter functions.
  defp frame(w, h, paint) do
    rgba =
      for y <- 0..(h - 1), x <- 0..(w - 1), into: <<>> do
        {r, g, b} = paint.(x, y)
        <<r, g, b, 255>>
      end

    %Frame{width: w, height: h, rgba: rgba}
  end

  test "an all-dark battle frame has no enemies and no lock" do
    f = frame(80, 400, fn _x, _y -> {9, 9, 9} end)
    obs = Interpret.battle(f, calib(), settings())
    assert obs.enemies == []
    assert obs.locked? == false
    assert obs.locked_row == nil
  end

  test "a dark-red band inside row 0's lock band reads as locked" do
    # row band geometry at scale 1.0: Calibration.row_band_geometry(1.0, row_height)
    {top, band} = Calibration.row_band_geometry(1.0, Settings.get(:battle_row_height))

    f =
      frame(80, 400, fn _x, y ->
        if y >= max(top, 0) and y < top + band, do: {160, 20, 20}, else: {9, 9, 9}
      end)

    obs = Interpret.battle(f, calib(), settings())
    assert obs.locked? == true
    assert obs.locked_row == 0
  end

  test "arena with no hostile name is nil" do
    f = frame(60, 40, fn _x, _y -> {9, 9, 9} end)
    assert Interpret.arena(f, calib(), settings()) == %{hostile: nil}
  end
end
```

NOTE for the implementer: if `Vision.locked_row/2`'s exact name/arity differs, grep `lib/pokex/vision.ex` for `locked_row` and use the real signature (`locked_row(counts, min_pixels)` per its `@spec`, returning `{:ok, row} | :none`).

- [ ] **Step 3: Run to verify failure**

Run: `mix test test/pokex/perception/interpret_test.exs`
Expected: FAIL — the stub returns `%{enemies: [], ...}` for the locked case (second test fails).

- [ ] **Step 4: Implement**

```elixir
# lib/pokex/perception/interpret.ex
defmodule Pokex.Perception.Interpret do
  @moduledoc """
  Pure frame → observation interpreters, one per feed. Ported from the combat half of
  `Fisher.Sensors.Real` (which stays untouched for fishing until phase 2): same slicing,
  same row-band geometry, same thresholds — the ONLY addition is the lock verdict
  (locked?/locked_row), computed here once so every consumer shares one interpretation.
  """

  alias Pokex.{Calibration, Frame, Settings, Vision}

  @doc """
  The battle panel: candidate enemy rows (HP bar, no own-pokemon pokeball), per-row
  lock-ring red counts, and whether/where the lock ring is up.
  """
  def battle(frame, calib, settings) do
    {top, band} =
      Calibration.row_band_geometry(calib.scale, Settings.value(settings, :battle_row_height))

    rows = Settings.value(settings, :battle_max_rows)
    strip_px = round(Calibration.strip_width() * calib.scale)

    body = Frame.crop(frame, {0, 0, frame.width - strip_px, frame.height})
    strip = Frame.crop(frame, {frame.width - strip_px, 0, strip_px, frame.height})

    creatures = body |> Vision.hp_bar_row_positions() |> rows_of(top, band, rows)

    own =
      strip
      |> Vision.pokeball_row_positions(min_count: Settings.value(settings, :pokeball_min_red_px))
      |> rows_of(top, band, rows)

    red = Vision.red_row_counts(body, top: top, band: band, rows: rows)

    locked_row =
      case Vision.locked_row(red, Settings.value(settings, :target_locked_min_pixels)) do
        {:ok, row} -> row
        :none -> nil
      end

    %{
      enemies: Enum.sort(creatures -- own),
      red: red,
      locked?: locked_row != nil,
      locked_row: locked_row
    }
  end

  @doc "The arena: the hostile's floating-name point in SCREEN coordinates, or nil."
  def arena(frame, calib, _settings) do
    case Vision.find_hostile(frame) do
      {:ok, pixel} -> %{hostile: Calibration.frame_to_screen(calib, calib.arena_region, pixel)}
      :not_found -> %{hostile: nil}
    end
  end

  # Bucket frame-Ys into distinct 0-based battle rows (same math as the lock sensor).
  defp rows_of(ys, top, band, rows) do
    ys
    |> Enum.map(fn y -> max(0, min(div(y - top, band), rows - 1)) end)
    |> Enum.uniq()
  end
end
```

- [ ] **Step 5: Run and commit**

Run: `mix test test/pokex/perception/interpret_test.exs && mix test`
Expected: PASS, suite green.

```bash
git add lib/pokex/perception/interpret.ex test/pokex/perception/interpret_test.exs
git commit -m "perception: battle + arena interpreters (pure, shared lock verdict)"
git push
```

---

### Task 6: Combat.Logic rewrite — the Tab state machine (pure)

Full rewrite of `lib/pokex/bots/combat/logic.ex`. Game facts (from Lucas): Tab selects the first attackable enemy; pressing again CYCLES to the next; with no enemy Tab does nothing; when the target dies the lock disappears and the next target needs a fresh Tab.

**Files:**
- Rewrite: `lib/pokex/bots/combat/logic.ex`
- Rewrite: `test/pokex/bots/combat/logic_test.exs`

**Interfaces:**
- Consumes: config map (plain atom-keyed map) with keys `tab_confirm_ms`, `tab_max_attempts`, `hunt_cooldown_ms`, `skill_burst_every_ms`, `fight_timeout_ms`, `target_lost_streak`, `skill_keys`, `combat_skill_burst_size`, `max_consecutive_failures`.
- Produces (Task 7 consumes):
  - States: `:idle | :hunting | :tabbing | :fighting | :error`.
  - `Logic.new(config)`, `Logic.start(logic, now)`, `Logic.stop(logic)`, `Logic.io_failed(logic, reason, now)`, `Logic.rescan(logic, now)` — same call shapes as today.
  - `Logic.step(logic, obs_or_nil, now)` → `{logic, actions}`; `obs` is the battle observation map (`%{enemies:, red:, locked?:, locked_row:, captured_at:}`) or `nil` (timer wake with no fresh data).
  - Actions: `{:tab}` (press the Tab key), `{:press, key}` (skill), `{:log, msg}`.
  - `Logic.next_wake(logic, now)` → ms until the next time-based deadline, or `nil` (purely event-driven).
  - Counters keep today's shape: `%{fights: 0, loots: 0, captures: 0, failures: 0}`; snapshot fields `state`, `counters`, `error`, `locked_row` (locked_row now comes from the last observation and may be nil — keep the field for panel compat).

- [ ] **Step 1: Write the failing tests (full rewrite of the test file)**

```elixir
# test/pokex/bots/combat/logic_test.exs
defmodule Pokex.Bots.Combat.LogicTest do
  use ExUnit.Case, async: true

  alias Pokex.Bots.Combat.Logic

  defp config(overrides \\ []) do
    Enum.into(overrides, %{
      tab_confirm_ms: 700,
      tab_max_attempts: 3,
      hunt_cooldown_ms: 1_500,
      skill_burst_every_ms: 300,
      fight_timeout_ms: 6_000,
      target_lost_streak: 2,
      skill_keys: ["1", "2", "3"],
      combat_skill_burst_size: 3,
      max_consecutive_failures: 5
    })
  end

  defp hunting(now \\ 0) do
    {logic, []} = Logic.start(Logic.new(config()), now)
    logic
  end

  defp obs(fields), do: Enum.into(fields, %{enemies: [], red: [], locked?: false, locked_row: nil, captured_at: 0})

  test "start enters :hunting" do
    assert %Logic{state: :hunting} = hunting()
  end

  test "hunting: enemies present → Tab, :tabbing" do
    {logic, actions} = Logic.step(hunting(0), obs(enemies: [0], captured_at: 10), 10)
    assert logic.state == :tabbing
    assert logic.tab_attempts == 1
    assert {:tab} in actions
  end

  test "hunting: empty battle or nil obs → hold, no actions" do
    assert {%Logic{state: :hunting}, []} = Logic.step(hunting(0), obs(captured_at: 10), 10)
    assert {%Logic{state: :hunting}, []} = Logic.step(hunting(0), nil, 10)
  end

  test "tabbing: a lock on a frame captured AFTER the Tab confirms and fires the first burst" do
    {logic, _} = Logic.step(hunting(0), obs(enemies: [0], captured_at: 10), 10)

    # a frame captured BEFORE the tab (stale) must NOT confirm
    {still, []} =
      Logic.step(logic, obs(locked?: true, locked_row: 0, captured_at: 5), 20)
    assert still.state == :tabbing

    {fighting, actions} =
      Logic.step(still, obs(locked?: true, locked_row: 0, captured_at: 30), 40)
    assert fighting.state == :fighting
    assert [{:press, "1"}, {:press, "2"}, {:press, "3"}] = actions
  end

  test "tabbing: window expiry re-Tabs up to max attempts, then hunt cooldown" do
    {logic, _} = Logic.step(hunting(0), obs(enemies: [0], captured_at: 10), 10)

    # 800ms later, no lock → second Tab
    {logic, actions} = Logic.step(logic, obs(enemies: [0], captured_at: 800), 811)
    assert logic.state == :tabbing and logic.tab_attempts == 2
    assert {:tab} in actions

    # exhaust the third attempt, then the next expiry sends us to hunting WITH a hold
    {logic, _} = Logic.step(logic, obs(enemies: [0], captured_at: 1_600), 1_612)
    assert logic.tab_attempts == 3
    {logic, _} = Logic.step(logic, obs(enemies: [0], captured_at: 2_400), 2_413)
    assert logic.state == :hunting
    assert logic.hold_until == 2_413 + 1_500

    # while held, enemies do NOT trigger a Tab
    assert {%Logic{state: :hunting}, []} =
             Logic.step(logic, obs(enemies: [0], captured_at: 2_500), 2_500)

    # after the hold, they do
    {logic, actions} = Logic.step(logic, obs(enemies: [0], captured_at: 4_000), 4_000)
    assert logic.state == :tabbing
    assert {:tab} in actions
  end

  test "rescan clears the hunt hold (fish hooked → enemy imminent)" do
    {logic, _} = Logic.step(hunting(0), obs(enemies: [0], captured_at: 10), 10)
    logic = %{logic | state: :hunting, hold_until: 99_999, tabbed_at: nil}
    logic = Logic.rescan(logic, 50)
    assert logic.hold_until == nil
  end

  test "fighting: bursts are throttled by skill_burst_every_ms" do
    logic = confirmed()

    # immediately after the confirm burst, another locked frame does NOT burst again
    {logic, []} = Logic.step(logic, obs(locked?: true, locked_row: 0, captured_at: 150), 150)

    # past the throttle it does, continuing the rotation (burst 2 wraps: keys 1,2,3 again)
    {_logic, actions} = Logic.step(logic, obs(locked?: true, locked_row: 0, captured_at: 460), 460)
    assert [{:press, _}, {:press, _}, {:press, _}] = actions
  end

  test "fighting: lock gone for target_lost_streak frames counts the kill and re-hunts" do
    logic = confirmed()

    {logic, []} = Logic.step(logic, obs(locked?: false, captured_at: 500), 500)
    assert logic.lost_streak == 1

    {logic, actions} = Logic.step(logic, obs(locked?: false, captured_at: 620), 620)
    assert logic.state == :hunting
    assert logic.counters.fights == 1
    assert Enum.any?(actions, &match?({:log, _}, &1))
  end

  test "fighting: a nil obs (timer wake) never counts toward the lost streak" do
    logic = confirmed()
    {logic, []} = Logic.step(logic, nil, 500)
    assert logic.lost_streak == 0
  end

  test "fighting: fight_timeout drops the target" do
    logic = confirmed()
    {logic, actions} = Logic.step(logic, obs(locked?: true, locked_row: 0, captured_at: 7_000), 7_000)
    assert logic.state == :hunting
    assert Enum.any?(actions, &match?({:log, _}, &1))
    assert logic.counters.fights == 0
  end

  test "next_wake: tabbing → confirm window remainder; fighting → timeout remainder; hunting hold → hold remainder; free hunting → nil" do
    {tabbing, _} = Logic.step(hunting(0), obs(enemies: [0], captured_at: 10), 10)
    assert Logic.next_wake(tabbing, 110) == 600

    fighting = confirmed()
    assert Logic.next_wake(fighting, 100) == 6_000 - (100 - fighting.entered_at)

    held = %{hunting(0) | hold_until: 2_000}
    assert Logic.next_wake(held, 500) == 1_500

    assert Logic.next_wake(hunting(0), 500) == nil
  end

  # hunting --Tab--> tabbing --locked frame--> fighting (first burst already fired at t=40)
  defp confirmed do
    {logic, _} = Logic.step(hunting(0), obs(enemies: [0], captured_at: 10), 10)
    {logic, _} = Logic.step(logic, obs(locked?: true, locked_row: 0, captured_at: 30), 40)
    assert logic.state == :fighting
    logic
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/pokex/bots/combat/logic_test.exs`
Expected: FAIL — old Logic has no `:hunting` state / `next_wake`.

- [ ] **Step 3: Rewrite the Logic**

```elixir
# lib/pokex/bots/combat/logic.ex  (FULL REWRITE)
defmodule Pokex.Bots.Combat.Logic do
  @moduledoc """
  Pure Tab-targeting state machine. No side effects, no captures, no clock of its own: the
  driver feeds it battle OBSERVATIONS from the perception blackboard (or nil on a timer
  wake) plus monotonic `now`, and executes the returned keyboard-only actions.

  hunting  — enemies visible in the battle list → press Tab (the game selects the first
             attackable enemy) → tabbing. A hunt hold (after exhausted Tab attempts)
             throttles retries against an unattackable-but-visible row.
  tabbing  — wait for the lock ring on a frame captured AFTER the Tab (the confirm window
             counts from the press, so capture latency can't eat it — the old click flow's
             500ms window expired before its first read). No lock in tab_confirm_ms →
             re-Tab (cycles to the next candidate) up to tab_max_attempts, then hunt-hold.
  fighting — lock up → fire the next blind-rotation skill burst, throttled by
             skill_burst_every_ms (observations arrive faster than keys should). Lock gone
             target_lost_streak OBSERVED frames in a row → the target died: count the kill
             and hunt the next one (a nil/timer wake never counts — only real frames vote).

  There is NO mouse anywhere: Tab and skills are keys, the Guardian owns the panic corner,
  and the Body is not involved.
  """

  defstruct state: :idle,
            config: nil,
            entered_at: 0,
            tabbed_at: nil,
            tab_attempts: 0,
            hold_until: nil,
            last_obs_at: nil,
            skill_idx: 0,
            last_burst_at: nil,
            lost_streak: 0,
            locked_row: nil,
            failures: 0,
            error: nil,
            counters: %{fights: 0, loots: 0, captures: 0, failures: 0}

  # -- lifecycle ------------------------------------------------------------

  def new(config), do: %__MODULE__{config: config}

  def start(%__MODULE__{state: state} = logic, now) when state in [:idle, :error] do
    {%{
       logic
       | state: :hunting,
         entered_at: now,
         tabbed_at: nil,
         tab_attempts: 0,
         hold_until: nil,
         skill_idx: 0,
         last_burst_at: nil,
         lost_streak: 0,
         locked_row: nil,
         failures: 0,
         error: nil
     }, []}
  end

  def start(logic, _now), do: {logic, []}

  def stop(logic), do: {%{logic | state: :idle}, []}

  def io_failed(logic, reason, now), do: fail(logic, now, reason)

  @doc "A fish was hooked → an attackable enemy is imminent: drop any hunt hold."
  def rescan(%__MODULE__{state: :hunting} = logic, now),
    do: %{logic | hold_until: nil, entered_at: now}

  def rescan(logic, _now), do: logic

  # -- stepping ---------------------------------------------------------------

  @doc """
  Step on a battle observation (map with :enemies/:locked?/:locked_row/:captured_at) or nil
  (timer wake — only time-based rules apply). Returns {logic, actions}.
  """
  def step(%__MODULE__{state: state} = logic, _obs, _now) when state in [:idle, :error],
    do: {logic, []}

  def step(%{state: :hunting} = logic, obs, now) do
    cond do
      logic.hold_until != nil and now < logic.hold_until ->
        {logic, []}

      enemies(obs) != [] ->
        {tab(%{logic | hold_until: nil}, now), [{:tab}, {:log, "alvo na lista; Tab"}]}

      true ->
        {%{logic | hold_until: nil, locked_row: nil}, []}
    end
  end

  def step(%{state: :tabbing} = logic, obs, now) do
    cond do
      fresh_lock?(obs, logic.tabbed_at) ->
        # confirmed on a post-Tab frame → fight, and don't waste this event: first burst now.
        logic = %{
          logic
          | state: :fighting,
            entered_at: now,
            lost_streak: 0,
            locked_row: obs.locked_row,
            last_burst_at: nil
        }

        press_next_skill(logic, now)

      now - logic.tabbed_at > logic.config.tab_confirm_ms and
          logic.tab_attempts < logic.config.tab_max_attempts ->
        {tab(logic, now), [{:tab}, {:log, "sem lock; Tab #{logic.tab_attempts + 1}"}]}

      now - logic.tabbed_at > logic.config.tab_confirm_ms ->
        {%{
           logic
           | state: :hunting,
             entered_at: now,
             tabbed_at: nil,
             tab_attempts: 0,
             hold_until: now + logic.config.hunt_cooldown_ms
         }, [{:log, "Tab não lockou; pausa na caça"}]}

      true ->
        {logic, []}
    end
  end

  def step(%{state: :fighting} = logic, obs, now) do
    cond do
      now - logic.entered_at > logic.config.fight_timeout_ms ->
        {rehunt(logic, now), [{:log, "timeout do alvo; recaçando"}]}

      locked?(obs) ->
        logic = %{logic | lost_streak: 0, locked_row: obs.locked_row}
        press_next_skill(logic, now)

      observed?(obs) and logic.lost_streak + 1 >= logic.config.target_lost_streak ->
        logic = update_in(logic.counters.fights, &(&1 + 1))
        {rehunt(logic, now), [{:log, "alvo morto; caçando o próximo"}]}

      observed?(obs) ->
        {%{logic | lost_streak: logic.lost_streak + 1}, []}

      true ->
        # timer wake without a fresh frame: only the timeout above may act.
        {logic, []}
    end
  end

  @doc """
  When the driver must wake us even if no observation arrives: the earliest pending
  time-based deadline, or nil (purely event-driven right now).
  """
  def next_wake(%__MODULE__{state: :tabbing} = logic, now),
    do: max(logic.tabbed_at + logic.config.tab_confirm_ms - now, 1)

  def next_wake(%__MODULE__{state: :fighting} = logic, now),
    do: max(logic.entered_at + logic.config.fight_timeout_ms - now, 1)

  def next_wake(%__MODULE__{state: :hunting, hold_until: until}, now) when is_integer(until),
    do: max(until - now, 1)

  def next_wake(_logic, _now), do: nil

  # -- helpers ----------------------------------------------------------------

  defp tab(logic, now),
    do: %{logic | state: :tabbing, entered_at: now, tabbed_at: now, tab_attempts: logic.tab_attempts + 1}

  defp rehunt(logic, now) do
    %{
      logic
      | state: :hunting,
        entered_at: now,
        tabbed_at: nil,
        tab_attempts: 0,
        lost_streak: 0,
        skill_idx: 0,
        last_burst_at: nil,
        locked_row: nil
    }
  end

  # Blind rotation, throttled: observations arrive at feed cadence (~120ms) but keys should
  # fire at skill cadence (~300ms) — without the throttle the feed would triple the key rate.
  defp press_next_skill(%{config: %{skill_keys: []}} = logic, _now), do: {logic, []}

  defp press_next_skill(%{config: config} = logic, now) do
    if logic.last_burst_at != nil and now - logic.last_burst_at < config.skill_burst_every_ms do
      {logic, []}
    else
      burst = max(config.combat_skill_burst_size, 1)
      len = length(config.skill_keys)

      actions =
        for offset <- 0..(burst - 1) do
          {:press, Enum.at(config.skill_keys, rem(logic.skill_idx + offset, len))}
        end

      {%{logic | skill_idx: logic.skill_idx + burst, last_burst_at: now}, actions}
    end
  end

  defp fail(%__MODULE__{} = logic, now, reason) do
    failures = logic.failures + 1
    logic = update_in(logic.counters.failures, &(&1 + 1))
    reason = to_string(reason)

    if failures >= logic.config.max_consecutive_failures do
      {%{logic | state: :error, failures: failures, error: "#{reason} (#{failures}x seguidas)"},
       [{:log, reason}]}
    else
      {%{rehunt(logic, now) | failures: failures}, [{:log, reason}]}
    end
  end

  defp enemies(nil), do: []
  defp enemies(obs), do: obs[:enemies] || []

  defp observed?(obs), do: obs != nil

  defp locked?(nil), do: false
  defp locked?(obs), do: obs[:locked?] == true

  defp fresh_lock?(nil, _tabbed_at), do: false

  defp fresh_lock?(obs, tabbed_at),
    do: obs[:locked?] == true and is_integer(obs[:captured_at]) and obs[:captured_at] > tabbed_at
end
```

- [ ] **Step 4: Run the logic tests**

Run: `mix test test/pokex/bots/combat/logic_test.exs`
Expected: PASS. (`mix test` will FAIL now — the worker still calls the old API. That is expected mid-rewrite; Task 7 restores the suite. Do NOT commit yet.)

- [ ] **Step 5: proceed straight to Task 7** (they land as one commit train; the tree must not sit broken).

---

### Task 7: Combat.Worker rewrite + settings + panel labels (lands WITH Task 6)

Event-driven worker: subscribes to `"world"`, attaches `:battle` while running (and `:arena` only while fighting), presses Tab/skills via the direct keyboard path, never touches the Body or the mouse.

**Files:**
- Rewrite: `lib/pokex/bots/combat/worker.ex`
- Modify: `lib/pokex/settings.ex` (new seeds; remove `battle_confirm_ms`)
- Modify: `lib/pokex/bots/fisher/config.ex` (remove `:battle_confirm_ms` from the take-list so `Config.build` doesn't reference a dead seed; leave everything else — fishing still uses it)
- Modify: `lib/pokex/bots/bot_supervisor.ex` (combat child no longer takes `body:`)
- Modify: `lib/pokex_web/live/panel_live.ex:554-558` (state labels)
- Rewrite: `test/pokex/bots/combat/worker_test.exs`

**Interfaces:**
- Consumes: `Logic` (Task 6), `Perception.attach/detach` + `WorldState.get/3` (Tasks 3-5), `MiniGame.Worker.guard_before_input/0` + `guard_after_input/0` (unchanged), `Pokex.Rig.impl().press_many/2`.
- Produces: same public worker API (`run/1`, `halt/1`, `status/1`, `topic/0`, `catch_topic/0`); kill broadcast `{:kill, corpse}` unchanged (corpse now read from the `:arena` world entry, max age 5 × `feed_arena_ms`).

- [ ] **Step 1: Rewrite the worker test**

```elixir
# test/pokex/bots/combat/worker_test.exs  (FULL REWRITE)
defmodule Pokex.Bots.Combat.WorkerTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.Combat.Worker
  alias Pokex.Perception.WorldState
  alias Pokex.{Calibration, Settings}

  @keys [:tab_confirm_ms, :tab_max_attempts, :hunt_cooldown_ms, :skill_burst_every_ms,
         :combat_world_max_age_ms, :skill_keys]

  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    originals = Map.new(@keys, &{&1, Settings.get(&1)})

    on_exit(fn ->
      Application.delete_env(:pokex, :home_dir)
      Enum.each(originals, fn {k, v} -> Settings.put(k, v) end)
      :ets.delete(:pokex_world, :battle)
      :ets.delete(:pokex_world, :arena)
    end)

    Settings.put(:skill_burst_every_ms, 0)

    Calibration.save(%Calibration{
      scale: 1.0,
      screen_w: 1000,
      screen_h: 700,
      water_point: {400, 300},
      glow_region: {0, 0, 20, 20},
      battle_region: {0, 0, 80, 400},
      arena_region: {100, 100, 60, 40},
      neutral_point: {500, 500}
    })

    {:ok, _} = Pokex.Rig.Fake.start_link(%{})
    worker = start_supervised!({Worker, name: nil})
    :ok = Worker.run(worker)
    %{worker: worker}
  end

  defp battle_obs(fields) do
    Enum.into(fields, %{
      enemies: [],
      red: [],
      locked?: false,
      locked_row: nil,
      captured_at: System.monotonic_time(:millisecond)
    })
  end

  defp world!(worker, obs) do
    at = obs.captured_at
    WorldState.put(:battle, obs, at)
    send(worker, {:world, :battle, obs})
  end

  defp presses do
    for {:press, key} <- Pokex.Rig.Fake.calls(), do: key
  end

  @tag :tmp_dir
  test "an enemy observation makes it press Tab", %{worker: worker} do
    world!(worker, battle_obs(enemies: [0]))

    assert eventually(fn -> Settings.get(:tab_key) in presses() end)
    assert Worker.status(worker).state == :tabbing
  end

  @tag :tmp_dir
  test "a post-Tab locked observation confirms the fight and fires skills", %{worker: worker} do
    world!(worker, battle_obs(enemies: [0]))
    assert eventually(fn -> Worker.status(worker).state == :tabbing end)

    world!(worker, battle_obs(locked?: true, locked_row: 0))
    assert eventually(fn -> Worker.status(worker).state == :fighting end)
    assert eventually(fn -> "1" in presses() end)
  end

  @tag :tmp_dir
  test "lock lost for the streak broadcasts the kill with the arena corpse", %{worker: worker} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, Pokex.Bots.Loot.Worker.kill_topic())

    now = System.monotonic_time(:millisecond)
    WorldState.put(:arena, %{hostile: {123, 456}, captured_at: now}, now)

    world!(worker, battle_obs(enemies: [0]))
    assert eventually(fn -> Worker.status(worker).state == :tabbing end)
    world!(worker, battle_obs(locked?: true, locked_row: 0))
    assert eventually(fn -> Worker.status(worker).state == :fighting end)

    world!(worker, battle_obs(locked?: false))
    world!(worker, battle_obs(locked?: false))

    assert_receive {:kill, {123, 456}}, 1_000
    assert Worker.status(worker).counters.fights == 1
  end

  @tag :tmp_dir
  test "halt detaches and goes idle", %{worker: worker} do
    assert :ok = Worker.halt(worker)
    assert Worker.status(worker).state == :idle

    world!(worker, battle_obs(enemies: [0]))
    refute eventually(fn -> Worker.status(worker).state == :tabbing end, 300)
  end

  defp eventually(fun, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(fun, deadline)
  end

  defp poll(fun, deadline) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) > deadline -> false
      true ->
        Process.sleep(20)
        poll(fun, deadline)
    end
  end
end
```

- [ ] **Step 2: Settings seeds.** In `lib/pokex/settings.ex`:

REMOVE the `battle_confirm_ms: 500,` line (and its comment block). Grep first: `grep -rn battle_confirm_ms lib test` — the only other reference is `fisher/config.ex`'s take-list (removed below); if the diagnostics UI lists it, delete it there too.

APPEND to `@seed_settings` after the perception feed block:

```elixir
    # --- Combat: Tab targeting ------------------------------------------------------------------
    # Tab selects the first attackable enemy; pressing again CYCLES to the next. The confirm
    # window counts from the Tab press against frames captured AFTER it, so capture latency can't
    # eat the window (the old click flow's 500ms expired before its first read). Exhausting
    # tab_max_attempts hunt-holds for hunt_cooldown_ms so a visible-but-unattackable row can't
    # cause a Tab storm. skill_burst_every_ms throttles bursts below the feed cadence.
    tab_key: "tab",
    tab_confirm_ms: 700,
    tab_max_attempts: 3,
    hunt_cooldown_ms: 1_500,
    skill_burst_every_ms: 300,
    # Battle observations older than this are treated as unknown by combat (fail-safe: no keys).
    combat_world_max_age_ms: 600,
```

- [ ] **Step 3: `fisher/config.ex`** — remove the `:battle_confirm_ms,` line from the `Map.take` key list (line ~33). Nothing else.

- [ ] **Step 4: Rewrite the worker**

```elixir
# lib/pokex/bots/combat/worker.ex  (FULL REWRITE)
defmodule Pokex.Bots.Combat.Worker do
  @moduledoc """
  Event-driven driver around the pure Tab-targeting Combat.Logic. Consumes battle
  observations from the perception blackboard ("world" PubSub + WorldState), presses Tab
  and skill bursts through the DIRECT keyboard path (never the Body, never the mouse — the
  select-click died with the click-targeting flow), and broadcasts snapshots/kills exactly
  like before. The Guardian owns the panic corner; this worker reads no cursor.

  A fallback timer wakes the logic for its time-based deadlines (tab confirm window, fight
  timeout, hunt hold) even when the battle picture isn't changing — Logic.next_wake says
  when.
  """
  use GenServer
  require Logger

  alias Pokex.Bots.Combat.Logic
  alias Pokex.Bots.MiniGame
  alias Pokex.Perception
  alias Pokex.Perception.WorldState
  alias Pokex.{Preflight, Settings}

  @topic "combat"
  @catch_topic "fishing:caught"

  @config_keys [
    :tab_confirm_ms,
    :tab_max_attempts,
    :hunt_cooldown_ms,
    :skill_burst_every_ms,
    :fight_timeout_ms,
    :target_lost_streak,
    :skill_keys,
    :combat_skill_burst_size,
    :max_consecutive_failures
  ]

  def topic, do: @topic
  def catch_topic, do: @catch_topic

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, :ok)
      name -> GenServer.start_link(__MODULE__, :ok, name: name)
    end
  end

  def run(server \\ __MODULE__), do: GenServer.call(server, :run)
  def halt(server \\ __MODULE__), do: GenServer.call(server, :halt)
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(:ok) do
    Phoenix.PubSub.subscribe(Pokex.PubSub, @catch_topic)
    Phoenix.PubSub.subscribe(Pokex.PubSub, Perception.topic())
    {:ok, %{logic: nil, timer: nil, arena_attached?: false}}
  end

  @impl true
  def handle_call(:run, _from, state) do
    case Preflight.run() do
      :ok ->
        config = Settings.all() |> Map.take(@config_keys)
        {logic, _actions} = Logic.start(Logic.new(config), now())
        Perception.attach(:battle)
        broadcast(logic)
        # step immediately against whatever the world already knows
        {:reply, :ok, advance(%{state | logic: logic}, current_obs())}

      {:error, messages} when is_list(messages) ->
        {:reply, {:error, messages}, state}

      {:error, other} ->
        {:reply, {:error, [inspect(other)]}, state}
    end
  end

  def handle_call(:halt, _from, %{logic: nil} = state), do: {:reply, :ok, state}

  def handle_call(:halt, _from, state) do
    {logic, _} = Logic.stop(state.logic)
    Perception.detach(:battle)
    state = detach_arena(%{state | logic: logic})
    broadcast(logic)
    {:reply, :ok, cancel_timer(state)}
  end

  def handle_call(:status, _from, state), do: {:reply, snapshot(state.logic), state}

  @impl true
  def handle_info({:world, :battle, obs}, %{logic: %Logic{}} = state),
    do: {:noreply, advance(state, obs)}

  def handle_info({:world, _key, _obs}, state), do: {:noreply, state}

  def handle_info(:wake, %{logic: %Logic{}} = state), do: {:noreply, advance(state, current_obs())}
  def handle_info(:wake, state), do: {:noreply, state}

  def handle_info({:fish_caught}, %{logic: %Logic{}} = state) do
    {:noreply, advance(%{state | logic: Logic.rescan(state.logic, now())}, current_obs())}
  end

  def handle_info({:fish_caught}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  # -- the step pipeline -------------------------------------------------------

  defp advance(%{logic: %Logic{state: s}} = state, _obs) when s in [:idle, :error],
    do: cancel_timer(state)

  defp advance(state, obs) do
    previous = state.logic
    {logic, actions} = Logic.step(previous, obs, now())

    dispatch(actions)
    broadcast_activity(logic, actions)

    if logic.state != previous.state or logic.counters != previous.counters,
      do: broadcast(logic)

    if logic.counters.fights > previous.counters.fights,
      do: broadcast_kill(corpse())

    state = sync_arena(%{state | logic: logic})
    schedule_wake(state)
  end

  # Tab + skills are keys → the direct fire-and-forget path (a key must never wait behind a
  # mouse sequence holding the Body). Logs are broadcast, not typed.
  defp dispatch(actions) do
    keys =
      Enum.flat_map(actions, fn
        {:tab} -> [Settings.get(:tab_key)]
        {:press, key} -> [key]
        {:log, _} -> []
      end)

    if keys != [], do: spawn(fn -> tap_keys(keys) end)
    :ok
  end

  defp tap_keys(keys) do
    opts = [
      tap_count: Settings.get(:combat_skill_tap_count) |> positive_int(1),
      gap_ms: Settings.get(:combat_skill_gap_ms) |> non_neg_int(0),
      jitter_ms: Settings.get(:combat_skill_jitter_ms) |> non_neg_int(0)
    ]

    with :ok <- MiniGame.Worker.guard_before_input(),
         :ok <- Pokex.Rig.impl().press_many(keys, opts),
         :ok <- MiniGame.Worker.guard_after_input() do
      :ok
    else
      {:blocked, :mini_game_active} -> :ok
      {:error, reason} -> Logger.debug("combat key burst failed: #{inspect(reason)}")
    end
  catch
    kind, reason -> Logger.debug("combat key burst crashed: #{inspect({kind, reason})}")
  end

  # The freshest battle picture, or nil (stale/missing → Logic acts time-only, fail-safe).
  defp current_obs do
    case WorldState.get(:battle, Settings.get(:combat_world_max_age_ms), now()) do
      {:ok, obs} -> obs
      _stale_or_missing -> nil
    end
  end

  # The corpse point for loot: the arena feed's last hostile, if reasonably fresh.
  defp corpse do
    case WorldState.get(:arena, Settings.get(:feed_arena_ms) * 5, now()) do
      {:ok, %{hostile: point}} -> point
      _stale_or_missing -> nil
    end
  end

  # The arena feed (corpse position) only needs to run while fighting.
  defp sync_arena(%{logic: %Logic{state: :fighting}, arena_attached?: false} = state) do
    Perception.attach(:arena)
    %{state | arena_attached?: true}
  end

  defp sync_arena(%{logic: %Logic{state: s}, arena_attached?: true} = state)
       when s != :fighting,
       do: detach_arena(state)

  defp sync_arena(state), do: state

  defp detach_arena(%{arena_attached?: true} = state) do
    Perception.detach(:arena)
    %{state | arena_attached?: false}
  end

  defp detach_arena(state), do: state

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

  # -- broadcasts ---------------------------------------------------------------

  defp broadcast(logic),
    do: Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:combat, snapshot(logic)})

  defp broadcast_kill(corpse),
    do:
      Phoenix.PubSub.broadcast(
        Pokex.PubSub,
        Pokex.Bots.Loot.Worker.kill_topic(),
        {:kill, corpse}
      )

  defp broadcast_activity(logic, actions) do
    texts = for {:log, msg} <- actions, do: msg

    if texts != [] do
      level = if logic.state == :fighting or logic.counters.fights > 0, do: :macro, else: :debug

      Enum.each(texts, fn text ->
        Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:combat_log, level, "combate: #{text}"})
      end)
    end
  end

  defp snapshot(nil),
    do: %{state: :idle, counters: %Logic{}.counters, error: nil, locked_row: nil}

  defp snapshot(logic),
    do: %{
      state: logic.state,
      counters: logic.counters,
      error: logic.error,
      locked_row: logic.locked_row
    }

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, default), do: default

  defp non_neg_int(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_neg_int(_value, default), do: default

  defp now, do: System.monotonic_time(:millisecond)
end
```

- [ ] **Step 5: BotSupervisor** — in `lib/pokex/bots/bot_supervisor.ex` change the combat child spec (line ~71) from

```elixir
      Supervisor.child_spec({Combat.Worker, name: combat, body: body}, id: combat),
```

to

```elixir
      Supervisor.child_spec({Combat.Worker, name: combat}, id: combat),
```

- [ ] **Step 6: Panel labels** — in `lib/pokex_web/live/panel_live.ex:554-558` replace the combat_label clauses:

```elixir
  defp combat_label(:hunting, _row), do: "caçando"
  defp combat_label(:tabbing, _row), do: "confirmando alvo (Tab)"
  defp combat_label(:fighting, row) when is_integer(row), do: "lutando linha #{row}"
  defp combat_label(:fighting, _row), do: "lutando"
```

Then grep for stragglers: `grep -rn "scanning\|confirming" lib test --include="*.ex" --include="*.exs"` — update any remaining combat references (fishing has its own states; do not touch those). Also grep `Logic.needs\|Logic.waiting?\|Logic.tick_interval` — all callers were in the old worker; if diagnostics reference them, update or remove those call sites.

Also check the timing-tuner list in `panel_live.ex:31` (`:tick_ms_fighting` entry): `tick_ms_fighting` is still SEEDED (fishing's `Fisher.Config` includes it) but combat no longer reads it. Change its label to make ownership honest:

```elixir
    {:tick_ms_fighting, "Ritmo da luta (ms) — legado, sem efeito no combate Tab",
```

(keep the tuple's remaining elements exactly as they are).

- [ ] **Step 7: Run everything**

Run: `mix test`
Expected: PASS — logic tests (Task 6), new worker tests, and the whole suite. Fix any straggler test that referenced `:scanning`/`:confirming`/`battle_confirm_ms` (search `test/` for those strings; update to the new states/settings).

- [ ] **Step 8: Commit (Tasks 6+7 together)**

```bash
git add -A lib/pokex/bots/combat lib/pokex/settings.ex lib/pokex/bots/fisher/config.ex lib/pokex/bots/bot_supervisor.ex lib/pokex_web/live/panel_live.ex test/pokex/bots/combat
git commit -m "combat: keyboard-only Tab targeting driven by the perception blackboard

Replaces click-targeting (select-click + confirm window + candidate walk +
per-tick cursor read) with hunting→tabbing→fighting on battle observations
from the :battle feed. Confirm window counts from the Tab press against
post-press frames; re-Tab cycles targets; skill bursts throttled to
skill_burst_every_ms. Combat no longer touches the Body or the mouse."
git push
```

---

### Task 8: Whole-feature verification + docs touch-up

**Files:**
- Modify: `README.md` (if it describes combat click-targeting — grep `click` / `clique`)
- Verify: everything

- [ ] **Step 1:** `mix test` — full suite green.
- [ ] **Step 2:** `grep -rn "battle_confirm_ms\|Logic.needs\|tick_ms_fighting" lib/ test/` — the only `tick_ms_fighting` hits should be fishing's config/seed and the relabeled tuner entry; nothing references `battle_confirm_ms`.
- [ ] **Step 3:** Update README/moduledocs that describe the old click flow (grep `select-click`, `clica`, `battle click`).
- [ ] **Step 4:** Commit + push (`docs: combat flow docs reflect Tab targeting`).
- [ ] **Step 5:** Report to Lucas the manual validation checklist (in Portuguese):
  1. `git pull` + restart do server.
  2. No painel: Avançado → **Medir** (Captura de tela) — anotar backend + avg/max ANTES de ligar bots.
  3. Ligar SÓ o combate perto de inimigos: ver "caçando → confirmando alvo (Tab) → lutando" no feed; conferir que o Tab seleciona e as skills disparam ~a cada 300ms.
  4. Ligar pesca + combate juntos: o cursor não deve mais brigar (combate não move o mouse).
  5. Medir de novo e comparar.

---

## Follow-up plans (not in this document)

- **Phase 2** (separate plan after Lucas validates phase 1 in-game): migrate `:glow`/`:pokemon_hp`/`:mini_game`/`:skill_bar` to feeds; fishing/GameController/MiniGame become deciders; `:persistent_term` input guard; loot/mini-game event holds; delete pause/resume, the dead combat entries in `Fisher.Sensors.Real`, and the now-dead combat settings (`hostile_scan_every`, `tick_ms_fighting` if fishing truly doesn't use it).
- **Phase 3** (separate small plan): `/world` LiveView page over `WorldState.entries()`.
