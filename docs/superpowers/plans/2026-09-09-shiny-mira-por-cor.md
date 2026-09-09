# A mira por cor no capturador (PR 1) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After the guard announces a shiny, the Catcher looks for its CORPSE by the same colour, in any `player_mode`, and hands the ball to the existing `Logic` — one ball in flight, confirmation by absence, retry, give-up — with a fresh frame every time.

**Architecture:** New pure module `Pokex.Bots.Catcher.ShinyAim`: frame + armed colour rules + forbidden boxes + the eye's `:crowd` reading → candidates; a candidate is a CORPSE when no creature body (hostile or pet) stands within one tile of the blob, and it must be seen on two consecutive scans (`steady/3`). `Catcher.Worker` gains an *aim session* (`aim: %{since, prev}`) opened by `{:shiny_seen, _}`, polled on its own timer at `special_color_scan_ms`, closed by a TTL of 90 s or by the Logic having nothing pending after a throw. The aim obs is tagged `source: :shiny_aim`, which bypasses the `player_mode == "still"` and `combat_engaged?` gates (the "no body within a tile" test replaces the live-sprite worry), never the InputGate or the mini-game. Ball choice stays `Balls.key_for(name)`.

**Tech Stack:** Elixir, ExUnit, `Pokex.Vision.{ColorMark, ColorRules, Frame}`, `Pokex.Bots.ShinyGuard.forbidden_boxes/3` (made public), `Pokex.Perception.WorldState`.

## Global Constraints

- English identifiers/comments/test names (no accents in test names); pt-BR only in journal/feed phrases.
- Worktree `.claude/worktrees/shiny-na-cacada`; never `mix run`; run only the touched test files; full `mix precommit` + `mix credo` + `mix dialyzer` (separately) before the PR.
- Inert by construction until he teaches a rule and enables `shiny_guard_enabled`: no `{:shiny_seen, _}` → no aim session → nothing changes.
- No new settings. Cadence reuses `special_color_scan_ms`; tolerance reuses `corpse_match_tolerance_px`; the crowd fact is read with its own max age `@crowd_max_age_ms 1_500` (the eye walks at 1 s).

---

### Task 1: `ShinyGuard.forbidden_boxes/3` goes public

**Files:** Modify `lib/pokex/bots/shiny_guard.ex` (`defp forbidden_boxes` → `def`, with `@doc`).

- [ ] Step 1: change `defp forbidden_boxes(calib, %Frame{scale: scale}, {rx, ry, _w, _h})` to `def`, add `@doc "The character's and the standing pokémon's 3×3-tile boxes, in FRAME pixels of `region`: the aim and the guard refuse the same ground."`.
- [ ] Step 2: `mix test test/pokex/bots/shiny_guard_test.exs` → green.
- [ ] Step 3: commit `git add lib/pokex/bots/shiny_guard.ex` — "as caixas proibidas da guarda viram públicas: a mira recusa o mesmo chão".

### Task 2: `Catcher.ShinyAim` — pure judge and steady

**Files:** Create `lib/pokex/bots/catcher/shiny_aim.ex`; Test `test/pokex/bots/catcher/shiny_aim_test.exs`.

**Interfaces (produces):**
- `ShinyAim.judge(frame, region, rules, forbidden, crowd, tile_px) :: [candidate]` where `candidate = %{name, px, point: {sx, sy}, in_frame: {fx, fy}}` — only blobs ≥ `rule.min_px` with **no body within `tile_px`** (Chebyshev) in `crowd.hostiles ++ [crowd.pet]`; `crowd == nil` → `[]`.
- `ShinyAim.steady(candidates, prev, tolerance) :: [candidate]` — candidates whose point is within `tolerance` of one in `prev`.
- `ShinyAim.obs(candidates, region, at) :: obs` — `%{scanning?: true, source: :shiny_aim, corpses: [point], known: %{point => %{name, score: px}}, region, captured_at: at}`.
- `ShinyAim.scan(opts) :: obs | nil` — captures via `opts[:capture]` (default `&Capture.frame/2`, file `"shiny_aim.raw"`), rules via `ColorRules.armed/0`, crowd via `WorldState.get(:crowd, @crowd_max_age_ms, now)`; blind → `%{scanning?: false, source: :shiny_aim, reason}`.

