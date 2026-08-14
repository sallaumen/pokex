# Pokex

A game-automation bot for a 2D tile-based MMORPG, written in Elixir/OTP.
It sees with screen captures, thinks in supervised processes, and acts through
synthetic mouse and keyboard events on macOS.

[![CI](https://github.com/sallaumen/pokex/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/sallaumen/pokex/actions/workflows/ci.yml)
[![Elixir](https://img.shields.io/badge/Elixir-1.19-4B275F?logo=elixir&logoColor=white)](https://elixir-lang.org)
[![OTP](https://img.shields.io/badge/OTP-27-A90533?logo=erlang&logoColor=white)](https://www.erlang.org)
[![Phoenix](https://img.shields.io/badge/Phoenix-1.8-FD4F00?logo=phoenixframework&logoColor=white)](https://www.phoenixframework.org)
[![LiveView](https://img.shields.io/badge/LiveView-1.2-FD4F00)](https://hexdocs.pm/phoenix_live_view)
[![Platform](https://img.shields.io/badge/platform-macOS-000000?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![License](https://img.shields.io/badge/License-MIT-blue)](LICENSE)

---

## What this is

A personal project, and an honest one about its purpose: I wanted to learn OTP
by building something that would punish me for getting concurrency wrong, and a
bot for a game I actually play turned out to be an unusually good teacher. Real
input latency, real race conditions, real consequences when a process crashes at
3 AM with a key still held down.

It is **not** a product. It runs on one machine — mine — against one screen
resolution, one window layout, and one game client. There is a calibration flow
that makes it portable in principle, and the [Running it](#running-it) section is
an honest account of what you would have to redo. But nothing here is packaged,
and nothing here is supported.

What it is worth reading for is the middle layer: roughly 50k lines of Elixir
and 37k lines of tests spent on the problem of driving a hostile, API-less
system reliably.

## Why it's an interesting engineering problem

The game exposes no API. There is no protocol to speak, no memory to read, no
hook to install. The entire input surface is **pixels on a screen**, and the
entire output surface is **synthetic mouse and keyboard events** delivered to a
window that has no idea a program is talking to it.

That constraint turns a game bot into a systems problem:

- **Sensing is slow, expensive, and contended.** A single macOS screen capture
  costs ~0.28s. Several running concurrently cost 2–4s *each*. So capture is a
  scarce resource that has to be scheduled, not a function you call.
- **Actuation is destructive and unrecoverable.** A keystroke sent to the wrong
  window is gone. A key held down when a process dies stays held down. There is
  no transaction to roll back.
- **The world lies.** Frames arrive mid-animation, the client drops inputs, and
  a modal dialog can steal focus between the moment you decide to act and the
  moment you act.
- **A human is in the loop.** I am sitting at the same machine. The bot has to
  yield instantly, on a signal I can give without a keyboard.

OTP maps onto this almost embarrassingly well: supervision for the crashes,
message passing for the contention, and process isolation for the parts that
must survive when the rest does not.

## Architecture

The supervision tree is the design document. Start order is load-bearing and is
annotated in [`application.ex`](lib/pokex/application.ex) — the safety floor
comes up before anything capable of pressing a key.

```
Pokex.Supervisor  (:one_for_one)
│
├── Settings ................. JSON-persisted runtime config (character ⊕ base ⊕ seed)
├── Bots.Perf ................ timing instrumentation
│
├── Bots.InputGate ........... THE ACTUATION SAFETY FLOOR — owns the gate ETS table.
│                             Starts before anything that can send input, so the
│                             check can never find a missing table.
├── Rig.Mac.KeyEvents ........ port to a native Swift CGEvent helper
├── Rig.Mac.OsaBus ........... serializes the osascript fallback (one queue)
├── Bots.Capture ............. serializes ALL screen captures (global singleton)
│
├── Perception ............... blackboard + one demand-driven feed per screen region
│   ├── WorldState ........... ETS-backed fact store
│   └── Feed × 6 ............. :battle :skill_bar :hud :team :minimap :corpses
│
├── Bots.Session ............. generation counter; invalidates stale resumes
├── Bots.BotSupervisor ....... the fleet
│   ├── Body ................. THE SINGLE HANDS — only process that drives the mouse
│   ├── Guardian ............. panic corner + session stop conditions
│   └── Worker × 7 ........... fishing, combat, cavebot, catcher, mini-game,
│                             player-support, timers
│
├── Bots.ShinyGuard .......... always-on watchdog
├── Bots.Logout .............. ends the session on rule or command
├── Layout.Sentinel .......... notices the game window moving
├── Bots.StockAlerts ......... consumable thresholds
├── Journal .................. history that survives a page reload
├── Combos.Runner ............ scripted key sequences
├── Bots.Focus ............... pauses the fleet when the game loses focus
├── Machine.Presence ......... detects a second Pokex VM on this Mac
└── PokexWeb.Endpoint ........ Phoenix LiveView control panel (port 4004)
```

26 GenServers, 3 supervisors, 6 pure decision modules.

## Design decisions worth reading

If you only open a few files, open these.

### Pure logic, impure drivers

Every bot is split in two. The `*.Logic` modules are **pure functions** — they
take an observation plus `now` (a monotonic timestamp, injected, never read) and
return the next state plus a list of actions as *data*. They perform no I/O,
know nothing about the screen, and never call a process.

```elixir
Fishing.Logic.step(logic, observation, now) ::
  {logic, [action]}
```

The `Worker` GenServer around each one senses, calls `step/3`, hands the returned
actions to the `Body`, and schedules the next tick. That split is why a state
machine governing a real-time game can be tested exhaustively with no screen, no
game, and no timing — the suite runs on Linux in CI.

See [`fishing/logic.ex`](lib/pokex/bots/fishing/logic.ex) and its
[driver](lib/pokex/bots/fishing/worker.ex).

### Serialization as a design tool

Three different bottlenecks in this system are solved by deliberately funnelling
concurrent work through a single process. Elixir makes it easy to run everything
in parallel; the interesting engineering was in figuring out where *not* to.

- **[`Bots.Capture`](lib/pokex/bots/capture.ex)** — every screen capture in the
  app goes through one GenServer. Measured: one `screencapture` is ~0.28s, but
  several concurrently balloon to 2–4s each, because macOS contends badly on the
  display grab. Four workers each grabbing their own region was the real cause of
  a jittery sample rate — *not* the number of processes. Serializing them made
  each capture ~0.28s again and the cadence steady.
- **[`Bots.Body`](lib/pokex/bots/body.ex)** — the only process allowed to drive
  the mouse. Workers submit action *sequences*, and the Body runs one at a time,
  atomically, so a `click → move → read` is never interleaved with another
  worker's clicks. It is a priority queue that deliberately lets a waiting
  normal-priority request through after high-priority work, so fishing cannot
  starve behind repeated combat clicks.
- **[`Rig.Mac.OsaBus`](lib/pokex/rig/mac/osa_bus.ex)** — macOS System Events is
  one queue whether you respect that or not. Concurrent `osascript` calls pile up
  and desync keystrokes from the mouse moves they belong with.

### A fail-safe floor for actuation

[`Bots.InputGate`](lib/pokex/bots/input_gate.ex) is a named public ETS table
holding two independent booleans. `Rig.Mac` consults it before **every**
key, click, and move — and never before a capture, because sensing has to keep
working in order to tell when it is safe to act again.

Two owners, one flag each, so neither can clobber the other: the `Guardian`
clears `corner_ok` while the cursor sits in the panic corner; the `Focus` poller
clears `focus_ok` while the game window is not frontmost.

The property that matters is that it is **fail-closed**. A missing flag — a fresh
table on boot, or a restart of the owning process — reads as BLOCKED, not
allowed. "I don't know that it's safe" and "it's safe" used to be the same
answer, and a restart opened a window where input flowed until the pollers caught
up. This exists because a modal dialog that stole focus once absorbed hundreds of
stray keystrokes overnight.

Reads are lock-free straight off ETS, because this is the hottest path in the
system. The GenServer exists only to own the table across caller crashes.

### The emergency stop never depends on what it's stopping

[`Bots.Guardian`](lib/pokex/bots/guardian.ex) polls the cursor every 100ms and
halts the entire fleet the instant it enters the top-left kill corner. Two
properties make it trustworthy:

1. **It is external to every worker.** A stop implemented as "ask the worker to
   stop itself" deadlocks exactly when you need it most — when the worker is
   wedged. The Guardian never asks.
2. **The latch is set before anything is halted.** `InputGate.set_panic_latch/1`
   closes the gate *first*; halting comes second. A safety path that depends on
   the stopped party answering is not a safety path.

The same process also owns session stop conditions and an anti-stagnation rule,
because they are the same shape of problem: an external observer with the
authority to stop everything.

### Perception as a blackboard

Workers do not take screenshots. [`Perception`](lib/pokex/perception.ex) runs one
demand-driven `Feed` per screen region — `:battle`, `:skill_bar`, `:hud`,
`:team`, `:minimap`, `:corpses` — and workers *attach* to the feeds they need,
then read facts from the `WorldState` blackboard or the `"world"` PubSub topic. A
feed with no consumers stops capturing. Adding a worker costs no extra captures
if it needs regions someone else already watches.

All pixel analysis lives in [`Vision`](lib/pokex/vision.ex), which is pure by
construction: binary pattern matching over RGBA frames, no I/O, ever.

### Native escape hatches

Two hot paths were too slow through shell-outs, so they became ports to small
Swift helpers speaking line-delimited JSON over stdio:

- **[`key_events.swift`](priv/native/key_events.swift)** — CGEvents at ~1–2ms per
  hold/release, versus ~60–100ms per `osascript` spawn. That difference is the
  whole reason the fishing mini-game is playable.
- **[`screen_capture_kit.swift`](priv/native/screen_capture_kit.swift)** —
  ScreenCaptureKit instead of the `screencapture` binary.

Both are compiled to `~/.pokex/bin/` **only when the source SHA changes**,
because macOS TCC keys the Accessibility grant to the binary's code hash — a
gratuitous rebuild silently revokes your own permission. Both **degrade rather
than block**: while a helper is missing, still compiling, untrusted, or crashed,
`Rig.Mac` transparently falls back to the `osascript` path.

## Stack

- **Elixir ~> 1.15** (CI runs 1.19 / OTP 27) — supervision, GenServers, ETS, ports, PubSub
- **Phoenix 1.8 + LiveView 1.2** — the control panel, on Bandit
- **Swift** — two native helpers for the latency-critical paths
- **`cliclick` / `osascript`** — the fallback actuation path
- **No database.** State lives in supervised processes; config is JSON on disk.

## Project layout

```
lib/pokex/
  bots/          the fleet: workers, Body, Guardian, InputGate, Session
  perception/    blackboard + feeds + interpreters
  vision/        pure pixel analysis over frames
  rig/           the only layer allowed to touch the OS
  calibration/   screen geometry, in points; Retina conversion isolated here
  pokedex/       species data scraped from the game's wiki
  settings/      layered runtime config
lib/pokex_web/   LiveView control panel
priv/native/     Swift helpers
docs/            design specs and implementation plans, in order
```

## Running it

**Expect to do work.** This is calibrated for one machine: macOS, an ultrawide
3440×1440 display, and the game client running under Wine/CrossOver. Different
resolution or window layout means redoing calibration; a different game client
means rewriting the interpreters in `lib/pokex/perception/interpret/`.

```bash
brew install cliclick
mix setup
mix phx.server          # http://localhost:4004
```

On the first action macOS will prompt for permissions. Grant **Accessibility**
and **Screen Recording** to your terminal in System Settings → Privacy &
Security, then restart the server — the grant is not picked up live.

Then, with the game open and the window positioned where it will stay:

1. `/calibration` — capture the screen and mark the regions.
2. `/` — set skill priority order and start.
3. `/diagnostics` — live tuning of every threshold and each action in isolation.

**Emergency stop:** move the mouse to the top-left corner of the screen. The bot
halts immediately, including mid-pause.

Thresholds are runtime settings, measured against the real game and documented
inline in [`settings.ex`](lib/pokex/settings.ex).

The Pokédex is populated by `mix pokedex.scrape`, which reads the game's wiki.
That origin is the single piece of configuration naming a specific server —
`config :pokex, :wiki_base`, overridable with `POKEX_WIKI_BASE`. Pointing it at a
different wiki also means rewriting the parsers in
[`pokedex/scraper.ex`](lib/pokex/pokedex/scraper.ex): the HTML shape is not
portable.

## Tests

2033 tests across 150 files, ~37k lines. The suite runs on **Linux** in CI on
purpose: every path that genuinely touches macOS is disabled in the test
environment, and the workflow proves that separation holds on every pull
request.

```bash
mix test
mix precommit    # compile --warnings-as-errors + format + test
mix lint         # credo + dialyzer
```

Fixtures include real captures from the live game, so the pixel interpreters are
tested against what the client actually renders rather than against synthetic
images. Player names in those captures have been redacted.

## Disclaimer

Automating a game client violates the terms of service of essentially every
online game, and will get an account banned. This repository is published as a
piece of engineering — an OTP case study with an unusually demanding runtime — not
as a tool for anyone to deploy. It is deliberately not packaged for reuse. If you
run it anywhere, that is entirely on you.

No game client, source, or binaries are redistributed here. The repository does
contain screen captures of the running client used as test fixtures, and species
data scraped from the game's public wiki. Sprite images are not committed — they
are repopulated locally by `mix pokedex.scrape`.

## License

[MIT](LICENSE) © Lucas Tavano
