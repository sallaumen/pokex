# Observability & Calibration Tooling — Design

**Date:** 2026-07-07 (overnight autonomous session)

**Goal:** Give Lucas (and Claude) the tooling to debug the bot without hand-capturing
screenshots and describing them. One click should dump everything the bot "sees" as
data Claude can read in the morning, plus cleaner, exportable logs.

**Context / motivation (Lucas, going to sleep):**
- "botões novos de Print Screen" — quick screenshot buttons.
- "Log … melhoria visual dos logs, porque não posso guardar tantos" — capped, cleaner,
  leveled logs (macro vs debug).
- "botão de exportar os últimos eventos" — dump the recent event feed.
- "botão de extrair algum dado em JSON … metadados de pixels, mapeamento de matriz da
  minha tela com metadados de pixels de cada ponto" — a JSON pixel/screen dump + a
  downsampled matrix of what the bot sees.
- Combat scan still felt slow last test (no pre-click enemy signal → search is near its
  floor; timing knobs already tuned). Observability first, so the next test produces data.

**Game facts confirmed (PokeTibia wiki):** fishing = cast rod hotkey + click water →
water *bubbles* (the cyan glow) → press rod to hook; combat has a "moves charged" bar
(hover shows how many are ready) — the real Phase-2 skill-cooldown signal; a fishing
*challenge* minigame appears at fishing level 30 (bar over a moving fish), bypassed by
premium lures.

## Deliverables (each its own commit + push; TDD)

1. **`Pokex.Vision.downsample/2`** — pure. Frame → grid of cells `%{r,g,b,class}` where
   class ∈ `pokeball_red | lock_red | hp_green | cyan | other | dark` (reusing the existing
   pixel predicates, "most-salient class present in the cell" wins). Foundation for the
   "screen matrix" export and an on-screen colored grid.

2. **`Pokex.Diagnostics.Report`** — orchestrates capture. Given the Rig, saved Calibration
   and Settings, it captures every region (glow / battle body / battle strip / arena) + the
   full screen, decodes to Frames, runs every Vision metric, downsamples the battle + glow
   regions, and builds a JSON-serializable map. Writes a timestamped file AND overwrites
   `~/.pokex/exports/latest.json`; region PNGs stay in `~/.pokex/captures/` and are
   referenced by path. Rig injected for tests (Rig.Fake + PngFixtures).

3. **`Home.exports_dir/0` + `PokexWeb.ExportsController` + route** — serve/download files
   under `~/.pokex/exports/` (json / log). Mirrors CapturesController.

4. **Log levels + Panel feed revamp** — workers broadcast `{:fishing_log, level, text}` /
   `{:combat_log, level, text}` (`:macro` when the state or a counter changed this tick,
   else `:debug`). Panel stores `%{level, source, text, at}`, capped at 200, timestamped,
   styled by level; a "Mostrar debug" toggle hides the chatty per-tick lines by default;
   an "Exportar eventos" button writes the buffer to `~/.pokex/exports/events-<ts>.log`.
   Backward-compatible 2-tuple fallback for hot-reload safety.

5. **Panel "Prints & Diagnóstico" section** — one-click region + full-screen screenshots
   (with inline preview + download), and an "Exportar diagnóstico (JSON)" button that runs
   `Diagnostics.Report`, renders the battle matrix as a colored grid + key metrics inline,
   and links the JSON download.

## Non-goals tonight
- No bot-behavior (mouse/keyboard) changes — observability only, so nothing regresses
  while Lucas can't validate. The combat "scan only rows with a creature" optimization is
  left as a documented follow-up (needs live validation).
- Phase-2 skill-cooldown vision still needs Lucas's two skill-bar screenshots.
