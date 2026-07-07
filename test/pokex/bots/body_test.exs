defmodule Pokex.Bots.BodyTest.RaisingRig do
  # Test-local Rig double whose press/1 raises for a specific combo, simulating
  # Pokex.Rig.Mac.Commands.press/1's Map.fetch!/2 blowing up on a mis-keyed
  # modifier (e.g. "super+1"). Everything else behaves like Pokex.Rig.Fake so
  # the Body can still run a normal follow-up sequence through it.
  @behaviour Pokex.Rig

  def start_link, do: Agent.start_link(fn -> [] end, name: __MODULE__)

  def log, do: __MODULE__ |> Agent.get(& &1) |> Enum.reverse()

  @impl true
  def press("boom"), do: raise(ArgumentError, "unknown modifier")

  def press(combo) do
    Agent.update(__MODULE__, &[combo | &1])
    :ok
  end

  @impl true
  def click(_button, _point), do: :ok
  @impl true
  def move(_point), do: :ok
  @impl true
  def capture_sequence(_point), do: :ok
  @impl true
  def capture(_region, filename), do: {:ok, filename}
  @impl true
  def capture_screen, do: {:ok, "screen.png"}
  @impl true
  def cursor_position, do: {:ok, {500, 500}}
end

defmodule Pokex.Bots.BodyTest.SlowRig do
  # Test-local Rig double: like Pokex.Rig.Fake, but press/1 blocks until
  # released (so a test can deterministically hold the Body busy instead of
  # racing a sleep against near-instant fake calls) and every call is logged
  # in arrival order. Execution order into the Rig is what actually proves
  # priority was honored — racing which caller's post-reply code runs first
  # is not reliable, since GenServer.reply/2 order doesn't guarantee which
  # process the scheduler resumes first. Scoped to this test file only; does
  # not touch the shared Pokex.Rig.Fake used elsewhere.
  @behaviour Pokex.Rig

  def start_link, do: Agent.start_link(fn -> %{held?: true, log: []} end, name: __MODULE__)

  def release, do: Agent.update(__MODULE__, &%{&1 | held?: false})

  def log, do: __MODULE__ |> Agent.get(& &1.log) |> Enum.reverse()

  @impl true
  def press(combo) do
    wait_release()
    Agent.update(__MODULE__, &%{&1 | log: [combo | &1.log]})
    :ok
  end

  defp wait_release do
    if Agent.get(__MODULE__, & &1.held?) do
      Process.sleep(1)
      wait_release()
    else
      :ok
    end
  end

  @impl true
  def click(_button, _point), do: :ok
  @impl true
  def move(_point), do: :ok
  @impl true
  def capture_sequence(_point), do: :ok
  @impl true
  def capture(_region, filename), do: {:ok, filename}
  @impl true
  def capture_screen, do: {:ok, "screen.png"}
  @impl true
  def cursor_position, do: {:ok, {500, 500}}
end

defmodule Pokex.Bots.BodyTest do
  use ExUnit.Case, async: false
  alias Pokex.Bots.Body
  alias Pokex.Bots.BodyTest.SlowRig

  setup do
    {:ok, _} = Pokex.Rig.Fake.start_link()
    {:ok, pid} = Body.start_link(name: :body_test)
    %{body: pid}
  end

  test "executes an action sequence atomically through the Rig", %{body: body} do
    assert :ok = Body.perform([{:press, "1"}, {:move, {5, 5}}], :normal, body)

    # Filter out {:cursor_position} — the app-wide Guardian polls the panic
    # corner on its own timer against this same shared Rig.Fake, and its
    # reads may land in this window. What this test actually asserts is that
    # OUR sequence ran, in order, atomically.
    calls = Enum.reject(Pokex.Rig.Fake.calls(), &match?({:cursor_position}, &1))
    assert calls == [{:press, "1"}, {:move, {5, 5}}]
  end

  @tag timeout: 2_000
  test "a :high request runs before a queued :normal one" do
    previous_rig = Application.get_env(:pokex, :rig)
    Application.put_env(:pokex, :rig, SlowRig)
    on_exit(fn -> Application.put_env(:pokex, :rig, previous_rig) end)

    {:ok, _} = SlowRig.start_link()
    {:ok, body} = Body.start_link(name: :body_prio)
    test = self()

    # Occupy the body with a press/1 call that genuinely blocks (via SlowRig)
    # until released below, so the low/high requests below provably arrive
    # and queue while the body is busy — not just win a timing race.
    spawn(fn -> Body.perform([{:press, "occupy"}], :normal, body) end)
    wait_until_busy(body)

    # low priority queued first, high second; high must execute first even
    # though both are now waiting behind the occupier. Assert on the order
    # actions actually reached the Rig (SlowRig.log/0), not on which test
    # process's post-reply `send` the scheduler happens to run first.
    spawn(fn ->
      Body.perform([{:press, "low"}], :normal, body)
      send(test, :low_done)
    end)

    wait_until_queued(body, :normal, 1)

    spawn(fn ->
      Body.perform([{:press, "high"}], :high, body)
      send(test, :high_done)
    end)

    wait_until_queued(body, :high, 1)

    SlowRig.release()

    assert_receive :low_done, 500
    assert_receive :high_done, 500
    assert SlowRig.log() == ["occupy", "high", "low"]
  end

  defp wait_until_busy(body) do
    if :sys.get_state(body).busy? do
      :ok
    else
      Process.sleep(1)
      wait_until_busy(body)
    end
  end

  defp wait_until_queued(body, key, count) do
    if :queue.len(Map.fetch!(:sys.get_state(body), key)) >= count do
      :ok
    else
      Process.sleep(1)
      wait_until_queued(body, key, count)
    end
  end

  test "cursor reads without queueing behind input", %{body: body} do
    assert {:ok, {500, 500}} = Body.cursor(body)
  end

  @tag timeout: 2_000
  test "a raising action reports {:error, :crashed, ...} instead of wedging the Body" do
    previous_rig = Application.get_env(:pokex, :rig)
    Application.put_env(:pokex, :rig, Pokex.Bots.BodyTest.RaisingRig)
    on_exit(fn -> Application.put_env(:pokex, :rig, previous_rig) end)

    {:ok, _} = Pokex.Bots.BodyTest.RaisingRig.start_link()
    {:ok, body} = Body.start_link(name: :body_crash)

    assert {:error, {:crashed, :error, %ArgumentError{}}} =
             Body.perform([{:press, "boom"}], :normal, body)

    # Prove the Body dequeued and stayed usable: a subsequent normal sequence
    # still executes through the Rig.
    assert :ok = Body.perform([{:press, "1"}], :normal, body)
    assert Pokex.Bots.BodyTest.RaisingRig.log() == ["1"]
  end
end
