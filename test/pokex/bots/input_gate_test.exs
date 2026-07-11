defmodule Pokex.Bots.InputGateTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.InputGate

  setup do
    # the app-wide InputGate owns the table; reset both flags to the open default after each test
    on_exit(fn ->
      InputGate.set_corner_ok(true)
      InputGate.set_focus_ok(true)
    end)

    :ok
  end

  test "allowed? is the AND of both guards" do
    InputGate.set_corner_ok(true)
    InputGate.set_focus_ok(true)
    assert InputGate.allowed?()

    InputGate.set_corner_ok(false)
    refute InputGate.allowed?()

    InputGate.set_corner_ok(true)
    InputGate.set_focus_ok(false)
    refute InputGate.allowed?()

    InputGate.set_corner_ok(false)
    InputGate.set_focus_ok(false)
    refute InputGate.allowed?()
  end

  test "state reports both flags" do
    InputGate.set_corner_ok(false)
    InputGate.set_focus_ok(true)
    assert InputGate.state() == %{corner_ok: false, focus_ok: true}
  end
end
