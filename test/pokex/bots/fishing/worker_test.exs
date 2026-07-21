defmodule Pokex.Bots.Fishing.WorkerTest.SlowRig do
  # Test-local Rig double: like Pokex.Rig.Fake, but click/2 blocks until
  # released (so the test can deterministically hold the Body busy instead of
  # racing a sleep against near-instant fake calls) and every call is logged
  # in arrival order. Execution order into the Rig is what actually proves
  # priority was honored. Scoped to this test file only; does not touch the
  # shared Pokex.Rig.Fake used elsewhere.
  @behaviour Pokex.Rig

  def start_link, do: Agent.start_link(fn -> %{held?: true, log: []} end, name: __MODULE__)

  def release, do: Agent.update(__MODULE__, &%{&1 | held?: false})

  def log, do: __MODULE__ |> Agent.get(& &1.log) |> Enum.reverse()

  @impl true
  def click(button, point) do
    wait_release()
    Agent.update(__MODULE__, &%{&1 | log: [{:click, button, point} | &1.log]})
    :ok
  end

  defp wait_release do
    if Agent.get(__MODULE__, & &1.held?) do
      Process.sleep(1)
      wait_release()
    else
      :ok
    end
  end

  @impl true
  def press(combo) do
    Agent.update(__MODULE__, &%{&1 | log: [{:press, combo} | &1.log]})
    :ok
  end

  @impl true
  def press_many(combos, opts) do
    tap_count = opts |> Keyword.get(:tap_count, 1) |> max(1)

    Enum.each(combos, fn combo ->
      Enum.each(1..tap_count, fn _tap -> press(combo) end)
    end)

    :ok
  end

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

