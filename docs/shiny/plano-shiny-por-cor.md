# Plano: o shiny pela COR de referência (Poké Alliance)

> **O SHINY É O "CHEFE"** (Lucas, 01/09): "o shiny É o chefe — foi assim que eu usei
> pra falar antes, mas nesse jogo o que tô chamando de chefe são os shinies". Uma
> criatura só: recolor, vida e ataque muito maiores, pede o combo skills → stun →
> revive, e é o troféu da noite. Onde este documento diz "chefe", leia "shiny" —
> e o código tem UM conceito (`especial?`), não dois.

> Pedido do Lucas (01/09/2026): "pra identificar o chefe, temos que usar uma COR de referência…
> os chefes geralmente têm esse detalhe da cor diferente. (…) tem 1 shiny, 1 com a base diferente
> (…) tínhamos que mapear essa cor especial e apitar quando ela aparecer na tela (…) o padrão
> antigo usava um detalhe no campo de battle que não existe agora no Poké Alliance. (…) às vezes
> a variação é em detalhes pequenos — tem que ser algo sensível. Pode re-fazer tudo de shiny,
> inclusive apagar as fotos atuais de corpos mortos com shiny."

Este documento é o plano de implementação. Quem for implementar: leia a seção
"Armadilhas que já custaram noites" ANTES de escrever qualquer linha.

> **ESTADO (01/09):** fases 1, 3 e o painel de ensino IMPLEMENTADOS.
> #465 `Vision.ColorMark` + `Vision.ColorRules`; #467 o `ShinyGuard` re-feito
> por COR (estrela, `shiny_action`, `shiny_star_min_columns`,
> `shiny_confirm_ms` e o escape REMOVIDOS — avistar é registrar); e o painel
> de ensino na calibração (§3.4): conta-gotas (`ColorMark.dominant/3`, o
> patch vota e a mediana decide), leitura ao vivo sobre a foto, **prova de
> ruído** em 12 fotos do chão que sobe o gatilho pra 3× o pico (e NUNCA abaixa
> o que ele escolheu à mão), badge provada/sem-prova, liga-desliga e apagar.
> Corpos pintados: o corpses.json dele não tinha amostras `painted` — no-op.
>
> **O QUE FALTA:** o protocolo shiny completo (§8) — alvo preferido, corpo do
> shiny real ensinado na primeira morte, "cor → qual linha da battle list".
> O **chefe-por-cor JÁ ALIMENTA `heavy?`**: o `ShinyGuard` publica o fato
> `:special` a cada varredura e o cérebro o lê (fato velho = chefe nenhum).
> Medido na bancada (6 sementes × 3 min, mesmo mundo com e sem a regra de
> cor): pior momento 5% → 27%, mediana 15% → 34%, o triplo de chefes mortos.
> E o que só ELE pode fazer: ensinar a primeira regra com o Electrode shiny na
> tela, medir o chão com o Torterra em campo, e LIGAR a guarda no painel.

## 1. Por que refazer

O detector atual (`Pokex.Bots.ShinyGuard`, lib/pokex/bots/shiny_guard.ex) dispara pela
**estrelinha dourada** que o PokeTibia/PXG pinta na battle list antes do nome
(`shiny_star_min_columns` — colunas douradas densas na linha). **O Poké Alliance não pinta
estrela nenhuma.** O gatilho está morto desde a migração (memória `poke-alliance-migracao`).

No PA, o que separa shiny/chefe do comum é a **paleta**: mesmo sprite, cor trocada — o
Electrode shiny é verde onde o comum é vermelho; chefes têm detalhe de cor (cabelo, corpo).
E o sprite aparece em QUALQUER pose (o Electrode de ponta-cabeça usando rollout), então
casar sprite inteiro (histograma por crop ensinado, como o acervo de corpos) exigiria uma
amostra por pose. **Presença de COR é invariante à pose e sensível a detalhe pequeno** —
é o caminho.

## 2. O que já existe (inventário, com file:line)

**Fica e serve de precedente:**
- `Pokex.Vision.Frame` — crops RGBA cru (a captura é RAW, nunca .png: decode de PNG já
  custou 22s/frame — memória `captura-raw-nao-png`).
- `Pokex.Vision.SpriteLibrary` (lib/pokex/vision/sprite_library.ex) — acervo ensinado
  genérico, histograma 512 cubos, amostras por nome, cache por mtime+size do JSON.
  **Não é o motor deste plano** (é por crop/pose), mas é o padrão de UX de ensino e de
  storage a imitar.
