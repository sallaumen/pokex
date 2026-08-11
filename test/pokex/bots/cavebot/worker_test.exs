defmodule Pokex.Bots.Cavebot.WorkerTest.FakeBody do
  @moduledoc """
  Module-shaped Body double (the Combos.Runner mold, not the Catcher's pid): the Worker
  calls `arrow_step/3` on it, so the step lands here instead of becoming a real key
  press. Every command is sent to the test pid.
  """
  use Agent

  def start_link(test),
    do: Agent.start_link(fn -> %{test: test, reply: :ok} end, name: __MODULE__)

  @doc "Makes subsequent steps be REFUSED (gate closed, HUD not located, ...)."
  def refuse(reason), do: Agent.update(__MODULE__, &%{&1 | reply: {:error, reason}})

  @doc "Accepts steps again."
  def allow, do: Agent.update(__MODULE__, &%{&1 | reply: :ok})

  def arrow_step(dx, dy, _opts \\ []) do
    fake = Agent.get(__MODULE__, & &1)
    send(fake.test, {:stepped, dx, dy})

    case fake.reply do
      :ok -> {:ok, if(abs(dx) >= abs(dy), do: "right", else: "down")}
      error -> error
    end
  end

  @doc "Walking holds a direction now; [] is the release."
  def hold(keys) do
    fake = Agent.get(__MODULE__, & &1)
    send(fake.test, {:held, keys})

    if keys == [], do: :ok, else: fake.reply
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

defmodule Pokex.Bots.Cavebot.WorkerTest.FakeCatcher do
  @moduledoc """
  Answers `Catcher.Worker.sweep_now/1` (a plain `:sweep_now` cast) and tells the
  test the hunt asked for a sweep.
  """
  use GenServer

  def start_link(test), do: GenServer.start_link(__MODULE__, test)

  @impl true
  def init(test), do: {:ok, test}

  @impl true
  def handle_cast(:sweep_now, test) do
    send(test, :sweep_asked)
    {:noreply, test}
  end
end

