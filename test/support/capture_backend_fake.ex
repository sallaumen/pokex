defmodule Pokex.CaptureBackendFake do
  @moduledoc "Test double for the ScreenCaptureKit backend."
  use Agent

  def start_link(script \\ %{}) do
    Agent.start_link(fn -> %{script: script, calls: []} end, name: __MODULE__)
  end

  def calls, do: __MODULE__ |> Agent.get(& &1.calls) |> Enum.reverse()

  def start(opts), do: record({:start, opts}, :start, {:ok, __MODULE__})

  def capture(backend, region, path),
    do: record({:capture, backend, region, path}, :capture, {:ok, path})

  def display_region(backend),
    do: record({:display_region, backend}, :display_region, :unknown)

  def stop(backend), do: record({:stop, backend}, :stop, :ok)

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
