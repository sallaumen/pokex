# Desenho: o simulador de caçada — fase 1, a fundação

> Data: 17 de agosto de 2026
> Lido a partir de: `main` em `eb119d0`
> Natureza: desenho de arquitetura. Autoriza a sequência de PRs da seção 14, nada fora dela.
> Origem: Lucas, 17/08 — *"a ideia é você criar um simulador do jogo numa nova aba (…) a gente fazer que nem a gente fez no Phishing (…) ver os feedbacks com o nosso próprio simulador pra IA, que hoje você não tá conseguindo simular bem porque o jogo é uma coisa externa. E aí toda hora eu preciso ficar testando e o teste nunca dá certo direito."*
> Irmão de: `docs/refactor/desenho-engine-2026-08-17.md` (a engine que este simulador existe para exercitar).

---

## 1. O problema, dito com precisão

O jogo é externo. Toda mudança de regra tática hoje se prova de um jeito só: Lucas abre o PXG, caça, e depois lê o journal. Isso tem três custos que já apareceram no histórico deste projeto:

1. **O laço de feedback é de horas, não de segundos.** Uma hipótese sobre `pile_settle_ms` custa uma noite de caçada.
2. **O experimento não é repetível.** Duas voltas na mesma rota não produzem a mesma pilha, então "melhorou" nunca é medida — é impressão.
3. **A verdade é invisível.** No jogo real, ninguém pode comparar *o que existia na tela* com *o que o bot leu*. Quando a decisão sai errada, não há como separar "os olhos erraram" de "o cérebro errou". O handoff da IA anterior é explícito sobre o preço disso: quatro briefings dela tinham defeito real, e o que os pegou foi ceticismo, não teste.

Um simulador não substitui a caçada real. Ele muda a natureza da pergunta que se leva pra caçada real: em vez de *"será que funciona?"*, vira *"o mundo se comporta como eu modelei?"* — que é uma pergunta muito mais barata de responder.

**E ele tem um segundo uso, imediato:** o laço do recibo de skill (aperta → barra muda → `SkillReceipt` confirma) fecha inteiro dentro do simulador. Esse é exatamente o laço que está quebrado hoje (journal de 17/08, 2ª run: 6 aberturas, 6 `🔁 não saiu`, zero `alvo morto`). Se ele fechar no simulador, o defeito está no mundo real — barra calibrada pro pokémon errado, ou tecla não chegando ao jogo. Se não fechar nem aqui, é lógica, e se acha sem abrir o PXG.

---

## 2. Por que este projeto já está pronto pra isso

Três costuras existem hoje, e nenhuma foi feita pensando em simulador — são consequência do desenho por fatos:

| costura | onde | o que ela permite |
|---|---|---|
| **As mãos têm plugue** | `Pokex.Rig.impl/0` é `Application.get_env(:pokex, :rig, Pokex.Rig.Mac)`; `config/test.exs` já usa `Pokex.Rig.Fake` | Trocar quem recebe as teclas sem tocar em quem as decide |
| **Os olhos têm plugue** | `Perception.attach/detach` viram no-op sob `perception_feeds_active: false` (já desligado em teste) | Desligar a captura sem desligar os consumidores |
| **A frota é nomeável** | `BotSupervisor` recebe o nome de cada worker por opção | Fica aberta a porta pra frota gêmea, se um dia valer |

E, o achado que fecha a segurança: **`Body.execute/1` despacha *toda* ação por `Rig.impl()`** — `press`, `click`, `move`, `tap`, `focus_click`, `capture_sequence`. O `Combat` chama `Rig.press_many` direto; o `Capture` chama `Rig.impl().capture_screen()`. Não existe caminho lateral: `Rig.impl()` é o **único** ponto por onde qualquer coisa sai deste programa para o Mac. Trocar esse módulo fecha todas as portas de uma vez.

---

## 3. Escopo: três fases, e este spec é da primeira

