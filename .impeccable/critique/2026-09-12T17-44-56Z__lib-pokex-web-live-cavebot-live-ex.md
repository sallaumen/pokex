---
target: a Central do cavebot
total_score: 28
max_score: 40
na_heuristics: 
p0_count: 2
p1_count: 2
timestamp: 2026-09-12T17-44-56Z
slug: lib-pokex-web-live-cavebot-live-ex
---
Method: dual-agent (A: design review · B: detector + browser evidence)

## Design Health Score

| # | Heurística | Nota | Achado |
|---|---|---|---|
| 1 | Visibilidade do estado | 3 | `#cavebot-minimap-gap` diz "a posição não pode ser lida" enquanto `#tile-pos` mostra "2380, 30026 · andar 5 · agora" |
| 2 | Sistema ↔ mundo real | 4 | "as oito bocas", "as teclas saíram", "solte a caçada no painel" — a língua dele |
| 3 | Controle e liberdade | 2 | `#cavebot-active` troca o pokémon em campo no `phx-change`, sem confirmar e sem desfazer |
| 4 | Consistência | 2 | duas políticas de cor pra vida de inimigo na MESMA tela: lista neutra, olho pinta bicho saudável de `pk-danger` |
| 5 | Prevenção de erro | 2 | `revive_budget_out?` trata estoque DESCONHECIDO como seguro → selo verde |
| 6 | Reconhecer > lembrar | 3 | legenda fechada; 2 de 6 linhas da lista invisíveis sem nenhum indício |
| 7 | Flexibilidade | 3 | zero atalho de teclado numa tela vista por horas, num app que dirige o mouse |
| 8 | Estético e minimalista | 3 | 34% do viewport (266px de 790) é aviso antes do primeiro estado vivo |
| 9 | Recuperação de erro | 3 | a tarja "o resgate está desligado" não é clicável; o conserto está 660px abaixo |
| 10 | Ajuda e documentação | 3 | o ensino mora em `title=`, que é só do mouse |
| **Total** | | **28/40** | bom, com dois buracos sérios |

## Design Specificity

**Autoral, sem dúvida.** "1 coisa antes de dormir", "o que ela fez", "vi 3 · lista 5 · 2 sem ver", o `" ?"` que separa deduzir de ler, `count_label(nil) -> "não vejo a lista"` (zero e cego com palavras diferentes). Nada disso sai de template.

Onde escorrega pro genérico: dois grids de KPI empilhados (o resumo da noite e os seis cartões), com 12 células mostrando zero.

**Varredura determinística: o detector NÃO leu nada.** `detect.mjs` só escaneia `.html/.css/.jsx/.tsx/.vue/...` — `.ex` não está na lista, então os três arquivos foram descartados em silêncio e o exit 0 não significa "limpo". Corrijo o que reportei nos PRs de hoje.

**Evidência real (overlay no navegador):** 70 achados, 28 visíveis. Reais: contraste 3.87:1 no "62" (`pk-text-3` sobre `pk-ok-dim`), 11 alvos com menos de 24px de altura, salto de cabeçalho h2→h4, 3 controles nomeados só por `title`, `line-height` 1.25 no `#siege-headline`, tracking de 0.10em em texto corrido, e o `<svg>` do minimapa cobrindo a própria legenda. 41 eram `<details>` fechados (falso positivo).

## Priority Issues

### [P0] O layout de uma tela apaga o feed numa noite barulhenta
O bloco é `h-[calc(100dvh-4.5rem)]` e o cockpit é o `flex-1`. Cada tarja de aviso come a fatia do cockpit, mas o feed tem piso de 160px, o olho de 144px e o mapa é `shrink-0`. Quando não cabe, o conteúdo ESCAPA (overflow visível) e é pintado por baixo da barra de segurança.

Medido a 1440×790 (Chrome maximizado no notebook dele): com 3 avisos e luta rodando, o feed vai de 758 a 866 — inteiramente debaixo da barra de segurança e 76px além do viewport. **Zero linhas visíveis.** Mesmo a 1440×900 com luta, 36px do feed ficam ocultos. Quanto pior a noite, menos tela sobra.

### [P0] O selo "pronto pra noite" trata "não sei" como "pode"
`revive_budget_out?` só bloqueia quando a conta EXISTE e zerou. Sem conta → verde. É exatamente o estado da noite de 4,9 horas moendo com o pokémon no chão, que o próprio comentário do código cita.

### [P1] O olho pinta bicho saudável de vermelho
`hp_fill/1`: vida > 66 = `pk-danger`. Na mesma tela, `enemy_fill/2` recusa isso de propósito ("verde e vermelho aqui competiriam com as barras de cima"). Uma pilha cheia vira uma grade de quadrados cor de alarme.

### [P1] Emoji de interface entrou hoje, contra a regra do próprio DESIGN.md
`👁 o cerco` e `🪞 espelho` são rótulo e botão — o caso que a dívida declarada manda trocar por heroicon. E `pk-shiny` (roxo) existe no CSS e em três arquivos sem estar declarado no DESIGN.md.

### [P2] Quatro defeitos medidos
Números do mapa a **4,7px** (o selo novo herdou a fonte do mapa grande) e rótulos do olho a 6px, ambos abaixo do piso de 12px; barra de rolagem permanente de 1px (a conta do frame dá 100dvh+1); 2 de 6 linhas da lista invisíveis sem indício; `prefers-reduced-motion` não para o brilho do shiny (zera a duração mas não as iterações → estrobo).

## Persona Red Flags

**Lucas às 2h, de canto de olho:** dois chips verdes e um cinza na barra de segurança lê como "tá tudo bem" — o cinza é `resgate desligado`. O selo verde com o estoque não contado. O olho rosa de bicho saudável. O feed com 14 cópias da mesma frase no mesmo segundo.

**Lucas de manhã, lendo a noite:** 13 linhas, timestamps repetidos, sem colapso de repetidas — um evento tagarela apaga o incidente em um segundo. A saída real é o `copiar`, um botão fantasma de 54×19px.

**Lucas no meio da luta:** `#cavebot-active` nasce sem borda e dispara no `phx-change` — uma rolagem com o select focado troca o pokémon em campo, sem desfazer.

## Minor

Feed sem `tabindex` (teclado não rola); carimbo e "SUPORTE" repetidos em todas as linhas; a frase do cérebro truncada a 1280px; `▸` literal onde o resto usa heroicon; 12 células de zero ocupando ~15% do viewport.
