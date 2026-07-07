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

  alias Pokex.Bots.{Body, Combat, Fishing, Guardian}

  def start_link(opts \\ []) do
    body = Keyword.get(opts, :body, Body)
    guardian = Keyword.get(opts, :guardian, Guardian)
    fishing = Keyword.get(opts, :fishing, Fishing.Worker)
    combat = Keyword.get(opts, :combat, Combat.Worker)
    state = %{body: body, guardian: guardian, fishing: fishing, combat: combat}

    case Keyword.get(opts, :name, __MODULE__) do
      nil -> Supervisor.start_link(__MODULE__, state)
      name -> Supervisor.start_link(__MODULE__, state, name: name)
    end
  end

  @impl true
  def init(%{body: body, guardian: guardian, fishing: fishing, combat: combat}) do
    on_panic = fn -> stop_all(fishing, combat) end

    children = [
      Supervisor.child_spec({Body, name: body}, id: body),
      Supervisor.child_spec({Guardian, name: guardian, on_panic: on_panic, body: body},
        id: guardian
      ),
      Supervisor.child_spec({Fishing.Worker, name: fishing, body: body}, id: fishing),
      Supervisor.child_spec({Combat.Worker, name: combat, body: body}, id: combat)
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Starts both workers. If fishing fails preflight/calibration, combat is
  never started. If fishing starts but combat then fails, fishing is halted
  again so a failed `start_all/0` never leaves exactly one bot running.
  """
  @spec start_all(GenServer.server(), GenServer.server()) :: :ok | {:error, [String.t()]}
  def start_all(fishing \\ Fishing.Worker, combat \\ Combat.Worker) do
    with :ok <- Fishing.Worker.run(fishing),
         :ok <- Combat.Worker.run(combat) do
      :ok
    else
      {:error, _messages} = error ->
        stop_all(fishing, combat)
        error
    end
  end

  @doc "Halts both workers. Safe to call repeatedly — halting an idle worker is a no-op."
  @spec stop_all(GenServer.server(), GenServer.server()) :: :ok
  def stop_all(fishing \\ Fishing.Worker, combat \\ Combat.Worker) do
    Fishing.Worker.halt(fishing)
    Combat.Worker.halt(combat)
    :ok
  end

  @spec status(GenServer.server(), GenServer.server()) :: %{fishing: map, combat: map}
  def status(fishing \\ Fishing.Worker, combat \\ Combat.Worker) do
    %{fishing: Fishing.Worker.status(fishing), combat: Combat.Worker.status(combat)}
  end
end
