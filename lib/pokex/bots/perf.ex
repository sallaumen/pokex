defmodule Pokex.Bots.Perf do
  @moduledoc """
  Tiny runtime performance aggregator for bot hot paths.

  Workers can fire-and-forget timings here without coupling to telemetry setup.
  The process logs compact summaries every few seconds so we can diagnose real
  runtime latency without printing one line per cursor/capture/input event.
  """
  use GenServer
  require Logger

  @default_interval_ms 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def record(key, ms, server \\ __MODULE__) when is_number(ms) do
    cast(server, {:record, normalize_key(key), ms})
  end

  def count(key, server \\ __MODULE__) do
    cast(server, {:count, normalize_key(key)})
  end

  @doc "Current-window and last-flushed-window stats, for the panel's capture metrics."
  def snapshot(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil -> %{current: %{}, last_window: %{}, window_ms: 0}
      _pid -> GenServer.call(server, :snapshot)
    end
  end

  defp cast(server, message) do
    case GenServer.whereis(server) do
      nil -> :ok
      _pid -> GenServer.cast(server, message)
    end
  end

  @impl true
  def init(opts) do
    interval =
      Keyword.get(
        opts,
        :interval_ms,
        Application.get_env(:pokex, :perf_log_interval_ms, @default_interval_ms)
      )

    state = %{interval_ms: interval, stats: %{}, last_window: %{}}

    if enabled?(interval), do: Process.send_after(self(), :flush, interval)
    {:ok, state}
  end

  @impl true
  def handle_cast({:record, key, ms}, state) do
    {:noreply, update_in(state.stats, &record_stat(&1, key, ms))}
  end

  def handle_cast({:count, key}, state) do
    {:noreply, update_in(state.stats, &count_stat(&1, key))}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply,
     %{current: state.stats, last_window: state.last_window, window_ms: state.interval_ms}, state}
  end

  @impl true
  def handle_info(:flush, %{interval_ms: interval, stats: stats} = state) do
    if map_size(stats) > 0 do
      stats
      |> Enum.sort_by(fn {key, _stat} -> to_string(key) end)
      |> Enum.map(fn {key, stat} -> format_stat(key, stat) end)
      |> Enum.chunk_every(6)
      |> Enum.each(fn chunk -> Logger.info("perf " <> Enum.join(chunk, " | ")) end)
    end

    if enabled?(interval), do: Process.send_after(self(), :flush, interval)
    {:noreply, %{state | stats: %{}, last_window: stats}}
  end

  defp enabled?(interval), do: is_integer(interval) and interval > 0

  defp record_stat(stats, key, ms) do
    Map.update(stats, key, %{count: 1, total: ms, max: ms}, fn stat ->
      %{
        count: stat.count + 1,
        total: stat.total + ms,
        max: max(stat.max, ms)
      }
    end)
  end

  defp count_stat(stats, key) do
    Map.update(stats, key, %{count: 1, total: 0, max: 0}, fn stat ->
      %{stat | count: stat.count + 1}
    end)
  end

  defp format_stat(key, %{count: count, total: total, max: max}) when total > 0 do
    avg = total / count
    "#{key} n=#{count} avg=#{fmt(avg)}ms max=#{fmt(max)}ms"
  end

  defp format_stat(key, %{count: count}), do: "#{key} n=#{count}"

  defp fmt(value) when is_integer(value), do: Integer.to_string(value)
  defp fmt(value), do: :erlang.float_to_binary(value, decimals: 1)

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key), do: inspect(key)
end
