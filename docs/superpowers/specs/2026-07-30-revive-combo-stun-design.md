# Auto-revive com combo de stun — design

**Data:** 2026-07-30 · **Aprovado por:** Lucas (chat)

## Problema

Caçando pokémons mais fortes, o momento do revive é o mais vulnerável: o
resgate atual (recolher → max-revive no retrato → soltar) acontece com os
mobs batendo. As skills 1 e 2 (stun em área) devem ficar RESERVADAS pra esse
momento — stunar os inimigos ao redor e só então reviver — e a escolha disso
precisa ser nativa no painel do auto-revive. Objetivo declarado: "garantir que
meu personagem nunca mais vai morrer à toa".

## Decisões do Lucas

1. **Skill em cooldown na hora do resgate → PULA** (consulta a leitura da
   barra; leitura indisponível → aperta às cegas). Nunca espera.
2. **Reserva das skills no combate → SÓ AVISO no painel** (ele mesmo tira as
   teclas de `skill_keys`; sem exclusão automática).
3. **Arquitetura → combo do editor, COMPILADO** no resgate atômico. O combo é
   autorado no editor de combos existente; o resgate NÃO passa pelo
   `Combos.Runner` (semântica de luta/troca) — só empresta a autoria.

## Comportamento

### Settings (fronteira do #106)

- `rescue_mode: "direto"` — enum `~w(direto combo)`.
- `rescue_combo: ""` — nome do combo escolhido (string livre; validada em uso,
  não na fronteira — combo pode ser renomeado depois).

### Compilação do prefixo (na hora do disparo)

No modo `"combo"`, `fire_combo` resolve o combo por nome no `Combos.Store` e
compila o PREFIXO de stun:

- `{:skill, k}` → `Perception.ready_skills()`: `nil` (leitura indisponível) →
  inclui `{:press, k}` às cegas; `k` presente → inclui; ausente → **pula** com
  log dizendo qual ("pulei skill k — cooldown").
- `{:wait, ms}` → mantém; `{:wait, setting}` → resolve via `Settings.get`
  ANTES da compilação pura (waits sempre mantidos — custo de ms, zero risco).
- Sequência final = `prefixo ++ [{:wait, rescue_step_ms}] ++ cauda atual`
  (recolher → retrato → Shift+Q → soltar → recentrar), UMA sequência atômica
  no Body a `:critical` — nada entra entre o stun e o revive.

A decisão de QUAIS skills entram é do worker (leitura fresca);
`PlayerSupport.Logic` continua pura: `stun_prefix(steps, ready)` filtra e
emite `{:press,_}/{:wait,_}`, e `combo/1` aceita `stun_steps` (default `[]`).

### Elegibilidade

Combo elegível pro resgate = TODOS os passos `{:skill,_}` ou `{:wait,_}`.
`swap_member`/`swap_counter` tornam o combo inelegível (`Combos.rescue_eligible?/1`).
No dropdown do painel, inelegíveis aparecem desabilitados com o motivo.

### Falhar na direção de SALVAR

Combo escolhido inexistente, desabilitado ou inelegível na hora do disparo →
prefixo vazio + `rule_alarm` ("combo de resgate 'X' indisponível — revivendo
direto"). Um nome pendurado JAMAIS pula o revive. Gatilho, cooldown, guarda de
duas leituras e gate fechado: inalterados.

### Painel (card do Suporte)

- Seletor `direto | com combo`; dropdown dos combos só no modo combo.
- Preview estático da sequência compilada completa (sem consultar cooldown):
  "1 → 500ms → 2 → 500ms → Q → retrato → Shift+Q → Q".
- Aviso de conflito: tecla `{:skill}` do combo escolhido presente em
  `skill_keys` do combate → aviso visível ("a skill 1 está na rotação do
  combate — pode estar em cooldown na hora do resgate"). Não bloqueia nada.

## Testes

- Logic: `stun_prefix` (pronta entra / cooldown pula / `nil` às cegas / waits
  mantidos); `combo/1` com `stun_steps` antes do recall, atomicidade da lista.
- Worker: modo combo compila e dispara a sequência completa; nome pendurado →
  alarme + revive direto; modo direto inalterado.
- `Combos.rescue_eligible?/1`: skill/wait sim; swap não.
- Painel: seletor + dropdown + aviso de conflito + preview.
- Settings: enum `rescue_mode` na fronteira.

## Fora de escopo

Exclusão automática de teclas reservadas do combate (descartada pelo Lucas);
gatilhos novos de resgate; passos novos na linguagem de combos.
