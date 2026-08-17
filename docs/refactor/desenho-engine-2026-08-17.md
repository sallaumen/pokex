# Desenho: a engine central de decisão

> Data: 17 de agosto de 2026
> Lido a partir de: `main` em `5ceb5b9`
> Natureza: desenho de arquitetura. Autoriza a sequência de PRs da seção 15, nenhuma reescrita fora dela.
> Origem: Lucas, 17/08 — *"a gente precisa organizar esse código pra ele saber tomar decisões melhores (…) a nossa game engine, que seria um worker central de lógica de processamento, deveria estar dando conta. Pra ser honesto, acho que nem essa game engine tá bem feita nesse projeto."*
> Escopo pedido: *"um desenho completo, lembrando dos refactors necessários, melhorias em backend, melhorias em db, melhorias no front-end, melhorias de logs — algo completo para termos essa base da Engine sendo algo CONFIÁVEL de onde nosso software vai dar os passos para começar a ficar realmente inteligente na caçada."*

---

## 1. As quatro regras que ele fechou

Contrato de comportamento, fechado em conversa no dia 17/08, cada uma com a frase dele. Qualquer código aqui que as contrarie está errado — não elas.

**R1 — A régua é contagem, não relógio.** Menos de 3 monstros (sem contar o próprio pokémon) não vale nem atacar: segue andando, eles somem ou entram na próxima perna.
> *"Se tem 1 ou 2 monstros, eu às vezes até ignoro aquele mob e sigo a minha vida (…) eu realmente mato quando tem uns três."*

**R2 — A ganância tem teto.** Juntar demais e arrastar para longe de onde nasceram faz os monstros **sumirem**. Logo, "esperar parar de chegar" nunca pode ser sem limite: a perna gravada é o teto.
> *"Se você for muito ganancioso e quiser juntar muitos monstros de uma vez só, fazer eles andarem muito longe de onde eles nasceram, faz eles sumirem."*

**R3 — O revive é economia, não curativo.** Ele zera todos os cooldowns *e* cura. O certo é gastar os cooldowns matando a pilha e **então** reviver, resolvendo as duas coisas com uma tecla.
> *"Reviver no meio do nada, só porque a vida do pokémon ficou baixa, também é uma lógica muito burra."*

**R4 — O stun é relógio puro.** Recibo confirmado ⇒ a tela conta como dormindo por N ms, sem desmentido. Vetar por "ainda estou tomando dano" foi **recusado explicitamente**, e a razão é boa: vetaria justo o caso comum.
> *"O stun não pegar em todo mundo da tela vai acontecer (…) mesmo não tendo pego, se estamos com pouca vida e a maior parte da tela stunada, essa é a melhor hora pra usar o revive (…) essa é a melhor janela antes de eu não ter mais opções e deixar meu pokémon morrer e assim ter que usar o combo de revive sem meu pokémon no campo e sem meus inimigos estarem stunados, o que normalmente é morte na certa."*

E as faixas, que ele desenhou por cima disso:

| faixa | vida | comportamento |
|---|---|---|
| **verde** | ≥ 60% | caçada normal: mob, régua de 3, estoura área |
| **amarelo** | 30–60% | **fecha a rodada**: para de estender a mobada, espera a pilha chegar, stun, gasta tudo, mata, **e aí** revive mesmo acima de 30% |
| **vermelho** | < 30% | emergência: revive agora, no meio da luta |

Mais duas proibições que atravessam tudo:

- **Não começa perna nova com pouca vida.** A verificação passa a existir *antes* de sair andando — hoje não existe.
- **Não revive com bicho acordado em cima.** Recolher o pokémon com a pilha desperta entrega o personagem; o stun é o que compra a janela.

---

## 2. Diagnóstico: por que o bot é burro hoje

Cinco defeitos, todos confirmados no código e nos dados reais (`~/.pokex/routes.json`, `~/.pokex/settings.json`, `~/.pokex/journal/`, `~/.pokex/team.json`).

**1. O "resetar cooldown" é cego.** `run_stop(logic, :cooldown_revive, now)` (`cavebot/logic.ex:1122`) dispara porque a esquina carrega a marca. A rota *Meganium and Venoss* carrega nas esquinas **7, 15, 29, 66 e 68**. Nenhuma linha olha vida nem barra de skills.

