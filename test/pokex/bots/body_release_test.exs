defmodule Pokex.Bots.BodyReleaseTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.{Body, InputGate}
  alias Pokex.Rig.Fake

  setup context do
    InputGate.set_corner_ok(true)
    InputGate.set_focus_ok(true)
    InputGate.set_panic_latch(false)
    Pokex.SettingsStash.stash!(hold_max_ms: 200)
    script = Map.get(context, :script, %{key_up: [{:error, :unavailable}, :ok]})
    start_supervised!({Fake, script})
    body = start_supervised!({Body, name: :release_test_body})
    %{body: body}
  end

  test "retains and retries a key when its release fails", %{body: body} do
    assert :ok = Body.hold(["up"], body)
    assert {:error, _reason} = Body.release(body)
    assert Body.held(body) == ["up"]

    assert Pokex.TestWait.eventually(fn -> Body.held(body) == [] end)
    assert Enum.count(Fake.calls(), &(&1 == {:key_up, "up"})) == 2
  end

  test "refuses a new direction while the previous release is uncertain", %{body: body} do
    assert :ok = Body.hold(["up"], body)
    assert {:error, _reason} = Body.hold(["right"], body)
    refute {:key_down, "right"} in Fake.calls()
    assert Body.held(body) == ["up"]
    assert Pokex.TestWait.eventually(fn -> Body.held(body) == [] end)
  end

  test "refuses a still sequence when the arrow cannot be released", %{body: body} do
    assert :ok = Body.hold(["up"], body)
    assert {:error, _reason} = Body.perform([:still, {:press, "f4"}], :critical, body)
    refute {:press, "f4"} in Fake.calls()
    assert Pokex.TestWait.eventually(fn -> Body.held(body) == [] end)
    assert :ok = Body.perform([:still, {:press, "f4"}], :critical, body)
  end

  test "retries a failed release after the input gate closes", %{body: body} do
    assert :ok = Body.hold(["up"], body)
    InputGate.set_corner_ok(false)
    on_exit(fn -> InputGate.set_corner_ok(true) end)

    assert {:error, :input_gate_closed} = Body.hold(["right"], body)
    assert Pokex.TestWait.eventually(fn -> Body.held(body) == [] end)
    refute {:key_down, "right"} in Fake.calls()
  end

  @tag script: %{key_down: [{:error, :unavailable}, :ok]}
  test "releases an uncertain key before accepting the same direction again", %{body: body} do
    assert {:error, _reason} = Body.hold(["up"], body)
    assert :ok = Body.hold(["up"], body)
    assert Enum.take(Fake.calls(), 3) == [{:key_down, "up"}, {:key_up, "up"}, {:key_down, "up"}]
    assert :ok = Body.release(body)
  end
end
