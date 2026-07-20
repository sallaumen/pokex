defmodule Pokex.Bots.Combat.WorkerTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.Combat.Worker
  alias Pokex.Perception.WorldState
  alias Pokex.{Calibration, Settings, SettingsStash}

  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)

    SettingsStash.stash!(skill_burst_every_ms: 0)

    SettingsStash.stash_keys!([
      :tab_confirm_ms,
      :tab_max_attempts,
      :hunt_cooldown_ms,
      :combat_world_max_age_ms,
      :skill_keys
    ])

    on_exit(fn ->
      Application.delete_env(:pokex, :home_dir)
      :ets.delete(:pokex_world, :battle)
      :ets.delete(:pokex_world, :arena)
    end)

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
  test "at most ONE key burst in flight — a decision landing mid-burst skips, never stacks", %{
    worker: worker
  } do
    # re-script the Fake with a slow (osascript-like) burst so the first one is still in
    # flight when the next decision arrives
    Agent.stop(Pokex.Rig.Fake)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{press_many_sleep_ms: 250})

    # Tab burst (slow) spawns...
    world!(worker, battle_obs(enemies: [0]))
    assert eventually(fn -> Worker.status(worker).state == :tabbing end)

    # ...and the lock lands while it is STILL in flight → the skill burst must be SKIPPED
    world!(worker, battle_obs(locked?: true, locked_row: 0))
    assert eventually(fn -> Worker.status(worker).state == :fighting end)

    Process.sleep(400)
    assert presses() == [Settings.get(:tab_key)]

    # burst 1 done → the next locked frame fires a fresh skill burst normally
    world!(worker, battle_obs(locked?: true, locked_row: 0))
    assert eventually(fn -> length(presses()) > 1 end)
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

    # keep feeding fresh locked frames while we wait, like the real feed's ~120ms writes do —
    # a burst that lands while the (fast) Tab spawn is still alive is legitimately SKIPPED
    # (one-burst-in-flight), and the NEXT fresh frame is what re-fires it
    assert eventually(fn ->
             "1" in presses() or
               (world!(worker, battle_obs(locked?: true, locked_row: 0)) && false)
           end)
  end

  @tag :tmp_dir
  test "lock lost for the streak broadcasts the kill", %{worker: worker} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, Pokex.Bots.Catcher.Worker.kill_topic())

    world!(worker, battle_obs(enemies: [0]))
    assert eventually(fn -> Worker.status(worker).state == :tabbing end)
    world!(worker, battle_obs(locked?: true, locked_row: 0))
    assert eventually(fn -> Worker.status(worker).state == :fighting end)

    world!(worker, battle_obs(locked?: false))
    world!(worker, battle_obs(locked?: false))

    assert_receive {:kill}, 1_000
    assert Worker.status(worker).counters.fights == 1
  end

  @tag :tmp_dir
  test "holds itself while the :mini_game fact says playing, restarts fresh when it clears", %{
    worker: worker
  } do
    WorldState.put(:mini_game, %{playing?: true, confidence: 1.0}, now_ms())
    on_exit(fn -> WorldState.forget(:mini_game) end)

    # an enemy shows up mid-game: NO Tab — the worker froze itself
    world!(worker, battle_obs(enemies: [0]))
    refute eventually(fn -> Settings.get(:tab_key) in presses() end, 400)

    # game over: leave a fresh battle picture for the resume to read, clear the fact —
    # the worker's own held :wake poll must resume it with NO further :world events
    at = now_ms()
    WorldState.put(:battle, battle_obs(enemies: [0]) |> Map.put(:captured_at, at), at)
    WorldState.forget(:mini_game)

    assert eventually(fn -> Settings.get(:tab_key) in presses() end)
    assert Worker.status(worker).state == :tabbing
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

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
    Phoenix.PubSub.subscribe(Pokex.PubSub, Pokex.Bots.Catcher.Worker.kill_topic())

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

    assert_receive {:kill}, 1_000
    assert Worker.status(worker).counters.fights == 1
  end

  @tag :tmp_dir
  test "C1: after a kill, free hunting reaches :tabbing again (Tab pressed a 2nd time) via :wake polling alone",
       %{worker: worker} do
    world!(worker, battle_obs(enemies: [0]))
    assert eventually(fn -> Worker.status(worker).state == :tabbing end)
    world!(worker, battle_obs(locked?: true, locked_row: 0))
    assert eventually(fn -> Worker.status(worker).state == :fighting end)

    world!(worker, battle_obs(locked?: false))
    world!(worker, battle_obs(locked?: false))
    assert eventually(fn -> Worker.status(worker).state == :hunting end)
    assert Worker.status(worker).counters.fights == 1

    # The Tab press itself lands via an async spawned task (dispatch/1), so its arrival in
    # Fake can lag a hair behind the synchronous state transition above — eventually, not a
    # bare assert (this used to be masked by sync_arena's now-removed Perception.attach/detach
    # call adding incidental latency to the worker's own message loop). ≥ 1, not == 1: the
    # post-kill probe window now fires additional blind Tabs by design.
    assert eventually(fn -> Enum.count(presses(), &(&1 == Settings.get(:tab_key))) >= 1 end)

    # From here on: NO more :world events (the feed wouldn't broadcast either — a
    # non-empty-but-pixel-static battle list is not a content CHANGE). Seed WorldState
    # directly with fresh enemies-present frames on a short loop, exactly like the feed's
    # own per-tick ETS writes — free :hunting's own poll (C1's next_wake fix) must pick
    # them up and press Tab again, with nothing driving it but the worker's :wake timer.
    for _ <- 1..8 do
      at = System.monotonic_time(:millisecond)
      WorldState.put(:battle, battle_obs(enemies: [0]) |> Map.put(:captured_at, at), at)
      Process.sleep(100)
    end

    assert eventually(fn -> Worker.status(worker).state == :tabbing end)
    assert Enum.count(presses(), &(&1 == Settings.get(:tab_key))) >= 2
  end

  @tag :tmp_dir
  test "I1: :reattach_battle is a liveness no-op while already attached, worker keeps stepping",
       %{worker: worker} do
    # Exercising the real feed-restart path cheaply isn't practical here (it needs the
    # supervisor to actually kill+restart the registered Feed process); this pins the
    # handler directly: with logic active and already attached, :reattach_battle must not
    # crash or wedge the worker, and a subsequent world event still steps it normally.
    send(worker, :reattach_battle)
    assert Process.alive?(worker)

    world!(worker, battle_obs(enemies: [0]))
    assert eventually(fn -> Worker.status(worker).state == :tabbing end)
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
