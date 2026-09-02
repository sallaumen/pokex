defmodule Pokex.Bots.Tables do
  @moduledoc """
  Owns the ETS tables that have to outlive whoever writes them.

  `SkillClock`, `SkillTruth` and `ReviveLedger` each keep a public named table
  and create it lazily through `ensure_table/0` — from whichever process calls
  first. An ETS table dies with its owner, so the bot's memory of what it spent
  belonged to an accident: the first press of the night, if it happened inside
  a spawned burst, would have taken the whole clock down a second later. In the
  test suite the first caller is a test process, and CI showed the consequence
  on 2026-09-02 — a `reset/0` finding the table gone between `ensure_table` and
  `delete_all_objects`, because the test that owned it had just exited.

  `WorldState` and `InputGate` never had the problem: their tables are created
  inside a GenServer in the application tree. This is that GenServer for the
  three that were missing one. The lazy `ensure_table/0` stays everywhere as
  the idempotent fallback; this only guarantees the owner is the application.
  """
  use GenServer

  alias Pokex.Bots.{ReviveLedger, SkillClock, SkillTruth}

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    SkillClock.ensure_table()
    SkillTruth.ensure_table()
    ReviveLedger.ensure_table()
    {:ok, %{}}
  end
end
