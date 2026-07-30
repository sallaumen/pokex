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
  alias Pokex.Perception.WorldState
  alias Pokex.{Calibration, Settings}

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

    Settings.put(:player_mode, "parado")

    Calibration.save(%Calibration{
      scale: 1.0,
      screen_w: 1000,
      screen_h: 700,
      water_point: {400, 300},
      glow_region: {0, 0, 20, 20},
      battle_region: {900, 0, 80, 400},
      arena_region: {100, 200, 64, 64},
      neutral_point: {500, 500}
    })

    {:ok, _} = Pokex.Rig.Fake.start_link(%{})
    {:ok, body} = FakeBody.start_link(self())
    worker = start_supervised!({Worker, name: nil, body: body})
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
    assert_receive {:performed, :high, [{:capture_sequence, {150, 250}}]}, 1_000
    assert Worker.status(worker).pending_corpses == 1

    # the corpse vanished past the flight window → capture confirmed, nothing pending
    gone = corpses_obs([])
    gone = %{gone | captured_at: gone.captured_at + 2_000}
    world!(worker, gone)
    assert eventually(fn -> Worker.status(worker).pending_corpses == 0 end, 2_000)
  end

  @tag :tmp_dir
  test "a corpse observation makes it throw a ball at :high", %{worker: worker} do
    world!(worker, corpses_obs([{130, 224}]))
    assert_receive {:performed, :high, [{:capture_sequence, {130, 224}}]}, 1_000
    assert Worker.status(worker).counters.throws == 1
  end

  @tag :tmp_dir
  test "a bola diz QUAL pokémon o acervo reconheceu", %{worker: worker} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, "catcher")

    obs =
      corpses_obs([{130, 224}])
      |> Map.put(:known, %{{130, 224} => %{name: "Corsola", score: 0.87}})

    world!(worker, obs)

    assert_receive {:performed, :high, [{:capture_sequence, {130, 224}}]}, 1_000
    assert_log_eventually("🎯 Corsola reconhecido (87%)")
  end

  @tag :tmp_dir
  test "o start anuncia o acervo — vazio é sirene, não silêncio", %{worker: worker} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, "catcher")

    # o tmp deste teste não tem corpses.json: acervo vazio = captura cega
    :ok = Worker.run(worker)

    assert_receive {:rule_alarm, msg}, 1_000
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

  @tag :tmp_dir
  test "polling alone confirms a vanished corpse (no further events)", %{worker: worker} do
    world!(worker, corpses_obs([{130, 224}]))
    assert_receive {:performed, :high, _}, 1_000

    # the feed keeps RE-PUTTING fresh empty observations without broadcasting (no change);
    # simulate that and let the worker's wake polling find them
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
    # no {:world,...} event — only the kill accelerator
    Phoenix.PubSub.broadcast(Pokex.PubSub, Worker.kill_topic(), {:kill})

    assert_receive {:performed, :high, [{:capture_sequence, {140, 230}}]}, 1_000
  end

  @tag :tmp_dir
  test "movimento mode never acts", %{worker: worker} do
    Settings.put(:player_mode, "movimento")
    :ok = Worker.mode_changed(worker)
    assert Worker.status(worker).state == :manual

    world!(worker, corpses_obs([{130, 224}]))
    refute_receive {:performed, _p, _a}, 300

    # flipping back re-arms
    Settings.put(:player_mode, "parado")
    :ok = Worker.mode_changed(worker)
    assert Worker.status(worker).state == :armed
  end

  @tag :tmp_dir
  test "mode_changed on a HALTED worker never re-attaches the feed", %{worker: worker} do
    :ok = Worker.halt(worker)
    assert Worker.status(worker).state == :idle

    # poking the mode on a halted worker must not resurrect the feed attachment:
    # a corpse event afterwards must produce no throws
    :ok = Worker.mode_changed(worker)
    world!(worker, corpses_obs([{130, 224}]))
    refute_receive {:performed, _p, _a}, 300
    assert Worker.status(worker).state == :idle
  end

  @tag :tmp_dir
  test "a fight in progress holds all throws", %{worker: worker} do
    # combat engages — a corpse observation arriving mid-fight must be held: the stationary
    # blob the detector sees might just be the live, tile-locked enemy sprite
    send(worker, {:combat, %{state: :fighting, counters: %{}, error: nil, locked_row: 0}})

    world!(worker, corpses_obs([{150, 250}]))
    refute_receive {:performed, _p, _a}, 300
    assert Worker.status(worker).hold_reason == "esperando fim da luta"

    # the fight ends (kill or disengage) — a fresh corpse is already sitting in the world;
    # the disengage edge must re-check it immediately and throw, no waiting on the next poll
    fresh = corpses_obs([{150, 250}])
    WorldState.put(:corpses, fresh, fresh.captured_at)
    send(worker, {:combat, %{state: :hunting, counters: %{}, error: nil, locked_row: nil}})

    assert_receive {:performed, :high, [{:capture_sequence, {150, 250}}]}, 1_000
    assert Worker.status(worker).hold_reason == nil
    assert %{text: "bola arremessada", at: at} = Worker.status(worker).last_action
    assert is_integer(at)
  end

  @tag :tmp_dir
  test "the mini-game fact freezes loots and throws; the next event after it clears acts", %{
    worker: worker
  } do
    WorldState.put(
      :mini_game,
      %{playing?: true, confidence: 1.0},
      System.monotonic_time(:millisecond)
    )

    on_exit(fn -> WorldState.forget(:mini_game) end)

    # a kill lands mid-game: NO Space loot (Space is the mini-game's control key!), no ball
    obs = corpses_obs([{130, 224}])
    WorldState.put(:corpses, obs, obs.captured_at)
    Phoenix.PubSub.broadcast(Pokex.PubSub, Worker.kill_topic(), {:kill})
    refute_receive {:performed, _p, _a}, 300

    # game over: the catcher is event-driven — the next corpse event acts normally
    WorldState.forget(:mini_game)
    world!(worker, corpses_obs([{130, 224}]))
    assert_receive {:performed, :high, [{:capture_sequence, {130, 224}}]}, 1_000
  end

  @tag :tmp_dir
  test "relearn resets pending state", %{worker: worker} do
    world!(worker, corpses_obs([{160, 260}]))
    assert_receive {:performed, :high, [{:capture_sequence, {160, 260}}]}, 1_000
    assert Worker.status(worker).counters.throws == 1

    :ok = Worker.relearn(worker)

    # a warmup frame right after relearn: empty corpses, but scanning?: false — must never be
    # read as "the old pending throw's corpse vanished" (it would falsely confirm a capture
    # that never happened, and the NEXT queued throw would aim at the OLD spot's coordinates)
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

    # global Combat.Worker is idle in tests → seed is false → the gate is open again
    world!(worker, corpses_obs([{130, 224}]))
    assert_receive {:performed, :high, [{:capture_sequence, {130, 224}}]}, 1_000
  end

  @tag :tmp_dir
  test "a kill triggers the Space loot presses before any ball", %{worker: worker} do
    # a corpse is already detectable — the ball WOULD fire on the kill's re-read
    obs = corpses_obs([{130, 224}])
    WorldState.put(:corpses, obs, obs.captured_at)

    Phoenix.PubSub.broadcast(Pokex.PubSub, Worker.kill_topic(), {:kill})

    # FIRST perform must be the loot (2 presses with the configured gap), ball second
    assert_receive {:performed, :high, loot_actions}, 1_000
    assert loot_actions == [{:press, "space"}, {:wait, 250}, {:press, "space"}]

    assert_receive {:performed, :high, [{:capture_sequence, {130, 224}}]}, 1_000
    assert Worker.status(worker).counters.loots == 1
    # the ball lands after the loot, so it owns the pill's "última ação"
    assert %{text: "bola arremessada", at: _} = Worker.status(worker).last_action
  end

  @tag :tmp_dir
  test "loot_enabled false: kills loot nothing (balls unaffected)", %{worker: worker} do
    Settings.put(:loot_enabled, false)

    obs = corpses_obs([{130, 224}])
    WorldState.put(:corpses, obs, obs.captured_at)
    Phoenix.PubSub.broadcast(Pokex.PubSub, Worker.kill_topic(), {:kill})

    assert_receive {:performed, :high, actions}, 1_000
    assert actions == [{:capture_sequence, {130, 224}}]
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
    refute_receive {:performed, _, [{:capture_sequence, _} | _]}, 400

    # a direct corpse event is also gated
    world!(worker, corpses_obs([{140, 230}]))
    refute_receive {:performed, _, [{:capture_sequence, _} | _]}, 300
  end

  @tag :tmp_dir
  # Space reaches the corpse on the tile where the kill landed, wherever he
  # happens to be standing at that instant — so walking must not cost him the
  # drops. Only the BALL needs the standing-still ground baseline.
  @tag :tmp_dir
  test "movimento: o kill SAQUEIA, mas nunca joga bola", %{worker: worker} do
    Settings.put(:player_mode, "movimento")
    :ok = Worker.mode_changed(worker)

    obs = corpses_obs([{140, 230}])
    WorldState.put(:corpses, obs, obs.captured_at)
    Phoenix.PubSub.broadcast(Pokex.PubSub, Worker.kill_topic(), {:kill})

    assert_receive {:performed, :high, [{:press, "space"}, {:wait, 250}, {:press, "space"}]},
                   1_000

    assert Worker.status(worker).counters.loots == 1
    refute_receive {:performed, _p, [{:capture_sequence, _} | _]}, 300
  end

  @tag :tmp_dir
  test "movimento com o saque desligado: o kill não faz nada", %{worker: worker} do
    Settings.put(:player_mode, "movimento")
    Settings.put(:loot_enabled, false)
    :ok = Worker.mode_changed(worker)

    Phoenix.PubSub.broadcast(Pokex.PubSub, Worker.kill_topic(), {:kill})
    refute_receive {:performed, _p, _a}, 300
  end

  @tag :tmp_dir
  test "producer order (kill first, snapshot second) makes loot precede the ball", %{
    worker: worker
  } do
    # engage: the worker holds everything while the fight runs
    send(worker, {:combat, %{state: :fighting, counters: %{}, error: nil, locked_row: 0}})

    # a mature corpse observation is already in the world (the enemy stood on the melee tile)
    obs = corpses_obs([{130, 224}])
    WorldState.put(:corpses, obs, obs.captured_at)

    # the combat worker emits KILL then the hunting snapshot (post-fix producer order)
    Phoenix.PubSub.broadcast(Pokex.PubSub, Worker.kill_topic(), {:kill})

    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      "combat",
      {:combat, %{state: :hunting, counters: %{}, error: nil, locked_row: nil}}
    )

    # FIRST perform must be the Space loot; the ball comes on the disengage advance
    assert_receive {:performed, :high, [{:press, "space"} | _]}, 1_000
    assert_receive {:performed, :high, [{:capture_sequence, {130, 224}}]}, 1_000
  end

  defp eventually(fun, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      if fun.(), do: true, else: Process.sleep(20) && false
    end)
    |> Enum.find(fn done -> done or System.monotonic_time(:millisecond) > deadline end)
  end
end
