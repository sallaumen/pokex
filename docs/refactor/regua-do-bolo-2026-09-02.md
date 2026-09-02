# A régua do bolo: as configs que ele não acha

> Data: 2 de setembro de 2026
> Lido em `origin/main` `4087a318` (#486). Linhas citadas são desse commit.
> Natureza: diagnóstico e plano curto. **Nada implementado.**
> Para: revisão por outra IA com mais contexto do cavebot, antes de qualquer código.
> Depois da revisão, cada fatia vira um plano de execução próprio (superpowers:writing-plans).

## O sintoma

Feed da Central, 02/09 10:08:37:

```
🧠 10 passos e não veio mais ninguém: matando 2 inimigos
```

Ele quis subir esses 10 passos e não achou onde. Não está no /config, não está no
`settings.json` dele, e o feed não diz o nome do ajuste. É o `engine_patience_tiles`,
default 10, e ele está no default.

## O que a régua é hoje

`sizing/1` em [engine/logic.ex:1343](../../lib/pokex/bots/engine/logic.ex#L1343) decide,
nesta ordem, a cada tique (a config é relida a cada tique, `Config.in_force/1`):

| # | regra | condição | knob(s) | linha |
|---|-------|----------|---------|-------|
| 1 | nada aqui | `enemies == 0` | — | 1348 |
| 2 | cai em cima | vale a pena e `gather_piles` desligado | `engine_gather_piles` | 1351 |
| 3 | bolo cheio E andou | `enemies >= gather_target` e `walked >= gather_tiles` | `engine_gather_target` 6, `engine_gather_tiles` 6 | 1357 |
| 4 | pararam de chegar | bolo cheio e contagem parada `pile_settle_ms` | `engine_pile_settle_ms` 1500 | 1360 |
| 5 | **paciência** | alguém na tela e `walked >= patience_tiles` | `engine_patience_tiles` **10** | 1365 |
| 6 | teto de tempo | relógio `:sizing` passou de `size_ceiling_ms` → **pula a pilha** (`:skipping`) | `engine_size_ceiling_ms` 8000 | 1376 |
| 7 | senão | continua juntando (andando) | — | 1385 |

`walked` = tiles andados desde que a pilha foi vista
([situation.ex:178](../../lib/pokex/bots/engine/situation.ex#L178)). O relógio `:sizing`
atravessa `sizing ↔ gathering` sem zerar ([logic.ex:800](../../lib/pokex/bots/engine/logic.ex#L800)).

Onde cada knob aparece:

| knob | default | faixa | /config? | outro lugar |
|------|---------|-------|----------|-------------|
| `engine_gather_piles` | true | bool | não | modo Econômico força `false` em memória ([hunt_mode.ex:117](../../lib/pokex/bots/hunt_mode.ex#L117)) |
| `engine_gather_target` | 6 | 1..20 | **sim** ("Juntar até (bichos)") | |
| `engine_gather_tiles` | 6 | 0..60 | não | |
| `engine_patience_tiles` | 10 | 1..200 | não | |
| `engine_pile_settle_ms` | 1500 | 0..60000 | não | |
| `engine_size_ceiling_ms` | 8000 | 100..600000 | não | |
| `engine_skip_fire` | false | bool | não | |
| `cavebot_gather_wait_ms` | 4000 | 0..60000 | não | por rota e por waypoint na página do Cavebot ("respiro") |

## A confusão, em cinco pontos

1. **Uma régua, uma chave na página e seis fora.** O grupo "Cérebro da caçada" do
   /config ([config_live.ex:278](../../lib/pokex_web/live/config_live.ex#L278)) mostra
   `engine_gather_target` e esconde as outras dimensões da mesma decisão. Quem lê
   "Juntar até 6 bichos" não tem como saber que existe um teto de 10 passos e outro de 8s
   que fecham a janela antes.

2. **Paciência em passos, teto em segundos, e o teto passa na frente sem avisar.**
   Subir `patience_tiles` sozinho de 10 pra 25 pode deixar o bot pior: se os 25 passos
   levarem mais de 8s, a regra 6 vence e ele **deixa a pilha pra trás sem matar**
   ("só 2: não vale a área — seguindo a rota"). O comentário do teto em `settings.ex`
   diz "decide com o que apareceu"; o código faz `:skipping`. O único teste do teto
   ([logic_test.exs:206](../../test/pokex/bots/engine/logic_test.exs#L206)) cobre pilha
   que NÃO vale a pena. Pilha que vale, abaixo da paciência, passada do teto: sem teste,
   comportamento é pular.

3. **Dois "esperar o bolo" de duas eras.** O respiro antigo (`cavebot_gather_wait_ms`,
   4s ao chegar no "até aqui", editável por rota/waypoint) ainda vive em
   [cavebot/logic.ex:327](../../lib/pokex/bots/cavebot/logic.ex#L327) e segura o fogo via
   postura `:hold_fire`. O cérebro passa na frente da postura enquanto fala
   ([combat/worker.ex:484](../../lib/pokex/bots/combat/worker.ex#L484)); o respiro virou
   fallback de quando o fato do cérebro envelhece. Ninguém contou isso pra página do
   Cavebot: ela ainda oferece o campo como se mandasse, e a nota de "limpar" diz
   *"voltou a usar o respiro do /config"*
   ([cavebot_live.ex:1587](../../lib/pokex_web/live/cavebot_live.ex#L1587)) — e a chave
   **não está** no /config.

4. **O modo sobrepõe em memória, a página mostra o global.** No Econômico
   `gather_piles` é `false` e a régua inteira some (regra 2, "caindo em cima"). O /config
   não sinaliza que o número mostrado pode não ser o que está valendo.

5. **O feed dá o número e esconde o nome.** "10 passos e não veio mais ninguém" foi a
   pergunta desta sessão. Se a frase dissesse *paciência*, ele teria a palavra pra buscar.

Já resolvido, não refazer: o #485 tirou as chaves mortas `cavebot_group_min_enemies` /
`cavebot_group_max_wait_ms` e a citação ao `leash_tiles` (knob que não existe mais).

## Plano, em fatias (cada uma um PR pequeno)

**P1 — o feed nomeia a régua.** Só texto, em `engine/logic.ex`:
`"#{walked} passos (paciência) e não veio mais ninguém: matando N"`,
`"N depois de M passos juntando (bolo cheio): estourando a área"`,
`"só N em 8s (teto): não vale a área — seguindo a rota"`. Um teste por frase já
existe (`assert orders.why =~ ...`); ajustar os `=~`. Risco zero no jogo.

**P2 — /config expõe a régua inteira, na ordem em que o código decide.** No grupo
"Cérebro da caçada", logo abaixo de "Juntar até (bichos)":

| key | kind | label | hint (resumo) |
|-----|------|-------|---------------|
| `engine_gather_piles` | bool | Juntar bolo andando | Desligado: bateu, luta. O modo Econômico desliga isto sozinho. |
| `engine_gather_tiles` | int | Passos mínimos com o bolo cheio | Com "juntar até" batido, ainda anda isto antes de abrir. |
| `engine_patience_tiles` | int | Paciência (passos) | Andou isto com bicho na tela e o bolo não encheu: mata o que tem. **Era o "10 passos".** |
| `engine_size_ceiling_ms` | ms | Teto da juntada | Passou disto desde que viu a pilha: deixa a pilha e segue. Tem que caber a paciência. |
| `engine_pile_settle_ms` | ms | Pararam de chegar | Bolo cheio e contagem parada por isto: abre. |
| `engine_skip_fire` | bool | Bater ao deixar a pilha | Só teclas de alvo único. |

Keywords: `passos juntar mobar paciência teto pilha bolo`. Nenhuma lógica muda; é a
mesma `Settings.put/2` que a página já usa.

**P3 — paciência e teto param de brigar.** Duas opções pro revisor:

- **(A, recomendada)** O teto só derruba pilha que **não** vale a pena. Pilha que vale,
  passada do teto, **abre** com o que tem — é o que o comentário do teto já promete.
  Na prática: em `still_sizing/1`, a regra 6 ganha `and not t.s.worth_fighting?`, e
  `sizing/1` ganha uma cláusula "vale e passou do teto → open". Teste novo:
  *"pilha que vale, abaixo da paciência, passada do teto: abre, não passa reto"*.
- **(B)** Manter, e o hint do teto avisa que ele pula a pilha.

Risco de (A): o teto tem história no bench (era 4s, virou 8s em #376; `fleet_test.exs:227`).
Antes de mergear, A/B costas-com-costas no bench com a config dele: mortos/min, quedas,
tempo no chão.

**P4 — o respiro antigo diz o que é.** Menor mudança honesta: a nota da página do
Cavebot passa a dizer *"voltou ao respiro global (4s), que só vale quando o cérebro não
está falando"*, e `cavebot_gather_wait_ms` ganha linha no /config com esse mesmo hint.
Alternativa maior, pra decidir com quem conhece o cavebot: aposentar o respiro por
rota/waypoint quando a engine está ligada.

**P5 — o número dele, hoje, sem código.** Par de partida `engine_patience_tiles: 20` +
`engine_size_ceiling_ms: 16000` (os 10 passos do log couberam em 8s, então o passo é
≤ 0,8s; 20 passos precisam de até 16s). Sempre os dois juntos até o P3 entrar.

- Ao vivo, no iex do nó: `Pokex.Settings.put(:engine_patience_tiles, 20)` e
  `Pokex.Settings.put(:engine_size_ceiling_ms, 16_000)`. Valida faixa, grava, vale no
  próximo tique.
- No arquivo: as duas chaves em `~/.pokex/settings.json` e reiniciar (não há watcher).

Defaults no código **não mudam** sem A/B no bench.

## Perguntas pro revisor

1. P3(A): pilha que vale e passou do teto deve abrir, ou o pulo é intenção (R2, "arrastar
   longe demais faz a pilha sumir")? Se intenção, por que o teto e a paciência não são a
   mesma unidade?
2. O respiro por rota/waypoint ainda tem uso com a engine ligada, ou só confunde?
   Se tem, qual: chegada no "até aqui" antes do cérebro ter um fato fresco?
3. A página deve marcar quando o modo (Econômico) sobrepõe um knob mostrado?
4. Ordem: P1 e P2 primeiro (só texto e página)? P3 depois do A/B?

## Fora de escopo

Mudar a física da régua (R2/R6), a janela de bunching (`engine_bunch_ms`), o alvo do
bolo, ou qualquer default. O objetivo aqui é ele ENCONTRAR e entender o que já existe.
