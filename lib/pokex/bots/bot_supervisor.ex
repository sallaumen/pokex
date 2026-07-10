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

  alias Pokex.Bots.{Body, Combat, Fishing, Guardian, Loot, MiniGame}

  def start_link(opts \\ []) do
    body = Keyword.get(opts, :body, Body)
    guardian = Keyword.get(opts, :guardian, Guardian)
    fishing = Keyword.get(opts, :fishing, Fishing.Worker)
    combat = Keyword.get(opts, :combat, Combat.Worker)
    loot = Keyword.get(opts, :loot, Loot.Worker)
    mini_game = Keyword.get(opts, :mini_game, MiniGame.Worker)

    state = %{
      body: body,
      guardian: guardian,
      fishing: fishing,
      combat: combat,
      loot: loot,
      mini_game: mini_game
    }

    case Keyword.get(opts, :name, __MODULE__) do
      nil -> Supervisor.start_link(__MODULE__, state)
      name -> Supervisor.start_link(__MODULE__, state, name: name)
    end
  end

  @impl true
  def init(%{
        body: body,
        guardian: guardian,
        fishing: fishing,
        combat: combat,
        loot: loot,
        mini_game: mini_game
      }) do
    on_panic = fn -> stop_all(fishing, combat, loot) end
    peers = %{fishing: fishing, combat: combat, loot: loot}

    children = [
      Supervisor.child_spec({Body, name: body, mini_game: mini_game}, id: body),
      Supervisor.child_spec({Guardian, name: guardian, on_panic: on_panic, body: body},
        id: guardian
      ),
      Supervisor.child_spec({Fishing.Worker, name: fishing, body: body}, id: fishing),
      Supervisor.child_spec({Combat.Worker, name: combat, body: body}, id: combat),
      Supervisor.child_spec({Loot.Worker, name: loot, body: body}, id: loot),
      Supervisor.child_spec({MiniGame.Worker, name: mini_game, peers: peers}, id: mini_game)
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
  def start_all(fishing, combat, loot) do
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

  @spec start_all(
          GenServer.server(),
          GenServer.server(),
          GenServer.server(),
          GenServer.server()
        ) :: :ok | {:error, [String.t()]}
  def start_all(fishing, combat, loot, mini_game) do
    with :ok <- MiniGame.Worker.run(mini_game),
         :ok <- start_all(fishing, combat, loot) do
      :ok
    else
      {:error, _messages} = error ->
        stop_all(fishing, combat, loot, mini_game)
        error
    end
  end

  def start_all do
    start_all(Fishing.Worker, Combat.Worker, Loot.Worker, MiniGame.Worker)
  end

  @doc "Halts all workers. Safe to call repeatedly — halting an idle worker is a no-op."
  @spec stop_all(GenServer.server(), GenServer.server(), GenServer.server()) :: :ok
  def stop_all(fishing, combat, loot) do
    Fishing.Worker.halt(fishing)
    Combat.Worker.halt(combat)
    Loot.Worker.halt(loot)
    :ok
  end

  @spec stop_all(
          GenServer.server(),
          GenServer.server(),
          GenServer.server(),
          GenServer.server()
        ) :: :ok
  def stop_all(fishing, combat, loot, mini_game) do
    stop_all(fishing, combat, loot)
    MiniGame.Worker.halt(mini_game)
    :ok
  end

  def stop_all do
    stop_all(Fishing.Worker, Combat.Worker, Loot.Worker, MiniGame.Worker)
  end

  @spec status(GenServer.server(), GenServer.server(), GenServer.server()) ::
          %{fishing: map, combat: map, loot: map}
  def status(fishing, combat, loot) do
    %{
      fishing: Fishing.Worker.status(fishing),
      combat: Combat.Worker.status(combat),
      loot: Loot.Worker.status(loot)
    }
  end

  @spec status(
          GenServer.server(),
          GenServer.server(),
          GenServer.server(),
          GenServer.server()
        ) :: %{fishing: map, combat: map, loot: map, mini_game: map}
  def status(fishing, combat, loot, mini_game) do
    fishing
    |> status(combat, loot)
    |> Map.put(:mini_game, MiniGame.Worker.status(mini_game))
  end

  def status do
    status(Fishing.Worker, Combat.Worker, Loot.Worker, MiniGame.Worker)
  end
end
