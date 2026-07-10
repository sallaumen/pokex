# Pokex 🎣⚔️

Bot de pesca e combate para PokeXGames (Wine/CrossOver no macOS).
Cérebro em Elixir/Phoenix, olhos em `screencapture`, mãos em `cliclick`/`osascript`.

**Uso pessoal. Automação viola os ToS do jogo — risco de ban. Repo privado.**

## O que faz

Ciclo completo, controlado por um painel LiveView:

1. **Pesca** — equipa a vara, arremessa e espera as bolhas reais da mordida,
   ignorando o splash do arremesso e o pulso da isca (separados por magnitude e
   por "esperar a água acalmar").
2. **Luta** — o pokémon fisgado teleporta pra perto; aperta **Tab** pra selecionar
   o alvo (sem mouse) e confirma a trava pela borda vermelha **por-fileira** (sem
   lurar um segundo bicho), ataca com as skills na **ordem de prioridade** e mata
   todos os fisgados antes de seguir.
3. **Captura** — detecta o corpo por diferença contra o CHÃO VAZIO aprendido no
   início (baseline de warmup) e joga a pokébola sem andar. O **Parado/Em
   movimento** é global: modo **Parado** automático — arma o baseline, detecta o
   corpo parado, confirma o acerto e repete até 2 bolas. **Em movimento**
   desarma a automação (você captura na mão); "Reaprender chão" força um novo
   baseline ao trocar. **Space-loot** (em Parado): Espaço após cada kill prensa o
   corpo adjacente antes da pokébola; `loot_enabled`/`capture_enabled` são
   independentes (só looting, sem bola).

## Setup (uma vez)

1. `brew install cliclick`
2. `mix setup`
3. `mix phx.server` → http://localhost:4004
4. macOS pede permissões na primeira ação: conceda **Acessibilidade** e
   **Gravação de Tela** ao terminal (System Settings → Privacy & Security) e
   reinicie o `mix phx.server`.

## Rodar

1. Jogo aberto, personagem parado perto d'água, pokémon lutador fora da bola.
   Posicione a janela e **não a mova** (se mover, recalibre).
2. `/calibration` — capture a tela e marque água, janela Battle, arena, ponto neutro.
3. `/` — defina a **ordem das skills** (mais fortes primeiro) e **Start**.
4. `/diagnostics` — tunagem fina ao vivo (bolha, lock por-fileira, cada ação avulsa).

## Segurança

- **Pânico:** mouse no canto superior-esquerdo da tela → o bot para na hora
  (funciona até no meio das pausas).
- Stop no painel para na hora; após crash renasce parado (`idle`).
- N falhas seguidas → estado `error`, espera você.

## Arquitetura

- `Fisher.Logic` — máquina de estados **pura** (sem I/O): recebe observações +
  `now` (ms monotônico) e devolve o próximo estado + ações-dados.
- `Fisher` — GenServer driver: sente (`Sensors`/`Vision` sobre capturas), executa
  as ações (`Rig`), agenda ticks, transmite estado por PubSub.
- `Vision` — análise pura de pixels (bolha ciano por magnitude, lock vermelho
  por-fileira, nome do hostil na arena).
- `Calibration` — geometria da tela em POINTS; conversão Retina isolada aqui.

Os limiares são settings tunáveis, medidos no jogo real e comentados em
`lib/pokex/settings.ex`. Spec original em
`docs/superpowers/specs/2026-07-06-pokex-fishing-bot-design.md`.
