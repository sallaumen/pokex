defmodule Pokex.Bots.FocusTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.{Focus, InputGate}

  setup do
    Pokex.Settings.put(:pause_when_unfocused, true)
    Pokex.Settings.put(:focus_poll_ms, 20)
    Pokex.Settings.put(:game_app_name, "wine")
    # a latch left over from another suite's panic would silently veto the resume paths here
    InputGate.set_panic_latch(false)

    on_exit(fn ->
      Pokex.Settings.put(:pause_when_unfocused, false)
      InputGate.set_focus_ok(true)
    end)

    {:ok, agent} = Agent.start_link(fn -> %{frontmost: "wine", running: false, calls: []} end)

    record = fn tag -> Agent.update(agent, &%{&1 | calls: [tag | &1.calls]}) end

    opts = [
      name: nil,
      auto_start: true,
      poll_ms: 20,
      frontmost_fun: fn -> {:ok, Agent.get(agent, & &1.frontmost)} end,
      running_fun: fn -> Agent.get(agent, & &1.running) end,
      stop_all: fn -> record.(:stop) end,
      start_all: fn -> record.(:start) end
    ]

    %{agent: agent, opts: opts}
  end

  defp set(agent, fields), do: Agent.update(agent, &Map.merge(&1, fields))
  defp calls(agent), do: agent |> Agent.get(& &1.calls) |> Enum.reverse()

  # start a Focus instance and stop it when the test ends (name: nil instances would otherwise
  # leak and keep polling — a stray writer fighting the next test over the shared gate).
  defp start_focus!(opts) do
    {:ok, pid} = Focus.start_link(opts)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  defp eventually(fun, timeout \\ 800) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(fun, deadline)
  end

  defp poll(fun, deadline) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) > deadline -> false
      true -> Process.sleep(10) && poll(fun, deadline)
    end
  end

  test "losing focus closes the gate and halts the running workers", %{agent: agent, opts: opts} do
    set(agent, %{frontmost: "wine", running: true})
    start_focus!(opts)

    assert eventually(fn -> InputGate.state().focus_ok == true end)

    set(agent, %{frontmost: "Google Chrome"})
    assert eventually(fn -> InputGate.state().focus_ok == false end)
    assert :stop in calls(agent)
  end

  test "regaining focus reopens the gate and resumes what was running", %{
    agent: agent,
    opts: opts
  } do
    set(agent, %{frontmost: "Finder", running: true})
    start_focus!(opts)

    assert eventually(fn -> InputGate.state().focus_ok == false end)
    assert :stop in calls(agent)

    set(agent, %{frontmost: "wine"})
    assert eventually(fn -> InputGate.state().focus_ok == true end)
    assert :start in calls(agent)
  end

  test "a bot that was NOT running is halted but not auto-started on refocus", %{
    agent: agent,
    opts: opts
  } do
    set(agent, %{frontmost: "Finder", running: false})
    start_focus!(opts)

    assert eventually(fn -> InputGate.state().focus_ok == false end)

    set(agent, %{frontmost: "wine"})
    assert eventually(fn -> InputGate.state().focus_ok == true end)
    refute :start in calls(agent)
  end

  test "the master switch off leaves the gate open regardless of focus", %{
    agent: agent,
    opts: opts
  } do
    Pokex.Settings.put(:pause_when_unfocused, false)
    set(agent, %{frontmost: "Google Chrome", running: true})
    start_focus!(opts)

    Process.sleep(120)
    assert InputGate.state().focus_ok == true
    refute :stop in calls(agent)
  end

  test "INCIDENT REGRESSION: a panic between focus-lost and refocus kills the pending resume",
       %{agent: agent, opts: opts} do
    alias Pokex.Bots.InputGate
    on_exit(fn -> InputGate.set_panic_latch(false) end)

    # bot running, game focused
    set(agent, %{frontmost: "wine", running: true})
    start_focus!(opts)
    assert eventually(fn -> InputGate.state().focus_ok == true end)

    # 1. game loses focus → Focus halts the workers and remembers "resume later"
    set(agent, %{frontmost: "Google Chrome"})
    assert eventually(fn -> InputGate.state().focus_ok == false end)
    assert :stop in calls(agent)

    # 2. the human PANICS (mouse-to-corner sets the latch — what Guardian.panic does)
    InputGate.set_panic_latch(true)

    # 3. the human refocuses the game to fight manually → the pending resume MUST be dropped,
    #    not executed over the panic (this exact sequence restarted the bot mid-fight and got
    #    Lucas's Pokémon killed, 2026-07-11)
    set(agent, %{frontmost: "wine"})
    assert eventually(fn -> InputGate.state().focus_ok == true end)
    refute :start in calls(agent)

    # 4. and the drop is permanent — another focus round-trip resumes nothing either
    set(agent, %{frontmost: "Finder", running: false})
    assert eventually(fn -> InputGate.state().focus_ok == false end)
    set(agent, %{frontmost: "wine"})
    assert eventually(fn -> InputGate.state().focus_ok == true end)
    refute :start in calls(agent)
  end

  test "an unreadable frontmost holds the last verdict (no gate flapping)", %{
    agent: agent,
    opts: opts
  } do
    set(agent, %{frontmost: "wine", running: true})

    reader = fn ->
      case Agent.get(agent, & &1.frontmost) do
        :error -> :error
        name -> {:ok, name}
      end
    end

    start_focus!(Keyword.put(opts, :frontmost_fun, reader))
    assert eventually(fn -> InputGate.state().focus_ok == true end)

    set(agent, %{frontmost: :error})
    Process.sleep(120)
    assert InputGate.state().focus_ok == true
    refute :stop in calls(agent)
  end

  describe "ensure_front/0" do
    setup do
      on_exit(fn ->
        Pokex.Bots.InputGate.set_corner_ok(true)
        Pokex.Bots.InputGate.set_focus_ok(true)
      end)

      :ok
    end

    test "recusa enquanto o cursor está no canto do pânico" do
      Pokex.Bots.InputGate.set_corner_ok(false)

      assert Pokex.Bots.Focus.ensure_front() == {:error, :panic_corner}
    end

    # Os dois ramos devolvem :ok, então asserir só o retorno não prova nada —
    # uma implementação que SEMPRE frontasse passaria nos dois testes. O que
    # distingue é o efeito: o ramo que fronta dorme calibration_front_delay_ms
    # e abre a porteira; o que passa direto não faz nem um nem outro.
    test "quando o jogo já está na frente, passa direto — sem pagar a espera" do
      # A margem é ABSURDA de propósito: 3s de espera contra um teto de 1s. Uma
      # implementação que frontasse à toa dormiria os 3s inteiros, e nenhum pico
      # de carga da suíte fecha essa distância — o teste distingue os dois ramos
      # sem virar um piscante.
      Pokex.SettingsStash.stash!(calibration_front_delay_ms: 3_000)
      Pokex.Bots.InputGate.set_corner_ok(true)
      Pokex.Bots.InputGate.set_focus_ok(true)

      {micros, resultado} = :timer.tc(&Pokex.Bots.Focus.ensure_front/0)

      assert resultado == :ok
      assert div(micros, 1000) < 1_000, "pagou a espera do fronting sem precisar"
    end

    test "quando o jogo NÃO está na frente, fronta e abre a porteira na hora" do
      Pokex.SettingsStash.stash!(calibration_front_delay_ms: 0)
      Pokex.Bots.InputGate.set_corner_ok(true)
      Pokex.Bots.InputGate.set_focus_ok(false)

      assert Pokex.Bots.Focus.ensure_front() == :ok

      # abrir a porteira AQUI, e não esperar o poller notar, é o ponto: senão o
      # Rig engoliria a tecla seguinte em silêncio
      assert Pokex.Bots.InputGate.state().focus_ok
    end
  end
end
