# Percepção Total — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the bot SEE the whole screen continuously — enemy names/HP, my pokémon, team, character level, item stocks, minimap position — with zero manual HUD calibration, plus stock alerts, team↔slot mapping and a first combo engine.

**Architecture:** A deterministic bitmap-glyph reader (`Vision.Glyphs`) turns pixels into text; a layout profile anchored on 3 fixed UI templates (`Pokex.Layout`) derives every HUD region automatically; new demand-driven feeds (`:hud`, `:team`, `:minimap`, upgraded `:battle`) publish into the existing WorldState blackboard; `World.snapshot/0` exposes one game-state struct that alerts, combos and the future cavebot consume.

**Tech Stack:** Elixir/Phoenix LiveView (existing app), zero new deps. All vision is pure functions over the existing `Pokex.Vision.Frame` RGBA binaries.

**Spec:** `docs/superpowers/specs/2026-07-22-percepcao-total-design.md` — read it first.

## Global Constraints

- **NEVER start a dev server** (`mix phx.server`, `iex -S mix phx.server`) — Lucas's running instance shares `~/.pokex` and drives his real mouse. Verification is tests + static renders only.
- **Shared worktree** (`~/projects/pokex-round2`): other AI sessions work in this tree. NEVER `git add -A` / `git add .` — stage only files you created/edited. NEVER `git commit --amend`. Re-check `git rev-parse HEAD` + current branch immediately before every commit/push. A test failing in a file you didn't touch = probably a sister session's in-progress lane; verify against clean main before touching it.
- Branch flow: `git fetch origin && git checkout --detach origin/main && git checkout -b <lane>/<name>`; one PR per phase; merge your own PR right after creating it (Lucas's standing rule); delete the branch after merge.
- Commits end with: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` (adjust the model name if you are not Fable).
- Tests must NEVER reach the network and NEVER capture the real screen. Use `Pokex.Rig.Fake` (see `test/support/`); pre-write PNGs at `/tmp/fake/<filename>` for the Fake's default capture paths; occupy the `:pokedex_sync` registered name if a test could trigger a sync.
- `:persistent_term` caches need `clear()`/env-key scoping in `on_exit` (see `Pokex.Pokedex` pattern).
- All key/click actuation goes through `Pokex.Bots.Body` (priority lanes) behind InputGate + Focus guard + panic corner. Never actuate directly.
- Settings: ONE source of truth `@seed_settings` in `lib/pokex/settings.ex`; read via `Settings.get/1` / `Settings.value/2`; never scatter defaults.
- Ground truth: `test/fixtures/screen/ultrawide_3440x1440_full.png` (3440×1440 capture, 2026-07-22) + crops (`hud_bottom.png` @ (1200,1330) 1140×110, `right_panel.png` @ (3140,0) 300×800, `left_hud.png` @ (0,960) 360×480, `pokelog.png` @ (0,30) 300×480). Every region/glyph/template derives from these files — measure, don't guess.
- Confirmed game facts (from Lucas): the big left bar "5559/6410" = ACTIVE POKÉMON HP; character level = the "90" next to the blue-bar ⚪ orb in the bottom HUD; "96 🎣" = fishing skill; stock-alert slots = F1, F2, E, S+Q; team swap = single key C+2..C+6 (swaps directly).
- `mix format` + `mix compile --warnings-as-errors` + full `mix test` green before every PR.

## File Structure

```
lib/pokex/vision/glyphs.ex            # NEW  glyph atlas reader (pure)
lib/mix/tasks/glyphs.learn.ex         # NEW  atlas builder from labeled fixtures
priv/glyphs/atlas.json                # NEW  generated glyph atlas (committed)
test/fixtures/glyphs/labels.json      # NEW  labeled regions on the screen fixtures
lib/pokex/layout.ex                   # NEW  profile load + locate + Fix struct
priv/layouts/ultrawide_3440x1440.json # NEW  the layout profile (regions rel. to anchors)
priv/layouts/anchors/*.png            # NEW  anchor templates (extracted from fixture)
lib/pokex/perception/interpret.ex     # MOD  battle upgrade (+ enemies_detail)
lib/pokex/perception/interpret/hud.ex     # NEW  bottom-bar + left-HUD interpreter
lib/pokex/perception/interpret/team.ex    # NEW  team rows interpreter
lib/pokex/perception/interpret/minimap.ex # NEW  coord interpreter
lib/pokex/perception.ex               # MOD  feed_specs += :hud/:team/:minimap
lib/pokex/world.ex                    # NEW  World.snapshot/0
lib/pokex/bots/stock_alerts.ex        # NEW  always-on stock watcher
lib/pokex/pokedex/team.ex             # MOD  v3: slot field (C+N)
lib/pokex/combos.ex                   # NEW  combo structs + chooser + pure runner logic
lib/pokex/bots/combat/*               # MOD  combo execution hook
lib/pokex/bots/body.ex                # MOD  minimap_step/2 primitive
lib/pokex/settings.ex                 # MOD  new seeds (cadences, thresholds, combo waits)
lib/pokex_web/live/world_live.ex      # MOD  /world v2 (snapshot mirror)
lib/pokex_web/live/panel_live.ex      # MOD  stock badges + layout banner
lib/pokex_web/live/team_live.ex       # MOD  slot mapping UI (whatever file owns /time)
```

Phase→PR mapping: F1 = Tasks 1–4, F2 = 5–7, F3 = 8–12, F4 = 13, F5 = 14–16, F6 = 17, wrap-up = 18.

---

### Task 1: Fixture harness + labeled regions

**Files:**
- Create: `test/fixtures/glyphs/labels.json`
- Create: `test/support/screen_fixtures.ex`
- Test: `test/pokex/vision/glyphs_labels_test.exs`

**Interfaces:**
- Produces: `Pokex.ScreenFixtures.frame!(name)` → `%Pokex.Vision.Frame{}` loaded from `test/fixtures/screen/<name>.png`; `Pokex.ScreenFixtures.labels/0` → decoded labels.json.
- Labels entry shape: `{"fixture": "hud_bottom", "region": [x, y, w, h], "kind": "int"|"line"|"coord", "expected": "322"}` — region in FIXTURE-LOCAL pixels.

- [ ] **Step 1: Write labels.json with the initial measured regions**

These rects were measured at ±5px on the committed crops; the test loop in Step 2 is the precision instrument — nudge x/y by up to ±10px until the pixels under the rect contain exactly the label's text (view crops with any image viewer; each text line is ~16–22px tall).

```json
{
  "labels": [
    {"fixture": "hud_bottom", "region": [64, 22, 70, 22], "kind": "int", "expected": "1525"},
    {"fixture": "hud_bottom", "region": [282, 22, 40, 22], "kind": "int", "expected": "90"},
    {"fixture": "hud_bottom", "region": [946, 22, 40, 22], "kind": "int", "expected": "96"},
    {"fixture": "hud_bottom", "region": [660, 22, 78, 22], "kind": "line", "expected": "10:33"},
    {"fixture": "hud_bottom", "region": [78, 82, 40, 16], "kind": "int", "expected": "322"},
    {"fixture": "hud_bottom", "region": [138, 82, 34, 16], "kind": "int", "expected": "36"},
    {"fixture": "left_hud", "region": [150, 38, 180, 22], "kind": "line", "expected": "5559/6410"},
    {"fixture": "right_panel", "region": [12, 8, 200, 24], "kind": "coord", "expected": "(337, 46107, 4)"},
    {"fixture": "right_panel", "region": [64, 545, 130, 22], "kind": "line", "expected": "Pidgeot"},
    {"fixture": "right_panel", "region": [66, 468, 90, 26], "kind": "line", "expected": "Battle"}
  ]
}
```

- [ ] **Step 2: Write the harness + a test that only asserts fixtures load and regions fit inside them**

```elixir
# test/support/screen_fixtures.ex
defmodule Pokex.ScreenFixtures do
  @dir "test/fixtures/screen"

  def frame!(name) do
    {:ok, frame} = Pokex.Vision.Frame.from_png_file(Path.join(@dir, "#{name}.png"))
    frame
  end

  def labels do
    "test/fixtures/glyphs/labels.json" |> File.read!() |> Jason.decode!() |> Map.fetch!("labels")
  end
end
```

```elixir
# test/pokex/vision/glyphs_labels_test.exs
defmodule Pokex.Vision.GlyphsLabelsTest do
  use ExUnit.Case, async: true

  test "every label's region fits inside its fixture" do
    for %{"fixture" => f, "region" => [x, y, w, h]} <- Pokex.ScreenFixtures.labels() do
      frame = Pokex.ScreenFixtures.frame!(f)
      assert x >= 0 and y >= 0 and x + w <= frame.width and y + h <= frame.height,
             "label out of bounds in #{f}: #{inspect({x, y, w, h})}"
    end
  end
end
```

- [ ] **Step 3: Run** `mix test test/pokex/vision/glyphs_labels_test.exs` — PASS (bounds only; content correctness lands with the reader in Task 3).
- [ ] **Step 4: Commit** `git add test/support/screen_fixtures.ex test/fixtures/glyphs/labels.json test/pokex/vision/glyphs_labels_test.exs && git commit -m "percepcao: screen-fixture harness + labeled glyph regions"`

### Task 2: Glyph segmentation (binarize + split)

**Files:**
- Create: `lib/pokex/vision/glyphs.ex`
- Test: `test/pokex/vision/glyphs_test.exs`

**Interfaces:**
- Produces: `Glyphs.segment(frame, {x, y, w, h}, opts \\ [])` → `[%{x0: int, x1: int, bitmap: [[0|1]]}]` — one entry per glyph, left-to-right. Binarization: pixel is INK when `max(r,g,b) >= 170` (bright text on dark panels; the fixture's dimmest digits are ~180). A glyph boundary is ≥1 fully-empty pixel column. Rows are trimmed to the glyph's tight bounding box.

- [ ] **Step 1: Failing test — segmenting "5559/6410" yields 9 glyphs**

```elixir
defmodule Pokex.Vision.GlyphsTest do
  use ExUnit.Case, async: true

  alias Pokex.Vision.Glyphs

  defp label!(fixture, expected) do
    Enum.find(Pokex.ScreenFixtures.labels(), &(&1["fixture"] == fixture and &1["expected"] == expected))
  end

  test "segments 5559/6410 into 9 glyphs, left to right" do
    %{"region" => [x, y, w, h]} = label!("left_hud", "5559/6410")
    glyphs = Glyphs.segment(Pokex.ScreenFixtures.frame!("left_hud"), {x, y, w, h})

    assert length(glyphs) == 9
    assert glyphs == Enum.sort_by(glyphs, & &1.x0)
    assert Enum.all?(glyphs, fn g -> g.bitmap != [] and hd(g.bitmap) != [] end)
  end
end
```

- [ ] **Step 2: Run it** — FAIL (module undefined).
- [ ] **Step 3: Implement segment/3**

```elixir
defmodule Pokex.Vision.Glyphs do
  @moduledoc """
  Deterministic bitmap-font reader. The PXG client draws text as fixed pixel
  glyphs; reading is exact-match against a learned atlas — no OCR, no deps.
  Ground truth: the labeled screen fixtures (test/fixtures/glyphs/labels.json).
  """

  alias Pokex.Vision.Frame

  @ink 170

  def segment(%Frame{} = frame, {x, y, w, h}, _opts \\ []) do
    cols =
      for cx <- x..(x + w - 1) do
        for cy <- y..(y + h - 1), do: ink?(frame, cx, cy)
      end

    cols
    |> Enum.with_index()
    |> chunk_glyph_columns()
    |> Enum.map(fn col_group ->
      x0 = elem(hd(col_group), 1)
      x1 = elem(List.last(col_group), 1)
      bitmap = col_group |> Enum.map(&elem(&1, 0)) |> transpose() |> trim_rows()
      %{x0: x0 + x, x1: x1 + x, bitmap: bitmap}
    end)
  end

  defp chunk_glyph_columns(indexed_cols) do
    indexed_cols
    |> Enum.chunk_by(fn {col, _i} -> Enum.any?(col) end)
    |> Enum.filter(fn [{col, _} | _] -> Enum.any?(col) end)
  end

  defp transpose(cols), do: cols |> Enum.zip() |> Enum.map(&Tuple.to_list/1)

  defp trim_rows(rows) do
    rows
    |> Enum.drop_while(&(not Enum.any?(&1)))
    |> Enum.reverse()
    |> Enum.drop_while(&(not Enum.any?(&1)))
    |> Enum.reverse()
    |> Enum.map(fn row -> Enum.map(row, &if(&1, do: 1, else: 0)) end)
  end

  defp ink?(%Frame{width: w, rgba: rgba}, x, y) do
    <<r, g, b, _a>> = binary_part(rgba, (y * w + x) * 4, 4)
    max(r, max(g, b)) >= @ink
  end
end
```

- [ ] **Step 4: Run** — PASS. If glyph count ≠ 9, the region rect is off: nudge the label rect (±10px) per Task 1 Step 1 until exactly the string sits under it.
- [ ] **Step 5: Commit** `git add lib/pokex/vision/glyphs.ex test/pokex/vision/glyphs_test.exs && git commit -m "percepcao: glyph segmentation over the real fixtures"`

### Task 3: Atlas learn + exact reading

**Files:**
- Create: `lib/mix/tasks/glyphs.learn.ex`
- Create: `priv/glyphs/atlas.json` (generated, then committed)
- Modify: `lib/pokex/vision/glyphs.ex`
- Test: `test/pokex/vision/glyphs_test.exs`

**Interfaces:**
- Produces: `Glyphs.read_line(frame, region)` → `%{text: String.t(), confidence: float}` (confidence = matched_glyphs / total_glyphs; unknown glyph renders `"?"`); `Glyphs.read_int(frame, region)` → `integer | nil` (nil unless confidence == 1.0 and text is all digits); `Glyphs.read_coord(frame, region)` → `{int, int, int} | nil` (parses `"(x, y, z)"`); `Glyphs.atlas/0` (from `:persistent_term`, key `{:pokex, :glyph_atlas}`); `Glyphs.clear/0` for tests.
- Atlas JSON shape: `{"glyphs": {"<signature>": "<char>"}}` where signature = bitmap rows joined: rows of `0/1` joined by `,`, rows separated by `;` (e.g. `"010;111;010"`).
- `mix glyphs.learn` walks labels.json: segments each region, zips glyphs with the expected string's characters (spaces in expected = skipped gaps wider than 1.6× the median glyph gap — the segmenter never emits space glyphs), errors loudly on count mismatch, writes the union atlas.

- [ ] **Step 1: Failing tests — read every label back from the fixtures**

```elixir
  describe "reading (atlas)" do
    test "reads every labeled region back exactly" do
      for %{"fixture" => f, "region" => [x, y, w, h], "kind" => kind, "expected" => exp} <-
            Pokex.ScreenFixtures.labels() do
        frame = Pokex.ScreenFixtures.frame!(f)

        case kind do
          "int" ->
            assert Glyphs.read_int(frame, {x, y, w, h}) == String.to_integer(exp), "int #{f}/#{exp}"

          "coord" ->
            assert Glyphs.read_coord(frame, {x, y, w, h}) == {337, 46107, 4}

          "line" ->
            assert %{text: ^exp, confidence: 1.0} = Glyphs.read_line(frame, {x, y, w, h}), "line #{f}/#{exp}"
        end
      end
    end

    test "an unknown glyph degrades confidence and never guesses an int" do
      # all-white noise block: segments into glyphs the atlas has never seen
      rows = for _ <- 1..16, do: List.duplicate({255, 255, 255, 255}, 30)
      path = Pokex.PngFixtures.write!(Path.join(System.tmp_dir!(), "noise.png"), rows)
      {:ok, frame} = Pokex.Vision.Frame.from_png_file(path)

      assert Glyphs.read_int(frame, {0, 0, 30, 16}) == nil
      assert %{confidence: c} = Glyphs.read_line(frame, {0, 0, 30, 16})
      assert c < 1.0
    end
  end
```

- [ ] **Step 2: Run** — FAIL (read_line undefined).
- [ ] **Step 3: Implement the mix task and the readers**

```elixir
# lib/mix/tasks/glyphs.learn.ex
defmodule Mix.Tasks.Glyphs.Learn do
  @shortdoc "Builds priv/glyphs/atlas.json from the labeled screen fixtures"
  use Mix.Task

  @impl true
  def run(_argv) do
    labels = "test/fixtures/glyphs/labels.json" |> File.read!() |> Jason.decode!() |> Map.fetch!("labels")

    atlas =
      Enum.reduce(labels, %{}, fn %{"fixture" => f, "region" => [x, y, w, h], "expected" => exp}, acc ->
        {:ok, frame} = Pokex.Vision.Frame.from_png_file("test/fixtures/screen/#{f}.png")
        glyphs = Pokex.Vision.Glyphs.segment(frame, {x, y, w, h})
        chars = exp |> String.replace(" ", "") |> String.graphemes()

        if length(glyphs) != length(chars),
          do: Mix.raise("#{f}/#{exp}: #{length(glyphs)} glyphs vs #{length(chars)} chars — fix the label rect")

        glyphs
        |> Enum.zip(chars)
        |> Enum.reduce(acc, fn {g, char}, a ->
          Map.put(a, Pokex.Vision.Glyphs.signature(g.bitmap), char)
        end)
      end)

    File.mkdir_p!("priv/glyphs")
    File.write!("priv/glyphs/atlas.json", Jason.encode!(%{glyphs: atlas}, pretty: true))
    Mix.shell().info("atlas: #{map_size(atlas)} glifos")
  end
end
```

Readers added to `Pokex.Vision.Glyphs` (space recovery: a gap between consecutive glyphs wider than 1.6× the median gap inserts `" "`):

```elixir
  def signature(bitmap),
    do: bitmap |> Enum.map(fn row -> Enum.join(row, ",") end) |> Enum.join(";")

  def atlas do
    case :persistent_term.get({:pokex, :glyph_atlas}, nil) do
      nil ->
        path = Application.app_dir(:pokex, "priv/glyphs/atlas.json")
        atlas = path |> File.read!() |> Jason.decode!() |> Map.fetch!("glyphs")
        :persistent_term.put({:pokex, :glyph_atlas}, atlas)
        atlas

      atlas ->
        atlas
    end
  end

  def clear, do: :persistent_term.erase({:pokex, :glyph_atlas})

  def read_line(frame, region) do
    glyphs = segment(frame, region)
    atlas = atlas()

    gaps =
      glyphs |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> b.x0 - a.x1 end)

    median_gap = median(gaps)

    {chars, hits} =
      glyphs
      |> Enum.with_index()
      |> Enum.reduce({[], 0}, fn {g, i}, {out, hits} ->
        spaced =
          if i > 0 and median_gap != nil and
               g.x0 - Enum.at(glyphs, i - 1).x1 > median_gap * 1.6,
             do: [" " | out],
             else: out

        case Map.get(atlas, signature(g.bitmap)) do
          nil -> {["?" | spaced], hits}
          char -> {[char | spaced], hits + 1}
        end
      end)

    n = max(length(glyphs), 1)
    %{text: chars |> Enum.reverse() |> Enum.join(), confidence: hits / n}
  end

  def read_int(frame, region) do
    case read_line(frame, region) do
      %{text: text, confidence: 1.0} ->
        if text =~ ~r/^\d+$/, do: String.to_integer(text), else: nil

      _uncertain ->
        nil
    end
  end

  def read_coord(frame, region) do
    case read_line(frame, region) do
      %{text: text, confidence: 1.0} ->
        case Regex.run(~r/^\((\d+),\s?(\d+),\s?(\d+)\)$/, text) do
          [_, x, y, z] -> {String.to_integer(x), String.to_integer(y), String.to_integer(z)}
          nil -> nil
        end

      _uncertain ->
        nil
    end
  end

  defp median([]), do: nil
  defp median(list), do: list |> Enum.sort() |> Enum.at(div(length(list), 2))
```

- [ ] **Step 4: Run** `mix glyphs.learn` then the tests — PASS. Commit atlas + code. Add `Glyphs.clear()` to `test/test_helper.exs`-adjacent `on_exit` only in tests that swap atlases (none yet).
- [ ] **Step 5: Commit** `git add lib/mix/tasks/glyphs.learn.ex lib/pokex/vision/glyphs.ex priv/glyphs/atlas.json test/pokex/vision/glyphs_test.exs && git commit -m "percepcao: glyph atlas learn + exact deterministic reading"`

### Task 4: Lexicon closing for pokémon names

**Files:**
- Modify: `lib/pokex/vision/glyphs.ex`
- Test: `test/pokex/vision/glyphs_test.exs`

**Interfaces:**
- Produces: `Glyphs.closest_name(raw, lexicon)` → `String.t() | nil` — exact case-insensitive match first; else the unique lexicon entry with Levenshtein distance ≤ 2 treating `?` as a free wildcard (distance 0 against any char); ties or nothing within 2 → nil. `Glyphs.read_name(frame, region, lexicon)` → `String.t() | nil` composing read_line + closest_name (accepts confidence < 1.0 — that is the POINT of the lexicon).

- [ ] **Step 1: Failing tests**

```elixir
    test "closest_name closes a corrupted read against the pokedex lexicon" do
      lexicon = ["Pidgeot", "Pidgey", "Seadra", "Shiny Seadra"]
      assert Glyphs.closest_name("Pidgeot", lexicon) == "Pidgeot"
      assert Glyphs.closest_name("Pi?geot", lexicon) == "Pidgeot"
      assert Glyphs.closest_name("S?adra", lexicon) == "Seadra"
      assert Glyphs.closest_name("???????????", lexicon) == nil
      assert Glyphs.closest_name("Pidge?", lexicon) == nil  # Pidgeot × Pidgey tie → nil
    end

    test "read_name reads Pidgeot from the battle list fixture" do
      %{"region" => [x, y, w, h]} =
        Enum.find(Pokex.ScreenFixtures.labels(), &(&1["expected"] == "Pidgeot"))

      assert Glyphs.read_name(Pokex.ScreenFixtures.frame!("right_panel"), {x, y, w, h},
               Pokex.Pokedex.names()) == "Pidgeot"
    end
```

(`Pokex.Pokedex.names/0` exists — it feeds the /pokedex datalist; check `lib/pokex/pokedex.ex` for the exact function name and adapt the call, not the behavior.)

- [ ] **Step 2: Run — FAIL. Step 3: Implement:**

```elixir
  def read_name(frame, region, lexicon) do
    %{text: raw} = read_line(frame, region)
    closest_name(raw, lexicon)
  end

  def closest_name(raw, lexicon) do
    down = String.downcase(raw)

    case Enum.find(lexicon, &(String.downcase(&1) == down)) do
      nil ->
        scored =
          lexicon
          |> Enum.map(&{&1, distance(String.graphemes(down), String.graphemes(String.downcase(&1)))})
          |> Enum.filter(fn {_n, d} -> d <= 2 end)
          |> Enum.sort_by(&elem(&1, 1))

        case scored do
          [{name, d}] -> if unique_at?(scored, d), do: name, else: nil
          [{name, d}, {_second, d2} | _] when d < d2 -> name
          _tie_or_empty -> nil
        end

      exact ->
        exact
    end
  end

  defp unique_at?(scored, d), do: Enum.count(scored, fn {_n, sd} -> sd == d end) == 1

  # DP Levenshtein; "?" read from an unknown glyph matches ANY char at cost 0.
  defp distance(a, b) do
    row0 = Enum.to_list(0..length(b))

    a
    |> Enum.with_index(1)
    |> Enum.reduce(row0, fn {ca, i}, prev ->
      Enum.reduce(Enum.with_index(b, 1), {[i], prev}, fn {cb, j}, {row, prev} ->
        cost = if ca == cb or ca == "?", do: 0, else: 1
        val = min(min(hd(row) + 1, Enum.at(prev, j) + 1), Enum.at(prev, j - 1) + cost)
        {[val | row], prev}
      end)
      |> elem(0)
      |> Enum.reverse()
    end)
    |> List.last()
  end
```

**Step 4: Run — PASS.**
- [ ] **Step 5: Commit** `git commit -m "percepcao: lexicon closing — nomes fecham contra a Pokédex"` (stage the two files explicitly). **F1 done → PR:** `gh pr create` + merge (title: "Percepção F1: leitor de glifos determinístico"), full suite green first.

### Task 5: Layout profile + anchor extraction + locate

**Files:**
- Create: `priv/layouts/ultrawide_3440x1440.json`
- Create: `priv/layouts/anchors/` (3 PNGs, extracted from the full fixture)
- Create: `lib/pokex/layout.ex`
- Test: `test/pokex/layout_test.exs`

**Interfaces:**
- Produces: `Layout.locate(frame)` → `{:ok, %Layout.Fix{anchors: %{battle: {x,y}, minimap: {x,y}, hotbar: {x,y}}, regions: %{battle_list: rect, battle_header: rect, minimap: rect, minimap_coord: rect, hud_bottom: rect, pokemon_hp: rect, level: rect, food: rect, fishing: rect, slot_f1: rect, slot_f2: rect, slot_e: rect, slot_s_q: rect, team_rows: [rect x5], arena: rect}}} | {:error, {:anchor_not_found, name}}`; `Layout.locate/0` captures the full screen via `Pokex.Bots.Capture` then delegates. `Layout.profile/0` reads the JSON. Rect = `{x, y, w, h}` absolute screen px.
- Profile JSON: `{"resolution": [3440, 1440], "anchors": {"battle": {"template": "anchors/battle_header.png", "search": [3140, 400, 300, 200]}, ...}, "regions": {"battle_list": {"anchor": "battle", "offset": [0, 60], "size": [300, 285]}, ...}}` — every region = anchor position + offset.
- Anchor extraction: a one-off script step (below) cuts the templates from the fixture; templates must be ≥ 24×16 px of UNIQUE chrome (the 🔥+"Battle" header text block, the minimap's top-left frame corner including the coord strip's left edge, the "Sto" tab). Search windows are generous (±100px) so a moved dock still lands.

- [ ] **Step 1: Extract anchors from the fixture** (adapt the pure-python codec in `test fixtures` history, or use Elixir: load the frame, cut sub-rects, re-encode with `Pokex.PngFixtures.write!`). Battle header at ≈ (3186, 460) 120×30; minimap frame corner ≈ (3150, 0) 60×34 (includes coord strip start); hotbar "Sto" tab ≈ (1206, 1372) 34×40 on the full image. Verify each template by eye before committing.
- [ ] **Step 2: Failing test — locate on the fixture finds all three anchors and the derived battle_list region reads "Battle"**

```elixir
defmodule Pokex.LayoutTest do
  use ExUnit.Case, async: true

  alias Pokex.Layout

  test "locate on the real fixture finds the anchors and derives sane regions" do
    frame = Pokex.ScreenFixtures.frame!("ultrawide_3440x1440_full")

    assert {:ok, fix} = Layout.locate(frame)
    assert %{battle: {bx, by}} = fix.anchors
    assert_in_delta bx, 3186, 12
    assert_in_delta by, 460, 12

    # the derived header region must literally read "Battle" — locate's self-validation
    assert %{text: "Battle"} =
             Pokex.Vision.Glyphs.read_line(frame, fix.regions.battle_header)
  end

  test "a frame without the game errors loudly" do
    black = Pokex.FrameFixtures.of(400, 300, fn _x, _y -> {0, 0, 0} end)
    assert {:error, {:anchor_not_found, _}} = Layout.locate(black)
  end
end
```

- [ ] **Step 3: Implement Layout** — template search = exact RGB match of the template's pixels at every offset inside the search window (row-stride comparison over the Frame binary; break on first match; ~40 lines). `locate/1` = find anchors → apply region offsets from the profile → run the "Battle" glyph self-validation → Fix. `locate/0` = `Capture.frame({0, 0, w, h}, "layout_locate.png")` with `{w, h}` from the profile resolution.
- [ ] **Step 4: Run — PASS. Step 5: Commit** `"percepcao: layout profile + âncoras + locate na fixture real"`.

### Task 6: Layout fact, persistence and Calibration merge

**Files:**
- Modify: `lib/pokex/layout.ex`, `lib/pokex/calibration.ex`
- Test: `test/pokex/layout_test.exs`, `test/pokex/calibration_test.exs`

**Interfaces:**
- Produces: `Layout.apply!/0` — runs locate/0, `WorldState.put(:layout, fix_map, now)`, persists `~/.pokex/layout_fix.json` (Home.dir pattern); `Layout.current/0` → Fix | nil (WorldState first, file fallback). `Calibration.load/0` gains the merge: when a Layout fix exists, HUD-derived fields (`battle_region`, `skill_bar_region` if present in profile, plus the new region map exposed as `calib.layout`) come from the fix; wizard fields for world points (`water_point`, `pokemon_spot_point`, `escape_point`, `mini_game_region`) stay from the wizard file. Existing consumers keep working unchanged when no fix exists (backwards-compatible).
- Tests: merge behavior with a fake fix on disk (tmp_dir home); no fix → identical to today (regression guard on existing calibration tests).

Steps follow the same TDD cycle as Task 5 (failing test on merge precedence → implement → green → commit `"percepcao: layout fact + merge na calibração — wizard só pra pontos de mundo"`).

### Task 7: Auto re-locate + panel banner

**Files:**
- Modify: `lib/pokex/perception/feed.ex` (failure-streak hook), `lib/pokex/layout.ex`, `lib/pokex_web/live/panel_live.ex`
- Test: `test/pokex/layout_test.exs`, `test/pokex_web/live/panel_live_test.exs`

**Interfaces:**
- Produces: when a feed's failure streak hits `feed_failure_warn_streak` (existing setting), it now ALSO broadcasts `{:layout_suspect, key}` on topic `"layout"`; a small always-on `Layout.Sentinel` GenServer (app child, `:layout_sentinel_active` env flag false in test — ShinyGuard pattern) debounces those (1 re-locate per 30s max), runs `Layout.apply!/0`, and broadcasts `{:layout, %{ok?: bool, reason}}` on `"layout"`. Panel subscribes: `ok?: false` → persistent banner `id="layout-banner"` "layout não encontrado — o jogo está em fullscreen no monitor principal?"; feeds keep holding (they already hold on capture failure).
- Panel test: broadcast `{:layout, %{ok?: false, reason: :anchor_not_found}}` → banner appears; `ok?: true` → banner gone.

TDD cycle; commit `"percepcao: re-locate automático + banner — descalibragem manual morta"`. **F2 done → PR + merge** (full suite green).

### Task 8: Interpret.battle upgrade — enemies with names and HP

**Files:**
- Modify: `lib/pokex/perception/interpret.ex`
- Test: `test/pokex/perception/interpret_test.exs`

**Interfaces:**
- Consumes: `Glyphs.read_name/3`, `Layout.current/0` (row name rects derive from the battle_list region: each row is 47px tall at scale 1.0 — same geometry `Calibration.row_band_geometry/2` already computes; name sub-rect = x+64..x+200 of the row, the green HP bar sits 20px below the name baseline, 4px tall).
- Produces: battle obs gains `enemies_detail: [%{row: int, name: String.t() | nil, hp_pct: float | nil, shiny?: bool}]` — one entry per DETECTED enemy row (existing `enemies` list); `hp_pct` = green-ish (g > r and g > 90) fraction of the bar strip vs its full width; `shiny?` = row ∈ existing `shiny_rows`. Reading failure → `name: nil` (never guess); obs stays cheap when Layout absent (`enemies_detail: []`).
- Test: on the `right_panel` fixture geometry (battle_region crop offsets from the fixture map), the Pidgeot row yields `%{name: "Pidgeot", shiny?: false}` and `hp_pct > 0.9` (the fixture bar is nearly full).

TDD cycle; commit `"percepcao: battle lê nome + HP do inimigo — enemies_detail"`.

### Task 9: `:hud` feed

**Files:**
- Create: `lib/pokex/perception/interpret/hud.ex`
- Modify: `lib/pokex/perception.ex` (feed spec), `lib/pokex/settings.ex`
- Test: `test/pokex/perception/interpret_hud_test.exs`

**Interfaces:**
- Produces: `Interpret.Hud.interpret(frame, calib, settings)` → `%{level: int | nil, food: int | nil, fishing: int | nil, slots: %{f1: int | nil, f2: int | nil, e: int | nil, s_q: int | nil}}`. Region split (one capture per feed): `:hud` covers ONLY the bottom bar (`hud_bottom` rect from Layout); the active pokémon HP and team rows belong to the `:team` feed (Task 10), whose single region is the left column (x 0..360, y 960..1440).
- Settings seeds: `feed_hud_ms: 500`, `feed_team_ms: 500`, `feed_minimap_ms: 250`.
- Test: against the `hud_bottom` fixture with a fake Layout fix whose rects are the Task 1 label rects → exact values `%{level: 90, food: 1525, fishing: 96, slots: %{f1: 322, f2: 36, e: 7, s_q: 43}}`.

TDD cycle; commit `"percepcao: feed :hud — level, comida, pesca e estoques em números"`.

### Task 10: `:team` feed (left column: active HP + team rows)

**Files:**
- Create: `lib/pokex/perception/interpret/team.ex`
- Modify: `lib/pokex/perception.ex`
- Test: `test/pokex/perception/interpret_team_test.exs`

**Interfaces:**
- Produces: `%{pokemon_hp: {5559, 6410} | nil, rows: [%{slot: 2..6, present?: bool, hp_pct: float | nil}]}`. Row geometry from Layout (`team_rows` rects); `present?` = the row's green bar strip has ≥ 10 green px; `hp_pct` = green fraction of the bar width. On the `left_hud` fixture: `pokemon_hp == {5559, 6410}`, 5 rows present, all `hp_pct > 0.9`.

TDD cycle; commit `"percepcao: feed :team — vida do ativo + fileiras C+2..C+6"`.

### Task 11: `:minimap` feed with sanity gates

**Files:**
- Create: `lib/pokex/perception/interpret/minimap.ex`
- Modify: `lib/pokex/perception.ex`
- Test: `test/pokex/perception/interpret_minimap_test.exs`

**Interfaces:**
- Produces: `%{pos: {x, y, z} | nil}` via `Glyphs.read_coord` on the `minimap_coord` rect. Sanity INSIDE the interpreter state (arity-4 interpret like Corpses — see `Perception.feed_specs`): z must be 0..15; a jump of > 50 tiles on either axis vs the previous GOOD read → return `%{pos: nil}` and KEEP the previous internal last-good (one bad frame never poisons; two consecutive consistent reads re-baseline).
- Test: fixture read = `{337, 46107, 4}`; a synthetic frame with garbled digits → `pos: nil`; jump gate exercised with two synthetic frames.

TDD cycle; commit `"percepcao: feed :minimap — a coordenada textual vira fato"`.

### Task 12: `World.snapshot/0` + /world v2

**Files:**
- Create: `lib/pokex/world.ex`
- Modify: `lib/pokex_web/live/world_live.ex`
- Test: `test/pokex/world_test.exs`, `test/pokex_web/live/world_live_test.exs`

**Interfaces:**
- Produces: `World.snapshot/0` → `%World.Snapshot{me: %{pokemon_hp, level, food, fishing}, inventory: %{f1, f2, e, s_q}, team: [rows], enemies: [enemies_detail], pos, engaged?, shiny?, captured_at}` — read from WorldState with the existing staleness gates (`WorldState.get/2`); missing/stale fact → nil fields, snapshot always returns (never raises). `/world` renders the snapshot live (subscribes to the world topic; re-renders throttled 500ms).
- Tests: seed WorldState facts → snapshot assembles; stale facts → nils. LiveView test: page shows the seeded values.

TDD cycle; commit; **F3 done → PR + merge.**

### Task 13: StockAlerts worker + panel badges

**Files:**
- Create: `lib/pokex/bots/stock_alerts.ex`
- Modify: `lib/pokex/application.ex` (child), `lib/pokex/settings.ex`, `lib/pokex_web/live/panel_live.ex`
- Test: `test/pokex/bots/stock_alerts_test.exs`, panel test additions

**Interfaces:**
- Settings seeds: `stock_alerts_enabled: true`, `stock_alert_f1: 30, stock_alert_f2: 10, stock_alert_e: 5, stock_alert_s_q: 10` (0 disables a slot).
- Worker: ShinyGuard pattern EXACTLY — env flag `:stock_alerts_active` false in test; **subscribe to `Perception.topic()` in init** (PR #48 lesson: attach creates demand, PubSub delivers) + attach `:hud` on a slow poll while enabled. On `{:world, :hud, obs}`: for each armed slot, count crossed BELOW threshold → broadcast `{:rule_alarm, "estoque baixo: F1 com 28 (limiar 30)"}` once + `{:stock, %{slot, count, low?: true}}` on topic `"stock"`; re-arm when count rises above threshold. nil counts (bad read) are IGNORED — never alarm on a misread.
- Panel: subscribes `"stock"`; low slot → persistent red badge in the radar column (`id="stock-badge-f1"` etc.) until `low?: false`.
- Tests deliver obs via PubSub broadcast on `Perception.topic()` (never send/2): threshold crossing fires once; refill re-arms; nil ignored; disabled slot silent.

TDD cycle; commit `"percepcao: alerta de estoque — F1/F2/E/S+Q gritam antes de lazerar"`; **F4 → PR + merge.**

### Task 14: Team v3 — slot mapping

**Files:**
- Modify: `lib/pokex/pokedex/team.ex`, the /time LiveView (find it: `grep -rn "def render" lib/pokex_web/live | grep -i time`)
- Test: `test/pokex/pokedex/team_test.exs`, /time LiveView test

**Interfaces:**
- Produces: team member map gains `"slot" => 2..6 | nil`; `Team.set_slot(name, slot)` (moving a slot reassigns uniquely — setting slot 3 on B clears it from A); `Team.by_slot/0` → `%{2 => member | nil, ..., 6 => member | nil}`. v2 files load with slot nil (compat test). /time UI: a slot selector (C+2..C+6) chip per team member.

TDD cycle; commit `"combos: slots C+N no time — a ponte /time ↔ jogo"`.

### Task 15: Combo engine (pure)

**Files:**
- Create: `lib/pokex/combos.ex`
- Modify: `lib/pokex/settings.ex`
- Test: `test/pokex/combos_test.exs`

**Interfaces:**
- Produces: `%Combos.Combo{name: String.t(), trigger: {:enemy_element, String.t()} | {:enemy_species, String.t()}, steps: [{:swap, 2..6} | {:swap_counter} | {:skill, String.t()} | {:wait, pos_integer}]}`; `Combos.match(combos, enemy_name)` → Combo | nil (species beats element; element resolved via `Pokedex.get(enemy_name).elements`); `Combos.resolve_steps(combo, enemy_name, team_by_slot)` → concrete `[{:swap, n} | {:skill, k} | {:wait, ms}]` with `:swap_counter` resolved by the matchup scorer (reuse `Pokedex.Team.hunt_suggestions` internals — extract the member-vs-species scoring into a public `Team.best_counter(enemy_name)` → slot | nil); unresolvable counter → `:skip` (combo doesn't run).
- Settings: `combos_enabled: false`, `combo_sing_wait_ms: 2500`, seed combo list stored as data (settings value `combos: [%{name: "sing", trigger: ..., steps: [...]}]` is NOT a settings scalar — store in `~/.pokex/combos.json` via a `Combos.Store` with the Team file pattern; seeded on first read with the sing combo: `%{name: "sing", trigger: {:enemy_element, "Water"}, steps: [{:swap_member, "Jigglypuff"}, {:skill, "4"}, {:wait, :combo_sing_wait_ms}, {:swap_counter}]}` — `{:swap_member, name}` resolves to the member's slot at runtime (nil slot → `:skip`); the "Water" default trigger is a starting point Lucas edits in the UI later).
- Pure tests: match precedence, counter resolution, skip path, v1 sing combo resolves against a fixture team.

TDD cycle; commit `"combos: motor puro — gatilho, resolução de counter, sequência"`.

### Task 16: Combo runner in the combat path

**Files:**
- Modify: `lib/pokex/bots/combat/worker.ex` (read the module doc first — the tab/fight state machine), `lib/pokex_web/live/panel_live.ex` (combos toggle)
- Test: `test/pokex/bots/combat/worker_test.exs` additions

**Interfaces:**
- On combat ENGAGE edge with `combos_enabled` and an enemy name in `World.snapshot().enemies` matching a combo: run the resolved steps through the Body `:high` lane (swap = key `c+N` via the existing key-chord support in `Pokex.Bots.Body` — check `body.ex` for the chord format the fishing/skill macros use), `{:wait, ms}` = `Process.send_after` step advance, NOT a sleep in the GenServer. Abort instantly on: kill broadcast, combat disengage, panic latch, focus loss (subscribe to what Combat.Worker already tracks). One combo per engagement (re-arm on next engage).
- Tests with Body fake: engage with matching enemy → chord sequence lands in order with the wait between; kill mid-combo → remaining steps never fire; toggle off → nothing.

TDD cycle; commit `"combos: runner no combate — sing da Jigglypuff de fábrica"`; **F5 → PR + merge.**

### Task 17: `Body.minimap_step/2`

**Files:**
- Modify: `lib/pokex/bots/body.ex`, `priv/layouts/ultrawide_3440x1440.json` (minimap center + px-per-tile), `lib/pokex/settings.ex` (`minimap_px_per_tile: 4` — MEASURE: walk 10 tiles on a straight road and divide; seed with 4, Lucas validates live)
- Test: `test/pokex/bots/body_test.exs` additions

**Interfaces:**
- Produces: `Body.minimap_step(dx, dy)` → left-click at `minimap_center + {dx, dy} * px_per_tile`, clamped INSIDE the minimap region minus a 6px border, `:normal` lane, behind InputGate/Focus like every actuation. Returns `{:ok, {screen_x, screen_y}} | {:error, :no_layout}`.
- Tests with Rig fake: click lands at the computed point; clamping; no layout → error, no click.

TDD cycle; commit `"percepcao: primitivo minimap_step — a porta do cavebot"`; **F6 → PR + merge.**

### Task 18: Wrap-up — full verification + docs

- [ ] Full suite: `mix test` — 0 failures. `mix format --check-formatted`, `mix compile --warnings-as-errors`.
- [ ] Update `docs/refactor/handoff-kizubot.md` (or the current handoff doc) with a short "Percepção Total" section: what exists now, the fixture ground-truth workflow (`mix glyphs.learn`), and that cavebot is unblocked (pos fact + minimap_step + snapshot).
- [ ] Final PR + merge. Report to Lucas: what landed, what needs LIVE validation (glyph reads on HIS running client, re-locate trigger, sing combo timing, px_per_tile).

## Live-validation checklist (Lucas, after merge)
1. Boot with the game fullscreen → panel shows NO layout banner; /world shows level 90, food, fishing 96, slots, position updating.
2. Move a dock panel on purpose → feeds hold, banner appears, re-locate recovers after restoring.
3. Hunt: enemy names appear in /world; stock alert fires when a slot dips below threshold.
4. Set team slots in /time; enable combos; engage a Water enemy → sing combo runs; panic corner aborts it.
