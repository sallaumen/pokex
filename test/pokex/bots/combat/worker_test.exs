defmodule Pokex.Bots.Combat.WorkerTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.Combat.Worker
  alias Pokex.Bots.Fisher.Sensors
  alias Pokex.{Calibration, Settings}

  @fast %{
    tick_ms_fighting: 20,
    tick_ms_default: 20,
    wait_target_verify_ms: 5,
    target_lock_streak: 1,
    target_verify_attempts: 1,
    tile_px: 32,
    walk_step_ms: 5,
    wait_loot_ms: 5,
    wait_after_capture_ms: 5,
    humanize_max_ms: 0,
    cast_delay_max_ms: 0,
    hook_delay_min_ms: 0,
    hook_delay_max_ms: 0
  }

  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)

    on_exit(fn ->
      Application.delete_env(:pokex, :home_dir)
      Enum.each(Settings.defaults(), fn {k, v} -> Settings.put(k, v) end)
    end)

    Enum.each(@fast, fn {k, v} -> Settings.put(k, v) end)

    Calibration.save(%Calibration{
      scale: 2.0,
      screen_w: 1000,
      screen_h: 700,
      water_point: {400, 300},
      glow_region: {368, 268, 64, 64},
      battle_region: {700, 100, 260, 200},
      arena_region: {200, 100, 400, 400},
      neutral_point: {420, 350}
    })

    {:ok, _} = Pokex.Rig.Fake.start_link()

    {:ok, _} =
      Sensors.Fake.start_link(%{
        # click row 0, lock persists one attack tick, then vanishes with the
        # strip clear (no survivor) → dead → loot → capture.
        battle_lock: [
          [0, 0, 0, 0, 0, 0],
          [600, 0, 0, 0, 0, 0],
          [600, 0, 0, 0, 0, 0],
          [0, 0, 0, 0, 0, 0],
          [0, 0, 0, 0, 0, 0]
        ],
        hostile: [{410, 320}]
      })

    {:ok, _} = Pokex.Bots.Body.start_link(name: :combat_worker_test_body)
    worker = start_supervised!({Worker, name: nil, body: :combat_worker_test_body})
    %{worker: worker}
  end

  @tag :tmp_dir
  test "runs the full combat cycle: scan, lock, fight, loot, capture", %{worker: worker} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())

    assert :ok = Worker.run(worker)
    assert_receive {:combat, %{state: :scanning, counters: %{captures: 1}}}, 5_000

    calls = Pokex.Rig.Fake.calls()
    assert {:click, :left, {786, 118}} in calls
    assert {:move, {420, 350}} in calls
    assert {:press, "1"} in calls
    assert {:press, "space"} in calls
    assert Enum.any?(calls, &match?({:capture_sequence, _}, &1))

    assert :ok = Worker.halt(worker)
    assert Worker.status(worker).state == :idle
  end

  @tag :tmp_dir
  test "the select click+move is submitted to the Body at :high priority", %{worker: worker} do
    # Occupy the shared Body with a queued :normal action first, so the
    # combat select click provably jumps ahead of it (proves :high routing,
    # not just that the click eventually happens).
    test = self()

    spawn(fn ->
      send(
        test,
        {:normal_result,
         Pokex.Bots.Body.perform([{:press, "occupy"}], :normal, :combat_worker_test_body)}
      )
    end)

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    assert :ok = Worker.run(worker)

    assert_receive {:combat_log, _level, _}, 2_000
    assert_receive {:normal_result, :ok}, 2_000

    calls = Pokex.Rig.Fake.calls()
    assert {:click, :left, {786, 118}} in calls
  end

  @tag :tmp_dir
  test "start without calibration returns preflight errors", %{worker: worker} do
    File.rm!(Pokex.Home.calibration_file())
    assert {:error, [msg]} = Worker.run(worker)
    assert msg =~ "calibração"
  end

  @tag :tmp_dir
  test "a Body I/O failure drives Logic.io_failed and stays recoverable (scanning)", %{
    worker: worker
  } do
    previous_rig = Application.get_env(:pokex, :rig)
    Application.put_env(:pokex, :rig, Pokex.Bots.Combat.WorkerTest.FailingRig)
    on_exit(fn -> Application.put_env(:pokex, :rig, previous_rig) end)

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    assert :ok = Worker.run(worker)

    # first broadcast is the pre-tick :scanning snapshot (zero failures yet);
    # wait for a SECOND :combat broadcast — that's the tick where the click
    # failed through the Body and Logic.io_failed bumped counters.failures.
    assert_receive {:combat, %{state: :scanning, error: nil}}, 3_000

    assert_receive {:combat, %{state: :scanning, error: nil, counters: %{failures: failures}}},
                   3_000

    assert failures >= 1
    assert Worker.status(worker).state == :scanning
  end
end

defmodule Pokex.Bots.Combat.WorkerTest.FailingRig do
  @moduledoc "Rig double whose click always errors, to drive the worker's io_failed path."
  @behaviour Pokex.Rig

  @impl true
  def press(_combo), do: :ok
  @impl true
  def click(_button, _point), do: {:error, :boom}
  @impl true
  def move(_point), do: :ok
  @impl true
  def capture_sequence(_point), do: :ok
  @impl true
  def capture(_region, filename), do: {:ok, filename}
  @impl true
  def capture_screen, do: {:ok, "screen.png"}
  @impl true
  def cursor_position, do: {:ok, {500, 500}}
end
