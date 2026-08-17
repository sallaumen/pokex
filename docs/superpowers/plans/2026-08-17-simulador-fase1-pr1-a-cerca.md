# Simulador fase 1 · PR 1 — a cerca

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Erguer a cerca do simulador — mãos falsas (`Pokex.Rig.Sim`), o dono do estado armado (`Pokex.Sim.Fence`) e a recusa do `start_all` — **antes** de existir qualquer coisa que precise ser cercada.

**Architecture:** `Rig.impl/0` é o único gargalo por onde algo sai deste programa para o Mac (`Body.execute/1`, `Combat` e `Capture` todos passam por ele). Trocá-lo por um módulo que não referencia o SO fecha todas as portas de uma vez. O `Fence` é um GenServer supervisionado que faz essa troca numa ordem fixa, guarda o que trocou em `:persistent_term` (para sobreviver ao próprio reinício) e expõe `armed?/0` como leitura sem processo — o mesmo padrão do `InputGate`.

**Tech Stack:** Elixir/OTP, Phoenix 1.8, ExUnit, `:beam_lib` (para o teste estrutural de vazamento).

## Global Constraints

- **Todo código em inglês** — identificadores, comentários e nomes de teste. Sem exceção para código novo.
- **Strings de produto visíveis ao usuário em pt-BR** (feed, motivos de alarme, texto de UI). Asserções que casam com essas strings mantêm o texto pt-BR.
- **Comentários são raros e curtos** — só o que registra uma restrição não óbvia ou um fato medido. Nenhum comentário dentro de corpo de teste.
- **Nomes de teste seguem `~/elixir-references/tavano_rfc.txt`:** dizem o comportamento direto ("returns X when Y"), nunca "should", numeração por underscore para variantes.
- **Nunca compilar ou rodar nada em `~/projects/pokex`.** Todo trabalho no worktree `~/projects/worktrees/simulador`, branch `sim/mundo-que-eu-controlo`.
- **`defp` nunca entre cláusulas de `handle_call`/`handle_info`** — mata o compile com `--warnings-as-errors` sem que `mix test`, credo ou dialyzer vejam.
- **`mix precommit` no worktree é o portão**, e roda antes de qualquer commit final. Se a máquina estiver carregada (várias sessões de IA), um vermelho de timeout nos módulos de visão significa "medir de novo numa máquina quieta", nunca "aumentar o timeout".
- Testes que tocam nomes globais (`Application.put_env`, `:persistent_term`, `Pokex.Rig`) são `async: false`.

---

## File Structure

| arquivo | responsabilidade |
|---|---|
| `lib/pokex/rig/sim.ex` (criar) | As mãos falsas. Implementa os 16 callbacks de `Pokex.Rig`; reporta cada ação ao processo registrado como `Pokex.Sim.Runner` (quando existir) e devolve constantes seguras. Nenhuma referência ao SO. |
| `lib/pokex/sim/fence.ex` (criar) | O dono do estado armado. `arm/1`, `disarm/1`, `armed?/0`, restauração ordenada em `terminate/2` e recuperação em `init/1`. |
| `lib/pokex/bots/bot_supervisor.ex` (modificar, `start_all/0` na linha 312) | Recusa iniciar a frota real enquanto a cerca estiver de pé. |
| `lib/pokex/application.ex` (modificar) | Põe o `Fence` na árvore de supervisão. |
| `test/pokex/rig/sim_test.exs` (criar) | Comportamento dos callbacks + o teste estrutural de vazamento. |
| `test/pokex/sim/fence_test.exs` (criar) | Ordem de armar/desarmar, recusa, e a recuperação depois de morrer. |
| `test/pokex/bots/bot_supervisor_test.exs` (modificar) | A recusa do `start_all`. |

---

## Task 1: `Pokex.Rig.Sim` — as mãos falsas

**Files:**
- Create: `lib/pokex/rig/sim.ex`
- Test: `test/pokex/rig/sim_test.exs`

**Interfaces:**
- Consumes: o behaviour `Pokex.Rig` (16 callbacks, em `lib/pokex/rig.ex:10-48`).
- Produces: `Pokex.Rig.Sim`, um módulo sem estado. Toda ação vira `send(runner_pid, {:sim_rig, action})` quando `Pokex.Sim.Runner` estiver registrado; nada acontece quando não estiver. As tarefas 2 e 3 só dependem do **nome do módulo**; a PR 3 (o `Runner`) é quem vai consumir `{:sim_rig, action}`.

