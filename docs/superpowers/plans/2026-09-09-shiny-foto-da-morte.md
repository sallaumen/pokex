# A foto da morte do shiny (PR 0) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `ShinyGuard` keeps the last frame with the special colour, converts the blob point to SCREEN points, and photographs + journals the three moments that answer "does the shiny corpse keep its palette?": first sighting, the blob leaving, and the battle list dropping while the blob is on screen.

**Architecture:** No new process. `ShinyGuard.judge/4` already reads every scan; it gains a `keepsake` step that compares this scan with the previous one (seen edge, gone edge, enemies drop) and, on an edge, writes `captures/shiny/<ms>-<uniq>-<tag>.raw` (+ `.bmp` evidence with a cross on the blob) and files `kind: :special` in `Pokex.Engine.Events`. `Frame.to_raw/1` is the only new public function (the inverse of `from_file/1`). The `:special` fact and `{:shiny_seen, _}` carry screen points from now on; the engine reads only `especial?` and the Catcher ignores the point, so consumers are unaffected.

**Tech Stack:** Elixir/Phoenix, ExUnit, `Pokex.Vision.{Frame, ColorMark, Evidence}`, `Pokex.Engine.Events`, `Pokex.Perception.WorldState`.

## Global Constraints

- Identifiers, comments and test names in English; user-facing text (journal phrases) in pt-BR; no accents in test names (the #515 guard).
- Never run anything in `~/projects/pokex`; work in `.claude/worktrees/shiny-na-cacada`. Never `mix run` (memory `mix-run-mata-o-helper`). Run only the test file you touched, never the whole suite until the end.
- Gate before the PR: `mix precommit`, then `mix credo` and `mix dialyzer` separately. `git add` per file.
- Writes under `~/.pokex` only via `Pokex.Home.write!/2` (atomic) and only in a subdirectory with rotation (`@keep_photos 30`, like `CrowdWatch`).
- Captures are RAW (`.raw`, PXRW header); evidence is BMP (the project has no PNG encoder — `Pokex.Vision.Evidence`).

---

### Task 1: `Frame.to_raw/1` — the inverse of `from_file/1`

**Files:**
- Modify: `lib/pokex/vision/frame.ex` (after `from_file/1`)
- Test: `test/pokex/vision/frame_test.exs`

**Interfaces:**
- Produces: `Pokex.Vision.Frame.to_raw(%Frame{}) :: binary` — `<<"PXRW", 1, width::32, height::32, rgba::binary>>`, readable back by `Frame.from_file/1`.

- [ ] **Step 1: Write the failing test** (append inside the module of `test/pokex/vision/frame_test.exs`)

```elixir
  @moduletag :tmp_dir

  test "to_raw round-trips through from_file", %{tmp_dir: tmp} do
    frame = %Pokex.Vision.Frame{width: 2, height: 1, rgba: <<1, 2, 3, 255, 4, 5, 6, 255>>}
    path = Path.join(tmp, "roundtrip.raw")
    File.write!(path, Pokex.Vision.Frame.to_raw(frame))

    assert {:ok, %Pokex.Vision.Frame{width: 2, height: 1, rgba: rgba}} =
             Pokex.Vision.Frame.from_file(path)

    assert rgba == frame.rgba
  end
```

If the file already declares `@moduletag :tmp_dir`, do not add it twice.

- [ ] **Step 2: Run it, expect failure**

Run: `mix test test/pokex/vision/frame_test.exs`
Expected: FAIL with `undefined function to_raw/1`.

- [ ] **Step 3: Implement**

```elixir
  @doc """
  The bytes `from_file/1` reads: the 13-byte PXRW header and the RGBA. What a
  keeper writes when it wants to save exactly the frame it analysed.
  """
  @spec to_raw(t) :: binary
  def to_raw(%__MODULE__{width: w, height: h, rgba: rgba}),
    do: <<"PXRW", 1, w::32, h::32, rgba::binary>>
```

- [ ] **Step 4: Run it, expect pass**

Run: `mix test test/pokex/vision/frame_test.exs`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add lib/pokex/vision/frame.ex test/pokex/vision/frame_test.exs
git commit -m "o frame sabe se escrever em raw: o inverso do from_file, pra guardar exatamente a foto que foi lida"
```

### Task 2: screen points in the `:special` fact and in `{:shiny_seen, _}`

**Files:**
- Modify: `lib/pokex/bots/shiny_guard.ex` — `snapshot/1`, `judge/4`, `publish_special/1`, `fire/3`
- Test: `test/pokex/bots/shiny_guard_test.exs`

**Interfaces:**
- Produces: `:special` fact `%{especial?: boolean, vistos: [%{name, px, point: {sx, sy}}]}` with `point` in SCREEN points; `{:shiny_seen, %{px, name, point: {sx, sy}}}` likewise.

- [ ] **Step 1: Write the failing test** (in `shiny_guard_test.exs`)

```elixir
  # The blob's centre of mass is in FRAME pixels; the fact and the broadcast
  # carry SCREEN points, the only frame a click or the Catcher understands.
  test "the fact and the broadcast carry the blob in screen points", %{region: region} do
    regra_provada(%{"name" => "Electrode shiny"})
    Phoenix.PubSub.subscribe(Pokex.PubSub, "shiny")
    start_guard(fn _region, _name -> {:ok, frame_com_mancha(region)} end)

    assert_receive {:shiny_seen, %{point: {sx, sy}}}, 2_000

    # the patch is 14x14 at (10,10) in the frame: its centre is (17,17) from the region origin
    {rx, ry, _w, _h} = region
    assert_in_delta sx, rx + 17, 4
    assert_in_delta sy, ry + 17, 4

    assert {:ok, %{vistos: [%{point: {^sx, ^sy}}]}} =
             WorldState.get(:special, 5_000, System.monotonic_time(:millisecond))
  end
```

- [ ] **Step 2: Run it, expect failure**

Run: `mix test test/pokex/bots/shiny_guard_test.exs`
Expected: the new test fails on `assert_in_delta` (the point is `{17, 17}` in frame px, not `{rx+17, ry+17}`).

- [ ] **Step 3: Implement** — `snapshot/1` returns the region too; `judge/5` converts each blob once; `publish_special/1` and `fire/3` use the converted blob.

```elixir
  defp snapshot(state) do
    with {:ok, calib} <- Calibration.load(),
         {:ok, {_x, _y, _w, _h} = region} <- SpotScan.region(calib),
         {:ok, %Frame{} = frame} <- state.capture.(region, "special_colors.raw") do
      {:ok, frame, region, forbidden_boxes(calib, frame, region)}
    end
  end
```

In `look/1` change the match to `{:ok, frame, region, forbidden} -> judge(state, rules, frame, region, forbidden)`.

```elixir
  defp judge(state, rules, frame, region, forbidden) do
    {state, best, vistos} =
      Enum.reduce(rules, {state, 0, []}, fn rule, {state, best, vistos} ->
        result =
          ColorMark.scan(frame, rule.specs,
            min_cell_px: rule.min_cell_px,
            forbidden: forbidden
          )

        mancha = result.manchas |> List.first() |> on_screen(region, frame.scale)
        hit? = mancha != nil and mancha.px >= rule.min_px

        {advance(state, rule, mancha, hit?), max(best, result.px),
         if(hit?, do: [{rule, mancha} | vistos], else: vistos)}
      end)

    publish_special(vistos)
    broadcast_reading(state, best)
  end

  # ColorMark answers in FRAME pixels of the square; everything downstream (the
  # fact, the Catcher, a click) speaks SCREEN points. Converted once, here.
  defp on_screen(nil, _region, _scale), do: nil

  defp on_screen(%{point: {fx, fy}} = mancha, {rx, ry, _w, _h}, scale) do
    mancha
    |> Map.put(:point, {rx + round(fx / scale), ry + round(fy / scale)})
    # the frame pixel stays for the evidence picture (Task 3); it never leaves the module
    |> Map.put(:in_frame, {fx, fy})
  end
```

`publish_special/1` and `fire/3` need no change: they already read `m.point` / `mancha.point`, which is now the screen point. Update the `@moduledoc` sentence "with `ColorMark` doing the reading" to add: "Points leave this module in SCREEN coordinates."

- [ ] **Step 4: Run, expect pass**

Run: `mix test test/pokex/bots/shiny_guard_test.exs`
Expected: all green (the existing `vistos: [%{name: ...}]` assertions still match).

- [ ] **Step 5: Commit**

```bash
git add lib/pokex/bots/shiny_guard.ex test/pokex/bots/shiny_guard_test.exs
git commit -m "a mancha do shiny sai da guarda em pontos de TELA: o fato e o aviso já dizem onde clicar"
```

### Task 3: the keepsake — photos and `kind: :special` on the three edges

**Files:**
- Modify: `lib/pokex/bots/shiny_guard.ex` — state, `judge/5`, new private section `-- a foto da morte --`
- Test: `test/pokex/bots/shiny_guard_test.exs`

**Interfaces:**
- Consumes: `Frame.to_raw/1` (Task 1); `on_screen/3` blobs (Task 2); `WorldState.get(:battle, ...)` `%{enemies: list}`; `Pokex.Vision.Evidence.data_url/2`; `Pokex.Engine.Events.record/2`.
- Produces: files `Pokex.Home.captures_dir()/shiny/<ms>-<uniq>-<tag>.raw` and `.bmp`, `tag in ["seen", "last", "gone", "drop"]`; journal record `kind: :special` with `%{tag, name, px, point: {sx, sy}, enemies}`; start option `journal: (atom, map -> :ok)` (default `&Pokex.Engine.Events.record/2`) so tests can observe the record.

Semantics, in one place:

| moment | condition | photos | journal `tag` |
|---|---|---|---|
| first sighting | no rule seen on the previous scan, ≥ 1 seen now | current frame → `seen` | `"seen"` |
| the colour leaves | ≥ 1 seen before, none now | previous frame → `last`, current frame → `gone` | `"gone"` |
| the list drops with the colour on screen | ≥ 1 seen now, `enemies < previous enemies` | current frame → `drop` | `"drop"` |

A moment repeats no sooner than `@photo_gap_ms 3_000` per tag (a blob flapping at the threshold must not push the useful photos out of the 30-file rotation). `enemies` is `length(:battle.enemies)` with `combat_world_max_age_ms`, `0` when the fact is stale — the same reading `CrowdWatch.listed/1` makes.

- [ ] **Step 1: Write the failing tests** (in `shiny_guard_test.exs`; add `alias Pokex.Home` at the top)

```elixir
  defp photos, do: Path.join(Home.captures_dir(), "shiny") |> Path.join("*") |> Path.wildcard()

  defp tags, do: photos() |> Enum.map(&(&1 |> Path.basename() |> String.split("-") |> List.last())) |> Enum.sort()

  defp start_guard_journaling(capture) do
    test = self()

    start_supervised!(
      {ShinyGuard,
       name: nil,
       active: true,
       capture: capture,
       journal: fn kind, payload -> send(test, {:journal, kind, payload}) end}
    )
  end

  # The question this whole PR exists to answer — "does the corpse keep the
  # palette?" — is answered by the photo of the moment the colour LEAVES, next
  # to the last photo in which it was still there.
  test "the colour leaving keeps the last frame with it and the first without", %{region: region} do
    regra_provada(%{"name" => "Electrode shiny"})
    {:ok, contador} = Agent.start_link(fn -> 0 end)
    limpo = frame(elem(region, 2), elem(region, 3), {40, 40, 40}, [])

    start_guard_journaling(fn _region, _name ->
      n = Agent.get_and_update(contador, &{&1, &1 + 1})
      if n < 3, do: {:ok, frame_com_mancha(region)}, else: {:ok, limpo}
    end)

    assert_receive {:journal, :special, %{tag: "seen", name: "Electrode shiny", px: px, point: {_, _}}}, 2_000
    assert px >= 50
    assert_receive {:journal, :special, %{tag: "gone", name: "Electrode shiny"}}, 2_000

    assert eventually(fn -> tags() == ["gone.bmp", "gone.raw", "last.bmp", "last.raw", "seen.bmp", "seen.raw"] end)

    # the "last" photo is a frame WITH the blob, the "gone" photo one WITHOUT
    [last] = photos() |> Enum.filter(&String.ends_with?(&1, "last.raw"))
    [gone] = photos() |> Enum.filter(&String.ends_with?(&1, "gone.raw"))
    assert {:ok, %Frame{rgba: com}} = Frame.from_file(last)
    assert {:ok, %Frame{rgba: sem}} = Frame.from_file(gone)
    assert com == frame_com_mancha(region).rgba
    assert sem == limpo.rgba
  end

  # The list shrinking while the colour is still on screen is the shiny most
  # likely dying — the frame of that instant is the corpse, if the palette stays.
  test "the list dropping with the colour on screen keeps a drop photo", %{region: region} do
    regra_provada(%{"name" => "Electrode shiny"})
    now = System.monotonic_time(:millisecond)
    WorldState.put(:battle, %{enemies: [0, 1]}, now)

    start_guard_journaling(fn _region, _name ->
      {:ok, frame_com_mancha(region)}
    end)

    assert_receive {:journal, :special, %{tag: "seen", enemies: 2}}, 2_000
    WorldState.put(:battle, %{enemies: [0]}, System.monotonic_time(:millisecond))

    assert_receive {:journal, :special, %{tag: "drop", enemies: 1, name: "Electrode shiny"}}, 2_000
    assert eventually(fn -> "drop.raw" in tags() end)
  end

  # A blob flapping at the threshold must not flood the rotation.
  test "the same moment does not repeat within the photo gap", %{region: region} do
    regra_provada()
    {:ok, contador} = Agent.start_link(fn -> 0 end)
    limpo = frame(elem(region, 2), elem(region, 3), {40, 40, 40}, [])

    # seen, gone, seen, gone, seen, gone... every scan flips
    start_guard_journaling(fn _region, _name ->
      n = Agent.get_and_update(contador, &{&1, &1 + 1})
      if rem(n, 2) == 0, do: {:ok, frame_com_mancha(region)}, else: {:ok, limpo}
    end)

    assert_receive {:journal, :special, %{tag: "seen"}}, 2_000
    assert_receive {:journal, :special, %{tag: "gone"}}, 2_000
    refute_receive {:journal, :special, %{tag: "seen"}}, 500
  end
```

Also add `:ets.delete(:pokex_world, :battle)` to the `setup` block, next to the `:special` delete.

- [ ] **Step 2: Run, expect failure**

Run: `mix test test/pokex/bots/shiny_guard_test.exs`
Expected: the three new tests fail (no `:journal` option, no `{:journal, ...}` messages, no photos).

- [ ] **Step 3: Implement**

State (in `start_link/1`):

```elixir
      journal: Keyword.get(opts, :journal, &Pokex.Engine.Events.record/2),
      # the previous scan, for the edges: which rules were seen, with which
      # blob, on which frame, with how many listed enemies
      prev: %{seen: [], frame: nil, enemies: 0},
      # last photo per tag: the flood gate
      photographed_at: %{}
```

Module attributes:

```elixir
  @keep_photos 30
  @photo_gap_ms 3_000
  @photo_dir "shiny"
```

Alias `Pokex.Home` and `Pokex.Vision.Evidence`.

`judge/5` ends with:

```elixir
    state = keepsake(state, vistos, frame)
    publish_special(vistos)
    broadcast_reading(state, best)
```

The new section:

```elixir
  # -- a foto da morte ----------------------------------------------------------
  #
  # Three moments answer "does the shiny's corpse keep the palette?": the colour
  # appearing, the colour leaving (with the LAST frame it was still in), and the
  # battle list shrinking while the colour is on screen. Each keeps a raw frame,
  # a BMP with a cross on the blob, and one `kind: :special` line in the journal.
  # Nothing here decides anything.

  defp keepsake(state, vistos, frame) do
    enemies = listed()
    now = System.monotonic_time(:millisecond)
    prev = state.prev

    state =
      cond do
        prev.seen == [] and vistos != [] ->
          keep(state, "seen", vistos, frame, enemies, now)

        prev.seen != [] and vistos == [] ->
          state
          |> keep("last", prev.seen, prev.frame, prev.enemies, now, :quiet)
          |> keep("gone", prev.seen, frame, enemies, now)

        vistos != [] and enemies < prev.enemies ->
          keep(state, "drop", vistos, frame, enemies, now)

        true ->
          state
      end

    %{state | prev: %{seen: vistos, frame: frame, enemies: enemies}}
  end

  # `:quiet` keeps the photo without a journal line: "last" is the companion of
  # "gone", one record for the pair.
  defp keep(state, tag, vistos, frame, enemies, now, voice \\ :loud)

  defp keep(state, tag, [{rule, mancha} | _] = _vistos, %Frame{} = frame, enemies, now, voice) do
    if gap_ok?(state, tag, now) do
      save_photos(frame, mancha, tag)

      if voice == :loud do
        state.journal.(:special, %{
          tag: tag,
          name: rule.name,
          px: mancha.px,
          point: mancha.point,
          enemies: enemies
        })
      end

      %{state | photographed_at: Map.put(state.photographed_at, tag, now)}
    else
      state
    end
  end

  defp keep(state, _tag, _no_blob, _no_frame, _enemies, _now, _voice), do: state

  defp gap_ok?(state, tag, now) do
    case Map.get(state.photographed_at, tag) do
      nil -> true
      at -> now - at >= @photo_gap_ms
    end
  end

  defp listed do
    now = System.monotonic_time(:millisecond)

    case WorldState.get(:battle, Settings.get(:combat_world_max_age_ms), now) do
      {:ok, %{enemies: enemies}} when is_list(enemies) -> length(enemies)
      _no_list -> 0
    end
  end

  # The raw is the frame the code read; the BMP is the same frame with a cross
  # on the blob, for eyes. Both under captures/shiny, 30 files kept.
  defp save_photos(frame, mancha, tag) do
    dir = Path.join(Home.captures_dir(), @photo_dir)
    File.mkdir_p!(dir)
    stem = "#{System.system_time(:millisecond)}-#{System.unique_integer([:positive, :monotonic])}-#{tag}"

    Home.write!(Path.join(dir, stem <> ".raw"), Frame.to_raw(frame))

    with {:ok, bytes} <- evidence_bytes(frame, mancha) do
      Home.write!(Path.join(dir, stem <> ".bmp"), bytes)
    end

    rotate(dir)
  rescue
    # A photo that cannot be saved is a photo lost, never a scan lost.
    _no_photo -> :ok
  end

  defp evidence_bytes(frame, %{in_frame: {fx, fy}}) do
    url = Evidence.data_url(frame, shrink: 2, marks: [{fx, fy, {255, 0, 255}}])

    case String.split(url, ",", parts: 2) do
      [_head, body] -> Base.decode64(body)
      _no_body -> :error
    end
  end

  defp rotate(dir) do
    dir
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.reverse()
    |> Enum.drop(@keep_photos)
    |> Enum.each(&File.rm/1)
  end
```

`publish_special/1` already picks `name/px/point` explicitly, so `in_frame` never leaves the module.

- [ ] **Step 4: Run, expect pass**

Run: `mix test test/pokex/bots/shiny_guard_test.exs`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add lib/pokex/bots/shiny_guard.ex test/pokex/bots/shiny_guard_test.exs
git commit -m "a foto da morte: a guarda guarda o último quadro com a cor, o primeiro sem, e o instante em que a lista cai com a cor na tela — com uma linha special no diário"
```

### Task 4: the gate and the PR

**Files:**
- Modify: `docs/shiny/plano-shiny-por-cor.md` — in the `ESTADO` header, one line: "09/09: PR 0 do plano `2026-09-09-shiny-na-cacada-design.md` — a guarda fotografa os três momentos (`captures/shiny/`) e publica pontos de TELA."

- [ ] **Step 1: Run the gate**

Run: `mix precommit` then `mix credo` then `mix dialyzer` (each on its own).
Expected: all clean. If credo flags the arity of `keep/7`, move `voice` and `now` into a small map argument — same behaviour.

- [ ] **Step 2: Commit the doc line and push, open the PR**

```bash
git add docs/shiny/plano-shiny-por-cor.md
git commit -m "o plano por cor aponta pro PR 0 da foto da morte"
git push -u origin feat/shiny-foto-da-morte
gh pr create --title "PR 0 do shiny na caçada: a foto da morte" --body-file -
```

PR body (pt-BR): what the three moments are, where the photos land, that `:special` now carries screen points, and the two things only he can do before this PR does anything: teach and prove a colour rule, and enable `shiny_guard_enabled`.

- [ ] **Step 3: When green, merge and move on** (house order: PR verde, mergeie você mesmo).
