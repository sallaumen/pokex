defmodule Pokex.Bots.Cavebot.WorkerTest.FakeBody do
  @moduledoc """
  Body double no formato MÓDULO (o molde do Combos.Runner, não o pid do
  Catcher): o Worker injeta o módulo e chama `minimap_step/3` nele, então o
  passo chega aqui em vez de virar um clique real computado de Layout +
  Calibration. Cada comando vai pro pid do teste.
  """
  use Agent

  def start_link(test),
    do: Agent.start_link(fn -> %{test: test, reply: :ok} end, name: __MODULE__)

  @doc "Faz os passos seguintes serem RECUSADOS (portão fechado, HUD não localizado…)."
  def refuse(reason), do: Agent.update(__MODULE__, &%{&1 | reply: {:error, reason}})

  @doc "Volta a aceitar os passos."
  def allow, do: Agent.update(__MODULE__, &%{&1 | reply: :ok})

  def minimap_step(dx, dy, _opts \\ []) do
    fake = Agent.get(__MODULE__, & &1)
    send(fake.test, {:stepped, dx, dy})

    case fake.reply do
      :ok -> {:ok, {dx, dy}}
      error -> error
    end
  end

  def perform(actions, priority, _server \\ nil) do
    send(test_pid(), {:performed, priority, actions})
    :ok
  end

  defp test_pid, do: Agent.get(__MODULE__, & &1.test)
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
  alias Pokex.SettingsStash

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

  defp two_waypoint_route! do
    {:ok, route} = Route.append(Route.new("cavena"), {100, 100, 7})
    {:ok, route} = Route.append(route, {200, 200, 7})
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

    assert Worker.status(worker) ==
             %{
               state: :walking,
               route: "cavena",
               wp_index: 0,
               wp_total: 1,
               wp_target: %{x: 100, y: 100, z: 7},
               pos: nil,
               pos_age_ms: nil,
               distance_tiles: nil,
               hold_reason: nil,
               last_action: nil,
               counters: %{waypoints: 0, steps: 0}
             }

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

    status = Worker.status(worker)
    assert status.state == :walking
    # e DIZ que está cego: "walking" parado, sem motivo escrito, é igualzinho a
    # um bot travado
    assert status.hold_reason =~ "não sei onde estou"
  end

  # A regressão que matou a frota: o Iniciar foi clicado no navegador, o jogo
  # perdeu o foco, o portão fechou e cada clique de passo virou um `:ok` mudo.
  # A Logic acreditou nos passos, a posição não mudou, e 6s depois veio o
  # :stuck → pânico. O passo recusado tem que ser VISÍVEL.
  test "passo recusado pelo portão vira motivo visível, e some quando volta", %{worker: worker} do
    route!()
    :ok = Worker.run(worker)
    minimap!({10, 20, 7})

    send(worker, :tick)
    assert_receive {:combat_cmd, :run}, 1_000

    FakeBody.refuse(:input_gate_closed)
    minimap!({10, 20, 7})
    send(worker, :tick)
    assert_receive {:stepped, 90, 80}, 1_000

    status = Worker.status(worker)
    assert status.hold_reason =~ "jogo sem foco"
    # visibilidade, não freio: o cavebot segue tentando a cada tick
    assert status.state == :walking

    FakeBody.allow()
    minimap!({10, 20, 7})
    send(worker, :tick)
    assert_receive {:stepped, 90, 80}, 1_000
    assert Worker.status(worker).hold_reason == nil
  end

  test "HUD não localizado tem motivo próprio", %{worker: worker} do
    route!()
    :ok = Worker.run(worker)
    minimap!({10, 20, 7})

    send(worker, :tick)
    assert_receive {:combat_cmd, :run}, 1_000

    FakeBody.refuse(:no_layout)
    minimap!({10, 20, 7})
    send(worker, :tick)
    assert_receive {:stepped, 90, 80}, 1_000

    assert Worker.status(worker).hold_reason =~ "HUD não localizado"
  end

  test "o motivo é anunciado no tópico mesmo sem o estado mudar", %{worker: worker} do
    route!()
    :ok = Worker.run(worker)
    minimap!({10, 20, 7})

    send(worker, :tick)
    assert_receive {:combat_cmd, :run}, 1_000
    # call síncrono: garante que o tick do :run_combat terminou antes de assinar
    assert Worker.status(worker).state == :walking

    # daqui pra frente o ESTADO não muda mais — só o motivo. Sem ele no gatilho
    # do broadcast, a tela ficaria mostrando "walking" pra sempre.
    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())

    FakeBody.refuse(:input_gate_closed)
    minimap!({10, 20, 7})
    send(worker, :tick)

    assert_receive {:cavebot, %{state: :walking, hold_reason: reason}}, 1_000
    assert reason =~ "jogo sem foco"
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
    assert Worker.status(worker) == Worker.idle_snapshot()

    # halted: um tick perdido é inócuo
    minimap!({10, 20, 7})
    send(worker, :tick)
    refute_receive {:stepped, _dx, _dy}, 300
    refute_receive {:combat_cmd, _cmd}, 100
  end

  # O bloqueio LOCAL: o cavebot bateu numa parede. Isso é problema DELE — tratar
  # igual a uma mudança de andar apagava a captura, o suporte E o auto-resume do
  # Focus (o latch de pânico veta até ele), por causa de um obstáculo de um tile.
  test "bloqueio LOCAL para só o cavebot: nada de latch de pânico", %{worker: worker} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    # sem paciência nenhuma: o primeiro tick sem progresso já vira :stuck e o
    # seguinte esgota os retries
    SettingsStash.stash!(cavebot_walk_timeout_ms: 0, cavebot_stuck_max_retries: 0)
    route!()
    :ok = Worker.run(worker)
    minimap!({10, 20, 7})

    send(worker, :tick)
    assert_receive {:combat_cmd, :run}, 1_000
    # anda, não sai do lugar, vira :stuck, esgota
    Enum.each(1..3, fn _ -> send(worker, :tick) end)

    assert_receive {:cavebot_alarm, :stuck}, 1_000
    assert_receive {:cavebot_log, :macro, "caçada: parei: travado, sem sair do lugar"}, 1_000
    assert_receive {:combat_cmd, :halt}, 1_000

    # a frota segue viva: o latch de pânico é do bloqueio PERIGOSO, e ele veta
    # até o auto-resume do Focus
    refute InputGate.panic_latched?()

    status = Worker.status(worker)
    assert status.state == :blocked
    assert status.hold_reason =~ "travado"
  end

  test "bloqueio PERIGOSO continua ligando o latch — mudança de andar", %{worker: worker} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    route!(7)
    :ok = Worker.run(worker)
    minimap!({10, 20, 5})

    send(worker, :tick)

    assert_receive {:cavebot_log, :macro, "caçada: BLOQUEADO: mudou de andar"}, 1_000
    assert InputGate.panic_latched?()
    assert Worker.status(worker).hold_reason =~ "mudou de andar"
  end

  test "o snapshot conta a caçada inteira: alvo, posição, distância, contadores", %{
    worker: worker
  } do
    route!()
    :ok = Worker.run(worker)
    minimap!({10, 20, 7})

    send(worker, :tick)
    assert_receive {:combat_cmd, :run}, 1_000
    send(worker, :tick)
    assert_receive {:stepped, 90, 80}, 1_000

    status = Worker.status(worker)
    assert status.route == "cavena"
    assert status.wp_index == 0
    assert status.wp_total == 1
    assert status.wp_target == %{x: 100, y: 100, z: 7}
    assert status.pos == {10, 20, 7}
    assert status.pos_age_ms >= 0
    assert status.distance_tiles == %{dx: 90, dy: 80}
    assert status.counters == %{waypoints: 0, steps: 1}
    assert status.last_action.text == "passo 90,80"

    # cego: a Logic para de andar, mas a tela mantém a ÚLTIMA coordenada com a
    # idade dela — "estava em 10,20 há Xms" é diagnóstico, "sem posição" não é
    WorldState.forget(:minimap)
    send(worker, :tick)

    blind = Worker.status(worker)
    assert blind.pos == {10, 20, 7}
    assert blind.pos_age_ms >= 0
    assert blind.hold_reason =~ "não sei onde estou"
  end

  # Avançar de waypoint não muda o ESTADO (:walking → :walking): sem o wp_index
  # no gatilho, a tela ficaria parada no waypoint 1 a caçada inteira.
  test "o snapshot é reemitido quando o waypoint avança, sem o estado mudar", %{worker: worker} do
    two_waypoint_route!()
    :ok = Worker.run(worker)
    minimap!({100, 100, 7})

    send(worker, :tick)
    assert_receive {:combat_cmd, :run}, 1_000
    assert Worker.status(worker).state == :walking

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    send(worker, :tick)

    assert_receive {:cavebot, %{state: :walking, wp_index: 1, counters: %{waypoints: 1}}}, 1_000
  end

  test "a caçada narra as bordas: rota, waypoint (macro) e passo (debug)", %{worker: worker} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    two_waypoint_route!()
    :ok = Worker.run(worker)

    assert_receive {:cavebot_log, :macro, "caçada: rota \"cavena\": 2 waypoints"}, 1_000

    minimap!({100, 100, 7})
    send(worker, :tick)
    assert_receive {:combat_cmd, :run}, 1_000

    # chegou no primeiro waypoint
    send(worker, :tick)
    assert_receive {:cavebot_log, :macro, "caçada: waypoint 1/2"}, 1_000

    # e o passo rumo ao segundo é DEBUG — o passo acontece 5×/s, não pode
    # competir com os fatos no feed
    send(worker, :tick)
    assert_receive {:cavebot_log, :debug, "caçada: passo 100,100 → wp 2/2"}, 1_000
  end

  test "o motivo de espera vira UMA linha na borda, não uma por tick", %{worker: worker} do
    route!()
    :ok = Worker.run(worker)
    minimap!({10, 20, 7})

    send(worker, :tick)
    assert_receive {:combat_cmd, :run}, 1_000

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    FakeBody.refuse(:input_gate_closed)

    Enum.each(1..3, fn _ ->
      minimap!({10, 20, 7})
      send(worker, :tick)
      assert_receive {:stepped, 90, 80}, 1_000
    end)

    assert_receive {:cavebot_log, :macro, motivo}, 1_000
    assert motivo =~ "jogo sem foco"
    # os ticks seguintes com o MESMO motivo são silêncio
    refute_receive {:cavebot_log, :macro, _repetido}, 200
  end

  # Desistir de reconectar era mudo: o worker ficava parado para sempre, sem
  # posição, sem motivo e sem log — o pior modo de falha possível.
  test "desistir do reattach do feed vira motivo escrito e linha no feed", %{worker: worker} do
    route!()
    :ok = Worker.run(worker)
    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())

    # as 20 tentativas já foram queimadas: a próxima morte do feed é a desistência
    ref = make_ref()
    :sys.replace_state(worker, &%{&1 | reattach_attempts: 20, feed_ref: ref})
    send(worker, {:DOWN, ref, :process, self(), :killed})

    assert_receive {:cavebot_log, :macro, "caçada: perdi o feed do minimapa" <> _}, 1_000
    assert Worker.status(worker).hold_reason =~ "perdi o feed do minimapa"
  end

  # O placeholder do BotSupervisor copia esta forma quando o worker não responde:
  # um mapa incompleto quebraria a tela exatamente na hora ruim.
  test "idle_snapshot/0 carrega a forma COMPLETA do snapshot" do
    assert Worker.idle_snapshot() == %{
             state: :idle,
             route: nil,
             wp_index: 0,
             wp_total: 0,
             wp_target: nil,
             pos: nil,
             pos_age_ms: nil,
             distance_tiles: nil,
             hold_reason: nil,
             last_action: nil,
             counters: %{waypoints: 0, steps: 0}
           }
  end
end
