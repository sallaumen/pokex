# Simulador fase 2 — os cenários de problema

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Transformar os quatro grupos de problema que Lucas marcou em cenários **declarativos** que ele carrega com um clique e assiste — inclusive o bug que está aberto no jogo hoje (a tecla que não sai).

**Architecture:** Um cenário é dado, não código: rota + semente + knobs + uma lista de **injeções com hora marcada**. `Pokex.Sim.World` ganha as falhas que ele pediu como estado (cego, tecla morta, mini-game, vida forçada), e o `Runner` aplica as injeções quando o relógio do mundo passa por elas. A tela ganha um seletor.

**Tech Stack:** Elixir puro sobre o que a fase 1 deixou pronto.

## Global Constraints

- Código em inglês; strings de produto (nome e descrição de cenário) em **pt-BR** — são produto, ele vai ler.
- Comentários raros; nomes de teste per `tavano_rfc.txt`.
- Worktree `~/projects/worktrees/os-cenarios`, branch `sim/os-cenarios`.
- `mix precommit` é o portão; merge na `main` quando passar.
- **Nenhuma falha injetada pode ser silenciosa.** Uma injeção ativa aparece na tela — um simulador que quebra escondido ensina a desconfiar da coisa errada.
- Determinismo continua sendo requisito: injeção tem hora, não sorteio.

---

## Task 1: As falhas como estado do mundo

**Files:** modificar `lib/pokex/sim/world.ex`, `test/pokex/sim/world_test.exs`

**Interfaces:**
- Produces: `World.fail(world, failure) :: t` e `World.recover(world, failure) :: t`, onde `failure` é
  - `:blind` — a tela não é legível (`enemies: nil`, nunca `[]`)
  - `{:dead_key, key}` — a tecla sai da mão e **não acontece nada no jogo**, mas o cooldown corre: é o bug aberto dele
  - `:mini_game` — a cápsula na tela; todo fato congela
  - `{:hp, pct}` — põe a vida onde o cenário precisa, sem esperar mordida
- `world.failures :: MapSet.t()` — o que está quebrado agora, para a tela mostrar.

**Contexto:**

O bug aberto no journal de 17/08 (2ª run: 6 aberturas, 6 `🔁 não saiu`, ZERO `alvo morto`) tem dois suspeitos que nenhum log separa: a tecla não chegou ao jogo, ou chegou e o efeito não caiu. `{:dead_key, key}` modela o SEGUNDO: a barra muda (o cooldown corre, o recibo confirma) e o monstro não perde vida. Se o simulador reproduzir o padrão do journal com essa injeção e não com a outra, o diagnóstico deixa de ser palpite.

`:mini_game` congela **todos** os fatos, e é assim de propósito: os feeds reais pulam a captura enquanto a cápsula está na tela, então fato velho durante o mini-game não é sinal de nada.

- [ ] **Step 1:** testes de mesa para cada falha (cego dá `nil` e não `[]`; tecla morta gasta cooldown sem tirar vida; mini-game congela; vida forçada muda a faixa).
- [ ] **Step 2:** rodar, ver vermelho.
- [ ] **Step 3:** implementar `failures` na struct, `fail/2`, `recover/2`, e os pontos onde cada uma morde (`observe/2`, `fire/2`, `step/2`).
- [ ] **Step 4:** verde.
- [ ] **Step 5:** commit.

---

## Task 2: O cenário como dado

**Files:** criar `lib/pokex/sim/scenario.ex` e `test/pokex/sim/scenario_test.exs`

**Interfaces:**
- `Scenario.all() :: [t]` · `Scenario.get(id) :: t | nil`
- `%Scenario{id, name, why, route, seed, knobs, script}` onde `script` é `[{at_ms, action}]` e `action` é `{:fail, failure}` / `{:recover, failure}`.

**A biblioteca — os quatro grupos dele:**

| id | grupo | o que mostra |
|---|---|---|
| `pilha-pequena` | régua | 2 monstros: a régua de 3 manda seguir andando |
| `pilha-que-fecha` | régua | 5 monstros que param de chegar: estoura a área |
| `ganancia` | régua | leash curto — arrastar faz sumir, e ele vê sumindo |
| `vida-caindo` | vida | mordida forte: verde → amarelo → fecha a rodada → revive |
| `morte` | vida | mordida brutal: a barra some e o fato vira `fainted?` |
| `tecla-morta` | mãos | o bug de hoje: recibo confirma, monstro não sangra |
| `tela-ilegivel` | cegueira | `enemies: nil` — a engine diz que não está vendo, e segura |
| `mini-game` | cegueira | a cápsula entra e todo fato congela |

Cada um carrega `why` em pt-BR dizendo **o que observar**, porque um cenário sem pergunta é só uma animação.

- [ ] **Step 1–5:** teste de que a biblioteca carrega, que todo id é único, que todo cenário aponta pra uma rota que existe (ou pra rota interna pequena), e que o script está ordenado no tempo. Depois implementar e commitar.

---

## Task 3: O `Runner` executa o roteiro, e a tela escolhe

**Files:** modificar `lib/pokex/sim/runner.ex`, `lib/pokex_web/live/sim_live.ex`, testes.

- `Runner.load_scenario(scenario)` carrega mundo + guarda o script; cada tick aplica o que venceu (comparando o relógio DO MUNDO, não o da máquina — o roteiro tem que ser reprodutível).
- A tela ganha um seletor de cenário ao lado do de rota, o `why` embaixo, e um selo vermelho listando as falhas ativas.

- [ ] **Step 1–5:** testes (o roteiro dispara na hora certa; uma falha ativa aparece no estado), implementar, verde, `mix precommit`, commit, merge na `main`.

---

## Definition of done

- [ ] As quatro falhas existem como estado e cada uma tem teste de mesa.
- [ ] Oito cenários carregáveis, cada um com `why` em pt-BR.
- [ ] O roteiro dispara pelo relógio do mundo (reprodutível), nunca pelo da máquina.
- [ ] Falha ativa é **visível** na tela.
- [ ] `mix precommit` verde e mergeado na `main`.
