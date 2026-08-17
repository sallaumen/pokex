# Simulador fase 1 · PR 2 — o mundo falso

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `Pokex.Sim.World` — o mundo, como função pura. Rota real, passo, escada, mobs com leash, skills com cooldown, e os fatos que a frota vai ler.

**Architecture:** Uma struct e quatro funções: `new/2`, `step/2`, `press/2`, `observe/2`. Zero processo, zero ETS, zero relógio — o tempo entra por parâmetro e o acaso por semente guardada na struct. A caçada inteira vira tabela de teste, e a mesma semente produz a mesma caçada.

**Tech Stack:** Elixir puro. `Pokex.Bots.Cavebot.Route` (a rota real), `Pokex.Bots.Combat.Loadout` (as skills reais), `:rand` com estado explícito.

## Global Constraints

- **Todo código em inglês** — identificadores, comentários e nomes de teste. Strings de produto visíveis ao usuário em pt-BR.
- **Comentários raros e curtos**; nenhum dentro de corpo de teste.
- **Nomes de teste per `~/elixir-references/tavano_rfc.txt`** — comportamento direto, nunca "should".
- **Nunca compilar ou rodar em `~/projects/pokex`.** Worktree: `~/projects/worktrees/mundo-falso`, branch `sim/o-mundo-falso`.
- **`mix precommit` no worktree é o portão.**
- **Nenhum número sem etiqueta.** Todo knob nasce em `@default_knobs` com um comentário de uma linha dizendo `measured` (dos dados dele), `inherited` (de `Settings`/`team.json`) ou `invented` (chute meu). Essa é a regra da empreitada, não estilo.
- **Determinismo é requisito, não conveniência.** Nada de `:rand.uniform/1` sem estado; nada de `System.monotonic_time` dentro de `World`.

---

## Descoberta que muda a PR 3 (registrar, não implementar aqui)

`Body.hold/1` (`body.ex:228`) consulta `InputGate.allowed?()`, que é `corner_ok and focus_ok` e **falha fechado**: `InputGate.flag/1` devolve `false` para chave ausente (`input_gate.ex:110`). Essas flags são escritas **só** por `Focus` (`focus.ex:86,106,132,145,250`) e `Guardian` (`guardian.ex:164`) — os dois que o `Fence` halta ao armar.

Consequência: com o simulador armado e Lucas olhando o navegador, `focus_ok` fica `false`, `Body.hold/1` recusa com `{:error, :input_gate_closed}`, e o personagem **nunca sai do lugar**.

**O conserto é do `Fence` e entra na PR 3:** ao armar, forçar `InputGate.set_corner_ok(true)` e `set_focus_ok(true)` — depois de as mãos falsas já estarem no lugar, nunca antes — e restaurar os valores anteriores ao desarmar. É seguro por construção: abrir a porta com o rig falso instalado entrega as teclas ao simulador, não ao jogo. **Não fazer nada disso nesta PR** — aqui não roda processo nenhum.

---

## File Structure

| arquivo | responsabilidade |
|---|---|
| `lib/pokex/sim/world.ex` (criar) | A struct e as quatro funções. Único arquivo de produção da PR. |
| `test/pokex/sim/world_test.exs` (criar) | Tabela de mesa: passo, escada, mobs, leash, skills, fatos. |
| `docs/superpowers/specs/2026-08-17-simulador-de-cacada-design.md` (modificar) | Registrar a descoberta do `InputGate` na seção 5. |

**Nota sobre tamanho:** `world.ex` vai fechar perto de 300 linhas. Se passar de 400, dividir por responsabilidade (`world/mobs.ex`, `world/facts.ex`) e manter `world.ex` como a fachada — o projeto já sofreu com um arquivo que virou 2.2× o próximo (`cavebot_live.ex`).

---

## Task 1: A struct, `new/2` e o passo

**Files:**
- Create: `lib/pokex/sim/world.ex`
- Test: `test/pokex/sim/world_test.exs`

**Interfaces:**
- Consumes: `Pokex.Bots.Cavebot.Route` (`route.ex:19` — `%Route{name, dungeon, z, enabled?, gather_wait_ms, waypoints}`; cada waypoint é `%{x, y, z, action, stops, fight_ms, gather_ms, combo, skills, ...}`).
- Produces:
  - `Pokex.Sim.World.new(%Route{}, opts) :: t` — `opts` aceita `:seed` (inteiro, default 42) e `:knobs` (mapa que sobrepõe `@default_knobs`).
  - `Pokex.Sim.World.step(t, dt_ms) :: t`
  - `Pokex.Sim.World.press(t, action) :: t` — `action` é exatamente o payload que `Rig.Sim` reporta: `{:key_down, key}`, `{:key_up, key}`, `{:press, key}`, `{:press_many, keys, opts}`, `{:tap, combo}`.
  - Campos lidos pelas tarefas seguintes: `:pos` (`{x, y, z}`), `:clock` (ms desde `new`), `:held` (lista de teclas de direção seguradas), `:mobs`, `:own`, `:keys`, `:rand`, `:knobs`.

