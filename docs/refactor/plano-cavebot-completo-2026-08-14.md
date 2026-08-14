# Plano: o Cave Bot completo

> Data: 14 de agosto de 2026
> Lido a partir de: `main` em `54df692`
> Natureza: direção e sequência. Nenhuma fase autoriza reescrita; cada uma vira PRs pequenas com `mix precommit` zerado (AGENTS.md, "CI and merging").

## O que "completo" significa

Uma caçada em que o Lucas dorme e confia, medida por quatro perguntas:

1. **Vivo?** O pokémon não morre por mob maior que o esperado, e quando a vida cai o bot reage antes do jogador humano reagiria.
2. **Caçando?** A madrugada inteira farmando; incidente vira pausa curta, não fim de noite.
3. **Se recupera?** Revive, retoma a rota, continua — sem clique humano.
4. **Conta a história?** De manhã, a Central responde o que aconteceu, quando e por quê, sem arqueologia de log.

As prioridades vêm dele, nesta ordem: **vivo > caçando > se recuperar** (2026-08-14).

## Estado em 14/08 (o que já existe)

- **Guarda de HP na mobada** (#265): abaixo de `cavebot_hp_abort_pct` (60) abandona o mob, solta o combo no que juntou, e a rota só volta em `cavebot_hp_resume_pct` (85). Barra ilegível durante recuperação = espera o revive.
- **Segurança visível** (#267/#269): card na Central (toggles resgate/cura/poção + limites editáveis), avisos ⚠️ no arranque, banners de parada, matança sólida no mapa, log de 40 linhas.
- **Resgate assíncrono e falante** (#270/#271): o combo roda numa task (pânico não espera mais o worker), revive/cura recusados são nomeados, gate obsoleto não explica mais a tela.
- **Rota mais esperta** (#263/#264, outra sessão): skills por categoria na rota, escada como ponto médio do par.
- **CI de volta** (#280): billing pago, workflow espelha o precommit; portão continua sendo o precommit local, CI é segunda opinião.
- **Instrumentação pronta**: `cavebot_measure_walk` no /config grava cada decisão de andar (distância, idade da leitura, o que saiu).

## Método (não negociável)

- **Medir antes de mexer.** Afirmações sobre comportamento se conferem em `~/.pokex/routes.json` e `~/.pokex/journal/*.jsonl`, nunca no relatório de quem implementou. As queixas de movimento ("passa do ponto", "empurra parede") estão SEM prova no journal — não construir em cima.
- **Uma limitação observável por PR**, teste no nível da decisão, strings de produto em pt-BR.
- **Handoff da IA anterior** (memória `cavebot-handoff-previous-ai` + docs/superpowers/): fatos do jogo (escada = 1 tecla/2 tiles; combo sem `fight_ms` é aura, não lição), armadilhas medidas (journal não persiste `:debug`; `Body.perform` nunca no tick; `skip_waypoint` abandona estado por-waypoint), e a instrução de premiar subagente que PARA em vez de adivinhar.

## Fase 0 — Prova de fogo (Lucas + qualquer IA; dias, não sprints)

Validar o que já entrou, em caçada real:

1. Uma madrugada com resgate ARMADO e a guarda ligada. De manhã: journal legível? morreu? quantos aborts de mobada, e foram justos?
2. Uma volta na Meganium com `cavebot_measure_walk` ligado — o dado que a Fase 1 inteira espera.
3. Ajustar os dois limites da guarda com base no que a noite mostrar (são settings, sem PR).

**Aceite:** uma madrugada sem morte, com a caçada ativa e o motivo de cada pausa escrito.

## Fase 1 — Movimento medido (bloqueada pela volta instrumentada)

Com o journal da volta: testar as hipóteses da IA anterior (leitura de até 800ms de idade; diagonal cortando caminho em ~62% das pernas) e consertar o que os NÚMEROS mostrarem.

**Aceite:** tiles/s ou precisão de chegada melhor, medida antes/depois na mesma rota, sem piora na taxa de stuck. Sem dado, esta fase não existe.

## Fase 2 — Morte deixa de ser fim de noite

Hoje: pokémon morto vira "luta que não anda" → `:fight_stalled` → bloqueio terminal. Com a guarda + resgate armado isso deve ser raro — mas raro não é nunca.

1. **Evidência primeiro:** o journal de uma morte real (o que a barra mostra? a lista de batalha congela?). Se a Fase 0 não produzir uma, simular no jogo de propósito.
2. Então, em ordem: resgate para pokémon já caído (cuidado com o histórico de falsos positivos de barra coberta — as portas de plausibilidade existem por incidente real); `:fight_stalled` com barra ilegível vira espera nomeada + alarme em vez de bloqueio, retomando pós-revive.
3. Fuga automática (`BotSupervisor.emergency_escape/1`) só como último recurso configurável, desligada por padrão — ela para a frota sem retomar, o que briga com "caçando".

**Aceite:** cenário de morte no harness determinístico se recupera sozinho; nenhuma mudança enfraquece a ordem do pânico (latch antes de halt).

## Fase 3 — Sessão com dono (pré-requisito de retomada automática)

É a Frente 1 do `plano-consolidacao-2026-07-29.md`, que continua válida: geração de sessão, comandos idempotentes, Focus/Guardian/blocks respondendo "quem parou, por quê, e o que retoma". Só com isso dá para reclassificar bloqueios de hoje (quais podem se re-armar com tentativas limitadas, quais são terminais de verdade) sem reabrir o risco de retomada-depois-de-pânico.

**Aceite:** a lista de testes obrigatórios da Frente 1, como escrita lá.

## Fase 4 — A Central vira cockpit

`cavebot_live.ex` está com ~2600 linhas, 2,2× o segundo maior arquivo — o emaranhado nomeado pelo handoff. Decompor por responsabilidade (componentes funcionais, projetores puros, parsing fora da LiveView — a receita da Frente 4), sem reescrever e sem mudar comportamento. Depois: atividade persistida (o log de 40 linhas morre no reload), sync dos toggles com o painel, polimento do mapa.

**Aceite:** testes atuais intactos, arquivo principal reduzido a fração do tamanho, DESIGN.md (#266) respeitado.

## Fase 5 — Completude de caçada (decidir COM o Lucas, não por ele)

Candidatas, em ordem de valor aparente — nenhuma é compromisso até ele escolher:

- **Suprimentos**: hoje `stock_alerts` só grita; uma madrugada completa ou repõe (rota de depósito) ou para com elegância no estoque zero.
- **Estatísticas de caçada**: kills/volta, tempo por volta, xp/h — o dado que diz se a rota é boa.
- **Rotação de rotas / respawn**: mais de uma rota armada em revezamento.

## Decisões que são do Lucas (paradas até ele falar)

1. Alarme do resgate: continua inmutável (`:geral`) ou vira categoria `:hp` (mutável)?
2. Resgate armado por padrão no modo caçada, ou continua opt-in?
3. Fuga automática: existe mesmo desligada, ou nem existe?
4. Quais candidatas da Fase 5 entram.

## Prompt de continuação

```text
Leia primeiro: AGENTS.md, docs/refactor/plano-cavebot-completo-2026-08-14.md,
docs/refactor/plano-consolidacao-2026-07-29.md (Frentes 1 e 4).

Confira em qual fase estamos: pergunte ao Lucas pela validação da Fase 0 e pelo
journal da volta com cavebot_measure_walk. Sem esses dados, as Fases 1 e 2 não
começam — trabalhe a Fase 4 (decomposição da cavebot_live.ex) ou a Fase 3.

Regras: worktree próprio com push imediato; uma limitação observável por PR;
mix precommit zerado no worktree antes de qualquer merge; afirmações conferidas
contra ~/.pokex, não contra relatórios; subagente que para e reporta está certo.
```
