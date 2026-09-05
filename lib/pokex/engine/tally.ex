defmodule Pokex.Engine.Tally do
  @moduledoc """
  THE REAL NIGHT in numbers, in the same shape as the simulator's scoreboard.

  The simulator can answer "is this brain better than that one" because it owns the world: it
  knows how many monsters existed and how many died. A real hunt has no such luxury; what it has
  is the trail the bot left. This module reads that trail and answers the same questions with
  it.

  Three sources, each knowing something the others do not:

    * `vitals` - the engine's pulse: health, how many on the list, how many damage keys
      ready, and whether the pokémon is on the field. This is where floor time,
      no-cooldown time and the distribution of piles he found come from.
    * `decision` - one line per CHANGE OF MIND, with the phase. This is where "where the
      minute went" comes from.
    * `kill` - the one moment the real world does not deduce: `Combat` saw a target fall.

  ## What this scoreboard is NOT

  It is not comparable to the simulator's line by line. There the rates come from an invented
  world and are worth a COMPARISON between two brains; here they come from the game and are
  worth what the night actually produced. What compares between the two is the SHAPE: if the
  real hunt spends the minute where the simulated one spends it, the simulator is telling the
  truth about the hunt.
  """

  alias Pokex.Engine.Events

  @minute_ms 60_000

  @doc """
  One day's scoreboard, or `nil` when there is no trail at all.

  `at` exists for the test: the window runs from the day's first record to its last, and a day
  with a single record has no window.
  """
  @spec of_day(Date.t()) :: map | nil
  def of_day(date \\ Date.utc_today()), do: date |> Events.read_day() |> card()

  @doc "The scoreboard of a list of records already read."
  @spec card([map]) :: map | nil
  def card([]), do: nil

  def card(events) do
    vitals = Enum.filter(events, &(&1["kind"] == "vitals"))
    decisions = Enum.filter(events, &(&1["kind"] == "decision"))
    kills = Enum.filter(events, &(&1["kind"] == "kill"))
    receipts = Enum.filter(events, &(&1["kind"] == "receipt"))

    case window(events) do
      nil ->
        nil

      {from, to} ->
        minutes = max(to - from, 1) / @minute_ms

        %{
          from: from,
          to: to,
          minutes: Float.round(minutes, 1),
          kills: length(kills),
          kills_per_min: per_min(length(kills), minutes),
          revives: revives(decisions),
          revives_per_min: per_min(revives(decisions), minutes),
          down_pct: share(vitals, &(&1["out"] != true)),
          stalled_pct: share(vitals, &stalled?/1),
          piles: piles(vitals),
          by_phase: by_phase(decisions, to),
          keys: keys(receipts)
        }
    end
  end

  # The window is the trail, not the clock: a day with a single record has no duration, and
  # dividing by it would invent a rate.
  defp window(events) do
    times = for e <- events, is_integer(e["at"]), do: e["at"]

    case times do
      [] -> nil
      [_only] -> nil
      _many -> {Enum.min(times), Enum.max(times)}
    end
  end

  # A revive press is a DECISION, and that is how it shows in the trail: a decision line with
  # `revive: "now"`. Counted per change of mind, the cadence those lines are written at: two
  # in a row with the same phrase are the same press.
  defp revives(decisions), do: Enum.count(decisions, &(&1["revive"] == "now"))

  # No pokémon on the field is the only pure loss: no kills, no defence, and the bites land on
  # the CHARACTER.
  defp share([], _pred), do: 0.0

  defp share(vitals, pred) do
    Float.round(Enum.count(vitals, pred) * 100 / length(vitals), 1)
  end

  # Zero free cooldowns with mobs on screen: the state R7 attacks.
  defp stalled?(v) do
    is_integer(v["enemies"]) and v["enemies"] > 0 and is_integer(v["ready"]) and v["ready"] == 0
  end

  # The piles he found: how many times the battle list held 1, 2, 3… His ruler argued against
  # what the game delivers.
  defp piles(vitals) do
    vitals
    |> Enum.map(& &1["enemies"])
    |> Enum.filter(&(is_integer(&1) and &1 > 0))
    |> Enum.frequencies()
  end

  @doc """
  THE KEYS THAT REALLY FIRED, by the interval between them.

  "How long between two keys does the game accept" is a question about the GAME, and the game
  already answers it: a key that fired stops being ready. One night with the gap at 500ms and
  another at 200 answer together what no discussion answers, and that is why `gap_ms` travels in
  every receipt rather than outside it.

  `unknown` is not a failure: it is a key that was already cooling when the burst fired, and
  about that one the receipt has nothing to say.
  """
  @spec keys([map]) :: %{optional(integer) => map}
  def keys(receipts) do
    receipts
    |> Enum.group_by(& &1["gap_ms"])
    |> Map.new(fn {gap, rows} -> {gap, tally_keys(rows)} end)
  end

  defp tally_keys(rows) do
    count = fn field -> Enum.sum(Enum.map(rows, &length(&1[field] || []))) end
    fired = count.("fired")
    missed = count.("missed")
    judged = fired + missed

    %{
      rajadas: length(rows),
      sairam: fired,
      falharam: missed,
      sem_veredito: count.("unknown"),
      # the rate only exists when there was something to judge: a whole night of keys
      # already cooling proves nothing about the interval
      taxa: if(judged > 0, do: Float.round(fired * 100 / judged, 1))
    }
  end

  # Where the minute went. A decision line lasts until the next one, which is exactly what
  # "one line per change of mind" means.
  defp by_phase([], _to), do: []

  defp by_phase(decisions, to) do
    decisions
    |> Enum.chunk_every(2, 1, [%{"at" => to}])
    |> Enum.reduce(%{}, fn [d, next], acc ->
      Map.update(acc, d["phase"], span(d, next), &(&1 + span(d, next)))
    end)
    |> shares()
  end

  defp span(d, next), do: max((next["at"] || d["at"]) - d["at"], 0)

  defp shares(by_phase) do
    total = by_phase |> Map.values() |> Enum.sum() |> max(1)

    by_phase
    |> Enum.map(fn {phase, ms} ->
      %{phase: phase, ms: ms, pct: Float.round(ms * 100 / total, 1)}
    end)
    |> Enum.sort_by(& &1.ms, :desc)
  end

  defp per_min(_count, minutes) when minutes <= 0, do: 0.0
  defp per_min(count, minutes), do: Float.round(count / minutes, 2)
end
