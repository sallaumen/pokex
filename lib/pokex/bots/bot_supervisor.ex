defmodule Pokex.Bots.BotSupervisor do
  @moduledoc """
  Owns the whole parallel bot: the shared `Body`, the `Guardian` (panic
  corner poller), and the two workers (`Fishing.Worker`, `Combat.Worker`).
  All four children start idle — nothing moves the mouse until `start_all/0`
  is called.

  `start_all/0` / `stop_all/0` / `status/0` fan out to the two workers with a
  uniform shape (`:ok | {:error, messages}`), so callers don't need to
  special-case which bot is behind it.

  Registers its children under fixed default names (`Pokex.Bots.Body`,
  `Pokex.Bots.Guardian`, `Pokex.Bots.Fishing.Worker`,
  `Pokex.Bots.Combat.Worker`) so the rest of the app can reach them without
  going through this supervisor. Tests that need an isolated instance (so
  they don't collide with the one `Pokex.Application` already starts) pass
  `:name, nil` plus `:fishing` / `:combat` names — see
  `test/pokex/bots/bot_supervisor_test.exs`.
  """
  use Supervisor

  alias Pokex.Bots.{Body, Combat, Fishing, Guardian, Loot}

  def start_link(opts \\ []) do
    body = Keyword.get(opts, :body, Body)
    guardian = Keyword.get(opts, :guardian, Guardian)
    fishing = Keyword.get(opts, :fishing, Fishing.Worker)
    combat = Keyword.get(opts, :combat, Combat.Worker)
    loot = Keyword.get(opts, :loot, Loot.Worker)
    state = %{body: body, guardian: guardian, fishing: fishing, combat: combat, loot: loot}

    case Keyword.get(opts, :name, __MODULE__) do
      nil -> Supervisor.start_link(__MODULE__, state)
      name -> Supervisor.start_link(__MODULE__, state, name: name)
    end
  end

  @impl true
  def init(%{body: body, guardian: guardian, fishing: fishing, combat: combat, loot: loot}) do
    on_panic = fn -> stop_all(fishing, combat, loot) end

    children = [
      Supervisor.child_spec({Body, name: body}, id: body),
      Supervisor.child_spec({Guardian, name: guardian, on_panic: on_panic, body: body},
        id: guardian
      ),
      Supervisor.child_spec({Fishing.Worker, name: fishing, body: body}, id: fishing),
      Supervisor.child_spec({Combat.Worker, name: combat, body: body}, id: combat),
      Supervisor.child_spec({Loot.Worker, name: loot, body: body}, id: loot)
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Starts the workers in order (fishing → combat → loot). If any fails
  preflight/calibration the ones after it never start, and everything is halted again, so a
  failed `start_all/0` never leaves a partial set running. Loot is event-driven (idle until a
  kill), so its `run` just readies it.
  """
  @spec start_all(GenServer.server(), GenServer.server(), GenServer.server()) ::
          :ok | {:error, [String.t()]}
  def start_all(fishing \\ Fishing.Worker, combat \\ Combat.Worker, loot \\ Loot.Worker) do
    with :ok <- Fishing.Worker.run(fishing),
         :ok <- Combat.Worker.run(combat),
         :ok <- Loot.Worker.run(loot) do
      :ok
    else
      {:error, _messages} = error ->
        stop_all(fishing, combat, loot)
        error
    end
  end

  @doc "Halts all workers. Safe to call repeatedly — halting an idle worker is a no-op."
  @spec stop_all(GenServer.server(), GenServer.server(), GenServer.server()) :: :ok
  def stop_all(fishing \\ Fishing.Worker, combat \\ Combat.Worker, loot \\ Loot.Worker) do
    Fishing.Worker.halt(fishing)
    Combat.Worker.halt(combat)
    Loot.Worker.halt(loot)
    :ok
  end

  @spec status(GenServer.server(), GenServer.server(), GenServer.server()) ::
          %{fishing: map, combat: map, loot: map}
  def status(fishing \\ Fishing.Worker, combat \\ Combat.Worker, loot \\ Loot.Worker) do
    %{
      fishing: Fishing.Worker.status(fishing),
      combat: Combat.Worker.status(combat),
      loot: Loot.Worker.status(loot)
    }
  end
end
