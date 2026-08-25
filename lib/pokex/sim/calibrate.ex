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

  ## The four the placar was still missing (2026-08-25)

  `Pokex.Sim.Score` can compare two brains exactly, and could not say a single
  ABSOLUTE number, because the damage model underneath it was invented. Four
  measurements close that, and all four come out of the same `vitals` stream the
  engine now files (`Engine.Worker.sample_vitals/4`) plus one line per key burst:

    * **`bite`** — how fast health falls per monster on screen. `bite_dmg` and
      `bite_every_ms` are a single rate, and the rate is what a night can answer.
    * **`kill`** — how many presses and how many seconds one monster costs. With
      `mob_hp` fixed at 100, presses-per-kill IS the damage per press.
    * **`revive_settle`** — how long F4 leaves the pokemon in the ball: the gap
      between the bar going away and coming back.
    * **`revive_reset`** — whether it comes back with the cooldowns cleared,
      which is the whole premise of R3b and a fact about the GAME that no amount
      of code can settle.

  Nothing here guesses. A night with no walk measurements answers `nil` for the
  speed, and a night with no events answers `nil` for the pile — because
  "unknown" and "the default" are different answers, and the whole discipline of
  this simulator is refusing to confuse them. The same rule holds for the four:
  each carries its own `n`, and a night that did not produce one answers `nil`
  rather than a number computed from two samples.
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
    events = Events.read_day(date)
    vitals = Enum.filter(events, &(&1["kind"] == "vitals"))

    %{
      date: date,
      walk: walk_speed(date),
      pile: piles(date),
      bite: bite(vitals),
      kill: kill(vitals, events),
      revive_settle: revive_settle(vitals),
      revive_reset: revive_reset(vitals),
      vitals: length(vitals)
    }
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

  # --- the four, from the vitals stream ---------------------------------------

  # A window between two readings is usable only when both saw the same world:
  # the pokemon on the field in both (health means nothing while it is in the
  # ball), health readable in both, and not so long a gap that the hunt was
  # doing something else in between.
  @max_window_ms 3_000
  @min_bite_samples 15

  @doc """
  How fast health falls, per monster on screen, in percent per second.

  Only DROPS count: a potion, a revive and a swap all move the bar the other
  way, and folding them in would report a hunt that heals itself. Attributed
  per enemy because that is the shape the knob has — one monster biting is the
  unit, and a pile of four is four of them.
  """
  @spec bite([map]) :: map | nil
  def bite(vitals) do
    samples =
      vitals
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.flat_map(&bite_sample/1)

    if length(samples) < @min_bite_samples,
      do: nil,
      else: summarize(samples, :pct_per_s_per_enemy)
  end

  defp bite_sample([a, b]) do
    elapsed = (b["at"] || 0) - (a["at"] || 0)
    enemies = a["enemies"]
    drop = (a["hp"] || 0) - (b["hp"] || 0)

    if usable_window?(a, b, elapsed) and is_integer(enemies) and enemies > 0 and drop > 0,
      do: [drop * 1_000 / (elapsed * enemies)],
      else: []
  end

  defp usable_window?(a, b, elapsed) do
    a["out"] == true and b["out"] == true and is_integer(a["hp"]) and is_integer(b["hp"]) and
      elapsed > 0 and elapsed <= @max_window_ms
  end

  @doc """
  What one monster costs: presses and milliseconds.

  A kill is the battle list SHRINKING while the hunt is standing on it
  (`route: :hold`, i.e. an engaged phase) — walking away shrinks the list too,
  and that one is a monster lost, not killed. Aggregate on purpose: matching
  one press to one corpse needs a receipt the game does not give, but a whole
  session of presses over a whole session of corpses is a ratio, and a ratio is
  what `mob_hp` versus damage per key actually is.
  """
  @fight_phases ~w(engaged closing emergency)
  @spec kill([map], [map]) :: map | nil
  def kill(vitals, events) do
    fights = fight_windows(vitals)
    kills = Enum.sum(Enum.map(fights, & &1.killed))

    if kills == 0 do
      nil
    else
      presses = presses_in(events, fights)
      ms = Enum.sum(Enum.map(fights, & &1.ms))

      %{
        n: kills,
        presses: presses,
        presses_per_kill: Float.round(presses / kills, 2),
        ms_per_kill: round(ms / kills),
        fighting_ms: ms
      }
    end
  end

  # Consecutive readings taken while a fight was open, each carrying how much
  # the list shrank across it and how long it lasted.
  defp fight_windows(vitals) do
    vitals
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [a, b] ->
      elapsed = (b["at"] || 0) - (a["at"] || 0)
      shrank = (a["enemies"] || 0) - (b["enemies"] || 0)

      if a["phase"] in @fight_phases and is_integer(a["enemies"]) and is_integer(b["enemies"]) and
           elapsed > 0 and elapsed <= @max_window_ms,
         do: [%{from: a["at"], to: b["at"], killed: max(shrank, 0), ms: elapsed}],
         else: []
    end)
  end

  defp presses_in(events, fights) do
    for %{"kind" => "press"} = press <- events,
        Enum.any?(fights, &(press["at"] >= &1.from and press["at"] <= &1.to)),
        reduce: 0 do
      total -> total + (press["n"] || 1)
    end
  end

  @doc """
  How long F4 leaves the pokemon in the ball.

  Measured from the bar going away to the bar coming back — the two moments the
  vitals stream writes the instant they happen, so the resolution is the
  engine's tick and not the heartbeat. A gap longer than `@max_down_ms` is not a
  settle, it is a revive that did not land, and it is excluded rather than
  averaged in (that failure has its own name: `:dead_revive`).
  """
  @max_down_ms 15_000
  @spec revive_settle([map]) :: map | nil
  def revive_settle(vitals) do
    samples =
      vitals
      |> down_windows()
      |> Enum.filter(&(&1 <= @max_down_ms))

    if samples == [], do: nil, else: summarize(samples, :ms)
  end

  # Every stretch with the pokemon off the field, as {went_at, came_back_at}.
  defp down_windows(vitals), do: Enum.map(down_pairs(vitals), fn {a, b} -> b["at"] - a["at"] end)

  # OFF the field is anything that is not `true`. The reading has three answers
  # since the engine gained a rule that refuses to fight without a body out, and
  # only a fall proven by the support answers `false` — a HEALTHY recall (which
  # is exactly the press R3b is about) leaves the bar unreadable and answers
  # `:unknown`. Pairing on `== false` would have measured the price of every
  # revive except the one being asked about.
  defp down_pairs(vitals) do
    vitals
    |> Enum.reduce({nil, []}, fn reading, {went, pairs} ->
      cond do
        went == nil and reading["out"] != true -> {reading, pairs}
        went != nil and reading["out"] == true -> {nil, [{went, reading} | pairs]}
        true -> {went, pairs}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  @doc """
  Does the pokemon come back with its cooldowns cleared?

  THE premise of R3b, and a fact about the game rather than about this code. It
  compares the last readable count of ready damage keys before the bar went away
  with the first one after it came back: a jump to every key ready is a reset,
  anything less is not. Both counts have to be readable, and the pokemon has to
  have had keys spent before it left — a bar that was already full proves
  nothing either way.
  """
  @spec revive_reset([map]) :: map | nil
  def revive_reset(vitals) do
    verdicts =
      vitals
      |> down_pairs()
      |> Enum.flat_map(&reset_verdict(vitals, &1))

    if verdicts == [] do
      nil
    else
      %{
        n: length(verdicts),
        resets: Enum.count(verdicts, & &1),
        kept: Enum.count(verdicts, &(not &1))
      }
    end
  end

  defp reset_verdict(vitals, {went, back}) do
    with %{"ready" => before_ready, "keys" => keys} when is_integer(before_ready) <-
           last_readable_before(vitals, went),
         %{"ready" => after_ready} when is_integer(after_ready) <-
           first_readable_after(vitals, back),
         true <- keys > 0 and before_ready < keys do
      [after_ready >= keys]
    else
      _cannot_tell -> []
    end
  end

  defp last_readable_before(vitals, went) do
    vitals
    |> Enum.filter(&(&1["at"] <= went["at"] and &1["out"] == true and is_integer(&1["ready"])))
    |> List.last()
  end

  defp first_readable_after(vitals, back) do
    Enum.find(
      vitals,
      &(&1["at"] >= back["at"] and &1["out"] == true and is_integer(&1["ready"]))
    )
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
    |> Map.merge(bite_knobs(report.bite))
    |> Map.merge(damage_knobs(report.kill))
    |> put_measured(:revive_settle_ms, report.revive_settle && round(report.revive_settle.median))
  end

  # The measured rate is percent-of-health per second per monster; the world
  # spends it as a bite of `bite_dmg` every `bite_every_ms`. One rate, two
  # knobs, so the cadence is FIXED at what the game feels like (a bite a second)
  # and the size carries the measurement. Inventing a second number out of one
  # measurement is how a measured knob turns back into a guess.
  @bite_cadence_ms 1_000
  defp bite_knobs(nil), do: %{}

  defp bite_knobs(bite) do
    %{
      bite_dmg: max(round(bite.median * @bite_cadence_ms / 1_000), 1),
      bite_every_ms: @bite_cadence_ms
    }
  end

  # `mob_hp` is 100 by definition — the unit the whole damage model is written
  # in — so "how many presses kill one" IS the damage per press, and the two
  # families (area and single) start from the same measurement until a night
  # can tell them apart.
  defp damage_knobs(nil), do: %{}

  defp damage_knobs(%{presses_per_kill: per_kill}) when per_kill > 0 do
    per_press = max(round(100 / per_kill), 1)
    %{single_damage_pct: per_press, aoe_damage_pct: per_press}
  end

  defp damage_knobs(_no_presses), do: %{}

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
