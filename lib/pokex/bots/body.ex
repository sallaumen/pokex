defmodule Pokex.Bots.Body do
  @moduledoc """
  The bot's single hands: the ONLY process that drives the Rig's mouse/keyboard.
  Workers submit action sequences; the Body runs ONE sequence at a time (atomic,
  so a click→move→read is never split), serving combat (`:high`) before fishing
  (`:normal`). Screen captures do NOT go through here — they are read-only and
  each worker senses on its own.
  """
  use GenServer
  alias Pokex.Rig

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, :ok, name: name)
  end

  @spec perform([tuple], :high | :normal, GenServer.server()) :: :ok | {:error, term}
  def perform(actions, priority \\ :normal, server \\ __MODULE__),
    do: GenServer.call(server, {:perform, actions, priority}, :infinity)

  @spec cursor(GenServer.server()) :: {:ok, {integer, integer}} | {:error, term}
  def cursor(server \\ __MODULE__), do: GenServer.call(server, :cursor)

  @impl true
  def init(:ok), do: {:ok, %{busy?: false, high: :queue.new(), normal: :queue.new()}}

  # Cursor reads bypass the input queue (read-only, needed live for the panic corner).
  # Guarded with a catch: the Guardian polls this on every tick for as long as
  # the bot exists, and its contract (see Guardian's moduledoc) is that a bad
  # read reschedules instead of crashing the poll loop — so a momentarily
  # unreachable Rig (e.g. its process restarting) must come back as
  # `{:error, _}`, not take the Body (and, transitively, the Guardian) down
  # with it.
  @impl true
  def handle_call(:cursor, _from, state) do
    {:reply, safe_cursor_position(), state}
  end

  def handle_call({:perform, actions, _priority}, from, %{busy?: false} = state) do
    run(actions, from)
    {:noreply, %{state | busy?: true}}
  end

  def handle_call({:perform, actions, priority}, from, state) do
    q = if priority == :high, do: :high, else: :normal
    {:noreply, Map.update!(state, q, &:queue.in({actions, from}, &1))}
  end

  @impl true
  def handle_info({:done, from, result}, state) do
    GenServer.reply(from, result)
    {:noreply, dequeue(state)}
  end

  # Pick the next sequence (high before normal); go idle when both are empty.
  defp dequeue(state) do
    case {:queue.out(state.high), :queue.out(state.normal)} do
      {{{:value, {actions, from}}, rest}, _} ->
        run(actions, from)
        %{state | high: rest, busy?: true}

      {_, {{:value, {actions, from}}, rest}} ->
        run(actions, from)
        %{state | normal: rest, busy?: true}

      _ ->
        %{state | busy?: false}
    end
  end

  # Execute the sequence off the GenServer loop so a slow input never blocks the
  # cursor read (the panic path). Report back via {:done, ...}.
  defp run(actions, from) do
    server = self()

    spawn(fn ->
      result =
        Enum.reduce_while(actions, :ok, fn action, :ok ->
          case execute(action) do
            :ok -> {:cont, :ok}
            {:error, r} -> {:halt, {:error, r}}
          end
        end)

      send(server, {:done, from, result})
    end)
  end

  defp safe_cursor_position do
    Rig.impl().cursor_position()
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp execute({:press, key}), do: Rig.impl().press(key)
  defp execute({:click, button, point}), do: Rig.impl().click(button, point)
  defp execute({:move, point}), do: Rig.impl().move(point)
  defp execute({:capture_sequence, point}), do: Rig.impl().capture_sequence(point)
  defp execute({:log, _}), do: :ok
end