defmodule Pokex.Bots.Fishing.WorkerTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.Fishing.Worker
  alias Pokex.Bots.Fisher.Sensors
  alias Pokex.Bots.Fishing.WorkerTest.SlowRig
  alias Pokex.Perception.WorldState
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

    # :focusing consumes the FIRST glow read (the live-line check: 50 < the
    # line_present_min_px of 100 → no line → the normal cast path). Then
    # watching starts under threshold (calm, so it settles) and spikes over
    # (a bite) — proving the worker applies threshold_glow/2 before Logic
    # ever sees a boolean.
    {:ok, _} =
      Sensors.Fake.start_link(%{
        glow: [50, 50, 900]
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
    # focus clicks the neutral point; the cast MOVES to the water and presses the rod
    # (Quick Cast — no water click anymore)
    assert {:click, :left, {420, 350}} in calls
    assert {:move, {400, 300}} in calls
    assert {:press, "shift+v"} in calls
    refute {:click, :left, {400, 300}} in calls

    assert :ok = Worker.halt(worker)
    assert Worker.status(worker).state == :idle
  end

  @tag :tmp_dir
  test "holds itself while the :mini_game fact says playing, recasting fresh when it clears", %{
    worker: worker
  } do
    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())

    assert :ok = Worker.run(worker)
    assert_receive {:fishing, %{state: :casting, counters: %{hooked: 1}}}, 5_000

    # the mini-game opens: the worker freezes itself — no sensing, no actions
    WorldState.put(:mini_game, %{playing?: true, confidence: 1.0}, now_ms())
    on_exit(fn -> WorldState.forget(:mini_game) end)

    # the freeze EDGE broadcasts the reason once, so the panel pill shows WHY
    assert_receive {:fishing, %{hold_reason: "mini-game em jogo"}}, 5_000

    # let in-flight ticks/Body sequences land, then the Rig must go quiet
    # ({:cursor_position} excluded: the app-global Guardian polls the panic
    # corner against this same shared Rig.Fake on its own timer)
    input_calls = fn ->
      Enum.reject(Pokex.Rig.Fake.calls(), &match?({:cursor_position}, &1))
    end

    Process.sleep(150)
    frozen = length(input_calls.())
    Process.sleep(300)
    assert length(input_calls.()) == frozen

    # game over: the worker restarts the cast cycle fresh on its own —
    # the focus click on the neutral point runs AGAIN (same as the old halt+run)
    focus_clicks = fn ->
      Enum.count(Pokex.Rig.Fake.calls(), &(&1 == {:click, :left, {420, 350}}))
    end

    # after the catch there is NO line in the water: re-script the glow low so
    # the resume's live-line check (the :focusing glow read) sees none and the
    # cycle restarts with the classic focus click + cast
    Agent.update(Sensors.Fake, &Map.merge(&1, %{glow: [50, 50, 900]}))

    before = focus_clicks.()
    WorldState.forget(:mini_game)
    assert hold_eventually(fn -> focus_clicks.() > before end)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp hold_eventually(fun, timeout \\ 2_000),
    do: hold_poll(fun, System.monotonic_time(:millisecond) + timeout)

  defp hold_poll(fun, deadline) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) > deadline -> false
      true -> Process.sleep(20) && hold_poll(fun, deadline)
    end
  end

  @tag :tmp_dir
  test "a raw glow count over the threshold becomes a bite that hooks (rod press)", %{
    worker: worker
  } do
    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())

    assert :ok = Worker.run(worker)
    assert_receive {:fishing, %{state: :casting, counters: %{hooked: 1}}}, 5_000

    # at least two rod presses by the time we've hooked once: the atomic cast arms
    # the rod, and the bite pulls it. (Each cast re-arms, so the count keeps growing.)
    calls = Pokex.Rig.Fake.calls()
    assert Enum.count(calls, &(&1 == {:press, "shift+v"})) >= 2
  end

  @tag :tmp_dir
  test "the :pokemon fact holds the hook end-to-end (fact → worker obs → Logic hold)", %{
    worker: worker
  } do
    Settings.put(:require_pokemon_hp, true)
    WorldState.put(:pokemon, %{hp_pct: 15, readable?: true}, System.monotonic_time(:millisecond))
    on_exit(fn -> WorldState.forget(:pokemon) end)

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())

    assert :ok = Worker.run(worker)
    assert wait_for_log("vida 15% < 40%", System.monotonic_time(:millisecond) + 5_000)

    # the cast armed the rod ONCE; the held bite must not pull a second press
    calls = Pokex.Rig.Fake.calls()
    assert Enum.count(calls, &(&1 == {:press, "shift+v"})) == 1
  end

  @tag :tmp_dir
  test "a lure-like false positive without a live line still triggers recast", %{worker: worker} do
    Settings.put(:watch_dead_streak_needed, 3)

    fake_lure_no_line = %{bubble_count: 0, lure_count: 180, line_present?: false}

    Agent.update(
      Sensors.Fake,
      &Map.merge(&1, %{glow: List.duplicate(fake_lure_no_line, 5)})
    )

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())

    assert :ok = Worker.run(worker)
    assert wait_for_log("re-lançando", System.monotonic_time(:millisecond) + 5_000)

    calls = Pokex.Rig.Fake.calls()
    assert Enum.count(calls, &(&1 == {:press, "shift+v"})) >= 2
  end

  @tag :tmp_dir
  test "a held bite SURFACES the lock in the feed (not just the bubble count)", %{worker: worker} do
    # The bug Lucas hit: with the gate holding the fish, the feed only showed
    # "vigiando: bolhas Npx (acima do limiar)" and never said WHY it wasn't pulling.
    # Drive a hold (gate on, no kill-skill ready) and assert the lock is visible.
    Settings.put(:require_cooldowns, true)
    # reconfigure the already-started Fake: calm→bite glow, and the gate never opens
    # first 50 feeds the :focusing live-line check (none), second settles watching
    Agent.update(
      Sensors.Fake,
      &Map.merge(&1, %{glow: [50, 50, 900, 900], cooldowns_ready?: [false]})
    )

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())

    assert :ok = Worker.run(worker)

    # the feed must carry the lock marker, persistently on the watch line
    assert wait_for_log("🔒", System.monotonic_time(:millisecond) + 5_000)
  end

  defp wait_for_log(substr, deadline) do
    receive do
      {:fishing_log, _level, text} when is_binary(text) ->
        if String.contains?(text, substr),
          do: true,
          else: wait_for_log(substr, deadline)

      _ ->
        wait_for_log(substr, deadline)
    after
      max(0, deadline - System.monotonic_time(:millisecond)) -> false
    end
  end

  @tag :tmp_dir
  test "announces the catch so combat searches immediately", %{worker: worker} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, Pokex.Bots.Combat.Worker.catch_topic())
    assert :ok = Worker.run(worker)
    # the scripted glow spikes over threshold → a hook → the catch event fires
    assert_receive {:fish_caught}, 5_000
  end

  @tag :tmp_dir
  @tag timeout: 5_000
  test "the fishing action yields to a competing :high action on the Body", %{worker: _worker} do
    # This test guards against the worker submitting its fishing action at
    # :high (or otherwise skipping the queue): with a single competitor, a
    # single dequeue would pass regardless of priority, so we hold the Body
    # busy with a BLOCKING action, wait until BOTH a competing :high action
    # AND the fishing :normal action are genuinely queued behind it, only
    # THEN release, and assert the :high action reached the Rig before the
    # fishing click did. If the worker used :high, ordering would flip (or
    # tie/race), and this assertion would fail.
    previous_rig = Application.get_env(:pokex, :rig)
    Application.put_env(:pokex, :rig, SlowRig)
    on_exit(fn -> Application.put_env(:pokex, :rig, previous_rig) end)

    {:ok, _} = SlowRig.start_link()
    body = :fishing_worker_priority_test_body
    {:ok, _} = Pokex.Bots.Body.start_link(name: body)
    worker = start_supervised!({Worker, name: nil, body: body}, id: :priority_worker)

    test = self()

    # Occupy the Body with a click that blocks until SlowRig.release/0, so
    # everything queued below provably queues instead of racing a fast fake.
    spawn(fn ->
      send(
        test,
        {:occupy_result, Pokex.Bots.Body.perform([{:click, :left, {1, 1}}], :normal, body)}
      )
    end)

    wait_until_busy(body)

    spawn(fn ->
      send(test, {:high_result, Pokex.Bots.Body.perform([{:click, :left, {9, 9}}], :high, body)})
    end)

    wait_until_queued(body, :high, 1)

    # Worker.run/1 blocks (its handle_call submits to the busy Body and waits
    # for the reply), so it must be spawned like the occupier/high callers
    # above — otherwise this call itself would time out before the fishing
    # action ever reaches the Body's queue.
    spawn(fn -> send(test, {:run_result, Worker.run(worker)}) end)
    wait_until_queued(body, :normal, 1)

    SlowRig.release()

    assert_receive {:occupy_result, :ok}, 2_000
    assert_receive {:high_result, :ok}, 2_000
    assert_receive {:run_result, :ok}, 2_000

    # Worker.run/1's own reply only covers Logic.start/2's (empty) initial
    # submit — the real fishing click ({:click, :left, neutral_point}) is
    # fired later from the first :tick, asynchronously. Poll for it.
    fishing_click = {:click, :left, {420, 350}}
    log = wait_for_click(fishing_click)

    high_idx = Enum.find_index(log, &(&1 == {:click, :left, {9, 9}}))
    fishing_idx = Enum.find_index(log, &(&1 == fishing_click))

    assert high_idx != nil and fishing_idx != nil
    assert high_idx < fishing_idx
  end

  defp wait_for_click(click, deadline \\ System.monotonic_time(:millisecond) + 2_000) do
    log = SlowRig.log()

    cond do
      click in log ->
        log

      System.monotonic_time(:millisecond) > deadline ->
        log

      true ->
        Process.sleep(1)
        wait_for_click(click, deadline)
    end
  end

  defp wait_until_busy(body) do
    if :sys.get_state(body).busy? do
      :ok
    else
      Process.sleep(1)
      wait_until_busy(body)
    end
  end

  defp wait_until_queued(body, key, count) do
    if :queue.len(Map.fetch!(:sys.get_state(body), key)) >= count do
      :ok
    else
      Process.sleep(1)
      wait_until_queued(body, key, count)
    end
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

    assert_receive {:fishing, %{state: :casting, error: nil, counters: %{failures: failures}}},
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
  def press_many(_combos, _opts), do: :ok
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
