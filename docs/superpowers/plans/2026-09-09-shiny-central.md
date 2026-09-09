# Ele vê na tela (PR 3) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Cave Bot Central shows the shiny's story as it happens: the sighting, the corpse found, the ball, and the aim in the capture tile; the dead ✨ badge reads the colour fact; the Panel stops saying "capturando" in a hunt with nothing to capture.

**Architecture:** Three small edits, no new process. `Pokex.World.snapshot/1` fills `shiny?` from the `:special` fact (three colour scans of age). `CavebotLive` lets through the Catcher's `:macro` lines that belong to the shiny story (🌟, ✨, "bola") and the guard's ✨ sighting on the combat topic; the capture tile reads `@catcher.aim?`/`pending_corpses`. `Catcher.Worker.mode_state/2` and `hold_reason/1` gain the `"hunt"` answer: armed only while aiming, otherwise "na caçada só o shiny leva bola".

## Global Constraints
- English identifiers/test names; pt-BR on screen. Worktree; touched test files only; full gate before the PR.

### Task 1: `shiny?` reads the colour fact — `lib/pokex/world.ex`, `test/pokex/world_test.exs`
### Task 2: the Central's feed and tile — `lib/pokex_web/live/cavebot_live.ex`, `test/pokex_web/live/cavebot_live_test.exs`
### Task 3: the Panel's honest label — `lib/pokex/bots/catcher/worker.ex`, `test/pokex/bots/catcher/worker_test.exs`
### Task 4: gate, doc line, PR, merge
