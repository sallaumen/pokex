defmodule Pokex.Bots.Catcher.WorkerTest.FakeBody do
  use GenServer
  def start_link(test), do: GenServer.start_link(__MODULE__, test)
  @impl true
  def init(test), do: {:ok, test}
  @impl true
  def handle_call({:perform, actions, priority, _at}, _from, test) do
    send(test, {:performed, priority, actions})
    {:reply, :ok, test}
  end
end

defmodule Pokex.Bots.Catcher.WorkerTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.Catcher.Worker
  alias Pokex.Bots.Catcher.WorkerTest.FakeBody
  alias Pokex.Calibration
  alias Pokex.Perception.WorldState
  alias Pokex.Settings

  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    mode = Settings.get(:player_mode)
    loot_enabled = Settings.get(:loot_enabled)
    capture_enabled = Settings.get(:capture_enabled)

    on_exit(fn ->
      Application.delete_env(:pokex, :home_dir)
      Settings.put(:player_mode, mode)
      Settings.put(:loot_enabled, loot_enabled)
      Settings.put(:capture_enabled, capture_enabled)
      :ets.delete(:pokex_world, :corpses)
    end)

    Settings.put(:player_mode, "still")

    Calibration.save(%Calibration{
      scale: 1.0,
      screen_w: 1000,
      screen_h: 700,
      water_point: {400, 300},
      glow_region: {0, 0, 20, 20},
      battle_region: {900, 0, 80, 400},
      neutral_point: {500, 500}
    })

    {:ok, _} = Pokex.Rig.Fake.start_link(%{})
    {:ok, body} = FakeBody.start_link(self())

    # The injected scanner reads the SAME WorldState the tests populate via world!/1 —
    # kill and confirmation wakes see exactly the staged scene (production defaults to
    # the real SpotScan).
    scanner = fn ->
      case WorldState.get(:corpses, 60_000, System.monotonic_time(:millisecond)) do
        {:ok, obs} -> obs
        _nada -> nil
      end
    end

    worker = start_supervised!({Worker, name: nil, body: body, scanner: scanner})
    :ok = Worker.run(worker)
    %{worker: worker}
  end

  defp corpses_obs(points) do
    %{scanning?: true, corpses: points, captured_at: System.monotonic_time(:millisecond)}
  end

  defp world!(worker, obs) do
    WorldState.put(:corpses, obs, obs.captured_at)
    send(worker, {:world, :corpses, obs})
  end

  @tag :tmp_dir
  test "pending_corpses rides the snapshot: 1 with a ball in flight, 0 once resolved", %{
    worker: worker
  } do
    assert Worker.status(worker).pending_corpses == 0

    world!(worker, corpses_obs([{150, 250}]))
    assert_receive {:performed, :high, [{:move, {150, 250}} | _]}, 1_000
    assert Worker.status(worker).pending_corpses == 1

    gone = corpses_obs([])
    gone = %{gone | captured_at: gone.captured_at + 2_000}
    world!(worker, gone)
    assert eventually(fn -> Worker.status(worker).pending_corpses == 0 end, 2_000)
  end

  @tag :tmp_dir
  test "a corpse observation makes it throw a ball at :high", %{worker: worker} do
    world!(worker, corpses_obs([{130, 224}]))
    assert_receive {:performed, :high, [{:move, {130, 224}} | _]}, 1_000
    assert Worker.status(worker).counters.throws == 1
  end

  @tag :tmp_dir
  test "the throw log names which pokemon the library recognized", %{worker: worker} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, "catcher")

    obs =
      corpses_obs([{130, 224}])
      |> Map.put(:known, %{{130, 224} => %{name: "Corsola", score: 0.87}})

    world!(worker, obs)

    assert_receive {:performed, :high, [{:move, {130, 224}} | _]}, 1_000
    assert_log_eventually("🎯 Corsola reconhecido (87%)")
  end

  @tag :tmp_dir
  test "run announces the library — empty is a siren, not silence", %{worker: worker} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, "catcher")

    :ok = Worker.run(worker)

    assert_receive {:rule_alarm, :capture, msg}, 1_000
    assert msg =~ "acervo de corpos VAZIO"
  end

  defp assert_log_eventually(fragment, timeout \\ 1_000) do
    receive do
      {:catcher_log, :macro, msg} ->
        if msg =~ fragment, do: :ok, else: assert_log_eventually(fragment, timeout)
    after
      timeout -> flunk("nenhum catcher_log contendo #{inspect(fragment)} chegou")
    end
  end

  # The feed keeps re-putting fresh empty observations WITHOUT broadcasting when nothing
  # changed — only the worker's wake polling can find them.
  @tag :tmp_dir
  test "polling alone confirms a vanished corpse (no further events)", %{worker: worker} do
    world!(worker, corpses_obs([{130, 224}]))
    assert_receive {:performed, :high, _}, 1_000

    spawn(fn ->
      for _i <- 1..8 do
        Process.sleep(150)
        obs = corpses_obs([])
        WorldState.put(:corpses, obs, obs.captured_at)
      end
    end)

    assert eventually(fn -> Worker.status(worker).counters.captures == 1 end, 3_000)
  end

  @tag :tmp_dir
  test "a kill event triggers an immediate world re-read", %{worker: _worker} do
    obs = corpses_obs([{140, 230}])
    WorldState.put(:corpses, obs, obs.captured_at)
    Phoenix.PubSub.broadcast(Pokex.PubSub, Worker.kill_topic(), {:kill})

    assert_receive {:performed, :high, [{:move, {140, 230}} | _]}, 1_000
  end

  @tag :tmp_dir
  test "movimento mode never acts", %{worker: worker} do
    Settings.put(:player_mode, "moving")
    :ok = Worker.mode_changed(worker)
    assert Worker.status(worker).state == :manual

    world!(worker, corpses_obs([{130, 224}]))
    refute_receive {:performed, _p, _a}, 300

    Settings.put(:player_mode, "still")
    :ok = Worker.mode_changed(worker)
    assert Worker.status(worker).state == :armed
  end

  @tag :tmp_dir
  test "mode_changed on a HALTED worker never re-attaches the feed", %{worker: worker} do
    :ok = Worker.halt(worker)
    assert Worker.status(worker).state == :idle

    :ok = Worker.mode_changed(worker)
    world!(worker, corpses_obs([{130, 224}]))
    refute_receive {:performed, _p, _a}, 300
    assert Worker.status(worker).state == :idle
  end

  @tag :tmp_dir
  # A corpse observation arriving mid-fight must be held: the stationary blob the detector
  # sees might just be the live, tile-locked enemy sprite.
  test "a fight in progress holds all throws", %{worker: worker} do
    send(worker, {:combat, %{state: :fighting, counters: %{}, error: nil, locked_row: 0}})

    world!(worker, corpses_obs([{150, 250}]))
    refute_receive {:performed, _p, _a}, 300
    assert Worker.status(worker).hold_reason == "esperando fim da luta"

    fresh = corpses_obs([{150, 250}])
    WorldState.put(:corpses, fresh, fresh.captured_at)
    send(worker, {:combat, %{state: :hunting, counters: %{}, error: nil, locked_row: nil}})

    assert_receive {:performed, :high, [{:move, {150, 250}} | _]}, 1_000
    assert Worker.status(worker).hold_reason == nil
    assert %{text: "bola arremessada" <> _, at: at} = Worker.status(worker).last_action
    assert is_integer(at)
  end

  @tag :tmp_dir
  # Space is the mini-game's control key — a loot press mid-game would sabotage the player.
  test "the mini-game fact freezes loots and throws; the next event after it clears acts", %{
    worker: worker
  } do
    WorldState.put(
      :mini_game,
      %{playing?: true, confidence: 1.0},
      System.monotonic_time(:millisecond)
    )

    on_exit(fn -> WorldState.forget(:mini_game) end)

    obs = corpses_obs([{130, 224}])
    WorldState.put(:corpses, obs, obs.captured_at)
    Phoenix.PubSub.broadcast(Pokex.PubSub, Worker.kill_topic(), {:kill})
    refute_receive {:performed, _p, _a}, 300

    WorldState.forget(:mini_game)
    world!(worker, corpses_obs([{130, 224}]))
    assert_receive {:performed, :high, [{:move, {130, 224}} | _]}, 1_000
  end

  # A post-relearn warmup frame (scanning?: false) must not read as "corpse vanished" —
  # it would falsely confirm a capture and aim the next queued throw at the old spot.
  @tag :tmp_dir
  test "relearn resets pending state", %{worker: worker} do
    world!(worker, corpses_obs([{160, 260}]))
    assert_receive {:performed, :high, [{:move, {160, 260}} | _]}, 1_000
    assert Worker.status(worker).counters.throws == 1

    :ok = Worker.relearn(worker)

    future_ms = System.monotonic_time(:millisecond) + 2_000
    warmup = %{scanning?: false, corpses: [], captured_at: future_ms}
    world!(worker, warmup)

    refute_receive {:performed, _p, _a}, 300
    assert Worker.status(worker).counters.captures == 0
  end

  @tag :tmp_dir
  test "run re-seeds combat engagement from live status (stale engaged flag can't stick)",
       %{worker: worker} do
    send(worker, {:combat, %{state: :fighting, counters: %{}, error: nil, locked_row: 0}})
    :ok = Worker.halt(worker)
    :ok = Worker.run(worker)

    world!(worker, corpses_obs([{130, 224}]))
    assert_receive {:performed, :high, [{:move, {130, 224}} | _]}, 1_000
  end

  @tag :tmp_dir
  test "a kill triggers the Space loot presses before any ball", %{worker: worker} do
    obs = corpses_obs([{130, 224}])
    WorldState.put(:corpses, obs, obs.captured_at)

    Phoenix.PubSub.broadcast(Pokex.PubSub, Worker.kill_topic(), {:kill})

    assert_receive {:performed, :high, loot_actions}, 1_000
    assert loot_actions == [{:press, "space"}, {:wait, 250}, {:press, "space"}]

    assert_receive {:performed, :high, [{:move, {130, 224}} | _]}, 1_000
    assert Worker.status(worker).counters.loots == 1
    assert %{text: "bola arremessada" <> _, at: _} = Worker.status(worker).last_action
  end

  @tag :tmp_dir
  test "loot_enabled false: kills loot nothing (balls unaffected)", %{worker: worker} do
    Settings.put(:loot_enabled, false)

    obs = corpses_obs([{130, 224}])
    WorldState.put(:corpses, obs, obs.captured_at)
    Phoenix.PubSub.broadcast(Pokex.PubSub, Worker.kill_topic(), {:kill})

    assert_receive {:performed, :high, actions}, 1_000
    assert [{:move, {130, 224}} | _] = actions
    assert Worker.status(worker).counters.loots == 0
  end

  @tag :tmp_dir
  test "capture_enabled false: loot still fires, balls never, feed never attaches",
       %{worker: worker} do
    Settings.put(:capture_enabled, false)
    :ok = Worker.mode_changed(worker)

    obs = corpses_obs([{130, 224}])
    WorldState.put(:corpses, obs, obs.captured_at)
    Phoenix.PubSub.broadcast(Pokex.PubSub, Worker.kill_topic(), {:kill})

    assert_receive {:performed, :high, [{:press, "space"} | _]}, 1_000
    refute_receive {:performed, _, [{:move, _} | _]}, 400

    world!(worker, corpses_obs([{140, 230}]))
    refute_receive {:performed, _, [{:move, _} | _]}, 300
  end

  @tag :tmp_dir
  test "every scan becomes a feed line — and the session scoreboard advances", %{worker: worker} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, "catcher")

    world!(worker, corpses_obs([{130, 224}]))
    assert_receive {:performed, :high, [{:move, _} | _]}, 1_000

    assert %{scans: v, with_target: c} = Worker.status(worker).counters
    assert v > 0, "a varredura tem que ser contada"
    assert c > 0, "esta varredura achou alvo"
  end

  @tag :tmp_dir
  test "a blind scan is counted and narrated, and never confirms a ball", %{worker: worker} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, "catcher")

    world!(worker, corpses_obs([{130, 224}]))
    assert_receive {:performed, :high, [{:move, {130, 224}} | _]}, 1_000
    assert Worker.status(worker).pending_corpses == 1

    blind = %{
      scanning?: false,
      corpses: [],
      known: %{},
      captured_at: System.monotonic_time(:millisecond) + 5_000,
      reason: :outside_arena
    }

    WorldState.put(:corpses, blind, blind.captured_at)
    send(worker, {:world, :corpses, blind})

    assert_log_eventually("cego")

    assert Worker.status(worker).pending_corpses == 1
    assert Worker.status(worker).counters.blind > 0
  end

  @tag :tmp_dir
  # The first post-kill frame is usually dirty (death animation, loot, own pokemon on top)
  # while the corpse lasts minutes — the worker re-scans on its own with no new event.
  test "a kill with no target re-triggers the scan — the corpse gets more chances", %{
    worker: _worker
  } do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    scanner = fn ->
      Agent.update(counter, &(&1 + 1))

      %{
        scanning?: true,
        corpses: [],
        known: %{},
        captured_at: System.monotonic_time(:millisecond)
      }
    end

    {:ok, body} = FakeBody.start_link(self())
    {:ok, worker} = Worker.start_link(name: nil, body: body, scanner: scanner)
    :ok = Worker.run(worker)

    Phoenix.PubSub.broadcast(Pokex.PubSub, Worker.kill_topic(), {:kill})

    assert eventually(fn -> Agent.get(counter, & &1) >= 2 end, 1_500)

    GenServer.stop(worker)
  end

  @tag :tmp_dir
  # Rig.Mac.gated/1 returns :ok even when it SUPPRESSES — acting and checking afterwards
  # would count a ball that never flew; the gate is asked BEFORE, skipping the whole step.
  test "gate closed: the ball is held, not counted — and Logic never learns of it", %{
    worker: worker
  } do
    Phoenix.PubSub.subscribe(Pokex.PubSub, "catcher")
    Pokex.Bots.InputGate.set_focus_ok(false)
    on_exit(fn -> Pokex.Bots.InputGate.set_focus_ok(true) end)

    world!(worker, corpses_obs([{130, 224}]))

    refute_receive {:performed, _p, [{:move, _} | _]}, 300
    assert_log_eventually("SEGURADA")

    assert Worker.status(worker).counters.throws == 0
    assert Worker.status(worker).pending_corpses == 0

    Pokex.Bots.InputGate.set_focus_ok(true)
    world!(worker, corpses_obs([{130, 224}]))
    assert_receive {:performed, :high, [{:move, {130, 224}} | _]}, 1_000
  end

  @tag :tmp_dir
  # Field 2026-07-30: the bot ran and looted while capture was silently off — the only
  # clue was a subtle pill that read as normal state.
  test "capture disabled says so by name — in the hold reason and in a start alarm",
       %{worker: worker} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, "catcher")
    Settings.put(:capture_enabled, false)
    :ok = Worker.mode_changed(worker)

    assert Worker.status(worker).hold_reason == "captura DESLIGADA — só saque"

    :ok = Worker.run(worker)
    assert_receive {:rule_alarm, :capture, msg}, 1_000
    assert msg =~ "captura DESLIGADA"

    Settings.put(:capture_enabled, true)
    :ok = Worker.mode_changed(worker)
    assert Worker.status(worker).hold_reason == nil
  end

  @tag :tmp_dir
  # Space reaches the corpse on the tile where the kill landed, wherever he
  # happens to be standing at that instant — so walking must not cost him the
  # drops. Only the BALL needs the standing-still ground baseline.
  @tag :tmp_dir
  test "movimento: a kill loots but never throws a ball", %{worker: worker} do
    Settings.put(:player_mode, "moving")
    :ok = Worker.mode_changed(worker)

    obs = corpses_obs([{140, 230}])
    WorldState.put(:corpses, obs, obs.captured_at)
    Phoenix.PubSub.broadcast(Pokex.PubSub, Worker.kill_topic(), {:kill})

    assert_receive {:performed, :high, [{:press, "space"}, {:wait, 250}, {:press, "space"}]},
                   1_000

    assert Worker.status(worker).counters.loots == 1
    refute_receive {:performed, _p, [{:move, _} | _]}, 300
  end

  @tag :tmp_dir
  test "movimento with loot disabled: a kill does nothing", %{worker: worker} do
    Settings.put(:player_mode, "moving")
    Settings.put(:loot_enabled, false)
    :ok = Worker.mode_changed(worker)

    Phoenix.PubSub.broadcast(Pokex.PubSub, Worker.kill_topic(), {:kill})
    refute_receive {:performed, _p, _a}, 300
  end

  @tag :tmp_dir
  test "producer order (kill first, snapshot second) makes loot precede the ball", %{
    worker: worker
  } do
    send(worker, {:combat, %{state: :fighting, counters: %{}, error: nil, locked_row: 0}})

    obs = corpses_obs([{130, 224}])
    WorldState.put(:corpses, obs, obs.captured_at)

    Phoenix.PubSub.broadcast(Pokex.PubSub, Worker.kill_topic(), {:kill})

    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      "combat",
      {:combat, %{state: :hunting, counters: %{}, error: nil, locked_row: nil}}
    )

    assert_receive {:performed, :high, [{:press, "space"} | _]}, 1_000
    assert_receive {:performed, :high, [{:move, {130, 224}} | _]}, 1_000
  end

  defp eventually(fun, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      if fun.(), do: true, else: Process.sleep(20) && false
    end)
    |> Enum.find(fn done -> done or System.monotonic_time(:millisecond) > deadline end)
  end
end
