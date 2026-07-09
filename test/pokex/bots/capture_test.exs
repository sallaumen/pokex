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
end