- `Pokex.Bots.Catcher.SpotScan` (lib/pokex/bots/catcher/spot_scan.ex) — varredura densa
  num quadrado `(2r+1)` tiles ao redor do personagem, com `forbidden_zones` (zonas
  proibidas) e duas fases (grossa + fina). O **quadrado ao redor do personagem** e as
  **zonas proibidas** são reutilizáveis aqui.
- `Pokex.Bots.PokemonTracker` (lib/pokex/bots/pokemon_tracker.ex:56) + `Vision.Finder` —
  rastreiam ONDE o próprio pokémon está. **Essencial** (ver armadilha nº 1).
- Detectores por contagem de pixel já em produção: `wild_min_red_pixels`,
  `pokeball_min_red_px`, `fishing_lure_min_pixels`, glow (`glow_threshold`) — o projeto
  já sabe medir "quantos pixels desta cor tem aqui".
- `Pokex.Vision.Recolor` (lib/pokex/vision/recolor.ex) — pintar corpo pra ensinar shiny
  nunca morto. FICA (é ferramenta genérica do ensino de corpos, usada em
  calibration_live.ex:1917), mas as amostras `painted: true` de shiny saem (ver §7).
- Esqueleto do `ShinyGuard` — attach/poll, janela de confirmação (`shiny_confirm_ms`),
  refratário 60s, `Pokex.Pokedex.ShinyLog` (troféu), medidor vivo no painel
  (`@reading_topic "shiny"`). O esqueleto FICA; o gatilho muda — e as AÇÕES morrem
  (decisão dele, 01/09): `alarm` e `escape` saem por inteiro.

**Morre:**
- O detector de estrela inteiro (dentro de shiny_guard.ex) e `shiny_star_min_columns`
  (settings.ex:516 + row no /config).
- **As ações `alarm` e `escape` do ShinyGuard, por inteiro** (decisão dele, 01/09):
  `shiny_action` (settings.ex:519 + range :1700 + row no /config), a integração com
  `BotSupervisor.emergency_escape/1` (`escape_fun`), a categoria de alarme de shiny em
  alarm_categories.ex e os testes das duas ações. Avistar = REGISTRAR (ShinyLog +
  diário + medidor do painel), nada mais — a reação vira responsabilidade do protocolo
  shiny da fase 2 (§8).
- Amostras de corpo shiny pintadas (`painted: true` em `~/.pokex/corpses.json`) — com
  backup antes (regra da casa: nunca escrever em ~/.pokex com o servidor dele vivo sem
  backup — memória `configs-nunca-mais-perdidas`).

## 3. Desenho proposto

### 3.1 O motor: `Pokex.Vision.ColorMark` (novo)

Uma REGRA DE COR (não um sprite): "existe mancha desta cor nesta região?"

```
regra = %{
  slug, name,                # "electrode-shiny"
  kind: :shiny | :chefe,     # muda o alarme e a ação futura
  colors: [%{rgb: {r,g,b}, tol_h: 12, tol_sv: 30}, ...],  # 1..3 tons por regra
  min_px: 25,                # sensibilidade (ver §5 — NUNCA chutar)
  min_cell_px: 6,            # densidade mínima por célula (anti-ruído espalhado)
  enabled: true, taught_at, note
}
```

- **Espaço de cor: HSV, matiz no centro.** O shading do sprite varia brilho/saturação
  (o verde da barriga vs o verde sombreado), mas o MATIZ segura. Tolerância apertada em
  H, folgada em S/V. `Recolor` já converte RGB↔HSV — extrair os helpers para uso comum
  em vez de duplicar.
- **Contagem por células** (precedente: `corpse_cell_px`): uma passada O(n) no frame
  soma pixels casados por célula de ~8px; mancha = células vizinhas acima de
  `min_cell_px`. Isso separa "detalhe de 25px concentrado no cabelo" de "25px de ruído
  espalhados pela grama" — é o que torna sensível SEM ser nervoso.
- Resposta: `%{px_total, manchas: [%{point, px, cells}], melhor}` — o `point` serve
  pro futuro (mira, tracking) e pro painel desenhar onde apitou.
- Puro e sem processo, como SpriteLibrary: recebe `Frame`, devolve mapa. Testável com
  fixtures (ver §6).

### 3.2 Storage: `~/.pokex/special_colors.json`

Arquivo próprio, pequeno, mesma disciplina do SpriteLibrary (cache por mtime+size,
escrita atômica). NÃO misturar com corpses.json — regra de cor não é crop.

### 3.3 O vigia: `ShinyGuard` re-feito por dentro

