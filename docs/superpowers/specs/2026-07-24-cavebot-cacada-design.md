# Cavebot — caçada automática + seleção de personagem

**Data:** 2026-07-24
**Pedido do Lucas:** um bot que caça sozinho — grava um conjunto de coordenadas,
percorre a rota, e caça de **dois jeitos ligáveis** (constante e mobado), sabe
usar combos por dungeon, e um seletor de **personagem** no topo que troca o time
e para onde vão as marcações da Pokédex. Ele está num personagem **low level de
propósito**: nele testa primeiro a caçada **constante**; o **mobado** vem depois,
num personagem mais forte. "Tem que ser bem feito — se não for, a gente pode ter
um problema."

Ancorado no código por um mapeamento de 6 subsistemas e revisado por um agente
adversarial que conferiu cada afirmação contra o arquivo real.

---

## Os dois estilos de caçada

Ambos são **ligáveis** e vivem sob um novo modo **"Caçada"** (Parado e Movimento
ficam intocados). Um seletor de estilo aparece quando a Caçada está ativa.

### Caçada CONSTANTE (o primeiro corte testável)

O jeito que gente de level baixo caça: **usa o auto-ataque + as skills um a um**,
foca um alvo por vez, anda a rota e vai matando um por um. Arquiteturalmente é o
mais simples: o cavebot **anda a rota** e o `Combat.Worker` **que já existe roda
o tempo todo** (Tab-lock + skills), fazendo exatamente o que faz hoje. O cavebot
só coordena o andar com a luta (pausa a rota enquanto há luta ativa, retoma
quando limpa) e deixa loot/bola/suporte assentarem.

É **este** o corte que o Lucas valida primeiro no personagem fraco.

### Caçada MOBADA (projetada agora, implementada depois)

O jeito de level alto: **não usa o auto-ataque** — ele mexe o pokémon demais e
estraga as skills de área. O ciclo é: entrar em **defesa (shift+3)**, andar
puxando um grupo de bichos atrás de você, virar **ataque (shift+1)**, soltar o
**combo de área associado** (que idealmente mata todos ao redor), e voltar a
andar. **Se o combo não matou todos**, ligar a constante **momentaneamente** pra
varrer o que sobrou (o Combat vem, vê o que restou, mata), e então retomar o
ciclo de mobar.

O mobado **não** é testável no personagem atual (fraco demais, sem pokémon
ainda). A spec o projeta pra não pintar a arquitetura num canto, mas a
implementação e o teste ao vivo vêm numa entrega posterior.

## A peça arquitetural que amarra os dois

Em **Caçada**, o cavebot é **dono exclusivo** do `run`/`halt` do `Combat.Worker`.
A política difere por estilo:

| | Combat (auto-ataque) | skills/combo |
|---|---|---|
| **Constante** | ligado o tempo todo (o Combat luta um a um) | as do próprio Combat |
| **Mobada** | **desligado** durante andar/agrupar/combo; ligado **só** de relance na limpeza | combo de área disparado pelo cavebot, em posição fixa |

É isso que garante, pela própria arquitetura, que "o auto-ataque não mexe o
pokémon durante o combo de área" — no mobado o Combat está halted enquanto o
combo roda. O bundle da Caçada é `[:catcher, :player_support, :cavebot]` —
**sem `:combat`**, porque quem o liga/desliga é o cavebot, na hora certa.
`stop_all` e o pânico continuam alcançando o Combat (halt de idle é no-op).

**Requisito ligado a isso:** como o Combat pode ficar halted enquanto o cavebot
anda, o cavebot **tem que** entrar em `Focus.default_running?` — senão, depois de
um alt-tab, a frota não re-sobe e o cavebot morre calado. Requisito, não opcional.

## Global Constraints (invioláveis)