**Contexto que o implementador precisa saber:**

1. **A convenção de sinal vem do cavebot, não de mim.** `worker.ex:1025-1030`: `dx > 0 → "right"`, `dy > 0 → "down"`. E `dx` é `alvo - atual`. Logo **`right` aumenta `x` e `down` aumenta `y`**. Errar isso faz o boneco andar para longe de cada esquina e nenhum teste de unidade pega.

2. **O cavebot anda SEGURANDO, não apertando.** `hold_walk/3` chama `body.hold(keys)`, que vira `key_down`/`key_up` no `Rig`. Então o mundo precisa de movimento *contínuo enquanto a tecla está baixa*, não um tile por evento. Duas teclas seguradas (`["right", "down"]`) andam nos dois eixos — a diagonal existe no jogo.

3. **O passo tem resto.** Com `ms_per_tile: 320` e um tick de 50ms, um tile leva 6,4 ticks. Guardar o progresso fracionário (`walk_debt`) em vez de arredondar por tick: arredondar transforma 320ms/tile em 350ms/tile e o erro acumula por uma perna inteira.

4. **`ms_per_tile` é o knob mais fraco que existe aqui.** Ninguém mediu tiles/s neste jogo — `cavebot_measure_walk` existe no `/config` para isso e nunca rodou. Ele nasce marcado `invented` e a tela da PR 4 vai dizer isso ao lado do slider.

- [ ] **Step 1: Write the failing test**

Create `test/pokex/sim/world_test.exs`:

```elixir
defmodule Pokex.Sim.WorldTest do
  use ExUnit.Case, async: true

  alias Pokex.Bots.Cavebot.Route
  alias Pokex.Sim.World

  defp route(waypoints) do
    %Route{
      name: "test",
      waypoints:
        Enum.map(waypoints, fn {x, y, z} ->
          %{
            x: x,
            y: y,
            z: z,
            action: :walk,
            stops: [],
            at: nil,
            dwell_ms: nil,
            park_point: nil,
            park_tiles: nil,
            fight_ms: nil,
            gather_ms: nil,
            combo: [],
            skills: [],
            gather_wait_ms: nil
          }
        end)
    }
  end

  defp straight, do: route([{100, 200, 5}, {110, 200, 5}])

  test "starts the character on the first waypoint" do
    world = World.new(straight())

    assert world.pos == {100, 200, 5}
    assert world.clock == 0
  end

  test "holding right increases x" do
    world =
      straight()
      |> World.new(knobs: %{ms_per_tile: 100})
      |> World.press({:key_down, "right"})
      |> World.step(100)

    assert world.pos == {101, 200, 5}
  end

  test "holding down increases y" do
    world =
      straight()
      |> World.new(knobs: %{ms_per_tile: 100})
      |> World.press({:key_down, "down"})
      |> World.step(100)

    assert world.pos == {100, 201, 5}
  end

  test "holding left and up walk the other way" do
    world =
      straight()
      |> World.new(knobs: %{ms_per_tile: 100})
      |> World.press({:key_down, "left"})
      |> World.press({:key_down, "up"})
      |> World.step(100)

    assert world.pos == {99, 199, 5}
  end

  test "two held keys walk both axes at once" do
    world =
      straight()
      |> World.new(knobs: %{ms_per_tile: 100})
      |> World.press({:key_down, "right"})
      |> World.press({:key_down, "down"})
      |> World.step(300)

    assert world.pos == {103, 203, 5}
  end

  test "releasing a key stops that axis" do
    world =
      straight()
      |> World.new(knobs: %{ms_per_tile: 100})
      |> World.press({:key_down, "right"})
      |> World.step(100)
      |> World.press({:key_up, "right"})
      |> World.step(500)

    assert world.pos == {101, 200, 5}
  end

  test "a partial tick carries its remainder instead of rounding it away" do
    world = World.new(straight(), knobs: %{ms_per_tile: 100})
    world = World.press(world, {:key_down, "right"})

    walked = Enum.reduce(1..10, world, fn _tick, w -> World.step(w, 30) end)

    assert walked.pos == {103, 200, 5}
  end

  test "standing still with nothing held does not move" do
    world = straight() |> World.new() |> World.step(5_000)

    assert world.pos == {100, 200, 5}
  end

  test "the clock advances by what was stepped" do
    world = straight() |> World.new() |> World.step(120) |> World.step(80)

    assert world.clock == 200
  end

  test "the same seed produces the same world" do
    a = World.new(straight(), seed: 7)
    b = World.new(straight(), seed: 7)

    assert a.mobs == b.mobs
  end

  test "different seeds produce different worlds" do
    nest =
      route([{100, 200, 5}, {110, 200, 5}])
      |> Map.update!(:waypoints, fn [first | rest] ->
        [%{first | gather_ms: 2_000} | rest]
      end)

    a = World.new(nest, seed: 7)
    b = World.new(nest, seed: 99)

    refute Enum.map(a.mobs, & &1.pos) == Enum.map(b.mobs, & &1.pos)
  end
end
```

