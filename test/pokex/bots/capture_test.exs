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

    refute Enum.any?(Pokex.Rig.Fake.calls(), &match?({:capture_screen}, &1))

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
    assert {:capture_screen} in Pokex.Rig.Fake.calls()

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

  test "failed SCK recoveries back off exponentially and reset on success" do
    start_supervised!({Pokex.CaptureBackendFake, %{start: [{:error, :timeout}]}})

    {:ok, pid} =
      Capture.start_link(
        name: :cap_sck_backoff,
        screen_capture_kit: Pokex.CaptureBackendFake,
        sck_start_retries: 0,
        sck_recover_interval_ms: 5_000
      )

    # each failed recovery result doubles the next delay (5s → 10s → 20s), capped at 60s
    send(pid, {:sck_recovery_result, {:error, :timeout}})
    state = :sys.get_state(pid)
    assert state.sck_recover_backoff_ms == 10_000
    assert_in_delta state.sck_recover_at - System.monotonic_time(:millisecond), 5_000, 200

    send(pid, {:sck_recovery_result, {:error, :timeout}})
    state = :sys.get_state(pid)
    assert state.sck_recover_backoff_ms == 20_000
    assert_in_delta state.sck_recover_at - System.monotonic_time(:millisecond), 10_000, 200

    # the cap holds
    :sys.replace_state(pid, fn s -> %{s | sck_recover_backoff_ms: 60_000} end)
    send(pid, {:sck_recovery_result, {:error, :timeout}})
    assert :sys.get_state(pid).sck_recover_backoff_ms == 60_000

    # a successful recovery resets the backoff to the base interval
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

    # exactly ONE SCK attempt (no retries on the dead stream), the zombie helper is stopped,
    # and the capture was served by the screencapture fallback
    assert Pokex.CaptureBackendFake.calls()
           |> Enum.filter(&match?({:capture, _, _, _}, &1))
           |> length() == 1

    assert Enum.any?(Pokex.CaptureBackendFake.calls(), &match?({:stop, _}, &1))
    assert Enum.any?(Pokex.Rig.Fake.calls(), &match?({:capture, _, _}, &1))

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

  test "backend_info reports the live backend and recovery flag" do
    # config/test.exs forces `capture_backend: :screencapture`, which the SCK backend's
    # enabled?/0 check rejects — so an isolated instance with no fake SCK module deterministically
    # starts on :rig, no macOS-specific behavior involved.
    {:ok, server} = Capture.start_link(name: nil)
    assert %{backend: :rig, recovering?: false} = Capture.backend_info(server)

    GenServer.stop(server)
  end

  describe "região impossível (fora da tela)" do
    # O erro real de 2026-07-30: minimapa calibrado com y=-132 depois da janela
    # do jogo mudar de lugar. Determinístico — o helper responde isso pra sempre.
    @outside_frame "region 3150,-132,290,458 -> 3150,-132,290,458 outside frame 3440x1440"
    @bad_region {3150, -132, 290, 458}

    test "sem retry, sem fallback CLI e sem matar o SCK saudável" do
      sck_outside_frame!()

      {:ok, pid} =
        Capture.start_link(
          name: :cap_regiao,
          screen_capture_kit: Pokex.CaptureBackendFake,
          sck_retry_sleep_ms: 0
        )

      assert {:error, {:screen_capture_kit, @outside_frame}} =
               Capture.grab(@bad_region, "feed_minimap.png", :cap_regiao)

      # UMA ida ao helper (os retries default não aconteceram)...
      assert length(sck_capture_calls()) == 1
      # ...nenhum fallback pro CLI (seria lixo, mais devagar)...
      refute Enum.any?(Pokex.Rig.Fake.calls(), &match?({:capture, _, _}, &1))
      # ...e o backend SCK segue VIVO (antes, fallback_backend o matava).
      refute Enum.any?(Pokex.CaptureBackendFake.calls(), &match?({:stop, _}, &1))

      GenServer.stop(pid)
    end

    test "quarentena: a segunda tentativa nem chega no helper; outra região ainda tenta" do
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

      # uma região DIFERENTE (recalibrada) não herda a quarentena da errada
      assert {:ok, "/tmp/fake/ok.png"} =
               Capture.grab({100, 100, 290, 458}, "feed_minimap.png", :cap_quarentena)

      assert length(sck_capture_calls()) == 2

      GenServer.stop(pid)
    end

    test "a recuperação do SCK dá nova chance às regiões em quarentena" do
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
      # o call abaixo entra na fila DEPOIS do info acima — sincroniza sozinho
      assert %{backend: :screen_capture_kit} = Capture.backend_info(:cap_rec_quarentena)

      assert {:error, _} = Capture.grab(@bad_region, "feed_minimap.png", :cap_rec_quarentena)
      assert length(sck_capture_calls()) == 2

      GenServer.stop(pid)
    end

    test "alarma UMA vez mandando recalibrar (painel + journal via \"game\")" do
      Phoenix.PubSub.subscribe(Pokex.PubSub, "game")
      sck_outside_frame!()

      {:ok, pid} =
        Capture.start_link(
          name: :cap_alarme_regiao,
          screen_capture_kit: Pokex.CaptureBackendFake,
          sck_retry_sleep_ms: 0
        )

      assert {:error, _} = Capture.grab(@bad_region, "feed_minimap.png", :cap_alarme_regiao)
      assert {:error, _} = Capture.grab(@bad_region, "feed_minimap.png", :cap_alarme_regiao)

      assert_receive {:rule_alarm, :captura, msg}
      assert msg =~ "feed_minimap.png"
      assert msg =~ "Recalibre"
      refute_receive {:rule_alarm, _, _}, 50

      GenServer.stop(pid)
    end

    test "a re-quarentena da MESMA região não re-toca a sirene — vira log" do
      # A recuperação do SCK limpa a quarentena de propósito (re-sondar é
      # certo), mas cada re-sonda da mesma região quebrada re-tocava o alarme —
      # 12 sirenes idênticas numa tarde (journal 2026-07-30).
      Phoenix.PubSub.subscribe(Pokex.PubSub, "game")
      sck_outside_frame!()

      {:ok, pid} =
        Capture.start_link(
          name: :cap_realarme_regiao,
          screen_capture_kit: Pokex.CaptureBackendFake,
          sck_retry_sleep_ms: 0
        )

      assert {:error, _} = Capture.grab(@bad_region, "feed_minimap.png", :cap_realarme_regiao)
      assert_receive {:rule_alarm, :captura, _}

      # o SCK renasce (limpa a quarentena e dá nova chance à região)...
      send(pid, {:sck_recovery_result, {:ok, :sck_novo}})
      assert %{backend: :screen_capture_kit} = Capture.backend_info(:cap_realarme_regiao)

      # ...a região segue quebrada: re-quarentena SEM sirene, com log
      assert {:error, _} = Capture.grab(@bad_region, "feed_minimap.png", :cap_realarme_regiao)
      refute_receive {:rule_alarm, _, _}, 50
      assert_receive {:game_log, :macro, msg}
      assert msg =~ "feed_minimap.png"

      GenServer.stop(pid)
    end
  end

  describe "alarme de fome na fila" do
    test "espera acima do teto alarma no painel — com rate limit" do
      Phoenix.PubSub.subscribe(Pokex.PubSub, "game")
      {:ok, pid} = Capture.start_link(name: :cap_fome)

      # simula um pedido que ficou 10s na fila (requested_at viaja na mensagem)
      atrasado = System.monotonic_time(:millisecond) - 10_000
      GenServer.call(pid, {:grab, {0, 0, 4, 4}, "lento.png", atrasado})

      assert_receive {:rule_alarm, :captura, msg}
      assert msg =~ "captura saturada"

      # a fila afogada estoura o teto em TODO pedido — sem rate limit seria sirene
      GenServer.call(pid, {:grab, {0, 0, 4, 4}, "lento2.png", atrasado})
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
end