- Toda tecla/clique passa pelo `Pokex.Bots.Body` (`minimap_step/3` e `perform/3`),
  atrás de `InputGate` (canto de pânico) + `Focus` guard + `mini_game_gate`. O
  cavebot **não tem nenhum caminho de atuação** que fuja disso — verificado: sem
  fala direta com o Rig.
- **O `Combat.Worker` não é modificado.** O cavebot é *peer* (molde
  `Combos.Runner`): escuta broadcasts e dirige o combate só por `run/1`/`halt/1`.
- **Movimento só é concluído quando `x`, `y` ou `z` muda de verdade.**
  `minimap_step` só clica e retorna `{:ok, point}` sem confirmar; a confirmação
  vem de reler o fato `:minimap`. Nunca inferir "andei" do resultado do `perform`
  (ação barrada retorna `:ok` como no-op).
- Settings: uma fonte da verdade, `@seed_settings`.
- Testes nunca tocam a rede nem capturam a tela real; nenhum servidor sobe.
- Toda ação tem: pré-condição, comando, confirmação visual, timeout, recuperação.

## Arquitetura

O cavebot é um **worker novo e haltável** (`Pokex.Bots.Cavebot.Worker`) modelado
no par `Combat.Worker`/`Combat.Logic` e no peer `Combos.Runner`. Compõe com o que
existe por três canais provados: **atuação** só pelo `Body`; **percepção** só pelo
blackboard (`attach(:minimap)` + `attach(:battle)`, leitura por `WorldState.get/3`);
**combate** por PubSub + API pública `run`/`halt`.

O coração vive numa **`Cavebot.Logic` PURA** (sem processo, relógio ou tela):
recebe `(pos {x,y,z}, contagem de inimigos, estado do Combat, counters, waypoint,
estilo, config, now)` e devolve a próxima ação e o próximo estado. É o que dá pra
testar sem jogo rodando, e é onde os dois estilos divergem.

### Máquina de estados — CONSTANTE (primeiro corte)

| estado | comando | confirmação | timeout → recuperação |
|---|---|---|---|
| `:walking` | `minimap_step(dx,dy)` até o waypoint (Combat rodando o tempo todo) | `x/y/z` do `:minimap` se aproxima do waypoint | `cavebot_walk_timeout_ms` sem progresso → `:stuck` |
| `:fighting` | pausa a rota; o Combat existente luta um a um | `enemies == []` sustentado por `cavebot_clear_debounce_ms` | `cavebot_fight_timeout_ms` → `:fight_stalled` |
| `:post_fight` | deixa loot→bola→suporte assentarem (dwell) | `cavebot_post_kill_dwell_ms` cumprido | — → volta a `:walking` |
| `:stuck` | re-emite `minimap_step` | posição volta a mudar | `cavebot_stuck_max_retries` → `:blocked` |
| `:fight_stalled` | nudge de UM tile em direção aos inimigos | o Combat volta a progredir | retries → `:blocked` |
| `:blocked` | `set_panic_latch(true)` + `stop_all` + alarme | — (chama humano) | — |

Na constante, o Combat é ligado no arranque da Caçada e só é halted em
`stop`/`:blocked` — o cavebot não o toca durante a caça.

### Máquina de estados — MOBADA (adicionada depois, sobre a mesma Logic)

Acrescenta, com o Combat **halted** por padrão:

| estado | comando | confirmação | timeout → recuperação |
|---|---|---|---|
| `:gathering` | defesa (shift+3) + andar puxando aggro pela rota | inimigos ≥ `cavebot_group_min_enemies` | `cavebot_group_max_wait_ms` → solta com o que tem |
| `:nuking` | ataque (shift+1), settle, dispara o combo de área associado (via Body/Combos, **sem** ligar o Combat) | combo terminou | `cavebot_combo_timeout_ms` → `:cleanup` |
| `:cleanup` | se sobrou bicho, liga o Combat **momentaneamente** (estilo constante) pra varrer | `enemies == []` sustentado | `cavebot_cleanup_timeout_ms` → `:fight_stalled` |
| `:post_fight` | halt no Combat; dwell; retoma o ciclo de mobar | dwell cumprido | — → volta a `:gathering`/`:walking` |

