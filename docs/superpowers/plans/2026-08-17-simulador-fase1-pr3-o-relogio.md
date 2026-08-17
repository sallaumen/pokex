# Simulador fase 1 · PR 3 — o relógio do mundo

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Dar tempo ao mundo falso. `Pokex.Sim.Runner` faz `World.step/2` num relógio de verdade e publica cada fato **na cadência real dele** no quadro; o `Fence` abre a porta de atuação e sobe o Runner ao armar. No fim desta PR a frota **de verdade** anda numa caçada que nunca tocou o jogo.

**Architecture:** O `Runner` é o único processo do simulador. `Rig.Sim` já manda `{:sim_rig, action}` para o nome `Pokex.Sim.Runner`; ele traduz em `World.press/2`. O tick avança o mundo pelo tempo **real** decorrido (não pelo nominal), porque a idade dos fatos que a frota lê é medida em tempo real.

**Tech Stack:** Elixir/OTP, `Pokex.Perception.WorldState`, `Phoenix.PubSub`.

## Global Constraints

- Código em inglês; strings de produto em pt-BR; comentários raros; nomes de teste per `tavano_rfc.txt`.
- Worktree `~/projects/worktrees/o-relogio`, branch `sim/o-relogio-do-mundo` (**empilhada sobre `sim/o-mundo-falso`**).
- `mix precommit` é o portão.
- **`defp` nunca entre cláusulas de `handle_info`/`handle_call`** — mata o compile com `--warnings-as-errors` sem que teste, credo ou dialyzer vejam.
- **Nada de `GenServer.call` em worker a partir do Runner.** Ele publica fato, como todo o resto do sistema.
- Cadências são **herdadas**, não inventadas: `Settings.get(:feed_battle_ms)` = 120, `:feed_skill_bar_ms` = 400, `:feed_minimap_ms` = 500.

---

## File Structure

| arquivo | responsabilidade |
|---|---|
| `lib/pokex/sim/runner.ex` (criar) | O único processo. Tick, tradução de teclas, publicação por cadência, difusão pra tela. |
| `lib/pokex/sim/fence.ex` (modificar) | Abrir a porta de atuação ao armar; subir/parar o Runner. |
| `test/pokex/sim/runner_test.exs` (criar) | Tick, cadências, teclas, publicação. |
| `test/pokex/sim/fence_test.exs` (modificar) | A porta de atuação. |
| `test/pokex/sim/fleet_test.exs` (criar) | A prova: frota real andando no mundo falso. |

---

## Task 1: O `Runner` — tick, teclas e publicação por cadência

**Files:** criar `lib/pokex/sim/runner.ex` e `test/pokex/sim/runner_test.exs`

**Interfaces:**
- Consumes: `Pokex.Sim.World` (PR 2) · `Pokex.Perception.WorldState.put/3` · `Pokex.Bots.Cavebot.Route`.
- Produces:
  - `Runner.start_link(opts)` — `:name` (default `Pokex.Sim.Runner`, e o default **importa**: é o nome que `Rig.Sim` procura), `:world`, `:tick_ms` (default 50), `:clock` (função `-> integer`, default `&System.monotonic_time/1` em ms — a costura que torna o teste determinístico).
  - `Runner.load(server, %Route{}, opts) :: :ok` · `Runner.play(server) :: :ok` · `Runner.pause(server) :: :ok` · `Runner.world(server) :: World.t()`

**Contexto:**

1. **O tick avança pelo tempo REAL decorrido, não pelos 50ms nominais.** A frota lê fatos com idade medida em `System.monotonic_time`; se o mundo andasse 50ms enquanto o relógio andou 80, cada fato nasceria com idade errada e o `stable_for_ms` da engine mediria fantasia. Guardar `last_at` e passar `now - last_at` para `World.step/2`.

2. **Cada fato tem a cadência dele.** Publicar tudo a cada tick seria mentir sobre o problema mais interessante que o bot tem: fatos de idades diferentes. `:battle` a 120ms, `:pokemon` a 120ms, `:skill_bar` a 400ms, `:minimap` a 500ms, `:mini_game` a 1000ms.

3. **`:mini_game` é publicado de propósito**, com `playing?: false`. Sem ele, `Perception.mini_game_playing?/1` cai em fato ausente, e o `Engine.Worker` para de decidir achando que a cápsula está na tela.

- [ ] **Step 1: Write the failing test** (`test/pokex/sim/runner_test.exs`)

