defmodule Pokex.Rig.SimTest do
  use ExUnit.Case, async: false

  alias Pokex.Rig.Sim

  setup do
    Process.register(self(), Pokex.Sim.Runner)
    :ok
  end

  test "reports a press to the runner and answers ok" do
    assert Sim.press("3") == :ok
    assert_receive {:sim_rig, {:press, "3"}}
  end

  test "reports press_many with its options" do
    assert Sim.press_many(["3", "4"], gap_ms: 60) == :ok
    assert_receive {:sim_rig, {:press_many, ["3", "4"], [gap_ms: 60]}}
  end

  test "reports holds and releases separately" do
    assert Sim.key_down("left") == :ok
    assert Sim.key_up("left") == :ok
    assert_receive {:sim_rig, {:key_down, "left"}}
    assert_receive {:sim_rig, {:key_up, "left"}}
  end

  test "refuses every capture instead of returning a fake frame" do
    assert Sim.capture_screen() == {:error, :simulated}
    assert Sim.capture({0, 0, 10, 10}, "x.png") == {:error, :simulated}
  end

  test "cursor_position never reports the panic corner" do
    {:ok, point} = Sim.cursor_position()
    refute Pokex.Bots.Corner.in_kill_corner?(point)
  end

  test "cursor_position never reports the command corner" do
    {:ok, {x, _y} = point} = Sim.cursor_position()
    refute Pokex.Bots.Corner.in_command_corner?(point, x + 500)
  end

  test "answers every callback when no runner is registered" do
    Process.unregister(Pokex.Sim.Runner)

    assert Sim.press("3") == :ok
    assert Sim.click(:left, {5, 5}) == :ok
    assert Sim.move({5, 5}) == :ok
    assert Sim.tap("shift+3") == :ok
    assert Sim.focus_click({5, 5}) == :ok
    assert Sim.capture_sequence({5, 5}) == :ok
    assert Sim.hold_latency_ms() == 0
    assert {:ok, %{count: 0}} = Sim.middle_watch()
    assert Sim.key_watch([1, 2]) == {:ok, []}
  end

  test "reaches nothing outside the beam" do
    imports = imports_of(Pokex.Rig.Sim)
    modules = imports |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    refute Pokex.Rig.Mac in modules
    refute System in modules
    refute :os in modules
    refute {:erlang, :open_port, 2} in imports
  end

  defp imports_of(module) do
    path = :code.which(module)
    {:ok, {^module, [imports: imports]}} = :beam_lib.chunks(path, [:imports])
    imports
  end
end
