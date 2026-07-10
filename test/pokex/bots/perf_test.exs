defmodule Pokex.Bots.PerfTest do
  use ExUnit.Case, async: true

  alias Pokex.Bots.Perf

  test "snapshot exposes the current window and the last flushed window" do
    {:ok, perf} = Perf.start_link(name: nil, interval_ms: 60_000)

    Perf.record("capture.backend.sck:battle.png", 42, perf)
    Perf.record("capture.backend.sck:battle.png", 58, perf)
    Perf.count("capture.backend.sck_retry:battle.png", perf)

    snap = Perf.snapshot(perf)
    assert snap.window_ms == 60_000
    assert snap.last_window == %{}
    assert %{count: 2, total: 100, max: 58} = snap.current["capture.backend.sck:battle.png"]
    assert %{count: 1} = snap.current["capture.backend.sck_retry:battle.png"]

    # a flush moves current -> last_window and clears current
    send(perf, :flush)
    snap = Perf.snapshot(perf)
    assert %{count: 2, max: 58} = snap.last_window["capture.backend.sck:battle.png"]
    assert snap.current == %{}
  end
end
