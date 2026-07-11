defmodule Pokex.Bots.FocusTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.{Focus, InputGate}

  setup do
    Pokex.Settings.put(:pause_when_unfocused, true)
    Pokex.Settings.put(:focus_poll_ms, 20)
    Pokex.Settings.put(:game_app_name, "wine")

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

  test "regaining focus reopens the gate and resumes what was running", %{agent: agent, opts: opts} do
    set(agent, %{frontmost: "Finder", running: true})
    start_focus!(opts)

    assert eventually(fn -> InputGate.state().focus_ok == false end)
    assert :stop in calls(agent)

    set(agent, %{frontmost: "wine"})
    assert eventually(fn -> InputGate.state().focus_ok == true end)
    assert :start in calls(agent)
  end

  test "a bot that was NOT running is halted but not auto-started on refocus", %{agent: agent, opts: opts} do
    set(agent, %{frontmost: "Finder", running: false})
    start_focus!(opts)

    assert eventually(fn -> InputGate.state().focus_ok == false end)

    set(agent, %{frontmost: "wine"})
    assert eventually(fn -> InputGate.state().focus_ok == true end)
    refute :start in calls(agent)
  end

  test "the master switch off leaves the gate open regardless of focus", %{agent: agent, opts: opts} do
    Pokex.Settings.put(:pause_when_unfocused, false)
    set(agent, %{frontmost: "Google Chrome", running: true})
    start_focus!(opts)

    Process.sleep(120)
    assert InputGate.state().focus_ok == true
    refute :stop in calls(agent)
  end

  test "an unreadable frontmost holds the last verdict (no gate flapping)", %{agent: agent, opts: opts} do
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
end