- [ ] **Step 2: Run it to make sure it fails**

```bash
cd ~/projects/worktrees/mundo-falso && mix test test/pokex/sim/world_test.exs
```

Expected: FAIL — `module Pokex.Sim.World is not available`.

- [ ] **Step 3: Write minimal implementation**

Create `lib/pokex/sim/world.ex`:

```elixir
defmodule Pokex.Sim.World do
  @moduledoc """
  The game, as a pure function.

  Four functions and a struct: `new/2` builds a world from one of his REAL
  recorded routes, `step/2` advances it by a number of milliseconds, `press/2`
  turns a key into an effect, and `observe/2` answers what a feed would have
  read. No process, no ETS, no clock, no randomness that is not seeded — the
  time comes in as a parameter and the luck lives in the struct.

  That is what makes a hunt a table test, and what makes the same seed replay
  the same hunt.

  ## Walking is HELD, not tapped

  The cavebot walks with `Body.hold/1` (`worker.ex:968`), which becomes
  `key_down`/`key_up` on the rig. So movement here is continuous while a key is
  down, not one tile per event, and two keys down walk both axes — the diagonal
  is real in the game.

  The sign convention is the cavebot's, not a choice: `worker.ex:1025-1030`
  reads `dx > 0` as "right" and `dy > 0` as "down", with `dx` being target minus
  current. So **right raises x and down raises y**. Getting it backwards walks
  away from every corner and no unit test would notice.

  ## The remainder is kept

  At 320ms per tile a 50ms tick is 0.156 of a tile. Rounding per tick would turn
  320ms/tile into 350ms/tile and the error would compound across a whole leg, so
  the fraction is carried in `walk_debt`.
  """

  alias Pokex.Bots.Cavebot.Route

  @default_knobs %{
    # invented — nobody has ever measured tiles/s in this game; cavebot_measure_walk
    # exists in /config for exactly this and has never been run
    ms_per_tile: 320
  }

  @directions %{"right" => {1, 0}, "left" => {-1, 0}, "down" => {0, 1}, "up" => {0, -1}}

  defstruct route: nil,
            pos: nil,
            held: [],
            walk_debt: 0.0,
            mobs: [],
            own: nil,
            keys: %{},
            clock: 0,
            rand: nil,
            knobs: %{}

  @type t :: %__MODULE__{}

  @spec new(Route.t(), keyword) :: t
  def new(%Route{} = route, opts \\ []) do
    seed = Keyword.get(opts, :seed, 42)
    knobs = Map.merge(@default_knobs, Keyword.get(opts, :knobs, %{}))
    start = List.first(route.waypoints)

    %__MODULE__{
      route: route,
      pos: {start.x, start.y, start.z},
      rand: :rand.seed_s(:exsss, {seed, seed, seed}),
      knobs: knobs
    }
  end

  @spec step(t, non_neg_integer) :: t
  def step(world, dt_ms) do
    world
    |> walk(dt_ms)
    |> Map.update!(:clock, &(&1 + dt_ms))
  end

  @spec press(t, tuple) :: t
  def press(world, {:key_down, key}) when is_map_key(@directions, key),
    do: %{world | held: Enum.uniq(world.held ++ [key])}

  def press(world, {:key_up, key}), do: %{world | held: world.held -- [key]}

  def press(world, _other), do: world

  defp walk(%{held: []} = world, _dt_ms), do: world

  defp walk(world, dt_ms) do
    debt = world.walk_debt + dt_ms / world.knobs.ms_per_tile
    tiles = trunc(debt)

    if tiles == 0 do
      %{world | walk_debt: debt}
    else
      %{world | pos: advance(world.pos, world.held, tiles), walk_debt: debt - tiles}
    end
  end

  defp advance({x, y, z}, held, tiles) do
    {dx, dy} =
      Enum.reduce(held, {0, 0}, fn key, {ax, ay} ->
        {kx, ky} = Map.fetch!(@directions, key)
        {ax + kx, ay + ky}
      end)

    {x + dx * tiles, y + dy * tiles, z}
  end
end
```

