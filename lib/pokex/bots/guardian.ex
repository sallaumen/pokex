defmodule Pokex.Bots.Guardian do
  @moduledoc """
  The single owner of the panic corner. Polls `Body.cursor/1` on a timer
  (bypasses the input queue — safe to poll live) and, the instant the cursor
  sits in `Pokex.Bots.Corner`'s top-left kill corner, halts EVERYTHING at
  once via `on_panic` and broadcasts `{:panic, "kill corner"}` on both the
  "fishing" and "combat" PubSub topics.

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

  @fishing_topic "fishing"
  @combat_topic "combat"

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    on_panic = Keyword.fetch!(opts, :on_panic)
    body = Keyword.get(opts, :body, Body)
    poll_ms = Keyword.get(opts, :poll_ms, 100)

    state = %{on_panic: on_panic, body: body, poll_ms: poll_ms}

    case name do
      nil -> GenServer.start_link(__MODULE__, state)
      name -> GenServer.start_link(__MODULE__, state, name: name)
    end
  end

  @impl true
  def init(state) do
    schedule_poll(state.poll_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    case Body.cursor(state.body) do
      {:ok, point} ->
        in_corner? = Corner.in_kill_corner?(point)
        # The gate closes the moment the cursor enters the corner, so it ALSO suppresses the
        # always-on GameController's revive/potion — not just the Start/Stop workers on_panic
        # halts. It reopens when the cursor leaves, so manual-play protection comes right back.
        InputGate.set_corner_ok(not in_corner?)
        if in_corner?, do: panic(state)

      _error ->
        :ok
    end

    schedule_poll(state.poll_ms)
    {:noreply, state}
  end

  defp panic(state) do
    state.on_panic.()
    Phoenix.PubSub.broadcast(Pokex.PubSub, @fishing_topic, {:panic, "kill corner"})
    Phoenix.PubSub.broadcast(Pokex.PubSub, @combat_topic, {:panic, "kill corner"})
  end

  defp schedule_poll(poll_ms), do: Process.send_after(self(), :poll, poll_ms)
end
