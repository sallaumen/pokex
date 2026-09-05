# O olho do cerco: ver quem está perto antes de recolher o pokémon

Data: 2026-09-05. Autor: Lucas com a IA. Estado: **desenho aprovado por seções,
aguardando revisão do texto inteiro.** Identificadores em inglês; texto pro
usuário em pt-BR.

## 1. Por que

Três mortes do personagem em 03/09 (12:32, 14:19, 16:20) tiveram a mesma
forma: o revive RECOLHE o pokémon, e durante a janela em que ele está na bola
todo monstro acordado que alcança o personagem bate NELE. A regra dita por
Lucas depois da terceira morte é o contrato:

> "não usar revive se tiver alguém perto, a não ser que tenha saído o stun (…)
> depois do R é o momento seguro pra usar revive, ou se não tiver nenhum
> monstro inimigo mais na tela"

Os PRs #511–#514 cercaram o revive com o que o cérebro enxerga hoje: **tela
limpa ou sono fresco**. Mas o cérebro não sabe onde ninguém está. `enemies` é a
contagem da lista de batalha; "em cima e perto" é um relógio de 6 s
(`engine_bunch_ms`); `@fits_around 8` é um teto de contagem; e `boss_tiles`,
a única distância que existe na `Situation`, só a bancada preenche. Um bicho
que chega DEPOIS da corrente (a morte das 16:20: um inimigo, pokémon a 100%,
"revive agora pra chegar inteiro", 4% de vida um segundo depois) é invisível
por construção.

### O olho que existe mede a cor errada

`Pokex.Bots.CrowdScan` + `Pokex.Vision.NameLabels` (#497) medem posição em
tiles a partir do "nome verde do pokémon" e contam "nome vermelho" como
inimigo. Na foto real de 03/09 18:22 (1812×1440, 5 Feraligatr, o Venusaur e o
personagem), com os olhos e com o leitor:

- **Todo nome estava verde** (Feraligatr, Venusaur, Lotavanon). No cliente do
  Poké Alliance a cor do nome acompanha a vida, como no Tibia. O
  "vermelho = inimigo" de 26/08 foi medido em bicho apanhando.
- **A âncora caiu num Feraligatr** (o primeiro "nome verde" da varredura), e
  nas fotos guardadas caiu até numa palmeira.
- **O "vermelho" contado era a crista do Feraligatr e a camisa do personagem.**
- **O marcador de verdade é a caveira branca** em cima do nome: 5 crânios
  idênticos (16×17 px, 118 pixels brancos cada). Lucas: caveira = monstro de
  nível 150+, "um golpe que te mata"; sem caveira o bicho continua agressivo,
  mas "é brincadeira" pro nível dele.

No campo, 21.436 leituras em 02–03/09: o olho viu menos que a lista em 12.104,
mais que a lista em 8.470, bateu em 862; com lista ≥ 3, disse "ninguém a ≤ 1
tile" em 14.799 de 19.474. Nada decidia em cima disso (o fato `:crowd` não tem
consumidor e as posições por bicho nem são publicadas), então esse olho não
matou ninguém. Mas também não protege ninguém.

### O que funciona na foto real

Protótipo rodado sobre a mesma foto: a **barra de vida** é uma caixa de 27×4 px
com borda preta e 2 linhas de preenchimento colorido (25 px = 100%), igual para
toda criatura. Em volta dela, duas assinaturas: a caveira acima e uma **caixa
preta com um número** embaixo, que só o pokémon dele tinha ("320").

| ser | caveira (px brancos) | caixa preta embaixo | tiles a partir do personagem |
|---|---|---|---|
| Feraligatr longe | 117 | não | (+5, −3) |
| Feraligatr longe | 119 | não | (−5, −2) |
| Feraligatr colado | 118 | não | (−1, +1) |
| Feraligatr colado | 118 | não | (+1, +1) |
| Feraligatr colado | 118 | não | (+1, +2) |
| Venusaur | 13 | **sim** | (0, +2) |