**Contexto que o implementador precisa saber:**

`Pokex.Corner.in_kill_corner?/1` (em `lib/pokex/bots/corner.ex:11`) define o canto de pânico como `x <= 10 and y <= 10` — o topo-esquerdo da tela. Um `cursor_position/0` devolvendo `{0, 0}` seria reportar pânico eterno ao Guardian. O ponto devolvido precisa estar longe dos dois cantos (o de pânico, topo-esquerdo, e o de comando, topo-direito).

- [ ] **Step 1: Write the failing test**

Create `test/pokex/rig/sim_test.exs`:

```elixir
defmodule Pokex.Rig.SimTest do
  use ExUnit.Case, async: false

  alias Pokex.Rig.Sim

  setup do
    Process.register(self(), Pokex.Sim.Runner)
    on_exit(fn -> :ok end)
    :ok
  end

  test "reports a press to the runner and answers ok" do
    assert Sim.press("3") == :ok
    assert_receive {:sim_rig, {:press, "3"}}
  end

  test "reports press_many with its options" do
    assert Sim.press_many(["3", "4"], gap_ms: 60) == :ok
    assert_receive {:sim_rig, {:press_many, ["3", "4"], [gap_ms: 60]}}
  end

  test "reports holds and releases separately" do
    assert Sim.key_down("left") == :ok
    assert Sim.key_up("left") == :ok
    assert_receive {:sim_rig, {:key_down, "left"}}
    assert_receive {:sim_rig, {:key_up, "left"}}
  end

  test "refuses every capture instead of returning a fake frame" do
    assert Sim.capture_screen() == {:error, :simulated}
    assert Sim.capture({0, 0, 10, 10}, "x.png") == {:error, :simulated}
  end

  test "cursor_position never reports the panic corner" do
    {:ok, point} = Sim.cursor_position()
    refute Pokex.Corner.in_kill_corner?(point)
  end

  test "cursor_position never reports the command corner" do
    {:ok, {x, _y} = point} = Sim.cursor_position()
    refute Pokex.Corner.in_command_corner?(point, x + 500)
  end

  test "answers every callback when no runner is registered" do
    Process.unregister(Pokex.Sim.Runner)

    assert Sim.press("3") == :ok
    assert Sim.click(:left, {5, 5}) == :ok
    assert Sim.move({5, 5}) == :ok
    assert Sim.tap("shift+3") == :ok
    assert Sim.focus_click({5, 5}) == :ok
    assert Sim.capture_sequence({5, 5}) == :ok
    assert Sim.hold_latency_ms() == 0
    assert {:ok, %{count: 0}} = Sim.middle_watch()
    assert Sim.key_watch([1, 2]) == {:ok, []}
  end

  test "reaches nothing outside the beam" do
    imports = imports_of(Pokex.Rig.Sim)
    modules = imports |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    refute Pokex.Rig.Mac in modules
    refute System in modules
    refute :os in modules
    refute {:erlang, :open_port, 2} in imports
  end

  defp imports_of(module) do
    path = :code.which(module)
    {:ok, {^module, [imports: imports]}} = :beam_lib.chunks(path, [:imports])
    imports
  end
end
```

- [ ] **Step 2: Run it to make sure it fails**

```bash
cd ~/projects/worktrees/simulador && mix test test/pokex/rig/sim_test.exs
```

Expected: FAIL — `Pokex.Rig.Sim is not available` / `module Pokex.Rig.Sim is not loaded`.

- [ ] **Step 3: Implement the minimal code to make the test pass**

Create `lib/pokex/rig/sim.ex`:

```elixir
defmodule Pokex.Rig.Sim do
  @moduledoc """
  The hands, pointed at a world that is not the game.

  `Rig.impl/0` is the ONE place anything leaves this program for the Mac —
  `Body.execute/1` dispatches every action through it, `Combat` calls
  `press_many` directly, and `Capture` calls `capture_screen`. So swapping this
  module closes every door at once, and there is no side path to remember.

  Nothing here reaches the operating system, and that is not a promise: a test
  reads this module's import chunk and fails if `Pokex.Rig.Mac`, `System`, `:os`
  or `:erlang.open_port/2` ever appear in it.

  Actions are REPORTED, not swallowed: whatever is registered as
  `Pokex.Sim.Runner` receives `{:sim_rig, action}` and turns it into an effect in
  the simulated world. With nothing registered every callback still answers
  normally — the fleet must never notice that its hands are simulated.

  ## Why the cursor sits where it does

  `Pokex.Corner.in_kill_corner?/1` reads the top-left corner as the panic corner
  (`x <= 10 and y <= 10`), and the top-right one as the command corner. A cursor
  reported at the origin would be a permanent panic order. This one sits far
  from both on purpose.
  """
  @behaviour Pokex.Rig

  @runner Pokex.Sim.Runner
  @cursor {640, 480}

  @impl true
  def press(key), do: report({:press, key})

  @impl true
  def press_many(keys, opts), do: report({:press_many, keys, opts})

  @impl true
  def key_down(key), do: report({:key_down, key})

  @impl true
  def key_up(key), do: report({:key_up, key})

  @impl true
  def hold_latency_ms, do: 0

  @impl true
  def click(button, point), do: report({:click, button, point})

  @impl true
  def move(point), do: report({:move, point})

  @impl true
  def tap(combo), do: report({:tap, combo})

  @impl true
  def focus_click(point), do: report({:focus_click, point})

  @impl true
  def capture_sequence(point), do: report({:capture_sequence, point})

  # A simulated frame would be a lie with a real shape: the interpreters would
  # read pixels that mean nothing. The simulator publishes FACTS instead, so the
  # honest answer here is a refusal.
  @impl true
  def capture(_region, _filename), do: {:error, :simulated}

  @impl true
  def capture_screen, do: {:error, :simulated}

  @impl true
  def cursor_position, do: {:ok, @cursor}

  @impl true
  def middle_watch, do: {:ok, %{count: 0, point: @cursor, at: nil}}

  @impl true
  def key_watch(_codes), do: {:ok, []}

  defp report(action) do
    case Process.whereis(@runner) do
      nil -> :ok
      pid -> send(pid, {:sim_rig, action})
    end

    :ok
  end
end
```

- [ ] **Step 4: Run the tests and make sure they pass**

