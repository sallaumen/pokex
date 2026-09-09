# O shiny na caçada: uma bola no corpo dele sem parar de caçar

Data: 2026-09-09. Autor: a IA, a pedido do Lucas. Estado: **plano, aguardando a
revisão dele antes de qualquer código.** Identificadores em inglês; texto pro
usuário em pt-BR.

> "Quero que comecemos a capturar shinies, é a próxima meta. Atualmente, sem
> isso, o lucro não está valendo a pena o tempo do meu computador ligado."

## 1. Por que

O capturador existe inteiro, está na árvore de supervisão em todos os modos
(`lib/pokex/modes.ex:48` põe `:catcher` no pacote `hunt`), e **nunca jogou uma
bola numa caçada**. Não é opinião, é contagem do diário dele
(`~/.pokex/events/*.jsonl`, 13 dias, 31/08 a 09/09):

| medida | valor |
|---|---|
| teclas apertadas em 13 dias | `3` 15.487 · `4` 14.091 · `5` 13.187 · `shift+3` 7.269 · `r` 3.781 · `tab` 2.841 … |
| teclas de bola (`f1`, `f2`, `f3`) | **0** |
| evento `kill` (o gatilho do capturador) em 10,6 h de 08/09 | **1** |
| evento `kill` em 5,6 h de 09/09 | **0** |
| quedas da lista de batalha (um bicho morreu ou saiu) em 08/09 | 3.248 (305/h) |
| dessas, com a rota **segurada** (`route: hold`) no instante da queda | 3.130 (**96%**) |
| segundos entre a queda e o próximo `route: go` (08/09, mediana) | 3,4 (p25 0,4 · p90 4,2) |
| `shiny_log.json` | `[]` |
| `~/.pokex/special_colors.json` | não existe |

Duas dessas linhas mudam o desenho:

- **O gatilho do capturador está morto na caçada.** O `{:kill}` que acorda o
  capturador só sai quando o contador `fights` do combate sobe
  (`lib/pokex/bots/combat/worker.ex:630-636`), e no modo dele (sem Tab,
  `fight_by_screen/3`) isso só acontece quando **a lista de batalha esvazia**
  (`lib/pokex/bots/combat/logic.ex:827-830`). Numa caverna com 305 mortes por
  hora a lista esvaziou uma vez em dez horas. Mesmo destravando o modo Parado,
  o capturador não ia acordar.
- **O personagem já está parado quando o bicho morre.** 96% das mortes
  acontecem com a rota segurada pela engine (corrente, revive, cerco). O
  problema "a mira não sobrevive a um personagem que anda" é real, mas é o
  problema dos **3 segundos depois** da morte, não do instante dela. A resposta
  é segurar a rota mais um pouco quando há um shiny no chão, e mirar numa foto
  fresca, e não rastrear o corpo enquanto ele anda pela tela.

## 2. Diagnóstico

### 2.1 Existe e não é chamado (na caçada)

| o quê | onde | por quê não roda |
|---|---|---|
| A varredura ancorada na morte (`SpotScan`) | `lib/pokex/bots/catcher/worker.ex:739-744` (`scan_obs/1`) | `player_mode != "still"` devolve `nil`; `Logic.step(logic, nil, _)` é no-op (`logic.ex:39`) |
| O passo da lógica (`Logic.step`) | `worker.ex:514-525` (`advance/2`) | só o ramo `player_mode == "still"` chama `do_advance/2`; a observação é contada (`contar/2`) e jogada fora |
| A varredura cega (`Sweep`) | `worker.ex:447-450` | "a varredura é do modo Parado"; a parada `:sweep` da rota foi removida em 28/08 (`lib/pokex/bots/cavebot/route.ex:56-62`) |
| `sweep_now(around)` — varrer em volta do **pokémon**, não do personagem | `worker.ex:88-105`, `sweep.ex:44-50` | nenhum chamador na caçada |
| O acelerador `{:kill}` | `worker.ex:248-254` | o produtor dispara 1× por noite (tabela acima) |
| O feed `:corpses` e `Interpret.Corpses` | `worker.ex:875-887` (`should_be_attached?/1` é `false` constante) | aposentado em 30/07; 8 chaves `corpse_*` sem leitor vivo (`settings.ex:479-489`) — limpeza, não bloqueio |
| A segurada de rota por captura (`capturing?/3`) | `lib/pokex/bots/cavebot/logic.ex:1222-1227`, lida só em `post_fight/3` (`:1167`) | na caçada a rota é da engine (`route_hold?`), e `post_fight` não passa por esse ramo |
| `shiny_always_ball` | `worker.ex:503-507` (`capture_allowed?/1`) | é um `or` **dentro** do mesmo `if` que exige `"still"` (`:740-741`); na caçada não fura nada |
| `ball_rules` do shiny | `balls.ex:31-85` | só há regra pro Krabby → `f2`; um shiny de caverna cai no `ball_key` padrão (`f1`) |

