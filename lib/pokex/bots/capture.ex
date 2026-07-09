defmodule Pokex.Bots.Capture do
  @moduledoc """
  Serializes screen captures so no two run at once.

  MEASURED on Lucas's machine (2 displays): ONE `screencapture` is ~0.28s, but several running
  CONCURRENTLY balloon to 2-4s EACH — macOS `screencapture` contends badly on the display grab.
  The workers each grabbing their own region in parallel (fishing's glow + combat's battle +
  the skill bar + the panel poll) was the real cause of the jittery, slow sample rate — NOT the
  number of processes. Routing every capture through this one GenServer means only one
  screencapture is ever in flight, so each stays ~0.28s and the cadence is steady.

  Read-only, off the Body's input path (captures never touched the Body). `grab/3` falls back to
  a DIRECT capture when the broker isn't running, so unit tests need nothing extra.
  """
  use GenServer

  alias Pokex.Rig

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Serialized screen capture — `{:ok, path} | {:error, reason}`. Blocks the caller until its turn
  comes and its capture completes (each ~0.28s alone), so concurrent callers queue instead of
  fighting over the display. Direct (unserialized) when the broker isn't started.
  """
  def grab(region, filename, server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil -> Rig.impl().capture(region, filename)
      pid -> GenServer.call(pid, {:grab, region, filename}, :infinity)
    end
  end

  @impl true
  def init(:ok), do: {:ok, %{}}

  # The capture runs INSIDE handle_call, so the GenServer processes one at a time — that IS the
  # serialization. A slow capture only delays the next queued capture, never the Body/panic path.
  @impl true
  def handle_call({:grab, region, filename}, _from, state) do
    {:reply, Rig.impl().capture(region, filename), state}
  end
end