```bash
cd ~/projects/worktrees/simulador && mix test test/pokex/rig/sim_test.exs
```

Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
cd ~/projects/worktrees/simulador && git add lib/pokex/rig/sim.ex test/pokex/rig/sim_test.exs && git commit -m "as mãos que não alcançam o Mac"
```

---

## Task 2: `Pokex.Sim.Fence` — o dono do estado armado

**Files:**
- Create: `lib/pokex/sim/fence.ex`
- Test: `test/pokex/sim/fence_test.exs`

**Interfaces:**
- Consumes: `Pokex.Rig.Sim` (tarefa 1) · `Pokex.Bots.BotSupervisor.status/0`, `active?/1` (`bot_supervisor.ex:536` e `:621`) e `stop_all/1` (`:506`).
- Produces:
  - `Pokex.Sim.Fence.arm(server \\ __MODULE__) :: :ok | {:error, [atom]}` — a lista são os workers que impedem, por nome (`:cavebot`, `:combat`, …).
  - `Pokex.Sim.Fence.disarm(server \\ __MODULE__) :: :ok`
  - `Pokex.Sim.Fence.armed?() :: boolean` — **leitura sem processo** (`:persistent_term`), para a tarefa 3 poder chamá-la de dentro do `start_all` sem um `GenServer.call`.
  - `Pokex.Sim.Fence.start_link/1` aceita `:name` (`nil` = sem registro), `:status` (função `-> map` no formato de `BotSupervisor.status/0`) e `:stop_all` (função `binary -> :ok`). As duas últimas são as costuras de teste: existem porque a alternativa é um teste que para a frota do app de verdade em cada teardown.

**Contexto que o implementador precisa saber:**

1. **Por que `:persistent_term` e não um `GenServer.call`.** O AGENTS.md proíbe `GenServer.call` num worker a partir de um processo que precisa sobreviver, e `start_all/0` é chamado de dentro de uma `Task` do Guardian e do `Focus`. O `InputGate` já resolve isso lendo um flag sem processo, e esta é a mesma forma. `:persistent_term` é certo aqui porque armar acontece poucas vezes por dia (a escrita faz varredura global; a leitura é de graça).

2. **A ordem é a cerca, não a intenção.** Copiada do caminho de pânico: *"o latch é erguido ANTES de qualquer coisa ser parada"*. Ao armar, o flag sobe primeiro (nada consegue mais iniciar a frota) e as mãos falsas entram em seguida (pega o que já estava em voo). Ao desarmar, a frota para primeiro e as mãos reais só voltam depois — e o flag é a última coisa a cair, então ele protege durante toda a restauração.

3. **O flag precisa sobreviver ao próprio `Fence` morrer.** Por isso o que foi trocado é guardado em `:persistent_term`, não só no estado do GenServer: um `Process.exit(pid, :kill)` pula o `terminate/2`, e o `init/1` do substituto precisa saber o que devolver.

4. **`arm/1` pode demorar.** `BotSupervisor.status/0` faz `GenServer.call` em seis workers com 1s de timeout cada. Por isso `arm/1` usa timeout de 15s — e é por isso que a LiveView, na PR 4, vai chamá-la de dentro de um `Task`, nunca direto no `handle_event`.

- [ ] **Step 1: Write the failing test**

Create `test/pokex/sim/fence_test.exs`:

```elixir
defmodule Pokex.Sim.FenceTest do
  use ExUnit.Case, async: false

  alias Pokex.Sim.Fence

  @env_keys [:rig, :perception_feeds_active, :journal_persist]

  setup do
    saved = Map.new(@env_keys, fn key -> {key, Application.get_env(:pokex, key)} end)
    test = self()

    on_exit(fn ->
      :persistent_term.erase({Fence, :arm_state})
      Enum.each(saved, &put_env/1)
    end)

    stop_all = fn reason ->
      send(test, {:stopped, reason, Pokex.Rig.impl()})
      :ok
    end

    %{original: saved.rig, stop_all: stop_all}
  end

  defp put_env({key, nil}), do: Application.delete_env(:pokex, key)
  defp put_env({key, value}), do: Application.put_env(:pokex, key, value)

  defp start_fence(ctx, opts \\ []) do
    running = Keyword.get(opts, :running, [])

    start_supervised!(
      {Fence, name: nil, status: fn -> status_of(running) end, stop_all: ctx.stop_all},
      id: Keyword.get(opts, :id, :fence)
    )
  end

  defp status_of(running) do
    Map.new([:fishing, :combat, :catcher, :mini_game, :player_support, :cavebot], fn name ->
      {name, %{state: if(name in running, do: :walking, else: :idle)}}
    end)
  end

  test "arming swaps the hands for the simulated rig", ctx do
    fence = start_fence(ctx)

    assert Fence.arm(fence) == :ok
    assert Pokex.Rig.impl() == Pokex.Rig.Sim
  end

  test "arming turns the perception feeds off", ctx do
    fence = start_fence(ctx)

    assert Fence.arm(fence) == :ok
    assert Application.get_env(:pokex, :perception_feeds_active) == false
  end

  test "arming keeps the simulation out of the journal on disk", ctx do
    fence = start_fence(ctx)

    assert Fence.arm(fence) == :ok
    assert Application.get_env(:pokex, :journal_persist) == false
  end

  test "arming refuses while a worker is running, naming it", ctx do
    fence = start_fence(ctx, running: [:cavebot])

    assert Fence.arm(fence) == {:error, [:cavebot]}
    refute Fence.armed?()
  end

  test "arming refuses without touching the hands", ctx do
    fence = start_fence(ctx, running: [:combat])
    before = Pokex.Rig.impl()

    assert {:error, _names} = Fence.arm(fence)
    assert Pokex.Rig.impl() == before
  end

  test "arming never stops a running fleet on its own", ctx do
    fence = start_fence(ctx, running: [:cavebot])

    assert {:error, _names} = Fence.arm(fence)
    refute_receive {:stopped, _reason, _rig}
  end

  test "armed? answers without asking the process", ctx do
    fence = start_fence(ctx)
    refute Fence.armed?()

    assert Fence.arm(fence) == :ok
    assert Fence.armed?()
  end

  test "disarming gives the real hands back", ctx do
    fence = start_fence(ctx)
    assert Fence.arm(fence) == :ok

    assert Fence.disarm(fence) == :ok
    assert Application.get_env(:pokex, :rig) == ctx.original
    refute Fence.armed?()
  end

  test "disarming stops the fleet before the real hands come back", ctx do
    fence = start_fence(ctx)
    assert Fence.arm(fence) == :ok

    assert Fence.disarm(fence) == :ok

    assert_receive {:stopped, "simulação desarmada", Pokex.Rig.Sim}
    assert Application.get_env(:pokex, :rig) == ctx.original
  end

  test "arming twice is a no-op rather than a second swap", ctx do
    fence = start_fence(ctx)

    assert Fence.arm(fence) == :ok
    assert Fence.arm(fence) == :ok
    assert Fence.disarm(fence) == :ok
    assert Application.get_env(:pokex, :rig) == ctx.original
  end

  test "disarming an unarmed fence touches nothing", ctx do
    fence = start_fence(ctx)

    assert Fence.disarm(fence) == :ok
    refute_receive {:stopped, _reason, _rig}
    assert Application.get_env(:pokex, :rig) == ctx.original
  end

  @tag :capture_log
  test "a fence killed while armed leaves the next one to stop the fleet first", ctx do
    {:ok, fence} =
      Fence.start_link(name: nil, status: fn -> status_of([]) end, stop_all: ctx.stop_all)

    Process.unlink(fence)
    assert Fence.arm(fence) == :ok
    assert Pokex.Rig.impl() == Pokex.Rig.Sim

    ref = Process.monitor(fence)
    Process.exit(fence, :kill)
    assert_receive {:DOWN, ^ref, :process, ^fence, :killed}
    assert Fence.armed?()

    revived = start_fence(ctx, id: :revived)

    assert_receive {:stopped, _reason, Pokex.Rig.Sim}

    :sys.get_state(revived)

    refute Fence.armed?()
    assert Application.get_env(:pokex, :rig) == ctx.original
  end