**2. A mobada termina no relógio.** `gathering?/2` é literalmente `now - at < gather_wait` (`cavebot/logic.ex:313`); o estouro sai na borda `hold_fire → free_fight` (`combat/worker.ex:277`). **Nada nesse caminho lê quantos inimigos existem.** A gravação dele mostra tempos reais de 1264, 2543, 3248 e 4806 ms — ele nunca esperou um número fixo.

**3. Ninguém sabe se o bicho está stunado.** O fato não existe.

**4. O suporte decide pela barra e mais nada.** `PlayerSupport.Logic.decide/1` vê `hp_pct`, `prev_hp_pct`, limiar e cooldown. Lê `:battle`, mas só para saber se está em combate antes da poção — nunca para decidir o revive. Com a configuração atual (`pokemon_hp_rescue_pct = 60`, `cavebot_hp_abort_pct = 30`) **o revive dispara 30 pontos antes de a caçada achar que existe problema**: no meio da pilha, cooldown cheio, valor jogado fora nas duas pontas. Não é bug escondido — é um número encontrando uma lógica que só sabe olhar a barra.

**5. Não existe camada derivada.** `WorldState` é um mural de 82 linhas (`put`/`get` com idade) e é *bom* nisso: leitura sem lock, fatos que expiram sozinhos, ninguém trava ninguém. O que falta é o andar de cima. Hoje "quantos monstros tem" é respondido em três lugares diferentes, e o Suporte nem faz a pergunta. E não existe **dono de sequência**: a rodada amarela atravessa os três workers, que só conversam por uma seta de mão única (`:posture`, do Cavebot pro Combat).

**Matéria-prima já lida e nunca combinada:** `:battle` (a cada 120ms) entrega contagem de linhas, e `enemies_detail` entrega `%{row, name, hp_pct, shiny?}` — nome por glifos contra a Pokédex (`interpret.ex:129`). `:skill_bar` (400ms) entrega teclas prontas. `:pokemon` entrega a vida. `team.json` diz quem está em campo (hoje: **Vespiquen**, com `1 = crowd`, `2 = buffs`, `3/4/5 = área`, `6-9 = single`).

---

## 3. O que "confiável" significa aqui

Seis provas. Se alguma não estiver de pé, a engine não é base pra nada.

1. **Não trava a frota.** A engine nunca segura o `Body`, nunca tira captura, nunca faz `GenServer.call` em worker. Laço puro sobre ETS; morrer e reiniciar custa um tick.
2. **Não muda comportamento em silêncio.** A PR 2 publica ordens que **ninguém obedece**, e a tela mostra lado a lado o que ela mandaria e o que o bot fez. Trocar o cérebro de um sistema que roda oito horas sozinho sem uma noite de sombra é irresponsável.
3. **Toda decisão é explicável depois.** Cada ordem carrega um `why` em português, e cada mudança vira linha de journal + registro estruturado.
4. **Degrada pro bot de hoje.** Ordem velha ou ausente ⇒ cada worker faz exatamente o que faz hoje (seção 8).
5. **A regra é função pura.** `(quadro, config, agora) → ordens`. A árvore inteira do Lucas vira tabela de teste, sem abrir o jogo.
6. **Dá pra reproduzir uma noite real.** O log estruturado da seção 10 é replayável contra a máquina — a mudança se prova contra a caçada que aconteceu, não contra a que eu imaginei.

---

## 4. A decisão: engine central, mandando por fato

Escolhido o caminho 2 (Lucas, 17/08: *"2, com qualidade e profundidade"*), depois de eu levantar o risco de ponto único de falha numa caçada de oito horas. O risco é real e a resposta é estrutural, não uma promessa.

**A engine manda por FATO, não por mensagem.** É o desenho que já provou funcionar no `:posture`, e o comentário que o descreve (`cavebot/worker.ex:368`) diz por quê:

> *"É um fato no quadro, não uma mensagem, e esse é o desenho inteiro: fatos carregam sua idade, então uma caçada que morre simplesmente para de renovar este, e o Combat lê como velho — o que ele trata como fogo livre."*

Uma engine que manda por `cast` cria dependência viva: se ela morre, ninguém recebe nada e todo mundo fica esperando. Uma engine que manda por fato cria dependência **com prazo de validade**: se ela morre, o fato envelhece e cada worker volta sozinho ao que sabe fazer. É a diferença entre um cérebro e um marca-passo.

