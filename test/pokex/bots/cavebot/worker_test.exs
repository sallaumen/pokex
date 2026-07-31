defmodule Pokex.Bots.Cavebot.WorkerTest.FakeBody do
  @moduledoc """
  Module-shaped Body double (the Combos.Runner mold, not the Catcher's pid): the Worker
  calls `minimap_step/3` on it, so the step lands here instead of becoming a real click
  computed from Layout + Calibration. Every command is sent to the test pid.
  """
  use Agent

  def start_link(test),
    do: Agent.start_link(fn -> %{test: test, reply: :ok} end, name: __MODULE__)

  @doc "Makes subsequent steps be REFUSED (gate closed, HUD not located, ...)."
  def refuse(reason), do: Agent.update(__MODULE__, &%{&1 | reply: {:error, reason}})

  @doc "Accepts steps again."
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
  Answers `Combat.Worker.run/1` and `halt/1` (plain `GenServer.call`s of `:run`/`:halt`)
  and reports to the test what the cavebot commanded.
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
  The Worker isolated with fake Body and Combat, driven by facts injected into the
  blackboard. `active: false` makes `run` prepare everything WITHOUT scheduling the
  automatic tick; each test fires `send(worker, :tick)` by hand, one step at a time.
  """
  # async: false — writes the shared blackboard, the routes' home_dir and (in the block
  # test) the global InputGate latch.
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

  test "run with no route configured refuses", %{worker: worker} do
    assert {:error, [msg]} = Worker.run(worker)
    assert msg =~ "nenhuma rota"
    assert Worker.status(worker).state == :idle
  end

  test "the first tick turns combat on; the next walks toward the waypoint", %{worker: worker} do
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

  # Decision 2026-07-30: undiscovered (black) minimap area = click and only warn; the
  # post-click probe reads a 3x3 patch at the point.
  test "a step into a black minimap area warns the journal — and the step still happens", %{
    worker: worker,
    tmp_dir: tmp
  } do
    dark =
      Pokex.PngFixtures.write!(
        Path.join(tmp, "dark.png"),
        List.duplicate(List.duplicate({0, 0, 0, 255}, 3), 3)
      )

    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, dark}]})
    Phoenix.PubSub.subscribe(Pokex.PubSub, "cavebot")

    route!()
    assert :ok = Worker.run(worker)
    minimap!({10, 20, 7})

    send(worker, :tick)
    assert_receive {:combat_cmd, :run}, 1_000

    send(worker, :tick)
    assert_receive {:stepped, 90, 80}, 1_000
    assert_receive {:cavebot_log, :macro, "caçada: 🕳️" <> _resto}, 1_000
  end

  test "enemies on screen: no walking — Logic yields to the fight", %{worker: worker} do
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

  test "an unknown position holds the step — never walks blind", %{worker: worker} do
    route!()
    :ok = Worker.run(worker)

    send(worker, :tick)
    assert_receive {:combat_cmd, :run}, 1_000

    send(worker, :tick)
    refute_receive {:stepped, _dx, _dy}, 300

    status = Worker.status(worker)
    assert status.state == :walking
    assert status.hold_reason =~ "não sei onde estou"
  end

  # Field regression: Iniciar clicked in the browser stole the game's focus, the gate
  # closed and every step click became a silent `:ok`; the position never changed and 6s
  # later came :stuck → panic. A refused step must be VISIBLE.
  test "a step refused by the gate becomes a visible reason, cleared when it reopens", %{
    worker: worker
  } do
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
    assert status.state == :walking

    FakeBody.allow()
    minimap!({10, 20, 7})
    send(worker, :tick)
    assert_receive {:stepped, 90, 80}, 1_000
    assert Worker.status(worker).hold_reason == nil
  end

  test "HUD not located gets its own reason", %{worker: worker} do
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

  # The synchronous status call doubles as a barrier: the :run_combat tick has finished
  # before the test subscribes.
  test "the reason is broadcast on the topic even without a state change", %{worker: worker} do
    route!()
    :ok = Worker.run(worker)
    minimap!({10, 20, 7})

    send(worker, :tick)
    assert_receive {:combat_cmd, :run}, 1_000
    assert Worker.status(worker).state == :walking

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())

    FakeBody.refuse(:input_gate_closed)
    minimap!({10, 20, 7})
    send(worker, :tick)

    assert_receive {:cavebot, %{state: :walking, hold_reason: reason}}, 1_000
    assert reason =~ "jogo sem foco"
  end

  test "a floor change blocks everything: latch, combat, alarm", %{worker: worker} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    route!(7)
    :ok = Worker.run(worker)
    minimap!({10, 20, 5})

    send(worker, :tick)

    assert_receive {:cavebot_alarm, :floor_changed}, 1_000
    assert_receive {:combat_cmd, :halt}, 1_000
    assert InputGate.panic_latched?()
    assert Worker.status(worker).state == :blocked

    send(worker, :tick)
    refute_receive {:stepped, _dx, _dy}, 300
    refute_receive {:combat_cmd, :run}, 100
  end

  test "combat refusing the start (preflight) blocks instead of walking blind", %{tmp_dir: _tmp} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    {:ok, failing} = FakeCombat.start_link(self(), {:error, ["sem calibração"]})

    own =
      start_supervised!(
        {Worker, name: :cavebot_preflight, body: FakeBody, combat: failing, active: false},
        id: :cavebot_preflight
      )

    route!()
    :ok = Worker.run(own)
    send(own, :tick)

    assert_receive {:combat_cmd, :run}, 1_000
    assert_receive {:cavebot_alarm, :combat_preflight_failed}, 1_000
    assert InputGate.panic_latched?()
    assert Worker.status(own).state == :blocked
  end

  # The per-dungeon combo gate reads this fact: run publishes it, halt forgets it.
  test "run publishes the route's :dungeon fact; halt forgets it", %{worker: worker} do
    {:ok, route} = Route.append(Route.new("cavena", "cavena-dg"), {100, 100, 7})
    :ok = Store.add(route)

    :ok = Worker.run(worker)
    now = System.monotonic_time(:millisecond)
    assert {:ok, %{id: "cavena-dg"}} = WorldState.get(:dungeon, :infinity, now)

    :ok = Worker.halt(worker)
    assert WorldState.get(:dungeon, :infinity, now) == :missing
  end

  test "halt turns combat off and returns to idle", %{worker: worker} do
    route!()
    :ok = Worker.run(worker)
    assert :ok = Worker.halt(worker)
    assert_receive {:combat_cmd, :halt}, 1_000
    assert Worker.status(worker) == Worker.idle_snapshot()

    minimap!({10, 20, 7})
    send(worker, :tick)
    refute_receive {:stepped, _dx, _dy}, 300
    refute_receive {:combat_cmd, _cmd}, 100
  end

  # Field regression 2026-07-29: clicking Iniciar in the BROWSER stole the game's focus →
  # gate closed → no step left, but the patience clocks kept running → :stuck before the
  # user reached the game. A closed gate now FREEZES patience.
  test "a closed gate freezes patience — the hunt waits instead of dying :stuck", %{
    worker: worker
  } do
    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    on_exit(fn -> InputGate.set_focus_ok(true) end)
    SettingsStash.stash!(cavebot_walk_timeout_ms: 0, cavebot_stuck_max_retries: 0)
    route!()
    :ok = Worker.run(worker)
    minimap!({10, 20, 7})

    InputGate.set_focus_ok(false)
    Enum.each(1..4, fn _ -> send(worker, :tick) end)

    status = Worker.status(worker)
    refute status.state in [:stuck, :blocked]
    assert status.hold_reason =~ "sem foco"
    refute_receive {:cavebot_alarm, :stuck}, 300
    refute_receive {:stepped, _dx, _dy}, 100

    Pokex.Settings.put(:cavebot_walk_timeout_ms, 60_000)
    InputGate.set_focus_ok(true)
    minimap!({10, 20, 7})
    Enum.each(1..3, fn _ -> send(worker, :tick) end)
    assert_receive {:stepped, _dx, _dy}, 1_000
  end

  # A LOCAL block (wall bump) is the cavebot's own problem — treating it like a floor
  # change killed capture, support AND the Focus auto-resume (the panic latch vetoes even
  # that) over a one-tile obstacle.
  test "a LOCAL block stops only the cavebot: no panic latch", %{worker: worker} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    SettingsStash.stash!(cavebot_walk_timeout_ms: 0, cavebot_stuck_max_retries: 0)
    route!()
    :ok = Worker.run(worker)
    minimap!({10, 20, 7})

    send(worker, :tick)
    assert_receive {:combat_cmd, :run}, 1_000
    Enum.each(1..3, fn _ -> send(worker, :tick) end)

    assert_receive {:cavebot_alarm, :stuck}, 1_000
    assert_receive {:cavebot_log, :macro, "caçada: parei: travado, sem sair do lugar"}, 1_000
    assert_receive {:combat_cmd, :halt}, 1_000

    refute InputGate.panic_latched?()

    status = Worker.status(worker)
    assert status.state == :blocked
    assert status.hold_reason =~ "travado"
  end

  test "a DANGEROUS block still sets the latch — floor change", %{worker: worker} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    route!(7)
    :ok = Worker.run(worker)
    minimap!({10, 20, 5})

    send(worker, :tick)

    assert_receive {:cavebot_log, :macro, "caçada: BLOQUEADO: mudou de andar"}, 1_000
    assert InputGate.panic_latched?()
    assert Worker.status(worker).hold_reason =~ "mudou de andar"
  end

  # When blind, the snapshot keeps the LAST coordinate with its age — "was at 10,20 Xms
  # ago" is diagnostic, "no position" is not.
  test "the snapshot tells the whole hunt: target, position, distance, counters", %{
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

    WorldState.forget(:minimap)
    send(worker, :tick)

    blind = Worker.status(worker)
    assert blind.pos == {10, 20, 7}
    assert blind.pos_age_ms >= 0
    assert blind.hold_reason =~ "não sei onde estou"
  end

  # Advancing a waypoint does not change the STATE (:walking → :walking); without wp_index
  # in the broadcast trigger the screen would sit on waypoint 1 the whole hunt.
  test "the snapshot is re-emitted when the waypoint advances, without a state change", %{
    worker: worker
  } do
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

  test "the hunt narrates the edges: route, waypoint (macro) and step (debug)", %{worker: worker} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    two_waypoint_route!()
    :ok = Worker.run(worker)

    assert_receive {:cavebot_log, :macro, "caçada: rota \"cavena\": 2 waypoints"}, 1_000

    minimap!({100, 100, 7})
    send(worker, :tick)
    assert_receive {:combat_cmd, :run}, 1_000

    send(worker, :tick)
    assert_receive {:cavebot_log, :macro, "caçada: waypoint 1/2"}, 1_000

    send(worker, :tick)
    assert_receive {:cavebot_log, :debug, "caçada: passo 100,100 → wp 2/2"}, 1_000
  end

  test "the hold reason becomes ONE feed line at the edge, not one per tick", %{worker: worker} do
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
    refute_receive {:cavebot_log, :macro, _repetido}, 200
  end

  # Giving up on reattach used to be mute: the worker sat forever with no position, no
  # reason and no log — the worst possible failure mode.
  test "giving up on the feed reattach becomes a written reason and a feed line", %{
    worker: worker
  } do
    route!()
    :ok = Worker.run(worker)
    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())

    ref = make_ref()
    :sys.replace_state(worker, &%{&1 | reattach_attempts: 20, feed_ref: ref})
    send(worker, {:DOWN, ref, :process, self(), :killed})

    assert_receive {:cavebot_log, :macro, "caçada: perdi o feed do minimapa" <> _}, 1_000
    assert Worker.status(worker).hold_reason =~ "perdi o feed do minimapa"
  end

  # The BotSupervisor placeholder copies this shape when the worker is unresponsive; an
  # incomplete map would break the screen at exactly the wrong time.
  test "idle_snapshot/0 carries the complete snapshot shape" do
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
