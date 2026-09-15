# A prova de que a bola saiu — plano de implementação

> Escrito em 15/09/2026 para outra pessoa implementar. Contém o PORQUÊ, porque
> sem ele a primeira decisão difícil vira chute.

## O problema, em uma frase

**O bot não sabe se a pokébola saiu da mão**, e por isso não pode alarmar, não
pode aprender e não pode ser deixado sozinho a noite inteira.

## Por que o que existe hoje não responde

### `🌟 capturado` não mede captura

Numa bola de âncora (a do shiny), `Catcher.Logic.confirm/3` pergunta se o corpo
ainda está no ponto — e a leitura que ele recebe é
`Catcher.Observation.anchors/3`, cujo campo `corpses` é **a lista de âncoras do
próprio rastro**:

```elixir
corpses: Enum.map(candidates, & &1.point)   # observation.ex
present?(obs.corpses, throw.point, tol)     # logic.ex
```

A âncora some quando o próprio arremesso a gasta (`Hunt.spend/2`) ou quando o
TTL de 120 s vence. Ou seja: `capturado` mede a contabilidade do bot.

E não poderia ser o sinal de qualquer jeito: **captura de verdade é ~1 a cada
12 h de caçada** (Lucas, 15/09). Medir arremesso por captura é medir a mecânica
do jogo, não o defeito.

### O `:hud` está morto desde 24/08

O feed `:hud` tira a região de `Pokex.Layout.region(:hud_bottom, calib.layout)`,
e `calib.layout` vem de `Layout.current/0`, que lê `~/.pokex/layout_fix.json`.
Esse arquivo virou **`layout_fix.json.bak-pxg-20260824`** na migração do PXG
pro Poké Alliance e nunca foi refeito.

Consequências medidas:

  * `calibration.json` tem `"layout": null`;
  * o fato `:hud` nunca é publicado, então `slots: %{f1:, f2:, e:, s_q:}` não
    existe;
  * **`Pokex.Bots.StockAlerts` nunca disparou em setembro inteiro** (conferido
    no diário) — uma via de segurança (bola/poção/revive acabando) silenciosamente
    morta há três semanas.

## A prova que o jogo já escreve

O número embaixo do atalho da bola. Cai = a bola saiu. Igual = a tecla não virou
bola — que é exatamente o "tentando jogar e não conseguindo" que ele vê, e o
**"You cannot use this object"** que o cliente escreveu no vídeo de 22:40:23.

**Fixture já cortada do vídeo dele:** `test/fixtures/hud/hotbar_f1_827.png`
(340×56, recorte nativo em `(1400, 1396)` da tela 3440×1440; o F1 marca `827`).

## O que JÁ ESTÁ PRONTO (não refazer)

Em `Pokex.Bots.Catcher.Worker`:

  * `watch_stock/2` — no arremesso, guarda `%{slot, antes, at}` em `state.proof`,
    escolhendo o slot pela tecla que `Balls.key_for/2` devolveu;
  * `check_proof/1` no `:pulse`, com `@proof_after_ms 2_000`;
  * `stuck?/2` — **a regra, pública e testável**: caiu = `false`, igual ou maior
    (ele repôs a bag) = `true`, não lido = `:unread`;
  * `ball_did_not_leave/1` — linha no diário e alarme em `stuck_balls_alarm` (4);
  * `stock_blind/2` — diz UMA vez por corrida que não consegue medir;
  * `stuck_balls` no `snapshot/1`.

`stock/1` lê `WorldState.get(:hud, …)` → `slots[slot]`. **É o único ponto que
precisa mudar de fonte.**

## O plano — três peças, nesta ordem

### 1. `ball_stock_region` na calibração (marcação à mão)

Ele escolheu a marcação à mão em vez de refazer o layout automático, e a razão
é boa: o layout automático precisa de templates recortados da tela dele e de
validação por perfil de monitor; a marcação à mão é o caminho que ele já
conhece.

