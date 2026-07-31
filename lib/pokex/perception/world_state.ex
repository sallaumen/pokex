defmodule Pokex.Perception.WorldState do
  @moduledoc """
  The shared blackboard: one named public ETS table holding the latest interpreted
  observation per perception key, with the monotonic capture timestamp. Feeds write; anyone
  reads lock-free. Consumers MUST go through `get/3` and treat `:stale`/`:missing` as
  "unknown" — the fail-safe choice (hold, don't act) is the caller's job, the staleness
  math is ours.

  The GenServer exists only to own the table (so it survives caller crashes and dies with
  the supervision tree); reads and writes never touch the process.
  """
  use GenServer

  @table :pokex_world

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  @doc "Record the latest observation for `key`, stamped with its capture time."
  def put(key, obs, at_ms) do
    :ets.insert(@table, {key, obs, at_ms})
    :ok
  end

  @doc "The freshest observation for `key`, age-checked against `max_age_ms`."
  def get(key, max_age_ms, now_ms) do
    case :ets.lookup(@table, key) do
      [{^key, obs, at}] ->
        age = now_ms - at
        if age <= max_age_ms, do: {:ok, obs}, else: {:stale, obs, age}

      [] ->
        :missing
    end
  end

  @doc """
  How old `key`'s last observation is, in ms — `nil` when nothing was ever
  published for it.

  `get/3` answers "may I act on this?" and deliberately hides the age of a
  FRESH fact. A screen asks a different question — "are reads arriving?" —
  and needs the number even when the answer is yes, so it can tell "not
  reading" apart from "reading, and this is the value".
  """
  def age(key, now_ms) do
    case :ets.lookup(@table, key) do
      [{^key, _obs, at}] -> max(now_ms - at, 0)
      [] -> nil
    end
  end

  @doc "Drop `key` entirely — reads go back to `:missing` (the fail-open unknown)."
  def forget(key) do
    :ets.delete(@table, key)
    :ok
  end

  @doc "Everything the world currently knows — the /world page's data source."
  def entries, do: :ets.tab2list(@table)
end