```elixir
defmodule Pokex.Sim.RunnerTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.Cavebot.Route
  alias Pokex.Perception.WorldState
  alias Pokex.Sim.Runner

  defp route do
    %Route{
      name: "sim",
      waypoints:
        for {x, y, z} <- [{100, 200, 5}, {110, 200, 5}] do
          %{
            x: x, y: y, z: z, action: :walk, stops: [], at: nil, dwell_ms: nil,
            park_point: nil, park_tiles: nil, fight_ms: nil, gather_ms: 2_000,
            combo: [], skills: [], gather_wait_ms: nil
          }
        end
    }
  end

  setup do
    for key <- [:battle, :pokemon, :skill_bar, :minimap, :mini_game], do: WorldState.forget(key)
    clock = :counters.new(1, [])
    :counters.put(clock, 1, 0)

    advance = fn ms -> :counters.add(clock, 1, ms) end
    read = fn -> :counters.get(clock, 1) end

    server =
      start_supervised!({Runner, name: nil, tick_ms: 10, clock: read, route: route()})

    %{server: server, advance: advance}
  end

  test "starts paused so nothing moves until asked", %{server: server} do
    refute Runner.playing?(server)
  end

  test "a held key walks the character once it is playing", %{server: server, advance: advance} do
    Runner.play(server)
    send(server, {:sim_rig, {:key_down, "right"}})
    advance.(1_000)
    Runner.tick_now(server)

    {x, _y, _z} = Runner.world(server).pos
    assert x > 100
  end

  test "a paused runner ignores the clock", %{server: server, advance: advance} do
    send(server, {:sim_rig, {:key_down, "right"}})
    advance.(5_000)
    Runner.tick_now(server)

    assert Runner.world(server).pos == {100, 200, 5}
  end

  test "publishes the battle fact on the blackboard", %{server: server} do
    Runner.play(server)
    Runner.tick_now(server)

    assert {:ok, battle} = WorldState.get(:battle, 5_000, System.monotonic_time(:millisecond))
    assert is_list(battle.enemies)
  end

  test "publishes every fact the fleet reads", %{server: server} do
    Runner.play(server)
    Runner.tick_now(server)

    for key <- [:battle, :pokemon, :skill_bar, :minimap, :mini_game] do
      assert {:ok, _obs} = WorldState.get(key, 5_000, System.monotonic_time(:millisecond)),
             "#{key} was never published"
    end
  end

  test "holds a fact until its own cadence is due", %{server: server, advance: advance} do
    Runner.play(server)
    Runner.tick_now(server)
    first = WorldState.age(:minimap, System.monotonic_time(:millisecond))

    advance.(100)
    Runner.tick_now(server)

    assert WorldState.age(:minimap, System.monotonic_time(:millisecond)) >= first
  end

  test "loading a route replaces the world", %{server: server} do
    Runner.load(server, route(), seed: 99)

    assert Runner.world(server).pos == {100, 200, 5}
    assert Runner.world(server).clock == 0
  end
end
```

- [ ] **Step 2: Run it to make sure it fails.** `mix test test/pokex/sim/runner_test.exs` → `module Pokex.Sim.Runner is not available`.
- [ ] **Step 3: Implement `Pokex.Sim.Runner`.** GenServer com `@tick_ms 50`; `handle_info({:sim_rig, action})` chama `World.press/2`; `handle_info(:tick)` calcula `now - last_at`, chama `World.step/2`, publica os fatos vencidos e difunde `{:sim, world}` no tópico `"sim"`; `tick_now/1` é um `call` que roda um tick sob demanda (é o que torna o teste determinístico, em vez de esperar por tempo).
- [ ] **Step 4: `mix test test/pokex/sim/runner_test.exs`** → PASS.
- [ ] **Step 5: Commit** — `git commit -m "o mundo ganha relógio, e cada fato a cadência dele"`

---

## Task 2: A porta de atuação

**Files:** modificar `lib/pokex/sim/fence.ex` e `test/pokex/sim/fence_test.exs`

**Interfaces:** consome `Pokex.Bots.InputGate.state/0` (`%{corner_ok:, focus_ok:, panic_latch:}`), `set_corner_ok/1`, `set_focus_ok/1`.

**Contexto — a razão de existir desta tarefa:**

