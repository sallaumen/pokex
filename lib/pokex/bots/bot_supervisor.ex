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

  alias Pokex.Bots.{Body, Combat, Fishing, GameController, Guardian, Loot, MiniGame}

  def start_link(opts \\ []) do
    body = Keyword.get(opts, :body, Body)
    guardian = Keyword.get(opts, :guardian, Guardian)
    fishing = Keyword.get(opts, :fishing, Fishing.Worker)
    combat = Keyword.get(opts, :combat, Combat.Worker)
    loot = Keyword.get(opts, :loot, Loot.Worker)
    mini_game = Keyword.get(opts, :mini_game, MiniGame.Worker)
    game_controller = Keyword.get(opts, :game_controller, GameController.Worker)

    state = %{
      body: body,
      guardian: guardian,
      fishing: fishing,
      combat: combat,
      loot: loot,
      mini_game: mini_game,
      game_controller: game_controller
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
        mini_game: mini_game,
        game_controller: game_controller
      }) do
    # The panic corner halts the automated workers, including the mini-game watcher (so it can't
    # resume the peers it paused). The GameController is NOT halted — it is an always-on monitor,
    # independent of Start/Stop, so its survival combo can protect you while you play by hand.
    on_panic = fn -> stop_all(fishing, combat, loot, mini_game) end
    peers = %{fishing: fishing, combat: combat, loot: loot}

    children = [
      Supervisor.child_spec({Body, name: body, mini_game: mini_game}, id: body),
      Supervisor.child_spec({Guardian, name: guardian, on_panic: on_panic, body: body},
        id: guardian
      ),
      Supervisor.child_spec({Fishing.Worker, name: fishing, body: body}, id: fishing),
      Supervisor.child_spec({Combat.Worker, name: combat}, id: combat),
      Supervisor.child_spec({Loot.Worker, name: loot, body: body}, id: loot),
      Supervisor.child_spec({MiniGame.Worker, name: mini_game, peers: peers}, id: mini_game),
      Supervisor.child_spec({GameController.Worker, name: game_controller, body: body},
        id: game_controller
      )
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

  # A worker can be legitimately unresponsive for seconds — e.g. parked on a screen capture the
  # OS is throttling (measured: 8-16s per `screencapture` while ScreenCaptureKit recovery
  # contended for the display). The panel's mount goes through here, so a busy worker must NEVER
  # take the page down: ask with a short timeout and fall back to a placeholder snapshot that
  # renders as "ocupado" (every panel label/class has a catch-all for unknown states).
  @status_timeout_ms 1_000
  @busy_snapshot %{state: :ocupado, counters: %{}, error: "sem resposta (captura lenta?)"}

  defp safe_status(server, extra \\ %{}) do
    GenServer.call(server, :status, @status_timeout_ms)
  catch
    :exit, _reason -> Map.merge(@busy_snapshot, extra)
  end

  @spec status(GenServer.server(), GenServer.server(), GenServer.server()) ::
          %{fishing: map, combat: map, loot: map}
  def status(fishing, combat, loot) do
    %{
      fishing: safe_status(fishing),
      combat: safe_status(combat, %{locked_row: nil}),
      loot: safe_status(loot)
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
    # confidence included because the panel template reads @mini_game.confidence STRICTLY —
    # a placeholder without it would crash the very render this fallback exists to protect.
    |> Map.put(:mini_game, safe_status(mini_game, %{in_game?: false, confidence: 0.0}))
  end

  @spec status(
          GenServer.server(),
          GenServer.server(),
          GenServer.server(),
          GenServer.server(),
          GenServer.server()
        ) :: %{fishing: map, combat: map, loot: map, mini_game: map, game_controller: map}
  def status(fishing, combat, loot, mini_game, game_controller) do
    fishing
    |> status(combat, loot, mini_game)
    |> Map.put(:game_controller, safe_status(game_controller, %{hp_pct: nil}))
  end

  def status do
    status(Fishing.Worker, Combat.Worker, Loot.Worker, MiniGame.Worker, GameController.Worker)
  end
end
