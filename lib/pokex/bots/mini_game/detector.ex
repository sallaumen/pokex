defmodule Pokex.Bots.MiniGame.Detector do
  @moduledoc """
  Conservative image detector for the fishing mini-game overlay.

  This is intentionally only a presence detector. It looks for the long dark
  vertical control bar that appears over the player's character and optionally
  boosts confidence when the bright "PRESS SPACE" prompt is visible near the top.

  Detection runs in three passes:

  1. **Anchored** — columns within `anchor_tolerance` of the calibrated player
    point, tight 8px gap budget. Normal map objects can also form dark vertical
    runs (e.g. the dock fence), and the anchor window keeps them out. The bar is
    drawn AT the character — measured (2026-07-10) ~40px to the RIGHT of the
    sprite center, so the window must be wider than the sprite (see the
    mini_game_anchor_tolerance seed).
  2. **Sweep** — when the anchored pass finds nothing, the full frame is swept
    with a sprite-sized gap budget (nameplate/sprite pixels interrupt the dark
    column when the overlay lands on the character). Sweep candidates must show
    the blue capsule INSIDE the column (measured: ~100 sampled capsule pixels on
    a real open frame vs 0 on the dock-fence frame), which is what lets it skip
    the anchor entirely — a stale/imprecise player calibration no longer blocks
    detection.
  3. **Capsule** — when even the sweep fails (measured 2026-07-20: the bar at
    the viewport's right edge merges with the dark sidebar into one block wider
    than max_width), the capsule itself is the anchor: find the blue pixels,
    then demand a bar-length dark column through them. Width plays no part, so
    dark neighbours can't disqualify the bar.

  Caveat for passes 2-3: a frame where the fish fully occludes the capsule has
  no blue evidence for that tick; the enter streak just picks the next one up.
  """

  alias Pokex.Vision.Frame

  defstruct present?: false,
            confidence: 0.0,
            bar: nil,
            prompt_score: 0

  @type t :: %__MODULE__{
          present?: boolean,
          confidence: float,
          bar: map | nil,
          prompt_score: non_neg_integer
        }

  # sweep: x stride between sampled columns (must stay under the bar's minimum
  # width), gap budget as a fraction of frame height (a 2x-scale sprite +
  # nameplate interrupts ~100-130px of a ~950px crop), and the minimum sampled
  # capsule-blue pixels a candidate must contain.
  @sweep_stride 4
  @sweep_gap_ratio 0.15
  @sweep_min_blue_px 6

  @doc "Returns a presence reading for the mini-game overlay in a captured frame."
  @spec detect(Frame.t(), keyword) :: t
  def detect(%Frame{} = frame, opts \\ []) do
    bar = find_dark_bar(frame, opts) || sweep_bar(frame, opts) || capsule_bar(frame, opts)
    prompt_score = prompt_score(frame)
    bar_confidence = if bar, do: bar.confidence, else: 0.0
    min_confidence = Keyword.get(opts, :min_confidence, 0.62)

    confidence =
      (bar_confidence + min(prompt_score / 850, 0.18))
      |> min(1.0)
      |> Float.round(3)

    %__MODULE__{
      present?: confidence >= min_confidence,
      confidence: confidence,
      bar: bar,
      prompt_score: prompt_score
    }
  end

  defp find_dark_bar(%Frame{width: w, height: h} = frame, opts) do
    step = max(Keyword.get(opts, :step, 2), 1)
    min_dark_ratio = Keyword.get(opts, :min_dark_ratio, 0.34)
    min_width = Keyword.get(opts, :min_width, max(8, round(w * 0.012)))
    max_width = Keyword.get(opts, :max_width, max(36, round(w * 0.035)))
    anchor_x = opts |> Keyword.get(:anchor_x, div(w, 2)) |> clamp(0, w - 1)
    anchor_y = Keyword.get(opts, :anchor_y)
    anchor_tolerance = Keyword.get(opts, :anchor_tolerance, max(20, round(w * 0.04)))
    anchor_y_tolerance = Keyword.get(opts, :anchor_y_tolerance, max(28, round(h * 0.06)))
    max_gap = max(Kernel.round(Keyword.get(opts, :max_gap_px, 8) / step), 0)
    left = max(anchor_x - anchor_tolerance, 0)
    right = min(anchor_x + anchor_tolerance, w - 1)
    min_dark = round(h * min_dark_ratio / step)

    columns =
      for x <- left..right//step do
        {x, dark_column_run(frame, x, step, max_gap)}
      end

    columns
    |> Enum.chunk_by(fn {_x, run} -> run.score >= min_dark end)
    |> Enum.filter(fn [{_x, run} | _] -> run.score >= min_dark end)
    |> Enum.map(&bar_candidate(&1, step, step, h, min_dark_ratio, :anchor))
    |> Enum.filter(fn candidate ->
      candidate.width >= min_width and candidate.width <= max_width and
        abs(candidate.x - anchor_x) <= anchor_tolerance and
        crosses_anchor_y?(candidate, anchor_y, anchor_y_tolerance)
    end)
    |> Enum.max_by(& &1.confidence, fn -> nil end)
  end

  defp sweep_bar(%Frame{width: w, height: h} = frame, opts) do
    step = max(Keyword.get(opts, :step, 2), 1)
    stride = max(step, @sweep_stride)
    min_dark_ratio = Keyword.get(opts, :min_dark_ratio, 0.34)
    min_width = Keyword.get(opts, :min_width, max(8, round(w * 0.012)))
    max_width = Keyword.get(opts, :max_width, max(36, round(w * 0.035)))
    max_gap = max(round(h * @sweep_gap_ratio / step), 1)
    min_dark = round(h * min_dark_ratio / step)

    columns =
      for x <- 0..(w - 1)//stride do
        {x, dark_column_run(frame, x, step, max_gap)}
      end

    columns
    |> Enum.chunk_by(fn {_x, run} -> run.score >= min_dark end)
    |> Enum.filter(fn [{_x, run} | _] -> run.score >= min_dark end)
    |> Enum.map(&bar_candidate(&1, stride, step, h, min_dark_ratio, :sweep))
    |> Enum.filter(fn candidate ->
      candidate.width >= min_width and candidate.width <= max_width and
        capsule_evidence?(frame, candidate)
    end)
    |> Enum.max_by(& &1.confidence, fn -> nil end)
  end

  defp bar_candidate(run, x_step, y_step, height, min_dark_ratio, via) do
    {{left, _}, {right, _}} = {List.first(run), List.last(run)}
    {_x, best_run} = Enum.max_by(run, fn {_x, column_run} -> column_run.score end)
    dark_ratio = best_run.score * y_step / height

    %{
      x: div(left + right, 2),
      width: right - left + x_step,
      y1: best_run.start,
      y2: best_run.stop,
      height: max(best_run.stop - best_run.start + y_step, 0),
      dark_ratio: dark_ratio,
      confidence: bar_confidence(dark_ratio, min_dark_ratio),
      via: via
    }
  end

  defp capsule_evidence?(%Frame{width: w} = frame, candidate) do
    half = div(candidate.width, 2)
    x1 = max(candidate.x - half, 0)
    x2 = min(candidate.x + half, w - 1)

    blue =
      for x <- x1..x2//2, y <- candidate.y1..candidate.y2//2, reduce: 0 do
        acc -> if capsule_pixel?(Frame.at(frame, x, y)), do: acc + 1, else: acc
      end

    blue >= @sweep_min_blue_px
  end

  # Last-resort pass: the capsule IS the anchor. Median-x of the capsule-blue
  # pixels names the bar's column; a bar-length dark run through it (sweep gap
  # budget — the capsule itself interrupts the dark) confirms. Width is only
  # measured (bounded by max_width), never used to reject — this is what
  # survives the bar sitting flush against the dark sidebar.
  defp capsule_bar(%Frame{width: w, height: h} = frame, opts) do
    step = max(Keyword.get(opts, :step, 2), 1)
    min_dark_ratio = Keyword.get(opts, :min_dark_ratio, 0.34)
    max_width = Keyword.get(opts, :max_width, max(36, round(w * 0.035)))
    min_dark = round(h * min_dark_ratio / step)
    max_gap = max(round(h * @sweep_gap_ratio / step), 1)

    blue_xs =
      for x <- 0..(w - 1)//2,
          y <- 0..(h - 1)//2,
          capsule_pixel?(Frame.at(frame, x, y)),
          do: x

    with true <- length(blue_xs) >= @sweep_min_blue_px,
         cx = blue_xs |> Enum.sort() |> Enum.at(div(length(blue_xs), 2)),
         run = dark_column_run(frame, cx, step, max_gap),
         true <- run.score >= min_dark do
      half = div(max_width, 2)
      left = grow_dark(frame, cx, -1, max(cx - half, 0), step, max_gap, min_dark)
      right = grow_dark(frame, cx, 1, min(cx + half, w - 1), step, max_gap, min_dark)
      dark_ratio = min(run.score * step / h, 1.0)

      %{
        x: div(left + right, 2),
        width: right - left + 1,
        y1: run.start,
        y2: run.stop,
        height: max(run.stop - run.start + step, 0),
        dark_ratio: dark_ratio,
        confidence: bar_confidence(dark_ratio, min_dark_ratio),
        via: :capsule
      }
    else
      _no_capsule_or_no_bar -> nil
    end
  end

  # Widen from the capsule column while neighbours still carry a bar-length
  # dark run, up to `limit`.
  defp grow_dark(frame, x, dir, limit, step, max_gap, min_dark) do
    next = x + dir
    within? = if dir < 0, do: next >= limit, else: next <= limit

    if within? and dark_column_run(frame, next, step, max_gap).score >= min_dark do
      grow_dark(frame, next, dir, limit, step, max_gap, min_dark)
    else
      x
    end
  end

  # The capsule's saturated blue. b >= 225 keeps open WATER out (measured
  # 2026-07-20: water tops out around {0, 86, 180}; the capsule reads
  # {0, 164, 255} live and >= 235 in every fixture).
  defp capsule_pixel?({r, g, b}), do: b >= 225 and b >= g + 60 and r <= 80

  defp bar_confidence(dark_ratio, min_dark_ratio) do
    # The real overlay bar occupies roughly 45-55% of the arena crop, not the
    # whole frame. Once a column run clears the minimum length gate, normalize
    # confidence against that gate instead of raw full-frame height.
    scaled = (dark_ratio - min_dark_ratio) / max(1.0 - min_dark_ratio, 0.01)
    (0.56 + scaled * 0.44) |> max(0.0) |> min(1.0)
  end

  # One row of the column scan: a dark pixel extends the current run (and may
  # beat the best one), a light pixel either bridges a gap or ends the run.
  defp column_step({best, b_start, b_stop, current, c_start, gap, _last_y}, true, y, _max_gap) do
    c_start = if current == 0, do: y, else: c_start
    current = current + gap + 1

    if current > best,
      do: {current, c_start, y, current, c_start, 0, y},
      else: {best, b_start, b_stop, current, c_start, 0, y}
  end

  defp column_step({best, b_start, b_stop, current, c_start, gap, last_y}, false, _y, max_gap) do
    cond do
      current == 0 -> {best, b_start, b_stop, 0, 0, 0, last_y}
      gap < max_gap -> {best, b_start, b_stop, current, c_start, gap + 1, last_y}
      true -> {best, b_start, b_stop, 0, 0, 0, last_y}
    end
  end

  defp crosses_anchor_y?(_candidate, nil, _tolerance), do: true

  defp crosses_anchor_y?(candidate, anchor_y, tolerance) do
    candidate.y1 <= anchor_y + tolerance and candidate.y2 >= anchor_y - tolerance
  end

  defp dark_column_run(%Frame{height: h} = frame, x, step, max_gap) do
    {best, best_start, best_stop, _current, _current_start, _gap, _last_dark_y} =
      for y <- 0..(h - 1)//step, reduce: {0, 0, 0, 0, 0, 0, 0} do
        acc -> column_step(acc, dark_pixel?(frame, x, y), y, max_gap)
      end

    %{score: best, start: best_start, stop: best_stop}
  end

  defp dark_pixel?(frame, x, y) do
    {r, g, b} = Frame.at(frame, x, y)
    max(r, max(g, b)) <= 82 and b >= r - 8 and g >= r - 16
  end

  defp clamp(value, min, max), do: value |> Kernel.max(min) |> Kernel.min(max)

  defp prompt_score(%Frame{width: w, height: h} = frame) do
    top_h = max(1, round(h * 0.22))

    for y <- 0..(top_h - 1)//3, x <- 0..(w - 1)//3, reduce: 0 do
      acc ->
        {r, g, b} = Frame.at(frame, x, y)

        cond do
          r >= 210 and g >= 210 and b >= 190 -> acc + 1
          g >= 150 and g > r + 25 and g > b + 10 -> acc + 1
          true -> acc
        end
    end
  end
end