Os estados de recuperação (`:stuck`/`:fight_stalled`/`:blocked`) são
compartilhados entre os dois estilos.

## Módulos novos

| módulo | arquivo | natureza | responsabilidade |
|---|---|---|---|
| `Pokex.Bots.Cavebot.Logic` | `lib/pokex/bots/cavebot/logic.ex` | **puro** | a máquina de estados dos DOIS estilos + recuperação; "nunca concluído até x/y/z mudar" |
| `Pokex.Bots.Cavebot.Route` | `lib/pokex/bots/cavebot/route.ex` | **puro** | `%Route{name, dungeon, z, waypoints}` + validação single-floor + append |
| `Pokex.Bots.Cavebot.Store` | `lib/pokex/bots/cavebot/store.ex` | **puro** | `~/.pokex/routes.json` (molde `Combos.Store`) |
| `Pokex.Bots.Cavebot.Worker` | `lib/pokex/bots/cavebot/worker.ex` | GenServer | peer; attach com reattach; dirige o Body; liga/desliga o Combat conforme o estilo |
| `Pokex.Characters` | `lib/pokex/characters.ex` | **puro** | `list/create/rename/delete` (molde `Calibration.list_profiles`) |
| `PokexWeb.CavebotLive` | `lib/pokex_web/live/cavebot_live.ex` | LiveView | gravar-andando + editar rota + escolher DG/estilo; **`attach(:minimap)` no mount** |

Mais o accessor **`Perception.minimap/1`** (espelhando `pokemon/1`) com staleness
fail-open — leitura de posição com max-age próprio, tight, pro loop de controle.

## Modelo de dados

**Rota:** `~/.pokex/routes.json`,
`%{"routes" => [%{"name","dungeon","z","enabled","waypoints" => [%{"x","y","z"}]}]}`.
Waypoint capturado andando: a UI lê `World.snapshot().pos` (do fato `:minimap`) e
faz append. Invariante single-floor validado no `Route`; `z` divergente em runtime
→ `:blocked`.

**Estilo de caçada:** setting `hunt_style: "constante"` (default; `"mobada"` vem
depois). Lido pela `Cavebot.Logic` pra escolher a máquina de estados.

**Gate de combo por dungeon:** campo `:dungeon` (nil = global) no `%Combos.Combo{}`
+ encode/decode. O `Cavebot.Worker` publica o fato `:dungeon` no `run`. O
`Combos.Runner` lê esse fato e passa o id pro filtro puro em `Combos.match/2`:
combo com `:dungeon` só casa na DG corrente; global casa sempre. **Combat
intocado.** A DG é o nome da rota ativa. No mobado, o "combo de área associado" à
caçada reusa esse mesmo mecanismo (combo com `:dungeon` da rota).

**Personagem (só time + marcações da Pokédex):** setting `active_character: ""`.
Ponto de troca **único**: `Team.file/0`. Vazio → legado `~/.pokex/team.json`
(intocado); senão → `~/.pokex/chars/<slug>/team.json`. As marcações da Pokédex
são o mesmo `team.json`. O caminho de atuação do bot **não toca** `team.json` (os
combos usam `Team.best_counter/swap_key` do feed `:team`). `team_icons.json` e
`shiny_log.json` ficam globais.
**Correção do cético:** `Team.file/0` recebe o slug por opts com default lendo
Settings; **todo teste que setar `active_character` reseta em `on_exit`** (a
classe de sangramento cross-teste via ETS que o projeto já sofreu).