Lucas marcou quatro grupos de cenário (a régua e a pilha · vida, revive e morte · mãos que falham · rota e cegueira). Isso não cabe numa empreitada.

| fase | entrega | prova de pronto |
|---|---|---|
| **1 — a fundação** *(este spec)* | O mundo falso, a cerca, os olhos e mãos trocados, e a aba `/sim` assistindo | Uma caçada **normal** roda de ponta a ponta na `Meganium and Venoss` com a frota **de verdade**, e o jogo não é tocado |
| **2 — os cenários** | Os quatro grupos como arquivos declarativos com injeção de falha | Um clique em "pilha pequena na esquina 16" mostra a engine decidindo pular |
| **3 — a bancada** | Fast-forward, replay dos `events/*.jsonl`, varredura de knobs lado a lado | `pile_settle_ms` deixa de ser chute |

A fase 1 é a única com risco de arquitetura. As fases 2 e 3 são conteúdo sobre uma base pronta.

---

## 4. A decisão de arquitetura

**Escolhido: trocar os olhos e as mãos de uma frota só** (Lucas, 17/08: *"Os workers reais (GenServers)"*).

A frota real — `Engine.Worker`, `Cavebot.Worker`, `Combat.Worker`, `PlayerSupport.Worker`, `Body` — roda **sem uma linha alterada**, lendo exatamente os fatos que lê hoje, nas cadências de hoje. O que muda é de onde os fatos vêm e para onde as teclas vão.

**Rejeitado: a frota gêmea** (instanciar o `WorldState`, subir um segundo `BotSupervisor` com quadro próprio). São 54 chamadas em 16 arquivos, incluindo o Guardian e o caminho de pânico — o único código do projeto onde errar não dá erro, dá tecla presa com ninguém olhando. O ganho ("simular enquanto caço") não paga esse risco.

**Onde roda:** no servidor de sempre (`:4000`), com trava (Lucas, 17/08). A consequência aceita é que a cerca é **código**, não estrutura — e é por isso que a seção 5 é a seção mais importante deste documento, e a seção 11 lhe dá dois testes.

---

## 5. A cerca

`Pokex.Sim.Fence` é um GenServer supervisionado e é o **único** dono do estado armado. Nunca a LiveView: uma aba fechada não pode devolver o teclado ao jogo com a frota andando.

A ordem é copiada do caminho de pânico do AGENTS.md — *"o latch é erguido ANTES de qualquer coisa ser parada"*. Aqui: **o rig falso é armado antes de qualquer coisa subir; o rig real só volta depois de tudo estar parado.** A cerca é a ordem, não a intenção.

### Armar

0. **Recusa** se `BotSupervisor.safe_status/2` mostrar qualquer worker rodando, e diz quais. Armar **nunca** interrompe uma caçada em curso por conta própria — o botão volta como *"parar tudo e armar"*, e aí o `stop_all` é ato dele, explícito, não efeito colateral de um clique em outra coisa. (Desvio consciente da opção que ele escolheu, que dizia "para tudo antes": uma tecla que interrompe oito horas de caçada por engano é cara demais para ser implícita.)
1. `Application.put_env(:pokex, :rig, Pokex.Rig.Sim)` — **primeiro de tudo**.
2. `Application.put_env(:pokex, :perception_feeds_active, false)`.
3. `Application.put_env(:pokex, :journal_persist, false)` — uma simulação não suja o journal que ele lê de manhã. O anel em memória continua, então o feed ao vivo funciona igual.
4. Halta `Guardian` e o vigia de foco: são sensores apontados para uma tela que não é a simulação.
5. **E só então** sobe o `Sim.Runner` e a frota.

### Desarmar

1. `BotSupervisor.stop_all` e para o `Sim.Runner`.
2. Confirma que pararam.
3. **E só então** devolve `rig`, `perception_feeds_active`, `journal_persist`, e os sensores.

### Quando algo morre