### 2.2 É chamado e não decide

| o quê | onde | o que se perde |
|---|---|---|
| O **ponto** da mancha do shiny (`vistos[].point`) | publicado em `lib/pokex/bots/shiny_guard.ex:175-184`; lido em `lib/pokex/bots/engine/worker.ex:372-379` | o cérebro lê só o booleano `especial?`; o ponto é descartado — e está em **pixels do frame**, nunca convertido pra tela (`color_mark.ex:19-21`) |
| `{:shiny_seen, %{point}}` no capturador | `worker.ex:324-327` | vira `shiny_pending?: true`; o ponto é ignorado |
| As posições por bicho do olho (`:crowd.hostiles[].dx/dy`) | `lib/pokex/bots/crowd_scan.ex:55-84`; lidas em `engine/situation.ex:224` | só o `park_spot` e a frase-sombra do revive usam; nenhum diff entre fotos (identidade é a fase C do olho, `2026-09-05-siege-eye-design.md:88-90`) |
| O selo "capturando" do painel | `worker.ex:955-962` (`mode_state/2`) | `"hunt"` não casa nenhuma cláusula: mostra `:armed` enquanto os portões acima bloqueiam tudo; `hold_reason/1` (`:991-1011`) não tem ramo de modo |
| A guarda de cor (`ShinyGuard`) | `shiny_guard.ex:90-95` | `shiny_guard_enabled` padrão `false` e `ColorRules.armed/0` vazio (sem regra provada) — nem varre |
| `enemies_detail[].shiny?` e o badge ✨ da Central | `lib/pokex/perception/interpret.ex:76-82`; `cavebot_live.ex:2542` com `world.ex:78` | os dois são `false` fixo desde a migração |

### 2.3 Não existe

1. **Uma regra de cor ensinada e provada** pro shiny que ele caça hoje (só ele pode fazer — §6).
2. **Uma mira que sobreviva à caçada**: hoje o ponto é congelado na varredura ancorada no `player_point` calibrado (`spot_scan.ex:98-103`) e entregue à `Body` segundos depois.
3. **Um sinal "o shiny morreu e o corpo está AQUI"**: a guarda publica `especial?: false` na primeira foto sem mancha (`shiny_guard_test.exs:199-213`) e não guarda o último ponto; o olho não tem identidade entre fotos.
4. **Um canal capturador → engine** pra segurar a rota enquanto há bola a dar.
5. **Corpo, bola e promessa de captura no simulador** (`sim/world.ex:1448-1457` apaga o bicho morto; `Sim.Hands` só obedece rota/fogo/revive/park; `Verdict` tem 13 promessas, nenhuma de bola).
6. **Corpo ensinado de qualquer bicho da caverna**: os 30 corpos de `corpses.json` são todos de água (Krabby, Tentacool, Magikarp…); nada de Magneton.
7. **Uma fixture real de shiny ou de corpo por cor** (os testes de `ColorMark`/`ShinyGuard` usam frames sintéticos; as 4 fixtures de shiny em `test/fixtures/shiny/` são da estrela do cliente antigo, órfãs).

## 3. O coração: mirar num personagem que anda

Três caminhos, do mais barato ao mais caro:

**A. Segurar os pés e mirar numa foto fresca (recomendado).** O corpo do shiny
é encontrado **pela mesma cor** que o achou vivo — a paleta é do sprite, e o
corpo é o sprite deitado. Quando a mancha continua na tela e a criatura sumiu
da lista, o capturador pede à engine que segure a rota (`route: :hold`, com
teto), tira UMA foto do quadrado, acha a mancha, converte pra ponto de tela
com o `scale` e a origem da região, e joga. A foto tem menos de 100 ms; o
personagem está parado por ordem da engine. É o mesmo par ordem/frase que
segura a rota pro revive hoje, e cabe na medida: 96% das mortes já acontecem
parado, e a segurada só precisa cobrir os 3 s que hoje o separam do próximo
passo.

**B. Rastrear o corpo enquanto anda.** Diff de `:crowd` entre fotos (a barra
que sumiu em `{dx,dy}` → corpo ali), somar o deslocamento do personagem lido
do minimapa, e re-mirar a cada passo. Precisa da identidade por bicho (fase C
do olho, não construída), de uma leitura do minimapa por passo, e falha
quando bolha de fala ou pilha esconde barras (`siege.ex:17-20`). É o caminho
pro corpo **comum** sem regra de cor — fase futura, não a primeira.

**C. Parar a caçada inteira ao avistar.** Postura de chefe já existe
(`engine/logic.ex:1155`); bastaria não voltar à rota até a bola sair. Mais
simples que A, mas transforma um falso positivo da cor (o Torterra verde, §9
do plano por cor) em caçada parada. A recusa é a mesma do plano por cor: uma
regra que para tudo morre de descrédito no primeiro dia.

Decisão proposta: **A**, com **C** só como consequência natural da postura de
chefe que já existe (o shiny vivo já segura a rota — R7 não recua,
`engine/logic.ex:1311-1313`). B fica anotado pra corpos comuns.

## 4. A menor fatia que já dá valor

Um shiny visto, morto, com uma bola no corpo, e a frase na Central. Quatro PRs
pequenos, cada um mergeável sozinho; o valor aparece no terceiro.

### PR 0 — a foto da morte (medição, sem comportamento novo)

- **Muda:** a `ShinyGuard` guarda o último ponto visto (em **pontos de tela**,
  com a região e o `scale` no fato `:special`) e, quando a mancha some ou a
  lista cai dentro de 3 s de um avistamento, salva o quadrado cru em
  `~/.pokex/captures/shiny/<ts>.raw` + o PNG de evidência com a cruz no ponto,
  e escreve no diário `kind: "special"` com `px`, `point`, `seen?`. Só o maior
  blob por regra continua sendo julgado (`shiny_guard.ex:161`) — anotar.
- **Mede:** a pergunta que sustenta a fatia inteira — **o corpo do shiny
  mantém a paleta?** Uma foto responde. Não há medição disso no repositório
  (a `Recolor` existe justamente porque ele nunca fotografou um corpo de
  shiny). Também mede o chão da regra com o Torterra em campo, que é a
  armadilha nº 1 do plano por cor.
- **Depende dele:** ensinar e provar uma regra de cor (§6) e ligar
  `shiny_guard_enabled`. Sem isso o PR 0 é inerte por construção.
- **Pode quebrar:** nada no jogo; escreve em `~/.pokex/captures/` (com teto de
  fotos, como `crowd/` faz com 30).

### PR 1 — a mira por cor no capturador (`Catcher.ShinyAim`, novo)

- **Muda:** um módulo puro que recebe `Frame` + regras armadas + zonas
  proibidas e devolve a observação que a `Logic` já entende:
  `%{scanning?: true, corpses: [point], known: %{point => %{name, score}}, captured_at}`,
  com `point` em tela (`Calibration.frame_to_screen/3`, `calibration.ex:717`).
  No `worker.ex`, `scan_obs/1` ganha um segundo ramo: **`shiny_pending?` abre a
  varredura por cor em qualquer modo**; o `SpotScan` por corpo ensinado continua
  só no Parado. O sinal de "é corpo, não bicho vivo": mancha presente em 2
  fotos seguidas **sem barra de vida a até 1 tile acima** (`:crowd`), ou queda
  da lista nos últimos 3 s. `Balls.key_for/1` já casa `"Shiny Magneton"` por
  contenção — ele escolhe a bola em `ball_rules`.
