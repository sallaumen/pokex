defmodule Pokex.Bots.Loot.WorkerTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.Loot.Worker
  alias Pokex.{Calibration, Settings}

  @fast %{
    tick_ms_default: 10,
    tile_px: 32,
    walk_step_ms: 5,
    wait_loot_ms: 5,
    wait_after_capture_ms: 5,
    loot_presses: 2
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
    {:ok, _} = Pokex.Bots.Body.start_link(name: :loot_worker_test_body)
    worker = start_supervised!({Worker, name: nil, body: :loot_worker_test_body})
    %{worker: worker}
  end

  @tag :tmp_dir
  test "a kill event before running is a safe no-op", %{worker: worker} do
    Phoenix.PubSub.broadcast(Pokex.PubSub, Worker.kill_topic(), {:kill, {410, 320}})
    assert Worker.status(worker).state == :idle
  end

  @tag :tmp_dir
  test "a {:kill, corpse} runs the full walk→loot→capture→walk-back cycle", %{worker: worker} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    assert :ok = Worker.run(worker)

    Phoenix.PubSub.broadcast(Pokex.PubSub, Worker.kill_topic(), {:kill, {410, 320}})

    assert_receive {:loot, %{state: :idle, counters: %{loots: 1, captures: 1}}}, 5_000

    calls = Pokex.Rig.Fake.calls()
    assert {:press, "space"} in calls
    assert Enum.any?(calls, &match?({:capture_sequence, _}, &1))
    # walked out AND back (a "down" out, "up" back) → returns to origin
    assert {:press, "down"} in calls
    assert {:press, "up"} in calls
  end

  @tag :tmp_dir
  test "a second kill while busy is DROPPED (one corpse at a time)", %{worker: worker} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    assert :ok = Worker.run(worker)

    Phoenix.PubSub.broadcast(Pokex.PubSub, Worker.kill_topic(), {:kill, {410, 320}})
    Phoenix.PubSub.broadcast(Pokex.PubSub, Worker.kill_topic(), {:kill, {410, 320}})

    # exactly one cycle runs → captures stays at 1, never 2
    assert_receive {:loot, %{state: :idle, counters: %{captures: 1}}}, 5_000
    refute_receive {:loot, %{counters: %{captures: 2}}}, 300
  end

  @tag :tmp_dir
  test "halt stops the worker (idle)", %{worker: worker} do
    assert :ok = Worker.run(worker)
    Phoenix.PubSub.broadcast(Pokex.PubSub, Worker.kill_topic(), {:kill, {410, 320}})
    assert :ok = Worker.halt(worker)
    assert Worker.status(worker).state == :idle
  end
end