O `Fence` guarda a configuração original no seu próprio estado e a restaura em `terminate/2`, **na ordem de desarmar**. Se ele for morto de forma que `terminate` não rode, o supervisor o reinicia e o `init/1` detecta o rig falso ativo sem simulação rodando: ele **halta a frota primeiro e devolve o rig depois**. Na dúvida, o rig falso é o estado seguro. O contrário nunca.

### A trava do outro lado

`BotSupervisor.start_all/0` passa a recusar enquanto o `Fence` estiver armado. É uma linha, e é ela que torna impossível o único cenário que machuca: simulação armada com a caçada real subindo por baixo.

### A tarja

Enquanto armado, **todas** as páginas mostram uma tarja no header (o `HeaderState` já existe para isso). Ele nunca pode ficar em dúvida sobre em qual mundo está olhando.

---

## 6. Os módulos novos

```
                 ┌────────────────────────────────────────────┐
                 │ Pokex.Sim.World            (PURA)          │
                 │ step(world, dt) · press(world, key)        │
                 │ observe(world, :battle | :pokemon | ...)   │
                 └───────────────┬────────────────────────────┘
                                 │ é o estado de
                 ┌───────────────▼────────────────────────────┐
                 │ Pokex.Sim.Runner           (GenServer)     │
                 │ tick 50ms → World.step                     │
                 │ publica cada fato NA CADÊNCIA REAL DELE    │
                 │ difunde no tópico "sim" para a tela        │
                 └───────────────▲────────────────────────────┘
                                 │ as teclas chegam aqui
                 ┌───────────────┴────────────────────────────┐
                 │ Pokex.Rig.Sim   @behaviour Pokex.Rig       │
                 │ nenhuma linha que alcance o SO             │
                 └────────────────────────────────────────────┘

   A FROTA REAL, sem alteração: Engine · Cavebot · Combat · PlayerSupport · Body
   lendo o quadro :pokex_world exatamente como hoje.
```

### `Pokex.Sim.World` — pura

```elixir
%World{
  route: %Pokex.Bots.Cavebot.Route{},   # a rota REAL, do routes.json
  leg: 0,                               # índice da esquina atual (só para a tela)
  pos: {2286, 30013, 5},
  own: %{name: "Vileplume", hp_pct: 100, out?: true, alive?: true},
  mobs: [%{id: 1, name: "Venonat", pos: {…}, hp_pct: 100,
           spawn: {…}, leash_tiles: 12, speed_ms: 320, bite: %{dmg: 4, every_ms: 900}}],
  keys: %{"3" => %{kind: :area, cooldown_ms: 8_000, ready_at: 0, dmg: 34, radius: 4}},
  target: nil,
  clock: 0,
  seed: 42,                             # determinismo: mesma semente, mesma caçada
  knobs: %{…}                           # a tabela da seção 7
}
```

Três funções e nada mais:

- **`step(world, dt_ms) → world`** — move os mobs em direção ao jogador; aplica mordidas; aplica dano pendente; mata; **despawna quem passou do leash** (é a R2 virando mecânica, não regra); faz nascer mob novo conforme a densidade da perna; avança cooldowns.
- **`press(world, key) → world`** — a tecla vira efeito. Seta = um passo. Skill de área = dano em todos dentro do raio. Skill single = dano no alvo. Tab = troca alvo. A tecla reservada = stun. **A escada é mecânica de mundo**: a tecla de escada anda dois tiles e muda o `z` (sem ela a `Meganium and Venoss`, que cruza os andares 5 e 6, não anda de ponta a ponta — e a prova da fase 1 é justamente a volta completa).
- **`observe(world, key) → obs`** — produz o fato no formato exato do interpretador real (seção 8).

Pura de propósito: sem ETS, sem relógio, sem processo. A caçada inteira vira tabela de teste.

### `Pokex.Sim.Runner` — GenServer

