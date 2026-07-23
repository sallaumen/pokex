defmodule Pokex.Bots.Cavebot.WorkerTest.FakeBody do
  @moduledoc """
  Body double no formato MÓDULO (o molde do Combos.Runner, não o pid do
  Catcher): o Worker injeta o módulo e chama `minimap_step/3` nele, então o
  passo chega aqui em vez de virar um clique real computado de Layout +
  Calibration. Cada comando vai pro pid do teste.
  """
  use Agent

  def start_link(test), do: Agent.start_link(fn -> test end, name: __MODULE__)

  def minimap_step(dx, dy, _opts \\ []) do
    send(test_pid(), {:stepped, dx, dy})
    {:ok, {dx, dy}}
  end

  def perform(actions, priority, _server \\ nil) do
    send(test_pid(), {:performed, priority, actions})
    :ok
  end

  defp test_pid, do: Agent.get(__MODULE__, & &1)
end

defmodule Pokex.Bots.Cavebot.WorkerTest.FakeCombat do
  @moduledoc """
  Responde `Combat.Worker.run/1` e `halt/1` (que são só `GenServer.call` de
  `:run`/`:halt`) e conta pro teste o que o cavebot mandou.
  """
  use GenServer

  def start_link(test, run_reply \\ :ok),
    do: GenServer.start_link(__MODULE__, {test, run_reply})

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:run, _from, {test, run_reply} = state) do
    send(test, {:combat_cmd, :run})
    {:reply, run_reply, state}
  end

  def handle_call(:halt, _from, {test, _} = state) do
    send(test, {:combat_cmd, :halt})
    {:reply, :ok, state}
  end
end

