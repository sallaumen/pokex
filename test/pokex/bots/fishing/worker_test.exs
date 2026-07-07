defmodule Pokex.Bots.Fishing.WorkerTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.Fishing.Worker
  alias Pokex.Bots.Fisher.Sensors
  alias Pokex.{Calibration, Settings}

  @fast %{
    wait_focus_ms: 5,
    wait_after_equip_ms: 5,
    wait_cast_settle_ms: 5,
    wait_assess_ms: 5,
    tick_ms_watching: 20,
    tick_ms_default: 20,
    watch_dead_streak_needed: 1000,
    watch_timeout_ms: 30_000,
    calm_streak_needed: 1,
    glow_streak_needed: 1,
    glow_threshold: 500,
    max_consecutive_failures: 5,
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

    # Watching needs [:cursor, :glow]. The RAW glow count starts under threshold
    # (calm, so watching settles) then spikes over threshold (a bite) — proving
    # the worker applies threshold_glow/2 before Logic ever sees a boolean.
    {:ok, _} =
      Sensors.Fake.start_link(%{
        glow: [50, 900]
      })

    {:ok, _} = Pokex.Bots.Body.start_link(name: :fishing_worker_test_body)
    worker = start_supervised!({Worker, name: nil, body: :fishing_worker_test_body})
    %{worker: worker}
  end

  @tag :tmp_dir
  test "runs focus -> equip -> cast -> watch -> hook, submitting to the Body at :normal", %{
    worker: worker
  } do
    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())

    assert :ok = Worker.run(worker)
    assert_receive {:fishing, %{state: :casting, counters: %{hooked: 1}}}, 5_000

    calls = Pokex.Rig.Fake.calls()
    assert {:click, :left, {420, 350}} in calls
    assert {:press, "v"} in calls
    assert {:click, :left, {400, 300}} in calls

    assert :ok = Worker.halt(worker)
    assert Worker.status(worker).state == :idle
  end

  @tag :tmp_dir
  test "a raw glow count over the threshold becomes a bite that hooks (rod press)", %{
    worker: worker
  } do
    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())

    assert :ok = Worker.run(worker)
    assert_receive {:fishing, %{state: :casting, counters: %{hooked: 1}}}, 5_000

    # two rod presses: one to equip, one to pull the hook after the bite.
    calls = Pokex.Rig.Fake.calls()
    assert Enum.count(calls, &(&1 == {:press, "v"})) == 2
  end

  @tag :tmp_dir
  test "the cast is submitted to the Body at :normal priority", %{worker: worker} do
    # Occupy the shared Body with a queued :high action first, so the fishing
    # cast provably waits behind it (proves :normal routing).
    test = self()

    spawn(fn ->
      send(
        test,
        {:high_result,
         Pokex.Bots.Body.perform([{:press, "occupy"}], :high, :fishing_worker_test_body)}
      )
    end)

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    assert :ok = Worker.run(worker)

    assert_receive {:high_result, :ok}, 2_000
    assert_receive {:fishing_log, _}, 2_000

    calls = Pokex.Rig.Fake.calls()
    assert {:click, :left, {420, 350}} in calls
  end

  @tag :tmp_dir
  test "start without calibration returns preflight errors", %{worker: worker} do
    File.rm!(Pokex.Home.calibration_file())
    assert {:error, [msg]} = Worker.run(worker)
    assert msg =~ "calibração"
  end

  @tag :tmp_dir
  test "a Body I/O failure drives Logic.io_failed and stays recoverable", %{worker: worker} do
    previous_rig = Application.get_env(:pokex, :rig)
    Application.put_env(:pokex, :rig, Pokex.Bots.Fishing.WorkerTest.FailingRig)
    on_exit(fn -> Application.put_env(:pokex, :rig, previous_rig) end)

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    assert :ok = Worker.run(worker)

    assert_receive {:fishing, %{state: :focusing, error: nil}}, 3_000

    assert_receive {:fishing, %{state: :equipping, error: nil, counters: %{failures: failures}}},
                   3_000

    assert failures >= 1
  end
end

defmodule Pokex.Bots.Fishing.WorkerTest.FailingRig do
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