Siga o padrão de `skill_bar_region`, que é o mais parecido (região de HUD, com
dígitos dentro):

  * `lib/pokex/calibration.ex`: campo no `defstruct`, `to_list/1` no `save/2`,
    `to_tuple/1` no load (linhas ~40, ~181, ~223) e a lista de chaves de ~572;
  * `lib/pokex_web/live/calibration_live.ex`: entrada em `@adjustables`
    (`"ball_stock_region" => {:ball_stock_region, :region}`), o passo de
    marcação e o `draft`/`keepable` correspondentes (veja `skill_bar_region` em
    ~587, ~1152, ~1214).

**Aponte para o número, não para o ícone**: o retângulo é o rodapé do slot, onde
o `827` está desenhado.

### 2. O leitor do número

Um módulo novo, `Pokex.Vision.StockDigits` (ou uma função em `SkillDigits`, que
já lê número branco com contorno preto em cima de slot — é o vizinho mais
próximo do problema).

  * entrada: `Frame.t()` da região;
  * saída: `{:ok, inteiro}` ou `:unread`;
  * **`:unread` é resposta legítima e é o caminho seguro** (veja "as armadilhas").

Valide contra `test/fixtures/hud/hotbar_f1_827.png` — o recorte tem os slots F1
a S+F3, então dá pra fixar mais de um número da MESMA foto.

### 3. Ligar no lugar do `:hud` morto

Em `Catcher.Worker.stock/1`: se `ball_stock_region` estiver marcada, fotografe e
leia; senão, tente o `:hud` (que volta a funcionar se o layout for refeito um
dia); senão `nil` — e `stock_blind/2` já diz isso em voz alta.

Cadência: uma foto por arremesso e outra 2 s depois. Não precisa de feed.

## As armadilhas (todas pagas em campo, nesta ordem)

1. **Leitura ruim NUNCA acusa.** `stuck?/2` devolve `:unread` e ninguém grita. É
   a lição literal do `StockAlerts`: "um alarme que repete a cada 500 ms é um
   alarme que ele aprende a ignorar". Um falso "a bola não saiu" durante a noite
   vale menos que silêncio.

2. **O jogo ABREVIA contagem grande.** No mesmo recorte, o slot `E` aparece como
   **`12k`**. Um número abreviado é estável entre dois arremessos e por isso
   **mente como prova** — trate qualquer leitura não-numérica (com `k`, `m`, ou
   com ponto) como `:unread`, nunca como número.

3. **Cada arremesso tem a SUA prova.** `corpse_max_balls` permite mais de uma
   bola no mesmo corpo, e a segunda precisa do seu próprio "antes". Um teste que
   ignora isso acusa com razão e parece defeito (aconteceu duas vezes ao montar
   a cerca).

4. **A calibração é UM arquivo só para a suíte inteira.** Um teste que salva uma
   `%Calibration{}` e vai embora acorda comportamento em quem conta com tela não
   medida (o `ball_test` afirma o ponto SEM o desvio do `Screen.BarOffset`).
   Se salvar, devolva a anterior no `on_exit` — veja
   `test/pokex/bots/catcher/hunt_test.exs`.

5. **O `press` só é gravado como evento pelo `Combat.Worker`.** Não use a
   ausência de `press` nos eventos como prova de nada (já custou meio dia).

## Como saber que funcionou

Não é teste verde — é campo:

  * a linha `🥎 não sei dizer se a bola sai da mão` **para de aparecer**;
  * numa noite, `stuck_balls` fica em 0 na maior parte do tempo;
  * quando o corpo não está no chão, a linha `🥎 a bola não saiu da mão: o
    estoque de f1 continua em N` aparece — e aí, pela primeira vez, dá pra
    medir se **esperar** antes de arremessar resolve (a hipótese dele de 15/09,
    que hoje é indecidível porque o medidor é cego).

## O que NÃO fazer

  * Não meça sucesso por `capturado` nem por `capturado (tardio)` — os dois
    saem do medidor cego descrito acima.
  * Não refaça o layout automático "de passagem". Ele revive o `StockAlerts`
    inteiro e vale a pena, mas é outro trabalho, com outras provas (templates
    da tela dele, um perfil por monitor).
