defmodule Pokex.Engine.Events do
  @moduledoc """
  The night as DATA, beside the night as a story.

  The journal keeps prose — `"waypoint 12/45 · 2286,30013 andar 5"` — which is
  exactly right for reading at breakfast and useless for asking *"what is the
  average pile size at corner 15 over the last seven nights?"*. Every number the
  engine will ever want to calibrate itself against is currently trapped inside
  a sentence.

  So this writes the same moments a second time, typed:

      {"at":1786941533474,"kind":"decision","phase":"sizing","band":"green",
       "enemies":2,"stable_ms":1800,"hp":90,"why":"contando quem chega: …"}

  One file per day under `~/.pokex/events/`, append-only, newline-delimited
  JSON. Same disciplines as the journal, for the same reasons: writes are
  env-gated so the suite never touches his real home, and files older than
  @keep_days go on boot.

  ## Why not a database

  There is no Ecto and no SQLite in this project, and at one player's volume —
  a few thousand lines a night, a couple of MB — rescanning seven files for an
  aggregate costs less than a blink. Adding a database would buy queries nobody
  is blocked on yet. The trigger to revisit is written down in
  `docs/refactor/desenho-engine-2026-08-17.md`: a night past ~50MB, a
  cross-night aggregate on every render, or wanting real ad-hoc exploration.
  Until one of those bites, JSONL is also the format a replay reads.

  ## Why a process

  Not for speed — for ORDER. Two writers appending to one file interleave
  half-lines, and a half-line is a corrupt record that no reader can tell from
  a truncated one. Same reasoning as `Pokex.StateFile`: a resource that cannot
  take two writers gets one owner. `record/2` is a cast, so the engine's tick
  never waits on a disk.
  """
  use GenServer

  require Logger

  @keep_days 14

  def start_link(opts \\ []) do
    state = %{
      persist?:
        Keyword.get(opts, :persist, Application.get_env(:pokex, :engine_events_persist, true))
    }

    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, state)
      name -> GenServer.start_link(__MODULE__, state, name: name)
    end
  end

  @doc """
  Files one typed record. Fire-and-forget on purpose: a disk that is slow, full
  or gone must never be able to slow down a decision.
  """
  @spec record(atom, map, GenServer.server()) :: :ok
  def record(kind, payload, server \\ __MODULE__) do
    GenServer.cast(server, {:record, kind, payload, System.system_time(:millisecond)})
  catch
    # The engine runs whether or not anybody is writing this down.
    :exit, _no_writer -> :ok
  end

  @doc "Where the files live."
  def dir, do: Path.join(Pokex.Home.dir(), "events")

  @doc """
  Every record of one day, oldest first — what a replay and any "how did last
  night actually go" question reads. A missing file is an empty day, never an
  error: nights the bot did not run are legitimately blank.
  """
  @spec read_day(Date.t()) :: [map]
  def read_day(date) do
    date
    |> day_file()
    |> File.read()
    |> case do
      {:ok, body} -> body |> String.split("\n", trim: true) |> Enum.flat_map(&decode/1)
      {:error, _no_file} -> []
    end
  end

  @impl true
  def init(state) do
    {:ok, prune_old_files(state)}
  end

  @impl true
  def handle_cast({:record, _kind, _payload, _at}, %{persist?: false} = state),
    do: {:noreply, state}

  def handle_cast({:record, kind, payload, at}, state) do
    write(kind, payload, at)
    {:noreply, state}
  end

  defp write(kind, payload, at) do
    File.mkdir_p!(dir())

    line =
      payload
      |> Map.new(fn {k, v} -> {k, encodable(v)} end)
      |> Map.merge(%{at: at, kind: kind})
      |> Jason.encode!()

    File.write!(day_file(Date.utc_today()), line <> "\n", [:append])
  catch
    kind, reason ->
      # Data is the bonus; the decision is the service. Say it once, loudly
      # enough to be found, and keep deciding.
      Logger.warning("engine events: não consegui escrever (#{inspect({kind, reason})})")
      :ok
  end

  # Atoms are how the orders name themselves (`:free`, `:hold`, `:yellow`), and
  # JSON has no atoms — they become their own text rather than crashing the
  # write or silently dropping the record.
  defp encodable(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: Atom.to_string(value)

  defp encodable(value) when is_list(value), do: Enum.map(value, &encodable/1)
  defp encodable(value), do: value

  defp decode(line) do
    case Jason.decode(line) do
      {:ok, record} -> [record]
      # A half-written last line (a kill mid-append) costs that line, never the day.
      {:error, _torn} -> []
    end
  end

  defp day_file(date), do: Path.join(dir(), Date.to_iso8601(date) <> ".jsonl")

  defp prune_old_files(%{persist?: false} = state), do: state

  defp prune_old_files(state) do
    cutoff = Date.add(Date.utc_today(), -@keep_days)

    case File.ls(dir()) do
      {:ok, files} ->
        for f <- files, Path.extname(f) == ".jsonl", do: prune_file(f, cutoff)

      _no_dir ->
        :ok
    end

    state
  end

  defp prune_file(file, cutoff) do
    case Date.from_iso8601(Path.rootname(file)) do
      {:ok, date} -> if Date.before?(date, cutoff), do: File.rm(Path.join(dir(), file))
      _not_ours -> :ok
    end
  end
end
