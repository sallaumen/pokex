# A engine segura os pés pra bola (PR 2) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** While the Catcher is aiming at a shiny's corpse, the brain holds the route (feet only — fire and revive unchanged) for at most `engine_capture_hold_ms`, says why in one sentence, and the bench proves the hold buys the ball without costing a death or a revive.

**Architecture:** The Catcher publishes the fact `:capture` (`%{aiming?, pending, corpses}`) on every aim tick and clears it when the session closes. `Engine.Worker` reads it into the picture as `capturing?`; `Engine.Logic` gets an OVERLAY in `decide/1` (same shape as `hold_until_reset_seen/2`): a walking order under `capturing?` becomes `phase: :capturing, route: :hold` with the why "shiny no chão — segurando a rota pra bola (Ns)", until the ceiling. The sim grows a corpse: `World` keeps dead bosses as corpses for `corpse_ms`, `Hands` throws the ball after the road has held `ball_ms` in a row, a lost corpse counts `balls_lost`, and `Verdict` gains the promise `:captura`. Scenario `shiny-no-chao` declares it.

**Tech Stack:** Elixir, ExUnit, `Pokex.Bots.Engine.{Logic, Situation, Worker, Orders, Config}`, `Pokex.Sim.{World, Hands, Bench, Verdict, Scenario, Runner}`.

## Global Constraints

- English identifiers/comments/test names (no accents in test names); pt-BR in feed/journal phrases and scenario prose.
- Worktree only; never `mix run`; run only touched test files; `mix precommit` + `mix credo` + `mix dialyzer` separately before the PR.
- One new setting: `engine_capture_hold_ms` (default 6_000, range 0..15_000, 0 = off), knob `capture_hold_ms`; a `/config` row next to `engine_bunch_ms`.
- Fire and revive are NEVER changed by the hold. Red band is never held.
- The bench never derives what production decides (`contrato_test`): the bench feeds `capturing?` from the world and calls `Logic.step`.

---

### Task 1: the brain holds the road (`Engine.Logic` + `Situation` + `Config` + settings)

**Files:** Modify `lib/pokex/bots/engine/logic.ex` (`decide/1`, new `hold_for_capture/2`), `lib/pokex/bots/engine/situation.ex` (type + `capturing?:`), `lib/pokex/bots/engine/orders.ex` (`:capturing` phase), `lib/pokex/bots/engine/config.ex` (`capture_hold_ms: :engine_capture_hold_ms`), `lib/pokex/settings.ex` (default + range), `lib/pokex_web/live/config_live.ex` (row). Tests: `test/pokex/bots/engine/logic_test.exs`, `test/pokex/bots/engine/situation_test.exs`.

- [ ] Tests (logic): describe "the shiny on the ground holds the road":
  - walking world (`situation(%{enemies: 0, capturing?: true})`, hunt walking) at 10_000 → `phase == :capturing`, `route == :hold`, `why =~ "shiny no chão"`; same logic at 10_000 + 6_500 → `route == :go`, `phase != :capturing`.
  - `capturing?: false` → never `:capturing`; a fresh `capturing?: true` after a gap restarts the clock (since is dropped when false).
  - `own_hp: 10` (red band) with `capturing?: true` → not held (`phase != :capturing`).
  - fire is untouched: a fighting order (`enemies: 4`) with `capturing?: true` keeps `route: :hold` as it was and `phase` stays the fight's — the overlay only touches `route: :go` orders.
- [ ] Test (situation): `inputs(%{battle: battle(~w(Electrode)), capturing?: true})` → `capturing?: true`; missing → `false`.
- [ ] Implement: `@held_by_capture [:travelling, :gathering, :sizing, :bunching, :skipping]`; `hold_for_capture/2` inserted in `decide/1` after `shadow_siege` and before `with_park`; `logic.since[:capture_hold]` is the clock.
- [ ] Run both test files → green; commit — "o cérebro segura os pés pro corpo do shiny: só a rota, com teto, e a frase diz por quê".

### Task 2: the fact `:capture` — Catcher publishes, Engine reads

**Files:** Modify `lib/pokex/bots/catcher/worker.ex` (`:aim` tick publishes; `close_aim/1` clears), `lib/pokex/bots/engine/worker.ex` (`inputs/4` gets `capturing?: capturing?(now)`). Tests: `test/pokex/bots/catcher/worker_test.exs`, `test/pokex/bots/engine/worker_test.exs`.

- [ ] Catcher test: after `{:shiny_seen, _}` in hunt mode, `WorldState.get(:capture, 5_000, now)` answers `{:ok, %{aiming?: true}}`; after the TTL closes the session, `%{aiming?: false}`.
- [ ] Engine worker test: `WorldState.put(:capture, %{aiming?: true, pending: 1, corpses: []}, now)` → the filed decision on a walking hunt has `phase: :capturing` (or: the `:orders` fact says `route: :hold` with the why). Mirror the existing `:special` test in that file.
- [ ] Implement; run; commit — "o fato :capture: o capturador diz que está mirando, o cérebro lê com o prazo da varredura de cor".

### Task 3: the sim grows a corpse, a ball and the promise

**Files:** Modify `lib/pokex/sim/world.ex` (`corpses: []`, knob `corpse_ms: 20_000`, `hit/3` keeps dead bosses when `boss_color`, `decay_corpses/1` in `run/2` bumping `stats.balls_lost`, `capture_input/1`, `throw_ball/1`, `observe(world, :capture)`), `lib/pokex/sim/hands.ex` (`aiming_since`, `capture/4` with `ball_ms` 1_400), `lib/pokex/sim/bench.ex` (`capturing?:` input; outcome `balls`/`balls_lost`), `lib/pokex/sim/verdict.ex` (`:captura`), `lib/pokex/sim/scenario.ex` (`shiny-no-chao`), `lib/pokex/sim/runner.ex` (`capture: 700` cadence). Tests: `test/pokex/sim/world_test.exs`, `hands_test.exs`, `verdict_test.exs`, `bench_test.exs`.

- [ ] World tests: a boss killed with `boss_color: true` leaves a corpse at its tile; `capture_input/1` says `aiming?: true` while it is on screen; after `corpse_ms` it decays and `stats.balls_lost == 1`; `throw_ball/1` removes it and bumps `stats.balls`.
- [ ] Hands test: with a corpse on screen, `route: :hold` for two ticks ≥ `ball_ms` apart throws (`stats.balls == 1`); `route: :go` in between resets the wait.
- [ ] Verdict test: `:captura` — no corpse ever: pass "nada a capturar"; `balls: 2, balls_lost: 0`: pass; `balls_lost: 1`: fail.
- [ ] Bench test: `shiny-no-chao` × 3 seeds × 60 s → `Verdict.judge(report, [:captura, :nao_cai])` all pass with the default `capture_hold_ms`, and `:captura` FAILS with `capture_hold_ms: 0` (the hold is what buys the ball — the measurement the spec asked for).
- [ ] Implement; run; commit — "o sim ganha corpo, bola e a promessa captura: sem a segurada o corpo do shiny some sem bola".

### Task 4: gate, docs, PR

- [ ] `mix precommit`; `mix credo`; `mix dialyzer`; doc line in `docs/shiny/plano-shiny-por-cor.md`; push; PR; merge when green.