- **Mede na bancada:** teste com a fixture do PR 0 (o `.raw` da morte) — a
  mira cai a ≤ meio tile do corpo; teste sintético com a mancha **dentro** da
  caixa do pokémon → nenhuma mira; teste com barra viva sobre a mancha → nenhuma
  mira. Zero jogo até isso passar.
- **Pode quebrar:** o ponto da mancha é o centro de massa da cor; num corpo
  deitado, pode ficar meio tile fora do que o cliente considera "o corpo". Por
  isso a fixture real antes; `corpse_max_balls` continua o teto.

### PR 2 — a engine segura a rota pra bola

- **Muda:** o capturador publica o fato `:capture`
  (`%{pending?: true, name, since}`) enquanto tem corpo na fila; a engine lê
  (`engine/worker.ex:355-366`, ao lado de `especial?`) e, em qualquer fase com
  `route: :go`, responde `Orders.standing(:capturing, band, "shiny no chão —
  segurando a rota pra bola (Ns)")`, com teto `capture_hold_max_ms` (proposta:
  6.000, faixa 2.000..15.000). Fogo e revive **não mudam** — só os pés. Na
  `Cavebot.Logic`, `capturing?/3` passa a valer também em `:walking`.
- **Mede na bancada:** `Sim.World` retém o bicho morto como `corpse` por N s
  com `shiny?`; o `Runner` publica `:capture` quando um corpo shiny existe;
  cenário novo `shiny-no-chao` (grupo do chefe, `boss_color: true`) com
  promessa nova `:bola_a_tempo` (a rota segurou ≤ teto e voltou) somada a
  `:nao_morre` e `:revive_no_prazo` — a segurada não pode custar o revive.
  6 sementes × 3 min, como o elo cor → chefe foi medido.
- **Pode quebrar:** o teto vence antes da bola (mancha atrás do pokémon). O
  diário conta: cada segurada fecha com uma frase própria (`why` distinto,
  senão o `changed_mind?/2` não grava — `engine/worker.ex:479-480`).

### PR 3 — ele vê na tela

- **Muda:** a Central deixa passar `{:catcher_log, :macro, _}` só das frases
  de bola/captura (hoje descarta tudo, `cavebot_live.ex:251`); o tile
  `tile-capture` mostra "shiny no chão · bola 1/2" em vez de "corpos na fila";
  o badge ✨ morto (`world.ex:78`) passa a ler o fato `:special`;
  `mode_state/2` ganha o ramo `"hunt"` e `hold_reason/1` explica a segurada.
  `ShinyLog.resolve_last("ball")` já existe (`worker.ex:675-684`) — a
  prateleira do painel fecha o troféu sozinha.
- **Mede:** teste de LiveView com `render_hook`/broadcast (memória: `<img>`
  sem `phx-hook` não reage); nada de servidor por cima do dele.

Depois desses quatro: **uma noite de caçada com a guarda ligada.** A régua é o
diário: linhas `kind: "special"` com `seen?: true` × bolas (`press` de `f*`)
× `ShinyLog` com `outcome: "ball"`. Se o shiny não aparecer na noite, a fatia
não está provada — só está pronta.

## 5. Etapas seguintes (cada uma um PR)

| # | o que muda | como se mede na bancada | o que pode quebrar |
|---|---|---|---|
| 4 | **Segunda bola e desistência com frase**: `corpse_max_balls` por shiny, TTL de ignorar visível na Central | cenário do sim com corpo que "não some" → 2 bolas e desistência ≤ teto | gastar bola num corpo que o jogo já recolheu |
| 5 | **Bag vazia**: contar bolas por chave (`press` de `f*` sem captura confirmada N vezes) e alarmar; `dry_balls_alarm` já existe (`logic.ex:191-206`) | teste puro da `Logic` | alarme falso quando a confirmação é inconclusiva (teto de 60 s, `logic.ex:13`) |
| 6 | **Prioridade de alvo**: com `especial?` e `:crowd`, a engine manda o fogo single no tile da mancha (hoje nada ordena alvo; Tab é só do Econômico) | sim: o shiny morre antes dos comuns em ≥ 80% das sementes | o Auto Combo dele não tem alvo — só vale no Econômico |
| 7 | **Corpo comum na caçada** (caminho B): diff de `:crowd` por `{dx,dy}` → corpo; `SpotScan` com corpo ensinado da caverna | fixture com pilha antes/depois | bolha de fala, barra escondida na pilha |
| 8 | **Limpeza**: feed `:corpses`, `Interpret.Corpses`, 8 chaves `corpse_*`, fixtures órfãs da estrela | suíte verde | nada — é remoção de código morto |

