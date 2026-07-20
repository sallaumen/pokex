defmodule Pokex.Bots.Guardian do
  @moduledoc """
  The single owner of the panic corner. Polls `Body.cursor/1` on a timer
  (bypasses the input queue — safe to poll live) and, the instant the cursor
  sits in `Pokex.Bots.Corner`'s top-left kill corner, halts EVERYTHING at
  once via `on_panic` and broadcasts `{:panic, "kill corner"}` on both the
  "fishing" and "combat" PubSub topics.

  ALSO the watchdog for the session STOP CONDITIONS (hunt goals): the same
  poll checks the `:session` fact against `stop_after_minutes` /
  `stop_after_kills` (kills ride the combat snapshots this process
  subscribes to). A hit halts the fleet through the SAME latch + on_panic
  path as the corner — a reached goal is a standing order to stay stopped
  until the human presses Iniciar — but broadcasts `{:session_stop, reason}`
  instead of `{:panic, _}`, so the panel reports a met goal, not an
  emergency. Being external to every worker, the stop can never deadlock on
  a worker halting itself; and since `on_panic` (stop_all) forgets the
  `:session` fact, a fired condition cannot re-fire.

  `on_panic` is injected (not a hard dependency on the bot supervisor) so
  this module doesn't need to know about `BotSupervisor` — callers pass e.g.
  `&BotSupervisor.stop_all/0`.

  Design note: `on_panic` fires on EVERY poll tick that finds the cursor in
  the corner, not just on the first entry. A human parked in the corner
  wants the bot to stay stopped, and re-invoking a stop is harmless as long
  as `on_panic` is idempotent (stopping already-stopped workers is a no-op)
  — which is simpler and safer than tracking "fresh entry" edge state that
  could itself have a bug that lets a second panic slip through unhandled.

  The poll loop must never crash on a bad cursor read: an `{:error, _}`
  reply (or any other unexpected shape) just reschedules the next poll.

  Bound on the panic guarantee: panic is delivered promptly but is bounded
  by whatever `Body` action is currently in flight — a worker blocked
  mid-action is halted once that action returns (actions are short: one
  osascript/cliclick).
  """
  use GenServer
  require Logger

  alias Pokex.Bots.{Body, Corner, InputGate}
  alias Pokex.Perception.WorldState
  alias Pokex.Settings

  @fishing_topic "fishing"
  @combat_topic "combat"

  # same practically-forever max age the :calibration/:session stamps use
  @session_max_age_ms 4_000_000_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    on_panic = Keyword.fetch!(opts, :on_panic)
    body = Keyword.get(opts, :body, Body)
    poll_ms = Keyword.get(opts, :poll_ms, 100)

    state = %{on_panic: on_panic, body: body, poll_ms: poll_ms, fights: 0}

    case name do
      nil -> GenServer.start_link(__MODULE__, state)
      name -> GenServer.start_link(__MODULE__, state, name: name)
    end
  end

  @impl true
  def init(state) do
    # kills for the stop condition ride the snapshots combat already broadcasts
    Phoenix.PubSub.subscribe(Pokex.PubSub, @combat_topic)
    schedule_poll(state.poll_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    case Body.cursor(state.body) do
      {:ok, point} ->
        in_corner? = Corner.in_kill_corner?(point)
        # The gate closes the moment the cursor enters the corner, so it ALSO suppresses the
        # always-on PlayerSupport's revive/potion — not just the Start/Stop workers on_panic
        # halts. It reopens when the cursor leaves, so manual-play protection comes right back.
        InputGate.set_corner_ok(not in_corner?)
        if in_corner?, do: panic(state)

      _error ->
        :ok
    end

    check_session_limits(state)
    schedule_poll(state.poll_ms)
    {:noreply, state}
  end

  def handle_info({:combat, snapshot}, state) do
    fights = get_in(snapshot, [:counters, :fights])
    {:noreply, %{state | fights: fights || state.fights}}
  end

  # the combat topic also carries {:combat_log, ...} / {:panic, ...} chatter — not ours
  def handle_info(_msg, state), do: {:noreply, state}

  defp panic(state) do
    # LATCH FIRST, halt second: the latch is what forbids every auto-resume path (the Focus
    # poller's refocus resume) from restarting workers over this human order — set it before
    # anything else so no resume can slip in between. Only Iniciar bot clears it.
    InputGate.set_panic_latch(true)
    state.on_panic.()
    Phoenix.PubSub.broadcast(Pokex.PubSub, @fishing_topic, {:panic, "kill corner"})
    Phoenix.PubSub.broadcast(Pokex.PubSub, @combat_topic, {:panic, "kill corner"})
  end

  # No running session (no fact) = nothing to measure; 0 = condition off.
  # A fired stop halts the fleet, which forgets :session — self-disarming.
  defp check_session_limits(state) do
    now = System.monotonic_time(:millisecond)

    case WorldState.get(:session, @session_max_age_ms, now) do
      {:ok, %{started_at: started_at}} ->
        minutes = Settings.get(:stop_after_minutes)
        kills = Settings.get(:stop_after_kills)

        cond do
          is_integer(minutes) and minutes > 0 and now - started_at >= minutes * 60_000 ->
            session_stop(state, "tempo de caçada atingido (#{minutes}min)")

          is_integer(kills) and kills > 0 and state.fights >= kills ->
            session_stop(state, "meta de kills atingida (#{state.fights}/#{kills})")

          true ->
            :ok
        end

      _no_session ->
        :ok
    end
  end

  defp session_stop(state, reason) do
    Logger.info("Guardian: parada por condição — #{reason}")
    # same order as panic: latch first, halt second — nothing may auto-resume
    # a finished hunt; only Iniciar clears it.
    InputGate.set_panic_latch(true)
    state.on_panic.()
    Phoenix.PubSub.broadcast(Pokex.PubSub, @combat_topic, {:session_stop, reason})
  end

  defp schedule_poll(poll_ms), do: Process.send_after(self(), :poll, poll_ms)
end
