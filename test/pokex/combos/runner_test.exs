defmodule Pokex.Combos.RunnerTest do
  @moduledoc """
  The half that touches the game: what gets pressed, and — more importantly —
  when nothing does.

  The runner is a peer of the combat worker rather than a change to it, so
  these tests drive it exactly the way the game does: a combat broadcast, then
  whatever the blackboard says the panel looks like at that instant.
  """
  # async: false — stashes global Settings and writes the blackboard
  use ExUnit.Case, async: false

  alias Pokex.Combos.{Combo, Runner, Store}
  alias Pokex.Perception.WorldState
  alias Pokex.{Settings, SettingsStash}

  defmodule FakeBody do
    @moduledoc "Records presses instead of making them; can be told to refuse."
    use Agent

    def start_link(answer), do: Agent.start_link(fn -> {answer, []} end, name: __MODULE__)

    def perform(actions, _priority) do
      Agent.get_and_update(__MODULE__, fn {answer, pressed} ->
        {answer, {answer, pressed ++ actions}}
      end)
    end

    def pressed, do: Agent.get(__MODULE__, fn {_answer, pressed} -> pressed end)
  end

  setup do
    # one shared blackboard: start from an empty world, never from the last test's
    WorldState.clear()

    tmp = Path.join(System.tmp_dir!(), "pokex-runner-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:pokex, :home_dir, tmp)

    SettingsStash.stash!(
      combos_enabled: true,
      combo_swap_wait_ms: 5,
      combo_sing_wait_ms: 5,
      combo_press_gap_ms: 5
    )

    on_exit(fn ->
      Application.delete_env(:pokex, :home_dir)
      File.rm_rf!(tmp)
      Enum.each([:battle, :team, :dungeon], &WorldState.forget/1)
    end)

    :ok
  end

  defp world(enemy, rows) do
    now = System.monotonic_time(:millisecond)

    WorldState.put(:battle, %{enemies_detail: [%{row: 0, name: enemy}], locked?: true}, now)
    WorldState.put(:team, %{pokemon_hp: nil, rows: rows}, now)
  end

  defp row(slot, name), do: %{slot: slot, name: name, present?: true, hp_pct: 1.0}

  defp engage(runner), do: send(runner, {:combat, %{state: :fighting}})
  defp disengage(runner), do: send(runner, {:combat, %{state: :idle}})

  defp start_runner(body_answer \\ :ok) do
    {:ok, _} = FakeBody.start_link(body_answer)
    {:ok, runner} = Runner.start_link(name: nil, active: true, body: FakeBody)
    runner
  end

  defp settle(runner) do
    # the runner steps itself with send_after; let those land
    Process.sleep(120)
    Runner.status(runner)
  end

  test "plays the sing combo when a Water enemy engages" do
    world("Magikarp", [row(5, "Jigglypuff"), row(4, "Sceptile")])
    runner = start_runner()

    engage(runner)
    settle(runner)

    assert [{:press, "ctrl+5"}, {:press, "4"}, {:press, "ctrl+4"}] = FakeBody.pressed()
  end

  # The bug the whole design is shaped around: the swap itself reshuffles the panel, so
  # the counter step's key must come from a fresh reading, after the shuffle.
  test "the counter key comes from the panel AFTER the swap, not before" do
    world("Magikarp", [row(5, "Jigglypuff"), row(4, "Sceptile")])
    runner = start_runner()

    engage(runner)
    Process.sleep(15)

    world("Magikarp", [row(2, "Jigglypuff"), row(3, "Sceptile")])
    settle(runner)

    assert [{:press, "ctrl+5"}, {:press, "4"}, {:press, "ctrl+3"}] = FakeBody.pressed()
  end

  test "switched off, it never presses anything" do
    Settings.put(:combos_enabled, false)
    world("Magikarp", [row(5, "Jigglypuff"), row(4, "Sceptile")])
    runner = start_runner()

    engage(runner)
    settle(runner)

    assert FakeBody.pressed() == []
  end

  test "an enemy no combo describes is left alone" do
    world("Sceptile", [row(5, "Jigglypuff"), row(4, "Sceptile")])
    runner = start_runner()

    engage(runner)
    settle(runner)

    assert FakeBody.pressed() == []
  end

  test "a combo it could not finish never starts" do
    world("Magikarp", [row(5, "Jigglypuff")])
    runner = start_runner()

    engage(runner)
    settle(runner)

    assert FakeBody.pressed() == []
  end

  # "Combos on, nothing happened" has two very different causes, and
  # they used to look identical: no combo described the enemy, or one did and
  # could not run. The second is now said out loud.
  test "a combo that matched but could not run announces the reason" do
    Phoenix.PubSub.subscribe(Pokex.PubSub, Runner.topic())

    world("Tentacool", [row(2, "Xatu"), row(3, "Sceptile")])
    runner = start_runner()

    engage(runner)

    assert_receive {:combo_skipped,
                    %{combo: "sing", enemy: "Tentacool", reason: {:not_on_screen, "Jigglypuff"}}},
                   1_000

    assert FakeBody.pressed() == []
    assert %{last_skip: %{reason: {:not_on_screen, "Jigglypuff"}}} = settle(runner)
  end

  test "no combo matching stays silent — that is the normal case" do
    Phoenix.PubSub.subscribe(Pokex.PubSub, Runner.topic())

    world("Pidgey", [row(2, "Xatu")])
    runner = start_runner()

    engage(runner)
    refute_receive {:combo_skipped, _any}, 300
    assert settle(runner).last_skip == nil
  end

  test "the fight ending mid-combo stops it where it stands" do
    world("Magikarp", [row(5, "Jigglypuff"), row(4, "Sceptile")])
    runner = start_runner()

    engage(runner)
    disengage(runner)
    settle(runner)

    assert %{running: nil} = Runner.status(runner)
    refute {:press, "ctrl+4"} in FakeBody.pressed()
  end

  test "the enemy dying mid-combo stops it too" do
    world("Magikarp", [row(5, "Jigglypuff"), row(4, "Sceptile")])
    runner = start_runner()

    engage(runner)
    send(runner, {:kill})
    settle(runner)

    assert %{running: nil} = Runner.status(runner)
    refute {:press, "ctrl+4"} in FakeBody.pressed()
  end

  test "a Body that refuses a press aborts the whole combo" do
    world("Magikarp", [row(5, "Jigglypuff"), row(4, "Sceptile")])
    runner = start_runner({:error, :blocked})

    engage(runner)
    settle(runner)

    assert %{running: nil} = Runner.status(runner)
    assert length(FakeBody.pressed()) == 1
  end

  test "one combo per engagement, however long the fight runs" do
    world("Magikarp", [row(5, "Jigglypuff"), row(4, "Sceptile")])
    runner = start_runner()

    engage(runner)
    settle(runner)
    pressed = FakeBody.pressed()

    engage(runner)
    send(runner, {:combat, %{state: :fighting}})
    settle(runner)

    assert FakeBody.pressed() == pressed
  end

  # The cavebot publishes the :dungeon fact on run and forgets it on halt, so a
  # combo restricted to one dungeon only exists while the hunt is inside it.
  test "a dungeon-restricted combo fires when the :dungeon fact matches" do
    WorldState.put(:dungeon, %{id: "cavena"}, System.monotonic_time(:millisecond))

    :ok =
      Store.put([
        %Combo{
          name: "dg",
          trigger: {:enemy_species, "Tentacool"},
          steps: [{:skill, "4"}],
          dungeon: "cavena"
        }
      ])

    world("Tentacool", [row(5, "Jigglypuff")])
    runner = start_runner()

    engage(runner)
    settle(runner)

    assert [{:press, "4"}] = FakeBody.pressed()
  end

  test "a combo for ANOTHER dungeon does not fire in this one" do
    WorldState.put(:dungeon, %{id: "cavena"}, System.monotonic_time(:millisecond))

    :ok =
      Store.put([
        %Combo{
          name: "dg",
          trigger: {:enemy_species, "Tentacool"},
          steps: [{:skill, "4"}],
          dungeon: "outra"
        }
      ])

    world("Tentacool", [row(5, "Jigglypuff")])
    runner = start_runner()

    engage(runner)
    settle(runner)

    assert FakeBody.pressed() == []
  end

  test "a row whose portrait was not read is never a target" do
    world("Magikarp", [row(5, "Jigglypuff"), %{slot: 4, name: nil, present?: true, hp_pct: 1.0}])
    runner = start_runner()

    engage(runner)
    settle(runner)

    assert FakeBody.pressed() == []
  end
end