- [ ] **Step 4: Run the tests and make sure they pass**

```bash
cd ~/projects/worktrees/mundo-falso && mix test test/pokex/sim/world_test.exs
```

Expected: 8 PASS. **The two seed tests still FAIL** (`a.mobs == b.mobs` passes trivially with `[]`, and the "different seeds" test fails because no mob exists yet) — that is correct: mobs arrive in Task 2. Delete nothing; leave both failing tests in place as the RED for the next task.

- [ ] **Step 5: Commit**

```bash
cd ~/projects/worktrees/mundo-falso && git add lib/pokex/sim/world.ex test/pokex/sim/world_test.exs && git commit -m "o passo, com o resto guardado"
```

---

## Task 2: A escada

**Files:**
- Modify: `lib/pokex/sim/world.ex`
- Test: `test/pokex/sim/world_test.exs`

**Interfaces:**
- Consumes: `World.step/2` e `World.press/2` da tarefa 1.
- Produces: nenhuma função nova. `world.pos` passa a mudar de `z` ao cruzar uma escada, e o campo `:stairs` (lista de `%{at: {x, y, z}, dir: {dx, dy}, to_z: integer}`) é derivado da rota em `new/2`.

**Contexto que o implementador precisa saber (fato de jogo, caro de redescobrir):**

Uma escada é **UMA tecla que anda DOIS tiles** (o degrau e o tile depois) e muda de andar. Lucas marca a esquina imediatamente antes e a imediatamente depois; **o degrau é o ponto médio do par**. O par só é válido quando é limpo: ±2 num eixo e 0 no outro. Pares sujos perderam a posição real da escada no momento da gravação — **não inventar correção para eles**, apenas ignorá-los.

Derivação em `new/2`: para cada par de waypoints consecutivos `a`, `b` com `a.z != b.z`, se `{abs(b.x - a.x), abs(b.y - a.y)}` for `{2, 0}` ou `{0, 2}`, registrar uma escada no ponto médio, com direção `{sign(b.x - a.x), sign(b.y - a.y)}` e `to_z: b.z`. Pares sujos são descartados em silêncio.

- [ ] **Step 1: Write the failing test**

Append to `test/pokex/sim/world_test.exs`:

```elixir
  defp stairway, do: route([{100, 200, 5}, {102, 200, 6}])

  test "derives a stair from a clean pair of waypoints across floors" do
    world = World.new(stairway())

    assert [%{at: {101, 200, 5}, to_z: 6}] = world.stairs
  end

  test "ignores a dirty cross-floor pair instead of guessing the step" do
    world = World.new(route([{100, 200, 5}, {107, 203, 6}]))

    assert world.stairs == []
  end

  test "stepping onto the stair walks two tiles and changes floor" do
    world =
      stairway()
      |> World.new(knobs: %{ms_per_tile: 100})
      |> World.press({:key_down, "right"})
      |> World.step(100)

    assert world.pos == {102, 200, 6}
  end

  test "a stair crossed the other way returns to the floor below" do
    world =
      route([{102, 200, 6}, {100, 200, 5}])
      |> World.new(knobs: %{ms_per_tile: 100})
      |> World.press({:key_down, "left"})
      |> World.step(100)

    assert world.pos == {100, 200, 5}
  end

  test "walking past a stair tile in another direction does not change floor" do
    world =
      stairway()
      |> World.new(knobs: %{ms_per_tile: 100})
      |> World.press({:key_down, "down"})
      |> World.step(300)

    assert world.pos == {100, 203, 5}
  end
```

- [ ] **Step 2: Run it to make sure it fails**

```bash
cd ~/projects/worktrees/mundo-falso && mix test test/pokex/sim/world_test.exs
```

Expected: the five new tests FAIL (`key :stairs not found`).

- [ ] **Step 3: Write minimal implementation**

Add `stairs: []` to the struct, derive them in `new/2`, and apply them in `advance/3`:

```elixir
  # A staircase is ONE key that walks TWO tiles and changes floor; he marks the
  # corner right before and right after, so the step is the midpoint of the pair.
  # Only a CLEAN pair (±2 on one axis, 0 on the other) carries a real position —
  # a dirty pair lost it at recording time, and guessing a correction there is
  # exactly what must not happen.
  defp stairs_of(%Route{waypoints: waypoints}) do
    waypoints
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [a, b] -> stair_between(a, b) end)
  end

  defp stair_between(%{z: z}, %{z: z}), do: []

  defp stair_between(a, b) do
    dx = b.x - a.x
    dy = b.y - a.y

    if {abs(dx), abs(dy)} in [{2, 0}, {0, 2}] do
      [%{at: {a.x + div(dx, 2), a.y + div(dy, 2), a.z}, dir: {sign(dx), sign(dy)}, to_z: b.z}]
    else
      []
    end
  end

  defp sign(0), do: 0
  defp sign(n) when n > 0, do: 1
  defp sign(_n), do: -1
```

Change `advance/3` to take the world, walk one tile at a time, and consult the stairs:

```elixir
  defp advance(world, tiles) do
    {dx, dy} = heading(world.held)

    Enum.reduce(1..tiles//1, world.pos, fn _tile, pos ->
      one_tile(pos, {dx, dy}, world.stairs)
    end)
  end

  defp heading(held) do
    Enum.reduce(held, {0, 0}, fn key, {ax, ay} ->
      {kx, ky} = Map.fetch!(@directions, key)
      {ax + kx, ay + ky}
    end)
  end

  # Landing on the step with the stair's own heading spends ONE key on TWO tiles.
  defp one_tile({x, y, z}, {dx, dy}, stairs) do
    next = {x + dx, y + dy, z}

    case Enum.find(stairs, &(&1.at == next and &1.dir == {dx, dy})) do
      nil -> next
      stair -> {x + dx * 2, y + dy * 2, stair.to_z}
    end
  end
```

Wire `walk/2` to call `advance(world, tiles)` and `new/2` to set `stairs: stairs_of(route)`.

- [ ] **Step 4: Run the tests and make sure they pass**

```bash
cd ~/projects/worktrees/mundo-falso && mix test test/pokex/sim/world_test.exs
```

Expected: all movement and stair tests PASS; the two seed/mob tests still fail (Task 3).

- [ ] **Step 5: Commit**

```bash
cd ~/projects/worktrees/mundo-falso && git add lib/pokex/sim/world.ex test/pokex/sim/world_test.exs && git commit -m "uma tecla, dois tiles, outro andar"
```

---

## Task 3: Os mobs, os ninhos e o leash

**Files:**
- Modify: `lib/pokex/sim/world.ex`
- Test: `test/pokex/sim/world_test.exs`

**Interfaces:**
- Consumes: `World.new/2` e `World.step/2`.
- Produces: `world.mobs :: [%{id, name, pos, hp_pct, spawn, nest}]`, povoado por `new/2` e movido por `step/2`.

**Contexto que o implementador precisa saber:**

1. **Onde os mobs nascem NÃO é chute.** Os ninhos ficam nas esquinas que carregam `gather_ms` ou `fight_ms` — exatamente onde a mão dele parou para mobar ou para matar. A rota gravada já é o mapa de onde há bicho; inventar posições de spawn jogaria fora o único dado espacial confiável que existe.

2. **O leash é a R2 virando mecânica.** *"Se você for muito ganancioso e quiser juntar muitos monstros de uma vez só, fazer eles andarem muito longe de onde eles nasceram, faz eles sumirem."* Um mob cuja distância até o próprio spawn passa de `leash_tiles` **desaparece** — não para, não volta: some. É o teto que a regra dele exige, e ele existe aqui como física do mundo, não como política de ninguém.

3. **Distância é Chebyshev, não euclidiana.** O jogo é uma grade com diagonal; a distância entre `{0,0}` e `{3,3}` é 3 tiles, não 4,24.

- [ ] **Step 1: Write the failing test**

Append to `test/pokex/sim/world_test.exs`:

