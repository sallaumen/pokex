# Percepção Total — spec de design

**Data:** 2026-07-22 · **Aprovado por:** Lucas (design em 7 seções, aprovação integral)
**Objetivo em uma frase:** o bot passa a ENXERGAR a tela inteira o tempo todo — nomes,
números, equipe, posição — sem nenhuma calibração manual de HUD, abrindo caminho pros
combos e, no salto seguinte, pro bot que caça sozinho.

## Contexto e motivação

Hoje a percepção cobre 4 regiões calibradas à mão (battle/arena/skill bar/corpses) e lê
apenas formas e cores. Lucas pediu (2026-07-22): "agora a gente vai pensar na minha tela,
começar a mapear todos os elementos e, o tempo todo, ter esses elementos mapeados
internamente… não quero mais que tenha uma descalibragem manual… só vai parar essa
implementação quando tudo estiver perfeito."

A captura de tela real de 2026-07-22 (fixture `test/fixtures/screen/ultrawide_3440x1440_full.png`,
3440×1440, fullscreen no monitor principal) é a VERDADE-TERRA deste projeto: toda medida,
todo glifo e todo template saem dela (e de capturas futuras rotuladas). Ela mostra:

| Elemento | Região aproximada (px, origem topo-esquerda) | Conteúdo legível |
|---|---|---|
| Pokélog Tracker | (0, 30) 300×480 | nomes + contadores de caçada ("Shiny Seadra 6/10") |
| Pokémon ativo | (0, 960) 360×160 | avatar, tecla Q, HP em dígitos "5559/6410" |
| Equipe C+2..C+6 | (0, 1115) 360×330 | fileira por slot: sprite, barra HP verde, barra azul |
| Barra inferior | (1200, 1330) 1140×110 | comida "1525💚", level "90⚪", "10:33⚡", pesca "96🎣", slots com contadores (F1=322, F2=36, E=7, S+Q=43, F4=245, C+E=322) |
| Minimapa | (3155, 0) 275×455 | mapa + coordenada TEXTUAL "(337, 46107, 4)" no topo |
| Battle list | (3140, 455) 300×345 | header "🔥 Battle", linhas com nome ("Pidgeot"), barra de HP do inimigo, estrela shiny, pokébola |
| Arena | centro (≈ 340..3140 × 0..1330) | nomes flutuantes (verde=Lucas, amarelo=pokémon, azul=players) |

Fatos confirmados pelo Lucas (2026-07-22):
- A barra "5559/6410" é o HP do **pokémon ativo** (não do personagem).
- O **level do personagem** é o "90" da bolinha ⚪ azul na barra inferior.
- Alertas de estoque: slots **F1, F2, E, S+Q** (bolas, bolas, poção, Shift+Q).
- Troca de pokémon: **C+N troca direto** (uma tecla recolhe o atual e manda o escolhido).
- O "96 🎣" é o skill de pesca, não o level.

## Decisões de arquitetura (aprovadas)

### D1 — Leitura de texto: atlas de glifos determinístico

O cliente desenha texto com fonte bitmap: cada caractere é sempre os mesmos pixels.

- **Atlas** em `priv/glyphs/atlas.json`: assinatura de pixels → caractere, por variante de
  fonte (a barra inferior, o HUD esquerdo e a battle list usam a mesma família em
  tamanhos próximos; o atlas guarda variantes separadas por altura de linha).
- **Pipeline de leitura**: binariza por luminância (texto claro sobre painel escuro),
  segmenta glifos por colunas vazias, casa cada glifo por assinatura exata; sem match
  exato → vizinho mais próximo com teto de distância; acima do teto → `?` e confiança
  degradada. Consumidor NUNCA chuta: leitura com confiança < 1.0 vira `nil` nos campos
  críticos.
- **Léxico**: nomes de pokémon fecham contra a Pokédex local (866 nomes) com distância de
  edição ≤ 2 — um glifo ruim não derruba o nome.
