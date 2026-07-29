# Fase 0 — Inventário e baseline

> **DOCUMENTO HISTÓRICO (marcado em 2026-07-29).** Retrata a main de 2026-07-20
> (`9a69b44`, 484 testes) — antes de percepção por feeds/blackboard, modos,
> personagens, cavebot e logout. Não parta daqui: o retrato atual e a direção
> estão em [plano-consolidacao-2026-07-29.md](plano-consolidacao-2026-07-29.md),
> e os donos de cada decisão em [donos-e-contratos.md](donos-e-contratos.md).


> Executada em 2026-07-20 sobre `main` @ `9a69b44` (pós PR #14).
> Baseline de testes: **484 testes, 0 falhas** (53 arquivos, `mix test`).
> Roteiro: [handoff-kizubot.md](handoff-kizubot.md), Prompt 0. Sem implementação, sem arquitetura-alvo.

## 1. Componentes atuais e responsabilidades

**Núcleo de atuação e segurança** (`lib/pokex/bots/`, `lib/pokex/rig/`)

| Módulo | Responsabilidade |
|---|---|
| `Bots.Body` | Serializa TODO input compartilhado em sequências atômicas com prioridades `:critical` / `:high` / `:normal`; aplica o gate do mini-game em inputs guardados (`:critical` passa — combo de sobrevivência). O Body nunca humaniza — delays vêm do chamador. |
| `Bots.InputGate` | Veto final de atuação: jogo frontmost + sem panic (+ `pause_when_unfocused`). |
| `Bots.Guardian` | Panic pelo canto da tela (poll do cursor); derruba tudo, inclusive revive/poção. |
| `Bots.Focus` / `Bots.Corner` | Frontmost do jogo (os scripts nativos de tecla re-frontam por conta própria); geometria do canto de panic. |
| `Rig` (+ `Rig.Mac`, `Rig.Fake`) | Abstração de SO: teclas/cliques via helper nativo `key_events` (Swift, inclui `middle_click`), `Commands`, `OsaBus`; `Fake` scriptável nos testes. |
| `Bots.Capture` (+ `Capture.ScreenCaptureKit`) | Broker único de screenshot: frames por região e tela cheia SEMPRE no display do jogo (metadata do SCK; CLI `screencapture` só como fallback sem-SCK). |
| `Vision` / `Vision.Frame` | Análise pura de pixels: glow, linhas de batalha, slots de skill, downsample/matriz. |
| `Bots.SkillBar` | Leitura pura da hotbar (prontidão por slot); cada consumidor faz o próprio one-shot. |
| `Bots.Perf` | Agregador leve de timings dos hot paths (resumos periódicos no log). |

**Percepção compartilhada** (`lib/pokex/perception/`)

| Módulo | Responsabilidade |
|---|---|
| `Perception` | Fachada: `feed_specs/0` + attach/detach, e leituras de fatos (`mini_game_playing?`, `mini_game_gate` lock-free, `pokemon`, `ready_skills`). |
| `Perception.WorldState` | Blackboard ETS `:pokex_world` com freshness (max-age por fato, fail-open documentado por consumidor); `put/forget`. |
| `Perception.Feed` | Um stream por região: captura na cadência, interpreta puro, grava no WorldState, broadcast PubSub `"world"` só em MUDANÇA. Demand-driven (para sem consumidores; monitora quem atachou). Feeds hoje: `:battle`, `:arena`, `:skill_bar`, `:corpses`. |
| `Perception.Interpret` (+ `.Corpses`) | Interpretadores puros frame → observação, um por feed. |

Fatos publicados por workers (fora dos feeds): `:mini_game` (worker do mini-game, todo tick), `:pokemon` (PlayerSupport), `:calibration` (BotSupervisor carimba o mtime carregado no start; esquece no stop).

**Capacidades (worker + lógica pura)** — todos sob `Bots.BotSupervisor` (`start_all/stop_all`)

| Capacidade | Módulos | Nota |
|---|---|---|
| Pesca | `Fishing.Worker` + `Fishing.Logic` + `Fisher.{Config,Sensors,Skills}` | Sensores ainda na árvore legada `fisher/` (ver §7.1). |
| Combate | `Combat.Worker` + `Combat.Logic` | Tab targeting; só dispara skills PRONTAS (fato `:skill_bar`). |
| Captura/loot | `Catcher.Worker` + `Catcher.Logic` | Baseline+diff do chão; loot (Espaço) e bola com toggles próprios (`loot_enabled`, `capture_enabled`); modos `player_mode` parado/movimento. |
| Mini-game | `MiniGame.{Worker,Detector,Player,Pilot,Track}` | Detector 3 passadas (âncora/varredura/cápsula); `Pilot` puro validado no lab; publica o fato `:mini_game`. |
| Suporte | `PlayerSupport.{Worker,Logic}` | Revive, poção (janela battle-clear), reposicionamento por middle-click; publica `:pokemon`. |

**Configuração e infraestrutura**: `Settings` (fonte única `@seed_settings`; arquivo em `~/.pokex` guarda SÓ overrides), `Calibration` (regiões/pontos serializados, `mtime/1`, perfis nomeados em `~/.pokex/calibrations/` com thumbnail), `Diagnostics.Report` (dump JSON + matriz "o que o bot vê"), `Home`, `Preflight`, `Mailer`.

## 2. Percepção → decisão → atuação, por capacidade

- **Pesca** — `Fishing.Worker` (tick) captura via `Fisher.Sensors` (glow/água) + one-shot da SkillBar + injeta o fato `:pokemon` nas observações → `Fishing.Logic` (máquina de estados pura; `hold_gate?` = cooldowns E/OU vida/pokémon ativo segura só a FISGADA, nunca o arremesso; teto `hook_hold_max_ms`) → `Body.perform(actions, :normal)` atômico ([fishing/worker.ex:226](../../lib/pokex/bots/fishing/worker.ex)). Congela sozinho quando o fato `:mini_game` diz jogando; retoma reiniciando o ciclo de cast.
- **Combate** — `Combat.Worker` atacha aos feeds `:battle` e `:skill_bar` → `Combat.Logic` decide alvo (Tab) e skills prontas → **bursts de tecla DIRETO no Rig** (`Rig.impl().press_many`, [combat/worker.ex:274](../../lib/pokex/bots/combat/worker.ex)), consultando `Perception.mini_game_gate()` antes de cada burst. Intencional (latência/atomicidade) — regra do handoff: medir antes de mexer.
- **Captura/loot** — `Catcher.Worker` orientado a eventos do fato `:battle` (gate: só avança com luta ENGAJADA encerrada) → baseline do chão + diff (`Interpret.Corpses` no feed `:corpses`) → `Catcher.Logic` → Body (cliques/Espaço; Espaço também é a tecla do mini-game, então o avanço é gateado em `mini_game_playing?`).
- **Mini-game** — `MiniGame.Worker` captura a faixa dedicada (`mini_game_region`) → `Detector` (3 passadas) arma por streak → `Player` lê a coluna (`Track`), pede decisão ao `Pilot` (puro, normalizado 0..1) e segura/solta Espaço **direto no Rig** (o gate do Body bloquearia o próprio player). Publica `:mini_game` todo tick, inclusive no halt/terminate.
- **Suporte** — `PlayerSupport.Worker` (tick) lê a própria região de HP → publica `:pokemon` → decide revive/poção/reposição (`Logic`): poção exige `potion_battle_clear_ms` contínuos sem batalha; reposição espera `reposition_battle_clear_ms` e manda o Pokémon pro `pokemon_spot_point` com middle-click nativo via Body `:normal`.

## 3. Coordenação e segurança (o que NUNCA pode regredir)

1. **Fail-safe de input**: nada de tecla/clique sem jogo frontmost e sem panic (`InputGate` + `Focus`); panic do `Guardian` para inclusive revive/poção.
2. **Um dono do input compartilhado**: o `Body` serializa e prioriza; `:high` (combate) preempta `:normal`; `:critical` (combo de sobrevivência) atravessa o gate do mini-game. As duas exceções diretas ao Rig (Combat bursts, MiniGame.Player) são deliberadas e documentadas nos moduledocs.
3. **Blackboard com freshness**: todo fato tem max-age (`*_fact_max_age_ms`) e comportamento fail-open explícito — um worker morto não pode deixar o resto do sistema preso.
4. **Coordenação por fatos, não por processos**: o pause/resume par-a-par foi deletado na Fase 2 do blackboard; cada worker se auto-segura lendo o fato e se retoma sozinho. Padrão a copiar em capacidades novas.
5. **Feeds demand-driven**: percepção compartilhada só roda com consumidor atachado; broadcast PubSub apenas em mudança.
6. **Captura no display certo**: `Capture.screen/2` usa a metadata do SCK; nunca reintroduzir `screencapture -m` como caminho principal (bug real de 2 monitores).

## 4. Superfícies e configuração reutilizáveis

**Rotas**: `/` (PanelLive), `/diagnostics`, `/calibration`, `/fishing-lab`, `/world` + `GET /captures/:name` e `GET /exports/:name`.

- `PanelLive` — status/controles por worker, Automações (toggles + forms dos gates), tuner de timings, feed com níveis macro/debug + filtro por worker, banner de calibração desatualizada, exports (JSON de diagnóstico, eventos). Duas colunas no xl. Parsing de forms extraído puro em `PokexWeb.PanelForms`.
- `CalibrationLive` — wizard completo, correções rápidas por passo clicável (zoom com pan, contagem), perfis nomeados com thumbnail.
- `WorldLive` — todos os fatos do blackboard com idade/frescor (a tela de "por que o bot acha isso").
- `DiagnosticsLive` / `FishingLabLive` — sondas de região e simulador do pilot com traces reais.
- **Configuração**: `Settings` cobre toggle+parâmetro de cada automação (padrão pronto para F2/F3); `Calibration.save_profile/apply_profile` é o modelo de "conjunto nomeado aplicável" a imitar.

Mapa KizuBot → Pokex (do dashboard de referência): Dashboard≈PanelLive · Healing≈PlayerSupport · Fishing≈Fishing · Combat≈Combat · Catch≈Catcher · Engine≈Settings/tuner · Alarms≈F7 · Cavebot≈F4-F5 · Account/Party/Farming≈sem equivalente (F2 cobre presets; F9 opcionais).

## 5. Ponto de extensão mais próximo, por fase do roadmap

| Fase | Ponto de extensão mais próximo (sem criar nada genérico) |
|---|---|
| 1 Painel/diagnóstico | Workers já emitem logs macro (mudança de estado) e contadores; PanelLive já tem cards por worker e o /world mostra fatos. Falta só o "por que estou parado/segurado" como informação estruturada de cada worker — a decisão já existe dentro de cada um (hold reasons da pesca, held? do combate, pending do suporte). |
| 2 Presets por Pokémon | `Settings` (chaves de skills/bolas/suporte já existem) + o padrão `Calibration.save_profile`: um preset = mapa nomeado de overrides aplicado em lote. UI: card em Automações ou junto dos perfis de calibração. |
| 3 Políticas pós-combate | Os três consumidores do fim-de-luta já leem o fato `:battle` com janelas battle-clear próprias (Catcher avança, poção, reposição). Ordem/prioridade configurável = coordenar essas janelas via `Settings`; motivo observável = logs macro que já existem. |
| 4 Cavebot mínimo | Ciclo de vida: `BotSupervisor` (mesmo padrão dos 5 workers); interrupção/retomada: auto-hold lendo `:battle`/`:mini_game` como os outros. **Gap real: não existe percepção de posição do personagem** (nenhum módulo lê minimapa — verificado) e o dono do input de MOVIMENTO do personagem ainda não existe (só o middle-click move o Pokémon). É a única fase cuja base precisa nascer. |
| 5 Cavebot robusto | Recorder: o padrão clique-na-screenshot do CalibrationLive (marking steps + zoom-pan) serve para gravar waypoints; "sem progresso": baseline+diff de frames já é técnica provada no Catcher. |
| 6 Combate evoluído | `Combat.Logic` é puro e testado — filtros/stop conditions entram como config nova ali; alcance/posicionamento tem o feed `:arena` pronto. O caminho direto de bursts: medir latência antes de qualquer mudança (prompt específico do handoff). |
| 7 Estatísticas/alarmes | Contadores por worker + export de eventos (`~/.pokex/exports`, `ExportsController`) já existem; agregação de sessão = módulo puro + card no Panel; alarmes = derivar dos logs macro com dedupe. |
| 8 Actions & Rules | Gatilhos observáveis = fatos do WorldState (já com freshness/idade no /world); simulação: o padrão do FishingLabLive (replay de traces reais) é o modelo. |
| 9 Opcionais | Sem base atual e sem necessidade concreta — não mapear (regra 10). |

## 6. Riscos e testes a preservar

- **Baseline**: 484 testes / 0 falhas / 53 arquivos. Suíte inteira roda com `Rig.Fake` + `server: false` — nenhum teste toca mouse/teclado/tela reais.
- **Testes-guardiões que nenhuma fase pode quebrar**: InputGate/Focus (frontmost + panic), prioridades e gates do Body, hold gates da pesca (cooldown/vida — arremesso nunca segurado), janelas battle-clear de poção/reposição, fixtures REAIS do Detector do mini-game (inclusive a barra colada na borda direita), round-trips de Calibration/perfis, stamps do fato `:calibration` no start/stop, LiveView tests do Panel/Calibration.
- **Flakiness conhecida**: falhas raras dependentes de ordem (pré-existentes, nunca reproduzidas em 3 runs seguidos); testes novos devem limpar fatos globais no `on_exit`.
- **Riscos operacionais** (valem para qualquer executor): NUNCA subir um segundo dev server (instância nova compartilha `~/.pokex` e o PlayerSupport auto-liga dirigindo o mouse real); não compilar/pull no checkout principal com o `phx.server` do Lucas rodando; recompilar helpers nativos exige re-grant de TCC (SCK por hash do fonte; Accessibility do `key_events`); a árvore é compartilhada entre sessões de IA — PRs isolados, merge imediato após criar.
- **Validação live pendente** (não re-quebrar o que ainda nem foi validado): mini-game jogando sozinho, reposicionamento pós-luta, perfis de calibração, gate de vida na pesca.

## 7. Observações arquiteturais (evidência apenas — sem proposta nesta rodada)

1. **Dupla via de sensores**: a pesca lê a tela via `Fisher.Sensors.Real`; o combate via feeds + `Perception.Interpret`. Evidência: o moduledoc do `Interpret` declara "Ported from the combat half of `Fisher.Sensors.Real` (which stays untouched for fishing until phase 2)". A migração da pesca para feeds já era radar antes deste handoff.
2. **Três disciplinas de atuação**: Body (pesca/captura/suporte), Rig direto no Combat ([worker.ex:274](../../lib/pokex/bots/combat/worker.ex)) e Rig direto no `MiniGame.Player` (moduledoc). As duas exceções são intencionais e documentadas; qualquer unificação exige medição de latência/atomicidade primeiro.
3. **PanelLive grande**: ~1,5k linhas (evidência: moduledoc do `PanelForms`, que já extraiu o parsing puro). A extração incremental é o padrão em curso, não uma reescrita.
4. **Tema do painel fora dos tokens**: ~136 cores hex hardcoded (tema escuro próprio, ignora o toggle de tema). Débito estético conhecido, baixa prioridade.
5. **Sem percepção de posição do jogador**: nenhum módulo lê minimapa/posição (verificado por busca na árvore). Bloqueia F4/F5 — é fundação nova de verdade, não extensão.
6. **Naming legado**: a árvore `fisher/` (Config/Sensors/Skills) serve o `fishing/` atual; rename interno de `skillbar_msg` pendente. Cosmético; só tocar com propósito.