---

## 5. Os três fatos

### `:situation` — o que é verdade

Escrito pela engine a cada tick. Puro derivado; nenhuma política aqui.

```elixir
%{
  enemies: 4,                    # linhas que NÃO são o meu pokémon
  enemies_named: [%{row: 1, name: "Venonat", hp_pct: 0.62, shiny?: false}, ...],
  worth_fighting?: true,         # enemies >= engage_from (R1)
  growing?: false,               # a contagem subiu na última janela
  stable_for_ms: 1800,           # há quanto tempo parou de subir
  own_hp: 47,                    # 0..100 ou nil
  own_out?: true,
  asleep_until: 1786941535474,   # relógio do stun, ou nil (R4)
  ready_keys: ["3", "4", "5"],
  spent?: true,                  # a maior parte das teclas de dano está em cooldown
  blind?: false,                 # algum fato essencial velho/ausente
  at: 1786941533474
}
```

### `:orders` — o que fazer

```elixir
%{
  phase: :travelling | :gathering | :sizing | :engaged | :closing | :recovering | :emergency,
  band: :green | :yellow | :red,
  route: :go | :hold,            # o Cavebot obedece
  fire: :hold | :free,           # o Combat obedece
  opening: ["3", "4", "5"],      # teclas já resolvidas — Combat não pergunta quem está em campo
  stun: :hold | :now,            # o Combat obedece
  revive: :hold | :now,          # o Suporte obedece
  potion: :hold | :now,          # o Suporte obedece
  why: "amarelo: fechando a rodada com 4 inimigos",
  at: 1786941533474
}
```

Separados de propósito: a tela pode mostrar o quadro com a decisão desligada, e testar o quadro não depende da política. Cada worker lê **só o campo dele**.

O `why` não é enfeite — é o que resolve *"eu ter um bom tracking do que ocorreu"*. Pela primeira vez dá pra ler **por que** ele fez, não só o que fez.

### `:stun` — o recibo que vira relógio

Publicado pelo **Combat** quando uma tecla de categoria `crowd` recebe recibo confirmado:

```elixir
%{key: "1", at: 1786941533474, confirmed?: true}
```

A engine lê e calcula `asleep_until = at + engine_stun_sleep_ms`. É assim que a sequência atravessa três processos sem ninguém chamar ninguém.

---

## 6. A máquina

`Pokex.Bots.Engine.Logic` é função pura de `(situation, config, now) → {logic, orders}`.

| estado | o que é | sai quando |
|---|---|---|
| `:travelling` | perna comum | entra em perna de mobada → `:gathering` |
| `:gathering` | perna de mobada; fogo preso, rota andando | chega no ponto de matança → `:sizing` · vida cai pro amarelo → `:closing` |
| `:sizing` | parado no ponto, contando quem chega | `enemies ≥ 3` **e** `stable_for_ms ≥ pile_settle_ms` → `:engaged` · teto `size_ceiling_ms` com `enemies < 3` → `:travelling` (**não luta**, R1) |
| `:engaged` | fogo livre com a abertura em área | tela limpa → paradas da esquina → `:travelling` · vida no amarelo → `:closing` |
| `:closing` | **a rodada amarela** (abaixo) | revive disparado → `:recovering` |
| `:recovering` | revive disparado | pokémon de volta e vida ≥ `resume_pct` → `:travelling` |
| `:emergency` | vermelho | revive imediato, sem esperar nada → `:recovering` |

**A sequência de `:closing`** — a única que atravessa os três workers, e a razão de existir uma engine:

1. `route: :hold` — para de estender a mobada na hora (R2: não arrasta mais ninguém).
2. Espera a pilha chegar — mesma régua do `:sizing`, com teto.
3. `stun: :now` — o Combat aperta a tecla `crowd` e publica `:stun`.
4. `fire: :free` com `opening` cheia — gasta tudo no que está dormindo.
5. Tela limpa **ou** `asleep_until` prestes a expirar → `revive: :now` (R3: cooldowns já gastos, o revive faz os dois serviços).
6. `:recovering` → volta pra rota com vida cheia e cooldown zerado.