- **`mix glyphs.learn`**: (re)constrói o atlas de fixtures rotuladas
  (`test/fixtures/glyphs/labels.json`: região + string esperada). Cliente mudou a fonte →
  testes quebram alto → rodar o learn com uma captura nova.
- **Rejeitado**: OCR (tesseract) — dependência pesada, lento, não-determinístico;
  sprite-matching como fundação — não cobre dígitos e os ícones de 20px não batem com os
  sprites da wiki (pode virar validação extra futura).

### D2 — Auto-calibração: layout profile + âncoras

Em fullscreen numa resolução fixa, os painéis do cliente são dockados: TODA região de HUD
é fixa relativa a poucas âncoras.

- **Profile** `priv/layouts/ultrawide_3440x1440.json`: 3 âncoras-template (header
  "Battle" com o 🔥, moldura do minimapa, aba "Sto" da hotbar — PNGs commitados em
  `priv/layouts/anchors/`) + todas as regiões de HUD declaradas como offsets das âncoras.
  Medidas extraídas da fixture.
- **`Layout.locate/0`** (boot + sob demanda): captura tela cheia → acha as âncoras (busca
  exata dentro de janelas declaradas no profile) → deriva as regiões → VALIDA (a região do
  header tem que ler "Battle" via Glyphs) → publica fato `:layout` no WorldState e
  persiste em `~/.pokex/layout_fix.json`.