A barra do personagem não apareceu: o balão "Venusaur, Ancient Armor!" estava
em cima dela. Não faz falta — o personagem é sempre o ponto calibrado.

Custo medido no log real do olho de hoje (mesma caixa): ~18 ms de leitura +
~9 ms de captura por olhada. O moduledoc que diz 280 ms está velho.

## 2. Objetivo

Dar ao cérebro uma foto do cerco — quem está colado no pokémon, quem está
dormindo, quem está solto e acordado, quem a lista diz que existe e o olho não
viu — e trocar a cerca do revive de "tela limpa ou sono fresco" por **"ninguém
acordado alcança VOCÊ antes do pokémon voltar"**. Cada revive dado ou segurado
diz por quê, em uma frase, no feed da Central. Tudo validado no simulador
antes de tocar o jogo: "o mundo real não é um ambiente de testes para o bot".

### Não-objetivos (desenhos próprios, depois)

- **A fuga** (recuar um canto; estacionar o pokémon num canto com o botão do
  meio e correr pro outro lado): o simulador hoje anda `route: :back` pra
  FRENTE (`Sim.Hands.tentando_andar?/2`) e não modela o pokémon seguindo o
  personagem com a pilha atrás. Sem isso a bancada não mede nada dela.
- **Rastreio entre fotos** (identidade por bicho, velocidade, "vindo pra
  cima"): fase C, depois que as fotos de campo provarem que as marcas são
  estáveis.

## 3. Arquitetura

```
JOGO                                          SIMULADOR (bancada e /sim)
captura SCK, caixa de 12×9 tiles em volta      verdade do mundo (mobs com pos,
do personagem (1812×1440 hoje, ~9 ms)          asleep_until, hp)
        │                                              │
Vision.CreatureMarks.find/2  ◄──── mesmo contrato ────►  Sim.World.marks/1
        │  marks: [%{point, hp_pct, skull?, pet?}]        (verdade → marcas,
        │                                                  com cegueira por knob)
Bots.CrowdScan.place/3 (puro)  →  leitura: tiles de VOCÊ e do pokémon
        │
Bots.CrowdWatch (cadência)  →  fato :crowd  %{read?, at, me, pet, hostiles, took_ms}
        │
Engine.Worker.inputs/4  →  Engine.Situation.build/3 (carrega `crowd` cru)
        │
Engine.Logic.tick/4  →  t.siege = Engine.Siege.build(crowd, listed, stun_cover, config, now)
        │                (função pura; a bancada chama a MESMA Situation/Logic)
Engine.Logic (recall_safe? v2, motivos)
        │
Orders.why + Events :decision  →  feed da Central
UI: PokexWeb.SiegeComponents.siege_card/1 (SVG em tiles, centrado no personagem)
        ← Central lê o fato :crowd e a foto;  /sim desenha verdade × leitura
```

Quatro decisões:

1. **Marcas são o contrato entre pixel e geometria.** `CreatureMarks` só
   entende de barra, caveira e caixa preta; devolve pontos na tela. Quem
   transforma em tiles é `CrowdScan.place/3`. Quem julga é `Siege`. Três
   funções puras, cada uma com teste de mesa; o simulador entra pelo contrato
   das marcas, nunca por baixo dele.
2. **A âncora é o personagem, sempre.** O ponto calibrado nunca some e nunca é
   confundido com um bicho. O pokémon é uma marca a mais (`pet`), opcional:
   sem ele, `from_pet` vira `nil` e o cérebro sabe que só tem a distância do
   personagem.
3. **O `Siege` nasce dentro do tique do cérebro, não no vigia.** `CrowdWatch`
   só mede e publica. O julgamento precisa do carimbo do stun, que só o
   `Logic` tem, e é exatamente o que a bancada roda também.
4. **Fato velho é fato ausente.** `:crowd` com mais de `crowd_fact_max_age_ms`
   (600 ms) não entra; `Siege` responde `read?: false`, o cérebro cai na cerca
   de hoje (tela limpa ou sono fresco) e o motivo no feed diz "sem olho".

## 4. Marcas e geometria

### 4.1 `Pokex.Vision.CreatureMarks`

A marca de uma criatura:

```elixir
%{point: {x, y},        # centro da barra, em coordenadas do frame
  hp_pct: 0..100,       # comprimento do preenchimento / largura útil
  skull?: boolean,      # caveira acima: peso "golpe que mata na janela"
  pet?: boolean}        # caixa preta do número colada embaixo
```

**O primitivo é o retângulo preto 27×4**, não a cor do preenchimento: um
bicho quase morto tem 1 px de preenchimento, e a barra continua inteira. O
`Pokex.Vision.Ink` (varredura de linhas amostradas com passo 2, 14–31 ms
medidos) procura corridas pretas de 26–28 px com `min_rows: 1`; cada
candidata é confirmada localmente (bordas superior e inferior a 3 linhas de
distância, colunas pretas nas pontas, interior só preto ou tinta saturada).
Dentro, o preenchimento é a corrida de pixels saturados (verde, amarelo ou
vermelho; `max > 120` e `max − min > 60`) a partir da esquerda: `hp_pct =
round(100 × fill / (bar_w − 2))`; zero preenchimento e retângulo certo é vida
~0.

Assinaturas, checadas em algumas centenas de pixels por marca:

- **caveira**: pixels quase brancos (`min > 150`, `max − min < 40`) num
  quadro de 24×26 centrado na barra, de 14 a 40 px acima dela; `skull?` quando
  a contagem ≥ 60% da referência (118).
- **caixa preta**: corrida preta ≥ 2 × `bar_w` na linha logo abaixo da borda
  inferior; `pet?`.

Tudo escala pela régua da tela: os tamanhos ficam como fração do `tile_px`
(barra 27/151 da largura do tile, caveira 118/151² da área, caixa ≥ 54/151)
e o plano de calibração por tela (`docs/refactor/calibracao-por-tela-2026-09-03.md`)
cobre o notebook. As faixas do HUD saem por máscara das regiões calibradas
(barra de skills, painel, minimapa) mais a barra de ferramentas do topo.

### 4.2 `Pokex.Bots.CrowdScan` v2

`look/1` captura a caixa em volta do personagem (raio
`crowd_scan_radius_tiles`), chama `CreatureMarks.find/2` e entrega a
`place/3`, pura, que a bancada também chama:

```elixir
%{read?: true, at: now, took_ms: 30,
  me: {px, py},                                   # ponto calibrado
  pet: %{point, dx, dy, tiles, hp_pct} | nil,     # a marca com caixa mais perto do personagem
  hostiles: [%{point, dx, dy, from_me, from_pet | nil, hp_pct, skull?}],
  evidence: data_url | nil}
```

- O corpo fica um tile abaixo da barra (`mark_to_body_px`, hoje = `tile_px`;
  constante calibrável, não chave).
- `dx/dy` são inteiros em tiles a partir do personagem (direita e baixo
  positivos, como o cavebot); `from_me` e `from_pet` são Chebyshev.
- A marca que cai a ≤ 0,6 tile do ponto do personagem é ele e sai da lista.
- `hostiles` ordenado do mais perto do personagem ao mais longe.
- `listed` (a lista de batalha) NÃO entra aqui: vistos × lista é trabalho do
  `Siege`.
- Leitura falha (`read?: false, reason:`) quando não há calibração, ponto do
  personagem ou captura.

### 4.3 `Pokex.Bots.CrowdWatch` v2

- Olha a cada `crowd_scan_every_ms` (250) enquanto a caçada está em qualquer
  fase de luta ou com revive pedido/segurado; a cada 1 s andando com a lista
  vazia. Custo ~30 ms por olhada; o `Perf` continua medindo `look_ms` e
  `battle_age_ms`.
- **A caixa cobre a tela do jogo inteira** (`crowd_scan_radius_tiles` sobe de
  6 pra 8, cortada na borda da tela): a lista de batalha enxerga o viewport
  de 15×11, e um bicho listado fora da caixa de 12×9 viraria "sem ver" sem
  estar escondido — e seguraria o revive de um bicho que está longe. Com a
  caixa do tamanho da tela, `unseen` é escondido de verdade. Custo estimado
  ~45 ms por olhada (a área cresce 1,5×).
- Publica `:crowd` **com as marcas e os pontos** (hoje descarta).
- **Fotos como prova**, com as marcas desenhadas (barra em caixa, caveira
  marcada, pokémon com anel, personagem com a cruz), guardadas em dois
  momentos: ao abrir a luta (como hoje) e **em cada decisão de revive**, dada
  ou segurada, com o veredito no nome do arquivo
  (`captures/crowd/<ts>-<verdict>.png`). Trinta ficam. O gatilho vem da
  difusão `{:engine, picture, orders}` que o `Engine.Worker` já faz.

### 4.4 Testes

- `test/pokex/vision/creature_marks_test.exs`: um recorte PNG da foto real de
  03/09 (a pilha e um Feraligatr longe, ≤ 500 KB, em `test/fixtures/`) prova
  as marcas: 5 caveiras, 1 pokémon, vidas 100/100/100/100/100/96. Quadros
  sintéticos desenhados pelo teste (barras pintadas em tiles conhecidos, em
  três réguas) provam tamanho escalado, caveira e caixa.
- `test/pokex/bots/crowd_scan_test.exs`: muda de fixture, não de pergunta —
  geometria a partir de marcas, exclusão da marca do personagem, pokémon = a
  caixa mais perto, `from_pet` nulo sem pokémon, ordenação.

## 5. O cerco e o cérebro

### 5.1 `Pokex.Bots.Engine.Siege`

`build(crowd, listed, stun_cover, config, now)`, pura, dentro de
`Logic.tick/4`:

```elixir
%{read?: boolean, age_ms: n, pet_seen?: boolean,
  heavy?: boolean,   # a ÁREA tem caveira (nunca há mistura: ou todos, ou nenhum)
  hostiles: [%{dx, dy, from_me, from_pet, hp_pct, asleep?}],
  pinned: n,     # from_pet ≤ pin_tiles (1) — mordendo o pokémon
  covered: n,    # dormindo
  loose: n,      # acordado e fora da pilha
  unseen: n,     # max(listed − vistos, 0)
  nearest_awake_from_me: tiles | nil,
  recall_gap_ok?: boolean}
```

**Caveira é da área, não do bicho.** Lucas: "nunca existe bicho com caveira e
sem caveira misturados, ou são todos com caveira ou nenhum". Então `heavy?`
é um só: verdadeiro quando qualquer marca da leitura tem caveira, e **fica
travado durante a luta** (`logic.heavy_area?`, zerado quando a lista esvazia),
porque um efeito em cima da pilha esconde crânios sem mudar a área.

**Cobertura do stun.** Em todo lugar onde o cérebro carimba `:stunned` (as
ramas do controle, a do chefe e o `stamp_stun/1` do segurado) ou vê a
corrente acabar (`combo_just_ended?`), ele
guarda `logic.stun_cover = %{at, pet: {dx, dy}, points: [{dx, dy}]}` com os
inimigos da leitura daquele instante. Um inimigo está `asleep?` se o sono é
fresco (`now − at ≤ stun_hold_ms`) e existe um ponto coberto a ≤ 1 tile da
posição atual dele que estava a ≤ `stun_reach_tiles` do pokémon quando o stun
saiu. Quem chegou depois não casa com ponto nenhum: acordado, mesmo dentro do
raio hoje. Sem `stun_cover`, ninguém dorme.

**Não vistos.** Com sono fresco, `unseen` conta como pilha dormindo (o que
esconde barra é a pilha empilhada ou o efeito da área em cima dela). Sem sono
fresco, `unseen` é acordado em lugar desconhecido e o gap não fecha.

**A régua do revive.** `recall_gap_ok?` é verdadeiro quando não há acordado
(nem solto, nem sem ver) OU quando `nearest_awake_from_me` ≥ a guarda da
área: `recall_guard_tiles` (4) com caveira, `recall_guard_light_tiles` (2)
sem ("sem caveira é brincadeira"). Uma guarda só por luta, porque a área é uma
só.

### 5.2 As regras do `Logic` que mudam

1. `recall_safe?/1` = ciclo de chefe (`heavy?`, como hoje) OU tela limpa OU
   **(siege lido E gap ok)** OU **(siege não lido E sono fresco)**. Com o olho,
   sono fresco sozinho deixa de bastar (o solto). E o olho abre o revive SEM
   stun quando todo mundo está longe: um bicho a 6 tiles vindo, revive agora
   chega antes dele.
2. `held_by_recall?/1` continua parado com a reserva na mão; o controle sai
   quando pronto e o `stun_cover` nasce ali.
3. **Vermelho com gap fechado** (`emergency/1`): o pokémon caindo não ganha um
   revive que mata o personagem. Ordem: controle pronto → sai; senão parado
   com a reserva (`Orders.standing_and_firing`, `revive: :hold`); senão,
   abaixo de `revive_desperate_pct` (15), revive assim mesmo — o pokémon no
   chão é a mesma janela sem o revive. A fuga entra aqui na peça 4, antes do
   desespero.
4. `boss_tiles` passa a vir do olho no jogo: com a postura de chefe ligada
   (`heavy?` da `Situation` — o chefe por nome, cor ou grit, que é outra coisa
   que a caveira), é a distância do inimigo mais perto do pokémon.
   `close_enough_to_stun?/1` deixa de ser sempre verdadeiro fora da bancada.
   `boss_asleep_left_ms` continua só da bancada.

Tudo atrás de `crowd_watch_enabled` e `engine_recall_guard_tiles > 0`: com
qualquer um desligado o cérebro é o de hoje, byte a byte nos testes.

### 5.3 O motivo no feed

`Siege.summary/1` gera UMA frase curta em pt-BR que entra em toda ordem de
revive dada ou segurada (é `orders.why`; a narração já deduplica por frase):

- `olho (caveira): 3 colados dormindo · 1 solto a 5 tiles · 0 sem ver → revive seguro`
- `olho (caveira): 2 colados acordados · 1 solto a 2 tiles → segurando`
- `olho: 1 solto a 3 tiles, área leve → revive seguro`
- `sem olho (foto de 900 ms) → só o sono fresco vale`

O registro `:decision` (`Pokex.Engine.Events`) ganha
`siege: %{read, heavy, pinned, covered, loose, unseen, gap}`, e a foto da
decisão leva o veredito no nome. As linhas `🚑` do suporte não mudam.

### 5.4 Estacionar o pokémon ao lado do personagem quando a caçada para

Pedido de Lucas: "quando pararmos de andar, clicar com o botão do meio em 1
dos 4 tiles próximos ao meu personagem, com pelo menos 1 bloco de distância,
pra garantir que possamos ver todos os monstros que estão realmente atacando
meu pokémon". O pokémon segue o personagem a ~2 tiles; parado, a pilha fecha
em cima dele, longe do centro e da câmera. Com o pokémon a 1 tile do
personagem, a pilha fica no centro da tela, onde o olho lê melhor e onde a
marca `pet` tem um lugar previsível pra estar.

- **Quando:** na primeira ordem `route: :hold` com inimigo na lista (a parada
  do `sizing`/`bunching`/segurado), uma vez por parada. Não em paradas por
  escada, tropeço ou bloqueio.
- **Onde:** um dos quatro vizinhos ortogonais do personagem, a
  `cavebot_park_on_stop_tiles` (1) de distância, **do lado de onde a pilha
  vem** (o centróide dos inimigos da leitura, arredondado ao vizinho mais
  próximo); sem leitura, o tile de trás (o oposto ao último passo), que é
  por onde o pokémon já vem seguindo.
- **Como:** a mesma tubulação que já existe pro estacionar do fim da mobada:
  `Cavebot.Logic` devolve `{:park, {:tiles, {dx, dy}}}`, o `Worker` traduz
  por `Calibration.tile_point/2` e `park_click/2` (botão do meio nativo,
  `cavebot_park_clicks` vezes).
- **Prova:** o olho confirma (`pet.tiles == 1` nas leituras seguintes) e o
  cartão mostra; a bancada modela o clique (7.1) e mede a mesma pergunta com
  o estacionar ligado e desligado.
- **Uma dúvida que a bancada responde:** com o pokémon a 1 tile, a pilha fica
  a 1–2 tiles do personagem, e a guarda da recolhida se mede a partir dele —
  quem está dormindo não conta, mas um solto que chega já chega perto. O
  cenário `straggler-at-recall` roda nos dois modos e o número decide se 1
  tile é o certo ou se 2 compra segurança sem perder a câmera.

## 6. O cartão do cerco

`PokexWeb.SiegeComponents.siege_card/1`: SVG em espaço de tiles, `viewBox` =
a caixa do olho (12×9 tiles hoje), centrado no personagem — o idioma do mapa da
rota (`CavebotComponents.route_map/1`) e do `/sim`: coordenada de jogo é
coordenada de desenho. Recebe `siege`, `reading`, `photo` (opcional) e
`config` (raios).

Camadas, de baixo pra cima:

- a foto real por trás, escurecida, na MESMA escala (a foto é a caixa, então
  tile a tile bate por construção);
- grade de tiles;
- os raios: anel da mordida (`pin_tiles`) e do stun (`stun_reach_tiles`) em
  volta do pokémon; UM quadrado da guarda em volta do personagem (o da área:
  4 com caveira, 2 sem), Chebyshev como no `/sim`;
- inimigos como quadrados 1×1 em `(dx, dy)`: cor pela faixa de vida (paleta do
  `/sim`), contorno tracejado dormindo (idioma do `/sim`), **contorno grosso
  vermelho em quem está acordado dentro da guarda**; a caveira é um selo no
  cabeçalho ("área com caveira"), não um glifo por bicho;
- o pokémon em verde com anel, cinza quando não visto; o personagem no centro,
  o ponto azul do "você está aqui";
- selo "N sem ver" encostado na pilha.

Cabeçalho: a frase do `Siege.summary/1`, a idade da foto (`lido há 240 ms` /
`sem olho`) e o custo. Números tabulares, três tamanhos de texto, tokens do
`DESIGN.md`; nenhuma fonte ou cor nova (`design_drift_test` continua a régua).

**Na Central** (modo assistir): ao lado da tira do cérebro, no lugar do botão
"onde eles estão"; botão "foto agora"; e a última decisão de revive como
miniatura com o veredito no rodapé.

**No `/sim`:** dois cartões lado a lado, **verdade** (posições e sono exatos)
e **leitura** (marcas → geometria → `Siege`), e uma linha contando
divergências: pesados perdidos, dormindo julgado acordado e vice-versa, gap
errado. Essa linha vira a promessa `:eye_agrees`.

Interação: passar o mouse num inimigo mostra `dx, dy`, tiles do pokémon,
vida, sono. Sem zoom: o cartão é a tela do jogo.

## 7. Bancada, cenários e testes

### 7.1 `Pokex.Sim.World`

- `marks/1`: verdade → marcas pelo contrato da seção 4 (tile → ponto de tela
  pela mesma conversão do jogo, `Calibration.tile_point/2`). `skull?` vem do
  ninho (`heavy?: true` por padrão nas dungeons dele), `pet?` do próprio.
- **Cegueira por knob:** `stacked_hide?` (mobs no mesmo tile viram UMA marca,
  como barras empilhadas somem; ligado por padrão), `effect_hide_ms` (marcas
  dos atingidos somem por 300 ms depois de uma área), `mark_miss_pct` (perda
  aleatória por olhada; 0 por padrão, calibrado depois pelas fotos de campo).
- `siege_truth/1`: a foto julgada exata (sono pelo `asleep_until`, distâncias
  inteiras), pra linha de divergência e pros testes.
- Física que falta: `stragglers` (spawn a 6–8 tiles que acorda N ms depois da
  corrente); `player_bite_pct` (a mordida pesada NO PERSONAGEM durante a
  recolhida; 96 nas dungeons com caveira: a morte de 100% → 4% num golpe); e
  **o estacionar** — `Sim.Hands` passa a obedecer `{:park, {:tiles, {dx, dy}}}`
  como o clique do botão do meio: o pokémon anda até o tile pedido a
  `pet_ms_per_tile` e fica lá até o personagem andar de novo (aí volta a
  seguir). O alvo já muda pro personagem quando o pokémon está na bola
  (`target_of/2`).

A bancada entrega `inputs.crowd` passando as marcas por `CrowdScan.place/3`;
o `Siege.build` é chamado pelo `Logic.tick`, então não existe cópia
(`contrato_test` cobra os dois nomes no fonte da bancada). O `Runner` publica
`:crowd` na cadência real pra o `/sim` desenhar a leitura.

### 7.2 Cenários (`Pokex.Sim.Scenario`)

- `straggler-at-recall` — a morte das 16:20: pilha de 3, corrente mata 2, um
  chega de fora com a barra gasta. Promessas: `:no_recall_with_awake_in_guard`,
  `:alive`, e mortos por hora ≥ 90% do cenário sem straggler. Roda com o
  estacionar (5.4) ligado e desligado, e com o tile a 1 e a 2: é o número
  que decide onde o pokémon para.
- `asleep-pile-plus-loner` — pilha dormindo + um solto a 3 tiles: segura,
  controle sai, recolhe dentro da cobertura; `:alive`.
- `nine-on-top` (já existe como `nove-em-cima`; renomeado) — barras empilhadas
  e `unseen` alto: `:recall_flows` (revives por 10 min ≥ piso), pra cerca
  nenhuma travar a caçada.
- `skull-less-easy` — sem caveira, guarda 2: o revive abre mais cedo que no
  mesmo mundo com caveira, e `:alive`.
- `blind-eye` — `mark_miss_pct: 100`: **os números de todos os cenários
  atuais não mudam com o olho cego.** É a garantia de que ligar isso no jogo
  com o olho falhando é igual a hoje.

### 7.3 Promessas (`Pokex.Sim.Verdict`)

`:no_recall_with_awake_in_guard` (nunca `revive: :now` com `siege.read?` e
gap fechado), `:recall_flows`, `:eye_agrees` (divergência verdade × leitura
abaixo de um teto por corrida), mais `:alive`.

### 7.4 Testes de mesa

- `siege_test.exs`: tabela — chegou depois do stun; sem ver com e sem sono
  fresco; caveira × leve; foto velha → `read?: false`; sem pokémon visto.
- `logic_test.exs`: as quatro regras da seção 5.2, inclusive "olho aberto sem
  stun revive" e "sem olho = hoje".
- `contrato_test.exs`: a bancada chama `CrowdScan.place` e nunca deriva
  `Siege` por conta própria.
- LiveViews: o cartão com leitura, sem leitura e com foto; a linha de
  divergência no `/sim`.

### 7.5 Medição antes de mergear

O enxame de 4 sementes × 1 h com a config dele (`lotavanon`), olho desligado
(= hoje) e ligado: mortos, voltas, vida final, revives. Os dois lados no PR.

## 8. Chaves

| chave | padrão | onde | serve pra |
|---|---|---|---|
| `crowd_watch_enabled` | já existe | /config | chave-mestra: desligada = o bot de hoje |
| `engine_recall_guard_tiles` | 4 | /config, 0..10 | guarda do revive em área COM caveira; 0 = o olho não segura nada |
| `engine_recall_guard_light_tiles` | 2 | /config, 0..10 | a guarda em área sem caveira |
| `engine_revive_desperate_pct` | 15 | /config, 0..34 | abaixo disso o vermelho revive com gap fechado |
| `cavebot_park_on_stop` | true | /config | estacionar o pokémon ao lado do personagem em toda parada com bicho |
| `cavebot_park_on_stop_tiles` | 1 | travada, 1..2 | a que distância do personagem (a bancada decide entre 1 e 2) |
| `crowd_scan_radius_tiles` | 6 → 8 | travada (já existe) | a caixa cobre a tela do jogo inteira |
| `crowd_scan_every_ms` | 250 | travada | cadência em luta (1 s andando) |
| `crowd_fact_max_age_ms` | 600 | travada | foto mais velha = sem olho |
| `engine_pin_tiles` | 1 | travada | "colado" no pokémon |

Tamanhos de marca não viram chave (fração do `tile_px`). As chaves travadas
entram em `Settings.Locked` pra passar no teste de "chave sem destino".

## 9. Entrega em três PRs

Cada um inteiro, testado, com bancada verde e mergeável sozinho.

1. **Olho e cartão, sem cérebro.** `CreatureMarks`, `CrowdScan` v2,
   `CrowdWatch` publicando pontos, fotos por decisão, cartão na Central. O
   cérebro não lê nada. Lucas caça uma sessão; as fotos calibram a cegueira
   (`mark_miss_pct`, pilha empilhada) com dado real, inclusive na tela do
   notebook.
2. **Bancada e sombra.** `World.marks`, `siege_truth`, cenários, `/sim` com
   verdade × leitura, `Siege` calculado no tique e **escrito no feed como "o
   olho diria: …" sem mandar em nada**. Uma noite assim mostra onde ele
   discordaria do bot antes de ganhar a chave. **O estacionar (5.4) entra
   aqui**: primeiro o modelo na bancada e o cenário nos dois modos, depois o
   clique no jogo atrás de `cavebot_park_on_stop` — é a única mudança física
   antes do PR 3, e o olho do PR 1 é quem prova que o pokémon foi.
3. **O cérebro obedece.** As quatro regras da seção 5.2 atrás de
   `engine_recall_guard_tiles > 0`; bancada antes × depois; merge. As chaves
   de guarda nascem neste PR, já com o padrão 4/2: nos PRs 1 e 2 não existe
   regra pra elas mandarem.

### Checagem de campo do PR 1

- a barra escala com o `tile_px` na tela do notebook;
- quantas marcas sobrevivem numa pilha de 9;
- a caixa preta do número aparece só no pokémon dele (e o que é o "320");
- balão de fala esconde barra (a dele sumiu na foto);
- se 4 tiles de guarda bastam pra velocidade real dos monstros com caveira;
- (PR 2) o clique do meio leva o pokémon pro tile pedido, e ele fica lá até o
  personagem andar — o olho mostra `pet.tiles == 1` nas leituras seguintes.

## 10. Riscos e perguntas abertas

- **Outros jogadores e os pokémons deles** contam como inimigos (têm barra,
  não têm caixa perto do personagem). Falso "segurando", visível no cartão;
  aceito por ora.
- **Velocidade dos monstros** é desconhecida; a guarda de 4 é chute
  conservador. A fase C mede.
- **Efeitos e balões** escondem barras: o `unseen` cobre com sono fresco; sem
  sono, o revive segura. É o lado seguro do erro.
- **Custo**: 30 ms a cada 250 ms em luta é 12% de um núcleo do helper de
  captura. `battle_age_ms` fica no `Perf` pra provar que a lista não atrasa.

## 11. Nomes

`Pokex.Vision.CreatureMarks`, `Pokex.Bots.CrowdScan.place/3`,
`Pokex.Bots.CrowdWatch`, `Pokex.Bots.Engine.Siege`,
`PokexWeb.SiegeComponents.siege_card/1`, `Pokex.Sim.World.marks/1`,
`Pokex.Sim.World.siege_truth/1`; campos `stun_cover`, `heavy_area?`,
`recall_gap_ok?`, `pinned`, `covered`, `loose`, `unseen`, `skull?`, `pet?`;
ação do cavebot `{:park, {:tiles, {dx, dy}}}` (`park_beside/2`); cenários
`straggler-at-recall`, `asleep-pile-plus-loner`, `nine-on-top`,
`skull-less-easy`, `blind-eye`; promessas `:no_recall_with_awake_in_guard`,
`:recall_flows`, `:eye_agrees`.