Tick de 50ms, mais fino que qualquer consumidor. Avança o mundo e publica **cada fato na cadência real dele** — `:battle` a 120ms, `:skill_bar` a 400ms, `:minimap` a 500ms. Publicar tudo junto a cada tick seria mentir sobre o problema mais interessante que o bot tem: fatos de idades diferentes.

Difunde no tópico `"sim"` o quadro completo (verdade **e** percepção) para a tela.

### `Pokex.Rig.Sim` — `@behaviour Pokex.Rig`

Cada callback ou manda um `cast` para o `Runner` ou devolve uma constante segura. `capture_screen/0` responde `{:error, :simulated}` — e como os feeds estão desligados, ninguém pergunta. **Não consulta o `InputGate`**: a porta existe para proteger o jogo real, e no simulador não há jogo real ao alcance. (Reproduzir "a porta engoliu minha tecla" é cenário da fase 2, injetado de propósito, não efeito colateral de o navegador estar em foco.)

---

## 7. O mundo: os números, com etiqueta

Regra dura desta empreitada: **nenhum número do mundo falso pode ser invenção anônima.** Um simulador calibrado no olho ensina o que eu acho, não o que o jogo faz. Cada knob nasce com etiqueta, e as inventadas aparecem na tela como slider.

| knob | valor de partida | etiqueta | de onde vem |
|---|---|---|---|
| tempo até a pilha fechar | amostrado da distribuição real | **medido** | os `gather_ms` da mão dele: 198, 569, 1158, 1264, 1651, 1851, 2088, 2474, 2543, 2701, 2725, 3248, 3274, 3332, 3918, 4534, 4707, 4806, 6007 |
| duração de uma matança | amostrado das lições | **medido** | os `fight_ms` gravados (356ms a 19.6s) |
| cooldown de cada skill | do arquivo | **herdado** | `team.json` real |
| `engage_from`, faixas verde/amarelo/vermelho, `resume_pct` | dos ajustes | **herdado** | `Pokex.Settings` reais |
| **velocidade do personagem (ms/tile)** | 320ms | **inventado — o pior buraco** | ver abaixo |
| raio da lista de batalha | 7 tiles | **inventado** | slider |
| leash do mob (R2) | 12 tiles do spawn | **inventado** | a *regra* é dele; o número é meu |
| mordida do mob (dano, intervalo) | 4% a cada 900ms | **inventado** | slider |
| densidade de mobs por ninho | 2 a 6 | **inventado** (o *lugar* não é) | slider |

**Onde os mobs nascem não é chute.** Os ninhos ficam nas esquinas que carregam `gather_ms` ou `fight_ms` — ou seja, exatamente onde a mão dele parou pra mobar ou pra matar. A rota gravada já é o mapa de onde há bicho; inventar posições de spawn seria jogar fora o único dado espacial confiável que existe.

### A medição em aberto vira um botão

O desenho da engine deixa uma pergunta sem resposta: **o pokémon dele ocupa uma linha da lista de batalha?** `interpret.ex:44` registra uma leitura dizendo que não; ele diz que sim. A diferença é 1, e 1 é a distância entre atacar uma pilha e ir embora dela.

O simulador não resolve isso (só a caçada real resolve), mas faz melhor do que escolher um lado: **é um botão na tela.** Rodar o mesmo cenário com a linha própria presente e ausente mostra, em segundos, *quanto* a régua de 3 se mexe — e transforma uma discordância de memória em uma diferença medida. Se o impacto for grande, ele sobe na fila da caçada real; se for pequeno, para de ser assunto.

### O buraco declarado

**Ninguém nunca mediu tiles por segundo.** O handoff da IA anterior é explícito: *"Nobody measured tiles/s"*, e ela mesma marcou as próprias hipóteses de movimento como leitura de código, não medição. O `cavebot_measure_walk` existe no `/config` exatamente para isso.

Consequência que este spec assume: **o simulador nasce bom para decisão tática (contagem, faixa, revive, recibo) e fraco para timing de rota.** Enquanto uma volta na Meganium com `cavebot_measure_walk` ligado não existir, nenhuma conclusão sobre tempo de caminhada tirada daqui vale. Isso fica escrito na tela, ao lado do slider.