**A marca `cooldown_revive` da rota vira dica, não ordem.** Naquela esquina a engine revive **se** a vida estiver abaixo do amarelo ou os cooldowns estiverem realmente gastos. Senão pula e escreve: `pulei o reset: vida 92%, cooldowns prontos`. A rota dele não perde nada; ela para de mandar.

### Números — todos herdados do que ele já configurou

| knob | valor | de onde vem |
|---|---|---|
| `engine_engage_from` | 3 | R1 |
| `engine_pile_settle_ms` | 1500 | **a medir na PR 1** |
| `engine_size_ceiling_ms` | 4000 | maior `gather_ms` gravado por ele (4806), arredondado pra baixo |
| `engine_stun_sleep_ms` | 2000 | proposta dele |
| `engine_band_yellow_pct` | 60 | = `pokemon_hp_rescue_pct` atual |
| `engine_band_red_pct` | 30 | = `cavebot_hp_abort_pct` atual |
| `engine_resume_pct` | 80 | = `cavebot_hp_resume_pct` atual |

Nenhum número inventado por mim. Os dois que eu não sei estão marcados "a medir".
Todo knob entra em `Pokex.Settings` **com faixa** — e a faixa tem que cobrir o valor que os testes usam (o `SettingsStash` recusa fora de faixa; já custou uma sessão).

---

## 7. Contratos: quem executa o quê

As mãos ficam onde estão. A engine decide; ninguém mais decide.

| worker | continua dono de | passa a obedecer |
|---|---|---|
| **Cavebot** | andar (passos de minimapa), rota, escadas, paradas, varredura | `orders.route` |
| **Combat** | teclas via `Rig.press_many`, Tab, alvo, recibos | `orders.fire`, `orders.opening`, `orders.stun` |
| **PlayerSupport** | `Body.perform` no `:critical`, cursor no retrato, combos | `orders.revive`, `orders.potion` |

**Fica como reflexo, fora da engine:** a skill de cura do Suporte (instantânea, de graça, funciona em combate — não precisa de contexto pra estar certa) e todo o aparato de pânico.

---

## 8. Tabela de degradação — a promessa de segurança

O que cada worker faz quando `:orders` está velho, ausente, ou a engine morreu:

| worker | sem ordem | por quê |
|---|---|---|
| **Combat** | fogo livre | um bot pacifista com o cérebro morto é a pior falha possível — mesma regra do `:posture` hoje |
| **Cavebot** | segue a rota | parar no meio da caverna não é mais seguro que andar |
| **PlayerSupport** | escada de HP de hoje (cura → poção → resgate) | a proteção do personagem nunca depende do cérebro |

**Engine morta = o bot de hoje.** Essa é a linha que autoriza o caminho 2, e ela vira **teste de contrato**: um por worker, provando que ordem velha reproduz o comportamento atual.

---

## 9. Backend: as regras do processo

**Tick de 200ms**, o mesmo do Cavebot. Os fatos que ela lê são mais rápidos que isso: `:battle` a cada 120ms, `:skill_bar` 400ms, `:minimap` 500ms.

**Os feeds são sob demanda — a engine precisa se anexar.** `Perception.Feed` só captura enquanto alguém está anexado (`feed.ex:8`), e é por isso que a engine chama `Perception.attach(:battle)` e `attach(:skill_bar)` no `run`. Sem isso ela decidiria sobre um quadro que ninguém está pintando quando o Combat estiver ocioso.

**Mini-game congela tudo.** Os feeds pulam a captura enquanto `Perception.mini_game_playing?()` (`feed.ex:84`), porque a captura serializada pertence à capsula. A engine faz o mesmo: com o mini-game na tela ela publica `phase: :held` e para de decidir. Fato velho durante o mini-game não é sinal de nada.

**O latch de pânico é cerca dupla.** A engine consulta `InputGate` e não emite ordem com ele erguido; **e os executores continuam checando por conta própria**. Duas cercas, porque a cerca que depende do cérebro é a que falha quando o cérebro falha.

**Supervisão.** `Engine.Worker` entra no `BotSupervisor` como filho `:one_for_one`, e no `@run_order` **antes** do cavebot (que já é o último, por arrancar andando). Reiniciar é barato e não tem estado que valha preservar: o primeiro tick reconstrói o quadro dos fatos.