```elixir
  defp with_nest(waypoints, index, marks) do
    waypoints
    |> route()
    |> Map.update!(:waypoints, fn wps ->
      List.update_at(wps, index, &Map.merge(&1, marks))
    end)
  end

  defp nest_route, do: with_nest([{100, 200, 5}, {110, 200, 5}], 1, %{gather_ms: 2_000})

  test "spawns mobs only around waypoints his hand marked" do
    world = World.new(nest_route(), knobs: %{nest_size: 3, nest_radius: 2})

    assert length(world.mobs) == 3

    for mob <- world.mobs do
      {x, y, z} = mob.pos
      assert abs(x - 110) <= 2
      assert abs(y - 200) <= 2
      assert z == 5
    end
  end

  test "spawns nothing on a route with no gather or fight marks" do
    assert World.new(straight()).mobs == []
  end

  test "a mob within aggro range walks toward the character" do
    world =
      nest_route()
      |> World.new(knobs: %{nest_size: 1, nest_radius: 0, aggro_tiles: 20, mob_ms_per_tile: 100})

    [before] = world.mobs
    walked = World.step(world, 100)
    [after_step] = walked.mobs

    assert distance(after_step.pos, world.pos) < distance(before.pos, world.pos)
  end

  test "a mob outside aggro range stays where it spawned" do
    world =
      nest_route()
      |> World.new(knobs: %{nest_size: 1, nest_radius: 0, aggro_tiles: 2, mob_ms_per_tile: 100})

    [before] = world.mobs
    [after_step] = World.step(world, 500).mobs

    assert after_step.pos == before.pos
  end

  test "a mob dragged past its leash vanishes" do
    world =
      nest_route()
      |> World.new(
        knobs: %{nest_size: 1, nest_radius: 0, aggro_tiles: 99, mob_ms_per_tile: 50, leash_tiles: 3}
      )

    assert length(world.mobs) == 1

    dragged = Enum.reduce(1..40, world, fn _tick, w -> World.step(w, 50) end)

    assert dragged.mobs == []
  end

  test "a mob inside its leash is still there" do
    world =
      nest_route()
      |> World.new(
        knobs: %{nest_size: 1, nest_radius: 0, aggro_tiles: 99, mob_ms_per_tile: 50, leash_tiles: 30}
      )

    kept = Enum.reduce(1..40, world, fn _tick, w -> World.step(w, 50) end)

    assert length(kept.mobs) == 1
  end

  defp distance({x1, y1, _z1}, {x2, y2, _z2}), do: max(abs(x1 - x2), abs(y1 - y2))
```

- [ ] **Step 2: Run it to make sure it fails**

```bash
cd ~/projects/worktrees/mundo-falso && mix test test/pokex/sim/world_test.exs
```

Expected: the new tests FAIL (`world.mobs == []`).

- [ ] **Step 3: Write minimal implementation**

Add to `@default_knobs`:

```elixir
    # invented — a slider on the screen; the PLACE they spawn is not invented
    # (his gather_ms / fight_ms marks), only how many and how far they wander
    nest_size: 4,
    nest_radius: 3,
    aggro_tiles: 8,
    # invented — the same unmeasured tiles/s hole as the character's step
    mob_ms_per_tile: 420,
    # invented number, HIS rule: R2, "fazer eles andarem muito longe de onde
    # eles nasceram faz eles sumirem"
    leash_tiles: 12,
```

Add `spawn_mobs/1` (threading `world.rand` through every draw, never `:rand.uniform/1`), a `mob_debt` per mob mirroring `walk_debt`, and in `step/2` a `move_mobs/2` that: skips mobs on another floor, walks one tile toward the character when within `aggro_tiles` (Chebyshev), and **drops** any mob whose distance from its own `spawn` exceeds `leash_tiles`.

- [ ] **Step 4: Run the tests and make sure they pass**

```bash
cd ~/projects/worktrees/mundo-falso && mix test test/pokex/sim/world_test.exs
```

Expected: all PASS, including the two seed tests from Task 1.

- [ ] **Step 5: Commit**

```bash
cd ~/projects/worktrees/mundo-falso && git add lib/pokex/sim/world.ex test/pokex/sim/world_test.exs && git commit -m "eles nascem onde a mão dele parou, e somem se arrastados"
```

---

## Task 4: As skills, a vida, e `observe/2`

**Files:**
- Modify: `lib/pokex/sim/world.ex`
- Test: `test/pokex/sim/world_test.exs`
- Modify: `docs/superpowers/specs/2026-08-17-simulador-de-cacada-design.md`

**Interfaces:**
- Consumes: `Pokex.Bots.Combat.Loadout` (`loadout.ex:33` — `%Loadout{name, aoe, single, buffs, heal, crowd}`, cada campo uma lista de teclas).
- Produces: `World.observe(t, :battle | :pokemon | :skill_bar | :minimap | :mini_game) :: map`.

**Contexto que o implementador precisa saber — as formas dos fatos são contrato:**