end
```

**Duas armadilhas que este teste tem, e ambas já foram pagas uma vez:**

1. **`assert_receive {:stopped, …}` casa com o COMEÇO do restore, não com o fim.** `stop_all` é a primeira coisa que `restore/3` faz; apagar a flag é a última. Conferir `armed?/0` logo depois do `assert_receive` lê o meio da operação e reprova um código correto. O `:sys.get_state(revived)` resolve de forma determinística: a chamada fica atrás do `handle_continue` na fila do processo. Nunca `Process.sleep`.

2. **A recuperação loga de propósito**, então o teste leva `@tag :capture_log` — a suíte deste projeto trata log escapado como achado, não como ruído.

- [ ] **Step 2: Run it to make sure it fails**

```bash
cd ~/projects/worktrees/simulador && mix test test/pokex/sim/fence_test.exs
```

Expected: FAIL — `module Pokex.Sim.Fence is not available`.

- [ ] **Step 3: Implement the minimal code to make the test pass**

Create `lib/pokex/sim/fence.ex`:

```elixir
defmodule Pokex.Sim.Fence do
  @moduledoc """
  The one owner of "the simulator is armed", and the order in which it happens.

  Arming points the fleet's eyes and hands at a world that is not the game. That
  is three global switches (`:rig`, `:perception_feeds_active`, `:journal_persist`),
  and the danger is never the switches themselves — it is the window where half
  of them are flipped.

  So the order is copied from the panic path, where the same lesson was already
  paid for: the latch goes UP before anything is stopped, and comes DOWN only
  after everything is. Here that reads:

    * **Arming** — the flag first (nothing can start the real fleet any more),
      then the simulated hands (whatever was already in flight lands in the fake
      world), then the eyes, then the journal.
    * **Disarming** — the fleet stops first, and the real hands come back only
      after it has. The flag falls LAST, so it keeps guarding through the whole
      restore.

  ## Why the state lives outside the process

  `armed?/0` is read from inside `BotSupervisor.start_all/0`, which runs in the
  Guardian's Task and in `Focus` — processes that must not `GenServer.call`
  anything (AGENTS.md). So the answer lives in `:persistent_term`, the same
  shape `InputGate` uses for the panic latch: readable by anyone, costing no
  message.

  It also has to SURVIVE this process dying. A `Process.exit(pid, :kill)` skips
  `terminate/2`, and a replacement that could not tell what to restore would
  leave the fleet with simulated hands and nobody simulating. So what was
  swapped is stored there too, and `init/1` reads it: fleet halted first, hands
  returned after.

  Never the LiveView's job. A closed browser tab must never be able to hand the
  keyboard back to the game with a fleet still walking.
  """
  use GenServer

  require Logger

  alias Pokex.Bots.BotSupervisor

  @pt {__MODULE__, :arm_state}
  @arm_timeout_ms 15_000

  # A KEYWORD LIST, not a map: the order is the fence. The hands go first so
  # anything already in flight lands in the fake world; the eyes and the journal
  # follow. A map would iterate in whatever order the runtime likes.
  @swaps [rig: Pokex.Rig.Sim, perception_feeds_active: false, journal_persist: false]

  def start_link(opts \\ []) do
    state = %{
      status: Keyword.get(opts, :status, &BotSupervisor.status/0),
      stop_all: Keyword.get(opts, :stop_all, &BotSupervisor.stop_all/1)
    }

    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, state)
      name -> GenServer.start_link(__MODULE__, state, name: name)
    end
  end

  @doc """
  Arms the simulator, or refuses naming the workers that are running.

  Never stops a hunt on its own: interrupting eight hours of hunting is too
  expensive to be the side effect of a click meant for something else. The
  caller offers "stop everything and arm" as a separate, explicit action.
  """
  @spec arm(GenServer.server()) :: :ok | {:error, [atom]}
  def arm(server \\ __MODULE__), do: GenServer.call(server, :arm, @arm_timeout_ms)

  @spec disarm(GenServer.server()) :: :ok
  def disarm(server \\ __MODULE__), do: GenServer.call(server, :disarm, @arm_timeout_ms)

  @doc "Is the simulator armed? Reads no process — see the moduledoc."
  @spec armed?() :: boolean
  def armed?, do: :persistent_term.get(@pt, nil) != nil

  @impl true
  def init(state) do
    Process.flag(:trap_exit, true)
    {:ok, state, {:continue, :recover}}
  end

  @impl true
  def handle_continue(:recover, state) do
    case :persistent_term.get(@pt, nil) do
      nil ->
        {:noreply, state}

      saved ->
        Logger.warning(
          "cerca do simulador reiniciou armada — parando a frota e devolvendo as mãos"
        )

        restore(state, saved, "a cerca do simulador reiniciou")
        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:arm, _from, state) do
    if armed?() do
      {:reply, :ok, state}
    else
      {:reply, do_arm(state), state}
    end
  end

  def handle_call(:disarm, _from, state) do
    case :persistent_term.get(@pt, nil) do
      nil -> {:reply, :ok, state}
      saved -> {:reply, restore(state, saved, "simulação desarmada"), state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    case :persistent_term.get(@pt, nil) do
      nil -> :ok
      saved -> restore(state, saved, "a cerca do simulador saiu")
    end
  end

  defp do_arm(state) do
    case running(state) do
      [] ->
        saved = Map.new(@swaps, fn {key, _to} -> {key, Application.get_env(:pokex, key)} end)
        :persistent_term.put(@pt, saved)
        Enum.each(@swaps, fn {key, to} -> Application.put_env(:pokex, key, to) end)
        :ok

      names ->
        {:error, names}
    end
  end

  defp running(state) do
    state.status.()
    |> Enum.filter(fn {_name, snapshot} -> BotSupervisor.active?(snapshot) end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  # The fleet stops FIRST and the hands come back after: a worker still deciding
  # with the real rig restored under it is the one outcome this module exists to
  # make impossible. The flag falls LAST, so it guards through the whole restore.
  defp restore(state, saved, reason) do
    state.stop_all.(reason)
    Enum.each(saved, &put_env/1)
    :persistent_term.erase(@pt)
    :ok
  end

  defp put_env({key, nil}), do: Application.delete_env(:pokex, key)
  defp put_env({key, value}), do: Application.put_env(:pokex, key, value)
end
```

- [ ] **Step 4: Run the tests and make sure they pass**

```bash
cd ~/projects/worktrees/simulador && mix test test/pokex/sim/fence_test.exs
```

Expected: PASS, 12 tests.

- [ ] **Step 5: Commit**

```bash
cd ~/projects/worktrees/simulador && git add lib/pokex/sim/fence.ex test/pokex/sim/fence_test.exs && git commit -m "a cerca sobe antes do que ela cerca"
```

---

## Task 3: `start_all/0` recusa enquanto a cerca estiver de pé

**Files:**
- Modify: `lib/pokex/bots/bot_supervisor.ex:312-321` (`start_all/0`)
- Test: `test/pokex/bots/bot_supervisor_test.exs` (adicionar ao arquivo existente)

**Interfaces:**
- Consumes: `Pokex.Sim.Fence.armed?/0` (tarefa 2).
- Produces: `BotSupervisor.start_all/0` passa a devolver `{:error, [String.t()]}` quando a cerca está armada — a mesma forma que ele já usa para recusa de preflight, então `panel_live.ex:248` não muda.

**Contexto que o implementador precisa saber:**

`start_all/0` é o **único** ponto de entrada usado em produção — os três chamadores são `panel_live.ex:248` (o botão Iniciar), `focus.ex:178` (o re-arme automático quando a janela do jogo volta pra frente) e `guardian.ex:319`. As aridades maiores só são usadas por testes com supervisores isolados e, na PR 3, pelo próprio simulador para subir a frota **depois** de armar — por isso a guarda fica aqui e não em `run_chain/2`.

O chamador que mais importa é o `focus.ex:178`: sem esta guarda, trazer a janela do PXG pra frente com o simulador armado subiria a frota real por conta própria. Esse é o único cenário que machuca de verdade, e é este passo que o fecha.

A mensagem de recusa é string de produto e fica em pt-BR.

**Por que o segundo teste usa `case` e não `assert :ok`:** desarmado, `start_all/0` ainda pode recusar por preflight/calibração no ambiente de teste — e isso é legítimo. O que o teste prova é que a recusa **deixou de ser a do simulador**, não que a frota sobe. Um `assert :ok` aqui passaria a depender do estado de calibração da máquina, que é exatamente o tipo de teste que fica vermelho por motivo errado.

- [ ] **Step 1: Write the failing test**

Append to `test/pokex/bots/bot_supervisor_test.exs`, inside the existing `describe` block or as a new one:

```elixir
  describe "start_all/0 with the simulator armed" do
    setup do
      on_exit(fn ->
        :persistent_term.erase({Pokex.Sim.Fence, :arm_state})
        BotSupervisor.stop_all("fim do teste")
      end)

      :ok
    end

    test "refuses to start the real fleet" do
      :persistent_term.put({Pokex.Sim.Fence, :arm_state}, %{rig: Pokex.Rig.Fake})

      assert {:error, [message]} = BotSupervisor.start_all()
      assert message =~ "simulador"
    end

    test "stops refusing once the simulator is disarmed" do
      :persistent_term.put({Pokex.Sim.Fence, :arm_state}, %{rig: Pokex.Rig.Fake})
      assert {:error, [_message]} = BotSupervisor.start_all()

      :persistent_term.erase({Pokex.Sim.Fence, :arm_state})

      case BotSupervisor.start_all() do
        :ok -> :ok
        {:error, messages} -> refute Enum.any?(messages, &(&1 =~ "simulador"))
      end
    end
  end
```

- [ ] **Step 2: Run it to make sure it fails**

```bash
cd ~/projects/worktrees/simulador && mix test test/pokex/bots/bot_supervisor_test.exs
```

Expected: FAIL — o primeiro teste não recebe `{:error, [_]}` com "simulador" na mensagem.

- [ ] **Step 3: Implement the minimal code to make the test pass**

Replace `start_all/0` at `lib/pokex/bots/bot_supervisor.ex:312`:

```elixir
  # The ONE entry point production uses: the Iniciar button, Focus re-arming when
  # the game window comes back to front, and the Guardian's restart Task. Focus is
  # why this guard exists here — with the simulator armed, bringing the game
  # forward would otherwise start the real fleet with nobody asking.
  def start_all do
    if Pokex.Sim.Fence.armed?() do
      {:error, ["o simulador está armado — desarme antes de iniciar o bot de verdade"]}
    else
      start_all(
        Fishing.Worker,
        Combat.Worker,
        Catcher.Worker,
        MiniGame.Worker,
        PlayerSupport.Worker,
        Cavebot.Worker
      )
    end
  end
```

- [ ] **Step 4: Run the tests and make sure they pass**

```bash
cd ~/projects/worktrees/simulador && mix test test/pokex/bots/bot_supervisor_test.exs test/pokex/bots/focus_test.exs
```

Expected: PASS. `focus_test.exs` entra na mesma rodada porque `Focus` é o chamador que esta guarda protege.

- [ ] **Step 5: Commit**

```bash
cd ~/projects/worktrees/simulador && git add lib/pokex/bots/bot_supervisor.ex test/pokex/bots/bot_supervisor_test.exs && git commit -m "a janela voltar pra frente não acorda o bot de verdade"
```

---

## Task 4: O `Fence` na árvore de supervisão

**Files:**
- Modify: `lib/pokex/application.ex`
- Test: nenhum novo — a suíte inteira é o teste (o `Fence` passa a subir em todo `mix test`).

**Interfaces:**
- Consumes: `Pokex.Sim.Fence.start_link/1` (tarefa 2).
- Produces: `Pokex.Sim.Fence` registrado sob o próprio nome, disponível para a PR 4 (a aba) chamar `arm/1` e `disarm/1`.

**Contexto que o implementador precisa saber:**

O `Fence` tem que subir **depois** do `Pokex.Bots.BotSupervisor`, e isso é contraintuitivo o bastante para valer a explicação: a recuperação do `handle_continue(:recover, …)` chama `stop_all/1`, que fala com os workers pelo nome. Subindo antes, ela falaria com processos que ainda não existem. E não há corrida a temer: os workers do `BotSupervisor` sobem **ociosos** ("nothing moves the mouse until `start_all/0`"), e os três chamadores de `start_all/0` só existem depois que a aplicação está de pé.

`:persistent_term` sobrevive a reinício de aplicação dentro da mesma VM — que é exatamente o caso que a recuperação existe para cobrir.

- [ ] **Step 1: Add the child right after the BotSupervisor**

In `lib/pokex/application.ex`, the `children` list has `Pokex.Bots.BotSupervisor,` at line 34. Insert immediately after it:

```elixir
      Pokex.Bots.BotSupervisor,
      # AFTER the fleet on purpose: recovering from a fence that died armed halts
      # the workers by name, so they have to exist. They come up idle, so there is
      # no window to race — nothing walks until start_all/0, which this guards.
      Pokex.Sim.Fence,
```

- [ ] **Step 2: Compile with warnings as errors**

```bash
cd ~/projects/worktrees/simulador && mix compile --force --warnings-as-errors
```

Expected: compila sem warning. (`--force` porque `touch` não força recompilação — o Elixir compara digests, e um build velho passa em silêncio.)

- [ ] **Step 3: Run the full gate**

```bash
cd ~/projects/worktrees/simulador && mix precommit
```

Expected: PASS, zero warnings, formatação limpa, credo limpo. Se três módulos de visão estourarem 60s, a máquina está carregada — rodar de novo quieta, nunca aumentar o timeout.

- [ ] **Step 4: Commit and push**

```bash
cd ~/projects/worktrees/simulador && git add lib/pokex/application.ex && git commit -m "a cerca entra na árvore" && git push
```

---

## Definition of done da PR 1

- [ ] `Pokex.Rig.Sim` implementa os 16 callbacks e o teste de import chunk prova que ele não alcança `Pokex.Rig.Mac`, `System`, `:os` nem `:erlang.open_port/2`.
- [ ] `cursor_position/0` não cai nem no canto de pânico nem no de comando.
- [ ] Armar troca as três chaves na ordem certa; recusar não toca em nenhuma.
- [ ] Desarmar para a frota **antes** de devolver as mãos reais — provado por um teste que observa `Rig.impl()` de dentro do `stop_all`.
- [ ] Matar o `Fence` armado deixa o substituto parar a frota antes de restaurar.
- [ ] `start_all/0` recusa enquanto armado, e a recusa chega pelo `Focus`.
- [ ] `mix precommit` verde no worktree.
- [ ] **Nada simula ainda.** Esta PR só ergue a cerca. `Pokex.Sim.World` é a PR 2.
