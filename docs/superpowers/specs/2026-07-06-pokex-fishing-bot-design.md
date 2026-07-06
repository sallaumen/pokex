# Pokex v0 — Bot de pesca completo (design)

**Data:** 2026-07-06
**Status:** aprovado em brainstorming; aguardando plano de implementação
**Autor:** Lucas Tavano + Claude

## 1. Contexto e objetivo

Lucas joga PokeXGames (Poketibia) no macOS via Wine/CrossOver — o client roda como
janela nativa do macOS. A pesca manual é um ciclo lento e repetitivo:

1. `Shift+Z` equipa a vara;
2. clique esquerdo na água arremessa;
3. quando a água "brilha", `Shift+Z` de novo fisga;
4. o pokémon pescado teleporta para perto do personagem (que fica sempre no
   centro da tela) e entra na janela de **Battle**;
5. clicar na linha dele na Battle list mira; teclas `1`–`0` usam skills do
   pokémon do jogador até matar;
6. botão direito no corpo loota o item;
7. `Shift+1` + clique esquerdo no corpo tenta capturar;
8. repete.

O Pokex automatiza esse ciclo inteiro, controlado por um painel web local
(Phoenix LiveView) que funciona como "overlay" numa janelinha de navegador.
O app é projetado para receber novos botzinhos no futuro (auto-heal, etc.).

**Fora do v0:** overlay flutuante nativo (mini-app Swift com WebView vem
depois), detecção automática de água (sem calibração), inteligência de skills
(prioridade/combos), retry de captura, personagem em movimento, múltiplas
janelas do jogo, leitura de cooldown na hotbar.

## 2. Decisões estruturais

- **App:** `mix phx.new pokex --no-ecto` em `~/projects/pokex`. Sem banco:
  calibração e settings persistem em JSON em `~/.pokex/`.
- **Porta dev:** 4004 (beatgrid usa 4000).
- **Mãos e olhos do v0:** `cliclick` (brew) para mouse/teclado e
  `screencapture` (nativo do macOS) para leitura de tela. Zero código nativo
  próprio. Exige permissões de Acessibilidade e Gravação de Tela para o
  terminal que roda o app.
- **Decodificação de PNG:** `ExPng` (Elixir puro, sem NIF). As capturas de
  polling são regiões pequenas (~100×100 px), então performance é suficiente;
  se a calibração (tela cheia Retina) ficar lenta, é one-off e aceitável.
  Revisitar com Vix/libvips só se doer.
- **Repo privado** no GitHub: automação fere os ToS do jogo; não publicar.

## 3. Arquitetura

```
┌─────────────────────────────────────────────┐
│  PokexWeb (LiveView)                        │  painel, calibração, diagnóstico
├─────────────────────────────────────────────┤
│  Pokex.Bots.Fisher (GenServer)              │  driver da máquina de estados
│  Pokex.Bots.Fisher.Logic (puro)             │  transições + ações, testável
│  Pokex.Vision (puro)                        │  análise de imagens
│  Pokex.Calibration / Pokex.Settings         │  dados persistidos em ~/.pokex/
├─────────────────────────────────────────────┤
│  Pokex.Rig (behaviour)                      │  contrato de mãos/olhos
│    Pokex.Rig.Mac   → cliclick/screencapture │
│    Pokex.Rig.Fake  → testes                 │
└─────────────────────────────────────────────┘
```

Regra de ouro: **só `Rig.Mac` toca o mundo real.** Logic e Vision são funções
puras. Trocar cliclick por um helper Swift no futuro = trocar um módulo.

- **Supervisão:** `Pokex.Bots.Supervisor` supervisiona o `Fisher` (e futuros
  bots como irmãos). Estratégia `:one_for_one`. Após crash/restart o bot
  SEMPRE volta em `:idle` — nunca retoma a pescaria sozinho.
- **UI ao vivo:** `Fisher` faz broadcast de cada mudança de estado/contador via
  `Phoenix.PubSub`; a LiveView assina e atualiza.
- **Ticks:** o `Fisher` se agenda com `Process.send_after` (intervalo por
  estado). A cada tick: coleta observações (Rig + Vision conforme o estado),
  chama `Logic.step(state, obs) -> {state', actions}` e executa as ações via
  Rig. Uma ação por tick mantém o mouse "roubável" pelo usuário entre ticks.

## 4. Contrato do Rig

```elixir
@callback press(key_combo :: String.t()) :: :ok | {:error, term}
@callback click(:left | :right, {x :: int, y :: int}, mods :: [atom]) :: :ok | {:error, term}
@callback capture(region :: {x, y, w, h}) :: {:ok, ExPng.Image.t()} | {:error, term}
@callback cursor_position() :: {:ok, {x, y}} | {:error, term}
@callback focus_game() :: :ok | {:error, term}
```

Implementação `Rig.Mac` (coordenadas sempre em pontos de tela; a conversão
ponto↔pixel Retina vive exclusivamente em `Pokex.Calibration`):

