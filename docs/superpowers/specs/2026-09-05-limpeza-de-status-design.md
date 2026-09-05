# Limpeza de status: a Status Potion antes da corrente

**Data:** 2026-09-05 · **Branch:** `combate/limpeza-de-status`

## O problema

O pokémon pode entrar na corrente já sob status negativo — dormindo, silenciado,
congelado. Nesse estado a tecla do Auto Combo não faz nada no jogo: as skills não
saem, a barra não gasta, e o bot fica apertando `r` de quatro em quatro segundos
contra uma mobada que continua batendo. É uma das formas de morrer que o sistema
hoje não tem como enxergar (nenhum leitor de tela reconhece status) nem como
evitar.

Pedido dele (05/09):

> "Temos que garantir que sempre que ele vai apertar o auto combo ('r'), ele
> aperte a tecla 'e' antes, essa tecla usa o Status potion que cura qualquer
> status negativo se meu pokémon estiver sob algum, e depois de uns 100 ms, daí
> sim aperta o auto-combo."

A Status Potion **não é consumida quando não há status** (confirmado por ele): o
uso vira no-op e o item continua na bag. Isso muda o desenho inteiro — o custo do
prefixo é só TEMPO, nunca dinheiro, e não precisa de piso entre usos nem de
detecção prévia. A cura é profilática por construção: aperta sempre, cura quando
tem o que curar.

## O que já existia, e o que estava errado

O slot `E` já é conhecido do sistema em dois lugares:

* `Settings.potion_key: "e"` — modelado como **poção de VIDA** do pokémon: um
  gole fora de combate abaixo de `pokemon_hp_potion_pct`, degrau do meio da
  escada `cura → poção → revive`. Nunca foi ligado (`potion_enabled: false`).
* `StockAlerts` vigia quatro slots e chama o `E` de `"potion"`, com alarme de
  estoque baixo (`stock_alert_e: 5`).

Confirmado com ele: **o `e` do cliente dele é só Status Potion**. A poção de vida
é ficção — e ficção perigosa, porque as duas apontam para a mesma tecla: ligar
`potion_enabled` por engano faria o bot beber Status Potion por limiar de vida.
Este trabalho aposenta o conceito de HP-potion e põe o de status no lugar.

## As decisões (todas fechadas com ele)

| Pergunta | Resposta |
|---|---|
| O que há no slot `E` | Só Status Potion; a poção de vida não existe |
| Custo sem status | Nenhum — o uso é no-op, o item fica |
| Antes de quais teclas | Toda abertura ofensiva, em qualquer modo |
| Cadência | Auto Combo: toda corrente. Econômico/Padrão: só a abertura da luta |
| Poção de vida | Aposentada de vez, com o código junto |
| UI | Contador + linha no feed só na abertura; o resto é knob e estoque |

