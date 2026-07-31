defmodule Pokex.Rig.Mac.OsaBus do
  @moduledoc """
  Serializes every osascript KEY command through ONE process. macOS System Events is a single
  queue under the hood: N concurrent `osascript ... keystroke` processes don't run in parallel,
  they pile up — and with combat bursts (~1.2s each, spawned every ~300ms) plus fishing/loot/
  support scripts all flying at once, a key could land SECONDS after the mouse move it belonged
  with ("mouse moves, key never lands" — Lucas, 2026-07-11). One-at-a-time here keeps the latency
  of each script honest and the ordering sane.

  Mouse commands (cliclick) do NOT come through here: they talk to CGEvent directly, are fast,
  and are already serialized by the Body. Only the System Events (osascript) key path contends.

  Fail-open: if the bus is down the caller runs the command directly — a dead bus must never
  cost a rescue keystroke (input safety is the InputGate's job, upstream).
  """
  use GenServer
  require Logger

  alias Pokex.Bots.Perf

  @call_timeout_ms 30_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Run `{exe, args}` serialized behind every other key command. `{:ok, out} | {:error, _}`."
  def run(cmd, server \\ __MODULE__) do
    GenServer.call(server, {:run, cmd}, @call_timeout_ms)
  catch
    :exit, _reason -> execute(cmd)
  end

  @impl true
  def init(:ok), do: {:ok, :ok}

  @impl true
  def handle_call({:run, cmd}, _from, state), do: {:reply, execute(cmd), state}

  defp execute({exe, args}) do
    started_at = System.monotonic_time(:millisecond)

    result =
      case System.cmd(exe, args, stderr_to_stdout: true) do
        {out, 0} -> {:ok, out}
        {out, code} -> {:error, {exe, code, String.trim(out)}}
      end

    Perf.record("rig.cmd:key_bus", System.monotonic_time(:millisecond) - started_at)
    result
  rescue
    e in ErlangError -> {:error, {:executable_not_found, exe, e.original}}
  end
end