- `press("shift+z")` → `cliclick kd:shift t:z ku:shift`
- `click(:left, {x, y})` → `cliclick c:x,y`; `:right` → `rc:x,y`
- sequência de captura de pokémon → `cliclick kd:shift t:1 c:x,y ku:shift`
- `capture({x, y, w, h})` → `screencapture -x -R x,y,w,h <tmpfile>` + ExPng
- `cursor_position()` → `cliclick p`
- `focus_game()` → clique no **ponto neutro** calibrado (ver §6) + ~150ms.
  Necessário porque teclas do cliclick vão para o app frontmost — se o Lucas
  acabou de apertar Start no navegador, o navegador está na frente.

## 5. Máquina de estados do Fisher

| Estado        | Faz o quê                                                            | Sai quando                                        | Timeout → ação                     |
| ------------- | -------------------------------------------------------------------- | ------------------------------------------------- | ---------------------------------- |
| `idle`        | nada                                                                 | Start no painel (roda preflight antes)            | —                                  |
| `focusing`    | `focus_game()`                                                       | sempre → `equipping`                              | —                                  |
| `equipping`   | `press("shift+z")`, espera ~300ms                                    | sempre → `casting`                                | —                                  |
| `casting`     | clique no ponto de água calibrado                                    | sempre → `watching`                               | —                                  |
| `watching`    | a cada ~200ms captura região do brilho, compara com linhas de base    | brilho detectado → `press("shift+z")` → `assessing` | 30s sem brilho → `casting`         |
| `assessing`   | espera ~1,5s, captura faixa da Battle                                | ícone de pokébola presente → `fighting`; ausente → `equipping` | —                  |
| `fighting`    | 1º tick: clique na 1ª linha da Battle (mira). Depois: cicla skills (`1`,`2`,`3`... configurável) ~1s/tecla; a cada tick rastreia texto vermelho na arena (posição do bicho) | ícone de pokébola sumiu da Battle → `looting` | 90s → conta falha, `equipping` |
| `looting`     | botão direito na última posição do texto vermelho, 1 tile abaixo; sem posição conhecida, tenta em sequência (1 tick cada): ponto da água, depois os 4 tiles vizinhos | sempre → `capturing`      | —                                  |
| `capturing`   | `kd:shift t:1 c:x,y ku:shift` na mesma posição; espera ~2s           | sempre → `equipping` (incrementa contadores)       | —                                  |
| `error`       | parado, mensagem no painel                                           | usuário aperta Start de novo                       | —                                  |

Regras transversais:

- **Stop** no painel leva qualquer estado a `idle` imediatamente.
- **Kill corner (dead-man switch):** antes de executar qualquer ação de mouse/
  teclado, o Fisher lê `cursor_position()`; cursor no canto superior esquerdo
  (região 10×10 px) → auto-stop para `idle`. Lucas joga o mouse no canto e o
  bot morre, sem precisar achar o navegador.
- **Falhas consecutivas:** timeout de luta, loot sem alvo, erro de Rig etc.
  incrementam contador; `max_consecutive_failures` (default 5) → `error`.
  Qualquer ciclo completo com sucesso zera o contador.
- Timings acima são defaults de `Settings`, todos ajustáveis.

## 6. Calibração (wizard LiveView)

Pré-condição do v0: a janela do jogo não pode se mover nem mudar zoom depois
de calibrar (recalibrar se mexer).

Passos do wizard (`/calibration`):

1. App captura a tela inteira e exibe a screenshot no navegador; Lucas marca
   clicando/arrastando **na própria imagem**:
   a. **Ponto da água** (clique) — região do brilho = quadrado automático
      (~64×64 px em pontos) centrado nele, ajustável;
   b. **Faixa da Battle list** (retângulo) — a área das linhas de criaturas,
      incluindo a coluna direita onde aparece o ícone de pokébola;
   c. **Arena** (retângulo) — área em volta do personagem onde o pokémon
      pescado aparece; sugestão automática centrada no centro da tela;
   d. **Ponto neutro** (clique) — lugar seguro para clique de foco; sugestão:
      o tile do próprio personagem (clicar no próprio tile não anda).
2. App captura **linhas de base**:
   - água sem brilho: N frames (~10) ao longo de ~4s, para cobrir o ciclo de
     animação da água;
   - faixa da Battle sem pokémon selvagem presente.
3. Persistência em `~/.pokex/calibration.json` + PNGs de baseline ao lado:

```json
{
  "screen": {"scale": 2, "width": 1728, "height": 1117},
  "water_point": {"x": 812, "y": 402},
  "glow_region": {"x": 780, "y": 370, "w": 64, "h": 64},
  "battle_region": {"x": 1380, "y": 120, "w": 260, "h": 220},
  "arena_region": {"x": 560, "y": 260, "w": 560, "h": 420},
  "neutral_point": {"x": 864, "y": 470},
  "baselines": {"glow": ["glow_0.png", "..."], "battle": "battle_empty.png"}
}
```

Coordenadas em **pontos**; `scale` converte para pixels de imagem capturada.
A conversão vive num único módulo (`Pokex.Calibration`).

## 7. Vision — algoritmos

