defmodule Pokex.StateFile do
  @moduledoc """
  One queue for the read-modify-write of the state files under the home.

  `Store.add/1`, `set_enabled/2`, `delete/1` and their siblings all read the
  whole file, change one entry, and write the whole file back. Two of those
  running at once lose one of the two writes entirely — not a merge conflict,
  not an error: the write simply never happened. Measured 2026-08-14, two
  processes each adding a route 60 times, the file ended with ONE route and no
  error anywhere. In the app that is Lucas arming a route in the panel while the
  cavebot page files the lesson of a fight, and one of the two silently not
  existing afterwards.

  Same shape as `Rig.Mac.OsaBus` (System Events is one queue) and `Bots.Capture`
  (the screen is one queue): a resource that cannot take two writers at once
  gets one owner.

  Atomic writes (`Pokex.Home.write!/2`) fix a different half — a READER seeing a
  half-written file. They cannot fix this one: both writers here write whole,
  valid files, one just describes a world where the other's route never existed.
  """
  use GenServer

  require Logger

  # These are tiny JSON files; a second is already absurd. It exists so a caller
  # can never be parked here forever.
  @timeout 1_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, name: opts[:name] || __MODULE__)

  @impl true
  def init(:ok), do: {:ok, :ok}

  @doc """
  Runs `fun` with no other state-file mutation in flight, and returns what it returns.

  Never takes the caller down: an exit inside a LiveView `handle_event` takes the
  whole page with it, and a lost lock is not worth a dead panel. If the queue
  does not answer, the write still happens — unserialised, and said out loud.
  """
  def update(fun) when is_function(fun, 0) do
    case GenServer.call(__MODULE__, {:update, fun}, @timeout) do
      {:ok, result} -> result
      {:raised, error, stacktrace} -> reraise(error, stacktrace)
    end
  catch
    :exit, reason ->
      Logger.warning(
        "estado: a fila de escrita não respondeu em #{@timeout}ms (#{inspect(reason)}) — " <>
          "gravando sem serialização"
      )

      fun.()
  end

  @impl true
  def handle_call({:update, fun}, _from, state) do
    {:reply, {:ok, fun.()}, state}
  rescue
    # The caller's error belongs to the caller: re-raised there, with its own
    # stacktrace, while this process stays up for everyone else in the queue.
    error -> {:reply, {:raised, error, __STACKTRACE__}, state}
  end
end