### O outro dado que não existe

`~/.pokex/events/` **não foi criado** — o escritor estruturado da #307 nunca produziu arquivo. A contagem real de inimigos por esquina, que é o número que decide tudo, continua sem ser medida em lugar nenhum. Isso não bloqueia a fase 1; muda o papel dela: **o simulador é o motivo para esse dado começar a existir**, e a fase 3 é quem o consome.

---

## 8. Os fatos publicados — o contrato

O `Sim.World.observe/2` produz **exatamente** a forma que o interpretador real produz. Se o jogo mudar de forma um dia, o simulador tem que quebrar junto, e não continuar mentindo com confiança.

| fato | cadência | forma (conferida contra `perception/interpret.ex`) |
|---|---|---|
| `:battle` | 120ms | `%{enemies: [linhas], enemies_detail: [%{row, name, hp_pct, shiny?}], red: _, hp: [_], locked?: bool, locked_row: _, shiny_rows: [_], shiny_star_run: int}` |
| `:pokemon` | 120ms | `%{hp_pct: 0..100, readable?: bool}` |
| `:skill_bar` | 400ms | `%{ready_keys: ["3", "4"]}` |
| `:minimap` | 500ms | `%{pos: {x, y, z}}` |
| `:mini_game` | 1s | `%{playing?: false, confidence: 0.0}` — publicado de propósito, para `Perception.mini_game_playing?` nunca cair em fato ausente |
| `:layout` | uma vez ao armar | copiado do `layout_fix.json` real quando existir |

Duas sutilezas que o mundo falso **tem** que respeitar, porque são a matéria dos bugs:

- **`enemies` é lista de índices de linha, não de criaturas.** `Situation.read_battle` conta com `length/1`. Um simulador que publicasse nomes ali funcionaria por acidente e mentiria na primeira mudança.
- **`nil` é resposta legal.** Tela ilegível não é tela vazia — `enemies: nil` e `enemies: []` são fatos opostos, e o `Situation` já trata os dois. O mundo falso precisa saber produzir os dois (a *injeção* de ilegibilidade é fase 2; a *capacidade* é fase 1).

---

## 9. A tela — verdade contra percepção

`/sim`, uma aba nova. O que ela mostra é a única coisa que o jogo real nunca vai dar: os dois lados.

- **O mapa** (SVG, coordenadas reais): a rota desenhada, a perna atual destacada, o boneco, os mobs com anel de vida. Por cima, dois círculos que explicam a decisão inteira: o **raio da lista de batalha** (por que a contagem é 4 e não 7) e o **leash** de cada mob — o que está prestes a sumir pisca, e a R2 vira coisa que se vê.
- **Duas listas de batalha, lado a lado:** *o que existe* (verdade do mundo) e *o que o bot leu* (o fato `:battle`, com sua idade). Divergiram ⇒ o bug está nos olhos. Iguais e a decisão ruim ⇒ o bug está no cérebro. Isso sozinho separa metade dos bugs em duas pilhas.
- **O card da engine:** `phase`, `band`, `route`/`fire`/`revive`, e o `why` em português que a #304 já produz.
- **A linha do tempo:** cada mudança de decisão, cada tecla que saiu pelo `Rig.Sim`, cada recibo confirmado ou negado, cada fato publicado. É o *"bom tracking do que ocorreu"* do desenho da engine, ao vivo.
- **Os controles:** armar/desarmar, escolher rota, play/pause, e os knobs **inventados** como sliders — cada um com sua etiqueta à vista.

Visual: círculos e cores. Sprites bonitos não decidem nada e ficam para depois.

---

## 10. Degradação

A tabela da seção 8 do desenho da engine continua valendo dentro do simulador, e isso é uma *feature*: se o `Sim.Runner` morrer, os fatos envelhecem e cada worker volta ao que faz sem ordem — que é exatamente o comportamento que a gente quer poder observar. **Matar o Runner é um teste de degradação de graça.**

