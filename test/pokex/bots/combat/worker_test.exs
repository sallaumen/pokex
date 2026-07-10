defmodule Pokex.Bots.Combat.WorkerTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.Combat.Worker
  alias Pokex.Perception.WorldState
  alias Pokex.{Calibration, Settings}

  @keys [
    :tab_confirm_ms,
    :tab_max_attempts,
    :hunt_cooldown_ms,
    :skill_burst_every_ms,
    :combat_world_max_age_ms,
    :skill_keys
  ]

  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    originals = Map.new(@keys, &{&1, Settings.get(&1)})

    on_exit(fn ->
      Application.delete_env(:pokex, :home_dir)
      Enum.each(originals, fn {k, v} -> Settings.put(k, v) end)
      :ets.delete(:pokex_world, :battle)
      :ets.delete(:pokex_world, :arena)
    end)

    Settings.put(:skill_burst_every_ms, 0)

    Calibration.save(%Calibration{
      scale: 1.0,
      screen_w: 1000,
      screen_h: 700,
      water_point: {400, 300},
      glow_region: {0, 0, 20, 20},
      battle_region: {0, 0, 80, 400},
      arena_region: {100, 100, 60, 40},
      neutral_point: {500, 500}
    })

    {:ok, _} = Pokex.Rig.Fake.start_link(%{})
    worker = start_supervised!({Worker, name: nil})
    :ok = Worker.run(worker)
    %{worker: worker}
  end

  defp battle_obs(fields) do
    Enum.into(fields, %{
      enemies: [],
      red: [],
      locked?: false,
      locked_row: nil,
      captured_at: System.monotonic_time(:millisecond)
    })
  end

  defp world!(worker, obs) do
    obs = %{obs | captured_at: fresh_captured_at()}
    WorldState.put(:battle, obs, obs.captured_at)
    send(worker, {:world, :battle, obs})
  end

  # Every call gets a captured_at strictly newer than "now" at call time (so a post-Tab
  # frame is deterministically newer than tabbed_at — guards F1's strict freshness check)
  # AND strictly newer than the previous call's (guards Logic's frame dedup: two world!
  # calls in a row must look like two DISTINCT frames, never a re-read of the same one).
  defp fresh_captured_at do
    seq = Process.get(:world_seq, 0) + 5
    Process.put(:world_seq, seq)
    System.monotonic_time(:millisecond) + seq
  end

  defp presses do
    for {:press, key} <- Pokex.Rig.Fake.calls(), do: key
  end

  @tag :tmp_dir
  test "an enemy observation makes it press Tab", %{worker: worker} do
    world!(worker, battle_obs(enemies: [0]))

    assert eventually(fn -> Settings.get(:tab_key) in presses() end)
    assert Worker.status(worker).state == :tabbing
  end

  @tag :tmp_dir
  test "a post-Tab locked observation confirms the fight and fires skills", %{worker: worker} do
    world!(worker, battle_obs(enemies: [0]))
    assert eventually(fn -> Worker.status(worker).state == :tabbing end)

    world!(worker, battle_obs(locked?: true, locked_row: 0))
    assert eventually(fn -> Worker.status(worker).state == :fighting end)
    assert eventually(fn -> "1" in presses() end)
  end

  @tag :tmp_dir
  test "lock lost for the streak broadcasts the kill with the arena corpse", %{worker: worker} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, Pokex.Bots.Loot.Worker.kill_topic())

    now = System.monotonic_time(:millisecond)
    WorldState.put(:arena, %{hostile: {123, 456}, captured_at: now}, now)

    world!(worker, battle_obs(enemies: [0]))
    assert eventually(fn -> Worker.status(worker).state == :tabbing end)
    world!(worker, battle_obs(locked?: true, locked_row: 0))
    assert eventually(fn -> Worker.status(worker).state == :fighting end)

    world!(worker, battle_obs(locked?: false))
    world!(worker, battle_obs(locked?: false))

    assert_receive {:kill, {123, 456}}, 1_000
    assert Worker.status(worker).counters.fights == 1
  end

  @tag :tmp_dir
  test "halt detaches and goes idle", %{worker: worker} do
    assert :ok = Worker.halt(worker)
    assert Worker.status(worker).state == :idle

    world!(worker, battle_obs(enemies: [0]))
    refute eventually(fn -> Worker.status(worker).state == :tabbing end, 300)
  end

  @tag :tmp_dir
  test "a static locked-lost screen reaches the kill from :wake polling alone, no further :world events",
       %{worker: worker} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, Pokex.Bots.Loot.Worker.kill_topic())

    world!(worker, battle_obs(enemies: [0]))
    assert eventually(fn -> Worker.status(worker).state == :tabbing end)
    world!(worker, battle_obs(locked?: true, locked_row: 0))
    assert eventually(fn -> Worker.status(worker).state == :fighting end)

    # From here on: NO more :world events (the feed wouldn't broadcast either — the
    # content stopped changing). Simulate the feed's own per-tick ETS writes (a fresh
    # captured_at every ~120ms in production, even when the content is identical)
    # directly against WorldState: the worker's :wake polling must reach the kill on
    # its own, reading the SAME table the real feed writes.
    for _ <- 1..8 do
      at = System.monotonic_time(:millisecond)
      WorldState.put(:battle, battle_obs(locked?: false) |> Map.put(:captured_at, at), at)
      Process.sleep(100)
    end

    assert_receive {:kill, _}, 1_000
    assert Worker.status(worker).counters.fights == 1
  end

  @tag :tmp_dir
  test "a key-burst failure steps io_failed; repeated failures error the worker out",
       %{worker: worker} do
    send(worker, {:key_burst_failed, :boom})
    status = Worker.status(worker)
    assert status.state in [:hunting, :tabbing, :fighting]
    assert status.counters.failures == 1
    assert status.error == nil

    for _ <- 1..4, do: send(worker, {:key_burst_failed, :boom})

    status = Worker.status(worker)
    assert status.state == :error
    assert status.counters.failures == 5
    assert status.error =~ "boom"

    # once errored, further failures are ignored (no reactivation from a stale async task)
    send(worker, {:key_burst_failed, :boom})
    assert Worker.status(worker).counters.failures == 5
  end

  defp eventually(fun, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(fun, deadline)
  end

  defp poll(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) > deadline ->
        false

      true ->
        Process.sleep(20)
        poll(fun, deadline)
    end
  end
end