Conferidas contra `perception/interpret.ex:78-90` e `:129`. O mundo falso tem que produzir **exatamente** isto, ou o simulador mente com confiança:

```elixir
# :battle
%{
  enemies: [0, 1, 2],                 # ÍNDICES DE LINHA, não criaturas — Situation conta com length/1
  enemies_detail: [%{row: 0, name: "Venonat", hp_pct: 0.62, shiny?: false}],
  red: nil,
  hp: [],
  locked?: false,
  locked_row: nil,
  shiny_rows: [],
  shiny_star_run: 0
}

# :pokemon   %{hp_pct: 0..100, readable?: true}
# :skill_bar %{ready_keys: ["3", "4"]}
# :minimap   %{pos: {x, y, z}}
# :mini_game %{playing?: false, confidence: 0.0}
```

Duas sutilezas que são a matéria dos bugs:

- **`enemies` é lista de índices de linha.** `Situation.read_battle` faz `length(Map.get(battle, :enemies, []))`. Publicar nomes ali funcionaria por acidente e mentiria na primeira mudança.
- **`nil` é resposta legal.** Tela ilegível não é tela vazia: `enemies: nil` e `enemies: []` são fatos opostos, e `Situation` já trata os dois. A *capacidade* de produzir os dois entra aqui; a *injeção* de ilegibilidade é fase 2.

E o botão que resolve uma medição em aberto: o knob `own_row?` decide se o pokémon dele ocupa uma linha da lista. `interpret.ex:44` registra uma leitura dizendo que não; ele diz que sim. A diferença é 1, e 1 é a distância entre atacar uma pilha e ir embora dela. O mundo falso sabe fazer os dois, e a tela vai deixar ele comparar.

- [ ] **Step 1: Write the failing test**

Append to `test/pokex/sim/world_test.exs`:

```elixir
  defp loadout do
    %Pokex.Bots.Combat.Loadout{
      name: "Vileplume",
      aoe: ["3", "4"],
      single: ["6"],
      buffs: ["2"],
      heal: [],
      crowd: ["1"]
    }
  end

  defp armed_world(knobs \\ %{}) do
    World.new(
      nest_route(),
      knobs: Map.merge(%{nest_size: 3, nest_radius: 1, battle_radius: 99}, knobs),
      loadout: loadout()
    )
  end

  test "every skill starts ready" do
    assert World.observe(armed_world(), :skill_bar) == %{ready_keys: ["1", "2", "3", "4", "6"]}
  end

  test "pressing an area skill puts it on cooldown" do
    world = World.press(armed_world(), {:press, "3"})

    refute "3" in World.observe(world, :skill_bar).ready_keys
    assert "4" in World.observe(world, :skill_bar).ready_keys
  end

  test "a skill comes back after its cooldown" do
    world =
      armed_world(%{skill_cooldown_ms: 1_000})
      |> World.press({:press, "3"})
      |> World.step(1_000)

    assert "3" in World.observe(world, :skill_bar).ready_keys
  end

  test "an area skill damages every mob in range" do
    before = armed_world()
    after_hit = World.press(before, {:press, "3"})

    assert Enum.all?(after_hit.mobs, & &1.hp_pct < 100)
  end

  test "an area skill kills the mobs it finishes" do
    world = armed_world(%{aoe_damage: 100})

    assert World.press(world, {:press, "3"}).mobs == []
  end

  test "battle rows are the mobs inside the battle radius" do
    world = armed_world(%{battle_radius: 99})

    assert World.observe(world, :battle).enemies == [0, 1, 2]
    assert length(World.observe(world, :battle).enemies_detail) == 3
  end

  test "a mob outside the battle radius is not on the list" do
    world = armed_world(%{battle_radius: 0})

    assert World.observe(world, :battle).enemies == []
  end

  test "own_row? puts his pokemon on the list without making it an enemy" do
    world = armed_world(%{own_row?: true})
    battle = World.observe(world, :battle)

    assert length(battle.enemies) == 4
    assert Enum.any?(battle.enemies_detail, &(&1.name == "Vileplume"))
  end

  test "the minimap fact carries the position" do
    world = armed_world()

    assert World.observe(world, :minimap) == %{pos: world.pos}
  end

  test "the pokemon fact carries readable health" do
    assert World.observe(armed_world(), :pokemon) == %{hp_pct: 100, readable?: true}
  end

  test "the mini game fact is published as not playing" do
    assert World.observe(armed_world(), :mini_game) == %{playing?: false, confidence: 0.0}
  end

  test "an unreadable screen answers nil enemies rather than zero" do
    world = armed_world(%{readable?: false})
    battle = World.observe(world, :battle)

    assert battle.enemies == nil
    assert World.observe(world, :pokemon) == %{hp_pct: nil, readable?: false}
  end

  test "an adjacent mob bites the pokemon" do
    world =
      armed_world(%{nest_size: 1, nest_radius: 0, aggro_tiles: 99, mob_ms_per_tile: 50,
                    bite_dmg: 5, bite_every_ms: 100, leash_tiles: 99})

    bitten = Enum.reduce(1..60, world, fn _tick, w -> World.step(w, 50) end)

    assert bitten.own.hp_pct < 100
  end
```

