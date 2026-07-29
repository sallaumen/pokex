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

  # A caracterização da Etapa 0 cravava o comportamento antigo (fail-open) e
  # prometia: "quando a Frente 1 inverter, é ESTE teste que deve passar a
  # afirmar o contrário". Inverteu. Um restart agora BLOQUEIA input até os
  # pollers republicarem — no app real, Guardian (100ms) e Focus (~250ms);
  # aqui, as duas escritas explícitas fazem o papel deles.
  test "FRENTE 1: restart do dono da tabela FECHA o gate até os pollers republicarem" do
    InputGate.set_corner_ok(true)
    InputGate.set_focus_ok(true)
    InputGate.set_panic_latch(true)
    assert InputGate.allowed?()

    :ok = Supervisor.terminate_child(Pokex.Supervisor, Pokex.Bots.InputGate)
    {:ok, _pid} = Supervisor.restart_child(Pokex.Supervisor, Pokex.Bots.InputGate)

    # FAIL-CLOSED: "não sei se é seguro" deixou de ser a mesma resposta que
    # "é seguro". Nada atua até os donos das flags confirmarem o mundo.
    refute InputGate.allowed?()

    # Limitação DELIBERADA e documentada: o latch (ordem humana) é esquecido —
    # persisti-lo exigiria disco. A mitigação real é a geração de sessão: o
    # restart do Session também zera o contador e retomadas velhas não casam.
    refute InputGate.panic_latched?()

    # os pollers republicam → o gate reabre
    InputGate.set_corner_ok(true)
    InputGate.set_focus_ok(true)
    assert InputGate.allowed?()
  end

  test "FRENTE 1: flag que ninguém confirmou é BLOQUEADO, não liberado" do
    :ok = Supervisor.terminate_child(Pokex.Supervisor, Pokex.Bots.InputGate)
    {:ok, _pid} = Supervisor.restart_child(Pokex.Supervisor, Pokex.Bots.InputGate)

    # só UM dos donos confirmou — o AND continua fechado
    InputGate.set_corner_ok(true)
    refute InputGate.allowed?()
    assert InputGate.state() == %{corner_ok: true, focus_ok: false, panic_latch: false}
  end
end
