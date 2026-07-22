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

  alias Pokex.Combos.Runner
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
      Enum.each([:battle, :team], &WorldState.forget/1)
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
    # Magikarp is Water; Jigglypuff sings, Sceptile answers
    world("Magikarp", [row(5, "Jigglypuff"), row(4, "Sceptile")])
    runner = start_runner()

    engage(runner)
    settle(runner)

    assert [{:press, "ctrl+5"}, {:press, "4"}, {:press, "ctrl+4"}] = FakeBody.pressed()
  end

  test "the counter key comes from the panel AFTER the swap, not before" do
    # This is the bug the whole design is shaped around. Jigglypuff goes out at
    # C+5; by the time the counter step runs, everyone has shuffled and
    # Sceptile answers to C+3.
    world("Magikarp", [row(5, "Jigglypuff"), row(4, "Sceptile")])
    runner = start_runner()

    engage(runner)
    Process.sleep(15)

    # the panel reorders while the sing is landing
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
    # nobody answers Magikarp, so the sing would strand Jigglypuff
    world("Magikarp", [row(5, "Jigglypuff")])
    runner = start_runner()

    engage(runner)
    settle(runner)

    assert FakeBody.pressed() == []
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
    # panic latched, or the game is not focused: no half-combos
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

    # more combat broadcasts, same fight
    engage(runner)
    send(runner, {:combat, %{state: :fighting}})
    settle(runner)

    assert FakeBody.pressed() == pressed
  end

  test "a row whose portrait was not read is never a target" do
    world("Magikarp", [row(5, "Jigglypuff"), %{slot: 4, name: nil, present?: true, hp_pct: 1.0}])
    runner = start_runner()

    engage(runner)
    settle(runner)

    assert FakeBody.pressed() == []
  end
end
