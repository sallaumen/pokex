defmodule Pokex.Bots.MiniGame.Track do
  @moduledoc """
  Reads the mini-game track column: where is the FISH (target) and where is the
  player's BLUE capsule, normalized 0..1 over the track's vertical bounds.

  The column (from the Detector's bar candidate) contains more than the track:
  floor above/below it, and sometimes dark clutter (bench shadows) further out.
  Bounds therefore anchor on the LONGEST dark row-run and extend across
  interruptions: blue rows (the capsule) always extend; fish rows extend only
  when dark/blue resumes within a budget; a resumed dark run must be
  substantial, so nearby dark clutter across a floor gap can't stretch the
  bounds. Measured on the real frame (2026-07-10): track rows 235..696 with the
  capsule split 636..641 + 675..696 around the fish 642..673 — the fish draws
  OVER the capsule, so full occlusion of the blue means the capsule IS at the
  fish (the success state): `bar_y = fish_y`.
  """

  alias Pokex.Vision.Frame

  @column_margin 2
  @min_track_rows 60
  # fish (~32 rows) + capsule sliver interruptions, with margin
  @max_interrupt_rows 45
  @min_dark_resume_rows 10
  @min_fish_rows 4

  @spec read(Frame.t(), %{:x => integer, :width => integer, optional(any) => any}) ::
          {:ok, %{fish_y: float, bar_y: float, bar_source: :blue | :fish}}
          | {:error, :no_track | :no_fish}
  def read(%Frame{} = frame, bar), do: frame |> read_diag(bar) |> elem(0)

  @typedoc """
  What the read SAW, beside what it concluded: the sampled column, the bounds
  it settled on, the fish rows it elected and the raw pixel evidence behind the
  row classification. `read/2` never needed any of it — a bad game is
  unexplainable without it.
  """
  @type stats :: %{
          column: {integer, integer},
          rows: non_neg_integer,
          dark_px: non_neg_integer,
          blue_px: non_neg_integer,
          dark_rows: non_neg_integer,
          blue_rows: non_neg_integer,
          other_rows: non_neg_integer,
          track_at_edge?: boolean,
          top: integer | nil,
          bottom: integer | nil,
          fish_rows: {integer, integer} | nil
        }

  @doc """
  `read/2` plus the evidence. ONE reading path for both, so a diagnostic report
  can never describe a different read than the one that flew the capsule.
  """
  @spec read_diag(Frame.t(), %{:x => integer, :width => integer, optional(any) => any}) ::
          {{:ok, %{fish_y: float, bar_y: float, bar_source: :blue | :fish}}
           | {:error, :no_track | :no_fish}, stats}
  def read_diag(%Frame{} = frame, %{x: x, width: width}) do
    half = div(width, 2) + @column_margin
    left = clamp_int(x - half, 0, frame.width - 1)
    right = clamp_int(x + half, 0, frame.width - 1)
    {rows, pixels} = row_classes(frame, left, right)
    classes = List.to_tuple(rows)
    stats = base_stats(rows, pixels, {left, right})

    case longest_dark_run(classes) do
      nil ->
        {{:error, :no_track}, stats}

      {run_top, run_bottom} ->
        top = extend(classes, run_top, -1)
        bottom = extend(classes, run_bottom, +1)
        {result, fish_rows} = read_bounds(classes, top, bottom)
        {result, %{stats | top: top, bottom: bottom, fish_rows: fish_rows}}
    end
  end

  defp base_stats(rows, pixels, column) do
    counts = Enum.frequencies(rows)

    %{
      column: column,
      rows: length(rows),
      dark_px: pixels.dark,
      blue_px: pixels.blue,
      dark_rows: Map.get(counts, :dark, 0),
      blue_rows: Map.get(counts, :blue, 0),
      other_rows: Map.get(counts, :other, 0),
      # The track touching the LAST row means it had nowhere left to go, not
      # that it ended there: the strip is cutting it, and everything below the
      # cut (fish, capsule) is invisible to every reader downstream.
      track_at_edge?: List.last(rows) in [:dark, :blue],
      top: nil,
      bottom: nil,
      fish_rows: nil
    }
  end

  defp read_bounds(classes, top, bottom) do
    case largest_other_run(classes, top, bottom) || edge_fish_run(classes, top, bottom) do
      nil ->
        {{:error, :no_fish}, nil}

      {fish_top, fish_bottom} = fish_rows ->
        span = max(bottom - top, 1)
        fish_y = clamp_float(((fish_top + fish_bottom) / 2 - top) / span)

        case blue_mean(classes, top, bottom) do
          nil ->
            # Fish drawn OVER the capsule: full occlusion = the success state.
            {{:ok, %{fish_y: fish_y, bar_y: fish_y, bar_source: :fish}}, fish_rows}

          mean ->
            {{:ok, %{fish_y: fish_y, bar_y: clamp_float((mean - top) / span), bar_source: :blue}},
             fish_rows}
        end
    end
  end

  # A fish pegged at a track END can fall OUTSIDE the bounds: fewer than
  # @min_dark_resume_rows of track remain beyond it, so the extension never
  # commits across it. Look just past each edge for a fish-SIZED other-run
  # (the floor is other-classified too, but floor runs are far larger than a
  # fish) and clamp it to the edge — releasing there would drop the capsule
  # exactly when the fish demands the extreme.
  #
  # BOTH edges can hold a candidate at once (live traces, 2026-07-20: the real
  # fish pegged at the BOTTOM while bounded clutter sat past the TOP edge —
  # the old top-first order elected the clutter, the reading snapped to 0.0
  # and the capsule flew to the track top). The fish sprite is the larger
  # blob: the LONGER run wins.
  defp edge_fish_run(classes, top, bottom) do
    [edge_run(classes, top, -1), edge_run(classes, bottom, +1)]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      candidates -> candidates |> Enum.max_by(fn {run, _collapsed} -> run end) |> elem(1)
    end
  end

  defp edge_run(classes, edge, step) do
    start = first_other(classes, edge + step, step, @min_dark_resume_rows + 2)

    with y when y != nil <- start,
         run = run_length(classes, y, step, :other),
         true <- run >= @min_fish_rows and run <= @max_interrupt_rows,
         # a fish is a BOUNDED blob: dark/blue must terminate the run — a
         # frame-edge-truncated floor sliver is not a fish
         beyond = y + step * run,
         true <- beyond >= 0 and beyond < tuple_size(classes),
         true <- elem(classes, beyond) in [:dark, :blue] do
      # collapse to the edge row: the target IS the extreme
      {run, {edge, edge}}
    else
      _miss -> nil
    end
  end

  defp first_other(_classes, _y, _step, 0), do: nil

  defp first_other(classes, y, step, budget) do
    cond do
      y < 0 or y >= tuple_size(classes) -> nil
      elem(classes, y) == :other -> y
      true -> first_other(classes, y + step, step, budget - 1)
    end
  end

  # -- row classification -----------------------------------------------------

  # Returns the per-row classes AND the pixel tallies behind them: the counts
  # are free here (already summed per row) and they are the only way to tell a
  # "no blue anywhere" frame from a "blue just below the row threshold" one.
  defp row_classes(frame, left, right) do
    ncols = right - left + 1

    Enum.map_reduce(0..(frame.height - 1), %{dark: 0, blue: 0}, fn y, totals ->
      {dark, blue} =
        Enum.reduce(left..right, {0, 0}, fn x, acc -> tally(acc, Frame.at(frame, x, y)) end)

      class =
        cond do
          blue * 2 >= ncols -> :blue
          dark * 2 >= ncols -> :dark
          true -> :other
        end

      {class, %{totals | dark: totals.dark + dark, blue: totals.blue + blue}}
    end)
  end

  # The Detector's dark predicate, duplicated on purpose — the modules stay
  # decoupled and this one is pinned by the same real-frame fixture.
  defp tally({dark, blue}, pixel) do
    cond do
      dark_pixel?(pixel) -> {dark + 1, blue}
      blue_pixel?(pixel) -> {dark, blue + 1}
      true -> {dark, blue}
    end
  end

  defp dark_pixel?({r, g, b}), do: max(r, max(g, b)) <= 82 and b >= r - 8 and g >= r - 16

  defp blue_pixel?({r, g, b}), do: b >= 200 and b >= g + 60 and r <= 80

  # -- bounds -----------------------------------------------------------------

  defp longest_dark_run(classes) do
    size = tuple_size(classes)

    {best, _current} =
      Enum.reduce(0..(size - 1), {nil, nil}, fn y, {best, current} ->
        if elem(classes, y) == :dark do
          {start, _} = current || {y, y}
          current = {start, y}
          {better_run(best, current), current}
        else
          {best, nil}
        end
      end)

    case best do
      {top, bottom} when bottom - top + 1 >= @min_track_rows -> {top, bottom}
      _short -> nil
    end
  end

  defp better_run(nil, candidate), do: candidate

  defp better_run({bt, bb} = best, {ct, cb} = candidate),
    do: if(cb - ct > bb - bt, do: candidate, else: best)

  # Walk outward from a committed row. Blue rows always commit (the capsule is
  # unambiguous); a resumed dark run commits only when it is substantial —
  # small dark islands across a floor gap are clutter, not track.
  defp extend(classes, committed, step),
    do: advance(classes, committed + step, committed, 0, step)

  defp advance(classes, y, committed, gap, step) do
    cond do
      y < 0 or y >= tuple_size(classes) or gap > @max_interrupt_rows ->
        committed

      elem(classes, y) == :blue ->
        advance(classes, y + step, y, 0, step)

      elem(classes, y) == :dark ->
        run = run_length(classes, y, step, :dark)

        if run >= @min_dark_resume_rows do
          landed = y + step * (run - 1)
          advance(classes, landed + step, landed, 0, step)
        else
          advance(classes, y + step * run, committed, gap + run, step)
        end

      true ->
        advance(classes, y + step, committed, gap + 1, step)
    end
  end

  defp run_length(classes, y, step, class) do
    if y < 0 or y >= tuple_size(classes) or elem(classes, y) != class,
      do: 0,
      else: 1 + run_length(classes, y + step, step, class)
  end

  # -- contents ---------------------------------------------------------------

  defp largest_other_run(classes, top, bottom) do
    {best, _current} =
      Enum.reduce(top..bottom, {nil, nil}, fn y, {best, current} ->
        if elem(classes, y) == :other do
          {start, _} = current || {y, y}
          current = {start, y}
          {better_run(best, current), current}
        else
          {best, nil}
        end
      end)

    case best do
      {ft, fb} when fb - ft + 1 >= @min_fish_rows -> {ft, fb}
      _small -> nil
    end
  end

  defp blue_mean(classes, top, bottom) do
    {sum, count} =
      Enum.reduce(top..bottom, {0, 0}, fn y, {sum, count} ->
        if elem(classes, y) == :blue, do: {sum + y, count + 1}, else: {sum, count}
      end)

    if count > 0, do: sum / count
  end

  defp clamp_int(value, min, max), do: value |> Kernel.max(min) |> Kernel.min(max)
  defp clamp_float(value), do: value |> Kernel.max(0.0) |> Kernel.min(1.0)
end
