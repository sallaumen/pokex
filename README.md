# Pokex 🎣

Bot de pesca para PokeXGames rodando via Wine/CrossOver no macOS.
Cérebro em Elixir/Phoenix, mãos em `cliclick`, olhos em `screencapture`.

**Uso pessoal. Automação viola os ToS do jogo — risco de ban. Repo privado.**

## Setup (uma vez)

1. `brew install cliclick`
2. `mix setup`
3. `mix phx.server` → http://localhost:4004
4. Na primeira captura/clique o macOS pede permissões: conceda **Acessibilidade**
   e **Gravação de Tela** ao seu terminal em System Settings → Privacy & Security,
   e reinicie o `mix phx.server`.

## Fluxo

1. Abra o jogo, personagem parado perto d'água, pokémon lutador fora da pokébola.
2. Posicione a janela do jogo e NÃO a mova mais (se mover, recalibre).
3. `/calibration` — capture a tela e marque: água, janela Battle, arena, ponto neutro.
   O navegador não pode cobrir o jogo na hora da captura.
4. `/` — Start. O painel mostra estado e contadores ao vivo.
5. Tunagem fina em `/diagnostics` (score do brilho ao vivo, teste de cada ação).

## Segurança

- **Pânico:** jogue o mouse no canto superior-esquerdo da tela → o bot para.
- Stop no painel para na hora; após crash o bot renasce parado (`idle`).
- 5 falhas consecutivas → bot entra em `error` e espera você.

## Arquitetura (resumo)

`Fisher.Logic` (máquina de estados pura) ← observações ← `Sensors` ← `Vision` ← capturas
`Fisher` (GenServer) → ações → `Rig` (cliclick/screencapture) → jogo
Spec completa: `docs/superpowers/specs/2026-07-06-pokex-fishing-bot-design.md`.
