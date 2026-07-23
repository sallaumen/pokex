# Cavebot — caçada automática (primeiro corte) + seleção de personagem

**Data:** 2026-07-24
**Pedido do Lucas:** um bot que caça sozinho — grava um conjunto de coordenadas,
percorre a rota, agrupa inimigos, coloca o pokémon em **modo defesa (shift+3)**
enquanto agrupa e troca para **modo ataque (shift+1)** antes das skills, sabe
quando usar combos (configurável **por dungeon**), e um seletor de **personagem**
no topo da tela que troca o time e para onde vão as marcações da Pokédex. Ele
está num personagem **low level de propósito**, pra validar em locais básicos
antes do personagem real.

Este design foi ancorado no código existente por um mapeamento de 6 subsistemas
e revisado por um agente adversarial que conferiu cada afirmação contra o
arquivo real. Um furo estrutural que ele achou já foi resolvido por decisão do
Lucas (ver "A decisão do combate").

---

## Escopo

**Dentro do primeiro corte:** percorrer uma rota de **um único andar** (só
WALK), agrupar um grupo de inimigos, defesa (shift+3) ao agrupar, ataque
(shift+1) antes das skills, e delegar a luta ao combate **que já existe**. Mais
os estados de recuperação que o manual pede (travado, alvo fora de alcance,
corpo sumiu) e **parar + chamar humano** em captcha/GM ou mudança de andar
inesperada.

**Fora deste corte (deferido):** troca de andar deliberada (escada/buraco/rampa),
HM moves (cut/surf/dig/rock smash), detector automático de captcha/GM. Nesses
casos o bot **para**, nunca tenta contornar.

## Global Constraints (invioláveis)

- Toda tecla/clique passa pelo `Pokex.Bots.Body`, atrás de `InputGate` (canto de
  pânico) + `Focus` guard + `mini_game_gate`. O cavebot **não tem nenhum caminho
  de atuação** que fuja disso — verificado: só `Body.minimap_step/3` e
  `Body.perform/3`, ambos caem em `Rig.Mac.gated`.
- **O `Combat.Worker` não é modificado.** O cavebot é um *peer* que escuta
  broadcasts e dirige o combate só pela API pública `run/1`/`halt/1` — o mesmo
  padrão do `Combos.Runner`.
- **Movimento só é concluído quando `x`, `y` ou `z` muda de verdade.**
  `minimap_step` só clica e retorna `{:ok, point}` sem confirmar; a confirmação
  vem de reler o fato `:minimap`. O cavebot nunca infere "andei" do resultado do
  `perform` (uma ação barrada pelo gate retorna `:ok` como no-op).
- Settings: uma fonte da verdade, `@seed_settings` em `lib/pokex/settings.ex`.
- Testes nunca tocam a rede nem capturam a tela real; nenhum servidor sobe.
- Toda ação tem: pré-condição, comando, confirmação visual, timeout, recuperação.

## A decisão do combate (resolvida)

Para "agrupar em defesa sem atacar", o `Combat.Worker` precisa ficar **halted**
enquanto o cavebot anda e agrupa, e só ligar depois do shift+1. Isso conflitava
com o modo **Movimento** atual, que liga o combate continuamente.

**Decisão do Lucas: um terceiro modo, "Caçada".** Parado e Movimento ficam
exatamente como estão. Na Caçada, o cavebot é o **dono exclusivo** do `run`/`halt`
do combate. O bundle de workers da Caçada é `[:catcher, :player_support,
:cavebot]` — **sem `:combat`**, porque quem o liga/desliga é o cavebot, na hora
certa. `stop_all` e o pânico continuam alcançando o `Combat` de qualquer forma
(halt de worker idle é no-op).

**Requisito ligado a essa decisão:** como o combate fica halted enquanto o
cavebot anda, o cavebot **tem que** entrar em `Focus.default_running?` — senão,
depois de um alt-tab, a frota não re-sobe e o cavebot morre calado. É requisito,
não opcional.

## Arquitetura

O cavebot é um **worker novo e haltável** modelado no par
`Combat.Worker`/`Combat.Logic` e no peer `Combos.Runner`. Ele compõe com o que
já existe por três canais provados:

1. **Atuação** só pelo `Body` — WALK via `minimap_step/3`, postura via
   `perform([{:press, ...}], :high)`.
2. **Percepção** só pelo blackboard — `attach(:minimap)` e `attach(:battle)`,
   leitura lock-free por `WorldState.get/3`.
3. **Combate** por PubSub como o `Combos.Runner` — assina `Combat.Worker.topic()`,
   lê o snapshot, dirige o combate só por `run`/`halt`.

O coração de decisão vive numa **`Cavebot.Logic` PURA** (sem processo, sem
relógio, sem tela): recebe `(pos {x,y,z}, contagem de inimigos, estado do
Combat, counters, waypoint atual, config, now)` e devolve a próxima ação e o
próximo estado. É isso que dá pra testar sem jogo rodando.

### Máquina de estados (primeiro corte)

Cada estado com pré-condição, comando, confirmação, timeout e recuperação:

| estado | comando | confirmação | timeout → recuperação |
|---|---|---|---|
| `:walking` | `minimap_step(dx,dy)` até o waypoint (Combat halted, DEFESA aplicada); `dx,dy` clampados a um delta moderado (< `@max_jump=50` do gate do minimapa) | `x/y/z` do fato `:minimap` se aproxima do waypoint | `cavebot_walk_timeout_ms` sem progresso → `:stuck` |
| `:grouping` | `press` defesa (shift+3) se ainda não estiver; espera reunir | contagem de inimigos ≥ `cavebot_group_min_enemies` | `cavebot_group_max_wait_ms` → segue pro `:engaging` com o que tem |
| `:engaging` | `press` ataque (shift+1), settle, então `Combat.Worker.run` | snapshot do Combat entra em `[:tabbing, :fighting]` | run devolve `{:error,_}` (preflight) → `:blocked`; sem engajar no tempo → `:fight_stalled` |
| `:fighting` | nada (rota pausada); o Combat existente luta | `enemies == []` sustentado por `cavebot_clear_debounce_ms` | `cavebot_fight_timeout_ms` → `:fight_stalled` |
| `:post_fight` | `Combat.Worker.halt`; deixa loot→bola→suporte assentarem (o Catcher já disparou o Espaço) | dwell de `cavebot_post_kill_dwell_ms` cumprido | — → volta a `:walking` |
| `:stuck` | re-emite `minimap_step` (o cliente pode ter esbarrado num obstáculo) | posição volta a mudar | `cavebot_stuck_max_retries` esgotado → `:blocked` |
| `:fight_stalled` | nudge de UM tile em direção ao centroide dos inimigos | o Combat volta a progredir | retries esgotados → `:blocked` |
| `:blocked` | `InputGate.set_panic_latch(true)` + `BotSupervisor.stop_all` + alarme | — (estado terminal, chama humano) | — |

## Módulos novos

| módulo | arquivo | natureza | responsabilidade |
|---|---|---|---|
| `Pokex.Bots.Cavebot.Logic` | `lib/pokex/bots/cavebot/logic.ex` | **puro** | a máquina de estados inteira + recuperação; "nunca concluído até x/y/z mudar" vive aqui |
| `Pokex.Bots.Cavebot.Route` | `lib/pokex/bots/cavebot/route.ex` | **puro** | `%Route{name, dungeon, z, waypoints}` + validação single-floor (todos os waypoints com o mesmo z) + append |
| `Pokex.Bots.Cavebot.Store` | `lib/pokex/bots/cavebot/store.ex` | **puro** | `~/.pokex/routes.json`, `all/put/add/delete/set_enabled`, decode tolerante → seed (molde `Combos.Store`) |
| `Pokex.Bots.Cavebot.Worker` | `lib/pokex/bots/cavebot/worker.ex` | GenServer | peer fino `run/halt/status`; `attach(:minimap)+(:battle)` com reattach; dirige o Body; chama `Combat.run/halt` na hora certa |
| `Pokex.Characters` | `lib/pokex/characters.ex` | **puro** | `list/create/rename/delete` sob `chars_dir()` (molde `Calibration.list_profiles`) |
| `PokexWeb.CavebotLive` | `lib/pokex_web/live/cavebot_live.ex` | LiveView | gravar-andando ("marcar waypoint aqui" lê `World.snapshot().pos` → Store), editar/reordenar/apagar, escolher a rota/DG. **`attach(:minimap)` no mount** (senão o pos de gravação vem nil) |

Mais um accessor **`Perception.minimap/1`** (espelhando `pokemon/1`) com staleness
fail-open usando `cavebot_minimap_fact_max_age_ms` — a leitura de posição uniforme
com max-age próprio, tight, pro loop de controle (o `World.snapshot().pos` usa
janela de 5s, generosa demais).

## Modelo de dados

**Rota:** `~/.pokex/routes.json` (`Home.dir()`), formato
`%{"routes" => [%{"name","dungeon","z","enabled","waypoints" => [%{"x","y","z"}]}]}`.
Waypoint é capturado andando: o botão da CavebotLive lê `World.snapshot().pos`
(já derivado do fato `:minimap`) e faz append; depois o Lucas reordena/apaga.
Invariante single-floor validado no `Route`; `z` divergente em runtime → `:blocked`.

**Gate de combo por dungeon:** campo novo `:dungeon` (nil = global) no
`%Combos.Combo{}` + encode/decode no `Combos.Store`. O `Cavebot.Worker` publica o
fato `:dungeon` no `run` (forget no halt). O `Combos.Runner` **lê** esse fato
(leitura peer) e passa o id pro filtro puro em `Combos.match/2`: combo com
`:dungeon` só casa se == dungeon corrente; combo global casa sempre. **O
`Combat.Worker` não é tocado.** A identidade da DG é o **nome da rota ativa**
(simples e estável).