- [ ] Step 1: tests (synthetic frame helper copied from the guard test; region `{100, 100, 300, 300}`, tile 40, blob 14×14 at (10,10) → screen `{117, 117}`):
  - "a blob with no body near it is a corpse candidate in screen points"
  - "a blob with a hostile body within a tile is a living creature, not a corpse"
  - "a blob with the pet's body within a tile is not a corpse"
  - "without an eye reading nothing is a corpse"
  - "a blob inside a forbidden box is not seen"
  - "steady keeps only candidates seen on the previous scan"
- [ ] Step 2: run, expect failures (module missing).
- [ ] Step 3: implement (code in the module; see repository file after this task).
- [ ] Step 4: run → green. Step 5: commit both files — "a mira por cor: a mancha sem corpo vivo a um tile é o corpo do shiny, e só depois de duas fotos".

### Task 3: the aim session in `Catcher.Worker`

**Files:** Modify `lib/pokex/bots/catcher/worker.ex` (state, `start_link` option `aimer`, `{:shiny_seen, _}`, new `:aim` tick, `advance/2`, `do_advance/2`, `capture_allowed?/1`); Test `test/pokex/bots/catcher/worker_test.exs`.

**Interfaces:** `Worker` option `aimer: (-> obs | nil)` default `&ShinyAim.scan/0`. State `aim: nil | %{since: ms, prev: [candidate]}`.

Rules, in one place:

| event | effect |
|---|---|
| `{:shiny_seen, _}` with an armed logic | `shiny_pending?: true`, `aim: %{since: now, prev: []}`, `:aim` in `special_color_scan_ms` |
| `:aim` with `aim != nil` and `now - since < @aim_ttl_ms (90_000)` | `obs = aim_obs(state)`; `advance(state, obs)`; reschedule |
| `:aim` past the TTL | `aim: nil`, `shiny_pending?: false`, log `:macro` "🌟 shiny visto, corpo não achado em 90s — bola guardada" |
| after a throw, `Logic.pending == 0` and `shiny_pending? == false` | `aim: nil` (session over) |
| `advance/2` with `%{source: :shiny_aim}` | goes to `do_advance/2` whatever the mode |
| `do_advance/2` with `%{source: :shiny_aim}` | skips the `combat_engaged?` clause; keeps `capture_allowed?` and the InputGate |
| `capture_allowed?/1` | `capture_enabled or (aim != nil and shiny_always_ball)` |

`aim_obs/1`: `nil` when `aim == nil` or the mini-game plays; else `state.aimer.()`, blind narrated once at `:debug`, candidates passed through `ShinyAim.steady(cands, aim.prev, corpse_match_tolerance_px)`; `aim.prev` updated with the raw candidates; a non-empty steady set logs `:macro` "🌟 corpo do #{name} em x,y — bola" once per point.

- [ ] Step 1: tests in `worker_test.exs` (mode `"hunt"`, `aimer` reads `WorldState.get(:shiny_aim, ...)` like the scanner):
  - "in hunt mode a shiny sighting aims by colour and throws at :high" — put an aim obs with one candidate, send `{:shiny_seen, %{}}`, assert `{:performed, :high, [{:move, {117, 117}} | _]}` within 3 s (two ticks at `special_color_scan_ms` stashed to 50).
  - "the aim ignores the fight gate: a combat still engaged does not hold the shiny ball" — send `{:combat, %{state: :fighting}}` first, same assertion.
  - "in hunt mode without a sighting nothing flies" — aim obs present, no `{:shiny_seen}`, `refute_receive {:performed, _, _}, 500`.
  - "the aim session ends when the shiny is not found" — stash `special_color_scan_ms: 50`; use a 300 ms TTL via `Application.put_env(:pokex, :shiny_aim_ttl_ms, 300)` read at init; assert `Worker.status(worker).aim? == false` eventually and the macro log.
- [ ] Step 2: run, expect failures. Step 3: implement. Step 4: run → green. Step 5: commit — "o capturador mira o shiny pela cor em qualquer modo: sessão de mira aberta pelo avistamento, fechada pela bola ou por 90s".

### Task 4: gate, docs, PR

- [ ] `mix precommit`; `mix credo`; `mix dialyzer`.
- [ ] `docs/shiny/plano-shiny-por-cor.md` header: one line pointing at PR 1.
- [ ] push, `gh pr create`, wait green, merge.
