# Plano: Auto-calibração + preview visual

## Status (2026-07-07)
- **Fase 1 — preview visual: FEITA** (`88c4f11`, `7f36770`). A matemática das
  bandas virou fonte única em `Calibration.row_band_geometry/2` +
  `battle_row_bands/3` (o sensor e o preview leem a MESMA fórmula). As bandas
  por-fileira (L0…Ln) e o ponto do player são desenhados em **vermelho** sobre o
  screenshot, na `/calibration` (Revisar) e na `/diagnostics` (Preview das áreas),
  via componente compartilhado `PokexWeb.CalibrationOverlay`.
- **Fase 2 — detectar fileiras por HP: função PRONTA, falta validar ao vivo**
  (`6bdae46`). `Vision.hp_bar_rows/2` acha o Y exato de cada barra de HP verde.
  Ainda NÃO ligada ao sensor — primeiro o botão **"Detectar fileiras (HP)"** na
  `/diagnostics` imprime os Ys detectados AO LADO dos centros das bandas
  calibradas, pra medir o drift antes de confiar. **Próximo passo depende do
  Lucas rodar isso no jogo** e confirmar que as barras batem.
- **Fases 3-4 — auto player/água + botão Auto-calibrar: PENDENTES**, e de
  propósito: dependem de medir pixels ao vivo (limiares de verde/azul), então não
  serão chutadas às cegas. Fazer depois que a Fase 2 for validada no jogo real.

## Problema
A calibração é manual (o usuário clica os cantos de cada região). Qualquer
desvio de alguns px desloca a `battle_region` → as bandas por-fileira não caem
nas fileiras reais → o lock lê errado (ex.: Magikarp na linha 1 lendo **20px** em
vez de ~900; o anel real, medido ao vivo, dá **600-922** na fileira certa). O
mesmo drift afeta água/arena. Marcar na mão sempre vai errar um pouco.

## Objetivo
1. **Preview visual**: screenshot com as regiões calibradas desenhadas em
   **vermelho** por cima, pra ver na hora se estão alinhadas.
2. **Auto-detecção** das regiões (prioridade: painel Batalha + fileiras), pra
   eliminar o clique-nos-cantos.

## Fatos medidos (implementar sem re-derivar)
- Tela do usuário: 3440×1440, `scale` 1.0. Tile ≈ **88px**. Personagem sempre no
  CENTRO do viewport (o mundo rola em volta).
- `battle_region` ≈ `[2481, 440, 272, 409]`. Fileiras ≈ **52-53px** de altura;
  1ª fileira começa ~screen-y 458. `battle_body` = region menos os 30px da
  direita (coluna da pokébola).
- **Barra de HP** de cada fileira: run horizontal de VERDE
  (`g≥120 and g≥r+40 and g≥b+40`) ou VERMELHO (vida baixa), ~5px de altura. As
  barras de HP são o melhor landmark de fileira (Y exato de cada linha). Medido:
  barras em frame-y 33 e 86 → espaçamento 53.
- **Anel/nome vermelho** de lock: `r≥200 and g≤60 and b≤60`. O anel fica
  ~20px ACIMA da barra de HP; a banda de leitura deve ser CENTRADA no ponto do
  clique (já corrigido em `50cd4ad`: `top = first_row_offset*scale - band/2`).
- Lock travado ≈ **600-922 px**; nome não-travado ≈ 16-25 px; limiar 350.
- Painel Batalha: faixa vertical escura à direita do mundo, com header
  "🔥 Batalha" + linha de ícones, depois as fileiras.

## Fases

### Fase 1 — Preview visual (PRIMEIRO; baixo risco, valor imediato)
Sobrepor as regiões JÁ calibradas num screenshot ao vivo, em vermelho:
`battle_region`, cada **banda por-fileira** (o que o lock realmente lê),
`glow_region`, `water_point`, `arena_region`, `neutral_point`, `player_point`.
- Implementação: `<div>` container relativo com a `<img>` do screenshot +
  `<div>`s absolutos vermelhos posicionados por `coord × (largura_exibida /
  screen_w)`. Sem lib de imagem. As bandas vêm de `Calibration` +
  `battle_row_height` (mesma matemática do sensor, incluindo o `- band/2`).
- Renderizar na `/calibration` e na `/diagnostics`.
- **Isso sozinho já deixa o drift óbvio** (Lucas vê as bandas fora das fileiras).

### Fase 2 — Auto-detectar as FILEIRAS da Batalha (crítico pro combate)
- `Vision.hp_bar_rows(frame)` → acha as barras de HP (runs horizontais
  verde/vermelho) dentro do painel → lista dos Y exatos das fileiras.
- Daí derivar `battle_first_row` (1ª barra − offset do anel ~20px) e
  `battle_row_height` (espaçamento entre barras) EXATOS, auto-corrigindo o drift.
- Auto-detectar o X do painel: a faixa vertical escura à direita (borda
  mundo↔painel) ou o header. Salvar `battle_region` ajustado.
- Requisito de calibração: ≥1 bicho na lista (teu pokémon + idealmente 1
  selvagem) pra existirem barras de HP.
- **Alternativa mais robusta a avaliar:** detecção DINÂMICA das fileiras a cada
  leitura (o sensor acha as barras de HP toda vez) — elimina a calibração
  estática da batalha e é imune a mover a janela. Custo: +1 análise por tick
  (aceitável no ritmo do combate). Decidir na implementação.

### Fase 3 — Auto-detectar player/arena + água (best-effort)
- Player centralizado → `player_point`/centro da arena = centro do viewport do
  jogo. Detectar os limites do mundo: da esquerda da tela até a borda esquerda do
  painel Batalha; `arena_region` = esse retângulo, player = centro.
- Água: detectar a maior região AZUL adjacente ao player como ponto de
  arremesso (heurístico). Se pouco confiável, manter água manual + mostrar no
  preview. `glow_region` deriva do `water_point`.

### Fase 4 — Botão "Auto-calibrar" + confirmação
- Botão que roda a detecção, mostra o preview com overlays vermelhos, e Lucas
  **confirma** ou **empurra** um ponto (ajuste fino). Salva o `%Calibration{}`.

## Arquivos
- `lib/pokex/vision.ex` — detectores puros: `hp_bar_rows/2`, `panel_bounds/2`,
  `blue_region/2` (todos sobre `Frame`, testáveis com frames sintéticos).
- `lib/pokex/calibration.ex` — `auto_detect/1` que monta o `%Calibration{}` a
  partir das capturas + detectores.
- `lib/pokex_web/live/calibration_live.ex` — botão "Auto-calibrar" + overlay de
  preview.
- `lib/pokex_web/live/diagnostics_live.ex` — preview no diagnóstico.
- Testes: `vision_test.exs` (detectores), `calibration_test.exs` (auto_detect).

## Ordem de execução sugerida
Fase 1 (preview) → confirma o drift visualmente → Fase 2 (auto-fileiras, resolve
o combate) → Fase 3/4 (resto + UI). Cada fase é commit+push próprio, testes
verdes, sem tocar na pesca/combate já estabilizados além do necessário.

## Em aberto (decidir na implementação)
- Fileiras: estáticas na calibração vs. dinâmicas por tick (recomendo dinâmicas
  se o custo couber — imune a drift e a mover a janela).
- Água auto vs. manual (começar manual + preview; auto depois se confiável).
