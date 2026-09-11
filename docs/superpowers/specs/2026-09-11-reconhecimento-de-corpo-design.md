# Reconhecer o corpo certo: forma, paleta e a prova antes da caçada

Data: 2026-09-11. Autor: a IA, a pedido do Lucas. Estado: **plano, aguardando a
revisão dele antes de qualquer código.** Identificadores em inglês; texto pro
usuário em pt-BR.

> "Só por cor me parece muito fraco mesmo. A gente deveria usar um conjunto de
> um padrão próximo de cores junto com algumas linhas pretas, o contorno … mas
> algo realmente que seja preciso. … Aconteceu na caçada de Golem agora, que eu
> só configurei o Golem Shiny e ele capturou um monte de Golem que não é Shiny."

## 0. O resumo, pra quem tem cinco minutos

O casador de hoje compara **só a distribuição de cores** de um quadrado de
65 px (`Pokex.Vision.SpriteLibrary`, histograma RGB de 512 cubos). Medido nos
quadros reais dele desta noite:

- ele **não distingue a forma escura de um bicho da forma comum** — uma foto
  do Golem escurecida a 45 % ainda dá 0,70 nos três Golems comuns (o limiar
  dele é 0,60): é exatamente "capturou um monte de Golem que não é Shiny";
- ele dá 0,68 em **chão de pedra** e 0,66 no **toolbar** com a foto das costas
  do Shiny Golem — as bolas em `y=32` de ontem;
- as fotos de 65 px são **fragmentos**: o corpo ocupa ~1 tile (151 px), e o
  quadrado pega 0,43 tile — a foto do "pé" dele é 81 % chão.

O reconhecimento do pokémon dele **não usa algoritmo melhor**: é o mesmo
histograma. O que o faz parecer preciso são três portões — só olha nas barras
de vida, só aceita o nome que está no `/time`, e exige 0,15 de vantagem sobre o
segundo colocado. Sem esses portões, a foto do Shiny Slowking dele pontua 0,57
no Venusaur e 0,54 num Golem comum.

A proposta (§5) é fazer a captura pelo mesmo caminho que já funciona no pokémon
dele, e trocar a medida por uma que enxerga o que ele pediu:

1. **âncora** — corpo só onde um bicho estava de pé (feito, #592) e a decisão
   sempre **relativa**: a foto do shiny tem que ganhar da foto do comum;
2. **forma + paleta** — máscara pelo contorno preto (a forma), acordo pixel a
   pixel de cor dentro da máscara (a paleta), medido nesta mesma noite com
   margem 2× maior que o histograma nos casos que importam;
3. **a foto inteira do corpo, em tiles** — o clique acha o contorno e recorta o
   corpo todo; a amostra vive em unidade de tile e atravessa as duas telas;
4. **a prova** — antes da caçada, um botão pontua todas as fotos contra a tela
   de agora e mostra onde casariam (como a prova do chão das cores especiais);
5. **a bancada** — os quadros reais desta noite viram fixtures com verdade
   marcada, e todo casador novo é medido neles ANTES do jogo.

Quatro PRs (§6). O primeiro não muda comportamento: é a bancada. O que só ele
pode fazer está em §9.

**A espécie de validação é o Kabutops** (decisão dele, 11/09 00:37: "parece
mais legal e menos parecido com uma rocha"). Ele mandou nove fotos 1:1 da tela
— bicho vivo e corpo, forma comum (laranja) e shiny (preta) — que já estão em
`test/fixtures/corpses/kabutops/` e já foram ensinadas no acervo dele (§3.4):
o corpo comum como veto, o shiny como caça. Com isso a queixa de hoje cai
**antes de qualquer código**: medido, o casador atual dá 0,99 no corpo comum
com a foto comum e 0,35 com a foto do shiny.

## 1. Por que agora

Diário e eventos dele de 10/09 (o método da casa: contar as frases de saída):

| medida | valor |
|---|---|
| bolas comuns entre 20:02 e 22:18 | 2.123 |
| "capturado" ditas pelo juiz | 2.091 (o juiz media um ponto de tela, #591) |
| bolas com a pilha ainda chegando (`bunching`) | 1.353 |
| bolas no meio da corrente (`engaged`) | 272 |
| bolas com a lista de inimigos zerada | 435 |
| bolas em `y ≤ 37` (toolbar / painel do topo) às 19:48 | 4, todas "Shiny Golem reconhecido 66–84 %" |
| "hora da bola — 26 corpo(s) no chão" numa tela sem corpo | 1 |
| corpos ensinados | 3 (Scizor ×3 fotos, Shiny Venusaur ×1, Shiny Golem ×2) |
| Golem comum ensinado | **nenhum** |

Os PRs #591–#594 fecharam a **hora** e o **lugar** da bola (só parado, só sem
bicho vivo, só onde um bicho estava, e a rota espera). Ficou o **quem**: com a
foto do Shiny Golem sozinha no acervo, todo corpo de Golem que cai onde um
Golem estava de pé casa com a única foto que existe.

## 2. O que existe (inventário, com file:line)

| peça | onde | o que faz hoje |
|---|---|---|
| o casador | `lib/pokex/vision/sprite_library.ex:287-322` (`signature/1`, `count_bins/2`, `intersection/2`) | histograma RGB quantizado a 3 bits/canal (512 cubos), normalizado; nota = soma dos mínimos |
| a busca de corpo | `lib/pokex/bots/catcher/spot_scan.ex:142-180` (`sweep/4`), `:197` (`score/5`), `:238` (`peaks/3`) | desliza um quadrado de `corpse_sprite_box_px` (65, `settings.ex:122`) a passo 51 sobre a região inteira (2 567 × 1 440 na ultrawide = 1 350 janelas), refina ±51 a passo 8 em volta dos 4 melhores picos, aceita picos ≥ `corpse_match_min_similarity` (padrão 0,72 `settings.ex:119`; **o dele está em 0,60**) |
| o veto por entrada desligada | `sprite_library.ex:340-350` | toda entrada compete, ligada ou não; ganhar desligada é veto ("conheço e não quero") |
| a âncora | `lib/pokex/bots/catcher/logic.ex:117-120` (`admissible/1`, #592) | corpo só a ≤ 1 tile de onde o olho viu um inimigo de pé |
| a foto ensinada | `lib/pokex_web/live/calibration_live.ex:788-812` (`corpse_click`) | clique → quadrado fixo de 65 px em volta do clique, guardado como RGBA base64 |
| a pintura | `lib/pokex/vision/recolor.ex` | matiz/saturação/brilho pra ensinar o shiny que ele nunca matou |
| o pokémon dele | `lib/pokex/bots/crowd_scan.ex:288-328` (`sprite_pet/5`, `clearly_best/2`) | o MESMO histograma, quadrado de 96 px (`pokemon_sprite_box_px`), piso 0,55, só nas barras de vida, só o nome do `/time`, vantagem ≥ 0,15 sobre o segundo |
| a cerca do shiny | `lib/pokex/vision/creature_fence.ex:88-98` | idem, pra dizer "essa mancha está em cima do MEU pokémon" |
| o rastreador | `lib/pokex/vision/finder.ex`, `lib/pokex/bots/pokemon_tracker.ex` | idem, numa janela pequena em volta de um ponto |
| a mira do shiny | `lib/pokex/bots/catcher/shiny_aim.ex:60-95` | corpo do shiny pela COR (`ColorMark`), com a tela limpa e a cerca do olho |
| o nome em cima do bicho | `lib/pokex/vision/name_labels.ex`, `ink.ex` | acha o texto colorido; não lê letras |
| o nome na lista de batalha | `lib/pokex/perception/interpret.ex:127-143` (`name_at/4`) | `Glyphs.read_name/3` com o léxico da pokédex — **só com layout calibrado, e o dele é `layout: null`**: `named: []` em toda decisão da noite, mais de 2.800 frases "está na lista sem nome legível" |
| o léxico | `lib/pokex/pokedex.ex:28` (`names/0`) | tem as formas shiny ("Shiny Rattata" na fixture `test/fixtures/pokedex/shiny_rattata.json`) |
| o tile | `lib/pokex/screen/tile.ex:22-25` | 151 px na ultrawide, 36 no notebook |
| os quadros salvos | `~/.pokex/captures/shiny/*-seen.raw` (10 desta noite), `corpse_teach.png`, `test/fixtures/crowd/*.png` | região inteira da varredura, 2 566 × 1 440 |

O que **não** existe: uma foto de corpo de Shiny Golem (ele nunca matou um com
a captura ligada); qualquer corpo comum ensinado; uma medida de quanto uma foto
casa com a tela ANTES de caçar; uma fixture de corpo real com verdade marcada.

## 3. O que medi (nos quadros dele desta noite)

Quadro: `captures/shiny/1789080297334-28-seen.raw` (19:44:57), a região da
varredura, 2 566 × 1 440, tile 151. Nele: **três Golems comuns vivos**, o
**Shiny Venusaur dele**, chão de pedra cinza, o toolbar. Nenhum corpo. Caixas
de verdade marcadas a olho. Scripts em Python (numpy/scipy) — os números vão
pra bancada do PR 0 em Elixir, com os mesmos quadros.

### 3.1 O casador de hoje, com as fotos dele

Melhor janela de 65 px **dentro** de cada caixa (histograma, como em produção):

| foto ensinada | Golem 1 | Golem 2 | Golem 3 | Venusaur dele | toolbar (melhor pico no quadro) | melhor no chão |
|---|---|---|---|---|---|---|
| Shiny Golem #0 (o pé) | 0,44 | 0,45 | 0,40 | 0,42 | — | **0,55** |
| Shiny Golem #1 (as costas) | 0,47 | 0,51 | 0,53 | 0,35 | **0,66** | **0,68** |
| Shiny Venusaur | 0,29 | 0,50 | 0,34 | **0,62** | — | 0,24 |

Com o limiar dele em 0,60, as costas do Shiny Golem casam com **chão** e com o
**toolbar** — e não com os Golems comuns neste quadro. (Os 1.353 arremessos de
ontem na pilha chegando são outro quadro: bichos sobrepostos, pose diferente.
Não afirmo o que não medi.)

### 3.2 O experimento que imita a captura: ensinar de uma morte, achar a próxima

Recortei o Golem 1 do próprio quadro como se fosse a foto ensinada (65 px) e
perguntei a cada casador onde ele dispara. Verdade: Golem 2 e Golem 3. Depois
repintei a mesma foto como um shiny repintaria — e aí a verdade é **nada**.

Máscara = o contorno preto da sprite (luminância < 60), dilatado 1 px, buracos
preenchidos, maior componente. No Golem vivo ela cobre 64 % do quadrado; na
foto do "pé" dele, 19 %; nas "costas", 85 %.

| casador | foto original → G1 / G2 / G3 / pior falso | matiz +150° (shiny) → pior falso | escurecida a 45 % → pior falso | escurecida a 70 % → pior falso |
|---|---|---|---|---|
| histograma (hoje) | 0,99 / 0,97 / 0,78 / chão 0,65 | chão 0,43 ✔ | **Golem 3 0,70 ✘** (0,70 / 0,68 / 0,67 nos três) | não medido |
| NCC RGB com máscara | 0,95 / 0,74 / 0,45 ✘ / chão 0,45 | **Golem 1 0,64 ✘** | **Golem 1 0,98 ✘** | — |
| NCC cinza com máscara | 0,95 / 0,72 / — / chão 0,51 | Golem 1 0,91 ✘ | Golem 1 0,98 ✘ | — |
| **acordo pixel a pixel na máscara** (\|ΔRGB\| ≤ 32) | **1,00 / 0,89 / 0,61** / chão 0,56 | Golem 1 0,77 ✘ | Golem 3 0,55 ✔ (chão 0,66) | **Golem 1 0,82 ✘ sozinho** — mas 1,00 vs 0,82 lado a lado ✔ |

Lendo a tabela:

- **Histograma**: acha bem os outros Golems (é invariante a pose), pega a
  troca de matiz, e **não pega a troca de brilho** — 3 bits por canal jogam
  todos os tons escuros no mesmo cubo. É o defeito de ontem em número.
- **NCC** (correlação normalizada, o "template matching" clássico): forte na
  forma, **cego a brilho por construção** (a normalização tira média e
  contraste) — dá 0,98 pro Golem comum com a foto escurecida. Também não acha
  o Golem 3 (outra face). Não serve sozinho.
- **Acordo pixel a pixel**: sensível a forma E a cor absoluta. Sozinho ainda
  aceita 0,82 numa escurecida suave; **lado a lado com a foto original ganha
  por 0,18**. O que separa o shiny do comum é a decisão RELATIVA, não um
  limiar absoluto — exatamente o `clearly_best/2` que o pokémon dele já tem.
- O matiz +150° passou a 0,77 porque a máscara inclui contorno e cinzas, que
  não mudam de matiz. **A paleta tem que ser medida nos pixels saturados; o
  contorno é só forma.**

### 3.3 O que mais a tela ensinou

- **Corpo no PA é uma sprite própria, deitada**, sem barra, sem nome, sem
  caveira (o Scizor caído em `corpse_teach.png`). Pose fixa: uma foto por
  espécie basta pra forma.
- **O nome em cima do bicho não escreve "Shiny"**: o Venusaur shiny dele está
  escrito "Venusaur", e o shiny selvagem da fixture
  `venusaur_shiny_e_comuns.png` também. O texto dá a ESPÉCIE, não a forma.
- A **lista de batalha** talvez escreva "Shiny Golem" (a pokédex escreve) — mas
  hoje ela não é lida (§2). Pergunta pra ele, §9.
- As sprites são desenhadas **ampliadas com suavização** na ultrawide (blocos
  macios de ~5 px); no notebook o tile é 36. A escala nativa precisa ser
  MEDIDA (PR 0), e a amostra tem que viver em **unidade de tile** pra
  atravessar as duas telas (o atlas de glifos que não atravessava tamanho de
  tela, #541, foi a mesma lição com as fontes).
- Os assets do cliente (`~/Games/PokeAlliance/data/things/things.dat` + 12
  `things.spr.part*`) estão **cifrados** (cabeçalho não é o de um `.dat`;
  `init.lua` compilado). Extrair as sprites de lá é quebrar a proteção do
  cliente — **não vou por aí.** As imagens da pokédex (`/pokemon/076.png`,
  `076.1.png`) são a **arte oficial** (140 × 140, 3.511 cores), não a sprite do
  jogo: servem pra mostrar o que é um shiny, não pra casar.

### 3.4 Kabutops: o corpo real das duas formas (as fotos dele de 11/09)

Nove fotos 1:1 (tile 151): 2 Kabutops comuns vivos, 3 shinies vivos, 3 corpos
comuns (laranja), 1 corpo shiny (preto). Amostras de 65 px cortadas como o
clique da calibração corta, **centradas no corpo** (o centróide dos pixels
laranja, ou dos pretos dentro do contorno) — a única diferença pro clique dele
é que o centro foi calculado, não apontado.

Melhor janela de cada foto (`hist` = o casador de hoje; `acordo` = pixel a pixel
na máscara, tol 32):

| amostra | corpo comum ×3 | corpo shiny | shiny vivo ×3 | comum vivo ×2 | chão | Golem vivo | Venusaur dele |
|---|---|---|---|---|---|---|---|
| comum (3 fotos), hist | **0,98–1,00** | 0,06–0,09 | 0,07–0,13 | 0,68–0,76 | 0,33–0,36 | 0,31–0,33 | 0,17–0,19 |
| shiny (2 cortes), hist | 0,35 | **1,00** | 0,81–0,88 | 0,39–0,48 | 0,37–0,40 | 0,47 | 0,38–0,39 |
| comum, acordo | 0,98–1,00 | 0,18–0,62 | 0,13–0,49 | 0,47–0,55 | 0,41–0,45 | 0,55–0,65 | 0,35–0,46 |
| shiny, acordo | 0,58–0,60 | 1,00 | 0,50–0,64 | 0,30–0,35 | 0,22–0,24 | 0,53 | 0,50–0,52 |

O que muda em relação ao Golem: laranja contra preto é uma troca de paleta
enorme, e **o histograma de hoje já separa as formas** (0,99 vs 0,35 no corpo
comum; 0,06–0,09 vs 1,00 no corpo shiny). O Golem falhava porque olive-escuro
contra preto cai nos mesmos cubos de 3 bits. O acordo pixel a pixel é PIOR aqui
no shiny (0,58 no corpo comum): as lâminas cinza e o contorno estão nas duas
formas — a §5.3 já pede paleta só nos pixels do corpo e decisão relativa.

O que continua igual: a foto do shiny dá 0,81–0,88 no **shiny vivo** — corpo e
bicho de pé têm a mesma paleta; quem impede a bola é a lista zerada (#593) e a
âncora (#592), não o casador. E o Golem vivo fica em 0,47 com a foto do shiny —
abaixo do limiar dele (0,60), mas não com folga de 2×.

Estado do acervo dele agora (`~/.pokex/corpses.json`, backup
`corpses.json.bak-antes-do-kabutops-20260911-003924`): **Shiny Kabutops**
ligado (2 amostras), **Kabutops** desligado = veto (3 amostras), Shiny Golem
desligado (fotos guardadas), Scizor e Shiny Venusaur desligados.

### 3.5 O corpo escondido: a luz do item, e por que a identidade vem do bicho vivo

Ele matou um shiny nesta madrugada e a bola não saiu. Primeiro, porque a
varredura nem rodou — a chamada da bola saía no mesmo tique em que a rota
voltava a andar (390 de 398 chamadas fechadas; corrigido no #597). Depois,
porque **em cima do corpo acende uma luz por ~34 s**: é a luz de **item
dropado** — qualquer pokémon, várias cores, não é marca de shiny (correção
dele) — e enquanto ela está lá o corpo não se vê. Um casador de corpo, seja
qual for, não casa o que não vê.

Consequência pro desenho: **a identidade do corpo vem do bicho VIVO** e viaja
com a âncora (#592) até o lugar onde ele morreu. O que existe pra isso: a
guarda por cor (`ShinyGuard`/`ColorRules`, o vigia só conta cor em cima de
bicho vivo) e as fotos dele do shiny de pé (`live_shiny_1..3`, §3.4). Cada
âncora ganha `form` (hunted / common / unknown) quando o bicho ainda está de
pé; ao fechar a rodada, uma âncora `hunted` leva a bola no ponto dela mesmo
sem corpo visível, com a bola da forma. A varredura do corpo vira confirmação
quando dá pra ver, não condição. A luz do item, se for medida um dia, serve
só como "caiu um corpo aqui" — nunca como "é shiny".

## 4. Os caminhos

**A. Só os portões: âncora + forma comum ensinada como veto + prova.** Nada de
casador novo. Medido: a decisão relativa com histograma separa a escurecida a
45 % (0,99 vs 0,70). Não resolve o chão e o toolbar a 0,68 (a âncora resolve na
prática), nem a foto-fragmento, nem a tela do notebook. É a fatia mais barata e
entra primeiro de qualquer jeito (PR 1).

**B. Forma + paleta, com máscara, em tiles, sob os mesmos portões
(recomendado).** O casador passa a responder duas perguntas separadas — "é
esta forma?" (contorno) e "é esta paleta?" (cor nos pixels saturados) — e a
decisão é sempre entre as formas ensinadas, com vantagem mínima. Medido com
margem maior que o histograma onde importa; explicável pixel a pixel (a prova
mostra ONDE casou); custo cabe porque só se mede nas âncoras (§5.4). É o que
ele pediu: "padrão próximo de cores junto com o contorno".

**C. Biblioteca de sprites do próprio jogo.** Seria o ideal (máscara perfeita,
todas as formas, todas as espécies). Descartado: assets cifrados (§3.3).

**D. Modelo aprendido (rede pequena).** Sem dados rotulados, sem runtime no
BEAM, e uma caixa preta onde ele pediu precisão que dê pra conferir.
Descartado.

Decisão proposta: **B, entregue em fatias em que A é a primeira.**

## 5. O desenho

### 5.1 A regra de identidade

Uma bola sai quando, no ponto ancorado, a foto de uma **forma caçada** vence
todas as outras formas ensinadas (comum, dele) com vantagem ≥ `clear_by`, e a
forma passa do piso. Empate ou vitória de uma forma não caçada = sem bola, com
a frase dizendo quem ganhou ("Golem comum 0,91 vs Shiny Golem 0,63 — sem
bola"). É a regra que o pokémon dele já obedece (`clearly_best/2`), aplicada
ao corpo.

Toda entrada do acervo ganha um campo `form`:

| `form` | significa | efeito |
|---|---|---|
| `hunted` | o que ele quer capturar | pode levar bola |
| `common` | a forma comum da mesma espécie | veto quando ganha; é o que faltava hoje |
| `mine` | o pokémon dele | veto; unifica com `pokemon_sprites.json` (§5.5) |

A entrada "desligada" de hoje vira `common` na migração. O painel diz o que é
cada foto e o que acontece quando ela ganha.

### 5.2 A amostra: o corpo inteiro, com máscara, em tiles

- **Clique acha o corpo**: a partir do clique, o contorno preto (luminância
  < 60, dilatado 1 px) é seguido e preenchido; o maior componente é o corpo;
  a caixa é a sua envolvente + 2 px. Nada de 65 px fixos. Se não houver
  contorno fechado (clique no chão), o painel diz "não achei um corpo aqui".
- **Máscara guardada** com a amostra (`mask`, bits por pixel) — os pixels do
  corpo. O chão em volta deixa de fazer parte da foto.
- **Unidade de tile**: a amostra é reamostrada pra um tile canônico
  (`@canonical_tile_px`, decidido no PR 0 pela medição da escala nativa; 64 é a
  hipótese) e guarda o tile de origem. Casar em outra tela é reamostrar a
  região pelo tile dela. Amostras velhas de 65 px continuam válidas como
  "fragmento" (sem máscara → máscara cheia, forma marcada `fragment?: true`)
  até serem reensinadas; o painel avisa.
- **Pintura** (`Recolor`) continua existindo pro shiny nunca visto, aplicada só
  dentro da máscara; a amostra pintada é `painted: true` como hoje.

### 5.3 O casador: `Pokex.Vision.SpriteMatch` (novo), por trás da mesma API

`SpriteLibrary.best_in/3` e `match/3` continuam sendo a porta; por dentro:

1. **forma** (`shape`): correlação normalizada em cinza, dentro da máscara —
   invariante a brilho de propósito (é forma). Medido: 0,95/0,72 nos Golems,
   ≤ 0,51 no chão.
2. **paleta** (`palette`): fração dos pixels da máscara **com saturação ou
   brilho acima de um piso** (fora o contorno e os cinzas) cujo RGB está a ≤
   `tol` do pixel ensinado. Medido com tol 32: 1,00/0,89 na verdade, 0,46–0,55
   na escurecida a 45 %.
3. **nota** = `shape × palette` (as duas têm que estar lá), e a decisão da §5.1
   entre as formas.
4. **busca**: grosso na região reamostrada em tiles (barato), fino ±4 px na
   tela em volta do melhor.

Os limiares nascem da bancada (§7), não de opinião: piso de forma, tol da
paleta e `clear_by` são os valores em que a verdade passa em 100 % das
fixtures e o pior falso fica com margem ≥ 2×.

### 5.4 A busca: verificar nas âncoras, não varrer a tela

Hoje: 1 350 janelas × 3 amostras por varredura. Com #592, o corpo só pode estar
onde um bicho estava de pé — ≤ ~10 pontos. A varredura passa a **verificar**:
em cada âncora, cada forma ensinada, grosso em tiles (±meio tile) e fino em
pixels. É o que torna uma nota mais cara (máscara + duas medidas) mais barata
que a de hoje. A pesca e o modo Parado (sem olho) continuam com a varredura
deslizante — com o casador novo.

### 5.5 Um casador pra tudo

`CrowdScan.sprite_pet/5`, `CreatureFence.mine/5`, `Finder`, `ShinyAim` e
`SpotScan` passam a usar o mesmo `SpriteMatch`. O acervo do pokémon dele
(`pokemon_sprites.json`) vira `form: mine` no mesmo formato de amostra; o
arquivo continua separado (a separação é a segurança — teaching o pokémon dele
no acervo de corpos faria a bola voar nele). Uma medida, um número, uma frase
no diário.

### 5.6 A prova, no painel

Ao lado de cada foto: **"provar na tela de agora"** — tira a foto da região,
pontua a amostra em toda a região (deslizante, como a pesca), e mostra as 5
melhores janelas com miniatura, nota de forma, nota de paleta e onde caiu
(chão / toolbar / em cima de um bicho vivo / em cima do pokémon dele). É a
prova do chão das cores especiais (`calibration_live.ex:998-1074`) aplicada ao
corpo: ele vê o falso positivo ANTES da caçada, não no diário do dia seguinte.

### 5.7 A frase

Cada bola e cada recusa dizem quem ganhou e de quem: "Shiny Golem 0,88 (forma
0,93 · paleta 0,95) vs Golem comum 0,61 — bola" / "Golem comum ganhou — sem
bola" / "só forma, paleta 0,41 — não é o Shiny Golem". A hora da bola já lista
as manchas de fora (#592); passa a listar a forma vencedora de cada âncora.

## 6. As fatias (cada uma mergeável sozinha)

### PR 0 — a bancada e a escala (sem mudar comportamento)

- Fixtures: as nove fotos do Kabutops (já em `test/fixtures/corpses/kabutops/`)
  + o quadro `1789080297334-28-seen` (e `corpse_teach`) recortados às caixas de
  verdade, com `truth.json` (caixas: bicho vivo, corpo, pet, chão, toolbar, por
  espécie e forma).
- `Pokex.Vision.Bench` (ou `mix pokex.vision.bench`): pra cada casador e cada
  amostra, a tabela da §3.2 — verdade, pior falso por classe, margem. Um teste
  asserta as margens do casador de produção; mudar o casador sem passar na
  bancada não compila a promessa.
- Medição da escala nativa: fotografar o mesmo corpo na ultrawide e no
  notebook e medir o período dos blocos; fixa `@canonical_tile_px`.
- Nada muda pra ele. Valor: os números da §3 viram guarda.

### PR 1 — o caminho A: forma comum, veto e prova

- Campo `form` no acervo, migração (`enabled: false` → `common`), painel com
  a forma em cada foto e a frase do efeito.
- `SpotScan` decide por `clearly_best` entre as formas (com o histograma de
  hoje), e a frase diz quem ganhou.
- Botão "provar na tela de agora" (§5.6) com o casador de hoje.
- Valor: a queixa de hoje ("capturou Golem comum") cai no dia em que ele
  ensinar o Golem comum. Medido: 0,99 vs 0,70.

### PR 2 — forma + paleta, corpo inteiro, tiles

- `SpriteMatch` (§5.3), o clique que acha o contorno (§5.2), amostra com
  máscara em tiles, migração das amostras velhas como fragmento.
- `SpotScan` verifica nas âncoras (§5.4).
- A bancada do PR 0 passa a medir o casador novo e asserta as margens.
- Valor: a foto escurecida deixa de casar com o comum sozinha; chão e toolbar
  caem pela forma; a mesma foto vale no notebook.

### PR 3 — um casador pra tudo

- Pokémon dele, cerca do shiny, rastreador e mira do shiny no `SpriteMatch`
  (§5.5). Os testes existentes de cada um continuam; o `@clear_by` e o piso
  passam a vir da bancada.

### PR 2b — a identidade viaja com a âncora (a luz do item, §3.5)

- A âncora (#592) guarda a forma do bicho de pé: `hunted` quando a guarda por
  cor (regra ensinada e provada do shiny) ou a sprite viva do acervo o
  reconhece, `common` quando o acervo reconhece a forma comum, `unknown` no
  resto. A regra de cor do Shiny Kabutops (preto + verde) é dele pra ensinar.
- Ao fechar a rodada, âncora `hunted` = bola no ponto, com a bola da forma,
  corpo visível ou não; a confirmação é "inconclusiva" enquanto a luz cobre o
  corpo (nunca "capturado" por ausência).
- Medir antes: no jogo, a bola jogada em cima da luz pega o corpo? (só ele.)

### PR 4 — identidade pelo texto (depende da resposta dele, §9)

- Se a lista de batalha escreve "Shiny Golem": calibrar o `battle_rows` do PA
  (o `layout: null` de hoje) e ler os nomes — a espécie e a forma viram fato
  ANTES do bicho morrer, e a âncora (#592) carrega o nome pro corpo. Isso
  também mata as mais de 2.800 frases "sem nome legível" por noite.
- Se não: a espécie pela largura do nome em cima do bicho + léxico (o texto
  "Golem" tem 45 px; "Machamp" tem outra largura) — sem OCR de letra.

## 7. Medição primeiro (inegociável)

Antes de qualquer limiar entrar no código:

1. corpus: os 10 `-seen.raw` desta noite, o `corpse_teach.png`, as fixtures
   `crowd/*.png`, e **pelo menos um quadro com corpo de Golem comum e um com
   corpo de Shiny Golem** (só ele consegue, §9);
2. pra cada casador: verdade em 100 % das fixtures, pior falso por classe
   (chão, toolbar, bicho vivo, pokémon dele, forma irmã), margem ≥ 2× — o
   número vai no PR, como a régua do grit (#461);
3. tempo por verificação numa âncora, na máquina dele, com 4 formas — teto:
   a varredura inteira em < 150 ms (a de hoje é 67 ms).

## 8. Testes

- `SpriteMatch`: forma pura (mesma sprite, brilho ±50 % → forma ≥ piso, paleta
  < piso), paleta pura (matiz +150° → forma alta, paleta baixa), máscara vazia,
  amostra maior que a região, tela reamostrada (tile 36 e 151 da mesma
  amostra).
- Contorno: clique no corpo → caixa envolvente; clique no chão → recusa;
  contorno aberto (corpo cortado na borda) → recusa com frase.
- Decisão: hunted vence por ≥ clear_by → bola; common vence → sem bola com a
  frase; empate → sem bola; um só ensinado → precisa do piso.
- Migração: `enabled: false` → `common`; 65 px sem máscara → fragmento.
- Bancada: o teste que asserta as margens nos fixtures reais.
- Os testes do pokémon dele, da cerca e da mira continuam verdes no PR 3.

## 9. O que só ele pode fazer, e as perguntas

1. ~~Ensinar o corpo comum como forma a não capturar~~ — **feito com o
   Kabutops** (§3.4). Pra outra espécie: ensinar o corpo comum e desligar.
2. ~~Fotografar um corpo de shiny~~ — feito (Kabutops). **Validar em jogo**:
   uma caçada de Kabutops com a versão atual (#591–#594 + o acervo de §3.4) e
   trazer o diário — a frase da hora da bola diz quem ganhou em cada âncora.
3. **Responder**: na lista de batalha, um shiny selvagem aparece como "Shiny
   Kabutops" ou "Kabutops"? (em cima do bicho é só "Kabutops", medido nas
   fotos dele.) Decide o PR 4.
4. **Dizer em quais telas caça** (ultrawide e notebook?) — a escala nativa é
   medida com um corpo em cada uma.
5. Confirmar: a bola por forma (`hunted` escolhe a bola; `common` não leva
   nenhuma) é o que ele quer, ou há espécie comum que ele TAMBÉM captura?

## 10. Armadilhas (lidas antes de codar)

- **Limiar absoluto mente**: 0,82 numa escurecida suave passa qualquer piso
  razoável; só a comparação entre formas separa. Nunca decidir sem o irmão.
- **O contorno é forma, não paleta**: pixels pretos e cinzas não mudam com o
  shiny; medir paleta neles é o 0,77 do matiz +150°.
- **Pose**: NCC perdeu o Golem 3 (outra face). Corpo tem pose fixa; bicho
  vivo não — o pokémon dele precisa das faces ensinadas (já tem 3–4).
- **A foto-fragmento**: 65 px é 0,43 tile; a máscara da foto do "pé" é 19 %.
  Ensinar de novo o corpo inteiro é parte do trabalho dele, não opcional.
- **Escala**: nada de píxel fixo — tudo em tile
  (`docs/refactor/calibracao-por-tela-2026-09-03.md`).
- **Não afirmar o que a foto ensinada "é"**: eu chamei as costas do Shiny
  Golem de chão ontem. A prova no painel existe pra que a tela responda, não
  eu.
- **Os assets do cliente ficam fechados.** A via é ensinar pela tela.

## 11. Referências

- Template matching, NCC e suas limitações (brilho, oclusão, fundo):
  [Wikipedia — Template matching](https://en.wikipedia.org/wiki/Template_matching),
  [PyImageSearch — cv2.matchTemplate](https://pyimagesearch.com/2021/03/22/opencv-template-matching-cv2-matchtemplate/),
  [OpenCV — máscara só em CCORR_NORMED](https://github.com/opencv/opencv/issues/14076).
- Bots de jogo 2D comparando cor, histograma e bordas:
  [Clicker Bot for Gacha Games Using Image Recognition](https://www.sciencedirect.com/science/article/pii/S1877050921000521),
  [Best approach to game sprite object detection](https://answers.opencv.org/question/150993/best-approach-to-game-sprite-object-detection/).
- Formato `.spr`/`.dat` e cifragem no OTCv8 (o porquê do caminho C ser fechado):
  [OTLand — tibia .spr file format](https://otland.net/threads/understanding-tibia-spr-file-format-from-tibia-7-4.261776/),
  [OTLand — encrypt my .spr](https://otland.net/threads/i-need-a-encrypt-my-spr.283964/).
- Filtro de pixel art ampliada (por que os blocos são macios):
  [Pixel Art Filtering](https://jorenjoestar.github.io/post/pixel_art_filtering/).
- No repo: `docs/shiny/plano-shiny-por-cor.md` §4 (cor-presença vs histograma),
  `docs/superpowers/specs/2026-09-09-shiny-na-cacada-design.md`, #553 (o meio
  tile do pokémon dele), #582 (caixa RGB exata), #591–#594.