## 6. O que só ele pode decidir

1. **Ensinar a cor.** Abrir a calibração com o shiny na tela, conta-gotas,
   "medir o chão" com o Torterra em campo, e ligar `shiny_guard_enabled`. Sem
   isso nenhum PR desta lista faz nada — e é o único item que não dá pra
   medir por ele. Qual shiny ele caça agora (o Electrode da print de 01/09?
   um Magneton?).
2. **Parar a rota pra capturar, e por quanto tempo.** Proposta: sim, ≤ 6 s
   por corpo. Ele já para 96% das vezes; a pergunta é só o teto.
3. **Qual bola e quantas.** `ball_rules` pro shiny (f1? ultra?); teto de
   bolas por corpo (hoje `corpse_max_balls: 1` no `settings.json` dele —
   valeria 2 pro shiny?).
4. **Bag vazia:** parar de tentar e alarmar, ou seguir caçando em silêncio.
5. **Capturar não-shiny na caçada?** Custa corpo ensinado por espécie e bola
   por morte (305/h). Proposta: não nesta rodada.
6. **Duas perguntas do jogo que o código não sabe:** quanto tempo o corpo
   fica no chão; e o que acontece com uma bola jogada num shiny **vivo**
   (nada, perde a bola, ou o jogo recusa). A segunda decide quão conservador o
   sinal "é corpo" do PR 1 precisa ser.
7. **O corpo do shiny mantém a cor?** Ele deve saber de olho; o PR 0 prova
   com foto.

## 7. Riscos

- **Perder o shiny.** A cor falha (bolha, pilha, fora do quadrado de
  `corpse_scan_radius_tiles` = 8 dele) → nada acontece, como hoje. A perda
  nova possível é o **teto da segurada** vencer antes da bola; o diário conta
  cada uma.
- **Gastar bola à toa.** Bola num bicho vivo (sinal "é corpo" errado) ou num
  corpo já recolhido. Cerca: 2 fotos + sem barra + teto de bolas + TTL de
  ignorar (`corpse_ignore_ttl_ms`). Um falso positivo da cor custa no máximo
  `corpse_max_balls` por 45 s.
- **Morrer parado capturando.** A segurada só prende os pés; fogo, revive e
  a R7 continuam. O cenário do sim tem `:nao_morre` como promessa obrigatória
  e a segurada é recusada em banda vermelha (`band: :red` → rota da engine
  manda, sem `:capturing`).
- **Travar a caçada.** Teto em ms, fato com prazo (fato velho = sem segurada,
  como `especial?` faz com 3 varreduras), e a frase no feed. Nunca `:infinity`
  na `Body` fora do que já existe (`body.ex:28-29` já é o teto de hoje).
- **A cor do Torterra.** Armadilha nº 1 do plano por cor; a zona proibida da
  guarda é só o ponto calibrado do pokémon (3×3 tiles, `shiny_guard.ex:140-150`),
  não o rastreador. Se o chão medido com o Torterra em campo não der 3× de
  margem, a regra não arma e este plano espera.

## 8. Fora do escopo desta rodada

Varredura cega na caçada; corpo comum; prioridade de alvo (fase 6); limpeza
do feed morto (fase 8). O painel de ensino de cor não muda — o que existe
(`calibration_live.ex:1212-1252`) já basta pra ele ensinar e provar.

## 9. Como saber que fechou

Uma linha no diário dele com `kind: "press"` e `keys: ["f1"]` (ou a bola que
ele escolher) a menos de 6 s de uma linha `kind: "special"` com `seen?: false`,
e uma entrada em `shiny_log.json` com `outcome: "ball"`. Antes disso, nada
está "feito" — está construído.
