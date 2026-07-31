defmodule Pokex.Bots.Session do
  @moduledoc """
  The session GENERATION: an order counter, nothing more.

  The problem: `Focus` kept a boolean `resume?` — "a bot was running when focus
  dropped". A boolean has no identity: between focus loss and return, ANY other
  order (panel Stop, panic, logout, cavebot brake) should kill that pending
  resume, and only panic did (via the latch). A manual Stop in between was
  forgotten and the refocus re-armed the fleet over the human's order.

  The contract: **every order increments the generation**. Whoever wants to
  resume later stores their OWN pause's generation and only acts if
  `generation/0` is still that value — any order in between invalidates the
  resume, without needing to know which one it was.

  Orders (`order/2`): `:start` and `:stop` (the `BotSupervisor` funnels — every
  Iniciar/Parar/panic/logout/brake goes through there) and `:hold` (the Focus
  pause, resumable by definition — but still invalidating any older resume).

  A tiny process of its own, not a key in InputGate, on purpose: the InputGate
  is the ACTUATION safety floor (physical input veto); the generation orders
  INTENT. This module is the seed of a session owner, not a scheduler.

  A restart of this process zeroes the counter — failing SAFE: a resume stored
  before the restart compares `gen != 0` (real orders leave the generation ≥ 1)
  and is discarded. Worst case: Iniciar must be pressed again.
  """
  use GenServer

  @typedoc "One recorded order: who ordered what, at which generation."
  @type order :: %{
          kind: :start | :stop | :hold,
          reason: String.t() | nil,
          generation: pos_integer(),
          at: integer()
        }

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    state = %{generation: 0, last_order: nil}

    case name do
      nil -> GenServer.start_link(__MODULE__, state)
      name -> GenServer.start_link(__MODULE__, state, name: name)
    end
  end

  @doc """
  Records an order and returns the NEW generation — atomically. Whoever needs
  to compare later (Focus) stores exactly the value returned by their own
  order; reading the counter in a second step would open the window where
  another order slips in and the resume compares against the wrong generation.
  """
  @spec order(:start | :stop | :hold, String.t() | nil, GenServer.server()) :: pos_integer()
  def order(kind, reason \\ nil, server \\ __MODULE__) when kind in [:start, :stop, :hold],
    do: GenServer.call(server, {:order, kind, reason})

  @doc "The current generation. A pending resume only holds if it is still its pause's."
  @spec generation(GenServer.server()) :: non_neg_integer()
  def generation(server \\ __MODULE__), do: GenServer.call(server, :generation)

  @doc "The last recorded order (nil before the first) — for panel and diagnostics."
  @spec last_order(GenServer.server()) :: order() | nil
  def last_order(server \\ __MODULE__), do: GenServer.call(server, :last_order)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:order, kind, reason}, _from, state) do
    generation = state.generation + 1

    order = %{
      kind: kind,
      reason: reason,
      generation: generation,
      at: System.monotonic_time(:millisecond)
    }

    {:reply, generation, %{state | generation: generation, last_order: order}}
  end

  def handle_call(:generation, _from, state), do: {:reply, state.generation, state}
  def handle_call(:last_order, _from, state), do: {:reply, state.last_order, state}
end
