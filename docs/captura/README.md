# A captura, do brilho à bola

Este é o mapa da captura como ela funciona hoje. Se você nunca abriu esta parte
do código, comece por aqui: cada seção responde uma pergunta que a gente já
precisou responder às pressas com o bot rodando.

O desenho que originou tudo é o
[shiny na caçada](../superpowers/specs/2026-09-09-shiny-na-cacada-design.md); o
plano que arrumou a casa é a
[captura limpa e escalável](../superpowers/plans/2026-09-11-captura-limpa-e-escalavel.md).

---

## 1. O caminho

Duas lentes alimentam uma lógica só. Elas não se misturam: cada bola sabe de
qual veio (`source`), e é isso que impede a ausência numa lente de dar por
capturada a bola da outra.

```
                        ┌─ a lente do SHINY ────────────────────────────────┐
ShinyGuard (0,7s) ──────┤ Sparkle.find: a estrela amarela ao lado do nome    │
                        │  └─► {:shiny_on_screen, vistos} ─► Hunt.hunt/3     │
CrowdWatch (4/s) ───────┤ as barras de vida, em pontos de TELA               │
                        │  └─► Hunt.follow/4 ─► CrowdScan.mark_special       │
                        │       └─► Trail.observe: rastros em tiles do MUNDO │
                        │            └─► a barra caçada sumiu = ÂNCORA       │
                        └───────────────────────────────────────────────────┘

                        ┌─ a lente do CORPO COMUM ─────────────────────────┐
Engine (200ms) ─────────┤ {:capture_now}: a rodada fechou, a lista zerou     │
                        │  └─► SpotScan: varre o chão em volta do personagem │
                        │       └─► CorpseLibrary: casa com os corpos        │
                        │            ensinados na Calibração                 │
                        └───────────────────────────────────────────────────┘

          ambas ─► Catcher.Logic.step (fila, UMA bola no ar, conferência)
                    └─► {:capture_sequence, ponto, nome}
                         └─► Balls.key_for(nome, :corpse | :anchor)
                              └─► Ball.sequence ─► Body.perform(:high)

Catcher.Fact ─► fato :capture no quadro-negro ─► Engine.hold_for_capture
             └─► transmissão {:catcher, snapshot} ─► Cavebot, Suporte, Central
```

Fora desse caminho existe a **varredura cega** (`Sweep`, "varrer"): sem visão,
sem acervo, sem nota — uma bola em cada tile ao alcance, numa cadência lenta.
É a rede de segurança embaixo da mira, pra nunca perder um corpo que ESTAVA
ali. Ela é do modo Parado e tem interruptor próprio (`sweep_enabled`).

---

## 2. Quem decide o quê

**`ShinyGuard` + `Vision.Sparkle`** — o brilho. O cliente desenha uma estrela
amarela ao lado do nome de todo shiny: um glifo de interface, os mesmos pixels
pra toda espécie, sem luz do lugar. É uma regra global, não uma cor por
espécie. E o brilho DIZ VIVO: enquanto ele está lá, o bicho está de pé — barra
sumida na pilha não é morte enquanto o brilho aparece.

**`CrowdWatch` / `CrowdScan`** — as barras. O olho lê a barra de vida de cada
criatura algumas vezes por segundo, como pontos de TELA.
`CrowdScan.mark_special/3` é quem diz em cima de qual barra o brilho está.

**`Catcher.Trail`** — a identidade que viaja com a barra. Guarda as leituras
como RASTROS em tiles do MUNDO (a posição do minimapa mais o deslocamento na
tela sobre o tile), então um rastro sobrevive ao personagem andando e segue
cada criatura de olhada em olhada por vizinho mais próximo com um palpite de
velocidade. Quando a barra caçada some por algumas olhadas, o último lugar dela
é a **âncora**: o tile em que o corpo está deitado, com cor ou sem cor.

Por que não pela cor: *"cor nenhuma resolve isso"* (11/09). O corpo é arte
diferente do vivo — a casca viva do Shiny Golem é um escuro arroxeado, o morto
é cinza neutro — e medido nos quadros dele de 09:13, o corpo estava na tela com
**zero pixels** do tom ensinado.

