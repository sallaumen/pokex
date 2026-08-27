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
  # `{:mute, test}` takes the call, tells the test it was asked, and NEVER
  # answers — a Body parked inline in `apply_hold/2` (four serialized Rig calls
  # on a diagonal change) looks exactly like this from here.
  def handle_call(:cursor, _from, {:mute, test} = state) do
    send(test, :asked)
    {:noreply, state}
  end

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
  alias Pokex.Bots.InputGate
  alias Pokex.Perception.WorldState
  alias Pokex.Rig.Fake

  setup do
    # one shared blackboard: start from an empty world, never from the last test's
    WorldState.clear()

    test = self()
    on_panic = fn -> send(test, :panicked) end

    # These tests drive a Guardian whose cursor sits in the KILL CORNER, and that
    # Guardian closes the GLOBAL corner flag. Stopped while still "in the corner"
    # it left the gate shut for everything after it: every click answered
    # {:error, :input_gate_closed} — a whole file down, on some seeds only
    # (2026-08-04). The latch leaks the same way (the Focus resume tests read it).
    # Same restore contract input_gate_test and focus_test already keep.
    on_exit(fn ->
      InputGate.set_panic_latch(false)
      InputGate.set_corner_ok(true)
      InputGate.set_focus_ok(true)
    end)

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

  # The app-global Guardian kept its 100ms corner poll running for the WHOLE suite, and
  # every poll read the cursor through the SHARED Pokex.Rig.Fake. Any test asserting
  # "nothing reached the Rig" then failed whenever a poll landed inside its window — the
  # fishing gate test's ~1-in-3 ghost (measured 2026-08-11, seed 3). Same contract the
  # other app-global loops already keep (:focus_auto_monitor, :sweep_auto_tick,
  # :stock_alerts_active): the poller is OFF in the suite and test instances opt in.
  test "the app-global Guardian never polls during the suite — the shared Rig stays quiet" do
    {:ok, _fake} = Fake.start_link()

    # three default poll windows: a live poller would have logged three cursor reads
    Process.sleep(3 * 100)

    assert Fake.calls() == []
  end

  # O VIGIA DO CANTO NÃO PODE MORRER PORQUE O CORPO DEMOROU. `Body.cursor/1`
  # era um `GenServer.call` no timeout padrão de 5s, e timeout é EXIT, não
  # `{:error, _}` — o `_error -> state` deste laço não pega. O Body atende
  # `:cursor` na hora, MAS `apply_hold/2` roda INLINE no loop dele (de
  # propósito: o conjunto de teclas presas é estado, e um executor spawnado não
  # pode ser dono dele), e uma troca de diagonal são quatro chamadas seriadas
  # ao Rig com 1500ms de teto cada. Passa dos 5s sem nem tocar no osascript — e
  # aí o canto de matar deixa de ser vigiado exatamente durante o
  # congestionamento para o qual ele existe.
  test "um corpo que não responde não mata o vigia: ele segue perguntando", %{
    on_panic: on_panic
  } do
    {:ok, body} = FakeBody.start_link({:mute, self()})

    {:ok, guardian} =
      Guardian.start_link(
        name: nil,
        body: body,
        on_panic: on_panic,
        poll_ms: 5,
        auto_poll: true,
        cursor_timeout_ms: 50
      )

    ref = Process.monitor(guardian)

    assert_receive :asked, 500
    assert_receive :asked, 500
    refute_receive {:DOWN, ^ref, :process, _pid, _reason}, 100
  end

  test "a cursor in the kill corner triggers on_panic", %{on_panic: on_panic} do
    {:ok, body} = FakeBody.start_link({:ok, {0, 0}})

    {:ok, _guardian} =
      Guardian.start_link(name: nil, body: body, on_panic: on_panic, poll_ms: 5, auto_poll: true)

    assert_receive :panicked, 500
  end

  # The corner is the LAST thing standing, so stopping the fleet must never be
  # able to take it down. On 2026-08-11 a worker parked on a capture did not
  # answer its :halt inside the default 5s, the call exited, and the Guardian
  # died mid-panic — the rest of the fleet stayed running with nobody watching
  # the corner. BotSupervisor bounds that wait now; this is the belt under it,
  # so anything new in the stop path can never cost the corner again.
  @tag :capture_log
  test "a stop that blows up neither kills the Guardian nor swallows the panic" do
    Process.flag(:trap_exit, true)
    Phoenix.PubSub.subscribe(Pokex.PubSub, "combat")

    {:ok, body} = FakeBody.start_link({:ok, {0, 0}})
    wedged = fn -> exit({:timeout, {GenServer, :call, [Pokex.Bots.Catcher.Worker, :halt]}}) end

    {:ok, guardian} =
      Guardian.start_link(name: nil, body: body, on_panic: wedged, poll_ms: 5, auto_poll: true)

    assert_receive {:panic, "kill corner"}, 500
    refute_receive {:EXIT, ^guardian, _reason}, 100
    assert Process.alive?(guardian)
  end

  test "a safe cursor position never triggers on_panic", %{on_panic: on_panic} do
    {:ok, body} = FakeBody.start_link({:ok, {500, 500}})

    {:ok, _guardian} =
      Guardian.start_link(name: nil, body: body, on_panic: on_panic, poll_ms: 5, auto_poll: true)

    refute_receive :panicked, 100
  end

  test "panic SETS the latch, and leaving the corner does NOT clear it (only Iniciar bot does)",
       %{on_panic: on_panic} do
    alias Pokex.Bots.InputGate
    on_exit(fn -> InputGate.set_panic_latch(false) end)
    InputGate.set_panic_latch(false)

    {:ok, body} = FakeBody.start_link({:ok, {0, 0}})

    {:ok, _guardian} =
      Guardian.start_link(name: nil, body: body, on_panic: on_panic, poll_ms: 5, auto_poll: true)

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
      Guardian.start_link(name: nil, body: body, on_panic: on_panic, poll_ms: 5, auto_poll: true)

    assert eventually(fn -> InputGate.state().corner_ok == false end)

    FakeBody.set_reply(body, {:ok, {500, 500}})
    assert eventually(fn -> InputGate.state().corner_ok == true end)
  end

  test "an error reading the cursor reschedules without firing", %{on_panic: on_panic} do
    {:ok, body} = FakeBody.start_link({:error, :not_ready})

    {:ok, _guardian} =
      Guardian.start_link(name: nil, body: body, on_panic: on_panic, poll_ms: 5, auto_poll: true)

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
      Guardian.start_link(name: nil, body: body, on_panic: on_panic, poll_ms: 5, auto_poll: true)

    assert_receive {:panic, "kill corner"}, 500
    assert_receive {:panic, "kill corner"}, 500
  end

  # Pokex.Application permanently runs a Guardian at this same default name (under
  # BotSupervisor), so free the name for this test and hand it back afterwards.
  test "defaults: registers as Pokex.Bots.Guardian, 100ms cadence against Pokex.Bots.Body" do
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
        WorldState.forget(:session)
        Pokex.Settings.put(:stop_after_minutes, 0)
        Pokex.Settings.put(:stop_after_kills, 0)
      end)

      :ok
    end

    defp active_session!(age_ms) do
      at = System.monotonic_time(:millisecond)
      WorldState.put(:session, %{started_at: at - age_ms}, at)
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
          session_rules: true,
          auto_poll: true
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
          session_rules: true,
          auto_poll: true
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
          session_rules: true,
          auto_poll: true
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
          session_rules: true,
          auto_poll: true
        )

      send(guardian, {:combat, %{state: :hunting, counters: %{fights: 99}, error: nil}})

      refute_receive :panicked, 150
    end
  end

  describe "anti-stagnation (Actions & Rules)" do
    setup do
      on_exit(fn ->
        WorldState.forget(:session)
        Pokex.Settings.put(:stagnation_minutes, 0)
        Pokex.Settings.put(:stagnation_action, "alarm")
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
          session_rules: true,
          auto_poll: true
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

      assert_receive {:rule_alarm, :session, reason}, 1_000
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
      Pokex.Settings.put(:stagnation_action, "stop")
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
        WorldState.forget(:session)
        Pokex.Settings.put(:stagnation_minutes, 0)
        Pokex.Settings.put(:stagnation_action, "alarm")
        Pokex.Settings.put(:stop_after_action, "stop")
        Pokex.Settings.put(:stop_after_minutes, 0)
        Pokex.Settings.put(:stop_after_kills, 0)
        InputGate.set_panic_latch(false)
      end)

      :ok
    end

    defp start_guardian_with_logout!(on_panic, logout_fun) do
      {:ok, body} = FakeBody.start_link({:ok, {500, 500}})

      {:ok, guardian} =
        Guardian.start_link(
          name: nil,
          body: body,
          on_panic: on_panic,
          poll_ms: 5,
          session_rules: true,
          auto_poll: true,
          logout_fun: logout_fun
        )

      guardian
    end

    # Logout latches and stops the fleet on its own — the Guardian must not duplicate it.
    test "stagnation with action deslogar calls logout with the reason", %{on_panic: on_panic} do
      owner = self()
      active_session!(61_000)
      Pokex.Settings.put(:stagnation_minutes, 1)
      Pokex.Settings.put(:stagnation_action, "logout")

      start_guardian_with_logout!(on_panic, fn reason -> send(owner, {:logged_out, reason}) end)

      assert_receive {:logged_out, reason}, 1_000
      assert reason =~ "estagnação"
      refute_receive :panicked, 100
    end

    test "the kills goal with action deslogar calls logout", %{on_panic: on_panic} do
      owner = self()
      active_session!(0)
      Pokex.Settings.put(:stop_after_kills, 2)
      Pokex.Settings.put(:stop_after_action, "logout")

      guardian =
        start_guardian_with_logout!(on_panic, fn reason -> send(owner, {:logged_out, reason}) end)

      send(guardian, {:combat, %{state: :hunting, counters: %{fights: 2}, error: nil}})

      assert_receive {:logged_out, reason}, 1_000
      assert reason =~ "meta de kills atingida"
    end

    test "the kills goal with action parar still stops as always", %{on_panic: on_panic} do
      active_session!(0)
      Pokex.Settings.put(:stop_after_kills, 2)
      Pokex.Settings.put(:stop_after_action, "stop")

      guardian =
        start_guardian_with_logout!(on_panic, fn _reason -> flunk("must not log out") end)

      send(guardian, {:combat, %{state: :hunting, counters: %{fights: 2}, error: nil}})

      assert_receive :panicked, 1_000
    end

    test "a cleared minigame resets the stagnation clock", %{on_panic: on_panic} do
      active_session!(61_000)
      Pokex.Settings.put(:stagnation_minutes, 1)
      Pokex.Settings.put(:stagnation_action, "stop")

      guardian = start_guardian_with_logout!(on_panic, fn _reason -> :ok end)
      send(guardian, {:mini_game, %{state: :watching, counters: %{clears: 1}}})

      refute_receive :panicked, 400
    end

    test "with the minigame watcher stopped, a hook resets the clock", %{on_panic: on_panic} do
      active_session!(61_000)
      Pokex.Settings.put(:stagnation_minutes, 1)
      Pokex.Settings.put(:stagnation_action, "stop")

      guardian = start_guardian_with_logout!(on_panic, fn _reason -> :ok end)
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
      Pokex.Settings.put(:stagnation_action, "stop")

      guardian = start_guardian_with_logout!(on_panic, fn _reason -> :ok end)
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
            [name: nil, body: body, on_panic: on_panic, poll_ms: 5, auto_poll: true],
            opts
          )
        )

      guardian
    end

    test "holding the mouse in the corner fires once; leaving and returning re-arms", %{
      on_panic: on_panic
    } do
      owner = self()
      Pokex.Settings.put(:command_corner, true)
      Pokex.Settings.put(:command_corner_dwell_ms, 30)
      {:ok, body} = FakeBody.start_link({:ok, {3435, 5}})

      guardian_no_canto!(on_panic, body,
        screen_w_fun: fn -> 3440 end,
        command_toggle: fn -> send(owner, :toggled) end
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
      owner = self()
      Pokex.Settings.put(:command_corner, true)
      Pokex.Settings.put(:command_corner_dwell_ms, 5_000)
      {:ok, body} = FakeBody.start_link({:ok, {3435, 5}})

      guardian_no_canto!(on_panic, body,
        screen_w_fun: fn -> 3440 end,
        command_toggle: fn -> send(owner, :toggled) end
      )

      refute_receive :toggled, 300
    end

    test "without calibration (unknown screen width) the corner does not exist", %{
      on_panic: on_panic
    } do
      owner = self()
      Pokex.Settings.put(:command_corner, true)
      Pokex.Settings.put(:command_corner_dwell_ms, 10)
      {:ok, body} = FakeBody.start_link({:ok, {3435, 5}})

      guardian_no_canto!(on_panic, body,
        screen_w_fun: fn -> nil end,
        command_toggle: fn -> send(owner, :toggled) end
      )

      refute_receive :toggled, 300
    end
  end
end