**Nada de blocking.** Sem `Body.perform`, sem `Capture.frame`, sem `GenServer.call` para worker. Se um dia precisar de algo caro, vai por fato — nunca por chamada.

**`defp` nunca entre cláusulas de `handle_info`** (mata o compile com `--warnings-as-errors`; a armadilha já documentada).

---

## 10. Persistência: o que hoje chamamos de "db", e o que precisa mudar

**Estado atual, medido:** o projeto **não tem banco**. Nenhum Ecto, nenhum Postgres, nenhum SQLite no `mix.exs`. A persistência é arquivo JSON sob `~/.pokex` (`Pokex.Home` + `Pokex.StateFile`, que serializa read-modify-write porque duas escritas concorrentes já apagaram uma rota inteira em silêncio) e o journal em JSONL (`journal.ex`): anel de 500 eventos em memória, só `:macro` e `:alarm` vão pro disco, 14 dias de retenção.

**O problema pra ficar inteligente:** o journal guarda **prosa**. `"waypoint 12/45 · 2286,30013 andar 5"` é ótimo pra ler de manhã e inútil pra perguntar *"qual o tamanho médio da pilha na esquina 15 nas últimas 7 noites?"*. E a contagem de inimigos — o número que vai decidir tudo — **não é escrita em lugar nenhum hoje**.

**Desenho: dois arquivos, duas audiências.**

- `~/.pokex/journal/AAAA-MM-DD.jsonl` — continua como está. **A história**, em português, pra humano.
- `~/.pokex/events/AAAA-MM-DD.jsonl` — novo. **O dado**, tipado, pra máquina:

```json
{"at":1786941533474,"kind":"size","corner":15,"enemies":4,"stable_ms":1800,"hp":47,"band":"yellow"}
{"at":1786941535112,"kind":"engage","corner":15,"enemies":4,"opening":["3","4","5"]}
{"at":1786941541880,"kind":"stun","key":"1","confirmed":true}
{"at":1786941543010,"kind":"revive","reason":"closing","hp_before":41,"enemies":0}
{"at":1786941549002,"kind":"skip","corner":16,"enemies":1,"why":"pilha pequena"}
```

Um escritor (`Pokex.Engine.Events`), append-only, mesma disciplina do journal: gate por env pra suíte nunca escrever no `~/.pokex` real, retenção por dias, escrita atômica.

**Por que não SQLite agora.** Volume real: um jogador, algumas milhares de linhas por noite, arquivo na casa dos poucos MB. Reler 7 arquivos pra um agregado leva menos que um piscar. Adicionar Ecto + SQLite significa dependência nova, migrations, supervisão e setup de teste num projeto que hoje tem **zero** disso — custo alto pra um ganho que ainda não dói.

**O gatilho pra virar SQLite** (escrito aqui pra não virar discussão de opinião depois): quando qualquer uma acontecer — (a) uma noite passar de ~50MB de eventos, (b) a Central precisar de agregado cross-noite a cada render, ou (c) a gente quiser consulta ad-hoc de verdade pra calibrar regra. Aí entra `ecto_sqlite3` com o JSONL virando o formato de importação.

**O que os eventos compram, em ordem de valor:**

1. **Medir a régua.** O `pile_settle_ms` real e o tamanho real das pilhas — os dois números que hoje eu chutaria.
2. **Médico de rota com dado.** Hoje o `#route-doctor` acha os 20 cantos colados por geometria; com eventos ele passa a dizer *"a esquina 16 nunca juntou 3 em 6 noites"* — o argumento pra apagar.
3. **Desfecho de decisão.** Revive disparou → o pokémon sobreviveu? Stun saiu → ainda tomamos dano? É o que transforma R4 de suposição em número.
4. **Replay.** Alimentar `Engine.Logic` com uma noite gravada e conferir as decisões contra o que aconteceu. É a prova nº 6 da seção 3.

---

## 11. Logs: o que muda

**Hoje:** strings de prosa em `:macro`/`:alarm` (persistem) e `:debug` (só memória). O Journal escuta os tópicos `fishing combat catcher mini_game game body cavebot logout`.

**Mudanças:**

