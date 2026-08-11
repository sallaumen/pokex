defmodule Pokex.Timers.Schedule do
  @moduledoc """
  Which scheduled actions are due, and when the next one is.

  Pure: it is handed the clocks rather than reading any, so "does the berry go
  off now?" is a question with an answer at any point in time, including the
  ones that are awkward to reach in a running game — the second stretch of a
  hunt, the minute after a restart, the tick where two timers land together.

  The clocks:

    * `started_at` — when the fleet started. A `:every` timer that has never
      fired counts from here, so a 55-minute berry does not go off the instant
      the bot starts.
    * `mob_at` — when the hunt last started gathering, or `nil` when it is not.
      An `:after_mob` timer fires ONCE per stretch: `last_fired` older than
      this stretch means it has not gone off in THIS one.
  """

  alias Pokex.Timers.Timer

  @type clocks :: %{
          required(:now) => integer,
          required(:started_at) => integer,
          optional(:mob_at) => integer | nil,
          optional(:last_fired) => %{optional(String.t()) => integer}
        }

  @doc """
  The timers that should fire at `clocks.now`, in the order they are listed.

  Disabled ones never answer, and neither do timers whose clock has not
  started — an `:after_mob` timer outside a mob stretch is not late, it is
  simply not counting.
  """
  @spec due([Timer.t()], clocks) :: [Timer.t()]
  def due(timers, clocks) when is_list(timers),
    do: Enum.filter(timers, &due?(&1, clocks))

  @doc "Whether this one timer is due."
  @spec due?(Timer.t(), clocks) :: boolean
  def due?(%Timer{enabled?: false}, _clocks), do: false

  def due?(%Timer{} = timer, clocks) do
    case remaining(timer, clocks) do
      nil -> false
      ms -> ms <= 0
    end
  end

  @doc """
  How long until this timer fires, in ms — `nil` when it is not counting
  (disabled, or an `:after_mob` timer outside a stretch).

  Negative means overdue, which the panel shows as "agora": a countdown that
  clamps at zero cannot tell "about to" from "the presses are not landing".
  """
  @spec remaining(Timer.t(), clocks) :: integer | nil
  def remaining(%Timer{enabled?: false}, _clocks), do: nil

  def remaining(%Timer{trigger: :every} = timer, clocks) do
    from = last_fired(timer, clocks) || clocks.started_at
    from + timer.after_ms - clocks.now
  end

  def remaining(%Timer{trigger: :after_mob} = timer, clocks) do
    case Map.get(clocks, :mob_at) do
      nil ->
        nil

      mob_at ->
        if fired_this_stretch?(timer, clocks, mob_at),
          do: nil,
          else: mob_at + timer.after_ms - clocks.now
    end
  end

  # Its own last firing decides, not a counter: a stretch that started AFTER
  # the last firing is a stretch this timer has not served yet. That is what
  # makes it survive a restart, a route change, and two stretches back to back.
  defp fired_this_stretch?(timer, clocks, mob_at) do
    case last_fired(timer, clocks) do
      nil -> false
      at -> at >= mob_at
    end
  end

  defp last_fired(%Timer{id: id}, clocks),
    do: clocks |> Map.get(:last_fired, %{}) |> Map.get(id)

  @doc """
  Marks `timer` as fired at `now`, returning the updated `last_fired` map.

  Stamped when the press is DISPATCHED, never when it lands: the Body's queue
  can hold a press for seconds, and a timer that waited for the receipt would
  fire again on every tick in between.
  """
  @spec fired(%{optional(String.t()) => integer}, Timer.t(), integer) ::
          %{optional(String.t()) => integer}
  def fired(last_fired, %Timer{id: id}, now), do: Map.put(last_fired, id, now)
end