A cadência merece a justificativa: no Auto Combo uma luta tem VÁRIAS correntes
(corrente → 4s → revive → corrente, "quantas vezes precisarmos até matar o
shiny"), e o status que mata é o que chega no meio da mobada. Limpar só na
abertura deixaria a 2ª e a 3ª corrente descobertas. A janela de 4s já limita o
prefixo a ~15 apertos por minuto, então "toda corrente" é barato. Nos outros
modos as rajadas saem muito mais rápido e o mesmo "toda vez" viraria um `e` por
segundo — lá a abertura basta.

## Arquitetura

### O conceito: `Pokex.Bots.StatusCure`

Módulo novo, dono de tudo que a Status Potion é para o sistema: a tecla, o
liga/desliga, o respiro, e a regra pura *"esta rajada merece limpeza?"*. É o que
tira o `e` de "tecla solta no fluxo do revive" e o torna um item nomeado, com
estoque vigiado, botão manual, knobs e contador.

Superfície:

```elixir
@spec key() :: String.t()            # "" quando não configurada
@spec enabled?() :: boolean
@spec settle_ms() :: non_neg_integer
@spec due?(policy :: :always | :opening, keys :: [String.t()], cured? :: boolean) :: boolean
@spec press() :: :ok | {:error, term}  # o aperto avulso (botão manual)
```

`due?/3` é total e pura: `false` com a cura desligada ou sem tecla; `true` quando
a política é `:always`; `true` quando a política é `:opening` e `cured?` é falso e
a rajada tem alguma tecla que não seja o Tab (mirar não é atacar); `false` no
resto.

### A política é do modo, não um `if` solto

Callback novo no behaviour `Pokex.Bots.Combat.Plan`:

```elixir
@callback cure_policy(ctx) :: :always | :opening
```

| plano | resposta |
|---|---|
| `Plan.AutoCombo` | `:always` |
| `Plan.Economy` | `:opening` |
| `Plan.Standard` | `:opening` |

Segue a regra que os dois modos de caça já estabeleceram: quem responde "qual é a
mão deste modo" é o plano, e o worker nunca pergunta pelo modo.

### Onde o aperto acontece

`Combat.Worker.try_dispatch/2` é o funil único de toda tecla do combate — é lá
que já se calculam `chain` (as skills que a corrente vai disparar) e `special?`
(soltar as setas antes do `r`). O `cure?` entra pelo mesmo caminho, e o aperto
acontece dentro do `tap_keys/6`, nesta ordem:

```
mini_game_gate  →  let_go(setas)  →  press(e)  →  sleep(settle_ms)  →  stamp_clock  →  rajada
```

Três detalhes que essa ordem resolve:

1. **Depois do `let_go`.** As setas são estado do `Body` e a rajada não passa por
   ele; um `e` disparado com as setas apertadas repete o defeito do #495 (a tecla
   que sai andando).
2. **Antes do `stamp_clock`.** O carimbo do relógio das teclas tem que continuar
   marcando o instante em que a rajada VAI sair; o respiro entra antes dele, e
   não entre o carimbo e a prensa.
3. **Dentro do `tap_keys`**, e não num processo próprio: o `burst_pid` já garante
   uma rajada em voo por vez. Um worker paralelo apertando `e` recriaria a
   corrida mão-vs-cérebro que custou a noite do #480.

O `e` **não** é carimbado no `SkillClock` (não é skill e não tem cooldown na
barra), **não** entra em `sent`, nem nos recibos, nem em `damage_keys` — `spent?`
continua falando só da área do pokémon. O `HandWatch` vigia a fileira 1-0 e a
tecla do resgate, então o `e` não corre risco de virar "mão do Lucas" e carimbar
cooldown falso.

### Uma luta, uma limpeza (nos modos `:opening`)

O worker guarda `cured?` no estado, nascendo `false` a cada `handle_call({:run,
mode})` — que é chamado uma vez por engajamento. A primeira rajada ofensiva da
luta o vira `true`.

### Falha é sempre suave

Sem tecla configurada, com a cura desligada, ou com o aperto recusado pelo rig
(jogo fora de foco, InputGate travado), a rajada sai igual. Uma comodidade nunca
segura um ataque, e nada aqui entra no caminho de pânico.

## Settings

**Entram:**

```elixir
status_cure_enabled: true,
status_cure_key: "e",
status_cure_settle_ms: 100,
```

O padrão ligado é deliberado e ele aprovou: ao dar pull, a caçada dele já passa a
apertar `e`. Sem status a Status Potion é no-op, então o pior caso do padrão é
100ms por corrente.

**Saem, com o código junto** (a aposentadoria da poção de vida):

* `potion_enabled`, `potion_key`, `pokemon_hp_potion_pct`, `potion_cooldown_ms`,
  `potion_battle_clear_ms`
* `PlayerSupport.Logic.potion_wanted?/1` e seus testes
* o degrau da poção em `PlayerSupport.Worker.maybe_potion/2`, o
  `potion_after_clear_window/1` e o `potion_input/1`
