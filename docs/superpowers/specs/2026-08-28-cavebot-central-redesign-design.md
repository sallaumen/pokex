# Central da caçada: Assistir / Editar — design

Data: 2026-08-28. Aprovado por Lucas na conversa desta data.

## Problema

A Central da caçada (`lib/pokex_web/live/cavebot_live.ex`, ~3650 linhas) empilha
cinco faixas (loadout+cooldowns, "onde eles estão", tiles do mundo, segurança)
antes da bancada, e o mapa vive DENTRO da coluna esquerda que scrolla
(`lg:overflow-y-auto`). Num notebook 1440×900 (~800px úteis) o mapa some da
tela — e o mapa é a única coisa que nunca pode sumir.

Além disso a tela expõe controles de eras anteriores ao simulador. Auditoria de
28/08 (fluxo do dado, não nome):

| Conceito | Veredito |
|---|---|
| `:lure_start`/`:lure_end`, `luring?` | VIVO — engine lê `hunt.luring?` (`engine/logic.ex:542`), hp_guard, Timers e /sim dependem |
| stop `:sweep` ("varrer") | VIVO no código, MORTO em execução — Catcher recusa fora do modo Parado (`catcher/worker.ex:450`); a caçada perde `sweep_grace_ms` parada sem jogar bola |
| stops `:cooldown_revive`/`:wait` | VIVOS |
| `gather_wait_ms` | VIVO, mas só os Timers obedecem a postura; o fogo do combate é do engine agora |
| `park_tiles` | VIVO (park no `:lure_end`) |
| skill_meter / area_probe / crowd_scan | SÓ-UI — instrumentos de calibração humana dos knobs do /sim |
| `walk_test` | VIVO — diagnóstico minimapa/Body/teclas, sem substituto no sim |
| reset_revive, gather_piles, safety, comeback, hp_guard | todos VIVOS |
| `Route.z` | MORTO — só rótulo "andar N"; decisão usa `Route.floors/1` |
| campo `gathering?` do fato `:hunt` | MORTO — ninguém lê (engine casa `state` e `luring?`) |

## Decisões

1. **Dois modos na mesma LiveView: Assistir (padrão) e Editar.** Troca por aba
   no topo, via `live_patch` (`?modo=editar`) para sobreviver a refresh.
2. **Varrer removido de vez** (UI + Route + Logic + worker). `Catcher.sweep_now`
   fica — o modo Parado usa de verdade via /panel.
3. **Instrumentos ficam, colapsados** num drawer fechado abaixo da dobra do
   modo Assistir.
4. Limpezas de backend: campo `gathering?` do fato `:hunt`, `Route.z`, e o
   texto do `gather_wait` (promete segurar fogo, mas isso é do engine).

## Modo Assistir

Cabe inteiro em ~800px de altura; a página não scrolla (drawer abaixo da dobra
é a exceção deliberada).

- **Topo**: título + tally + abas Assistir/Editar numa linha só.
- **Banners de alerta** (minimapa não calibrado, parou, tropeçou, esperando,
  sim armado, glifos): no topo, NOS DOIS modos. São condicionais; quando
  aparecem, empurram o resto — o fato mais alto da página paga esse preço.
- **Grid principal** (`flex-1 min-h-0`):
  - **Esquerda: o mapa, canto superior esquerdo, sempre inteiro.** Dimensionado
    pela altura disponível (`min-h-0` + aspect fit), nunca dentro de coluna com
    scroll.
  - **Direita, empilhado**: "lutando como" + fileira de cooldowns (#414);
    tiles do mundo compactados (2 linhas × 3); log "O que ela fez" preenchendo
    o resto com scroll INTERNO.
- **Rodapé fino**: faixa Segurança atual (toggles + guarda de HP + tropeço).
- **Abaixo da dobra**: drawer "instrumentos" fechado por padrão com
  skill_meter, area_probe e crowd_scan intactos.

Some do modo Assistir (vai pro Editar): rotas, waypoints, edição de waypoint,
gravação, walk_test, otimizar rota.

## Modo Editar

- **Mapa à esquerda, sticky, sempre inteiro** — editar waypoint olhando o mapa
  é o ato; o mapa não acompanha scroll nenhum.
- **Coluna direita scrollável**: Rotas (seleção/criação/armar), Waypoints
  (lista), edição do waypoint selecionado, gravação + walk_test + otimizar.
- Banners de alerta idem Assistir. A faixa Segurança não repete aqui.

## Remoção do varrer

- **UI**: some o botão/rótulo `varrer` (`stop_label/stop_icon/stop_hint :sweep`,
  `decode_stop`), e o default de `decode_stop` deixa de ser `:sweep`.
- **Route**: `:sweep` sai dos stops válidos. **Migração na carga**: rota
  persistida com `"sweep"` num stop carrega ignorando a marca (drop
  silencioso no `Store`/decode — sem tocar nos arquivos salvos).
- **Logic**: `run_stop(:sweep)`, `sweeping?/3` e o custo de `sweep_grace_ms`
  somem; `post_fight` segue direto pros stops restantes.
- **Worker**: some a tradução `{:sweep, around}` → `Catcher.sweep_now`.
- **Config**: settings exclusivos do sweep do cavebot (ex.: grace) somem;
  os do Catcher/Parado ficam.

## Limpezas menores

- Fato `:hunt` perde o campo `gathering?` (produtor em `cavebot/worker.ex:429`;
  nenhum consumidor).
- `Route` perde `z`; o rótulo "andar N" deriva de `Route.floors/1`. Carga de
  rota antiga ignora `"z"` persistido; `Store` para de gravar.
- Texto do `gather_wait` na UI passa a dizer o que ele faz hoje: marca a
  janela da mobada (Timers/aura), não "segura o fogo".

## Testes

- `cavebot_live_test`: os dois modos renderizam; troca de aba preserva estado;
  cockpit não contém rotas/waypoints; modo Editar contém.
- Regressão de carga: rota persistida com stop `"sweep"` e com `"z"` carrega
  limpa e a caçada anda nela.
- Logic: `post_fight` sem sweep segue reto; suíte existente de stops ajustada.
- Conferência visual em worktree isolado (regras de `visual-check-safe-server`),
  viewport 1440×800.

## Fora de escopo (anotado)

- `plain?/1` (`cavebot/logic.ex:795`) ignora `park_tiles` ao decidir esquina
  encadeável — task separada.
- Branch órfã `origin/cavebot/cabe-na-tela` (15/08) atacava a mesma dor;
  substituída por este trabalho — apagar após o merge.
- Mover instrumentos pra outra página; redesenho do /panel.
