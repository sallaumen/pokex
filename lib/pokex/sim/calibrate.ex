defmodule Pokex.Sim.Calibrate do
  @moduledoc """
  What a real night says, in the shape the simulator's knobs are written in.

  The simulator is only worth its calibration: a world I tuned by eye teaches
  what I think, not what the game does. Two numbers have been guesses since the
  first line of it, and both are answerable from a night that was actually
  hunted:

    * **`ms_per_tile`** — nobody has ever measured tiles/s in this game. The
      cavebot's `cavebot_measure_walk` (off by default) logs a line per walk
      decision carrying the POSITION, and the journal stamps every line with its
      time. Two consecutive lines are therefore a distance and a duration, and
      enough of them are a distribution.
    * **`nest_size` / `pile_settle_ms`** — how many monsters actually show up at
      a corner, and how long they take to stop arriving. `Engine.Events` files
      one typed record per decision change with `enemies` and `stable_ms`, which
      is exactly the pair those two knobs are made of.

  Nothing here guesses. A night with no walk measurements answers `nil` for the
  speed, and a night with no events answers `nil` for the pile — because
  "unknown" and "the default" are different answers, and the whole discipline of
  this simulator is refusing to confuse them.
  """

  alias Pokex.Engine.Events
  alias Pokex.Journal

  @walk_line ~r/andar \w+ de (-?\d+),(-?\d+),(-?\d+):/

  @doc """
  Everything a night can say, with the sample size next to every number.

  The counts are not decoration: three walk decisions are not a measurement of
  anything, and a reader who cannot see `n` cannot tell a fact from an accident.
  """
  @spec report(Date.t()) :: map
  def report(date \\ Date.utc_today()) do
    %{date: date, walk: walk_speed(date), pile: piles(date)}
  end

  @doc """
  Milliseconds per tile, from consecutive walk-decision lines.

  Returns `nil` when the night has fewer than `min_samples` usable pairs — a
  number computed from four hops is a rumour, not a measurement.

  Pairs are dropped when the character changed floor (a staircase is one key and
  two tiles, so it would read as impossibly fast), when the gap is longer than
  `@max_gap_ms` (the hunt was stopped, fighting, or stuck in between) or when
  nothing moved.
  """
  @max_gap_ms 3_000
  @min_samples 20

  @spec walk_speed(Date.t()) :: map | nil
  def walk_speed(date) do
    samples =
      date
      |> walk_points()
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.flat_map(&pace/1)

    if length(samples) < @min_samples, do: nil, else: summarize(samples, :ms_per_tile)
  end

  @doc """
  What the piles really looked like: how many monsters, and how long they took
  to stop arriving before the engine opened on them.

  `engaged` is the distribution that `nest_size` should reproduce; `settled_ms`
  is the one `pile_settle_ms` is guessing at today.
  """
  @spec piles(Date.t()) :: map | nil
  def piles(date) do
    decisions = Enum.filter(Events.read_day(date), &(&1["kind"] == "decision"))

    if decisions == [] do
      nil
    else
      engaged =
        for d <- decisions, d["phase"] == "engaged", is_integer(d["enemies"]), do: d["enemies"]

      settled =
        for d <- decisions,
            d["phase"] == "engaged",
            is_integer(d["stable_ms"]),
            do: d["stable_ms"]

      %{
        decisions: length(decisions),
        engaged: summarize(engaged, :enemies),
        settled_ms: summarize(settled, :stable_ms),
        skipped: Enum.count(decisions, &(&1["phase"] == "skipping")),
        engagements: length(engaged)
      }
    end
  end

  @doc """
  The measured numbers, as simulator knobs — and only the ones the night could
  actually answer.

  A knob missing from this map is a knob the night did not measure, which is the
  signal to keep the labelled guess rather than to invent a fresher one.
  """
  @spec knobs(Date.t()) :: map
  def knobs(date \\ Date.utc_today()) do
    report = report(date)

    %{}
    |> put_measured(:ms_per_tile, report.walk && round(report.walk.median))
    |> put_measured(
      :nest_size,
      report.pile && report.pile.engaged && round(report.pile.engaged.median)
    )
  end

  defp put_measured(knobs, _key, nil), do: knobs
  defp put_measured(knobs, key, value), do: Map.put(knobs, key, value)

  defp walk_points(date) do
    date
    |> journal_lines()
    |> Enum.flat_map(fn line ->
      case Regex.run(@walk_line, line["text"] || "") do
        [_all, x, y, z] ->
          [
            %{
              at: line["at"],
              pos: {String.to_integer(x), String.to_integer(y), String.to_integer(z)}
            }
          ]

        _not_a_walk_line ->
          []
      end
    end)
  end

  # A staircase is one key and two tiles, so a pair that changed floor would read
  # as twice the real speed; a long gap means the hunt was doing something else
  # in between. Both are dropped rather than smoothed.
  defp pace([%{pos: {x1, y1, z1}, at: t1}, %{pos: {x2, y2, z2}, at: t2}]) do
    tiles = max(abs(x2 - x1), abs(y2 - y1))
    elapsed = t2 - t1

    if z1 == z2 and tiles > 0 and elapsed > 0 and elapsed <= @max_gap_ms,
      do: [elapsed / tiles],
      else: []
  end

  defp summarize([], _name), do: nil

  defp summarize(values, name) do
    sorted = Enum.sort(values)
    n = length(sorted)

    %{
      of: name,
      n: n,
      min: Enum.min(sorted),
      median: Enum.at(sorted, div(n, 2)),
      max: Enum.max(sorted),
      mean: Enum.sum(sorted) / n
    }
  end

  defp journal_lines(date) do
    date
    |> journal_file()
    |> File.read()
    |> case do
      {:ok, body} ->
        body |> String.split("\n", trim: true) |> Enum.flat_map(&decode/1)

      {:error, _no_file} ->
        []
    end
  end

  defp decode(line) do
    case Jason.decode(line) do
      {:ok, entry} -> [entry]
      _unreadable -> []
    end
  end

  defp journal_file(date), do: Path.join(Journal.dir(), "#{Date.to_iso8601(date)}.jsonl")
end
