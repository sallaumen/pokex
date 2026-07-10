defmodule Pokex.Bots.CaptureTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.Capture

  setup do
    # Rig.impl() is Rig.Fake in test env; it records every capture and returns a fake path.
    {:ok, _} = Pokex.Rig.Fake.start_link()
    :ok
  end

  test "grab falls back to a DIRECT capture when the broker isn't running" do
    # a server name with no process → straight to Rig.impl().capture (nothing to serialize on)
    assert {:ok, "/tmp/fake/z.png"} = Capture.grab({0, 0, 10, 10}, "z.png", :no_such_capture)
    assert {:capture, {0, 0, 10, 10}, "z.png"} in Pokex.Rig.Fake.calls()
  end

  test "grab serializes through the broker when it IS running" do
    {:ok, pid} = Capture.start_link(name: :cap_test)

    assert {:ok, "/tmp/fake/y.png"} = Capture.grab({1, 2, 3, 4}, "y.png", :cap_test)
    assert {:capture, {1, 2, 3, 4}, "y.png"} in Pokex.Rig.Fake.calls()

    GenServer.stop(pid)
  end

  @tag :tmp_dir
  test "frame decodes and reuses a short same-region cache", %{tmp_dir: tmp} do
    path = png!(tmp, "frame.png", {10, 20, 30})
    Agent.stop(Pokex.Rig.Fake)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, path}, {:ok, path}]})
    {:ok, pid} = Capture.start_link(name: :cap_frame_cache, cache_ttl_ms: 1_000)

    region = {1, 2, 3, 4}
    assert {:ok, %{width: 3, height: 2}} = Capture.frame(region, "frame.png", :cap_frame_cache)
    assert {:ok, %{width: 3, height: 2}} = Capture.frame(region, "frame.png", :cap_frame_cache)

    assert Pokex.Rig.Fake.calls() == [{:capture, region, "frame.png"}]

    GenServer.stop(pid)
  end

  @tag :tmp_dir
  test "frame_uncached bypasses the short same-region frame cache", %{tmp_dir: tmp} do
    first = png!(tmp, "first.png", {10, 20, 30})
    second = png!(tmp, "second.png", {90, 80, 70})
    Agent.stop(Pokex.Rig.Fake)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, first}, {:ok, second}]})
    {:ok, pid} = Capture.start_link(name: :cap_frame_uncached, cache_ttl_ms: 1_000)

    region = {1, 2, 3, 4}

    assert {:ok, %{rgba: <<10, 20, 30, 255, _rest::binary>>}} =
             Capture.frame(region, "frame.png", :cap_frame_uncached)

    assert {:ok, %{rgba: <<90, 80, 70, 255, _rest::binary>>}} =
             Capture.frame_uncached(region, "frame.png", :cap_frame_uncached)

    assert Pokex.Rig.Fake.calls() == [
             {:capture, region, "frame.png"},
             {:capture, region, "frame.png"}
           ]

    GenServer.stop(pid)
  end

  test "concurrent grabs are serialized — the broker never runs two captures at once" do
    {:ok, pid} = Capture.start_link(name: :cap_serial)

    # fire many grabs concurrently; every one must complete (the broker queues them one at a time)
    results =
      1..20
      |> Task.async_stream(fn i -> Capture.grab({i, 0, 1, 1}, "s#{i}.png", :cap_serial) end,
        max_concurrency: 20
      )
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert length(Pokex.Rig.Fake.calls()) == 20

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

    refute Enum.any?(Pokex.Rig.Fake.calls(), &match?({:capture, _, _}, &1))

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

    assert {:capture, region, "start-fallback.png"} in Pokex.Rig.Fake.calls()

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

    # initial start failed -> :rig fallback serves the capture
    assert {:ok, "/tmp/fake/first.png"} =
             Capture.grab({1, 1, 1, 1}, "first.png", :cap_sck_recover_after_start)

    assert {:capture, {1, 1, 1, 1}, "first.png"} in Pokex.Rig.Fake.calls()

    # make recovery due
    :sys.replace_state(pid, fn state ->
      %{state | sck_recover_at: System.monotonic_time(:millisecond) - 1}
    end)

    # the next capture KICKS OFF recovery in the background but still serves on :rig immediately —
    # it does NOT block on the (async) SCK re-init
    assert {:ok, second} =
             Capture.grab({2, 2, 2, 2}, "second.png", :cap_sck_recover_after_start)

    assert String.ends_with?(second, "second.png")
    assert {:capture, {2, 2, 2, 2}, "second.png"} in Pokex.Rig.Fake.calls()

    # recovery completes off the capture path and the backend swaps to SCK
    wait_until(fn ->
      match?({:screen_capture_kit, :sck_recovered}, :sys.get_state(pid).backend)
    end)

    assert Pokex.CaptureBackendFake.calls()
           |> Enum.filter(&match?({:start, _}, &1))
           |> length() == 2

    # a later capture now goes through the recovered SCK backend, not the rig
    assert {:ok, _} = Capture.grab({3, 3, 3, 3}, "third.png", :cap_sck_recover_after_start)

    assert {:capture, :sck_recovered, {3, 3, 3, 3}, _path} =
             Enum.find(Pokex.CaptureBackendFake.calls(), &match?({:capture, _, _, _}, &1))

    GenServer.stop(pid)
  end

  test "the broker ignores an unexpected message instead of crashing" do
    {:ok, pid} = Capture.start_link(name: :cap_catchall)
    send(pid, :totally_unexpected_message)
    # still alive and serving captures
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
    refute Enum.any?(Pokex.Rig.Fake.calls(), &match?({:capture, _, _}, &1))

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
    assert {:capture, region, "fallback.png"} in Pokex.Rig.Fake.calls()

    GenServer.stop(pid)
  end

  defp png!(dir, name, {r, g, b}) do
    rows = for _ <- 1..2, do: for(_ <- 1..3, do: {r, g, b, 255})
    Pokex.PngFixtures.write!(Path.join(dir, name), rows)
  end
end
