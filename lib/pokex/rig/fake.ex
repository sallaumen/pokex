defmodule Pokex.Rig.Fake do
  @moduledoc "Test double for Pokex.Rig: records every call, plays back scripted returns."
  @behaviour Pokex.Rig

  use Agent

  def start_link(script \\ %{}) do
    case Agent.start_link(fn -> %{script: script, calls: []} end, name: __MODULE__) do
      {:error, {:already_started, old}} ->
        # The previous test's Fake is still UNWINDING: it is linked to a test
        # process that already exited, but the exit signal is asynchronous, so
        # the next test's setup can land in this gap. That race was the suite's
        # "1 run in 5 fails one random test" ghost (measured 2026-07-20). Wait
        # out the death instead of racing it; test files touching this global
        # name are all async: false, so the holder is never a live test.
        ref = Process.monitor(old)

        receive do
          {:DOWN, ^ref, :process, ^old, _reason} -> :ok
        after
          1_000 ->
            Process.exit(old, :kill)

            receive do
              {:DOWN, ^ref, :process, ^old, _reason} -> :ok
            end
        end

        start_link(script)

      ok ->
        ok
    end
  end

  def calls, do: __MODULE__ |> Agent.get(& &1.calls) |> Enum.reverse()

  @impl true
  def press(combo), do: record({:press, combo}, :press, :ok)

  @impl true
  def press_many(combos, opts) do
    # optional scripted latency, so tests can model a slow (osascript) burst still in flight
    case Agent.get(__MODULE__, & &1.script[:press_many_sleep_ms]) do
      ms when is_integer(ms) and ms > 0 -> Process.sleep(ms)
      _ -> :ok
    end

    tap_count = opts |> Keyword.get(:tap_count, 1) |> max(1)
    calls = for combo <- combos, _tap <- 1..tap_count, do: {:press, combo}

    Agent.update(__MODULE__, fn state ->
      %{state | calls: Enum.reverse(calls) ++ state.calls}
    end)

    :ok
  end

  @impl true
  def key_down(key), do: record({:key_down, key}, :key_down, :ok)

  @impl true
  def key_up(key), do: record({:key_up, key}, :key_up, :ok)

  @impl true
  # Fake actuation is instantaneous — tests must not inherit real-backend lag.
  def hold_latency_ms, do: 0

  @impl true
  def click(button, point), do: record({:click, button, point}, :click, :ok)

  @impl true
  def move(point), do: record({:move, point}, :move, :ok)

  @impl true
  def hover(point), do: record({:hover, point}, :hover, :ok)

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
