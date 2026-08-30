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
    halt? = Keyword.get(opts, :halt?)

    # The tail fence, honored key by key like the real rig: tests arm it (via
    # ReviveLedger) and assert the held keys never became calls.
    {pressed, halted?} =
      Enum.reduce(combos, {[], false}, fn
        _combo, {acc, true} ->
          {acc, true}

        combo, {acc, false} ->
          if is_function(halt?, 0) and halt?.(),
            do: {acc, true},
            else: {[combo | acc], false}
      end)

    pressed = Enum.reverse(pressed)
    calls = for combo <- pressed, _tap <- 1..tap_count, do: {:press, combo}

    Agent.update(__MODULE__, fn state ->
      %{state | calls: Enum.reverse(calls) ++ state.calls}
    end)

    if halted?, do: {:halted, pressed}, else: :ok
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
  def tap(combo), do: record({:tap, combo}, :tap, :ok)

  @impl true
  def focus_click(point), do: record({:focus_click, point}, :focus_click, :ok)

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

  @impl true
  def middle_watch,
    do: record({:middle_watch}, :middle_watch, {:ok, %{count: 0, point: {0, 0}, at: 0}})

  @impl true
  def key_watch(codes), do: record({:key_watch, codes}, :key_watch, {:ok, []})

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