- **`"engine"` entra na lista de tópicos** do Journal. Sem isso as decisões não sobrevivem a um reload — exatamente o buraco que a PR #296 fechou pro resto.
- **Uma linha por mudança de ordem**, nunca por tick: `🧠 amarelo: fechando a rodada com 4 inimigos` / `🧠 pulei a pilha: só 1 inimigo na esquina 16`. Em `:macro`, porque `:debug` não chega no disco e o disco é onde a noite é lida.
- **A contagem entra nas linhas que já existem.** `waypoint 12/45 · 2286,30013 andar 5` vira `waypoint 12/45 · 2286,30013 andar 5 · 4 inimigos`. Custo zero, e responde metade das perguntas de manhã.
- **Setor de alarme próprio** (`:engine`), pra poder ser mutado sem calar o resto — a lição da PR #300, onde alarmes caíam no `:geral` inmutável.
- **O `why` é a mesma string** que a tela mostra e o evento estruturado carrega. Uma frase, três destinos: sem tradução, sem divergência.

---

## 12. Front-end: onde isso mora, e a regra que impede o inchaço

**Estado atual, medido:** `panel_live.ex` 3716 linhas, `cavebot_live.ex` 2996, `calibration_live.ex` 2523. O `cavebot_live` já é o emaranhado nomeado na análise anterior, e existe um `cavebot_components.ex` (411 linhas) onde a decomposição começou.

**Regra desta empreitada: `cavebot_live.ex` só pode encolher.** Nenhuma PR da engine adiciona linha líquida nele. O card da engine nasce em componente próprio (`lib/pokex_web/components/engine_panel.ex`), e toda PR que precisar tocar o LiveView leva junto um pedaço pra fora. Marco atual: **2996 linhas** — o número vai na descrição de cada PR.

**O que a tela ganha:**

- **Card "o que ele está pensando"** — o quadro (`:situation`) em números grandes: inimigos, vida, faixa, teclas prontas, relógio do stun. É o que faltava pra ele *ver* a decisão em vez de deduzi-la.
- **A frase `why`, permanente**, no topo do card. Uma linha, sempre atualizada.
- **Modo sombra (PR 2):** duas colunas, "a engine mandaria" × "o bot fez", com destaque quando divergem. É a tela que autoriza a PR 3 — e ela é temporária de propósito: sai quando os workers obedecerem.
- **Faixas de vida visíveis** no card de segurança: verde/amarelo/vermelho com os limiares dele, editáveis ali.

**Higiene que vem junto** (dívida já conhecida, paga onde encostar): o card de log e o médico de rota saem do `cavebot_live` pra componentes; nada de `assign` novo que duplique o que o fato já diz — a tela lê o mural, não guarda cópia.

---

## 13. Refactors: o que sai, o que encolhe

Só depois das PRs 3–5 no ar e medidas. Nada disso sai antes de o substituto estar provado.

| some | linhas hoje | vira |
|---|---|---|
| fato `:posture` + `publish_posture/2` | `cavebot/worker.ex:375` | `orders.fire` + `orders.opening` |
| `Cavebot.Logic.gathering?/2` e o relógio `gather_wait` | `logic.ex:313` | estado `:sizing` (contagem, R1) |
| `recovering?` / `recovering_after/2` / `destination_combo/1` / `hold_patience/2` | `logic.ex` | faixas + `:closing` |
| `Cavebot.Logic.hold_fire?/2` | `logic.ex:287` | `orders.fire` |
| `PlayerSupport.Logic.decide/1` | `player_support/logic.ex:25` | `orders.revive` |
| `run_stop(:cooldown_revive)` incondicional | `logic.ex:1122` | dica avaliada pela engine |
| campo `posture` no `Combat.Logic` | `combat/logic.ex:75` | `orders.fire` |

Efeito esperado: `cavebot/logic.ex` (1223) e `player_support/worker.ex` (1139) encolhem de verdade, e a lógica tática deixa de estar espalhada em três lugares.

**Um emaranhado de nome que vale desfazer no caminho:** existem dois conceitos chamados "combo" — `Pokex.Combos` (disparado por inimigo, com Runner próprio) e a rajada de abertura do Combat. São coisas sem relação. A engine só fala com a segunda; a primeira ganha nome próprio na PR 6 ou fica documentada como intocada.

---

## 14. Testes

