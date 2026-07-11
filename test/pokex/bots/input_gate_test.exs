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

  test "state reports all flags" do
    InputGate.set_corner_ok(false)
    InputGate.set_focus_ok(true)
    assert InputGate.state() == %{corner_ok: false, focus_ok: true, panic_latch: false}
  end

  test "the panic latch defaults OFF, sets from the very first write, and never gates input" do
    on_exit(fn -> InputGate.set_panic_latch(false) end)

    refute InputGate.panic_latched?()

    InputGate.set_panic_latch(true)
    assert InputGate.panic_latched?()
    # the latch forbids AUTO-RESUME, not actuation — the human's manual play is never suppressed
    assert InputGate.allowed?()

    InputGate.set_panic_latch(false)
    refute InputGate.panic_latched?()
  end
end
