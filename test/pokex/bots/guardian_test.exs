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

    # the cursor leaves the corner: the GATE reopens (live condition) but the LATCH stands
    # (human order) — auto-resume paths stay forbidden
    FakeBody.set_reply(body, {:ok, {500, 500}})
    assert eventually(fn -> InputGate.state().corner_ok == true end)
    assert InputGate.panic_latched?()
  end

  test "closes the InputGate's corner flag in the corner, reopens it outside", %{on_panic: on_panic} do
    alias Pokex.Bots.InputGate
    on_exit(fn -> InputGate.set_corner_ok(true) end)

    {:ok, body} = FakeBody.start_link({:ok, {0, 0}})

    {:ok, _guardian} =
      Guardian.start_link(name: nil, body: body, on_panic: on_panic, poll_ms: 5)

    # cursor parked in the corner → corner flag closed (this is what suppresses the always-on
    # PlayerSupport's revive/potion, not just the Start/Stop workers)
    assert eventually(fn -> InputGate.state().corner_ok == false end)

    FakeBody.set_reply(body, {:ok, {500, 500}})
    assert eventually(fn -> InputGate.state().corner_ok == true end)
  end

  test "an error reading the cursor reschedules without firing", %{on_panic: on_panic} do
    {:ok, body} = FakeBody.start_link({:error, :not_ready})

    {:ok, _guardian} =
      Guardian.start_link(name: nil, body: body, on_panic: on_panic, poll_ms: 5)

    refute_receive :panicked, 100

    # once the body starts reporting the corner, the still-running poll loop
    # catches it — proving the earlier error rescheduled instead of crashing
    # the loop or wedging it.
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

  test "defaults: registers as Pokex.Bots.Guardian, polls every 100ms against Pokex.Bots.Body" do
    # Pokex.Application permanently runs a Guardian at this same default name
    # (under BotSupervisor), so free the name for the duration of this test
    # and hand it back to the supervisor afterwards.
    :ok = Supervisor.terminate_child(Pokex.Bots.BotSupervisor, Pokex.Bots.Guardian)
    on_exit(fn -> Supervisor.restart_child(Pokex.Bots.BotSupervisor, Pokex.Bots.Guardian) end)

    on_panic = fn -> :ok end
    {:ok, guardian} = Guardian.start_link(on_panic: on_panic)

    assert Process.whereis(Pokex.Bots.Guardian) == guardian

    state = :sys.get_state(guardian)
    assert state.poll_ms == 100
    assert state.body == Pokex.Bots.Body
  end
end
