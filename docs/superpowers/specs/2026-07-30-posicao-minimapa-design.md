# Posição & minimapa: calibração manual + leitura robusta — design

**Data:** 2026-07-30 · **Aprovado por:** Lucas (chat)

## Problema

O bot vive errando a posição do personagem e a leitura da coordenada textual
"(2396, 30621, 5)" — números sobre fundo variável (montanha/grama/mar). O
cavebot depende disso e hoje não funciona direito. Lucas quer calibrar
MANUALMENTE os dois pontos.

## Diagnóstico (o que quebra de verdade)

1. **Onde ler**: `minimap`/`minimap_coord`/`minimap_map` vêm SÓ do layout
   automático (âncora `battle_header` + offset). Janela mudou de lugar → tudo
   desloca — a MESMA classe de drift que pegou o minimapa (y=-132) e o
   minigame hoje. Não há campo manual.
2. **Como ler**: a segmentação já rejeita cor saturada (spread) e já tem
   `drop_background` com banda de texto (testado com chão real 140-159
   transplantado). O piso de tinta da faixa da coordenada é o default 120 e
   não é afinável por fora — um fundo neutro mais claro que 120 dentro da
   banda do texto ainda compete com os dígitos.
3. **O passo do cavebot**: `Body.minimap_step` assume o personagem no CENTRO
   geométrico de `minimap_map`. A cruz real pode não estar ali → viés em todo
   passo. (Lucas confirmou: a cruz é FIXA, o mapa desliza — um ponto calibrado
   resolve.)
4. **Áreas pretas** (não descobertas): o clique do passo não sabe delas.
   Decisão do Lucas: **clicar mesmo assim e só avisar** no journal.

## Decisões do Lucas

- Marcador do personagem: fixo — calibrar UM ponto.
- Área preta no clique do passo: **só avisar** (journal), nunca bloquear.
- Áreas pretas do mapa quase não existem pra ele (mapa quase todo aberto).

## Design

### Calibration (a mão manda; layout = fallback)

Três campos manuais novos (opcionais, round-trip no JSON e nos perfis):

- `minimap_region` — o retângulo do MAPA em si (2 cliques).
- `minimap_player_point` — a cruz do personagem (1 clique).
- `minimap_coord_region` — a faixa do texto da coordenada (2 cliques).

Resolvedores públicos (mesma virada do mini-game em #109):

- `Calibration.minimap_region/1` → manual || `Layout.region(:minimap, fix)`
- `Calibration.minimap_coord_region/1` → manual || `Layout.region(:minimap_coord, fix)`
- `Calibration.minimap_map_region/1` → manual (`minimap_region`) || `Layout.region(:minimap_map, fix)`
- `Calibration.minimap_player_point/1` → manual || centro de `minimap_map_region/1`

### Leitura da coordenada

- Seed novo `minimap_coord_ink: 120` (faixa 40..255): o piso de tinta da
  faixa vira AFINÁVEL. Default = 120 (comportamento atual): MEDIDO na
  implementação, os dígitos têm núcleo 240+ mas o anti-alias espalha por
  160-239 e o atlas foi ensinado com as formas do piso 120 — subir o piso
  emagrece as formas e cega o atlas (165 falhou as 4 capturas reais). O knob
  fica como válvula ao vivo, documentado que mexer nele pede re-ensino de
  glifos.
- `Interpret.Minimap` resolve as regiões via `Calibration` (não mais direto no
  Layout) e lê com `[ink: Settings.get(:minimap_coord_ink)]` mesclado às
  region_opts do layout (a opção explícita vence). O crop relativo usa a
  ORIGEM da `minimap_region` resolvida (o feed captura essa região).
- Feed `:minimap` (perception.ex): `region:` passa a ser
  `Calibration.minimap_region/1`.
- Regressão protegida: `interpret_minimap_test.exs` lê as 4 capturas reais
  pelo caminho novo (layout-fallback E regiões manuais) e prova que o knob
  chega no leitor; `glyphs_minimap_test.exs` (chão transplantado) segue
  intacto.

### Calibração (UI) + validação ao vivo

Seção "Posição & minimapa" em `/calibration`, fluxo do professor de corpos:
📸 fotografar → clique 2× cantos do minimapa → 1× na cruz → 2× na faixa da
coordenada → salvar. Ao salvar (e num botão "Testar leitura"), a página lê a
coordenada DA FOTO com as regiões recém-marcadas e mostra o resultado na hora
("li (2396, 30621, 5) ✓" / "não li — ajuste a faixa"). Overlay das regiões no
"Revisar áreas".

### Passo do cavebot

- `Body.minimap_step`: o ponto de partida vira
  `Calibration.minimap_player_point/1` (não mais o centro de `minimap_map`);
  clamp na `minimap_map_region/1` resolvida continua.
- Aviso do preto (escolha dele): no WORKER do cavebot, após `{:ok, point}`,
  um probe barato (crop 3×3 via Capture no ponto clicado) — se todos os
  pixels são quase-pretos (brilho < 12), journal `🕳️ passo caiu em área não
  descoberta do minimapa` (macro, dedup do journal segura o spam). O clique
  já aconteceu; o probe nunca atrasa nem bloqueia.

## Fatias (merge-as-you-go)

1. **PR 1**: Calibration (campos + resolvedores + round-trip), seed
   `minimap_coord_ink`, Interpret.Minimap + feed usando os resolvedores,
   testes (resolvedores; fixtures reais com piso novo; manual vence layout).
2. **PR 2**: UI da calibração + Testar leitura + overlay no Revisar áreas.
3. **PR 3**: `minimap_step` a partir da cruz + probe do preto no worker.

## Fora de escopo

Entender a imagem do mapa (navegação segue 100% textual), detecção automática
da cruz, cadences de feeds, rotas do cavebot em si.
