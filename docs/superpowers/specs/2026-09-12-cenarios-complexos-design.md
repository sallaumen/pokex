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

## D1 — The revive order is an EDGE while the shiny is alive (42% are lost)

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

## D2 — The step between revives: `downed` walks with the shield down

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

### Fix

Hold the road for the first `revive_confirm_ms` of a fall, then walk as today:

```elixir
# THE FIRST TICKS OF A FALL ARE A REVIVE LANDING, not a pokémon lost. Since
# #640 the battle window catches the revive's own recall gap, and walking it
# spends a tile for nothing — 47 downed ticks on 12/09, every one of them a
# single tick with a monster on screen. Walking is for the fall that PERSISTS.
defp downed_route(t) when down_for(t) < t.config.revive_confirm_ms, do: :hold
```

The give-up brake, the stock shortcut and the ask cadence are untouched.

**Bench**: the sim's `own_row?: false` default makes `left_the_list?` inert on
purpose, so this needs a scenario that turns the row off for one tick. The
promise: the road does not move while the body is coming back.

---

## D3 — `sizing` walks with monsters (and with the shiny) on screen

### Measured, and this is the number that answers his question directly

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
pokémons que estavam fora da minha tela".

It is also, in `sizing`, the design working as intended: the phrase is
`só N inimigos à vista — seguindo a rota, contando quem vem`, and the road walks
because the pile has not reached `engage_from` (5). Gathering is the job.

The defect is that **it keeps doing it while the shiny is alive**: 55 `sizing`
ticks with `rota: :go` inside the 13,4 minutes the shiny was on screen. During a
shiny fight, "gathering" is calling reinforcements into a fight he is already
paying for with revives.

### And this is why the ball does not fly

`Catcher.Observation.screen_clear/2` is the gate both lenses share: **nobody
alive on the screen**. In the last 45 minutes `capturing` NEVER happened with an
enemy on screen (n=133, average 0,0, max 0). So a fresh monster walking in —
pulled by D3's step — starves the anchor. Ten times in three hours the journal
says it in his own words:

```
🌟 a âncora caiu com a estrada andando — a bola fica pra hora da bola
```

The ball is not actually broken: 37 balls went out for 40 falls, 16 confirmed.
What breaks is the *timing* — the road was walking at the moment the shiny fell,
so the anchor is deferred to a "hora da bola" that a new arrival keeps pushing
away. Fixing D3 fixes most of these without touching the Catcher.

### Fix

`special?` pins the feet, the same way a corpse already does. There is a ready
mechanism: `hold_for_capture/2` (logic.ex:596) turns a WALKING order into a
stand for `@held_by_capture` phases. Add the same shape for the special:

```elixir
# O SHINY NÃO PRECISA DE MOBADA. Juntar é o trabalho de `sizing`, mas com o
# especial vivo na tela um passo não junta — ele CHAMA: andar com bicho à
# vista soma +2,24 inimigos em 3 s, 90% das vezes (medido em 12/09). E o
# passo é o que adia a bola: a âncora nasce com a estrada andando e fica pra
# próxima. Enquanto o especial está vivo, os pés ficam.
@held_by_special [:travelling, :gathering, :sizing, :bunching, :skipping]
```

Red never holds (a shiny is not worth the character), same as capture.

**Bench**: an `auto_combo` scenario with a special alive and a pile below
`engage_from`. Today the road walks; after the fix it stands. Measure the kill
count and the time awake — the bench has already refuted one tactical change
this week, so this one has to earn it too.

---

## Order of work

1. **D1** — the revive level during the special. One condition, lethal, and the
   bench measures exactly this module.
2. **D2** — `downed` holds the road for `revive_confirm_ms`. Small and safe.
3. **D3** — the special pins the feet. A tactical change: ship it only if the
   bench says the kills do not fall and the time awake does not rise.

D4 (the ball) needs no code of its own; it is a consequence of D3.

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
