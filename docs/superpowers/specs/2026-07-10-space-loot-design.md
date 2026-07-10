# Space Loot + Global Player Mode — Design

**Date:** 2026-07-10
**Status:** approved by Lucas
**Amends:** 2026-07-10-corpse-capture-design.md (which dropped space-loot entirely; Lucas wants
it back as an independent toggle — sometimes loot WITHOUT capture)

## Game facts (confirmed by Lucas)

- Space loots only ADJACENT corpses; in his fishing flow the hooked pokémon teleports to the
  melee tile beside him and dies there — corpses are ALWAYS adjacent, so no walking, ever.
- The Pokéball consumes the corpse INCLUDING its loot → loot must land BEFORE the ball.
- UI preference: ONE global mode describing the player (Parado / Em movimento) + independent
  toggles for loot and capture that only act while Parado.

## Design

**Settings** (`@seed_settings`):
- RENAME `capture_mode` → `player_mode` (`"parado" | "movimento"`), same semantics, now global
  to loot AND capture (stale persisted `capture_mode` overrides self-clean via Settings.load).
  Every current reader of `:capture_mode` (Catcher.Worker gates + panel) moves to `:player_mode`.
- NEW `loot_enabled: true` — press Space after each kill (Parado only).
- NEW `capture_enabled: true` — throw Pokéballs at detected corpses (Parado only); the
  existing ball pipeline gains this gate alongside the mode gate.
- RESTORED `loot_presses: 2` and NEW `loot_press_gap_ms: 250` — number of Space presses per
  kill and the gap between them (rapid back-to-back inputs bug the game; the old Loot
  documented this).

**Catcher.Worker** (no new processes):
- Trigger: the `{:kill}` broadcast ONLY (one per confirmed kill — a corpse just dropped). The
  combat-disengage edge is NOT a loot trigger: a fight can end by timeout/rehunt with no
  corpse, and Space there would be a wasted press. On `{:kill}`, when
  `player_mode == "parado"` and `loot_enabled`: perform `[{:press, "space"}, {:wait, gap},
  ...]` (`loot_presses` presses) via `Body.perform(..., :high)` BEFORE the advance step, bump
  a new `loots` counter, log "🧰 saqueando" on the catcher topic. The corpse just died on the
  adjacent tile; Space reaches it from standing position.
- Ordering guarantee BY CONSTRUCTION: balls require the corpse detector's confirmation (≥2
  feed frames ≈ 800ms+ after the fight ends), while Space fires immediately on the kill edge —
  loot always precedes the ball on the same corpse. No explicit sequencing needed.
- The ball pipeline (queue/throw/confirm) is additionally gated on `capture_enabled` (loot-only
  operation = Space presses happen, no balls ever; the detected blobs sit in the world unused).
- A kill edge while another fight starts instantly (multi-hook) still fires the Space presses —
  Space loots the dead corpse regardless of the new fight (harmless, adjacent-only).

**Panel** ("Captura (Pokébola)" area reworked):
- Row 1 — **"Modo"**: Parado / Em movimento selector (global). Em movimento hint: "você
  saqueia e captura manualmente — em movimento o bot não age". Switching pokes
  `Catcher.Worker.mode_changed()` exactly as today.
- Row 2 — toggle **"Pegar loot (Espaço)"** (`loot_enabled`), subtitle "Espaço após cada kill
  (corpo cai do teu lado)".
- Row 3 — toggle **"Capturar (Pokébola)"** (`capture_enabled`), subtitle unchanged from today's
  parado description.
- "Reaprender chão" button stays (only visible in Parado). The catcher pill shows captures and
  loots counters.
- Automation count: loot and capture each count as ON when their toggle is on AND mode is
  parado (list grows to /6: fishing, combat, loot, capture, rescue, potion).

**Counters/snapshot:** Catcher counters gain `loots: 0`; snapshot unchanged otherwise.

**Testing (TDD):**
- Worker: kill edge × (mode, loot_enabled) table — space presses performed at :high with the
  configured count/gap, before any ball of the same cycle; loot-only (capture_enabled false)
  → spaces but never a capture_sequence; movimento → neither.
- Ball gate: capture_enabled false blocks throws even with a confirmed corpse observation.
- Panel: mode selector persists to player_mode + pokes the worker; both toggles persist;
  movimento hint shown; automation count reflects toggles+mode.
- Settings: player_mode rename — grep zero remaining `capture_mode` readers.
