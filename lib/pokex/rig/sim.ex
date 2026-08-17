defmodule Pokex.Rig.Sim do
  @moduledoc """
  The hands, pointed at a world that is not the game.

  `Rig.impl/0` is the ONE place anything leaves this program for the Mac —
  `Body.execute/1` dispatches every action through it, `Combat` calls
  `press_many` directly, and `Capture` calls `capture_screen`. So swapping this
  module closes every door at once, and there is no side path to remember.

  Nothing here reaches the operating system, and that is not a promise: a test
  reads this module's import chunk and fails if `Pokex.Rig.Mac`, `System`, `:os`
  or `:erlang.open_port/2` ever appear in it.

  Actions are REPORTED, not swallowed: whatever is registered as
  `Pokex.Sim.Runner` receives `{:sim_rig, action}` and turns it into an effect in
  the simulated world. With nothing registered every callback still answers
  normally — the fleet must never notice that its hands are simulated.

  ## Why the cursor sits where it does

  `Pokex.Bots.Corner.in_kill_corner?/1` reads the top-left corner as the panic
  corner (`x <= 10 and y <= 10`), and the top-right one as the command corner. A
  cursor reported at the origin would be a permanent panic order. This one sits
  far from both on purpose.
  """
  @behaviour Pokex.Rig

  @cursor {640, 480}

  @impl true
  def press(key), do: report({:press, key})

  @impl true
  def press_many(keys, opts), do: report({:press_many, keys, opts})

  @impl true
  def key_down(key), do: report({:key_down, key})

  @impl true
  def key_up(key), do: report({:key_up, key})

  @impl true
  def hold_latency_ms, do: 0

  @impl true
  def click(button, point), do: report({:click, button, point})

  @impl true
  def move(point), do: report({:move, point})

  @impl true
  def tap(combo), do: report({:tap, combo})

  @impl true
  def focus_click(point), do: report({:focus_click, point})

  @impl true
  def capture_sequence(point), do: report({:capture_sequence, point})

  # A simulated frame would be a lie with a real shape: the interpreters would
  # read pixels that mean nothing. The simulator publishes FACTS instead, so the
  # honest answer here is a refusal.
  @impl true
  def capture(_region, _filename), do: {:error, :simulated}

  @impl true
  def capture_screen, do: {:error, :simulated}

  @impl true
  def cursor_position, do: {:ok, @cursor}

  @impl true
  def middle_watch, do: {:ok, %{count: 0, point: @cursor, at: nil}}

  @impl true
  def key_watch(_codes), do: {:ok, []}

  # Nameable like every other collaborator in this project (`BotSupervisor` takes
  # each worker's name by option): the default IS the wiring, and a test that
  # needs to stand in for the runner sets its own name rather than fighting the
  # app-global one for the registration.
  defp runner, do: Application.get_env(:pokex, :sim_runner, Pokex.Sim.Runner)

  defp report(action) do
    case Process.whereis(runner()) do
      nil -> :ok
      pid -> send(pid, {:sim_rig, action})
    end

    :ok
  end
end