Tudo função pura sobre `ExPng.Image` + região.

- **Brilho (`glow?/3`):** distância média RGB entre o frame atual e CADA frame
  de baseline; brilho = distância mínima > `glow_threshold`. Usar N baselines
  cobre a animação natural da água (evita falso positivo). O threshold default
  vem com margem sobre a variação natural medida na calibração
  (`1.5 × max(distância entre baselines)`), ajustável no painel. A página de
  diagnóstico mostra o score ao vivo para tunar olhando o jogo.
- **Texto vermelho (`find_hostile/2`):** dentro da arena, pixels com
  `r > 180 and g < 80 and b < 80` (nome de criatura hostil é vermelho puro no
  client); clusteriza por proximidade e retorna o centroide do maior cluster,
  ou `:not_found`. A posição do corpo = centroide deslocado ~1 tile
  (`tile_size` do settings, default 32 pontos) para baixo. Independe da
  espécie do pokémon.
- **Pokébola na Battle (`wild_present?/2`):** na coluna direita da faixa da
  Battle (últimos ~30 px), conta pixels "vermelho de pokébola" adjacentes a
  brancos; presença = contagem > threshold. Baseline vazia da calibração
  valida o zero. Morte/captura = ícone desaparece. (Outros jogadores na Battle
  list não têm o ícone, então não interferem.)

## 8. Segurança e falhas

- Bot nasce e renasce em `idle`; nunca auto-start.
- **Preflight no Start:** cliclick no PATH? permissões OK (faz uma captura
  1×1 e um `cursor_position()` de teste)? calibração existe e o tamanho de
  tela bate com o atual? Falhou → mensagem clara com o passo a passo de
  correção (ex.: `brew install cliclick`, System Settings → Privacy).
- Kill corner + Stop + `max_consecutive_failures` (§5).
- Toda ação do Rig loga em `Logger` com estado + coordenadas, para depurar
  sessão ruim.

## 9. Interface (PokexWeb)

- **`/` painel:** estado atual (com cor), contadores (ciclos, fisgadas, mortes,
  loots, capturas, falhas), botões Start/Stop, threshold do brilho, link para
  calibração e diagnóstico. É a janela que fica pequena no canto.
- **`/calibration`:** wizard do §6.
- **`/diagnostics`:** laboratório manual (a "Fase 0" permanente): botões
  "Shift+Z", "clicar na água", "score do brilho ao vivo", "onde está o texto
  vermelho?", "pokébola presente?", "sequência de captura", preview das
  regiões calibradas. Primeiro marco de implementação e ferramenta de tunagem
  para sempre.

## 10. Testes (TDD)

- **`Fisher.Logic`:** núcleo nasce test-first; transições em tabela
  (estado × observação → novo estado + ações esperadas), incluindo timeouts,
  kill corner e contagem de falhas.
- **`Vision`:** fixtures PNG capturadas do jogo real (coletadas na
  calibração/diagnóstico): água normal vs brilhando, arena com/sem nome
  vermelho, battle com/sem pokébola.
- **`Fisher` GenServer + `Rig.Fake`:** ciclo completo de ponta a ponta
  (pesca → luta → loot → captura) sem tocar o jogo; o Fake registra as ações
  e devolve observações roteirizadas.
- **`Rig.Mac`:** fino de propósito; coberto pelo diagnóstico manual.

## 11. Riscos

| Risco | Mitigação |
| --- | --- |
| Wine/CrossOver ignorar input sintético (CGEvent) | M0 prova isso ANTES de tudo; alternativas (nível HID) só se necessário |
| Animação da água disparar brilho falso | multi-baseline + threshold com margem + tunagem ao vivo no diagnóstico |
| Nome vermelho de outro hostil na arena (raro pescando) | v0 aceita; arena pequena limita; futuro: filtrar por proximidade da água |
| Latência do `screencapture` (~200ms/frame) | irrelevante para pesca; limite conhecido para bots futuros de reflexo |
| Janela do jogo se move / muda resolução | preflight compara tamanho de tela; recalibrar é barato |
| Ban por automação | risco aceito pelo Lucas; repo privado; kill corner para retomar controle |

## 12. Marcos

- **M0 — provar mãos e olhos:** scaffold Phoenix + `Rig.Mac` + `/diagnostics`
  com botões básicos. Critério: Shift+Z equipa a vara no jogo real, clique
  acerta a água, captura lê pixels da janela do jogo. ⭐ risco nº 1 morre aqui
- **M1 — calibração:** wizard completo persistindo `~/.pokex/`.
- **M2 — pesca:** `equipping → casting → watching → assessing` com detecção de
  brilho. Critério: fisga peixes sozinho por 10 min sem intervenção.
- **M3 — combate:** Battle list + ciclo de skills + morte detectada.
- **M4 — loot + captura:** ciclo completo. Critério: 30 min de farm autônomo
  com contadores subindo e zero intervenção. **= v0 pronto**
- **Futuro:** overlay flutuante nativo (Swift + WebView fininho apontando para
  o LiveView), novos bots (auto-heal, anti-idle), skills inteligentes.