**`Catcher.Hunt`** — os alvos, do lado de fora do GenServer. Devolve fatos: o
rastro novo, as barras que caíram nesta olhada, e as âncoras em que a bola cabe
agora. Não joga e não fala.

**`Catcher.Logic`** — o núcleo puro. Uma fila, **exatamente UMA bola no ar**,
conferência de cada arremesso contra observações tiradas DEPOIS da janela de
voo (um acerto consome o corpo na hora — é regra do jogo), uma segunda tentativa,
e ignorados por TTL (um pet parado não é corpo). Sem relógio e sem I/O.

**`Catcher.Observation`** — o que o Catcher entrega à `Logic` quando a evidência
não é uma foto. A bola comum é julgada num quadro fresco; a do shiny não tem
quadro a oferecer — tem uma AFIRMAÇÃO sobre o chão. `anchors/3` veste essa
afirmação no contrato da `Logic`, e o portão que as duas lentes dividem:
**ninguém vivo na tela** (`screen_clear/2`, pela conta do cérebro). *"Quando tá
vivo temos que matar e quando tá morto temos que capturar"* (09/09).

**`Catcher.SpotScan` + `CorpseLibrary`** — a lente do corpo comum. Ancorada na
MORTE (não num detector de chão com aquecimento, que nunca teve janela quieta
pra aquecer) e densa, não em grade de tiles.

**`Catcher.Balls` / `Ball`** — qual bola, e como se joga. A escolha do corpo
comum mora na foto que o acervo ensinou (Calibração → corpos ensinados); a do
shiny é uma chave só, `shiny_ball_key`, porque a âncora não tem foto onde
pendurar um seletor. `Ball.sequence/2` é o dono do arremesso: posicionar,
esperar o assentamento, apertar a tecla, e — se `ball_needs_click` — clicar.

**`Catcher.Fact`** — o relato, num mapa só. A mesma verdade sai por dois fios
(o fato `:capture` do quadro-negro e a transmissão `{:catcher, snapshot}`), e
são três coisas: `pending` (corpos na fila ou bola no ar, das duas lentes),
`anchors` (corpos que o rastro sabe onde estão) e `hunted?` (a barra de um shiny
ainda DE PÉ). As duas primeiras seguram os pés; a terceira não — é hora de
matar, não de jogar bola —, mas licencia a bola com a captura desligada. O
prazo do fato é do Catcher: três pulsos de 1s.

**`Engine.Logic.hold_for_capture/2`** — segurar os pés. Com corpo no chão a rota
para (só os pés: skills e revive seguem) por até `engine_capture_hold_ms`, e
nunca na banda vermelha.

**`Catcher.Narration`** — as frases, puras. O worker é o dono das mãos e da voz;
a narração só devolve texto.

---

## 3. As linhas do diário, e o que cada uma prova

| Linha | O que ela prova |
|---|---|
| `✨ shiny na tela — o brilho ao lado do nome (Npx)` | o vigia achou a estrela; o bicho está VIVO |
| `🎯 <nome> caiu em x,y — a barra sumiu` | a barra caçada sumiu por algumas olhadas: nasceu uma âncora |
| `🌟 a âncora caiu com a estrada andando` | o corpo apareceu com os pés em movimento — a bola espera a hora da bola |
| `🌟 bola na âncora do <nome> em x,y — caiu há Ns` | a bola saiu na âncora, e há quanto tempo o corpo está ali |
| `🌟 bola em x,y` | a bola saiu (a linha comum do arremesso, com a estrela por ser do shiny) |
| `🌟 capturado em x,y` | a conferência deu positivo: o corpo sumiu depois da janela de voo |
| `🌟 a bola da âncora NÃO saiu — …` | uma cerca recusou o arremesso, e o motivo vem junto |
| `🎯 hora da bola — N corpo(s) no chão` | a varredura do acervo olhou o chão e achou |
| `🎯 acervo de corpos VAZIO` | não há nada ensinado: a mira não vai mirar em nada |

---

## 4. As configurações vivas

