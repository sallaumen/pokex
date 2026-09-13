# Complex scenes: the step between revives, the ball that never flies, and the slow revive

Date: 2026-09-12. Measured on his own run of today (`~/.pokex/events/2026-09-12.jsonl`
and `~/.pokex/journal/2026-09-12.jsonl`), last 3 hours, with the code that was
running live at 20:20 (PRs #633, #635, #638, #640, #642, #643, #644 already in).

His report, verbatim: *"Quando eu estou matando um shiny, geralmente, entre os
meus revives, ele acaba dando um passo. Esse passo acaba fazendo eu atrair mais
pokémons que estavam fora da minha tela… aí ele não está nem tentando lançar a
Pokébola nesses cenários, e parece que esse passo que ele está dando também
está deixando a utilização do revive ainda muito lenta."*

Every clause of that is true, and each has a different cause. Three defects,
ordered by how close each one is to killing the character.

---

## D1 — The revive order is an EDGE while the shiny is alive (42% are lost) — **SHIPPED (#645)**

This is the lethal one and it is the answer to *"ele usa a porra do auto combo e
depois espera meia hora pra usar a merda do revive"*.

### Measured

| | revive asks | aborted with no dispatch | width of the ask |
|---|---|---|---|
| shiny ALIVE on screen | 84 | **35 (42%)** | p50 0 ms, max 603 ms |
| no shiny | 191 | 25 (13%) | p50 0 ms, max 1009 ms |

190 of 267 asks in three hours last a **single tick (0 ms of width)**. The
support's own tick is ~120 ms plus a health photo; a level that narrow is a coin
flip, and #615 already learned this once.

On the next tick after an aborted ask the brain says, 30 times out of 60,
`[engaged] matando o que já abriu` — and fires **another chain**, which spends
the bar again, which asks for the revive again ~3 s later. The loop he watched.

Worked example, 20:15:27 → 20:15:38 (his run, one shiny, one survivor):

```
+3216ms  [resetting] revive=now   combo acabou com a barra gasta — revive agora
+3417ms  [resetting] revive=now   revive pedido há 0s — os cooldowns ainda não voltaram
+3820ms  [engaged  ] revive=hold  matando o que já abriu        ← o pedido MORREU
+4150ms  TECLA r                                                ← e saiu OUTRA corrente
+7228ms  TECLA r                                                ← e outra
+10304ms 🚑 revive despachado                                    ← 7,1 s depois do pedido
```

And 19:15:05, the worst of the day: three asks born and killed in 200 ms each,
the revive dispatched **12,4 segundos** after the first one — with the shiny's
corpse already on the ground and a survivor hitting him.

### Root cause, one line

`Engine.Logic.hold_until_reset_seen/2` (lib/pokex/bots/engine/logic.ex:646) is
the overlay that turns the revive ask into a LEVEL until the support takes it.
It excludes the special:

```elixir
if pending? and orders.revive == :hold and orders.phase in @held_by_reset and
     not special?(t) do
```

The comment justifying the exclusion says the special has its own cycle (*"stun
a cada emenda, F4 a cada 5s"*) which is shorter than the promise's deadline. In
**Auto Combo that cycle never turns**: `special_orders/1` needs the `:stunned`
stamp, the stamp needs `control_ready?`, and the chain burns the control key —
already recorded in `o-ciclo-do-especial-e-do-combo-antigo`.

Proof from today's run: of the **105 revive asks with the special around, ZERO**
came from the special cycle. Every one of them reads
`combo acabou com a barra gasta` — the ordinary `combo_reset_due?` rule. The
exclusion takes away the level and gives nothing back, exactly where the
character is most likely to die.

### Fix

Split the overlay. The exclusion exists to protect the special's *tempo* — its
road and its fire — not to unlatch its revive. The revive level is a separate
concern from freezing the feet and the hand.

```elixir
# The special keeps its own tempo: the road and the fire are not touched.
# But the ORDER TO REVIVE is a level for everyone — the ask is 200ms wide and
# the support's tick is 120ms plus a photo, and 42% of the asks with the shiny
# alive were lost to that gap on 12/09.
```

- when `special?(t)` and `pending?`: keep `orders` as chosen, but force
  `revive: :now` while `unanswered?(t)`;
- when not `special?(t)`: unchanged (the full `resetting` hold).

`unanswered?/1` already closes the level the instant `ReviveLedger` notes a
press from any hand, so this cannot become a held key.

**Bench**: a scenario in `mode: :auto_combo` with a special alive, where the
support's hand is slow by one tick. Today the ask evaporates; after the fix it
survives until the ledger notes the press. This is the `Engine.Logic` half, so
the bench is real proof here (see `a-bancada-mede-o-cerebro-nao-a-mao`).

---

## D2 — The step between revives: `downed` walks with the shield down — **SHIPPED (#646), by another route**

### Measured

47 `downed` ticks in three hours, and **every single one** reads
`rows=1, enemies=1, own=absent` — one row in the battle window, legible, and it
is not his. The pokémon is off the field, a monster is on screen, and the order
is:

```
[downed] rota=go fogo=hold revive=hold ini=1 own=absent rows=1
         "sem pokémon em campo — nada a atacar até ele voltar"
```

Route `:go`. **The brain orders a step with the shield down and a monster
hitting him.** 31 of those ticks happened with the shiny around.

Every stretch is a SINGLE tick — 44 stretches, all 0,0 s. This is not a fallen
pokémon; it is the revive's own recall gap, seen through the battle window by
the `left_the_list?` rule that #640 shipped today. The rule is right (the row
really is gone). The *order* is wrong.

### Root cause

`Engine.Logic.downed/1` (logic.ex:874) ends in `Orders.walking/3`, and the
comment above it explains why:

> The route keeps walking, for the same reason it does with no keys: standing
> still in a pile with nothing to defend him is the worse of the two.

That reasoning was written for a **proven, sustained** fall — the pokémon is
dead, the revive is not coming, running beats standing. It is not true for a
200 ms absence while a revive is landing: there the step costs a tile of
position, drags the fight into fresh ground, and buys nothing.

### The fix this plan first wrote, and the two fences that refused it

The plan said: hold the road for the first `revive_confirm_ms` of a fall. The
bench refused it, and then refused the next idea too:

| tentativa | what refuses it |
|---|---|
| **hold** the road during the recall | invariant `:hold_while_down`, **32 scenarios** — "parado com o pokémon na bola é o personagem levando as mordidas por ele" |
| **retreat** (`route: :back`) | promise `nao_recua` in `barra-que-demora` and `nove-em-cima` (64 to 108 ticks retreating) |

Both fences are measured and both are right. Three failed attempts at the same
spot is the signal to question the spot: **the defect was never what `downed`
orders — it was ENTERING `downed` during a recall we asked for ourselves.**

### What shipped (#646)

`left_the_list?/1` asks first whether the body is coming back: with a revive
press on record (`rescue_noted_at`, from any hand) inside `revive_confirm_ms`
AND the row absent for less than that, the absence already has an owner and
there is no fall to announce.

The two conditions must be two, and the clock of the second is the **absence**
(`row_gone_at`), not the press: `downed/1`'s cadence re-presses F4, and anchored
on the press each one would push the deadline forward — a long fall would blind
the rule forever.

**Bench**: it cannot judge this. `own_row?: false` is the simulated world's
default and `left_the_list?/1` is inert there on purpose (#640). The proof is
his journal plus three unit tests. What #646 DID add to the bench is the revive
ledger itself (`revive_noted_at` in `Sim.World`, `rescue_noted_at` in the
picture) — without it `unanswered?/1`, the level from #615 and #645, never
closed in a bench run at all.

---

## D3 — `sizing` walks with monsters on screen — **WITHDRAWN, and here is why**

The measurement that follows is correct. The CONCLUSION drawn from it was not,
and #647 replaced the fix with the instrument that will answer it properly.

### The measurement, which stands

For ticks that already have 1+ enemies on screen, does the crowd GROW within
3 seconds?

| phase | route | ticks | crowd grew | average change |
|---|---|---|---|---|
| **sizing** | **go** | 546 | **493 (90%)** | **+2,24 inimigos** |
| engaged | hold | 428 | 21 (5%) | −4,29 |
| bunching | hold | 296 | 158 (53%) | +0,41 |
| resetting | hold | 140 | 15 (11%) | −0,54 |
| skipping | go | 66 | 66 (100%) | +2,80 |

**Walking with monsters on screen adds 2,24 enemies within three seconds, nine
times out of ten.** That is his "esse passo acaba fazendo eu atrair mais
pokémons que estavam fora da minha tela". The step D2 removed was `downed`'s.

### Why the proposed fix was withdrawn

**It contradicts his own rule.** The 55 `sizing` ticks that walk while the shiny
is alive all read `só N inimigos à vista — seguindo a rota, contando quem vem`:

```
22  [sizing] inimigos=1     18  [sizing] inimigos=3     11  [sizing] inimigos=5
18  [sizing] inimigos=2     16  [sizing] inimigos=4
```

That is "postura no shiny é juntar primeiro!" (11/09), already written into
`cuts_queue?/1` — the special jumps the queue only once its fight is open or it
is alone (`enemies <= 1`). Pinning the feet in `sizing` would undo it.

**And the evidence for the ball claim did not survive.** This document first
said 11 of the 13 deferred anchors had `rota=hold` in the brain at that instant.
That reading is void: `decision` events are DEDUPED (`changed_mind?/2` writes
only when the mind changes), so the tick "just before" an anchor can be seconds
old and says nothing about the route at that moment:

```
15:37:16.401 âncora adiada
      -4197ms  [bunching] rota=hold
      -2589ms  [bunching] rota=hold   ← e nada por 2,6 s até a âncora
```

### What replaced it

`standing?/0` asks THREE questions — still mode, road held, screen clear — and
the deferral line blamed the first one every time. #647 makes it name the gate
that actually refused, with the count when it is the screen:

```
🌟 a âncora caiu com 2 bicho(s) vivo(s) na tela (a estrada estava parada)
```

No gate changed. **The open question is now instrumented instead of guessed:**
the next night says by itself whether what defers the shiny's ball is the road
or the survivor still standing. If it is the survivor, the decision to take to
him is whether a shiny anchor may fly with a live creature on screen — which is
`Observation.screen_clear/2`, the gate both lenses share, and a rule he wrote:
"quando tá vivo temos que matar e quando tá morto temos que capturar".

## Order of work

1. **D1** — the revive level during the special. ✅ #645.
2. **D2** — the recall gap is not a fall. ✅ #646 — and NOT the way this plan
   first wrote it: holding the road breaks the `:hold_while_down` invariant in
   32 scenarios, retreating breaks the `nao_recua` promise in 2. Both fences are
   measured. The defect was ENTERING `downed` during a recall we asked for, not
   what the phase orders.
3. **D3** — withdrawn; #647 instruments the question instead. Open until the
   next night answers it.

D4 (the ball) was folded into D3: the ball is not broken (37 balls for 40 falls,
16 confirmed) — what is unknown is which gate defers the other three.

## What is NOT wrong, so nobody goes looking

- **The chain → revive-ask latency does not degrade with more monsters.** p50 by
  enemy count: 0 → 2752 ms, 1-2 → 2765 ms, 3-5 → 2820 ms, 6+ → 2830 ms. The
  ceiling is his `auto_combo_window_ms: 3000`, and it holds. The slowness is
  entirely in the ask→dispatch gap (D1), which is worst at **1-2 enemies** —
  21 of 111 chains over 5 s there, and ZERO over 5 s at 6+ enemies.
- **`attack_mode_key` is retired for real.** `shift+1` was last pressed at
  18:25, before he restarted on #643. His `settings.json` has no override for
  it, so it reads the new `""` default.
- **The Catcher's negative `captured_at`** in the "a lógica recusou" line is
  `System.monotonic_time/1`, used consistently across the Catcher. Ugly in the
  log, not a bug.
