defmodule Pokex.Bots.Timers.WorkerTest do
  # async: false — reads the shared blackboard (:posture) and the home dir.
  use ExUnit.Case, async: false

  alias Pokex.Bots.Timers.Worker
  alias Pokex.Perception.WorldState
  alias Pokex.Pokedex.Team
  alias Pokex.Timers.{Store, Timer}

  @moduletag :tmp_dir

  @dataset %{
    "species" => [%{"name" => "Venusaur", "number" => 3, "elements" => ["Grass"]}],
    "lures" => []
  }

  setup %{tmp_dir: tmp} do
    File.write!(Path.join(tmp, "pokedex.json"), JSON.encode!(@dataset))
    Application.put_env(:pokex, :pokedex_path, Path.join(tmp, "pokedex.json"))
    Application.put_env(:pokex, :home_dir, tmp)
    WorldState.forget(:posture)

    on_exit(fn ->
      Application.delete_env(:pokex, :pokedex_path)
      Pokex.TestHome.restore()
      WorldState.forget(:posture)
    end)

    :ok
  end

  # A Body stand-in that records what it was asked to press. The real one is a
  # GenServer with an :infinity call; what matters here is WHICH keys arrived.
  defmodule FakeBody do
    @moduledoc false
    use GenServer

    def start_link(_), do: GenServer.start_link(__MODULE__, [])
    def pressed(pid), do: GenServer.call(pid, :pressed)

    @impl true
    def init(_), do: {:ok, []}

    @impl true
    def handle_call(:pressed, _from, keys), do: {:reply, Enum.reverse(keys), keys}

    def handle_call({:perform, actions, _priority, _at}, _from, keys),
      do: {:reply, :ok, Enum.reverse(for {:press, key} <- actions, do: key) ++ keys}
  end

  defp start_worker! do
    {:ok, body} = start_supervised({FakeBody, []}, id: :fake_body)
    # active: false — no self-scheduled tick; the tests drive :tick by hand so
    # the assertions never race a timer message.
    {:ok, worker} = start_supervised({Worker, name: nil, body: body, active: false})
    {worker, body}
  end

  defp mobbing! do
    WorldState.put(:posture, %{posture: :hold_fire, combo: []}, now())
  end

  defp free_fight! do
    WorldState.put(:posture, %{posture: :free_fight, combo: []}, now())
  end

  defp now, do: System.monotonic_time(:millisecond)

  # The press is dispatched OFF the tick on purpose (Body.perform is a call with
  # :infinity), so the test waits for it instead of assuming it already landed —
  # asserting straight after a tick is how this file first went green by luck.
  defp presses(body, expected, tries \\ 100) do
    keys = FakeBody.pressed(body)

    cond do
      length(keys) >= expected -> keys
      tries == 0 -> keys
      true -> Process.sleep(2) && presses(body, expected, tries - 1)
    end
  end

  # Proving a NON-press needs the same slack, or it passes before the press it
  # was meant to catch could have arrived.
  defp no_presses(body) do
    Process.sleep(20)
    FakeBody.pressed(body)
  end

  defp classify!(name, profile) do
    {:ok, _} = Team.add(name)
    Team.set_skills(name, profile)
    Team.set_active(name)
  end

  describe "the aura, eight seconds into a mob stretch" do
    test "it fires the JOB's keys, not a key written into the timer", %{} do
      classify!("Venusaur", %{"1" => :buffs, "3" => :aoe})

      Store.put([
        %Timer{id: "aura", name: "aura", trigger: :after_mob, after_ms: 0, category: :buffs}
      ])

      {worker, body} = start_worker!()
      :ok = Worker.run(worker)

      mobbing!()
      :ok = Worker.tick(worker)

      assert presses(body, 1) == ["1"]
    end

    test "outside a mob stretch it never fires" do
      classify!("Venusaur", %{"1" => :buffs})

      Store.put([
        %Timer{id: "aura", name: "aura", trigger: :after_mob, after_ms: 0, category: :buffs}
      ])

      {worker, body} = start_worker!()
      :ok = Worker.run(worker)

      free_fight!()
      :ok = Worker.tick(worker)

      assert no_presses(body) == []
    end

    # Once per stretch, not once per tick — the tick is a second and a stretch
    # is a minute.
    test "it fires ONCE per stretch, however many ticks the stretch lasts" do
      classify!("Venusaur", %{"1" => :buffs})

      Store.put([
        %Timer{id: "aura", name: "aura", trigger: :after_mob, after_ms: 0, category: :buffs}
      ])

      {worker, body} = start_worker!()
      :ok = Worker.run(worker)

      mobbing!()
      :ok = Worker.tick(worker)
      :ok = Worker.tick(worker)
      :ok = Worker.tick(worker)

      assert presses(body, 1) == ["1"]

      # a new stretch is a new firing. The sleep is the point, not noise: the
      # stamps are monotonic MILLISECONDS, and two stretches inside one of them
      # are the same stretch by any honest reading.
      free_fight!()
      :ok = Worker.tick(worker)
      Process.sleep(2)
      mobbing!()
      :ok = Worker.tick(worker)

      assert presses(body, 2) == ["1", "1"]
    end

    # The clock is the posture FACT, which ages: a hunt that dies stops
    # refreshing it and the stretch ends on its own.
    test "a stale posture ends the stretch instead of leaving the aura armed" do
      classify!("Venusaur", %{"1" => :buffs})

      Store.put([
        %Timer{id: "aura", name: "aura", trigger: :after_mob, after_ms: 0, category: :buffs}
      ])

      {worker, body} = start_worker!()
      :ok = Worker.run(worker)

      mobbing!()
      :ok = Worker.tick(worker)
      assert presses(body, 1) == ["1"]

      WorldState.forget(:posture)
      :ok = Worker.tick(worker)

      Process.sleep(2)
      mobbing!()
      :ok = Worker.tick(worker)
      assert presses(body, 2) == ["1", "1"]
    end
  end

  describe "a timer with nothing to press" do
    # Not a failure and not a fired timer: classifying the aura later has to
    # make it start working, which it cannot do if the clock was consumed.
    test "no pokémon on the field: nothing is pressed and the clock is kept" do
      Store.put([
        %Timer{id: "aura", name: "aura", trigger: :after_mob, after_ms: 0, category: :buffs}
      ])

      {worker, body} = start_worker!()
      :ok = Worker.run(worker)

      mobbing!()
      :ok = Worker.tick(worker)

      assert no_presses(body) == []
      assert [%{remaining: remaining}] = Worker.status(worker).timers
      assert remaining <= 0
    end
  end

  describe "the berry, every so often" do
    test "a literal key fires without any pokémon classified" do
      Store.put([%Timer{id: "berry", name: "berry", trigger: :every, after_ms: 1, keys: ["8"]}])

      {worker, body} = start_worker!()
      :ok = Worker.run(worker)
      # one millisecond IS the interval here; the clock has to actually move
      Process.sleep(2)
      :ok = Worker.tick(worker)

      assert presses(body, 1) == ["8"]
    end

    test "a long interval does not fire on the first tick" do
      Store.put([
        %Timer{id: "berry", name: "berry", trigger: :every, after_ms: 3_300_000, keys: ["8"]}
      ])

      {worker, body} = start_worker!()
      :ok = Worker.run(worker)
      :ok = Worker.tick(worker)

      assert no_presses(body) == []
    end
  end

  describe "stopped means stopped" do
    test "a worker that was never run presses nothing, however due the timer is" do
      Store.put([%Timer{id: "berry", name: "berry", trigger: :every, after_ms: 1, keys: ["8"]}])

      {worker, body} = start_worker!()
      :ok = Worker.tick(worker)

      assert no_presses(body) == []
      refute Worker.status(worker).running?
    end

    test "halting stops the firing and forgets the stretch" do
      Store.put([%Timer{id: "berry", name: "berry", trigger: :every, after_ms: 1, keys: ["8"]}])

      {worker, body} = start_worker!()
      :ok = Worker.run(worker)
      :ok = Worker.halt(worker)
      :ok = Worker.tick(worker)

      assert no_presses(body) == []
    end

    # Yesterday's stamps would make a 55-minute berry go off on the first tick
    # of today's session.
    test "a fresh run starts every clock over" do
      Store.put([
        %Timer{id: "berry", name: "berry", trigger: :every, after_ms: 3_300_000, keys: ["8"]}
      ])

      {worker, _body} = start_worker!()
      :ok = Worker.run(worker)

      assert [%{remaining: remaining}] = Worker.status(worker).timers
      assert remaining > 3_290_000
    end
  end

  describe "what the page reads" do
    test "every timer comes back with its countdown and the keys it would press" do
      classify!("Venusaur", %{"1" => :buffs})

      Store.put([
        %Timer{id: "aura", name: "aura", trigger: :after_mob, after_ms: 8_000, category: :buffs},
        %Timer{id: "berry", name: "berry", trigger: :every, after_ms: 60_000, keys: ["8"]}
      ])

      {worker, _body} = start_worker!()
      :ok = Worker.run(worker)

      assert %{running?: true, timers: [aura, berry]} = Worker.status(worker)

      # not in a stretch: not counting, which is not the same as "due in 8s"
      assert aura.remaining == nil
      assert aura.keys == ["1"]
      assert berry.remaining > 0
      assert berry.keys == ["8"]
    end
  end
end
