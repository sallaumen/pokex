defmodule Pokex.Bots.GuardianTest.FakeBody do
  # Minimal Body double: only implements what Guardian consumes (cursor/1),
  # scripted with a fixed reply. Scoped to this test file.
  use GenServer

  def start_link(reply), do: GenServer.start_link(__MODULE__, reply)

  def set_reply(server, reply), do: GenServer.call(server, {:set_reply, reply})

  def cursor(server), do: GenServer.call(server, :cursor)

  @impl true
  def init(reply), do: {:ok, reply}

  @impl true
  def handle_call(:cursor, _from, reply), do: {:reply, reply, reply}
  def handle_call({:set_reply, reply}, _from, _state), do: {:reply, :ok, reply}
end

defmodule Pokex.Bots.GuardianTest do
  # async: false — the "defaults" test terminates/restarts the shared
  # app-wide Pokex.Bots.Guardian child, which would race any concurrent
  # async test that reaches the real Guardian/Body.
  use ExUnit.Case, async: false

  alias Pokex.Bots.Guardian
  alias Pokex.Bots.GuardianTest.FakeBody

  setup do
    test = self()
    on_panic = fn -> send(test, :panicked) end
    # every corner-triggered panic now SETS the global latch — clear it after each test so it
    # never leaks into other suites (the Focus resume tests read it)
    on_exit(fn -> Pokex.Bots.InputGate.set_panic_latch(false) end)
    %{on_panic: on_panic}
  end

  defp eventually(fun, timeout \\ 500) do
    deadline = System.monotonic_time(:millisecond) + timeout

    poll = fn poll ->
      cond do
        fun.() -> true
        System.monotonic_time(:millisecond) > deadline -> false
        true -> Process.sleep(5) && poll.(poll)
      end
    end

    poll.(poll)
  end

  test "a cursor in the kill corner triggers on_panic", %{on_panic: on_panic} do
    {:ok, body} = FakeBody.start_link({:ok, {0, 0}})

    {:ok, _guardian} =
      Guardian.start_link(name: nil, body: body, on_panic: on_panic, poll_ms: 5)

    assert_receive :panicked, 500
  end

  test "a safe cursor position never triggers on_panic", %{on_panic: on_panic} do
    {:ok, body} = FakeBody.start_link({:ok, {500, 500}})

    {:ok, _guardian} =
      Guardian.start_link(name: nil, body: body, on_panic: on_panic, poll_ms: 5)

    refute_receive :panicked, 100
  end

  test "panic SETS the latch, and leaving the corner does NOT clear it (only Iniciar bot does)",
       %{on_panic: on_panic} do
    alias Pokex.Bots.InputGate
    on_exit(fn -> InputGate.set_panic_latch(false) end)
    InputGate.set_panic_latch(false)

    {:ok, body} = FakeBody.start_link({:ok, {0, 0}})

    {:ok, _guardian} =
      Guardian.start_link(name: nil, body: body, on_panic: on_panic, poll_ms: 5)

    assert eventually(fn -> InputGate.panic_latched?() end)

    FakeBody.set_reply(body, {:ok, {500, 500}})
    assert eventually(fn -> InputGate.state().corner_ok == true end)
    assert InputGate.panic_latched?()
  end

  # The corner flag is what suppresses the always-on PlayerSupport revive/potion, not just
  # the Start/Stop workers.
  test "closes the InputGate's corner flag in the corner, reopens it outside", %{
    on_panic: on_panic
  } do
    alias Pokex.Bots.InputGate
    on_exit(fn -> InputGate.set_corner_ok(true) end)

    {:ok, body} = FakeBody.start_link({:ok, {0, 0}})

    {:ok, _guardian} =
      Guardian.start_link(name: nil, body: body, on_panic: on_panic, poll_ms: 5)

    assert eventually(fn -> InputGate.state().corner_ok == false end)

    FakeBody.set_reply(body, {:ok, {500, 500}})
    assert eventually(fn -> InputGate.state().corner_ok == true end)
  end

  test "an error reading the cursor reschedules without firing", %{on_panic: on_panic} do
    {:ok, body} = FakeBody.start_link({:error, :not_ready})

    {:ok, _guardian} =
      Guardian.start_link(name: nil, body: body, on_panic: on_panic, poll_ms: 5)

    refute_receive :panicked, 100

    FakeBody.set_reply(body, {:ok, {0, 0}})
    assert_receive :panicked, 500
  end

  test "broadcasts {:panic, \"kill corner\"} on both the fishing and combat topics" do
    Phoenix.PubSub.subscribe(Pokex.PubSub, "fishing")
    Phoenix.PubSub.subscribe(Pokex.PubSub, "combat")

    {:ok, body} = FakeBody.start_link({:ok, {0, 0}})
    on_panic = fn -> :ok end

    {:ok, _guardian} =
      Guardian.start_link(name: nil, body: body, on_panic: on_panic, poll_ms: 5)

    assert_receive {:panic, "kill corner"}, 500
    assert_receive {:panic, "kill corner"}, 500
  end

  # Pokex.Application permanently runs a Guardian at this same default name (under
  # BotSupervisor), so free the name for this test and hand it back afterwards.
  test "defaults: registers as Pokex.Bots.Guardian, polls every 100ms against Pokex.Bots.Body" do
    :ok = Supervisor.terminate_child(Pokex.Bots.BotSupervisor, Pokex.Bots.Guardian)
    on_exit(fn -> Supervisor.restart_child(Pokex.Bots.BotSupervisor, Pokex.Bots.Guardian) end)

    on_panic = fn -> :ok end
    {:ok, guardian} = Guardian.start_link(on_panic: on_panic)

    assert Process.whereis(Pokex.Bots.Guardian) == guardian

    state = :sys.get_state(guardian)
    assert state.poll_ms == 100
    assert state.body == Pokex.Bots.Body
  end

  describe "stop conditions (session goals)" do
    setup do
      on_exit(fn ->
        Pokex.Perception.WorldState.forget(:session)
        Pokex.Settings.put(:stop_after_minutes, 0)
        Pokex.Settings.put(:stop_after_kills, 0)
      end)

      :ok
    end

    defp active_session!(age_ms) do
      at = System.monotonic_time(:millisecond)
      Pokex.Perception.WorldState.put(:session, %{started_at: at - age_ms}, at)
    end

    test "the kills goal reached stops the fleet and broadcasts {:session_stop, _}", %{
      on_panic: on_panic
    } do
      active_session!(0)
      Pokex.Settings.put(:stop_after_kills, 2)
      Phoenix.PubSub.subscribe(Pokex.PubSub, "combat")

      {:ok, body} = FakeBody.start_link({:ok, {500, 500}})

      {:ok, guardian} =
        Guardian.start_link(
          name: nil,
          body: body,
          on_panic: on_panic,
          poll_ms: 5,
          session_rules: true
        )

      send(guardian, {:combat, %{state: :hunting, counters: %{fights: 2}, error: nil}})

      assert_receive :panicked, 1_000
      assert_receive {:session_stop, reason}, 1_000
      assert reason =~ "meta de kills atingida (2/2)"
    end

    test "the session time limit stops the fleet", %{on_panic: on_panic} do
      active_session!(61_000)
      Pokex.Settings.put(:stop_after_minutes, 1)
      Phoenix.PubSub.subscribe(Pokex.PubSub, "combat")

      {:ok, body} = FakeBody.start_link({:ok, {500, 500}})

      {:ok, _} =
        Guardian.start_link(
          name: nil,
          body: body,
          on_panic: on_panic,
          poll_ms: 5,
          session_rules: true
        )

      assert_receive :panicked, 1_000
      assert_receive {:session_stop, reason}, 1_000
      assert reason =~ "tempo de caçada atingido (1min)"
    end

    test "without an active session, configured limits never fire", %{on_panic: on_panic} do
      Pokex.Settings.put(:stop_after_kills, 1)
      Pokex.Settings.put(:stop_after_minutes, 1)

      {:ok, body} = FakeBody.start_link({:ok, {500, 500}})

      {:ok, guardian} =
        Guardian.start_link(
          name: nil,
          body: body,
          on_panic: on_panic,
          poll_ms: 5,
          session_rules: true
        )

      send(guardian, {:combat, %{state: :hunting, counters: %{fights: 99}, error: nil}})

      refute_receive :panicked, 150
    end

    test "an active session with limits at 0 (off) never stops", %{on_panic: on_panic} do
      active_session!(3_600_000)

      {:ok, body} = FakeBody.start_link({:ok, {500, 500}})

      {:ok, guardian} =
        Guardian.start_link(
          name: nil,
          body: body,
          on_panic: on_panic,
          poll_ms: 5,
          session_rules: true
        )

      send(guardian, {:combat, %{state: :hunting, counters: %{fights: 99}, error: nil}})

      refute_receive :panicked, 150
    end
  end

  describe "anti-stagnation (Actions & Rules)" do
    setup do
      on_exit(fn ->
        Pokex.Perception.WorldState.forget(:session)
        Pokex.Settings.put(:stagnation_minutes, 0)
        Pokex.Settings.put(:stagnation_action, "alarme")
      end)

      :ok
    end

    defp start_guardian!(on_panic) do
      {:ok, body} = FakeBody.start_link({:ok, {500, 500}})

      {:ok, guardian} =
        Guardian.start_link(
          name: nil,
          body: body,
          on_panic: on_panic,
          poll_ms: 5,
          session_rules: true
        )

      guardian
    end

    test "an expired silence window with action alarme broadcasts once and re-arms", %{
      on_panic: on_panic
    } do
      active_session!(61_000)
      Pokex.Settings.put(:stagnation_minutes, 1)
      Phoenix.PubSub.subscribe(Pokex.PubSub, "combat")

      start_guardian!(on_panic)

      assert_receive {:rule_alarm, :sessao, reason}, 1_000
      assert reason =~ "sem kills nem peixes há 1min"

      refute_receive {:rule_alarm, _, _}, 150
      refute_receive :panicked, 10
    end

    test "activity (a hook) inside the window resets the silence clock", %{on_panic: on_panic} do
      active_session!(61_000)
      Pokex.Settings.put(:stagnation_minutes, 1)
      Phoenix.PubSub.subscribe(Pokex.PubSub, "combat")

      guardian = start_guardian!(on_panic)
      send(guardian, {:fishing, %{state: :watching, counters: %{hooked: 1}, error: nil}})

      refute_receive {:rule_alarm, _, _}, 150
    end

    test "action parar: stagnation stops the fleet through the session_stop path", %{
      on_panic: on_panic
    } do
      active_session!(61_000)
      Pokex.Settings.put(:stagnation_minutes, 1)
      Pokex.Settings.put(:stagnation_action, "parar")
      Phoenix.PubSub.subscribe(Pokex.PubSub, "combat")

      start_guardian!(on_panic)

      assert_receive :panicked, 1_000
      assert_receive {:session_stop, reason}, 1_000
      assert reason =~ "estagnação"
    end
  end

  describe "life sign and the logout action" do
    setup do
      on_exit(fn ->
        Pokex.Perception.WorldState.forget(:session)
        Pokex.Settings.put(:stagnation_minutes, 0)
        Pokex.Settings.put(:stagnation_action, "alarme")
        Pokex.Settings.put(:stop_after_action, "parar")
        Pokex.Settings.put(:stop_after_minutes, 0)
        Pokex.Settings.put(:stop_after_kills, 0)
        Pokex.Bots.InputGate.set_panic_latch(false)
      end)

      :ok
    end

    defp start_guardian_com_logout!(on_panic, logout_fun) do
      {:ok, body} = FakeBody.start_link({:ok, {500, 500}})

      {:ok, guardian} =
        Guardian.start_link(
          name: nil,
          body: body,
          on_panic: on_panic,
          poll_ms: 5,
          session_rules: true,
          logout_fun: logout_fun
        )

      guardian
    end

    # Logout latches and stops the fleet on its own — the Guardian must not duplicate it.
    test "stagnation with action deslogar calls logout with the reason", %{on_panic: on_panic} do
      dono = self()
      active_session!(61_000)
      Pokex.Settings.put(:stagnation_minutes, 1)
      Pokex.Settings.put(:stagnation_action, "deslogar")

      start_guardian_com_logout!(on_panic, fn motivo -> send(dono, {:deslogou, motivo}) end)

      assert_receive {:deslogou, motivo}, 1_000
      assert motivo =~ "estagnação"
      refute_receive :panicked, 100
    end

    test "the kills goal with action deslogar calls logout", %{on_panic: on_panic} do
      dono = self()
      active_session!(0)
      Pokex.Settings.put(:stop_after_kills, 2)
      Pokex.Settings.put(:stop_after_action, "deslogar")

      guardian =
        start_guardian_com_logout!(on_panic, fn motivo -> send(dono, {:deslogou, motivo}) end)

      send(guardian, {:combat, %{state: :hunting, counters: %{fights: 2}, error: nil}})

      assert_receive {:deslogou, motivo}, 1_000
      assert motivo =~ "meta de kills atingida"
    end

    test "the kills goal with action parar still stops as always", %{on_panic: on_panic} do
      active_session!(0)
      Pokex.Settings.put(:stop_after_kills, 2)
      Pokex.Settings.put(:stop_after_action, "parar")

      guardian =
        start_guardian_com_logout!(on_panic, fn _motivo -> flunk("must not log out") end)

      send(guardian, {:combat, %{state: :hunting, counters: %{fights: 2}, error: nil}})

      assert_receive :panicked, 1_000
    end

    test "a cleared minigame resets the stagnation clock", %{on_panic: on_panic} do
      active_session!(61_000)
      Pokex.Settings.put(:stagnation_minutes, 1)
      Pokex.Settings.put(:stagnation_action, "parar")

      guardian = start_guardian_com_logout!(on_panic, fn _motivo -> :ok end)
      send(guardian, {:mini_game, %{state: :watching, counters: %{clears: 1}}})

      refute_receive :panicked, 400
    end

    test "with the minigame watcher stopped, a hook resets the clock", %{on_panic: on_panic} do
      active_session!(61_000)
      Pokex.Settings.put(:stagnation_minutes, 1)
      Pokex.Settings.put(:stagnation_action, "parar")

      guardian = start_guardian_com_logout!(on_panic, fn _motivo -> :ok end)
      send(guardian, {:mini_game, %{state: :off, counters: %{clears: 0}}})
      send(guardian, {:fishing, %{counters: %{hooked: 1}}})

      refute_receive :panicked, 400
    end

    # The lost-overnight incident: the rod hooking while the minigame never clears is NOT
    # a life sign — the rule must fire anyway.
    test "with the minigame watcher running, a hook does NOT reset the clock", %{
      on_panic: on_panic
    } do
      active_session!(61_000)
      Pokex.Settings.put(:stagnation_minutes, 1)
      Pokex.Settings.put(:stagnation_action, "parar")

      guardian = start_guardian_com_logout!(on_panic, fn _motivo -> :ok end)
      send(guardian, {:mini_game, %{state: :watching, counters: %{clears: 0}}})
      send(guardian, {:fishing, %{counters: %{hooked: 1}}})

      assert_receive :panicked, 1_000
    end
  end

  describe "command corner (toggling from inside the game)" do
    setup do
      on_exit(fn ->
        Pokex.Settings.put(:command_corner, true)
        Pokex.Settings.put(:command_corner_dwell_ms, 600)
      end)

      :ok
    end

    defp guardian_no_canto!(on_panic, body, opts) do
      {:ok, guardian} =
        Guardian.start_link(
          Keyword.merge(
            [name: nil, body: body, on_panic: on_panic, poll_ms: 5],
            opts
          )
        )

      guardian
    end

    test "holding the mouse in the corner fires once; leaving and returning re-arms", %{
      on_panic: on_panic
    } do
      dono = self()
      Pokex.Settings.put(:command_corner, true)
      Pokex.Settings.put(:command_corner_dwell_ms, 30)
      {:ok, body} = FakeBody.start_link({:ok, {3435, 5}})

      guardian_no_canto!(on_panic, body,
        screen_w_fun: fn -> 3440 end,
        command_toggle: fn -> send(dono, :toggled) end
      )

      assert_receive :toggled, 1_000
      refute_receive :toggled, 200

      FakeBody.set_reply(body, {:ok, {500, 500}})
      Process.sleep(50)
      FakeBody.set_reply(body, {:ok, {3435, 5}})
      assert_receive :toggled, 1_000
    end

    test "just passing the mouse through the corner (under the dwell) does not fire", %{
      on_panic: on_panic
    } do
      dono = self()
      Pokex.Settings.put(:command_corner, true)
      Pokex.Settings.put(:command_corner_dwell_ms, 5_000)
      {:ok, body} = FakeBody.start_link({:ok, {3435, 5}})

      guardian_no_canto!(on_panic, body,
        screen_w_fun: fn -> 3440 end,
        command_toggle: fn -> send(dono, :toggled) end
      )

      refute_receive :toggled, 300
    end

    test "without calibration (unknown screen width) the corner does not exist", %{
      on_panic: on_panic
    } do
      dono = self()
      Pokex.Settings.put(:command_corner, true)
      Pokex.Settings.put(:command_corner_dwell_ms, 10)
      {:ok, body} = FakeBody.start_link({:ok, {3435, 5}})

      guardian_no_canto!(on_panic, body,
        screen_w_fun: fn -> nil end,
        command_toggle: fn -> send(dono, :toggled) end
      )

      refute_receive :toggled, 300
    end
  end
end