defmodule Pokex.Bots.Cavebot.WorkerTest do
  @moduledoc """
  O Worker isolado com Body e Combat fakes, dirigido por fatos injetados no
  blackboard — o padrão de runner_test/catcher worker_test.

  Determinismo: `active: false` faz o `run` preparar tudo SEM agendar o tick
  automático (o gate existe exatamente pra não rodar a cadência contra o Rig
  real); cada teste dispara `send(worker, :tick)` na mão e afirma um passo
  por vez.
  """
  # async: false — escreve o blackboard compartilhado, o home_dir das rotas e
  # (no teste de block) o latch global do InputGate.
  use ExUnit.Case, async: false

  alias Pokex.Bots.Cavebot.{Route, Store, Worker}
  alias Pokex.Bots.Cavebot.WorkerTest.{FakeBody, FakeCombat}
  alias Pokex.Bots.InputGate
  alias Pokex.Perception.WorldState

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)

    on_exit(fn ->
      Application.delete_env(:pokex, :home_dir)
      Enum.each([:minimap, :battle, :dungeon], &WorldState.forget/1)
      InputGate.set_panic_latch(false)
    end)

    {:ok, _} = FakeBody.start_link(self())
    {:ok, combat} = FakeCombat.start_link(self())

    worker =
      start_supervised!({Worker, name: nil, body: FakeBody, combat: combat, active: false})

    %{worker: worker}
  end

  defp route!(z \\ 7) do
    {:ok, route} = Route.append(Route.new("cavena"), {100, 100, z})
    :ok = Store.add(route)
    route
  end

  defp minimap!(pos),
    do: WorldState.put(:minimap, %{pos: pos}, System.monotonic_time(:millisecond))

  defp battle!(enemies) do
    WorldState.put(
      :battle,
      %{enemies: enemies, enemies_detail: []},
      System.monotonic_time(:millisecond)
    )
  end

  test "run sem rota configurada recusa", %{worker: worker} do
    assert {:error, [msg]} = Worker.run(worker)
    assert msg =~ "nenhuma rota"
    assert Worker.status(worker).state == :idle
  end

  test "primeiro tick liga o combate; o seguinte anda até o waypoint", %{worker: worker} do
    route!()
    assert :ok = Worker.run(worker)
    assert Worker.status(worker) == %{state: :walking, wp_index: 0, route: "cavena"}

    minimap!({10, 20, 7})

    send(worker, :tick)
    assert_receive {:combat_cmd, :run}, 1_000

    send(worker, :tick)
    assert_receive {:stepped, 90, 80}, 1_000
  end

  test "inimigos na tela: NÃO anda — a Logic cede a vez pra luta", %{worker: worker} do
    route!()
    :ok = Worker.run(worker)
    minimap!({10, 20, 7})
    battle!([%{row: 0, name: "Zubat"}])

    send(worker, :tick)
    assert_receive {:combat_cmd, :run}, 1_000

    send(worker, :tick)
    refute_receive {:stepped, _dx, _dy}, 300
    assert Worker.status(worker).state == :fighting
  end

  test "posição desconhecida segura o passo — nunca anda às cegas", %{worker: worker} do
    route!()
    :ok = Worker.run(worker)
    # nenhum fato :minimap no blackboard

    send(worker, :tick)
    assert_receive {:combat_cmd, :run}, 1_000

    send(worker, :tick)
    refute_receive {:stepped, _dx, _dy}, 300
    assert Worker.status(worker).state == :walking
  end

  test "mudança de andar bloqueia TUDO: latch, combate, alarme", %{worker: worker} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    route!(7)
    :ok = Worker.run(worker)
    # z=5 ≠ z=7 da rota: escada/buraco — a Logic devolve {:block, :floor_changed}
    minimap!({10, 20, 5})

    send(worker, :tick)

    assert_receive {:cavebot_alarm, :floor_changed}, 1_000
    assert_receive {:combat_cmd, :halt}, 1_000
    assert InputGate.panic_latched?()
    assert Worker.status(worker).state == :blocked

    # blocked é terminal: um tick manual depois não anda nem religa nada
    send(worker, :tick)
    refute_receive {:stepped, _dx, _dy}, 300
    refute_receive {:combat_cmd, :run}, 100
  end

  test "combate recusa o arranque (preflight): bloqueia em vez de andar cego", %{tmp_dir: _tmp} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    {:ok, failing} = FakeCombat.start_link(self(), {:error, ["sem calibração"]})

    own =
      start_supervised!(
        {Worker, name: :cavebot_preflight, body: FakeBody, combat: failing, active: false},
        id: :cavebot_preflight
      )

    route!()
    :ok = Worker.run(own)
    # primeiro tick manda :run_combat; o combate recusa → freio de mão
    send(own, :tick)

    assert_receive {:combat_cmd, :run}, 1_000
    assert_receive {:cavebot_alarm, :combat_preflight_failed}, 1_000
    assert InputGate.panic_latched?()
    assert Worker.status(own).state == :blocked
  end

  # O gate de combos por dungeon lê este fato: run publica, halt esquece.
  test "run publica o fato :dungeon da rota; halt esquece", %{worker: worker} do
    {:ok, route} = Route.append(Route.new("cavena", "cavena-dg"), {100, 100, 7})
    :ok = Store.add(route)

    :ok = Worker.run(worker)
    now = System.monotonic_time(:millisecond)
    assert {:ok, %{id: "cavena-dg"}} = WorldState.get(:dungeon, :infinity, now)

    :ok = Worker.halt(worker)
    assert WorldState.get(:dungeon, :infinity, now) == :missing
  end

  test "halt desliga o combate e volta a idle", %{worker: worker} do
    route!()
    :ok = Worker.run(worker)
    assert :ok = Worker.halt(worker)
    assert_receive {:combat_cmd, :halt}, 1_000
    assert Worker.status(worker) == %{state: :idle, wp_index: 0, route: nil}

    # halted: um tick perdido é inócuo
    minimap!({10, 20, 7})
    send(worker, :tick)
    refute_receive {:stepped, _dx, _dy}, 300
    refute_receive {:combat_cmd, _cmd}, 100
  end
end
