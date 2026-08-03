defmodule Pokex.Bots.FocusTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.Focus
  alias Pokex.Bots.InputGate

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

    # The agent also plays the Session: `generation` is the order counter, and the hold
    # returns the generation it created — the same contract as BotSupervisor.hold_for_focus/0.
    {:ok, agent} =
      Agent.start_link(fn -> %{frontmost: "wine", running: false, calls: [], generation: 0} end)

    record = fn tag -> Agent.update(agent, &%{&1 | calls: [tag | &1.calls]}) end

    bump = fn ->
      Agent.get_and_update(agent, fn s ->
        {s.generation + 1, %{s | generation: s.generation + 1}}
      end)
    end

    opts = [
      name: nil,
      auto_start: true,
      poll_ms: 20,
      frontmost_fun: fn -> {:ok, Agent.get(agent, & &1.frontmost)} end,
      running_fun: fn -> Agent.get(agent, & &1.running) end,
      hold_fun: fn ->
        record.(:stop)
        bump.()
      end,
      start_all: fn -> record.(:start) end,
      generation_fun: fn -> Agent.get(agent, & &1.generation) end
    ]

    %{agent: agent, opts: opts, bump: bump}
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

  # Incident 2026-07-11: this exact sequence (panic latch set between focus loss and
  # refocus) restarted the bot mid-fight and got the active Pokémon killed.
  test "a panic between focus-lost and refocus kills the pending resume",
       %{agent: agent, opts: opts} do
    alias Pokex.Bots.InputGate
    on_exit(fn -> InputGate.set_panic_latch(false) end)

    set(agent, %{frontmost: "wine", running: true})
    start_focus!(opts)
    assert eventually(fn -> InputGate.state().focus_ok == true end)

    set(agent, %{frontmost: "Google Chrome"})
    assert eventually(fn -> InputGate.state().focus_ok == false end)
    assert :stop in calls(agent)

    InputGate.set_panic_latch(true)

    set(agent, %{frontmost: "wine"})
    assert eventually(fn -> InputGate.state().focus_ok == true end)
    refute :start in calls(agent)

    set(agent, %{frontmost: "Finder", running: false})
    assert eventually(fn -> InputGate.state().focus_ok == false end)
    set(agent, %{frontmost: "wine"})
    assert eventually(fn -> InputGate.state().focus_ok == true end)
    refute :start in calls(agent)
  end

  # The old boolean forgot a manual Stop order — only panic vetoed the resume; the
  # generation counter closes that hole.
  test "a manual Stop between focus loss and return never restarts the bots",
       %{agent: agent, opts: opts, bump: bump} do
    set(agent, %{frontmost: "wine", running: true})
    start_focus!(opts)
    assert eventually(fn -> InputGate.state().focus_ok == true end)

    set(agent, %{frontmost: "Google Chrome"})
    assert eventually(fn -> InputGate.state().focus_ok == false end)
    assert :stop in calls(agent)

    bump.()

    set(agent, %{frontmost: "wine"})
    assert eventually(fn -> InputGate.state().focus_ok == true end)
    refute :start in calls(agent)

    set(agent, %{frontmost: "Finder", running: false})
    assert eventually(fn -> InputGate.state().focus_ok == false end)
    set(agent, %{frontmost: "wine"})
    assert eventually(fn -> InputGate.state().focus_ok == true end)
    refute :start in calls(agent)
  end

  test "with no order in between, a same-generation resume still restarts",
       %{agent: agent, opts: opts} do
    set(agent, %{frontmost: "Finder", running: true})
    start_focus!(opts)

    assert eventually(fn -> InputGate.state().focus_ok == false end)
    assert :stop in calls(agent)

    set(agent, %{frontmost: "wine"})
    assert eventually(fn -> InputGate.state().focus_ok == true end)
    assert eventually(fn -> :start in calls(agent) end)
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
        InputGate.set_corner_ok(true)
        InputGate.set_focus_ok(true)
      end)

      :ok
    end

    test "refuses while the cursor is in the panic corner" do
      InputGate.set_corner_ok(false)

      assert Focus.ensure_front() == {:error, :panic_corner}
    end

    # Both branches return :ok, so asserting the return proves nothing — an implementation
    # that ALWAYS fronted would pass both tests. The fronting branch sleeps
    # calibration_front_delay_ms and opens the gate; the pass-through does neither.
    # The margin is deliberately absurd (3s wait vs a 1s ceiling) so no suite load spike
    # can make this flaky.
    test "when the game is already in front, it passes through — without paying the wait" do
      Pokex.SettingsStash.stash!(calibration_front_delay_ms: 3_000)
      InputGate.set_corner_ok(true)
      InputGate.set_focus_ok(true)

      {micros, result} = :timer.tc(&Focus.ensure_front/0)

      assert result == :ok
      assert div(micros, 1000) < 1_000, "pagou a espera do fronting sem precisar"
    end

    test "when the game is NOT in front, it fronts and opens the gate immediately" do
      Pokex.SettingsStash.stash!(calibration_front_delay_ms: 0)
      InputGate.set_corner_ok(true)
      InputGate.set_focus_ok(false)

      assert Focus.ensure_front() == :ok

      assert InputGate.state().focus_ok
    end
  end
end