`Body.hold/1` (`body.ex:228`) consulta `InputGate.allowed?()` = `corner_ok and focus_ok`, e `InputGate.flag/1` devolve **`false` para chave ausente** (`input_gate.ex:110`). Essas duas flags só são escritas pelo `Focus` e pelo `Guardian` — os dois que o `Fence` halta ao armar. Com ele olhando o navegador, `focus_ok` está `false`, o `Body` recusa com `:input_gate_closed`, e **o personagem nunca sai do lugar**. O simulador nasceria morto e mudo.

**A ordem importa e é a mesma de sempre:** a porta abre **depois** das mãos falsas já estarem instaladas, e fecha **antes** de as mãos reais voltarem. Abrir a porta com o rig falso no lugar entrega as teclas ao simulador; abrir antes seria uma janela em que o rig real ainda responde.

`panic_latch` **não** é tocado. Ele é o freio dele, não meu.

- [ ] **Step 1: Write the failing test** (append a `fence_test.exs`)

```elixir
  test "arming opens the actuation gate so the body can walk", ctx do
    fence = start_fence(ctx)
    Pokex.Bots.InputGate.set_focus_ok(false)

    assert Fence.arm(fence) == :ok

    assert Pokex.Bots.InputGate.allowed?()
  end

  test "disarming gives the gate back the way it was", ctx do
    fence = start_fence(ctx)
    Pokex.Bots.InputGate.set_focus_ok(false)
    Pokex.Bots.InputGate.set_corner_ok(true)

    assert Fence.arm(fence) == :ok
    assert Fence.disarm(fence) == :ok

    refute Pokex.Bots.InputGate.state().focus_ok
    assert Pokex.Bots.InputGate.state().corner_ok
  end

  test "arming never touches the panic latch", ctx do
    fence = start_fence(ctx)
    latched = Pokex.Bots.InputGate.panic_latched?()

    assert Fence.arm(fence) == :ok

    assert Pokex.Bots.InputGate.panic_latched?() == latched
  end
```

- [ ] **Step 2: Run to fail.**
- [ ] **Step 3: Implement.** `do_arm/1` guarda `InputGate.state()` no mesmo `:persistent_term` do resto (para sobreviver a um `Fence` morto) e, **depois** dos `put_env`, chama `set_corner_ok(true)` e `set_focus_ok(true)`. `restore/3` devolve as duas flags **depois** do `stop_all` e **antes** dos `put_env` de volta.
- [ ] **Step 4: `mix test test/pokex/sim/fence_test.exs`** → PASS.
- [ ] **Step 5: Commit** — `git commit -m "a porta abre depois das mãos falsas, e fecha antes das reais"`

---

## Task 3: A prova — a frota real no mundo falso

**Files:** criar `test/pokex/sim/fleet_test.exs`

**Contexto:** é o teste que justifica a empreitada inteira. Ele arma a cerca, sobe o `Runner` com a rota, roda ticks, e prova que o **`Engine.Worker` de verdade** — sem uma linha alterada — construiu uma `:situation` a partir do mundo falso e publicou `:orders`.

Se ele passar, o simulador existe.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Pokex.Sim.FleetTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.Engine
  alias Pokex.Perception.WorldState
  alias Pokex.Sim.{Fence, Runner}

  @moduletag :tmp_dir
  @moduletag :capture_log

  test "the real engine builds a picture and gives orders from the fake world" do
    # arm, load, tick, then read what the REAL Engine.Worker published
  end
end
```

- [ ] **Step 2: Run to fail.**
- [ ] **Step 3: Make it pass** — arming, loading the route, running ticks, and starting `Engine.Worker` under the test's own supervisor (never the app-global one: *"an isolated supervisor in a test must never arm the app-global one"*, `bot_supervisor.ex:224`).
- [ ] **Step 4: `mix precommit`** → PASS.
- [ ] **Step 5: Commit and push.**

---

## Definition of done da PR 3

- [ ] O Runner avança o mundo pelo tempo **real** decorrido, não pelo nominal.
- [ ] Cada fato sai na cadência herdada de `Settings`, não todos por tick.
- [ ] `:mini_game` é publicado como `playing?: false` — sem ele a engine para de decidir.
- [ ] `Rig.Sim` → `Runner` → `World.press/2` fecha o laço: a tecla que a frota aperta vira efeito no mundo.
- [ ] A porta de atuação abre **depois** das mãos falsas e fecha **antes** das reais; `panic_latch` intocado.
- [ ] **A `Engine` de verdade publica `:orders` a partir do mundo falso.**
- [ ] `mix precommit` verde.