**Settings novas** (`@seed_settings`): `hunt_style`, `defense_mode_key: "shift+3"`,
`attack_mode_key: "shift+1"`, `cavebot_arrival_tolerance_tiles`,
`cavebot_walk_timeout_ms`, `cavebot_minimap_fact_max_age_ms`,
`cavebot_stuck_max_retries`, `cavebot_group_min_enemies`,
`cavebot_group_max_wait_ms`, `cavebot_stance_settle_ms`,
`cavebot_post_kill_dwell_ms`, `cavebot_clear_debounce_ms`,
`cavebot_fight_timeout_ms`, `cavebot_combo_timeout_ms`,
`cavebot_cleanup_timeout_ms`, `active_character`. E a flag `:cavebot_active`
(false em teste).

## Fases

**A ordem prioriza o que o Lucas testa primeiro (constante), no personagem fraco.**

- **Fase 0 — Seleção de personagem.** `active_character`; `Team.file/0` roteando
  legado ↔ `chars/<slug>/`; `Pokex.Characters`; seletor no topo do painel;
  migração best-effort. *Independente — pode ir primeiro e sozinha.*
- **Fase 1 — Route store + Settings.** `Cavebot.Route` + `Cavebot.Store`; chaves
  `cavebot_*` e `hunt_style`. Puro.
- **Fase 2 — `Cavebot.Logic` pura, estilo CONSTANTE.** A máquina de estados da
  constante + recuperação. 100% pura: injeta `(pos, enemies, combat_state, now)`
  e asserta ação/estado.
- **Fase 3 — `Cavebot.Worker` peer, estilo CONSTANTE.** `run/halt/status`; attach;
  dirige o Body; liga o Combat no arranque e deixa rodar. Rig.Fake + Body fake +
  `:cavebot_active false`.
- **Fase 4 — Fiação: modo "Caçada" (estilo constante).** child no `BotSupervisor`;
  modo em `Pokex.Modes` (bundle `[:catcher, :player_support, :cavebot]`); cavebot
  em `Focus.default_running?` (requisito); `@run_order`.
- **Fase 5 — Gate de combo por dungeon.** `:dungeon` no `%Combo{}`; `match/2`
  filtrando; `Runner` lendo o fato; UI do combo ganha o seletor de DG.
- **Fase 6 — `CavebotLive` (gravar/editar rota).** `attach(:minimap)` no mount;
  marcar/editar/reordenar; escolher DG. **Aqui o Lucas valida a constante ao vivo.**
- **Fase 7 (entrega POSTERIOR) — estilo MOBADA.** Estende a `Cavebot.Logic` com
  `:gathering`/`:nuking`/`:cleanup`, defesa/ataque, o combo de área e o fallback
  pra constante; seletor de estilo na UI. Testada pura primeiro; validação ao vivo
  quando o Lucas tiver um personagem forte.

## Confirmar na revisão (defaults que assumi)

1. **Estilo como sub-toggle da Caçada** (não como dois modos top-level separados).
   Parado / Movimento / Caçada, e dentro da Caçada um seletor constante/mobado.
   Confirmar essa forma na UI.
2. **Constante pausa a rota durante a luta** (não anda enquanto luta). Mais seguro
   pro v1; "andar matando" contínuo fica pra depois se você quiser.
3. **Combo de área do mobado reusa o sistema de Combos** (combo com `:dungeon`),
   disparado pelo cavebot em vez do Combat. Confirmar quando chegarmos no mobado.
4. **"Grupo limpo"** = `enemies == []` sustentado por `cavebot_clear_debounce_ms`
   (o `Combat.Logic` fica em `:hunting` pra sempre após limpar). Confirmar o
   debounce vs. um inimigo momentaneamente sem barra de HP.
5. **Captcha/GM:** sem feed de percepção; o corte 1 só detecta mudança de `z` e
   depende de parada manual/pânico. Confirmar que basta agora.
6. **Migração do `team.json`:** o time atual segue como "sem personagem" até você
   nomear o primeiro; na criação, cópia best-effort. Confirmar a UX.

## Fora de escopo (explícito)

Troca de andar deliberada, HM moves, detector automático de captcha, namespacing
de combos/rotas/calibração por personagem. O `Combat.Worker` permanece intocado.
