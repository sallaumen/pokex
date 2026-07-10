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
    mode = Settings.get(:capture_mode)

    on_exit(fn ->
      Application.delete_env(:pokex, :home_dir)
      Settings.put(:capture_mode, mode)
      :ets.delete(:pokex_world, :corpses)
    end)

    Settings.put(:capture_mode, "parado")

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
  test "a corpse observation makes it throw a ball at :high", %{worker: worker} do
    world!(worker, corpses_obs([{130, 224}]))
    assert_receive {:performed, :high, [{:capture_sequence, {130, 224}}]}, 1_000
    assert Worker.status(worker).counters.throws == 1
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
    Settings.put(:capture_mode, "movimento")
    :ok = Worker.mode_changed(worker)
    assert Worker.status(worker).state == :manual

    world!(worker, corpses_obs([{130, 224}]))
    refute_receive {:performed, _p, _a}, 300

    # flipping back re-arms
    Settings.put(:capture_mode, "parado")
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

  defp eventually(fun, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      if fun.(), do: true, else: Process.sleep(20) && false
    end)
    |> Enum.find(fn done -> done or System.monotonic_time(:millisecond) > deadline end)
  end
end