O que **não** degrada: a cerca. O `Fence` morrer nunca pode resultar em rig real com frota andando (seção 5).

---

## 11. A prova

| # | teste | o que garante |
|---|---|---|
| 1 | **A cerca** — armar com worker rodando recusa · armado, `Rig.impl() == Pokex.Rig.Sim` · matar o `Fence` para a frota **antes** de devolver o rig · `start_all` com o sim armado recusa | Que a trava é trava |
| 2 | **Nenhum vazamento, por estrutura** — lê o bytecode de `Pokex.Rig.Sim` e prova que ele não referencia `Pokex.Rig.Mac`, `System.cmd`, nem abre porta | Prova que não depende de eu ter tido cuidado |
| 3 | **Forma dos fatos** — `World.observe/2` casa com a forma que `Interpret` produz, chave por chave | Que o simulador não vai mentir com confiança |
| 4 | **O mundo é tabela** — `step/2` e `press/2` puros, casos de mesa: mob passa do leash e some · pilha para de crescer · skill entra em cooldown · escada anda dois tiles e muda `z` | A mecânica |
| 5 | **Integração** — sim armado, N ticks, e a frota **real** avança de esquina e a `Engine` publica `:orders` | Que a coisa toda anda junto |

Testes tocando nomes globais (`Rig`, `Application.put_env`) são `async: false`, pelo mesmo motivo que o `Rig.Fake` já é.

---

## 12. Fora de escopo da fase 1

Injeção de falhas e os quatro grupos de cenário (fase 2) · fast-forward e replay dos `events` (fase 3) · sprites · pesca, mini-game, catcher e timers · frota gêmea · `WorldState` instanciável · qualquer alteração em worker existente que não seja a recusa do `start_all` na seção 5.

**A exceção declarada:** a escada entra na fase 1 como mecânica de mundo (seção 6). Os *bugs* de escada continuam na fase 2.

---

## 13. Riscos conhecidos

1. **A cerca é código, não estrutura.** Foi decisão dele rodar no servidor de sempre. Os testes 1 e 2 da seção 11 são a mitigação, e o segundo é o que vale — ele não depende do meu cuidado.
2. **Fidelidade é o teto do valor.** Um simulador ensina o que foi modelado. A seção 7 é a defesa: etiqueta em cada número e o buraco de tiles/s declarado em voz alta, na tela, ao lado do slider.
3. **Armar deixa o bot real inutilizável** enquanto durar. É aceito: simulação e caçada não são para acontecer juntas, e a tarja do header existe para que isso nunca seja surpresa.
4. **O `Fence` mexe em `Application.put_env` em runtime**, que é global ao nó. É o preço da decisão da seção 4 e está cercado pela ordem da seção 5.

---

## 14. Sequência de PRs

| PR | o que entra | pronta quando |
|---|---|---|
| **1** | `Pokex.Rig.Sim` + `Pokex.Sim.Fence` + a recusa em `start_all` | Testes 1 e 2 passam. **Nada simula ainda** — a cerca sobe antes do que ela cerca. |
| **2** | `Pokex.Sim.World` pura: rota real, passo, mobs, leash, skills, escada | Teste 4 passa; nenhum processo envolvido |
| **3** | `Pokex.Sim.Runner` publicando os fatos nas cadências reais | Teste 3 passa; a frota real anda no mundo falso (teste 5) |
| **4** | A aba `/sim`: mapa, as duas listas, o card da engine, a linha do tempo, os sliders | Uma volta completa na `Meganium and Venoss`, assistida |

A PR 1 vir primeiro não é ordem alfabética: **a cerca sobe antes de existir qualquer coisa que precise ser cercada.** É a mesma disciplina que fez o latch de pânico ser erguido antes de qualquer halt.

`mix precommit` no worktree é o portão, como sempre.