Mantém: GenServer sempre-vivo, liga/desliga por setting, janela de confirmação (2
quadros: um vislumbre de 1 frame não registra), refratário, ShinyLog, medidor vivo pro
painel. SEM ações: nem alarme, nem escape — avistou, registra e segue.

Muda o gatilho:
- **Região:** o mesmo quadrado `(2r+1)` tiles ao redor do personagem do SpotScan
  (`SpotScan.region/1` — extrair/partilhar), NUNCA a arena inteira (custo + HUD).
- **Cadência:** própria (`special_color_scan_ms`, ~500ms), captura sob demanda via
  `Capture.frame/2` como o SpotScan — não pendurar no feed de batalha (que é outra
  região) nem manter feed de arena vivo à toa.
- **Zonas proibidas:** HUD (as do SpotScan) **+ a caixa do PRÓPRIO pokémon** vinda do
  `PokemonTracker` (armadilha nº 1). Sem tracker fresco → usar o ponto calibrado do
  pokémon + 1 tile de folga.
- Avistou (regra × mancha): loga `"🌟 {name}: {px}px em {point}"` no diário + entrada
  no ShinyLog + medidor do painel. NADA de ação (alarme e escape deletados). `kind:
  :chefe` → mesmo tratamento; a ligação com `heavy?`/postura de chefe (#461) é fase
  futura explícita (§8).

### 3.4 O painel: calibração → seção "Cores especiais"

Seguir o padrão das seções existentes de calibration_live (um tool aberto por vez,
crop ajustável sobre o MESMO screenshot — calibration_live.ex:379):

1. **Capturar** o quadro atual (personagem perto do bicho especial).
2. **Conta-gotas:** clique na mancha → amostra um patch 5×5, extrai o(s) tom(s)
   dominante(s), mostra o swatch. Cliques extras adicionam tons à mesma regra (shiny
   com 2 cores).
3. **Nome + tipo** (shiny/chefe) + salvar.
4. **Prova ao vivo:** com a regra selecionada, o painel roda o ColorMark no quadro
   capturado E num stream curto ao vivo, mostrando px_total/manchas em tempo real —
   ajuste de tolerância/min_px COM régua, não no escuro.
5. **Prova do RUÍDO (obrigatória antes de armar):** botão "medir o chão" — varre X
   segundos de caçada normal SEM o especial na tela (e as capturas guardadas em
   `~/.pokex/captures/arena-*.png` como corpus extra) e mostra o pico de px casados.
   O painel SUGERE `min_px = 3× o pico do chão` e marca a regra como "provada".
   Regra não provada não entra no vigia (só na prova do painel).
6. Lista de regras: enable/disable, apagar, re-ensinar, swatch + última prova.

### 3.5 Settings novas (com @ranges e rows no /config)

- `special_color_scan_ms` (500, 200..2000)
- `special_color_confirm_frames` (2, 1..5)
- `shiny_always_ball` FICA.
- Morrem: `shiny_star_min_columns` e `shiny_action` (com as duas ações).

## 4. Por que cor-presença e não sprite-histograma (registrado)

- Pose: o Electrode rola de ponta-cabeça — crop ensinado não casa; matiz casa.
- Detalhe pequeno: "às vezes a variação é em detalhes pequenos" — histograma de crop
  inteiro dilui 25px de cabelo diferente; contagem direta da cor não dilui.
- Custo: uma passada O(n) por célula vs sliding-window com score por janela.
- O que se perde: cor não diz QUEM é (não separa dois verdes iguais de espécies
  diferentes) — aceitável: o alarme diz "verde especial na tela", o Lucas olha. A
  identidade fina fica pra fase 2 (corpo morto re-ensinado do shiny REAL, que aí é
  crop e o acervo atual já resolve).

## 5. Medição PRIMEIRO (o método da casa — inegociável)

Antes de fixar qualquer tolerância/min_px default:

1. Montar corpus: ~20 capturas de caçada normal (várias dungeons dele, com o Torterra
   em campo!) + os arena-*.png guardados + 2-3 quadros com o Electrode shiny na tela
   (ele caça isso agora — pedir os quadros ou capturar numa sessão dele).
2. Medir: px casados do verde-shiny em cada quadro normal (o CHÃO) vs nos quadros com
   shiny (o SINAL). Escolher tol/min_px onde chão = 0 com margem ≥3× e sinal dispara
   em 100% dos quadros com shiny.
3. Registrar os números no PR (como a régua do grit em #461: "máximo do chão 4, zero
   falsos" — número medido, não opinião).

Se o verde do Torterra invadir o cone do verde-shiny mesmo com exclusão do tracker
(pilha EM CIMA do pokémon acontece — vide a print dele), a resposta é apertar tol_h e
re-medir, nunca alargar a zona proibida até cegar o detector.

## 6. Testes

- **ColorMark unitário:** frames sintéticos (mancha concentrada vs mesmo total
  espalhado; dois tons; matiz vizinho fora do cone; célula na borda) + 1 fixture real
  (crop pequeno de arena com o shiny, `.raw` como test/support/fixtures/minimap_real.raw).
- **Guard:** confirmação de 2 quadros (1 quadro não registra), refratário, zona
  proibida do próprio pokémon (frame com verde SÓ dentro da caixa do tracker →
  silêncio), e avistamento NÃO dispara ação nenhuma (só ShinyLog + broadcast).
- **Painel:** prova de ruído sugere min_px = 3× pico; regra não provada fica fora do
  vigia.
- Suíte com `--max-cases 6`; visão em TESTE, nunca `mix run` (memória
  `mix-run-mata-o-helper`).

## 7. Limpeza autorizada (com backup)

1. `cp ~/.pokex/corpses.json ~/.pokex/corpses.json.bak-antes-shiny-cor-<data>` e
   remover as amostras `painted: true` (são os stand-ins de shiny do PXG).
2. Remover detector de estrela + setting + row do /config + testes dele.
3. `shiny_log.json` está vazio — fica (o formato continua servindo).
4. `Recolor` fica (uso genérico no ensino de corpos).

## 8. Fases futuras (fora deste plano, anotadas de propósito)

- **Protocolo shiny completo** ("matar e capturar um shiny… hoje nem um dos 2 fazemos
  direito"). JÁ FEITO deste item: o shiny na tela **vale a luta** mesmo sozinho
  (`worth_fighting?`) e a caçada **não recua** dele (a R7 não kita com shiny na
  tela) — sem virar postura de chefe, que ele não é. Falta: prioridade de ALVO
  (qual linha da battle list é o shiny — a cor não diz a linha), bola garantida
  (`shiny_always_ball` já existe), corpo do shiny ensinado do REAL na primeira morte
  (aí o acervo de corpos assume a mira). Precisa resolver "cor → qual linha da battle
  list" (a cor não diz a linha; caminho provável: Finder rastreando a mancha + posição).
- ~~**Chefe por cor → `heavy?`**~~ — FEITO: a regra `kind: "chefe"` vira o fato
  `:special` (publicado a cada varredura do vigia, lido pelo cérebro com prazo de
  três varreduras) e entra no `heavy?` ao lado do nome e do grit. É o único canal
  que enxerga ANTES da luta abrir, e por isso fecha os dois buracos nomeados no
  #461 (chefe solitário abaixo da régua, e o mordedor que a mobada arrasta).
  O que ele NÃO fecha, medido: o tombo do PRIMEIRO bolo (~40s, ninho de comuns
  com a barra gasta) — por isso o cenário 🎨 promete `nao_cai`+`mata` e não
  `aguenta`. O sinal da MORDIDA continua na fila pra esse pedaço.

## 9. Armadilhas que já custaram noites (ler antes de codar)

1. **O PRÓPRIO Torterra é verde quase igual ao Electrode shiny** (print de 01/09).
   Sem a zona proibida do tracker + prova de ruído COM o Torterra em campo, o
   detector apita a caçada inteira e morre de descrédito no primeiro dia.
2. Captura em RAW, sem extensão .png no nome (22s de decode já medidos — memória
   `captura-raw-nao-png`; há teste que varre lib/ atrás disso).
3. Nunca rodar/compilar em ~/projects/pokex (servidor vivo dele); worktree próprio;
   nunca `preview_start {name}` de worktree (memórias `pokex-workspace-rules`,
   `preview-start-servidor-errado`).
4. Escrever em ~/.pokex só com backup ao lado (memória `configs-nunca-mais-perdidas`).
5. Tile do PA = 151px (memória `poke-alliance-migracao`) — dimensionar células e
   quadrado por `tile_px`, nunca por constante.
6. Limiar sem medição de chão é opinião — o método que salvou o grit (#461), o
   blackout (#456) e a estrela original (#? — "15+ na janela, 0 fora") é o mesmo:
   medir o chão, margem 3×, registrar números no PR.
7. Restauração de sanidade de teste por PATCH guardado, nunca `git checkout <arquivo>`
   com trabalho não commitado (lição de 29/08).
