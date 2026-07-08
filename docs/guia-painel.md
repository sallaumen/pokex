# Guia do painel — observabilidade + cooldowns

Referência rápida do que foi construído (2026-07-07/08). O painel é `/`, a calibração `/calibration`, o laboratório manual `/diagnostics`.

## Ativar "só pescar quando dá pra matar" (cooldowns)

1. **Calibrar a barra de skills** (uma vez): `/calibration` → **"Calibrar barra de skills"** → clique o canto superior-esquerdo e o inferior-direito da barra (sem o cadeado à direita). Não refaz o resto da calibração.
2. **Afinar o limiar pronto/cooldown**: no painel, clique **"Exportar diagnóstico (JSON)"** com o jogo aberto. O JSON (`~/.pokex/exports/latest.json`) traz, por slot, `brightness`/`saturation`/`state`. Manda pro Claude ou ajuste `skill_ready_min_brightness` / `skill_ready_min_saturation` até o `state` bater com o que você vê (pronta = colorida; cooldown = escura + número).
3. **Ligar**: seção **"Cooldowns das skills"** → toggle **"Só pescar quando dá pra matar"** + campo **"skills necessárias pra matar"** (ex.: `4 5 6 7`). Use o botão **"Ler"** pra ver o estado atual dos slots.

Com isso: a pesca **segura a fisga** (a bolha continua até você puxar) e só puxa quando TODAS as skills de matar estão prontas; o combate **dispara direto a skill pronta** de maior prioridade, pulando as em cooldown.

## Botões do painel

- **Start / Stop** — liga/desliga pesca + combate juntos.
- **Testar pesca / Testar combate** — roda um sozinho (o outro fica parado).
- **Feed "O que ele está fazendo"** — eventos macro por padrão; marque **debug** pra ver cada tick. **Exportar** grava os eventos em `~/.pokex/exports/`; **Limpar** zera.
- **Prints & Diagnóstico** — 📸 tela cheia / água / batalha / arena / skills (preview + baixar). **Exportar diagnóstico (JSON)** despeja tudo que o bot vê (regiões, métricas de pixel, matriz colorida do painel Batalha) — é o que o Claude lê pra diagnosticar sem foto.
- **Timing do combate** — calibra `skill_cast_ms` (velocidade de matar), `target_verify_attempts` + `wait_target_verify_ms` (velocidade de busca), `fight_timeout_ms`. Aplica no próximo Start/Testar.
- **Botão de pânico** — mouse no canto superior-esquerdo para tudo na hora.

## Arquitetura (por que não trava)

Os dois bots (`Fishing.Worker`, `Combat.Worker`) são processos **independentes**. A ÚNICA coisa compartilhada é o `Body` (mouse/teclado) — porque só o mouse precisa ser serializado. Tudo que um bot precisa da tela, ele **lê sozinho** como observação (brilho, batalha, e agora a barra de skills via `Pokex.Bots.SkillBar`, um helper **puro** sem processo/estado). Não há comunicação assíncrona entre os bots → nada pode travar um tick ou gerar estado inválido.

## Próximo passo (fazer junto, online)

**Busca do combate mais rápida** — pular linhas vazias da lista via detecção de HP (`Vision.hp_bar_rows`), com fallback seguro (se não travar nas linhas detectadas, varre o resto). Precisa validar ao vivo que a contagem de barras de HP é confiável na tua tela (dá pra ver no diagnóstico). Será **opt-in** (desligado por padrão) pra nunca piorar o que já funciona.