**Personagem (só time + marcações da Pokédex):** setting `active_character: ""`.
O ponto de troca é **único**: `Team.file/0`. Vazio → legado `~/.pokex/team.json`
(arquivo atual **intocado**); senão → `~/.pokex/chars/<slug>/team.json`. As
"marcações da Pokédex" são o **mesmo** `team.json` (os badges "no teu time/banco"
em `pokedex_detail_live` gravam via `Team.add`) — rotear `file/0` resolve time e
Pokédex de uma vez. Os dois únicos leitores do arquivo são UI; **o caminho de
atuação do bot não toca `team.json`** (os combos usam `Team.best_counter/swap_key`
derivados do feed `:team`, não do arquivo). `team_icons.json` fica **global**
(chaveado por espécie — o sprite do Sceptile é igual em qualquer personagem;
namespaçar quebraria o feed `:team`). `shiny_log.json` também global.

**Correção do cético (namespacing):** `Team.file/0` recebe o slug por
parâmetro/opts com default lendo `Settings.get(:active_character)`, mantendo os
testes de round-trip puros; e **todo teste que setar `active_character` reseta em
`on_exit`** — isso é a classe de sangramento cross-teste via ETS que o projeto já
sofreu (o incidente do nil no mirror).

**Settings novas** (`@seed_settings`, fonte única): `defense_mode_key: "shift+3"`,
`attack_mode_key: "shift+1"`, `cavebot_arrival_tolerance_tiles`,
`cavebot_walk_timeout_ms`, `cavebot_minimap_fact_max_age_ms`,
`cavebot_stuck_max_retries`, `cavebot_group_min_enemies`,
`cavebot_group_max_wait_ms`, `cavebot_stance_settle_ms`,
`cavebot_post_kill_dwell_ms`, `cavebot_clear_debounce_ms`,
`cavebot_fight_timeout_ms`, `active_character`. E a flag `:cavebot_active` (false
em teste, padrão do worker sempre-ligado).

## Fases (cada uma testável sozinha, sem tela nem rede)

- **Fase 0 — Seleção de personagem.** `active_character` no seed; `Team.file/0`
  roteando legado ↔ `chars/<slug>/`; `Pokex.Characters`; seletor no topo do
  painel; migração best-effort do `team.json` atual. *Independente das demais —
  pode ir primeiro e sozinha.*
- **Fase 1 — Route store + Settings.** `Cavebot.Route` (validação single-floor) e
  `Cavebot.Store` (routes.json); todas as chaves `cavebot_*`. Puro.
- **Fase 2 — `Cavebot.Logic` pura (o coração).** A máquina de estados inteira +
  recuperação. 100% pura: injeta `(pos, enemies, combat_state, counters, now)` e
  asserta a ação e o estado devolvidos.
- **Fase 3 — `Cavebot.Worker` peer.** `run/halt/status`; attach com reattach;
  subscribe "combat"; dirige o Body; chama `Combat.run/halt`. Testado com worker
  isolado + Rig.Fake + Body fake + `:cavebot_active false`.
- **Fase 4 — Fiação na frota.** child no `BotSupervisor`; **novo modo "Caçada"**
  em `Pokex.Modes` (bundle `[:catcher, :player_support, :cavebot]`, sem `:combat`);
  **cavebot em `Focus.default_running?` (requisito)**; `:cavebot` em `@run_order`.
- **Fase 5 — Gate de combo por dungeon.** Campo `:dungeon` no `%Combo{}` +
  encode/decode; `Combos.match/2` filtrando; `Runner` lendo o fato `:dungeon`;
  UI do combo ganha o seletor de DG.
- **Fase 6 — `CavebotLive`.** UI de marcar/editar rota (com `attach(:minimap)` no
  mount), escolher a DG; verificação whole-branch. A validação ao vivo é manual.

## Confirmar na revisão (defaults que assumi)

1. **Mecânica de "agrupar":** assumi *parar em defesa e deixar os inimigos
   virem* (simples e seguro pro low level). A alternativa é *kite ativo* (andar
   puxando aggro), que muda a política do `:grouping`. Confirmar.
2. **"Grupo limpo":** uso `enemies == []` sustentado por
   `cavebot_clear_debounce_ms` como veredito (o `Combat.Logic` fica em `:hunting`
   pra sempre após limpar, nunca volta a `:idle` sozinho). Confirmar que o
   debounce cobre o risco de um inimigo momentaneamente sem barra de HP.
3. **Captcha/GM:** não há feed de percepção pra isso. O corte 1 só detecta
   mudança de `z` e depende de parada manual/pânico pro captcha real. Confirmar
   que basta agora, ou se quer um fato `:blocker` mínimo já nesta entrega.
4. **Migração do `team.json`:** o time atual continua como "sem personagem" até
   você criar/nomear o primeiro; na criação, cópia best-effort pro
   `chars/<slug>/`. Confirmar essa UX (vs. converter o atual num personagem
   nomeado explicitamente no arranque).

## Fora de escopo (explícito)

Troca de andar deliberada, HM moves, detector automático de captcha, kite ativo,
namespacing de combos/rotas/calibração por personagem. O `Combat.Worker`
permanece intocado.