- **Re-localização automática**: streak de falha em qualquer feed OU validação quebrada →
  re-locate. Âncora não encontrada → banner alto no painel ("o jogo está em fullscreen no
  monitor principal?") e os feeds seguram — nunca clicar às cegas.
- **O wizard manual MORRE para HUD.** Sobram só pontos de MUNDO (água, spot do pokémon,
  escada de fuga, faixa do minigame) — conteúdo do mapa, impossível de ancorar em UI.
- **Monitor 2 (futuro)**: outro JSON de layout + seletor no perfil de calibração. Fora do
  escopo desta leva; a estrutura de profiles já nasce pronta pra isso.

## Componentes

### C1 — `Pokex.Vision.Glyphs`
- `read_line(frame, region, opts \\ [])` → `%{text: String.t(), confidence: float}`
- `read_int(frame, region)` → `integer | nil`
- `read_coord(frame, region)` → `{x, y, z} | nil` (parse de "(337, 46107, 4)")
- `closest_name(raw, lexicon)` → `String.t() | nil` (edição ≤ 2)
- Atlas carregado em `:persistent_term` (padrão da Pokédex); testes escopam por env key.

### C2 — `Pokex.Layout`
- `locate/0` → `{:ok, %Layout.Fix{}} | {:error, reason}`; `Fix` carrega todas as regiões
  derivadas + `located_at`.
- `regions/0` → regiões correntes (WorldState, com fallback ao arquivo persistido).
- Integração: `Calibration.load/0` passa a MESCLAR — campos de HUD vêm do Layout.Fix,
  pontos de mundo continuam do wizard. Consumidores existentes não mudam de API.

### C3 — Feeds novos/turbinados (máquina `Perception.Feed` existente, sem mudanças nela)
- `:battle` (120ms, turbinado): + `enemies_detail: [%{row, name, hp_pct, shiny?}]`
  (nome via Glyphs + léxico; HP pela proporção verde→vermelho da barra; shiny já existe).
- `:hud` (novo, 500ms): `%{pokemon_hp: {cur, max}, level, food, fishing,
  slots: %{f1: n, f2: n, e: n, s_q: n}}` — tudo via Glyphs sobre sub-regiões do profile.
- `:team` (novo, 500ms): `[%{slot: 2..6, present?: bool, hp_pct: float | nil}]` por
  fileira C+N (barra verde: proporção preenchida).
- `:minimap` (novo, 250ms): `%{pos: {x, y, z} | nil}` — `read_coord` da faixa do topo.
  Sanidade: z ∈ 0..15, salto de posição > 50 tiles num tick → descarta leitura (mantém
  última boa; gates de staleness existentes cobrem o resto).

### C4 — `Pokex.World`
- `snapshot/0`: UMA struct com o estado de jogo inteiro — `%World.Snapshot{me: %{pokemon_hp,
  level, food, fishing}, inventory: %{f1, f2, e, s_q}, team: [...], enemies: [...],
  pos: {x,y,z}, engaged?: bool, shiny?: bool, captured_at}` — montada dos fatos do
  WorldState com os gates de staleness. É a API que combos, alertas e o futuro cavebot
  consomem; a página **/world** vira o espelho vivo dela.

### C5 — `Pokex.Bots.StockAlerts` (worker sempre-vivo, padrão ShinyGuard)
- Observa `:hud` (assina o tópico world + atacha o feed quando habilitado — ver a lição
  do PR #48: attach cria demanda, PubSub entrega).
- Settings: `stock_alert_f1`, `stock_alert_f2`, `stock_alert_e`, `stock_alert_s_q`
  (limiares; 0 = desligado). Cruzou pra baixo → `{:rule_alarm, "estoque baixo: ..."}`
  UMA vez + badge persistente no painel até repor (re-arma ao subir do limiar).

### C6 — Equipe ↔ /time + Combos v1
- Team v3: membro ganha campo `slot` (2..6, o C+N dele). UI na página /time.
- `Pokex.Combos`: structs de combo — `%Combo{trigger: %{enemy_element: "Water"} | %{enemy_species: "Seadra"},
  steps: [{:swap, slot}, {:skill, "4"}, {:wait, ms}, {:swap_counter}]}` — `:swap_counter`
  escolhe o melhor slot pelo matchup da Pokédex (lógica de `hunt_suggestions` reusada).
- Executor no caminho do Combat.Worker via Body `:high`; roda SÓ com combate engajado;
  InputGate/Focus/pânico valem como sempre; combo abortado se o inimigo morre no meio
  (kill broadcast) ou o pânico latcha.
- V1 de fábrica: o combo do sing — Jigglypuff (slot dela) → skill 4 → espera configurável
  → troca pro counter. Sem detecção de sono nesta leva (espera temporizada).

### C7 — `Body.minimap_step(dx, dy)` (primitivo, cavebot depois)
- Converte offset em tiles → ponto no minimapa (escala do profile) → clique esquerdo via
  Body `:normal`. Feedback de chegada = `:minimap` (a coordenada muda). SÓ o primitivo +
  testes nesta leva.

## Tratamento de erro (transversal)
- Leitura duvidosa → `nil`, nunca chute; consumidores tratam `nil` como "não sei" e
  seguram ações.
- Âncoras perdidas → banner + feeds em espera; re-locate automático.
- Todos os cliques/teclas continuam atrás de InputGate + Focus guard + pânico.

## Testes
- Fixtures REAIS commitadas (`test/fixtures/screen/*.png` — a captura de 2026-07-22 e
  crops). Glyphs: ler "Pidgeot", "5559/6410", "(337, 46107, 4)", "322"/"36"/"7"/"43" das
  fixtures. Layout: locate na fixture cheia acha as 3 âncoras e deriva regiões que batem
  com as medidas. Interpret novo: obs corretas sobre as fixtures. Combos: lógica pura com
  Body fake (padrão Rig.Fake). Nada de rede, nada de captura real em teste.
- Suíte inteira verde em cada fase; cada fase = PR próprio.

## Fora de escopo (explícito)
- Cavebot / caça autônoma (salto seguinte; esta spec entrega os pré-requisitos).
- Monitor 2 / múltiplas resoluções (estrutura pronta, segundo profile depois).
- Detecção de sono/status do inimigo (combo v1 é temporizado).
- Itens/inventário além dos 4 slots de alerta ("não precisa mapear itens por enquanto").
- Pokélog Tracker como fonte (redundante com nossos contadores; fica documentado).

## Fases de implementação
F1 Glyphs+fixtures → F2 Layout/auto-calibração → F3 feeds+snapshot+/world v2 →
F4 alertas de estoque → F5 equipe/slots+combos v1 → F6 primitivo do minimapa.
Plano detalhado: `docs/superpowers/plans/2026-07-22-percepcao-total.md`.
