defmodule Pokex.Rig.Fake do
  @moduledoc "Test double for Pokex.Rig: records every call, plays back scripted returns."
  @behaviour Pokex.Rig

  use Agent

  def start_link(script \\ %{}) do
    Agent.start_link(fn -> %{script: script, calls: []} end, name: __MODULE__)
  end

  def calls, do: __MODULE__ |> Agent.get(& &1.calls) |> Enum.reverse()

  @impl true
  def press(combo), do: record({:press, combo}, :press, :ok)

  @impl true
  def press_many(combos, opts) do
    tap_count = opts |> Keyword.get(:tap_count, 1) |> max(1)
    calls = for combo <- combos, _tap <- 1..tap_count, do: {:press, combo}

    Agent.update(__MODULE__, fn state ->
      %{state | calls: Enum.reverse(calls) ++ state.calls}
    end)

    :ok
  end

  @impl true
  def click(button, point), do: record({:click, button, point}, :click, :ok)

  @impl true
  def move(point), do: record({:move, point}, :move, :ok)

  @impl true
  def capture_sequence(point), do: record({:capture_sequence, point}, :capture_sequence, :ok)

  @impl true
  def capture(region, filename),
    do: record({:capture, region, filename}, :capture, {:ok, "/tmp/fake/#{filename}"})

  @impl true
  def capture_screen,
    do: record({:capture_screen}, :capture_screen, {:ok, "/tmp/fake/screen.png"})

  @impl true
  def cursor_position, do: record({:cursor_position}, :cursor_position, {:ok, {500, 500}})

  defp record(call, key, default) do
    Agent.get_and_update(__MODULE__, fn state ->
      state = %{state | calls: [call | state.calls]}

      case state.script[key] do
        [only] -> {only, state}
        [head | tail] -> {head, put_in(state.script[key], tail)}
        _ -> {default, state}
      end
    end)
  end
end