- **`Engine.Situation`**: fatos → quadro. Tabela cobrindo leitura ausente, velha, e layout não localizado (sem `enemies_detail`, onde só sobra a contagem crua).
- **`Engine.Logic`**: `(quadro, config, agora) → ordens`. **A árvore inteira do Lucas vira tabela**: as três faixas, a régua de 3, o teto da ganância, a sequência amarela ponta a ponta, e o relógio do stun expirando no meio dela.
- **Contrato de degradação**: um teste por worker provando que ordem velha = comportamento de hoje (seção 8).
- **Replay**: alimentar a máquina com o `events.jsonl` de uma noite real e conferir as decisões. É o que impede o desenho de virar teoria.
- Ordem de asserção importa: `assert_receive` com padrões disjuntos **não** testa ordem (armadilha já documentada).

---

## 15. Sequência de PRs

Uma limitação observável por PR, `mix precommit` zerado, strings pt-BR, `cavebot_live.ex` nunca cresce.

**PR 1 — Medir antes de mexer.** ✅
`Engine.Situation` (pura) + `Engine.Worker` publicando o fato `:situation` + as duas medições narradas no journal (fonte `engine`, que a Central passa a semear e ouvir). **Zero mudança de comportamento.** Resolve duas coisas que nenhuma regra pode assumir:

- **A contagem que vai decidir tudo não é escrita em lugar nenhum hoje.**
- **A discordância sobre a própria linha:** o código afirma, em comentário de medição, que o pokémon dele **não** aparece na lista (`interpret.ex:44`); ele diz que é sempre a primeira linha. A captura de 11/08 22:14 mostra uma linha só, "Vileplume", com pokébola à direita, numa época em que o Shiny Vileplume estava no time — sugere que ele tem razão, mas captura estática não separa "meu pokémon" de "capturável marcado por quest". **Isso muda a régua em 1, que é a diferença entre atacar e ignorar.** Registrar o nome de cada linha resolve com dado dele, numa volta de caçada.

**PR 2 — A engine que só narra.** ✅
`Engine.Logic` (a árvore inteira dele, pura) + o fato `:hunt` que o Cavebot passa a publicar (onde a rota está, para a engine raciocinar sobre a perna e não só sobre a tela) + `Engine.Worker` publicando `:orders` + a **sombra no feed**: uma linha 🧠 por mudança de decisão, no mesmo lugar onde as linhas da caçada já caem. **Nenhum worker obedece.**

A sombra saiu no feed em vez de numa tela nova de propósito: a comparação "a engine mandaria × o bot fez" só vale se as duas colunas estiverem no mesmo texto, na mesma ordem cronológica — e é onde ele já lê. O card visual e o `Engine.Events` foram adiados pra PR 3, com o `cavebot_live.ex` intocado aqui (segue em **3002**).

**PR 3 — O quadro na tela, e o `cavebot_live` encolhendo.** ✅
A faixa `#engine-brain` em componente próprio (faixa da vida por palavra e cor, contagem, "parados há Ns", e a frase `why`), e a extração que paga a regra do "só encolher": o médico de rota saiu do LiveView pro `CavebotComponents`, e o arquivo fechou em **2982** (era 3002). `Pokex.Engine.Events` ficou pra PR seguinte — a faixa é o que ele precisa DURANTE o teste; o log estruturado é o que eu preciso DEPOIS.