| Chave | O que faz |
|---|---|
| `capture_enabled` | liga a captura de corpo comum |
| `ball_key` | a bola PADRÃO — a que leva um corpo que ninguém reconheceu |
| `ball_types` | as bolas do hotbar (tecla + nome), editadas nos Editores |
| `shiny_ball_key` | a bola do shiny; vazio = a padrão |
| `ball_needs_click` | a hotkey usa a bola direto, ou arma uma mira que espera clique |
| `capture_aim_settle_ms` | espera entre posicionar e apertar |
| `corpse_scan_radius_tiles` | o alcance da varredura do acervo |
| `corpse_match_min_similarity` | a nota mínima pra dizer "é este corpo" |
| `corpse_match_tolerance_px` | quantos px de folga ao casar um ponto com um nome |
| `corpse_max_balls` | teto de bolas por rodada |
| `shiny_always_ball` | um shiny merece bola mesmo com `capture_enabled` desligado |
| `shiny_guard_enabled`, `shiny_sparkle` | o vigia, e o brilho como regra global |
| `engine_capture_hold_ms` | por quanto tempo a rota para pra bola sair |
| `sweep_enabled`, `sweep_interval_ms`, `sweep_radius_tiles`, `sweep_side` | a varredura cega |
| `dry_balls_alarm` | o alarme de bola seca |

**E as aposentadas, que ficam declaradas.** `ball_rules` (a escolha da bola
virou campo do corpo ensinado), `shiny_aim_max_candidates` e
`shiny_needs_creature` (eram a fila da mira por COR do corpo, que não existe —
0 px em toda sessão de 11/09).

Elas continuam no alfabeto de propósito: tirar uma chave sem pôr outra faz este
build se declarar mais velho que o `settings.json` dele, e o `Settings` passa a
LER sem ESCREVER, em silêncio (#506/#507). **Chave aposentada fica declarada.**

---

## 5. Como investigar um shiny que passou

1. **Copie o episódio antes da rotação.** A caixa-preta guarda os últimos 6
   episódios em `~/.pokex/captures/incidents/<carimbo>-shiny/manifest.jsonl`.
   Passou de 6, o mais velho some.
2. **Gere o fixture.** Uma linha por entrada com `crowd.read? == true`:
   `t` (ms desde a primeira), `me`, `pos` (do minimapa), `hostiles`
   (`[[x, y, hp_pct]]`), `pet`, `vistos` (`[[x, y, px]]` de `special.vistos`),
   `listed` (a lista CRUA, com a linha do pokémon dele: 1 = pilha morta),
   `enemies`, `route`. **Nada de nomes** — o repositório é público.
   Guarde em `test/fixtures/captura/`.
3. **Rode a bancada:**

   ```bash
   MIX_ENV=test mix test test/pokex/bots/catcher/trail_replay_test.exs
   ```

   `Pokex.TrailReplay.run/1` devolve `%{anchors:, falls:, hunted:, looks:}` —
   alimentando `Trail.observe/4` e `Trail.hunt_at/6` exatamente como o worker.
4. **Olhe os quadros da queda e da bola.** A pergunta quase sempre é uma de
   três: a barra sumiu onde? a âncora nasceu fresca o bastante? a bola achou
   uma cerca fechada?

---

## 6. O que ainda não resolve

- **O bicho que anda no último segundo.** A âncora é onde a BARRA estava; se o
  bicho deu um passo antes de cair, o corpo fica um tile ao lado. Só olhando o
  CHÃO depois da queda pra fechar isso
  ([o corpo certo](../superpowers/specs/2026-09-11-reconhecimento-de-corpo-design.md)).
- **O nome escondido atrás do pet.** O pokémon dele em cima do bicho tapa o
  nome — o rastro trata como oclusão, não como morte, mas o nome fica ilegível.
- **O minimapa parado com a tela rolando.** Os gêmeos de 19:50: dois rastros
  muito próximos, e o mundo não se moveu no minimapa enquanto a tela rolava.

---

## 7. O que vem depois

- **O modo "captura tudo que mata".** Todo track que cai vira âncora; o acervo
  confirma e escolhe a bola. A seção com esse nome está no
  [plano da captura limpa](../superpowers/plans/2026-09-11-captura-limpa-e-escalavel.md).
- **O corpo achado no chão depois da queda** — o casador por histograma, com
  forma e paleta na máscara
  ([o corpo certo](../superpowers/specs/2026-09-11-reconhecimento-de-corpo-design.md)).