defmodule Pokex.Bots.Cavebot.WorkerTest do
  @moduledoc """
  The Worker isolated with fake Body and Combat, driven by facts injected into the
  blackboard. `active: false` makes `run` prepare everything WITHOUT scheduling the
  automatic tick; each test fires `tick!(worker)` by hand, one step at a time.
  """
  # async: false — writes the shared blackboard, the routes' home_dir and (in the block
  # test) the global InputGate latch.
  use ExUnit.Case, async: false

  alias Pokex.Bots.Cavebot.Route
  alias Pokex.Bots.Cavebot.Store
  alias Pokex.Bots.Cavebot.Worker
  alias Pokex.Bots.Cavebot.WorkerTest.FakeBody
  alias Pokex.Bots.Cavebot.WorkerTest.FakeCatcher
  alias Pokex.Bots.Cavebot.WorkerTest.FakeCombat
  alias Pokex.Bots.InputGate
  alias Pokex.Perception.WorldState
  alias Pokex.Rig.Fake
  alias Pokex.SettingsStash

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    # one shared blackboard: start from an empty world, never from the last test's
    WorldState.clear()

    Application.put_env(:pokex, :home_dir, tmp)

    on_exit(fn ->
      Application.delete_env(:pokex, :home_dir)
      Enum.each([:minimap, :battle, :dungeon], &WorldState.forget/1)
      InputGate.set_panic_latch(false)
    end)

    {:ok, _} = FakeBody.start_link(self())
    {:ok, combat} = FakeCombat.start_link(self())
    {:ok, catcher} = FakeCatcher.start_link(self())

    worker =
      start_supervised!(
        {Worker, name: nil, body: FakeBody, combat: combat, catcher: catcher, active: false}
      )

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

  # A tick is a bare `send` — asynchronous. The status call right after it is
  # not, and a GenServer handles its mailbox in order: once status answers, the
  # tick is PROVABLY done and every message it produced is already in ours
  # (local sends enqueue before the call that follows them returns).
  #
  # Without it, each assertion below was racing the scheduler with a 1s budget:
  # green on a quiet machine, red on a loaded 2-core runner, on a different test
  # each run. A deadline is not a synchronisation primitive.
  defp tick!(worker) do
    send(worker, :tick)
    Worker.status(worker)
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
               wp_target: %{x: 100, y: 100, z: 7, action: :walk, sweep?: false},
               pos: nil,
               pos_age_ms: nil,
               distance_tiles: nil,
               hold_reason: nil,
               luring?: false,
               last_action: nil,
               counters: %{waypoints: 0, steps: 0}
             }

    minimap!({10, 20, 7})

    tick!(worker)
    assert_receive {:combat_cmd, :run}, 1_000

    tick!(worker)
    assert_receive {:held, ["right", "down"]}, 1_000
  end

  test "enemies on screen: no walking — Logic yields to the fight", %{worker: worker} do
    route!()
    :ok = Worker.run(worker)
    minimap!({10, 20, 7})
    battle!([%{row: 0, name: "Zubat"}])

    tick!(worker)
    assert_receive {:combat_cmd, :run}, 1_000

    tick!(worker)
    refute_receive {:held, [_ | _]}, 300
    assert Worker.status(worker).state == :fighting
  end

  test "an unknown position holds the step — never walks blind", %{worker: worker} do
    route!()
    :ok = Worker.run(worker)

    tick!(worker)
    assert_receive {:combat_cmd, :run}, 1_000

    tick!(worker)
    refute_receive {:held, [_ | _]}, 300

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

    tick!(worker)
    assert_receive {:combat_cmd, :run}, 1_000

    FakeBody.refuse(:input_gate_closed)
    minimap!({10, 20, 7})
    tick!(worker)
    assert_receive {:held, ["right", "down"]}, 1_000

    status = Worker.status(worker)
    assert status.hold_reason =~ "jogo sem foco"
    assert status.state == :walking

    FakeBody.allow()
    minimap!({10, 20, 7})
    tick!(worker)
    assert_receive {:held, ["right", "down"]}, 1_000
    assert Worker.status(worker).hold_reason == nil
  end

  test "HUD not located gets its own reason", %{worker: worker} do
    route!()
    :ok = Worker.run(worker)
    minimap!({10, 20, 7})

    tick!(worker)
    assert_receive {:combat_cmd, :run}, 1_000

    FakeBody.refuse(:no_layout)
    minimap!({10, 20, 7})
    tick!(worker)
    assert_receive {:held, ["right", "down"]}, 1_000

    assert Worker.status(worker).hold_reason =~ "HUD não localizado"
  end

  # The synchronous status call doubles as a barrier: the :run_combat tick has finished
  # before the test subscribes.
  test "the reason is broadcast on the topic even without a state change", %{worker: worker} do
    route!()
    :ok = Worker.run(worker)
    minimap!({10, 20, 7})

    tick!(worker)
    assert_receive {:combat_cmd, :run}, 1_000
    assert Worker.status(worker).state == :walking

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())

    FakeBody.refuse(:input_gate_closed)
    minimap!({10, 20, 7})
    tick!(worker)

    assert_receive {:cavebot, %{state: :walking, hold_reason: reason}}, 1_000
    assert reason =~ "jogo sem foco"
  end

  test "a floor change blocks everything: latch, combat, alarm", %{worker: worker} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    route!(7)
    :ok = Worker.run(worker)
    minimap!({10, 20, 5})

    tick!(worker)

    assert_receive {:cavebot_alarm, :floor_changed}, 1_000
    assert_receive {:combat_cmd, :halt}, 1_000
    assert InputGate.panic_latched?()
    assert Worker.status(worker).state == :blocked

    tick!(worker)
    refute_receive {:held, [_ | _]}, 300
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
    tick!(own)

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
    tick!(worker)
    refute_receive {:held, [_ | _]}, 300
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
    Enum.each(1..4, fn _ -> tick!(worker) end)

    status = Worker.status(worker)
    refute status.state in [:stuck, :blocked]
    assert status.hold_reason =~ "sem foco"
    refute_receive {:cavebot_alarm, :stuck}, 300
    refute_receive {:stepped, _dx, _dy}, 100

    Pokex.Settings.put(:cavebot_walk_timeout_ms, 60_000)
    InputGate.set_focus_ok(true)
    minimap!({10, 20, 7})
    Enum.each(1..3, fn _ -> tick!(worker) end)
    assert_receive {:held, [_ | _]}, 1_000
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

    tick!(worker)
    assert_receive {:combat_cmd, :run}, 1_000
    Enum.each(1..3, fn _ -> tick!(worker) end)

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

    tick!(worker)

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

    tick!(worker)
    assert_receive {:combat_cmd, :run}, 1_000
    tick!(worker)
    assert_receive {:held, ["right", "down"]}, 1_000

    status = Worker.status(worker)
    assert status.route == "cavena"
    assert status.wp_index == 0
    assert status.wp_total == 1
    assert status.wp_target == %{x: 100, y: 100, z: 7, action: :walk, sweep?: false}
    assert status.pos == {10, 20, 7}
    assert status.pos_age_ms >= 0
    assert status.distance_tiles == %{dx: 90, dy: 80}
    assert status.counters == %{waypoints: 0, steps: 1}
    assert status.last_action.text == "segurando right+down"

    WorldState.forget(:minimap)
    tick!(worker)

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

    tick!(worker)
    assert_receive {:combat_cmd, :run}, 1_000
    assert Worker.status(worker).state == :walking

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    tick!(worker)

    assert_receive {:cavebot, %{state: :walking, wp_index: 1, counters: %{waypoints: 1}}}, 1_000
  end

  test "the hunt narrates the edges: route, waypoint (macro) and step (debug)", %{worker: worker} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    two_waypoint_route!()
    :ok = Worker.run(worker)

    assert_receive {:cavebot_log, :macro, "caçada: rota \"cavena\": 2 waypoints"}, 1_000

    minimap!({100, 100, 7})
    tick!(worker)
    assert_receive {:combat_cmd, :run}, 1_000

    tick!(worker)
    assert_receive {:cavebot_log, :macro, "caçada: waypoint 1/2"}, 1_000

    tick!(worker)
    assert_receive {:cavebot_log, :debug, "caçada: segurando right+down → wp 2/2"}, 1_000
  end

  test "the hold reason becomes ONE feed line at the edge, not one per tick", %{worker: worker} do
    route!()
    :ok = Worker.run(worker)
    minimap!({10, 20, 7})

    tick!(worker)
    assert_receive {:combat_cmd, :run}, 1_000

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    FakeBody.refuse(:input_gate_closed)

    Enum.each(1..3, fn _ ->
      minimap!({10, 20, 7})
      tick!(worker)
      assert_receive {:held, ["right", "down"]}, 1_000
    end)

    assert_receive {:cavebot_log, :macro, reason}, 1_000
    assert reason =~ "jogo sem foco"
    refute_receive {:cavebot_log, :macro, _repeated}, 200
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
             luring?: false,
             last_action: nil,
             counters: %{waypoints: 0, steps: 0}
           }
  end

  # With a key HELD the character keeps walking between readings, so correcting
  # a one-tile error overshoots it the other way: left+down → down → right+down
  # around the same corner (Lucas's log, 2026-08-10). An axis already inside the
  # arrival tolerance is not held at all.
  test "an axis already within tolerance is not held — no zig-zag", %{worker: worker} do
    {:ok, route} = Route.append(Route.new("cavena"), {101, 200, 7})
    :ok = Store.add(route)
    :ok = Worker.run(worker)
    minimap!({100, 100, 7})

    tick!(worker)
    assert_receive {:combat_cmd, :run}, 1_000

    # dx is 1 (inside the tolerance), dy is 100: only the vertical is held
    tick!(worker)
    assert_receive {:held, ["down"]}, 1_000
  end

  # Lucas's own pokémon shows up in the battle list (2026-08-10): Combat tabbed
  # at it, failed three times, called it scenery and moved on — while the hunt,
  # counting raw rows, stood still forever waiting for a fight that could never
  # start. It yields the road only to rows Combat might still fight.
  test "a row Combat gave up on does not hold the hunt", %{worker: worker} do
    # leaving :fighting costs a debounce plus a dwell; this test is about WHO
    # counts as an enemy, not about those clocks
    SettingsStash.stash!(cavebot_clear_debounce_ms: 0, cavebot_post_kill_dwell_ms: 0)
    route!()
    :ok = Worker.run(worker)
    minimap!({10, 20, 7})
    battle!([%{row: 0, name: "meu próprio pokémon"}])

    tick!(worker)
    assert_receive {:combat_cmd, :run}, 1_000

    # raw count says 1 enemy: without Combat's verdict the hunt stands still
    tick!(worker)
    refute_receive {:held, [_ | _]}, 300

    # Combat gave up on that row — the road is free again
    send(worker, {:combat, %{state: :hunting, scenery: 1}})
    # clear -> post_fight -> walking -> step, one tick each with the clocks at zero
    Enum.each(1..4, fn _tick -> tick!(worker) end)
    assert_receive {:held, ["right", "down"]}, 1_000

    # and a REAL target still stops it
    send(worker, {:combat, %{state: :hunting, scenery: 0}})
    tick!(worker)
    refute_receive {:held, [_ | _]}, 300
  end

  # Heard, never asked: a `call` to the Catcher parks behind its multi-second
  # captures, and this worker ticks 5x a second. The snapshot it broadcasts is
  # what tells the hunt to hold its ground after a kill.
  test "the Catcher's queue reaches the hunt through the topic", %{worker: worker} do
    # the SWEEP queue is deliberately not counted: it is deferred outside the
    # standing mode, so waiting on it is waiting on work nobody will do
    send(worker, {:catcher, %{pending_corpses: 2, sweep: %{pending: 3}}})
    assert %{capture_pending: 2, capture_changed_at: first} = :sys.get_state(worker)
    assert is_integer(first)

    # a snapshot without the sweep block is read the same, never a crash
    send(worker, {:catcher, %{pending_corpses: 1}})
    assert %{capture_pending: 1} = :sys.get_state(worker)

    # an unchanged queue does NOT refresh the clock: that is what tells a
    # working capture from a frozen one
    state = :sys.get_state(worker)
    send(worker, {:catcher, %{pending_corpses: 1}})
    assert %{capture_changed_at: unchanged} = :sys.get_state(worker)
    assert unchanged == state.capture_changed_at
  end

  # "depois que matar tudo, fazer aquela varredura de captura antes de andar"
  # (Lucas, 2026-08-10): a waypoint may ask for the ground to be swept, and
  # the request has to actually REACH the Catcher.
  describe "sweeping where the pile died" do
    test "arriving at a marked waypoint after a fight asks the Catcher to sweep", %{
      worker: worker
    } do
      # the debounce and the dwell are CLOCKS, and these ticks take microseconds
      SettingsStash.stash!(cavebot_clear_debounce_ms: 0, cavebot_post_kill_dwell_ms: 0)

      {:ok, route} = Route.append(Route.new("cavena"), {100, 100, 7})
      {:ok, route} = Route.append(route, {200, 100, 7})
      :ok = Store.add(Route.set_sweep(route, 0, true))

      :ok = Worker.run(worker)
      minimap!({100, 100, 7})
      tick!(worker)
      tick!(worker)
      assert Worker.status(worker).wp_index == 1

      # a fight starts and ends right there
      battle!([0])
      tick!(worker)
      assert Worker.status(worker).state == :fighting

      battle!([])
      Enum.each(1..6, fn _ -> tick!(worker) end)

      assert_receive :sweep_asked, 1_000
    end

    test "an unmarked waypoint asks for nothing", %{worker: worker} do
      SettingsStash.stash!(cavebot_clear_debounce_ms: 0, cavebot_post_kill_dwell_ms: 0)
      two_waypoint_route!()

      :ok = Worker.run(worker)
      minimap!({100, 100, 7})
      tick!(worker)
      tick!(worker)

      battle!([0])
      tick!(worker)
      battle!([])
      Enum.each(1..6, fn _ -> tick!(worker) end)

      refute_receive :sweep_asked, 300
    end
  end

  # The hunt tells Combat to hold its fire by PUBLISHING A FACT, refreshed
  # every tick. Nothing is commanded and nobody is remembered: Combat obeys a
  # reading with an age, exactly like every other reading it makes.
  describe "the posture the hunt asks of Combat" do
    defp lure_route! do
      {:ok, route} = Route.append(Route.new("cavena"), {100, 100, 7})
      {:ok, route} = Route.append(route, {200, 100, 7})
      {:ok, route} = Route.append(route, {200, 200, 7})
      :ok = Store.add(Route.set_action(route, 0, :lure_start) |> Route.set_action(2, :lure_end))
      route
    end

    defp posture! do
      case WorldState.get(:posture, 60_000, System.monotonic_time(:millisecond)) do
        {:ok, %{posture: posture}} -> posture
        other -> other
      end
    end

    test "a plain leg publishes free fire", %{worker: worker} do
      two_waypoint_route!()
      :ok = Worker.run(worker)
      minimap!({10, 20, 7})
      tick!(worker)
      tick!(worker)

      assert posture!() == :free_fight
    end

    # Reaching waypoint 1 ("mobar daqui") on a clear screen: from the next tick
    # on, the leg being walked is a mob leg.
    defp reach_lure_start!(worker) do
      lure_route!()
      :ok = Worker.run(worker)
      minimap!({100, 100, 7})
      tick!(worker)
      tick!(worker)
      assert Worker.status(worker).wp_index == 1
    end

    test "on a mob leg it asks Combat to hold fire, and walks THROUGH the enemies", %{
      worker: worker
    } do
      reach_lure_start!(worker)

      battle!([0, 1, 2])
      tick!(worker)

      assert posture!() == :hold_fire
      # a crowd on screen would stop any other leg; this one it walks
      assert Worker.status(worker).state == :walking
      assert_receive {:held, [_ | _]}, 1_000
    end

    test "past 'até aqui' the fact goes back to free fire", %{worker: worker} do
      reach_lure_start!(worker)
      tick!(worker)
      assert posture!() == :hold_fire

      # arrive at waypoint 2, then at waypoint 3 ("até aqui")
      minimap!({200, 100, 7})
      tick!(worker)
      minimap!({200, 200, 7})
      tick!(worker)

      assert Worker.status(worker).wp_index == 0
      assert posture!() == :free_fight
    end

    test "stopping frees Combat at once, without waiting for the fact to age", %{worker: worker} do
      reach_lure_start!(worker)
      tick!(worker)
      assert posture!() == :hold_fire

      :ok = Worker.halt(worker)
      assert posture!() == :free_fight
    end
  end
end