**PR 4/5 — Combat e Cavebot obedecem.** ✅ (#307, "o combate obedece, e a noite vira número")
`fire`/`opening` no Combat (a régua de 3 entra em vigor; `:posture` vira compatibilidade) e `route: :go | :hold` + a marca `cooldown_revive` virando dica no Cavebot, no mesmo PR. `Pokex.Engine.Events` (o JSONL estruturado) nasceu aqui também.

O `stun` foi tirado desta PR de propósito: Combat apertando a tecla reservada e o Suporte revivendo por conta própria são duas metades do mesmo mecanismo, e subir só uma repete o erro que já matou o pokémon dele uma vez.

**PR 6 — Suporte obedece.** ✅ (#309, "o suporte fecha a rodada, e o segundo apertador desaparece")
`revive` — não `potion`, que nenhuma regra da Logic decide ainda e ficou de fora por não ter o que obedecer.

**Correção de desenho, achada ao ler `PlayerSupport.Worker` de perto pela primeira vez nesta etapa:** o plano original (PRs 2–5) tinha o Combat apertando um stun PRÓPRIO no meio da rodada amarela, cedo, para o revive no fim reaproveitar o sono. Mas `PlayerSupport` já tem, desde as PRs #285/#289, um combo ATÔMICO e testado em campo — aperta a tecla reservada, CONFIRMA pelo recibo, espera o resto do sono, só então recolhe — tudo dentro de um `Body.perform` só (`PlayerSupport.Logic.combo/1`). Dois apertadores da MESMA tecla reservada, um cedo (Combat) e um tarde (Suporte), é exatamente o tipo de coincidência de tempo que já causou o erro que R4 existe para evitar.

Então o desenho mudou: a engine decide só o QUANDO (`revive: :now`), nunca o COMO — o combo velho de `PlayerSupport` continua sendo o único a apertar a tecla reservada, sem mudança nenhuma nele. `orders.stun`, o fato `:stun`, `asleep?`/`asleep_until` em `Situation`, e todo o encanamento de `reserved` no `Combat.Worker` — nada disso chegou a ser usado de verdade (o `Combat` nunca aperta a tecla reservada em rotina nenhuma) e foi removido na mesma PR que ligou o Suporte.

**PR 7 — Limpeza. ADIADA (2026-08-17), com uma condição escrita.**

Fui abrir esta PR — remover `:posture`, `Cavebot.Logic.gathering?/recovering?`, `PlayerSupport.Logic.decide/1` como a tabela da seção 13 manda — e travei antes do primeiro commit. Essas funções não são código morto: são o **piso de segurança** da Tabela de Degradação (seção 8), a linha que autoriza o caminho 2 inteiro — **"engine morta = o bot de hoje"**.

Hoje `Combat.Worker.posture/0` tem DUAS camadas de queda: engine → fato `:posture` (a lógica antiga, ainda esperta) → só se isso também sumir, fogo livre cego. A tabela da seção 13, seguida ao pé da letra, apaga a camada do meio — vira engine viva ou bot cego, sem meio-termo. A mesma coisa vale para `PlayerSupport.Logic.decide/1`: é o piso que a Tabela de Degradação promete ("escada de HP de hoje") quando `orders.revive` está velho ou ausente.

Apagar esse piso justo agora seria trocar velocidade por risco na pior hora: `orders.revive` foi mergeado nesta mesma sessão (#309) e **ainda não tem uma noite de campo validando** que a engine decide bem sozinha, e o bug das skills que não saem (17/08) continua aberto — o sistema já não está 100% confiável, e não é quando se tira a rede debaixo dele.

**A condição pra reabrir:** algumas noites reais (a começar por uma inteira, sem parada manual) confirmando que a engine decide bem sozinha em `fire`/`route`/`revive` — e só então a tabela da seção 13 sai como estava planejada. Até lá, a tela de sombra e o `cavebot_live.ex` continuam como estão; não há razão de segurança pra tocar neles antes.

---

## 16. Invariantes que não se movem

- Kill corner → `set_panic_latch(true)` → halt da frota. Nunca passa pela engine.
- Cerca dupla no latch: engine **e** executores.
- `Body.perform` nunca dentro do tick de ninguém; a engine nem toca no `Body`.
- Fatos ausentes falham abertos (seção 8), sempre.
- `Recording.tidy/1` move marcas, nunca o caminho — apagar esquina é decisão do Lucas.
- Escrita em arquivo de estado passa pelo `StateFile`.
- `defp` nunca entre cláusulas de `handle_info`.

---

## 17. Pendências e medições

- **A medição da PR 1**: a própria linha do pokémon na lista, e o `pile_settle_ms` real.
- **Queixa nº 5 dele, ainda sem diagnóstico**: *"usou duas skills em área e não conferiu a área para ver se matou tudo"*. Com `enemies_named` carregando `hp_pct` por linha, vira provavelmente uma regra de `:engaged` — não uma PR própria.
- **Fase 1 do roteiro anterior (movimento)** segue travada esperando uma volta com `cavebot_measure_walk` ligado. Independente desta empreitada.
- **Decisões dele ainda em aberto** no roteiro de 14/08: resgate armado por padrão no modo caçada? fuga automática existe? — nenhuma bloqueia a engine.
