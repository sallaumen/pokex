defmodule Pokex.Bots.Supervisor do
  @moduledoc "Supervises all bots. A crashed bot restarts in :idle, never mid-hunt."
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: Supervisor.init([Pokex.Bots.Fisher], strategy: :one_for_one)
end
