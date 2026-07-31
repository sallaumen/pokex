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
    assert InputGate.allowed?()

    InputGate.set_panic_latch(false)
    refute InputGate.panic_latched?()
  end

  # Fail-closed: a restart BLOCKS input until the pollers republish — in the real app
  # Guardian (100ms) and Focus (~250ms); here two explicit writes play their role.
  # The latch (a human order) is deliberately forgotten on restart — persisting it would
  # need disk; the session generation is the real mitigation.
  test "a restart of the table owner closes the gate until the pollers republish" do
    InputGate.set_corner_ok(true)
    InputGate.set_focus_ok(true)
    InputGate.set_panic_latch(true)
    assert InputGate.allowed?()

    :ok = Supervisor.terminate_child(Pokex.Supervisor, Pokex.Bots.InputGate)
    {:ok, _pid} = Supervisor.restart_child(Pokex.Supervisor, Pokex.Bots.InputGate)

    refute InputGate.allowed?()

    refute InputGate.panic_latched?()

    InputGate.set_corner_ok(true)
    InputGate.set_focus_ok(true)
    assert InputGate.allowed?()
  end

  test "a flag nobody confirmed is blocked, not allowed" do
    :ok = Supervisor.terminate_child(Pokex.Supervisor, Pokex.Bots.InputGate)
    {:ok, _pid} = Supervisor.restart_child(Pokex.Supervisor, Pokex.Bots.InputGate)

    InputGate.set_corner_ok(true)
    refute InputGate.allowed?()
    assert InputGate.state() == %{corner_ok: true, focus_ok: false, panic_latch: false}
  end
end
