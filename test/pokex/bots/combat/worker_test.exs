defmodule Pokex.Bots.Combat.WorkerTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.Combat.Worker
  alias Pokex.Calibration
  alias Pokex.Perception.WorldState
  alias Pokex.Rig.Fake
  alias Pokex.Settings
  alias Pokex.SettingsStash

  setup %{tmp_dir: tmp} do
    # one shared blackboard: start from an empty world, never from the last test's
    WorldState.clear()

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
      :ets.delete(:pokex_world, :skill_bar)
      # a posture left behind would make the NEXT test's combat pacifist
      :ets.delete(:pokex_world, :posture)
    end)

    Calibration.save(%Calibration{
      scale: 1.0,
      screen_w: 1000,
      screen_h: 700,
      water_point: {400, 300},
      glow_region: {0, 0, 20, 20},
      battle_region: {0, 0, 80, 400},
      neutral_point: {500, 500}
    })

    {:ok, _} = Fake.start_link(%{})
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
    for {:press, key} <- Fake.calls(), do: key
  end

  @tag :tmp_dir
  test "at most ONE key burst in flight — a decision landing mid-burst skips, never stacks", %{
    worker: worker
  } do
    # re-script the Fake with a slow (osascript-like) burst so the first one is still in
    # flight when the next decision arrives
    Agent.stop(Fake)
    {:ok, _} = Fake.start_link(%{press_many_sleep_ms: 250})

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

    # the dispatched burst is the pill's "última ação"
    assert %{text: "teclas " <> _, at: at} = Worker.status(worker).last_action
    assert is_integer(at)
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
  test "a fresh :skill_bar fact narrows every skill burst to READY keys only", %{worker: worker} do
    # only "2" is ready → all skill presses must be "2"; Tab is not a skill and stays
    put_fact = fn ->
      at = System.monotonic_time(:millisecond)
      WorldState.put(:skill_bar, %{states: [:cooldown, :ready], ready_keys: ["2"]}, at)
    end

    put_fact.()
    world!(worker, battle_obs(enemies: [0]))
    assert eventually(fn -> Worker.status(worker).state == :tabbing end)

    world!(worker, battle_obs(locked?: true, locked_row: 0))
    assert eventually(fn -> Worker.status(worker).state == :fighting end)

    # keep the fact fresh and the frames flowing (same re-feed dance as the burst tests)
    assert eventually(fn ->
             skills = Enum.reject(presses(), &(&1 == Settings.get(:tab_key)))

             (skills != [] and Enum.uniq(skills) == ["2"]) or
               (put_fact.() && world!(worker, battle_obs(locked?: true, locked_row: 0)) && false)
           end)

    skills = Enum.reject(presses(), &(&1 == Settings.get(:tab_key)))
    assert skills != [] and Enum.uniq(skills) == ["2"]
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
    assert Worker.status(worker).hold_reason == "mini-game em jogo"

    # game over: leave a fresh battle picture for the resume to read, clear the fact —
    # the worker's own held :wake poll must resume it with NO further :world events
    at = now_ms()
    WorldState.put(:battle, battle_obs(enemies: [0]) |> Map.put(:captured_at, at), at)
    WorldState.forget(:mini_game)

    assert eventually(fn -> Settings.get(:tab_key) in presses() end)
    assert Worker.status(worker).state == :tabbing
    assert Worker.status(worker).hold_reason == nil
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
    assert eventually(fn -> Enum.any?(presses(), &(&1 == Settings.get(:tab_key))) end)

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

  # The hunt asks for quiet by publishing the `:posture` fact; this worker
  # obeys a READING with an age, never a command it has to remember.
  describe "holding fire while the hunt gathers mobs" do
    defp posture!(posture) do
      WorldState.put(:posture, %{posture: posture}, System.monotonic_time(:millisecond))
    end

    @tag :tmp_dir
    test "a full battle list presses nothing while the fact says hold fire", %{worker: worker} do
      posture!(:hold_fire)
      world!(worker, battle_obs(enemies: [0, 1, 2]))

      refute eventually(fn -> Settings.get(:tab_key) in presses() end, 300)
      assert Worker.status(worker).state == :hunting
      assert Worker.status(worker).hold_reason == "segurando o fogo (trecho de mob)"

      posture!(:free_fight)
      world!(worker, battle_obs(enemies: [0, 1, 2]))

      assert eventually(fn -> Settings.get(:tab_key) in presses() end)
      assert Worker.status(worker).hold_reason == nil
    end

    # The fact ages out on its own: a hunt that dies mid mob stretch must not
    # leave the bot standing pacifist in the crowd it just gathered.
    @tag :tmp_dir
    test "a posture nobody is refreshing goes stale and combat fights again", %{worker: worker} do
      SettingsStash.stash!(posture_max_age_ms: 500)

      WorldState.put(
        :posture,
        %{posture: :hold_fire},
        System.monotonic_time(:millisecond) - 5_000
      )

      world!(worker, battle_obs(enemies: [0]))

      assert eventually(fn -> Settings.get(:tab_key) in presses() end)
    end

    @tag :tmp_dir
    test "with no fact at all it fights, exactly as it always did", %{worker: worker} do
      WorldState.forget(:posture)
      world!(worker, battle_obs(enemies: [0]))

      assert eventually(fn -> Settings.get(:tab_key) in presses() end)
    end
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
