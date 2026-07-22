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

  alias Pokex.Bots.{Body, Catcher, Combat, Fishing, PlayerSupport, Guardian, MiniGame}

  def start_link(opts \\ []) do
    body = Keyword.get(opts, :body, Body)
    guardian = Keyword.get(opts, :guardian, Guardian)
    fishing = Keyword.get(opts, :fishing, Fishing.Worker)
    combat = Keyword.get(opts, :combat, Combat.Worker)
    catcher = Keyword.get(opts, :catcher, Catcher.Worker)
    mini_game = Keyword.get(opts, :mini_game, MiniGame.Worker)
    player_support = Keyword.get(opts, :player_support, PlayerSupport.Worker)

    state = %{
      body: body,
      guardian: guardian,
      fishing: fishing,
      combat: combat,
      catcher: catcher,
      mini_game: mini_game,
      player_support: player_support
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
        catcher: catcher,
        mini_game: mini_game,
        player_support: player_support
      }) do
    # The panic corner halts EVERY automated worker — including the mini-game watcher (its
    # halt clears the :mini_game fact, so nobody stays self-held) and the PlayerSupport
    # (Lucas: a support gone wrong, e.g. a minimized window misread burning potions, must be
    # killable by mouse-to-corner like everything else; it re-arms on boot, Iniciar bot, or a
    # support toggle).
    on_panic = fn -> stop_all(fishing, combat, catcher, mini_game, player_support) end

    children = [
      Supervisor.child_spec({Body, name: body}, id: body),
      Supervisor.child_spec({Guardian, name: guardian, on_panic: on_panic, body: body},
        id: guardian
      ),
      Supervisor.child_spec({Fishing.Worker, name: fishing, body: body}, id: fishing),
      Supervisor.child_spec({Combat.Worker, name: combat}, id: combat),
      Supervisor.child_spec({Catcher.Worker, name: catcher, body: body}, id: catcher),
      Supervisor.child_spec({MiniGame.Worker, name: mini_game}, id: mini_game),
      Supervisor.child_spec({PlayerSupport.Worker, name: player_support, body: body},
        id: player_support
      )
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Starts the workers in order (fishing → combat → catcher). If any fails
  preflight/calibration the ones after it never start, and everything is halted again, so a
  failed `start_all/0` never leaves a partial set running. Catcher is event-driven (armed in
  `parado` mode, idle waiting on the corpse feed), so its `run` just readies it.
  """
  # The order a run must follow: the mini-game watcher first (it owns Space, so a
  # loot press before it is watching would drive the capsule), then fishing →
  # combat → catcher.
  @run_order [:mini_game, :fishing, :combat, :catcher]

  @spec start_all(GenServer.server(), GenServer.server(), GenServer.server()) ::
          :ok | {:error, [String.t()]}
  def start_all(fishing, combat, catcher) do
    run_chain(%{fishing: fishing, combat: combat, catcher: catcher}, [:fishing, :combat, :catcher])
  end

  @spec start_all(
          GenServer.server(),
          GenServer.server(),
          GenServer.server(),
          GenServer.server()
        ) :: :ok | {:error, [String.t()]}
  def start_all(fishing, combat, catcher, mini_game) do
    run_chain(
      %{fishing: fishing, combat: combat, catcher: catcher, mini_game: mini_game},
      @run_order
    )
  end

  # Runs exactly the workers `wanted` names, in @run_order, skipping the rest.
  # A failure anywhere halts everything this map can reach: a half-started fleet
  # is worse than a stopped one, because the half that IS running keeps touching
  # the game.
  defp run_chain(servers, wanted) do
    result =
      @run_order
      |> Enum.filter(&(&1 in wanted and is_map_key(servers, &1)))
      |> Enum.reduce_while(:ok, fn worker, :ok ->
        case run_worker(worker, servers) do
          :ok -> {:cont, :ok}
          {:error, _messages} = error -> {:halt, error}
        end
      end)

    with {:error, _messages} <- result do
      halt_chain(servers)
      result
    end
  end

  defp run_worker(:mini_game, %{mini_game: server}), do: MiniGame.Worker.run(server)
  defp run_worker(:fishing, %{fishing: server}), do: Fishing.Worker.run(server)
  defp run_worker(:combat, %{combat: server}), do: Combat.Worker.run(server)
  defp run_worker(:catcher, %{catcher: server}), do: Catcher.Worker.run(server)

  # Halting an idle worker is a no-op, so this halts every worker the map names —
  # not only the ones the mode asked to start.
  defp halt_chain(servers) do
    Enum.each(@run_order, fn worker ->
      case servers do
        %{^worker => server} -> halt_worker(worker, server)
        _not_named -> :ok
      end
    end)
  end

  defp halt_worker(:mini_game, server), do: MiniGame.Worker.halt(server)
  defp halt_worker(:fishing, server), do: Fishing.Worker.halt(server)
  defp halt_worker(:combat, server), do: Combat.Worker.halt(server)
  defp halt_worker(:catcher, server), do: Catcher.Worker.halt(server)

  @spec start_all(
          GenServer.server(),
          GenServer.server(),
          GenServer.server(),
          GenServer.server(),
          GenServer.server()
        ) :: :ok | {:error, [String.t()]}
  def start_all(fishing, combat, catcher, mini_game, player_support) do
    # Iniciar bot is the ONE act that clears a standing panic order — the human explicitly
    # asked for the bot again. Cleared even if preflight fails below: the intent to resume
    # was expressed either way.
    Pokex.Bots.InputGate.set_panic_latch(false)

    # PlayerSupport.run is infallible (no preflight — it monitors even uncalibrated), so it
    # can't poison the with-chain; arming it first means a preflight failure below still
    # leaves the player protected. Gated by the same env flag as its boot auto-start so a
    # test calling start_all never leaves the app-global monitor ticking against the shared
    # Rig for the rest of the suite.
    if Application.get_env(:pokex, :player_support_auto_monitor, true),
      do: :ok = PlayerSupport.Worker.run(player_support)

    # The MODE decides which workers this is: standing on a spot runs the rod and
    # the mini-game watcher; walking runs neither. Reading it here rather than at
    # the button means the focus guard's auto-resume obeys it too.
    wanted = Pokex.Modes.workers(Pokex.Modes.current())

    servers = %{
      fishing: fishing,
      combat: combat,
      catcher: catcher,
      mini_game: mini_game
    }

    case run_chain(servers, wanted) do
      :ok ->
        at = System.monotonic_time(:millisecond)

        # Stamp WHICH calibration this run loaded (workers read the file at run).
        # The panel compares it against the file's current mtime: different =
        # "os bots rodam uma calibração antiga" → the restart banner.
        Pokex.Perception.WorldState.put(
          :calibration,
          %{loaded_mtime: Pokex.Calibration.mtime()},
          at
        )

        # The hunt SESSION starts here — worker counters also reset at run, so
        # the panel's duration/rates measure the same window the counters do.
        Pokex.Perception.WorldState.put(:session, %{started_at: at}, at)

        :ok

      {:error, _messages} = error ->
        Pokex.Perception.WorldState.forget(:calibration)
        Pokex.Perception.WorldState.forget(:session)
        error
    end
  end

  def start_all do
    start_all(
      Fishing.Worker,
      Combat.Worker,
      Catcher.Worker,
      MiniGame.Worker,
      PlayerSupport.Worker
    )
  end

  @doc "Halts all workers. Safe to call repeatedly — halting an idle worker is a no-op."
  @spec stop_all(GenServer.server(), GenServer.server(), GenServer.server()) :: :ok
  def stop_all(fishing, combat, catcher) do
    Fishing.Worker.halt(fishing)
    Combat.Worker.halt(combat)
    Catcher.Worker.halt(catcher)
    :ok
  end

  @spec stop_all(
          GenServer.server(),
          GenServer.server(),
          GenServer.server(),
          GenServer.server()
        ) :: :ok
  def stop_all(fishing, combat, catcher, mini_game) do
    stop_all(fishing, combat, catcher)
    MiniGame.Worker.halt(mini_game)
    :ok
  end

  @spec stop_all(
          GenServer.server(),
          GenServer.server(),
          GenServer.server(),
          GenServer.server(),
          GenServer.server()
        ) :: :ok
  def stop_all(fishing, combat, catcher, mini_game, player_support) do
    stop_all(fishing, combat, catcher, mini_game)
    PlayerSupport.Worker.halt(player_support)
    # nothing is running an old calibration anymore — the banner has no meaning
    Pokex.Perception.WorldState.forget(:calibration)
    # the hunt session ended with the workers
    Pokex.Perception.WorldState.forget(:session)
    :ok
  end

  @doc """
  The emergency-escape protocol (Actions & Rules): latch FIRST (nothing may
  auto-resume — the flee usually lands on ANOTHER floor, where resuming the
  hunt would be wrong; only Iniciar clears it), ONE click-to-walk to the
  calibrated staircase at :critical, halt the fleet, tell the panel. Returns
  the flee result — {:error, :not_calibrated} still stops everything: a
  triggered escape must never leave the hunt running.
  """
  def emergency_escape(reason) do
    Pokex.Bots.InputGate.set_panic_latch(true)
    flee = PlayerSupport.Worker.flee_to_escape()
    stop_all()
    Phoenix.PubSub.broadcast(Pokex.PubSub, "combat", {:escape, reason, flee})
    flee
  end

  def stop_all do
    stop_all(
      Fishing.Worker,
      Combat.Worker,
      Catcher.Worker,
      MiniGame.Worker,
      PlayerSupport.Worker
    )
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
          %{fishing: map, combat: map, catcher: map}
  def status(fishing, combat, catcher) do
    %{
      fishing: safe_status(fishing),
      combat: safe_status(combat, %{locked_row: nil}),
      # mode included so the busy placeholder carries the full catcher snapshot shape (and any
      # future template read of .mode can't crash).
      catcher: safe_status(catcher, %{mode: "parado"})
    }
  end

  @spec status(
          GenServer.server(),
          GenServer.server(),
          GenServer.server(),
          GenServer.server()
        ) :: %{fishing: map, combat: map, catcher: map, mini_game: map}
  def status(fishing, combat, catcher, mini_game) do
    fishing
    |> status(combat, catcher)
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
        ) :: %{fishing: map, combat: map, catcher: map, mini_game: map, player_support: map}
  def status(fishing, combat, catcher, mini_game, player_support) do
    fishing
    |> status(combat, catcher, mini_game)
    |> Map.put(:player_support, safe_status(player_support, %{hp_pct: nil}))
  end

  def status do
    status(Fishing.Worker, Combat.Worker, Catcher.Worker, MiniGame.Worker, PlayerSupport.Worker)
  end
end
