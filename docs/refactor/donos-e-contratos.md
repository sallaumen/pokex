# Donos e contratos — o mapa de quem decide o quê

> Escrito em 2026-07-29 sobre `main` @ `49fe709` (Etapa 0 do
> [plano de consolidação](plano-consolidacao-2026-07-29.md)). Sem mudança de
> comportamento: isto é o retrato, não a direção. Uma IA nova começa AQUI, não
> pelo `git log`.

## Input (teclado/mouse reais)

| Camada | Dono | Regra |
|---|---|---|
| Execução | `Pokex.Rig.Mac` (via `Pokex.Rig.impl/0`) | Único lugar que fala com o SO. `gated/1` devolve `:ok` para chamada SUPRIMIDA — nunca trate `:ok` como prova de que a tecla chegou; a tela é a testemunha. |
| Fila/prioridade | `Pokex.Bots.Body` | Toda atuação de worker passa por ele (`:critical` > `:high` > `:normal`). Exceção deliberada: o player do mini-game segura Space direto pelo Rig (latência). |
| Veto | `Pokex.Bots.InputGate` | AND de `corner_ok` × `focus_ok`, consultado pelo Rig antes de CADA input. Hoje é **fail-open** quando a tabela não existe (janela de restart — caracterizada em teste; a Frente 1 inverte). |
| Ordem humana | latch do pânico (`InputGate.set_panic_latch/1`) | Proíbe AUTO-retomada, não a atuação manual. Só o "Iniciar bot" limpa. Guardian (canto), Logout e metas de sessão o travam. |

## Ciclo de vida da frota

| Decisão | Dono hoje | Observação |
|---|---|---|
| Iniciar/parar tudo | `Pokex.Bots.BotSupervisor.start_all/stop_all` | Ordem importa: cavebot cai primeiro (ele re-arma o combate). |
| Quais workers o modo liga | `Pokex.Modes` | Presets embutidos ("parado", "movimento", "caçada"); Settings continua o dono dos valores. |
| Pausa/retomada por foco | `Pokex.Bots.Focus` | Guarda um booleano `resume?` — sem identidade de sessão (é O problema da Frente 1). |
| Metas e estagnação | `Pokex.Bots.Guardian` | Sinal de vida = kill + minigame VENCIDO (fisgada só conta com o vigia desligado). Ações: alarme/parar/deslogar. |
| Fim de sessão de verdade | `Pokex.Bots.Logout` | Ctrl+Q + Enter e CONFERE a tela, com testemunha (baseline legível antes). |
| "Está rodando?" | `BotSupervisor.active?/1` | Pegadinha caracterizada: estados de parada do cavebot (`:blocked`/`:stuck`/`:fight_stalled`) contam como ATIVO. Header só acompanha pesca+combate. |

## Fatos (percepção)

| Camada | Dono | Regra |
|---|---|---|
| Blackboard | `Pokex.Perception.WorldState` (ETS) | Fatos com timestamp; leitor decide o max age. Fato velho ≠ observação atual. |
| Captura | `Pokex.Bots.Capture` | UMA captura de SO por vez (broker serializado). Nunca voltar a grabs concorrentes. |
| Feeds | `Pokex.Perception.Feed` | Sob demanda: só capturam com alguém `attach`ado. Não publicam sem calibração. |
| Leitura de tela | `Pokex.Vision.Glyphs` | Confiança 1.0 ou `nil` — nunca chuta. Atlas em `~/.pokex/glyphs_learned.json`. |

## Arquivos persistidos (`~/.pokex`)

| Arquivo | Dono | Regra |
|---|---|---|
| `settings.json` | `Pokex.Settings` | SÓ overrides; a fonte de defaults é `@seed_settings` no código. ~180 chaves, sem schema de tipo/faixa ainda (Frente 2). |
| `chars/<slug>/…` | `Pokex.Characters` | Camada por personagem ⊕ base ⊕ seed. |
| `calibration*.json` | `Pokex.Calibration` | Perfis; workers releem a cada run/tick. |
| `glyphs_learned.json` | `Vision.Glyphs` | Estritamente aditivo ao ensinar. |

## Regras de trabalho para agentes

- Testes NUNCA tocam rede, tela ou input reais (flags de env: `native_key_events`,
  `front_game_cmd`, `shiny_guard_active`, `logout_active`, …).
- NUNCA subir um segundo `mix phx.server`: instâncias compartilham `~/.pokex` e
  o mouse real.
- Árvore compartilhada entre IAs: `git add` só dos SEUS arquivos; PRs mergeiam
  logo após criação; correção posterior é PR novo.
- `mix precommit` antes de terminar; o CI (`.github/workflows/ci.yml`) roda o
  equivalente em cada PR.