* o campo `battle_clear_since` do estado — só o caminho da poção o escreve; o
  `waiting?` da linha de status passa a ser só o `reposition_pending?`
* `PlayerSupport.Worker.use_potion/1`, o contador `counters.potions` e o
  `potion_count/1` do painel, junto com o botão
* as menções à escada `cura → poção → revive` nos moduledocs, que passam a
  descrever `cura → revive`

Chaves aposentadas precisam sair também do crachá `__keys__` (#449) e da lista
`@setting_keys`, senão a guarda recusa gravar o `settings.json` — o defeito que
deixou o config dele sem gravar de 02/09 a 03/09.

## UI

Quatro pontos, todos de texto, na medida que ele pediu ("não precisa ter muita
coisa"):

1. **`/config`** — seção "Limpeza de status" com os três knobs, rótulos pt-BR, e
   o chip explicando que no Auto Combo ela sai a cada corrente e nos outros modos
   só na abertura.
2. **`StockAlerts`** — o slot `E` deixa de se chamar `"potion"` e passa a
   `"Status Potion"`. O alarme de estoque baixo que já existe passa a dizer a
   verdade sobre o que acabou.
3. **Painel** — o botão "🧪 poção (manual)" vira "🧴 limpar status (manual)" e
   aperta o `e` na hora, via `StatusCure.press/0`.
4. **Feed** — uma linha `🧴 limpando status` **só na abertura** da luta. TODA
   limpeza, de abertura ou de corrente, entra no rastro como evento `:cure`, e é
   de lá que sai o contador — o `Engine.Tally` o deriva contando eventos, do
   mesmo jeito que já conta os revives por decisão, sem estado novo. O contador
   do painel que hoje mostra poções bebidas (`counters.potions`) morre com o
   resto; o número que passa a aparecer é o do tally.

## Testes

* `StatusCure.due?/3`: tabela das três políticas × cura ligada/desligada × tecla
  vazia × rajada só de Tab.
* `Plan.cure_policy/1` para os três planos.
* `Combat.Worker`: com `Rig.Fake`, a rajada do Auto Combo registra `press("e")`
  antes das teclas; a segunda corrente da mesma luta também; no Econômico só a
  primeira rajada registra; com a cura desligada nenhuma registra.
* Ordem: o `e` sai depois do `Body.release` (a invariante do #495) e o
  `SkillClock` não tem carimbo para `"e"` depois da rajada.
* Aposentadoria: nenhum `potion_` sobra em `lib/`, e o `__keys__` gravado não tem
  as chaves mortas.

## Bancada: a assimetria, escrita

O simulador não modela status negativo, então ele **nunca vai medir o benefício
desta feature**. Vou espelhar apenas o **custo** — o respiro de
`status_cure_settle_ms` — no `Sim.Hands`, porque a regra do #486 é que toda cerca
do `Combat.Worker` precisa de espelho lá, senão a bancada mede uma mão que não é
a do bot.

Consequência a registrar em voz alta: nos números do sim esta feature aparece
como **perda pura** (uns 100ms por corrente, ~2,5% da janela de 4s). Nenhuma
promessa do `Verdict` deve julgá-la, e nenhuma comparação A/B de mortos deve ser
usada para decidir se ela fica. Quem decide isso é o olho dele na caçada real —
o mesmo caso do #490.

## Fora de escopo

* **Detectar status na tela.** Não existe leitor de status hoje, e a cura
  profilática torna a detecção desnecessária para este fim. Se um dia aparecer,
  ela vira o gatilho e o prefixo vira o fallback — nada deste desenho muda de
  forma.
* **Limpar status antes do revive.** O revive recolhe e devolve o pokémon; se
  algum dia se confirmar que o status sobrevive a isso, entra depois.
* **Reagir ao sinal indireto do sono** (corrente sai, barra não gasta — o
  `SkillTruth` já vê isso). É uma inferência interessante e uma feature separada.
