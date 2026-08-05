defmodule Pokex.Bots.CaptureTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.Capture
  alias Pokex.Rig.Fake

  setup do
    # Rig.impl() is Rig.Fake in test env; it records every capture and returns a fake path.
    {:ok, _} = Fake.start_link()
    :ok
  end

  test "grab falls back to a DIRECT capture when the broker isn't running" do
    assert {:ok, "/tmp/fake/z.png"} = Capture.grab({0, 0, 10, 10}, "z.png", :no_such_capture)
    assert {:capture, {0, 0, 10, 10}, "z.png"} in Fake.calls()
  end

  test "grab serializes through the broker when it IS running" do
    {:ok, pid} = Capture.start_link(name: :cap_test)

    assert {:ok, "/tmp/fake/y.png"} = Capture.grab({1, 2, 3, 4}, "y.png", :cap_test)
    assert {:capture, {1, 2, 3, 4}, "y.png"} in Fake.calls()

    GenServer.stop(pid)
  end

  test "screen captures the SCK backend's full display region — never the CLI's guess" do
    start_supervised!(
      {Pokex.CaptureBackendFake,
       %{
         start: [{:ok, :sck_backend}],
         display_region: [{:ok, {0, 0, 3440, 1440}}]
       }}
    )

    {:ok, pid} =
      Capture.start_link(name: :cap_screen_sck, screen_capture_kit: Pokex.CaptureBackendFake)

    assert {:ok, _path} = Capture.screen("screen.png", :cap_screen_sck)

    assert {:capture, :sck_backend, {0, 0, 3440, 1440}, _path} =
             Enum.find(Pokex.CaptureBackendFake.calls(), &match?({:capture, _, _, _}, &1))

    refute Enum.any?(Fake.calls(), &match?({:capture_screen}, &1))

    GenServer.stop(pid)
  end

  test "SCK display_region converts the helper's ready metadata to a points region" do
    alias Pokex.Bots.Capture.ScreenCaptureKit

    backend = %ScreenCaptureKit{
      metadata: %{"display_width" => 6880, "display_height" => 2880, "scale" => 2.0}
    }

    assert ScreenCaptureKit.display_region(backend) == {:ok, {0, 0, 3440, 1440}}
    assert ScreenCaptureKit.display_region(%ScreenCaptureKit{}) == :unknown
  end

  test "screen falls back to the CLI capture_screen without SCK display metadata" do
    {:ok, pid} = Capture.start_link(name: :cap_screen_cli)

    assert {:ok, "/tmp/fake/screen.png"} = Capture.screen("screen.png", :cap_screen_cli)
    assert {:capture_screen} in Fake.calls()

    GenServer.stop(pid)
  end

  # The panel print, the x-ray and the profile thumbnail throw the measurement
  # away, and the probe is a WHOLE extra capture serialized with every reader.
  @tag :tmp_dir
  test "screen never pays for the point measurement it does not use", %{tmp_dir: tmp} do
    screen = Pokex.PngFixtures.write!(Path.join(tmp, "plain.png"), rows(302, 196))
    Agent.stop(Fake)
    {:ok, _} = Fake.start_link(%{capture_screen: [{:ok, screen}]})
    {:ok, pid} = Capture.start_link(name: :cap_screen_no_probe)

    assert {:ok, ^screen} = Capture.screen("plain.png", :cap_screen_no_probe)
    refute Enum.any?(Fake.calls(), &match?({:capture, _region, _file}, &1))

    GenServer.stop(pid)
  end

  test "screen_with_points measures the FILMED display, never every monitor together" do
    start_supervised!(
      {Pokex.CaptureBackendFake,
       %{start: [{:ok, :sck_backend}], display_region: [{:ok, {0, 0, 3440, 1440}}]}}
    )

    {:ok, pid} =
      Capture.start_link(name: :cap_points_sck, screen_capture_kit: Pokex.CaptureBackendFake)

    assert {:ok, _path, {3440, 1440}} = Capture.screen_with_points("screen.png", :cap_points_sck)

    GenServer.stop(pid)
  end

  @tag :tmp_dir
  test "screen_with_points derives the CLI's points from a probe taken in the same turn", %{
    tmp_dir: tmp
  } do
    screen = Pokex.PngFixtures.write!(Path.join(tmp, "cli.png"), rows(302, 196))
    probe = Pokex.PngFixtures.write!(Path.join(tmp, "probe.png"), rows(200, 200))
    Agent.stop(Fake)
    {:ok, _} = Fake.start_link(%{capture_screen: [{:ok, screen}], capture: [{:ok, probe}]})
    {:ok, pid} = Capture.start_link(name: :cap_points_cli)

    assert {:ok, ^screen, {151, 98}} = Capture.screen_with_points("s.png", :cap_points_cli)

    GenServer.stop(pid)
  end

  test "display_points answers from the backend without taking any capture" do
    start_supervised!(
      {Pokex.CaptureBackendFake,
       %{start: [{:ok, :sck_backend}], display_region: [{:ok, {0, 0, 3440, 1440}}]}}
    )

    {:ok, pid} =
      Capture.start_link(name: :cap_display_points, screen_capture_kit: Pokex.CaptureBackendFake)

    assert {:ok, {3440, 1440}} = Capture.display_points(:cap_display_points)
    refute Enum.any?(Pokex.CaptureBackendFake.calls(), &match?({:capture, _, _, _}, &1))

    GenServer.stop(pid)
  end

  test "display_points stays unknown without a broker and without SCK metadata" do
    assert Capture.display_points(:no_such_broker) == :unknown

    {:ok, pid} = Capture.start_link(name: :cap_display_cli)
    assert Capture.display_points(:cap_display_cli) == :unknown
    GenServer.stop(pid)
  end

  @tag :tmp_dir
  test "frame decodes and reuses a short same-region cache", %{tmp_dir: tmp} do
    path = png!(tmp, "frame.png", {10, 20, 30})
    Agent.stop(Fake)
    {:ok, _} = Fake.start_link(%{capture: [{:ok, path}, {:ok, path}]})
    {:ok, pid} = Capture.start_link(name: :cap_frame_cache, cache_ttl_ms: 1_000)

    region = {1, 2, 3, 4}
    assert {:ok, %{width: 3, height: 2}} = Capture.frame(region, "frame.png", :cap_frame_cache)
    assert {:ok, %{width: 3, height: 2}} = Capture.frame(region, "frame.png", :cap_frame_cache)

    assert Fake.calls() == [{:capture, region, "frame.png"}]

    GenServer.stop(pid)
  end

  @tag :tmp_dir
  test "frame_uncached bypasses the short same-region frame cache", %{tmp_dir: tmp} do
    first = png!(tmp, "first.png", {10, 20, 30})
    second = png!(tmp, "second.png", {90, 80, 70})
    Agent.stop(Fake)
    {:ok, _} = Fake.start_link(%{capture: [{:ok, first}, {:ok, second}]})
    {:ok, pid} = Capture.start_link(name: :cap_frame_uncached, cache_ttl_ms: 1_000)

    region = {1, 2, 3, 4}

    assert {:ok, %{rgba: <<10, 20, 30, 255, _rest::binary>>}} =
             Capture.frame(region, "frame.png", :cap_frame_uncached)

    assert {:ok, %{rgba: <<90, 80, 70, 255, _rest::binary>>}} =
             Capture.frame_uncached(region, "frame.png", :cap_frame_uncached)

    # captures only: Fake's log is global and the Body polls the cursor through it
    assert Enum.filter(Fake.calls(), &match?({:capture, _region, _file}, &1)) == [
             {:capture, region, "frame.png"},
             {:capture, region, "frame.png"}
           ]

    GenServer.stop(pid)
  end

  test "concurrent grabs are serialized — the broker never runs two captures at once" do
    {:ok, pid} = Capture.start_link(name: :cap_serial)

    results =
      1..20
      |> Task.async_stream(fn i -> Capture.grab({i, 0, 1, 1}, "s#{i}.png", :cap_serial) end,
        max_concurrency: 20
      )
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert length(Fake.calls()) == 20

    GenServer.stop(pid)
  end

  test "screen capture kit retries a transient start timeout before falling back" do
    start_supervised!(
      {Pokex.CaptureBackendFake,
       %{
         start: [{:error, :timeout}, {:ok, :sck_backend}],
         capture: [{:ok, "/tmp/sck/start-retried.png"}]
       }}
    )

    {:ok, pid} =
      Capture.start_link(
        name: :cap_sck_start_retry,
        screen_capture_kit: Pokex.CaptureBackendFake,
        sck_start_retries: 1,
        sck_start_retry_sleep_ms: 0
      )

    assert {:ok, "/tmp/sck/start-retried.png"} =
             Capture.grab({1, 2, 3, 4}, "start-retried.png", :cap_sck_start_retry)

    assert Pokex.CaptureBackendFake.calls()
           |> Enum.filter(&match?({:start, _}, &1))
           |> length() == 2

    assert {:capture, :sck_backend, {1, 2, 3, 4}, _path} =
             Enum.find(Pokex.CaptureBackendFake.calls(), &match?({:capture, _, _, _}, &1))

    refute Enum.any?(Fake.calls(), &match?({:capture, _, _}, &1))

    GenServer.stop(pid)
  end

  test "screen capture kit start falls back only after retry exhaustion" do
    start_supervised!({Pokex.CaptureBackendFake, %{start: [{:error, :timeout}]}})

    region = {4, 3, 2, 1}

    {:ok, pid} =
      Capture.start_link(
        name: :cap_sck_start_fallback,
        screen_capture_kit: Pokex.CaptureBackendFake,
        sck_start_retries: 1,
        sck_start_retry_sleep_ms: 0
      )

    assert {:ok, "/tmp/fake/start-fallback.png"} =
             Capture.grab(region, "start-fallback.png", :cap_sck_start_fallback)

    assert Pokex.CaptureBackendFake.calls()
           |> Enum.filter(&match?({:start, _}, &1))
           |> length() == 2

    assert {:capture, region, "start-fallback.png"} in Fake.calls()

    GenServer.stop(pid)
  end

  test "screen capture kit permission denial does not retry until settings change" do
    start_supervised!(
      {Pokex.CaptureBackendFake,
       %{start: [{:error, {:not_ready, "The user declined TCCs for display capture"}}]}}
    )

    {:ok, pid} =
      Capture.start_link(
        name: :cap_sck_permission_denied,
        screen_capture_kit: Pokex.CaptureBackendFake,
        sck_start_retries: 3,
        sck_start_retry_sleep_ms: 0
      )

    assert {:ok, "/tmp/fake/tcc-fallback.png"} =
             Capture.grab({5, 5, 5, 5}, "tcc-fallback.png", :cap_sck_permission_denied)

    assert Pokex.CaptureBackendFake.calls()
           |> Enum.filter(&match?({:start, _}, &1))
           |> length() == 1

    state = :sys.get_state(pid)
    refute state.sck_recoverable?
    assert state.sck_recover_at == nil

    GenServer.stop(pid)
  end

  test "failed SCK recoveries back off exponentially and reset on success" do
    start_supervised!({Pokex.CaptureBackendFake, %{start: [{:error, :timeout}]}})

    {:ok, pid} =
      Capture.start_link(
        name: :cap_sck_backoff,
        screen_capture_kit: Pokex.CaptureBackendFake,
        sck_start_retries: 0,
        sck_recover_interval_ms: 5_000
      )

    send(pid, {:sck_recovery_result, {:error, :timeout}})
    state = :sys.get_state(pid)
    assert state.sck_recover_backoff_ms == 10_000
    assert_in_delta state.sck_recover_at - System.monotonic_time(:millisecond), 5_000, 200

    send(pid, {:sck_recovery_result, {:error, :timeout}})
    state = :sys.get_state(pid)
    assert state.sck_recover_backoff_ms == 20_000
    assert_in_delta state.sck_recover_at - System.monotonic_time(:millisecond), 10_000, 200

    :sys.replace_state(pid, fn s -> %{s | sck_recover_backoff_ms: 60_000} end)
    send(pid, {:sck_recovery_result, {:error, :timeout}})
    assert :sys.get_state(pid).sck_recover_backoff_ms == 60_000

    send(pid, {:sck_recovery_result, {:ok, :sck_recovered}})
    state = :sys.get_state(pid)
    assert state.sck_recover_backoff_ms == 5_000
    assert state.sck_recover_at == nil

    GenServer.stop(pid)
  end

  test "a failed SCK start recovers ASYNCHRONOUSLY — captures never block on the re-init" do
    start_supervised!(
      {Pokex.CaptureBackendFake,
       %{
         start: [{:error, :timeout}, {:ok, :sck_recovered}]
       }}
    )

    {:ok, pid} =
      Capture.start_link(
        name: :cap_sck_recover_after_start,
        screen_capture_kit: Pokex.CaptureBackendFake,
        sck_start_retries: 0,
        sck_recover_interval_ms: 60_000
      )

    assert {:ok, "/tmp/fake/first.png"} =
             Capture.grab({1, 1, 1, 1}, "first.png", :cap_sck_recover_after_start)

    assert {:capture, {1, 1, 1, 1}, "first.png"} in Fake.calls()

    :sys.replace_state(pid, fn state ->
      %{state | sck_recover_at: System.monotonic_time(:millisecond) - 1}
    end)

    assert {:ok, second} =
             Capture.grab({2, 2, 2, 2}, "second.png", :cap_sck_recover_after_start)

    assert String.ends_with?(second, "second.png")
    assert {:capture, {2, 2, 2, 2}, "second.png"} in Fake.calls()

    wait_until(fn ->
      match?({:screen_capture_kit, :sck_recovered}, :sys.get_state(pid).backend)
    end)

    assert Pokex.CaptureBackendFake.calls()
           |> Enum.filter(&match?({:start, _}, &1))
           |> length() == 2

    assert {:ok, _} = Capture.grab({3, 3, 3, 3}, "third.png", :cap_sck_recover_after_start)

    assert {:capture, :sck_recovered, {3, 3, 3, 3}, _path} =
             Enum.find(Pokex.CaptureBackendFake.calls(), &match?({:capture, _, _, _}, &1))

    GenServer.stop(pid)
  end

  test "the broker ignores an unexpected message instead of crashing" do
    {:ok, pid} = Capture.start_link(name: :cap_catchall)
    send(pid, :totally_unexpected_message)
    assert {:ok, _} = Capture.grab({0, 0, 1, 1}, "x.png", :cap_catchall)
    assert Process.alive?(pid)
    GenServer.stop(pid)
  end

  defp wait_until(fun, deadline \\ System.monotonic_time(:millisecond) + 1_000) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("condition not met before deadline")
      true -> Process.sleep(2) && wait_until(fun, deadline)
    end
  end

  test "screen capture kit retries a transient capture failure before falling back" do
    start_supervised!(
      {Pokex.CaptureBackendFake,
       %{
         capture: [
           {:error, {:screen_capture_kit, "no frame available from ScreenCaptureKit"}},
           {:ok, "/tmp/sck/retried.png"}
         ]
       }}
    )

    {:ok, pid} =
      Capture.start_link(
        name: :cap_sck_retry,
        screen_capture_kit: Pokex.CaptureBackendFake,
        sck_capture_retries: 1,
        sck_retry_sleep_ms: 0
      )

    assert {:ok, "/tmp/sck/retried.png"} =
             Capture.grab({1, 2, 3, 4}, "retried.png", :cap_sck_retry)

    assert Pokex.CaptureBackendFake.calls()
           |> Enum.filter(&match?({:capture, _, _, _}, &1))
           |> length() == 2

    refute Enum.any?(Pokex.CaptureBackendFake.calls(), &match?({:stop, _}, &1))
    refute Enum.any?(Fake.calls(), &match?({:capture, _, _}, &1))

    GenServer.stop(pid)
  end

  test "a stopped stream is never retried — straight to fallback (SCK can't resume it)" do
    start_supervised!(
      {Pokex.CaptureBackendFake,
       %{
         capture: [
           {:error,
            {:screen_capture_kit,
             "ScreenCaptureKit stream stopped: Error Domain=... Code=-3805 " <>
               "\"Failed during stream due to application connection being interrupted\""}}
         ]
       }}
    )

    {:ok, pid} =
      Capture.start_link(
        name: :cap_sck_stopped,
        screen_capture_kit: Pokex.CaptureBackendFake,
        sck_capture_retries: 3,
        sck_retry_sleep_ms: 0
      )

    assert {:ok, _path} = Capture.grab({1, 2, 3, 4}, "stopped.png", :cap_sck_stopped)

    assert Pokex.CaptureBackendFake.calls()
           |> Enum.filter(&match?({:capture, _, _, _}, &1))
           |> length() == 1

    assert Enum.any?(Pokex.CaptureBackendFake.calls(), &match?({:stop, _}, &1))
    assert Enum.any?(Fake.calls(), &match?({:capture, _, _}, &1))

    GenServer.stop(pid)
  end

  test "screen capture kit falls back to screencapture after retry exhaustion" do
    start_supervised!(
      {Pokex.CaptureBackendFake,
       %{
         capture: [
           {:error, {:screen_capture_kit, "no frame available from ScreenCaptureKit"}}
         ]
       }}
    )

    region = {9, 8, 7, 6}

    {:ok, pid} =
      Capture.start_link(
        name: :cap_sck_fallback,
        screen_capture_kit: Pokex.CaptureBackendFake,
        sck_capture_retries: 1,
        sck_retry_sleep_ms: 0
      )

    assert {:ok, "/tmp/fake/fallback.png"} =
             Capture.grab(region, "fallback.png", :cap_sck_fallback)

    assert Pokex.CaptureBackendFake.calls()
           |> Enum.filter(&match?({:capture, _, _, _}, &1))
           |> length() == 2

    assert Enum.any?(Pokex.CaptureBackendFake.calls(), &match?({:stop, _}, &1))
    assert {:capture, region, "fallback.png"} in Fake.calls()

    GenServer.stop(pid)
  end

  # config/test.exs forces capture_backend: :screencapture, which SCK's enabled?/0 rejects —
  # an isolated instance with no fake SCK module deterministically starts on :rig.
  @tag :tmp_dir
  test "frame_with_path_uncached NUNCA serve do cache — o laço do minigame depende disso",
       %{tmp_dir: tmp} do
    first = png!(tmp, "a.png", {10, 20, 30})
    second = png!(tmp, "b.png", {90, 80, 70})
    Agent.stop(Pokex.Rig.Fake)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, first}, {:ok, second}]})
    {:ok, pid} = Capture.start_link(name: :cap_path_uncached, cache_ttl_ms: 60_000)

    region = {1, 2, 3, 4}

    # o cacheado semeia a entrada; o uncached ignora ela e captura de novo
    assert {:ok, %{rgba: <<10, 20, 30, 255, _::binary>>}, _path} =
             Capture.frame_with_path(region, "x.png", :cap_path_uncached)

    assert {:ok, %{rgba: <<90, 80, 70, 255, _::binary>>}, _path} =
             Capture.frame_with_path_uncached(region, "x.png", :cap_path_uncached)

    GenServer.stop(pid)
  end

  test "backend_info reports the live backend and recovery flag" do
    {:ok, server} = Capture.start_link(name: nil)
    assert %{backend: :rig, recovering?: false} = Capture.backend_info(server)

    GenServer.stop(server)
  end

  describe "impossible region (outside the screen)" do
    # Field error 2026-07-30: minimap calibrated with y=-132 after the game window moved.
    # Deterministic — the helper answers this forever.
    @outside_frame "region 3150,-132,290,458 -> 3150,-132,290,458 outside frame 3440x1440"
    @bad_region {3150, -132, 290, 458}

    test "no retry, no CLI fallback, and the healthy SCK is not killed" do
      sck_outside_frame!()

      {:ok, pid} =
        Capture.start_link(
          name: :cap_region,
          screen_capture_kit: Pokex.CaptureBackendFake,
          sck_retry_sleep_ms: 0
        )

      assert {:error, {:screen_capture_kit, @outside_frame}} =
               Capture.grab(@bad_region, "feed_minimap.png", :cap_region)

      assert length(sck_capture_calls()) == 1
      refute Enum.any?(Fake.calls(), &match?({:capture, _, _}, &1))
      refute Enum.any?(Pokex.CaptureBackendFake.calls(), &match?({:stop, _}, &1))

      GenServer.stop(pid)
    end

    test "quarantine: the second attempt never reaches the helper; a different region still tries" do
      sck_outside_frame!([{:ok, "/tmp/fake/ok.png"}])

      {:ok, pid} =
        Capture.start_link(
          name: :cap_quarentena,
          screen_capture_kit: Pokex.CaptureBackendFake,
          sck_retry_sleep_ms: 0
        )

      assert {:error, _} = Capture.grab(@bad_region, "feed_minimap.png", :cap_quarentena)

      assert {:error, {:screen_capture_kit, @outside_frame}} =
               Capture.grab(@bad_region, "feed_minimap.png", :cap_quarentena)

      assert length(sck_capture_calls()) == 1

      assert {:ok, "/tmp/fake/ok.png"} =
               Capture.grab({100, 100, 290, 458}, "feed_minimap.png", :cap_quarentena)

      assert length(sck_capture_calls()) == 2

      GenServer.stop(pid)
    end

    # backend_info is a call, so it queues behind the recovery info message — built-in sync.
    test "SCK recovery gives quarantined regions another chance" do
      sck_outside_frame!()

      {:ok, pid} =
        Capture.start_link(
          name: :cap_rec_quarentena,
          screen_capture_kit: Pokex.CaptureBackendFake,
          sck_retry_sleep_ms: 0
        )

      assert {:error, _} = Capture.grab(@bad_region, "feed_minimap.png", :cap_rec_quarentena)
      assert length(sck_capture_calls()) == 1

      send(pid, {:sck_recovery_result, {:ok, :sck_backend_novo}})
      assert %{backend: :screen_capture_kit} = Capture.backend_info(:cap_rec_quarentena)

      assert {:error, _} = Capture.grab(@bad_region, "feed_minimap.png", :cap_rec_quarentena)
      assert length(sck_capture_calls()) == 2

      GenServer.stop(pid)
    end

    test "alarms once asking to recalibrate (panel + journal via \"game\")" do
      Phoenix.PubSub.subscribe(Pokex.PubSub, "game")
      sck_outside_frame!()

      {:ok, pid} =
        Capture.start_link(
          name: :cap_region_alarm,
          screen_capture_kit: Pokex.CaptureBackendFake,
          sck_retry_sleep_ms: 0
        )

      assert {:error, _} = Capture.grab(@bad_region, "feed_minimap.png", :cap_region_alarm)
      assert {:error, _} = Capture.grab(@bad_region, "feed_minimap.png", :cap_region_alarm)

      assert_receive {:rule_alarm, :capture, msg}
      assert msg =~ "feed_minimap.png"
      assert msg =~ "Recalibre"
      refute_receive {:rule_alarm, _, _}, 50

      GenServer.stop(pid)
    end

    # Journal 2026-07-30: recovery clears quarantine on purpose, but each re-probe of the
    # same broken region re-rang the alarm — 12 identical sirens in one afternoon.
    test "re-quarantining the same region does not re-ring the siren — it logs instead" do
      Phoenix.PubSub.subscribe(Pokex.PubSub, "game")
      sck_outside_frame!()

      {:ok, pid} =
        Capture.start_link(
          name: :cap_region_realarm,
          screen_capture_kit: Pokex.CaptureBackendFake,
          sck_retry_sleep_ms: 0
        )

      assert {:error, _} = Capture.grab(@bad_region, "feed_minimap.png", :cap_region_realarm)
      assert_receive {:rule_alarm, :capture, _}

      send(pid, {:sck_recovery_result, {:ok, :sck_novo}})
      assert %{backend: :screen_capture_kit} = Capture.backend_info(:cap_region_realarm)

      assert {:error, _} = Capture.grab(@bad_region, "feed_minimap.png", :cap_region_realarm)
      refute_receive {:rule_alarm, _, _}, 50
      assert_receive {:game_log, :macro, msg}
      assert msg =~ "feed_minimap.png"

      GenServer.stop(pid)
    end
  end

  describe "queue starvation alarm" do
    # requested_at travels in the grab message — an old timestamp simulates 10s stuck in queue.
    test "a wait above the ceiling alarms the panel — rate limited" do
      Phoenix.PubSub.subscribe(Pokex.PubSub, "game")
      {:ok, pid} = Capture.start_link(name: :cap_fome)

      late = System.monotonic_time(:millisecond) - 10_000
      GenServer.call(pid, {:grab, {0, 0, 4, 4}, "lento.png", late})

      assert_receive {:rule_alarm, :capture, msg}
      assert msg =~ "captura saturada"

      GenServer.call(pid, {:grab, {0, 0, 4, 4}, "lento2.png", late})
      refute_receive {:rule_alarm, _, _}, 50

      GenServer.stop(pid)
    end
  end

  defp sck_outside_frame!(extra_script \\ []) do
    start_supervised!(
      {Pokex.CaptureBackendFake,
       %{
         start: [{:ok, :sck_backend}],
         capture: [{:error, {:screen_capture_kit, @outside_frame}} | extra_script]
       }}
    )
  end

  defp sck_capture_calls,
    do: Enum.filter(Pokex.CaptureBackendFake.calls(), &match?({:capture, _, _, _}, &1))

  defp png!(dir, name, {r, g, b}) do
    rows = for _ <- 1..2, do: for(_ <- 1..3, do: {r, g, b, 255})
    Pokex.PngFixtures.write!(Path.join(dir, name), rows)
  end

  defp rows(w, h), do: for(_ <- 1..h, do: for(_ <- 1..w, do: {9, 9, 9, 255}))
end
