# A escada é um passo, não uma busca

**Data:** 2026-08-12
**Pedido do Lucas:** "quando to numa escada, é bem claro o ponto da escada que vai
ser o ponto exatamente entre o ponto de começo e fim de onde andei na escada (…)
se fui de um ponto X para um ponto Y à minha esquerda, a coordenada Y vai subir
em 2 pontos, 1 bloco da escada e 1 bloco de depois da escada, **com 1 passo só**,
e por isso eu sempre tento marcar o bloco logo antes da escada e logo depois pra
ajudar na implementação e evitar bugs (…) vejo isso com muita frequência sendo um
problema e a movimentação tá muito ruim ainda."

---

## O fato do jogo que ele ensinou

**Tomar uma escada é UMA tecla que anda DOIS tiles** — o degrau e o tile depois
dele — e muda de andar. Por isso ele marca o canto logo antes e o logo depois: o
par descreve a escada inteira, e **o degrau é o ponto médio**.

## Medido nas cinco rotas dele (2026-08-12)

14 trocas de andar. A assinatura que ele descreveu — um eixo com delta ±2 e o
outro com 0 — aparece em **7 delas**:

| trecho | dx | dy | limpo |
|---|---|---|---|
| Meganium wp7→8, wp61→62 | 0 | ∓2 | ✅ |
| Xatu wp22→23, wp25→26, wp27→28, wp49→50 | 0 | ∓2 | ✅ |
| Azumaril wp48→1 | 0 | +2 | ✅ |
| Xatu wp1→2 | 0 | +3 | ❌ |
| Xatu wp16→17 | 0 | −4 | ❌ |
| Xatu wp30→31 | −1 | +2 | ❌ |
| Xatu wp34→35 | +2 | +3 | ❌ |
| Azumaril wp2→3 | +2 | −3 | ❌ |
| Azumaril wp11→12 | −4 | −4 | ❌ |
| Azumaril wp23→24 | +1 | +3 | ❌ |

Nos sete tortos sobrou caminhada dobrada no mesmo canto — ele diz "sempre TENTO
marcar", e em metade das vezes conseguiu.

## O que a máquina faz hoje

Nada disso é conhecido. `Logic.follow_route/3` calcula `dx`/`dy` até o waypoint
alvo e, fora da tolerância, emite `{:walk, dx, dy}` — que o Worker traduz em
**segurar a seta** (`hold_walk/3`). Duas consequências:

1. **Segurar tecla numa escada é errado por construção.** O passo é uma tecla
   que anda 2 tiles; segurando, ele toma a escada no primeiro press e continua
   andando no andar de cima até o próximo tick (200ms) — passa do ponto.
2. **A busca do anel vira o caminho comum.** Se a leitura pegar o personagem no
   tile do meio (o degrau), `|dx| ≤ 1` e `|dy| ≤ 1` mas o andar ainda é o de
   baixo → cai em `enter_stairs/3` e tateia o anel de 16 posições, até
   `cavebot_stair_max_probes` (32) sondas de `cavebot_stair_probe_ms` (450ms) =
   **14 segundos** pra um degrau que uma tecla resolvia.

O anel (#230/#232) foi desenhado pra quando a gravação só tinha o tile onde ele
CAIU. O dado dele melhorou; a leitura não acompanhou.

## O desenho

### 1. A rota reconhece o trecho de escada

`Route.stair_leg(waypoints, index)` — PURA, sem processo nem tela:

- devolve `{:stair, sx, sy}` quando a perna que SAI de `index` muda de `z` **e**
  tem delta exatamente ±2 num eixo e 0 no outro; `sx`/`sy` são o sinal (a
  direção da tecla);
- devolve `nil` em qualquer outro caso — inclusive nos sete trechos tortos, que
  continuam caindo no anel.

O degrau é `{(x1+x2)/2, (y1+y2)/2}` — derivável, e é o que a tela mostra.

### 2. Escada se toma com UM TOQUE

Na `follow_route`, quando a perna atual é `{:stair, sx, sy}`:

- emite `{:nudge, sx, sy}` — que o Worker já traduz em soltar o hold e dar UM
  toque (o mesmo caminho do chute cego);
- espera `cavebot_stair_step_ms` pelo andar mudar;
- não mudou? repete, até `cavebot_stair_step_taps` (3);
- esgotou? **aí sim** entra no anel, que fica de rede pros trechos tortos.

### 3. O canto de partida deixa de ser aproximado

`arrival_tolerance` é 1 tile, então ele pode "chegar" ao canto de antes estando
ao lado — e de um tile ao lado, o toque não pega o degrau. **Quando a perna que
SAI de um waypoint é uma escada, chegar nele exige tile exato.**

### 4. A tela diz quais estão limpos

Na `/cavebot`, a perna de escada ganha 🪜. Limpa: mostra o degrau (o ponto
médio). Torta: diz que não está limpa e **por quê**, com a regra em uma linha.

⚠️ **Não dá pra oferecer a correção pronta, e é importante ser honesto nisso.**
O degrau só é derivável quando o par JÁ está limpo — é o ponto médio de dois
tiles que distam exatamente 2. Numa perna torta (`dy=+3`, ou `dx=−4/dy=−4`) a
gravação dobrou caminhada no mesmo canto e **a posição real da escada se perdeu**:
não existe conta que a recupere. A tela diagnostica e diz o que fazer; quem sabe
onde a escada fica é ele, andando até lá.

## O que este spec NÃO faz

- **Não mexe no anel** — ele continua sendo a rede dos trechos tortos.
- **Não conserta as rotas dele automaticamente**, nem propõe cantos: nas pernas
  tortas a informação não existe mais (acima).
- **Não ataca overshoot nem parede fora da escada.** As duas queixas dele
  ("passa do ponto e volta", "fica empurrando parede") são HIPÓTESES: o journal
  de 2026-08-11 tem 5 "BLOQUEADO: mudou de andar" e todos são o bug de duas
  rotas armadas do #214, não escada. Sem medição, não se constrói.

## A instrumentação que resolve isso

Junto, e só isso: cada decisão de andar passa a registrar **de que distância** ela
decidiu, **com que idade de leitura** (`cavebot_minimap_fact_max_age_ms` admite
até 800ms) e **onde o personagem estava** no tick seguinte. Isso dá as três
coisas que faltam pra fechar o diagnóstico do overshoot sem palpite: a velocidade
real dele em tiles/s (que ninguém mediu), quantos tiles ele anda por decisão, e
se a decisão foi tomada sobre um fato velho.

## Como se prova

- `Route.stair_leg/2` puro: os 7 trechos limpos das rotas REAIS dele devolvem a
  direção certa; os 7 tortos devolvem `nil`.
- `Logic`: perna de escada emite um toque e não um hold; não mudou de andar →
  repete; esgotado → entra no anel.
- `Logic`: chegar num waypoint cuja perna de saída é escada exige tile exato.
- Regressão: os trechos tortos continuam achando a escada pelo anel.
