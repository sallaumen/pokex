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

  # CARACTERIZAÇÃO (Etapa 0 do plano de consolidação, alvo da Frente 1 item 7).
  # Este teste crava o comportamento ATUAL, não o desejado: a tabela ETS morre
  # com o processo, e sem tabela todo flag responde o default ABERTO — inclusive
  # o latch do pânico, que volta a "sem pânico". É uma janela fail-open real
  # entre o restart e a próxima batida dos pollers (Guardian a cada 100ms,
  # Focus no tick seguinte). A Frente 1 quer inverter isso pra fail-closed;
  # quando inverter, é ESTE teste que deve passar a afirmar o contrário.
  test "CARACTERIZAÇÃO: restart do dono da tabela reabre o gate e esquece o pânico" do
    InputGate.set_corner_ok(false)
    InputGate.set_focus_ok(false)
    InputGate.set_panic_latch(true)
    refute InputGate.allowed?()

    :ok = Supervisor.terminate_child(Pokex.Supervisor, Pokex.Bots.InputGate)
    {:ok, _pid} = Supervisor.restart_child(Pokex.Supervisor, Pokex.Bots.InputGate)

    # HOJE: tudo esquecido, input liberado — até a ordem humana de pânico.
    assert InputGate.allowed?()
    refute InputGate.panic_latched?()
  end
end