- [ ] **Step 2: Run it to make sure it fails**

```bash
cd ~/projects/worktrees/mundo-falso && mix test test/pokex/sim/world_test.exs
```

Expected: the new tests FAIL (`function Pokex.Sim.World.observe/2 is undefined`).

- [ ] **Step 3: Write minimal implementation**

Add to `@default_knobs`:

```elixir
    # inherited — the real cooldowns live in team.json; this is the fallback for
    # a loadout that does not name one
    skill_cooldown_ms: 8_000,
    # invented — sliders
    aoe_damage: 34,
    aoe_radius: 4,
    single_damage: 22,
    battle_radius: 7,
    bite_dmg: 4,
    bite_every_ms: 900,
    # HIS open measurement, not a knob I get to settle: interpret.ex:44 records a
    # reading saying his pokemon does NOT take a row; he says it always does
    own_row?: false,
    readable?: true
```

`new/2` gains `:loadout`. `press/2` gains `{:press, key}`, `{:press_many, keys, _opts}` and `{:tap, combo}`, each resolving the key through the loadout: `aoe` damages every mob within `aoe_radius`, `single` damages the nearest, `crowd` is the reserved control key, and every fired key goes on cooldown. `step/2` gains the bite. `observe/2` builds the five facts in the shapes above, with `readable?: false` collapsing `:battle` to `enemies: nil, enemies_detail: []` and `:pokemon` to `hp_pct: nil`.

- [ ] **Step 4: Run the full gate**

```bash
cd ~/projects/worktrees/mundo-falso && mix precommit
```

Expected: PASS, zero warnings.

- [ ] **Step 5: Record the InputGate discovery in the spec**

In `docs/superpowers/specs/2026-08-17-simulador-de-cacada-design.md`, section 5 ("A cerca"), add under "Armar", after the step that halts Guardian and the focus watcher:

> **E abre a porta de atuação.** `Body.hold/1` consulta `InputGate.allowed?()`, que é `corner_ok and focus_ok` e falha fechado — e essas duas flags só são escritas pelo `Focus` e pelo `Guardian`, que acabaram de ser haltados. Com Lucas olhando o navegador, `focus_ok` está `false` e o personagem nunca sai do lugar. Então armar força as duas para `true` — **depois** das mãos falsas, nunca antes — e desarmar restaura o que havia. É seguro por construção: a porta aberta com o rig falso instalado entrega as teclas ao simulador, não ao jogo. (Descoberto ao desenhar a PR 2; entra na PR 3.)

- [ ] **Step 6: Commit and push**

```bash
cd ~/projects/worktrees/mundo-falso && git add -A && git commit -m "o que a tela mostraria, na forma exata que o interpretador produz" && git push
```

---

## Definition of done da PR 2

- [ ] `World` é pura: nenhum `System.monotonic_time`, nenhum `:rand.uniform/1` sem estado, nenhum processo. Mesma semente ⇒ mesma caçada.
- [ ] O passo guarda o resto (10 ticks de 30ms a 100ms/tile andam 3 tiles, não 0 nem 10).
- [ ] `right` aumenta `x`, `down` aumenta `y` — a convenção do cavebot, não outra.
- [ ] A escada anda dois tiles com uma tecla e muda de andar; par sujo é ignorado sem palpite.
- [ ] Mobs nascem só nas esquinas que a mão dele marcou; passar do leash faz sumir.
- [ ] `observe/2` produz as cinco formas exatas de `interpret.ex`, e `enemies` é lista de índices.
- [ ] `readable?: false` produz `enemies: nil`, não `enemies: []`.
- [ ] Todo knob tem etiqueta `measured` / `inherited` / `invented` no `@default_knobs`.
- [ ] `mix precommit` verde.
- [ ] **Nada publica fato ainda** — o `Runner` é a PR 3.
