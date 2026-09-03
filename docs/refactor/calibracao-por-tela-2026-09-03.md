# Calibração por tela: caçar numa tela só (03/09/2026)

> "se para eu começar a usar outro monitor com este bot (começando agora a usar 1
> monitor só do notebook) se vai ter problema... já tive problema no passado com
> distâncias na mão feitas no código que mesmo calibrando de novo não resolvia
> (…) ter algo que linke a calibração à resolução da tela (…) ver na UI os
> problemas (…) alerta pra eu não rodar caçada com ela incompleta ou mal
> calibrada (…) selecionar qual calibração eu quero, pra qual tamanho de monitor"

Investigação só de leitura (código, `~/.pokex`, telas ligadas hoje). Nada foi
mudado. O plano no fim é pra outra IA executar, fase a fase, cada uma com PR.

## 1. Resposta curta

**Hoje não é seguro caçar no notebook, e recalibrar sozinho não resolve.** Mas
o bot também não faz besteira: com a calibração do ultrawide em vigor e o jogo
no notebook, o preflight do combate recusa o arranque ("a calibração é de uma
tela 3440×1440 e esta é 1512×982"), o cavebot cai no bloqueio perigoso e para.
Suporte e cérebro continuam rodando sem preflight, lendo regiões que não
existem nessa tela: o alarme de cegueira toca, ninguém aperta nada.

Recalibrando tudo no notebook, as MARCAS ficam certas e a régua (`ScreenScale`)
corrige 21 números. O que fica errado é o que ele lembra de 06/08 ("calibrei e
não resolveu"): seis famílias de leitura carregam pixel do ultrawide fora de
qualquer calibração ou régua (seção 3). A pior delas hoje é nova: o portão da
barra de skills do #502 mede o rótulo da tecla em pixels fixos, e no notebook o
rótulo é menor que o mínimo. Resultado previsível: "barra ilegível" o tempo
todo, revive nunca confirmado, exatamente o que ele viu em 02/09 por outro
motivo.

## 2. O que já existe (não reinventar)

As telas dele hoje: ultrawide 3440×1440 a 1× (principal) e o Liquid Retina do
MacBook, 3024×1964 pixels = **1512×982 pontos**.

| Peça | Onde | O que faz |
|---|---|---|
| `screen_w/screen_h/scale` na calibração | `lib/pokex/calibration.ex:10-13` | toda marca carrega a tela em que foi feita |
| Foto por tela | `calibration.ex:375-409` | cada save grava `~/.pokex/calibrations/auto-WxH.json` + sidecar `.settings.json` com os 21 números da régua |
| Perfis nomeados | `calibration.ex:301-333` | "2-moni-8skill-esq", "1-moni-esq-bx"… |
| `screen_check/2` | `calibration.ex:556-569` | `:same` / `{:rescalable}` (mesma forma, régua errada) / `{:another_screen}` |
| Preflight de tela | `lib/pokex/preflight.ex:96-131` | só no rig Mac, só por fishing/combat; o cavebot herda pelo `run_combat` (`cavebot/worker.ex:646-661`) |
| Régua | `lib/pokex/screen_scale.ex` | mede `largura da barra / slots` contra 35,25 pt; propõe 14 lineares + 7 de área |
| Página | `calibration_live.ex:150-175, 458-479, 560-580` | reabre no que está salvo para ESTA tela; "Usar a última calibração desta tela"; "Corrigir a escala" |
| Alerta dos números | `calibration_review.ex:154-200` | "N números são de outra tela → Corrigir os N" |
| Captura | `priv/native/screen_capture_kit.swift:330-357` | filma o display PRINCIPAL (`CGMainDisplayID`), 1 pixel por ponto (no Retina reamostra o 2×) |

A captura numa tela só é o caso bom: o principal É o notebook. Com duas telas e
o jogo na secundária, filma a errada (limitação já documentada em
`screen_capture_kit.ex:90-93`).

## 3. O que quebra numa tela diferente mesmo recalibrando

Ranqueado pelo estrago na caçada. Cada item diz onde e o que fazer.

1. **Atlas de glifos** (`priv/glyphs/atlas.json`, `~/.pokex/glyphs_learned.json`,
   `lib/pokex/vision/glyphs.ex:685-692`). Bitmap exato por altura, tolerância
   0,12. Lê a coordenada do minimapa, os nomes da lista de batalha e o painel
   do time. Numa altura de fonte diferente não há candidato: o cavebot fica sem
   coordenada e não anda. O aprendido é UM arquivo global, sem carimbo de tela
   (`glyphs.ex:433`). O ensino existe (/calibration e /diagnostics), mas ninguém
   diz "nesta tela faltam estes dígitos".
2. **Portão da barra de skills (#502)** `lib/pokex/vision/skill_digits.ex:143-150`:
   largura 2..10, altura 5..11, ≥ 8 px brancos, escalados por `frame.scale`, que
   é 1,0 em qualquer tela com o SCK. A régua do HUD no notebook foi medida em
   0,76 no cliente antigo: um rótulo de 5-6 px vira 4 e cai fora do mínimo.
   Trocar `frame.scale` pela régua do slot (`largura da região / slots ÷ 35,25`).
3. **Quatro números de pixel fora da régua** (`settings.ex:50-58`):
   `pokemon_sprite_box_px`, `pokemon_track_radius_px`, `pokemon_track_step_px`,
   `pokemon_park_tolerance_px`. Parecem calibrados no /config e não se movem.
   Também fora: `battle_first_row_y` (`settings.ex:180`) e
   `mini_game_anchor_tolerance` (`:228`).
4. **Constantes soltas em pixel:** `@strip_width 30` e `@first_row_y_offset 18`
   (`calibration.ex:63-64`); `@row_pitch 67` do painel do time
   (`perception/interpret/team.ex:23`, erro acumula por linha); faixas de
   tamanho dos rótulos de nome `22/150/6/20` (`vision/name_labels.ex:86-89`,
   chamadores em `area_probe.ex:183` e `crowd_scan.ex:91` não passam nada) e
   dos números de dano (`damage_numbers.ex:46-49`); `@gap 6` de `vision/ink.ex:30`;
   grade `div(x, 16)` de `vision.ex:78,85`; margens do minimapa 28/32/28 em
   `bots/body.ex:196-198` (errar aqui clica nos controles do mapa);
   `@default_pokemon_hp_region {46,1105,121,13}` (`calibration.ex:602`) usado
   quando a Pokebar não foi marcada.
5. **O perfil do notebook que existe é de outro jogo.** `auto-1512x982.json` é de
   07/08: cliente PXG, 9 slots, sem minimapa, sem vida do personagem. "Usar a
   última calibração desta tela" (`calibration_live.ex:462-479`) restaura isso
   sem avisar e diz "restaurada". Armadilha certa no primeiro dia.
6. **Reamostragem Retina.** O SCK entrega 1 px por ponto (média do 2×). Leitores
   de cor e proporção (vida, cooldown por brilho) não ligam; leitores de forma
   exata (atlas, rótulos) precisam ser ensinados NESSA tela. Se o Wine sobe o
   jogo em 1512×982 e o macOS dobra, a média devolve o pixel original; se
   interpola, borra. Só medindo (fase 0).

Fora de risco: tudo que é em TILES (`Calibration.tile_px()` em
`crowd_scan`, `sweep`, `spot_scan`, `area_probe`), vida em %, cores, o mouse
(cliclick em pontos), as teclas (nativo). O `Pokex.Layout` (auto-layout do
ultrawide) recusa outra resolução com erro honesto (`layout.ex:131-134`) e a
calibração à mão vence ele em tudo.

## 4. O desenho (brief)

**Trabalho e público.** Ele, sozinho, trocando de mesa: precisa saber ANTES de
apertar Iniciar se a calibração desta tela está completa e lendo, e trocar de
tela sem refazer nove cliques. Modo: operar.

**Conceito: a tela é a chave.** Um cartão **Tela** no topo do /calibration e
repetido no Painel e na Central, sempre com três linhas:

- **Tela atual**, medida ao vivo: `1512×982 · notebook · Retina 1×` (nome vem do
  `system_profiler`/`NSScreen`, com fallback pro tamanho).
- **Calibração em vigor**: de qual tela é, quando foi salva, em qual cliente.
- **Veredito** em uma cor: ✓ *lendo* (prova passou) · ⚠ *incompleta* (falta
  região X ou prova falhou em Y) · ✗ *de outra tela*. O veredito tem o botão que
  conserta ao lado ("Provar de novo", "Marcar a faixa", "Usar o perfil desta
  tela").

**Prova de leitura por região.** Não basta a marca existir; a região tem que
LER. Um verificador puro por região, rodado sobre uma foto fresca:

| Região | Prova |
|---|---|
| lista de batalha | ≥ 1 linha segmentada, nome legível OU "sem bicho" explícito |
| barra de skills | portão de rótulos 2/3 (o do #502) + refs por slot |
| vida do pokémon / do personagem | trilho reconhecido, % entre 0 e 100 |
| minimapa + faixa | a faixa lê "(x, y, z)" numa foto andando (já existe `CoordBandSearch`) |
| ponto do personagem, neutro, escada | dentro da tela |
| glifos | cobertura nesta tela: dígitos 0-9 e `( , )` na altura medida |

O resultado vai pro arquivo da calibração (`proof: %{region => {ok | fail,
at, resumo}}`) e pro cartão. O preflight passa a exigir prova recente (ou
re-prova no Start: uma foto por feed, ~1 s) e a exigir por MODO: cavebot precisa
de minimapa, faixa, ponto do personagem, as duas vidas e a barra; parado precisa
de água e brilho. A recusa nomeia a região e o botão.

**Perfil por tela = tudo que muda com a tela.** Calibração + 21 números da
régua + glifos aprendidos nela + cliente/jogo + data + prova. A lista de perfis
mostra isso por linha, com o veredito. Restaurar um perfil sem prova ou de outro
cliente pede confirmação com o motivo ("este perfil é de 07/08, cliente
antigo, sem minimapa"). "Tela alvo" vira uma escolha explícita no cartão (a
atual vem marcada), não uma dedução silenciosa.

**Régua completa.** Toda constante de pixel que hoje mora num módulo passa a
derivar do slot (a régua) ou vira setting na lista da régua. O portão #502 é o
primeiro.

**O que não muda.** Os nove passos do wizard, a régua do slot como medida (não
o display), "uma calibração por monitor, sem multiplicar marcas" (decisão dele
de 07/08), o design system (`pk-*`, cores de veredito ok/warn/danger já
existem).

## 5. Plano por fases (uma PR cada)

### Fase 0: medir no notebook (ele, 10 minutos, sem código)

1. Jogo em tela cheia no notebook, macOS na escala padrão (1512×982).
2. /calibration → Capturar tela → wizard completo → salvar perfil `notebook-pa`.
3. No Painel, "Ler" em cada região; anotar: largura da barra e slots (a régua),
   altura da fonte da faixa (`px` do `read_coord`), se o portão da barra passa
   (`feed_skill_bar.raw` na diagnose), % das duas vidas.
4. Mandar esses quatro números. Sem eles a fase 2 é chute.

### Fase 1: prova de leitura + cartão Tela + preflight por modo

- `lib/pokex/calibration/proof.ex` (novo): `run(calib, photos) :: %{region => result}`,
  puro; cada verificador reaproveita o interpretador do feed
  (`perception/interpret/*`) em vez de reler à sua maneira.
- `lib/pokex/calibration.ex`: campo `proof` + `client` + `saved_at`; `save/2`
  carimba; `from_map` tolera arquivo sem eles.
- `lib/pokex/preflight.ex`: `check_regions(mode)` e `check_proof/1`; mensagens
  nomeiam região e botão; `Pokex.Modes.workers/1` já diz o modo.
- `bot_supervisor.ex:236-249`: suporte e cérebro continuam sem preflight, mas
  publicam `:calibration_proof` no `WorldState` para o cartão.
- UI: `PokexWeb.ScreenCard` (componente), montado em `calibration_live`,
  `panel_live` (perto do banner "calibração mudou", `:2701`) e `cavebot_live`.
- Testes: `calibration_proof_test.exs` com as fixtures reais que já existem
  (`test/fixtures/skill_bar/*.raw`, `test/fixtures/hp/*.raw`); `preflight_test`
  por modo com rig Fake; LiveView do cartão nos três estados.

### Fase 2: régua completa

- `screen_scale.ex`: entram `pokemon_sprite_box_px`, `pokemon_track_radius_px`,
  `pokemon_track_step_px`, `pokemon_park_tolerance_px`, `battle_first_row_y`,
  `mini_game_anchor_tolerance` (lineares).
- `skill_digits.ex:143-150`: tamanhos por `slot_pt / 35,25`, recebendo a régua
  do chamador (`SkillBar.read/1` já tem região e contagem). Fixture do notebook
  (fase 0) vira teste.
- Constantes → derivadas: `@strip_width`, `@first_row_y_offset`, `@row_pitch`,
  faixas de `name_labels`/`damage_numbers`, `ink @gap`, grade `div 16`, margens
  do `body.ex`, `@default_pokemon_hp_region` (passa a nil: sem marca, sem
  leitura, e a prova acusa).
- Teste de cerca: `screen_scale_test` varre `Settings.defaults()` por chaves
  `_px|_pt|_pixels|_y|_x` fora das listas e falha nomeando a chave.

### Fase 3: perfil por tela com carimbo e escolha explícita

- `calibration.ex:375-409`: a foto por tela leva junto `client`, `saved_at`,
  `proof` e a lista de glifos aprendidos nela; `restore_last_for_screen/1`
  devolve `{:ok, calib, warnings}`.
- `calibration_live.ex:462-479`: restaurar perfil sem prova ou de outro cliente
  pede confirmação com o motivo; o `auto-1512x982.json` de 07/08 é o caso de
  teste.
- Cartão Tela ganha o seletor "Tela alvo" e a lista de perfis com veredito.

### Fase 4: glifos por tela

- `glyphs.ex:427-448`: aprendido carimbado com `{screen_w, screen_h, altura}`;
  índice continua por `{linhas, largura}` (alturas diferentes convivem).
- Cobertura por tela no cartão ("dígitos lidos nesta tela: 7/13") com o ensino
  que já existe (`calibration_live.ex:1678`, `diagnostics_live.ex:174`).

## 6. Suposições e perguntas

- Suposto: o jogo roda em tela cheia no notebook e o macOS fica na escala
  padrão. Se ele usar "mais espaço", a tela vira outra (1800×1169) e ganha perfil
  próprio; o desenho aguenta.
- Suposto: a régua do cliente novo no notebook fica perto de 0,7 como o antigo
  (0,76). A fase 0 confirma.
- Pergunta: perfis com nome dele ("notebook-pa") ou só automáticos por tamanho?
  O desenho mostra os dois; o nome ajuda quando a mesma tela tem dois layouts
  de janela.
