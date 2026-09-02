defmodule Pokex.Vision do
  @moduledoc "Pure pixel analysis over Frames. No I/O here, ever."

  alias Pokex.Vision.Frame
  alias Pokex.Vision.SkillDigits

  def distance(%Frame{rgba: a}, %Frame{rgba: b}) when byte_size(a) == byte_size(b) do
    sum_abs_diff(a, b, 0, 0)
  end

  def glow_score(current, baselines) when baselines != [] do
    baselines |> Enum.map(&distance(current, &1)) |> Enum.min()
  end

  def glow?(current, baselines, threshold), do: glow_score(current, baselines) > threshold

  def suggested_threshold(baselines) do
    pairs = for a <- baselines, b <- baselines, a != b, do: distance(a, b)
    natural = if pairs == [], do: 0.0, else: Enum.max(pairs)
    max(natural * 1.5, 12.0)
  end

  defp sum_abs_diff(
         <<r1, g1, b1, _::8, rest1::binary>>,
         <<r2, g2, b2, _::8, rest2::binary>>,
         n,
         acc
       ) do
    sum_abs_diff(rest1, rest2, n + 1, acc + abs(r1 - r2) + abs(g1 - g2) + abs(b1 - b2))
  end

  defp sum_abs_diff(<<>>, <<>>, n, acc), do: acc / (3 * n)

  # A pixel counts as "vivid" (part of a live coloured icon, not the grey cooldown overlay
  # or its white number) when it is both strongly saturated and not near-black.
  @vivid_sat 60
  @vivid_bright 60

  @doc """
  Whether a captured frame IS the skill bar: at least two thirds of its `count`
  slots carry a glyph of the game's font — the hotkey label under every slot,
  or the countdown over a cooling one (`Pokex.Vision.SkillDigits.labelled_slots/2`).

  It used to ask for 10% of near-black pixels plus 1% of vivid/white ones. The
  "dark chrome" that share was counting is the dark PART OF THE ICONS, not a
  frame around the bar: his three August bars measured 10.9-11.6%, and the
  bar he calibrated on 2026-09-02 — a tight, correct crop of nine slots —
  measured 9.6%. Giving the crop slack makes it worse (9.5%): the bar sits on
  a light panel. So a perfect calibration read as "not the bar" on every tick
  of every hunt that day (755 "a barra está ilegível" lines), and each revive
  waited the full unverifiable deadline standing still. The label is what the
  game always draws; the share of dark paint is whatever the icons happen to be.
  """
  @spec skill_bar_frame?(Frame.t(), pos_integer) :: boolean
  def skill_bar_frame?(%Frame{} = frame, count) when is_integer(count) and count > 0 do
    labelled = SkillDigits.labelled_slots(frame, count)

    MapSet.size(labelled) * 3 >= count * 2
  end

  @doc """
  Locates the hostile creature inside the given frame by clustering pure-red
  pixels (the floating red name text). Species-agnostic. Returns frame PIXELS.
  """
  def find_hostile(%Frame{} = frame, opts \\ []) do
    min_r = Keyword.get(opts, :min_r, 180)
    max_g = Keyword.get(opts, :max_g, 80)
    max_b = Keyword.get(opts, :max_b, 80)
    min_pixels = Keyword.get(opts, :min_pixels, 8)

    reds = red_pixels(frame.rgba, 0, frame.width, min_r, max_g, max_b, [])

    if length(reds) < min_pixels do
      :not_found
    else
      {best_bucket, _count} =
        reds
        |> Enum.frequencies_by(fn {x, y} -> {div(x, 16), div(y, 16)} end)
        |> Enum.max_by(fn {_bucket, count} -> count end)

      {bx, by} = best_bucket

      cluster =
        Enum.filter(reds, fn {x, y} ->
          abs(div(x, 16) - bx) <= 1 and abs(div(y, 16) - by) <= 1
        end)

      count = length(cluster)
      {sum_x, sum_y} = Enum.reduce(cluster, {0, 0}, fn {x, y}, {ax, ay} -> {ax + x, ay + y} end)
      {:ok, {div(sum_x, count), div(sum_y, count)}}
    end
  end

  defp red_pixels(<<r, g, b, _a, rest::binary>>, index, width, min_r, max_g, max_b, acc) do
    acc =
      if r >= min_r and g <= max_g and b <= max_b,
        do: [{rem(index, width), div(index, width)} | acc],
        else: acc

    red_pixels(rest, index + 1, width, min_r, max_g, max_b, acc)
  end

  defp red_pixels(<<>>, _index, _width, _min_r, _max_g, _max_b, acc), do: acc

  @doc """
  Counts the TEAL "bite" bubble pixels around the bait, by HUE not brightness so
  it works day and night. A bubble is teal: green and blue both above red AND
  green not far below blue. Normal map glints in the example screenshot can be
  bright but skew too blue, so the `10*g >= 7*b` (green >= 0.70*blue) ratio keeps
  those out while cyan bubbles pass. `min_sum` floors out near-black sensor noise.
  """
  def bubble_count(%Frame{rgba: rgba}, opts \\ []) do
    min_sum = Keyword.get(opts, :min_sum, 60)
    teal_pixels(rgba, min_sum, 0)
  end

  defp teal_pixels(<<r, g, b, _a, rest::binary>>, min_sum, n) do
    n = if bubble_pixel?(r, g, b, min_sum), do: n + 1, else: n
    teal_pixels(rest, min_sum, n)
  end

  defp teal_pixels(<<>>, _min_sum, n), do: n

  defp bubble_pixel?(r, g, b, min_sum) do
    r <= 80 and g >= 115 and b >= 150 and g > r + 45 and b > r + 70 and
      10 * g >= 7 * b and g + b >= min_sum
  end

  @doc """
  Fishing-specific reading for the expanded water search region.

  A large water crop is intentionally tolerant to calibration drift, but it also
  includes random map glints. To avoid treating those glints as a live line or a
  bite, first locate the red/orange lure pixels, then count cyan pixels only near
  that lure. If no lure is found, the signal is empty even if the water texture
  contains cyan highlights.
  """
  def fishing_signal(%Frame{} = frame, opts \\ []) do
    min_lure_pixels = Keyword.get(opts, :min_lure_pixels, 20)
    radius = Keyword.get(opts, :bubble_radius_px, 48)
    line_present_min = Keyword.get(opts, :line_present_min_px, 100)

    case lure_center(frame, opts) do
      {:ok, center, lure_count} ->
        bubble_count = bubble_count_near(frame, center, radius, opts)

        %{
          bubble_count: bubble_count,
          lure_count: lure_count,
          line_present?: lure_count >= min_lure_pixels and bubble_count >= line_present_min
        }

      :none ->
        %{bubble_count: 0, lure_count: 0, line_present?: false}
    end
  end

  defp lure_center(%Frame{width: width, height: height, rgba: rgba} = frame, opts) do
    bucket_px = Keyword.get(opts, :lure_bucket_px, 16)
    min_bucket_pixels = Keyword.get(opts, :lure_candidate_min_pixels, 5)

    candidates =
      rgba
      |> lure_buckets(0, width, bucket_px, %{})
      |> Map.values()
      |> Enum.filter(&(&1.count >= min_bucket_pixels))

    case select_lure_candidate(candidates, frame, opts) do
      candidate when not is_nil(candidate) ->
        center = {div(candidate.sum_x, candidate.count), div(candidate.sum_y, candidate.count)}

        radius =
          Keyword.get(opts, :lure_cluster_radius_px, max(18, bucket_px + div(bucket_px, 2)))

        count = lure_count_near(frame, center, radius)

        if count > 0 do
          {:ok, center, count}
        else
          :none
        end

      _ ->
        fallback_lure_center(rgba, width, height)
    end
  end

  defp select_lure_candidate([], _frame, _opts), do: nil

  defp select_lure_candidate(candidates, frame, opts) do
    expected = Keyword.get(opts, :expected_center)
    max_distance = Keyword.get(opts, :max_lure_distance_px, max(frame.width, frame.height))
    radius = Keyword.get(opts, :bubble_radius_px, 48)

    candidates
    |> Enum.filter(fn candidate ->
      expected == nil or candidate_distance(candidate, expected) <= max_distance
    end)
    |> Enum.max_by(
      fn candidate ->
        center = {div(candidate.sum_x, candidate.count), div(candidate.sum_y, candidate.count)}
        bubbles = bubble_count_near(frame, center, radius, opts)

        distance_penalty =
          if expected, do: candidate_distance(candidate, expected) * 0.35, else: 0

        bubbles * 4 + min(candidate.count, 64) - distance_penalty
      end,
      fn -> nil end
    )
  end

  defp candidate_distance(candidate, {ex, ey}) do
    cx = candidate.sum_x / candidate.count
    cy = candidate.sum_y / candidate.count
    :math.sqrt(:math.pow(cx - ex, 2) + :math.pow(cy - ey, 2))
  end

  defp lure_buckets(<<r, g, b, _a, rest::binary>>, index, width, bucket_px, acc) do
    acc =
      if lure_pixel?(r, g, b) do
        x = rem(index, width)
        y = div(index, width)
        key = {div(x, bucket_px), div(y, bucket_px)}

        Map.update(acc, key, %{count: 1, sum_x: x, sum_y: y}, fn bucket ->
          %{bucket | count: bucket.count + 1, sum_x: bucket.sum_x + x, sum_y: bucket.sum_y + y}
        end)
      else
        acc
      end

    lure_buckets(rest, index + 1, width, bucket_px, acc)
  end

  defp lure_buckets(<<>>, _index, _width, _bucket_px, acc), do: acc

  defp fallback_lure_center(rgba, width, _height) do
    case lure_stats(rgba, 0, width, 0, 0, 0) do
      {0, _sum_x, _sum_y} -> :none
      {count, sum_x, sum_y} -> {:ok, {div(sum_x, count), div(sum_y, count)}, count}
    end
  end

  defp lure_pixel?(r, g, b),
    do: r >= 120 and r >= g + 25 and r >= b + 25 and g >= 20 and g <= 190 and b <= 190

  defp lure_stats(<<r, g, b, _a, rest::binary>>, index, width, count, sum_x, sum_y)
       when r >= 120 and r >= g + 25 and r >= b + 25 and g >= 20 and g <= 190 and b <= 190 do
    x = rem(index, width)
    y = div(index, width)
    lure_stats(rest, index + 1, width, count + 1, sum_x + x, sum_y + y)
  end

  defp lure_stats(<<_::32, rest::binary>>, index, width, count, sum_x, sum_y),
    do: lure_stats(rest, index + 1, width, count, sum_x, sum_y)

  defp lure_stats(<<>>, _index, _width, count, sum_x, sum_y), do: {count, sum_x, sum_y}

  defp bubble_count_near(%Frame{width: width, rgba: rgba}, {cx, cy}, radius, opts) do
    min_sum = Keyword.get(opts, :min_sum, 60)
    radius2 = max(radius, 0) * max(radius, 0)
    teal_pixels_near(rgba, 0, width, cx, cy, radius2, min_sum, 0)
  end

  defp lure_count_near(%Frame{width: width, rgba: rgba}, {cx, cy}, radius) do
    radius2 = max(radius, 0) * max(radius, 0)
    lure_pixels_near(rgba, 0, width, cx, cy, radius2, 0)
  end

  defp teal_pixels_near(<<r, g, b, _a, rest::binary>>, index, width, cx, cy, radius2, min_sum, n) do
    x = rem(index, width)
    y = div(index, width)
    dx = x - cx
    dy = y - cy

    n = if dx * dx + dy * dy <= radius2 and bubble_pixel?(r, g, b, min_sum), do: n + 1, else: n

    teal_pixels_near(rest, index + 1, width, cx, cy, radius2, min_sum, n)
  end

  defp teal_pixels_near(<<>>, _index, _width, _cx, _cy, _radius2, _min_sum, n), do: n

  defp lure_pixels_near(<<r, g, b, _a, rest::binary>>, index, width, cx, cy, radius2, n) do
    x = rem(index, width)
    y = div(index, width)
    dx = x - cx
    dy = y - cy

    n = if dx * dx + dy * dy <= radius2 and lure_pixel?(r, g, b), do: n + 1, else: n
    lure_pixels_near(rest, index + 1, width, cx, cy, radius2, n)
  end

  defp lure_pixels_near(<<>>, _index, _width, _cx, _cy, _radius2, n), do: n

  @doc "True when the battle strip contains the red/white pokeball icon of a wild pokemon."
  def wild_present?(%Frame{rgba: rgba}, opts \\ []) do
    count_pokeball_red(rgba, 0, Keyword.get(opts, :min_count, 12))
  end

  @doc """
  True when a FIXED red selection border is present in the battle frame — i.e.
  a target is locked (vs a blink, which is gone by the next frame). Heuristic:
  counts bright-red pixels, which spike when the border appears around the
  selected portrait. Tune `min_count` against the real game via /diagnostics.
  """
  def target_locked?(%Frame{rgba: rgba}, opts \\ []) do
    count_pokeball_red(rgba, 0, Keyword.get(opts, :min_count, 40))
  end

  @doc """
  Per-row count of TARGET-red pixels inside the battle body, one entry per battle
  row. Bands start at `top` (frame px) and are `band` (frame px) tall — pixels
  above `top` (the header) and below the last band are ignored. Lets the state
  machine attribute a lock to the row Tab selected, instead of trusting one
  aggregate over all rows.

  The red predicate is LOOSER than the bright pokeball red: MEASURED on the real
  game, a locked target's red NAME + selection ring are DARK red (~r 140-200, g/b
  ~20-30) — red-dominant but well below the pokeball's r≥200, which made a clearly
  locked target read ~0px. `r >= 130 and g <= 70 and b <= 70` catches the dark
  target red while still rejecting white/gray names, green HP bars, and blue icons;
  a non-fight row measures ~120px (one pokeball), so the 350 lock threshold still
  separates cleanly.
  """
  @spec red_row_counts(Frame.t(), keyword) :: [non_neg_integer]
  def red_row_counts(%Frame{width: w, rgba: rgba}, opts) do
    top = Keyword.fetch!(opts, :top)
    band = Keyword.fetch!(opts, :band)
    rows = Keyword.fetch!(opts, :rows)
    counts = red_band_counts(rgba, 0, w, top, band, rows, %{})
    for i <- 0..(rows - 1), do: Map.get(counts, i, 0)
  end

  @doc """
  Per-row count of HP-BAR GREEN inside the battle body, one entry per row — the
  same bands `red_row_counts/2` uses.

  It answers ONE question: **is that bar moving?** Not "how much health is
  left": the fraction needs the measured bar box, and this has to work with or
  without a located layout. A count is enough for the question that matters — a
  target being hit loses green, a target nobody can reach keeps every pixel.

  Pixels left of `min_x` are skipped because the creature ICON lives there and
  some are green (Vileplume's cap is the case at hand). A constant offset would
  not break a CHANGE test, but an animated icon would.
  """
  @spec hp_row_counts(Frame.t(), keyword) :: [non_neg_integer]
  def hp_row_counts(%Frame{width: w, rgba: rgba}, opts) do
    top = Keyword.fetch!(opts, :top)
    band = Keyword.fetch!(opts, :band)
    rows = Keyword.fetch!(opts, :rows)
    min_x = Keyword.get(opts, :min_x, div(w * 3, 10))
    counts = green_band_counts(rgba, 0, w, min_x, top, band, rows, %{})
    for i <- 0..(rows - 1), do: Map.get(counts, i, 0)
  end

  # Same shape (and the same clause-order rule) as red_band_counts: the
  # predicate clause MUST come before the catch-all. The green is the HP bar's
  # own — bright, and far from both the grey names and the dark red of a lock.
  defp green_band_counts(<<r, g, b, _a, rest::binary>>, index, width, min_x, top, band, rows, acc)
       when g >= 90 and g > r + 30 and g > b + 30 do
    acc =
      if rem(index, width) >= min_x,
        do: bump_band(acc, div(index, width), top, band, rows),
        else: acc

    green_band_counts(rest, index + 1, width, min_x, top, band, rows, acc)
  end

  defp green_band_counts(<<_::32, rest::binary>>, index, width, min_x, top, band, rows, acc),
    do: green_band_counts(rest, index + 1, width, min_x, top, band, rows, acc)

  defp green_band_counts(<<>>, _index, _width, _min_x, _top, _band, _rows, acc), do: acc

  defp bump_band(acc, y, top, band, rows) do
    row = if y >= top, do: div(y - top, band), else: -1
    if row >= 0 and row < rows, do: Map.update(acc, row, 1, &(&1 + 1)), else: acc
  end

  # Clause order matters: the red-predicate clause MUST come before the catch-all
  # <<_::32, ...>> (which matches any 4 bytes). Mirrors pokeball_row_counts.
  defp red_band_counts(<<r, g, b, _a, rest::binary>>, index, width, top, band, rows, acc)
       when r >= 130 and g <= 70 and b <= 70 do
    y = div(index, width)
    row = if y >= top, do: div(y - top, band), else: -1
    acc = if row >= 0 and row < rows, do: Map.update(acc, row, 1, &(&1 + 1)), else: acc
    red_band_counts(rest, index + 1, width, top, band, rows, acc)
  end

  defp red_band_counts(<<_::32, rest::binary>>, index, width, top, band, rows, acc),
    do: red_band_counts(rest, index + 1, width, top, band, rows, acc)

  defp red_band_counts(<<>>, _index, _width, _top, _band, _rows, acc), do: acc

  @doc """
  The single locked battle row: the loudest band whose red count reaches
  `min_pixels`, or `:none` if none do. Argmax (not any-over-threshold) is robust
  when a sibling row briefly grazes the threshold. Ties break to the lowest index.
  """
  @spec locked_row([non_neg_integer], non_neg_integer) :: {:ok, non_neg_integer} | :none
  def locked_row(counts, min_pixels) do
    counts
    |> Enum.with_index()
    |> Enum.filter(fn {c, _i} -> c >= min_pixels end)
    |> Enum.max_by(fn {c, _i} -> c end, fn -> nil end)
    |> case do
      nil -> :none
      {_c, i} -> {:ok, i}
    end
  end

  @doc "Total count of pokeball/selection-red pixels — for tuning thresholds in /diagnostics."
  def red_count(%Frame{rgba: rgba}), do: red_count(rgba, 0)

  defp red_count(<<r, g, b, _a, rest::binary>>, n) when r >= 200 and g <= 60 and b <= 60,
    do: red_count(rest, n + 1)

  defp red_count(<<_::32, rest::binary>>, n), do: red_count(rest, n)
  defp red_count(<<>>, n), do: n

  defp count_pokeball_red(_rgba, n, min_count) when n >= min_count, do: true

  defp count_pokeball_red(<<r, g, b, _a, rest::binary>>, n, min_count)
       when r >= 200 and g <= 60 and b <= 60,
       do: count_pokeball_red(rest, n + 1, min_count)

  defp count_pokeball_red(<<_::32, rest::binary>>, n, min_count),
    do: count_pokeball_red(rest, n, min_count)

  defp count_pokeball_red(<<>>, _n, _min_count), do: false

  @doc """
  Y-offset (frame pixels) of the TOPMOST pokeball-icon row inside the battle
  strip — i.e. the row of a WILD creature. Players' rows have no pokeball, so
  this lets the bot target the wild pokemon amid other players in the list.
  Returns `{:ok, y}` (band center) or `:not_found`.
  """
  def find_wild_row(%Frame{width: w, rgba: rgba}, opts \\ []) do
    min_count = Keyword.get(opts, :min_count, 12)
    band = Keyword.get(opts, :band, 16)

    rgba
    |> pokeball_row_counts(0, w, band, %{})
    |> Enum.filter(fn {_row, count} -> count >= min_count end)
    |> Enum.min_by(fn {row, _count} -> row end, fn -> nil end)
    |> case do
      nil -> :not_found
      {row, _count} -> {:ok, row * band + div(band, 2)}
    end
  end

  @doc """
  Center Y (frame pixels) of EVERY pokeball-icon row in the battle strip. The pokeball marks
  the PLAYER'S OWN active pokemon (corrected 2026-07-08 from live video — enemies have HP bars
  but NO pokeball), so these are the OWN-pokemon rows: combat subtracts them from the HP-bar
  rows to get the attackable enemy rows. Returns ALL of them, at raw scanline resolution
  (band 1) then clustered, so a caller can bucket each into its real row band. A pokeball is a
  scanline with >= `min_count` bright-red px; consecutive such scanlines within `gap` px
  collapse into one icon and we return the middle.

  Read it on the STRIP (`Calibration.battle_strip/1`), never the body — `battle_body/1` crops
  the pokeball column off, so this returns `[]` on a body frame.

  `min_count` default 5: MEASURED on Lucas's real screen (2026-07-09) the pokeball icon is a
  small ~7-px-wide red blob per scanline, so the old 12 never matched — his own Mareep looked
  attackable and got clicked. 5 catches the 4-7 px the icon actually has while staying above the
  ~0 red an empty enemy strip carries. Tune via the `pokeball_min_red_px` setting.

  Options: `:min_count` (5), `:gap` (6).
  """
  def pokeball_row_positions(%Frame{width: w, rgba: rgba}, opts \\ []) do
    min_count = Keyword.get(opts, :min_count, 5)
    gap = Keyword.get(opts, :gap, 6)

    rgba
    |> pokeball_row_counts(0, w, 1, %{})
    |> Enum.filter(fn {_y, count} -> count >= min_count end)
    |> Enum.map(fn {y, _count} -> y end)
    |> Enum.sort()
    |> cluster(gap)
    |> Enum.map(&cluster_center/1)
  end

  defp pokeball_row_counts(<<r, g, b, _a, rest::binary>>, index, width, band, acc)
       when r >= 200 and g <= 60 and b <= 60 do
    row = div(div(index, width), band)
    pokeball_row_counts(rest, index + 1, width, band, Map.update(acc, row, 1, &(&1 + 1)))
  end

  defp pokeball_row_counts(<<_::32, rest::binary>>, index, width, band, acc),
    do: pokeball_row_counts(rest, index + 1, width, band, acc)

  defp pokeball_row_counts(<<>>, _index, _width, _band, acc), do: acc

  @doc """
  Center Y (frame pixels, top→bottom) of each battle-list HP bar. Every creature
  row in the PokeTibia battle list carries a thin horizontal HP bar; detecting the bars
  gives the EXACT vertical position of every row, so the lock bands can be
  anchored to real landmarks instead of a hand-marked offset that drifts.

  A bar is a scanline with at least `min_run` GREEN pixels
  (`g >= min_g and g >= r + margin and g >= b + margin` — green-DOMINANT, so
  neither grayish sprites nor teal water pass); consecutive green scanlines
  (a bar is ~5px tall) within `gap` px collapse into one bar and we return the
  middle of each cluster. Low-HP bars turn red — ambiguous with the lock ring —
  so this reads the green/healthy bars; call it on a fresh battle list.

  Options: `:min_g` (120), `:margin` (40), `:min_run` (¼ of the frame width,
  min 4), `:gap` (6).
  """
  def hp_bar_rows(%Frame{width: w, height: h, rgba: rgba}, opts \\ []) do
    min_g = Keyword.get(opts, :min_g, 120)
    margin = Keyword.get(opts, :margin, 40)
    min_run = Keyword.get(opts, :min_run, max(div(w, 4), 4))
    gap = Keyword.get(opts, :gap, 6)

    counts = green_row_counts(rgba, 0, w, min_g, margin, %{})

    0..(h - 1)//1
    |> Enum.filter(fn y -> Map.get(counts, y, 0) >= min_run end)
    |> cluster(gap)
    |> Enum.map(&cluster_center/1)
  end

  # Clause order matters: the green-predicate clause MUST precede the catch-all.
  defp green_row_counts(<<r, g, b, _a, rest::binary>>, index, width, min_g, margin, acc)
       when g >= min_g and g >= r + margin and g >= b + margin do
    y = div(index, width)
    green_row_counts(rest, index + 1, width, min_g, margin, Map.update(acc, y, 1, &(&1 + 1)))
  end

  defp green_row_counts(<<_::32, rest::binary>>, index, width, min_g, margin, acc),
    do: green_row_counts(rest, index + 1, width, min_g, margin, acc)

  defp green_row_counts(<<>>, _index, _width, _min_g, _margin, acc), do: acc

  # Group an ascending list of Ys, merging neighbours within `gap` into one run.
  defp cluster([], _gap), do: []

  defp cluster([first | rest], gap) do
    {done, current} =
      Enum.reduce(rest, {[], [first]}, fn y, {done, [prev | _] = cur} ->
        if y - prev <= gap, do: {done, [y | cur]}, else: {[cur | done], [y]}
      end)

    [current | done] |> Enum.reverse() |> Enum.map(&Enum.reverse/1)
  end

  defp cluster_center(ys) do
    {lo, hi} = Enum.min_max(ys)
    div(lo + hi, 2)
  end

  @doc """
  True when the battle body holds at least one creature, detected by its HP bar:
  a horizontal scanline carrying a CONSECUTIVE run of >= `min_run` HP-bar-colored
  pixels — GREEN (`g >= 120 and g >= r + 40 and g >= b + 40`, a healthy bar) OR RED
  (`r >= 120 and r >= g + 40 and r >= b + 40`, a low-HP bar, or a red target
  ring/name). The run must be CONTIGUOUS left-to-right on one scanline — unlike
  `green_row_counts`/`red_band_counts` above, which tally ANY matching pixels
  anywhere in the row, this resets its running count to zero on every
  non-matching pixel (and at each row boundary), so thin speckle (isolated
  matching pixels, or runs shorter than `min_run`) never trips it. Early-exits
  `true` on the first qualifying scanline — a clearly-populated frame doesn't
  need to be scanned to the end. Used by /diagnostics to report whether the
  Battle list holds a creature; live combat now decides enemies/idle from
  `Interpret.battle/3`'s own row diff (Tab-targeting is keyboard-only — no
  click, no shared-mouse contention with fishing to avoid).

  Options: `:min_run` (¼ of the frame width, min 4).
  """
  def battle_has_creature?(%Frame{width: w, rgba: rgba}, opts \\ []) do
    min_run = Keyword.get(opts, :min_run, max(div(w, 4), 4))
    bar_run_scan(rgba, 0, w, min_run, 0)
  end

  # Tracks a CONSECUTIVE run of HP-bar-colored pixels per scanline: the running
  # count resets to 0 at every row boundary AND whenever a pixel fails the
  # predicate (a true contiguous run, not a per-row total). Stops the moment a
  # run reaches min_run.
  defp bar_run_scan(<<>>, _index, _width, _min_run, _run), do: false

  defp bar_run_scan(<<r, g, b, _a, rest::binary>>, index, width, min_run, run) do
    run = if rem(index, width) == 0, do: 0, else: run
    run = if hp_bar_px?(r, g, b), do: run + 1, else: 0

    if run >= min_run,
      do: true,
      else: bar_run_scan(rest, index + 1, width, min_run, run)
  end

  # Three bar colours, all measured on real captures: GREEN while healthy, RED at low HP in the
  # old client, and the AMBER the new one paints for a damaged bar — (124, 130, 24) on
  # 2026-08-24, where red and green sit within 6 of each other and neither dominates. Without
  defp hp_bar_px?(r, g, b) do
    (g >= 120 and g >= r + 40 and g >= b + 40) or
      (r >= 120 and r >= g + 40 and r >= b + 40) or
      (r >= 100 and g >= 100 and b <= 90)
  end

  @doc """
  Center Y (frame pixels, top→bottom) of every HP bar in the battle body. Every creature
  row (your own pokemon, players, the wild target) carries a thin horizontal HP bar, so
  the bar positions give the VERTICAL location of every occupied row WITHOUT selecting
  anything. Crucially, the bar is present BEFORE any Tab press — unlike the red lock
  ring, which only appears AFTER a Tab confirms a target — so combat can bound its scan
  to the rows that actually hold a creature instead of scanning empty black rows every
  tick.

  A bar is a scanline carrying a CONTIGUOUS run of >= `min_run` HP-bar px — GREEN
  (healthy) OR RED (low-HP), so a damaged creature still counts (unlike `hp_bar_rows/2`,
  which reads green only). The run must be contiguous (not a per-row total), which rejects
  thin speckle and red NAME text (sparse) while a solid bar passes. Consecutive bar
  scanlines within `gap` px (a bar is ~5px tall) collapse into one bar and we return the
  middle of each cluster.

  Options: `:min_run` (¼ of the frame width, min 4), `:gap` (6).
  """
  def hp_bar_row_positions(%Frame{width: w, rgba: rgba}, opts \\ []) do
    min_run = Keyword.get(opts, :min_run, max(div(w, 4), 4))
    gap = Keyword.get(opts, :gap, 6)

    rgba
    |> bar_run_rows(0, w, min_run, 0, [])
    |> Enum.reverse()
    |> cluster(gap)
    |> Enum.map(&cluster_center/1)
  end

  @doc """
  Every HP bar in the panel, WITH the fraction of it still filled.

  `hp_bar_row_positions/2` answers WHERE the bars are and stops there, and that
  left the panel saying far less than it shows. His battle window carries, per
  row, a track of a fixed width whose filled part IS the creature's health —
  the same reading his own pokemon's Pokebar gets. Measured on his capture of
  2026-08-27: 128px of track, 87 of them filled, against a Pokebar reading 67%.

  Two things follow from counting the SPENT part of the track as bar:

    * **A dying creature stops vanishing.** The run rule needs `min_run` pixels
      in a line, and a bar that only counts colour shrinks with the health
      behind it: on his 174px panel the old ¼-of-the-width floor lost every
      creature below ~34% — the ones about to die, which is exactly when
      walking away leaves something alive. Track plus fill is the full width at
      any health.
    * **The fraction needs no located layout.** The bar measures its own box,
      so a hand-calibrated region reads health as well as an anchored one.

  Returns one map per bar: `y` (centre, frame pixels), `x`/`w` (the track) and
  `pct` (0.0–1.0). Options: `:min_run` (¼ of the frame width, min 4), `:gap`
  (6, the vertical slack that joins a bar's scanlines) and `:blend` (2, how many
  foreign pixels a run may swallow — the fill/track boundary is antialiased,
  and one blended pixel there must not split a bar in two).
  """
  @spec hp_bars(Frame.t(), keyword) :: [
          %{y: non_neg_integer, x: non_neg_integer, w: pos_integer, pct: float}
        ]
  def hp_bars(frame, opts \\ [])

  def hp_bars(%Frame{width: w, height: h, rgba: rgba}, opts) when w > 0 and h > 0 do
    min_run = Keyword.get(opts, :min_run, max(div(w, 4), 4))
    gap = Keyword.get(opts, :gap, 6)
    blend = Keyword.get(opts, :blend, 2)

    0..(h - 1)
    |> Enum.map(&{&1, bar_line(binary_part(rgba, &1 * w * 4, w * 4), min_run, blend)})
    |> Enum.reject(&(elem(&1, 1) == nil))
    |> cluster_bars(gap)
  end

  def hp_bars(_empty_frame, _opts), do: []

  # The longest stretch of BAR on one scanline — filled part plus spent track.
  defp bar_line(line, min_run, blend) do
    case scan_bar(line, 0, blend, nil, nil) do
      {x, last, fill} when last - x + 1 >= min_run -> %{x: x, w: last - x + 1, fill: fill}
      _too_short_or_none -> nil
    end
  end

  defp scan_bar(<<>>, _x, _blend, open, best), do: longer(best, open)

  defp scan_bar(<<r, g, b, _a, rest::binary>>, x, blend, open, best) do
    cond do
      hp_bar_px?(r, g, b) -> scan_bar(rest, x + 1, blend, grow(open, x, 1), best)
      hp_track_px?(r, g, b) -> scan_bar(rest, x + 1, blend, grow(open, x, 0), best)
      open == nil -> scan_bar(rest, x + 1, blend, nil, best)
      elem(open, 3) >= blend -> scan_bar(rest, x + 1, blend, nil, longer(best, open))
      true -> scan_bar(rest, x + 1, blend, blank(open), best)
    end
  end

  defp grow(nil, x, fill), do: {x, x, fill, 0}
  defp grow({start, _last, fill, _gaps}, x, hit), do: {start, x, fill + hit, 0}

  defp blank({start, last, fill, gaps}), do: {start, last, fill, gaps + 1}

  defp longer(best, nil), do: best
  defp longer(nil, {start, last, fill, _gaps}), do: {start, last, fill}

  defp longer({best_start, best_last, _fill} = best, {start, last, fill, _gaps}) do
    if last - start > best_last - best_start, do: {start, last, fill}, else: best
  end

  # The SPENT part of a bar: dark slate blue, measured (39, 59, 79) on his panel.
  # Blue-dominant and dark, with the panel background (13, 16, 19) darker still
  # and every icon and glyph in the row far away from it.
  defp hp_track_px?(r, g, b),
    do: b >= 45 and b <= 110 and b >= g + 10 and g >= r + 10 and r <= 70

  defp cluster_bars([], _gap), do: []

  defp cluster_bars([first | rest], gap) do
    {done, current} =
      Enum.reduce(rest, {[], [first]}, fn {y, _line} = entry, {done, [{prev, _} | _] = cur} ->
        if y - prev <= gap, do: {done, [entry | cur]}, else: {[cur | done], [entry]}
      end)

    [current | done] |> Enum.reverse() |> Enum.map(&bar_of/1)
  end

  # A bar is ~5 scanlines and its top and bottom ones are blended into the row
  # behind them; the MIDDLE reading by fill is the one that is all bar.
  defp bar_of(lines) do
    {lo, hi} = lines |> Enum.map(&elem(&1, 0)) |> Enum.min_max()

    middle =
      lines
      |> Enum.sort_by(fn {_y, line} -> line.fill / line.w end)
      |> Enum.at(div(length(lines), 2))
      |> elem(1)

    %{y: div(lo + hi, 2), x: middle.x, w: middle.w, pct: middle.fill / middle.w}
  end

  @doc """
  How many distinct HP bars the battle body holds — the CREATURE COUNT, derived from
  `hp_bar_row_positions/2`. Kept for /diagnostics; combat itself bounds its scan by the
  bar POSITIONS (deepest occupied row), not this bare count.
  """
  def hp_bar_count(%Frame{} = frame, opts \\ []), do: length(hp_bar_row_positions(frame, opts))

  # Like bar_run_scan/5 but COLLECTS every scanline (row y) that reaches a qualifying
  # contiguous run, instead of early-exiting on the first — so distinct bars can be
  # located. Adds a row once, when its run first hits min_run (the head-guard blocks a
  # re-add if the same row has a second run).
  defp bar_run_rows(<<>>, _index, _width, _min_run, _run, acc), do: acc

  defp bar_run_rows(<<r, g, b, _a, rest::binary>>, index, width, min_run, run, acc) do
    run = if rem(index, width) == 0, do: 0, else: run
    run = if hp_bar_px?(r, g, b), do: run + 1, else: 0
    y = div(index, width)
    acc = if run == min_run and (acc == [] or hd(acc) != y), do: [y | acc], else: acc
    bar_run_rows(rest, index + 1, width, min_run, run, acc)
  end

  @doc """
  Per-slot skill-bar state: splits the frame into `count` equal-width vertical slots
  (the skill hotbar) and returns a detailed map per slot — average `brightness`
  (`max(r,g,b)`), average `saturation` (`max-min`), the `vivid_pct` of the slot, and a
  `state`.

  A READY skill shows a colourful icon; a skill on COOLDOWN is darkened by a dim grey
  overlay with a white countdown number. The AVERAGE saturation can't separate them when
  the ready icon is a SMALL bright symbol on a dark ground (e.g. skill 3's green glyph on
  black): the average washes the colour out. So the primary signal is `vivid_pct` — the %
  of pixels that are strongly COLOURED (per-pixel saturation ≥ @vivid_sat and brightness ≥
  @vivid_bright). A ready icon has a chunk of vivid pixels (the coloured glyph); the
  cooldown overlay greys everything and the white number is colourless, so vivid_pct ≈ 0.

  THE PREFERRED MODE — reference match (per-slot, calibrated): pass `:refs`, a list with one
  `{r, g, b}` per slot captured at calibration time with every skill READY. A slot's live
  `signature` (the average colour of its NON-white pixels) is compared with its own
  reference: within `:max_distance` (euclidean) → `:ready`, further → `:cooldown`. The
  countdown glyph and any white icon art are excluded from BOTH sides of the comparison, so
  no white rendering can contaminate it in either direction — this is what universal
  thresholds could never do: the pink-with-white icon read permanently :cooldown under the
  white override, while the olive icon's number anti-aliasing read falsely :ready under the
  colour tests (Lucas, 2026-07-10). A slot with no reference (nil, or an all-white live
  read) falls back to the threshold rules below.

  The ceiling is TIGHT by measurement: PokeTibia's cooldown REPLACES the icon with a dark panel
  + countdown number, and for icons whose ready art is a small glyph on black the ref
  averages out dark too — the panel lands only ~44-60 away (measured 2026-07-20; a red
  countdown glyph pulls even closer). A TRUE ready match measures 0-1: the icon is static
  art and the capture is deterministic. So the gap to split is ~1 vs ~44, and the old
  ceiling of 60 read half the charging bar as :ready.

  Threshold fallback (no reference): the COUNTDOWN NUMBER wins — a slot whose `white_pct`
  (share of PURE-white pixels: min channel ≥ 200, near-zero saturation) reaches
  `min_white_pct` reads `:cooldown` no matter how colourful the rest looks. Otherwise a
  slot is `:ready` when saturated ENOUGH (avg) OR with enough VIVID pixels — colour, never
  brightness alone (white/grey are colourless; brightness is still REPORTED per slot).
  Erring toward :cooldown is the CHEAP direction: the fishing gate's hook_hold_max_ms
  ceiling bounds a false hold, while a false ready pulls monsters with nothing to kill.

  All numbers are exported per slot for tuning from the diagnostic dump. Options: `:count`
  (7), `:refs` (nil), `:max_distance` (25), `:min_saturation` (40), `:min_vivid_pct` (7),
  `:min_white_pct` (4). Returns
  `[%{brightness, saturation, vivid_pct, white_pct, signature, distance, state}]`, left→right.
  """
  def skill_slots(%Frame{width: w, rgba: rgba}, opts \\ []) do
    count = (Keyword.get(opts, :count) || 7) |> clamp(1, w)
    # `|| default` (not Keyword's default) so a nil setting value — a caller passing a partial
    # settings map — still yields a number instead of crashing the `>=` comparison.
    min_s = Keyword.get(opts, :min_saturation) || 40
    min_vivid = Keyword.get(opts, :min_vivid_pct) || 7
    min_white = Keyword.get(opts, :min_white_pct) || 4
    max_distance = Keyword.get(opts, :max_distance) || 25
    refs = Keyword.get(opts, :refs) || []
    slot_w = max(div(w, count), 1)

    acc = skill_slot_acc(rgba, 0, w, count, slot_w, %{})

    for i <- 0..(count - 1)//1 do
      {sb, ss, vivid, white, cr, cg, cb, cn, n} = Map.get(acc, i, {0, 0, 0, 0, 0, 0, 0, 0, 0})
      n = max(n, 1)
      brightness = div(sb, n)
      saturation = div(ss, n)
      vivid_pct = div(vivid * 100, n)
      white_pct = div(white * 100, n)
      signature = if cn > 0, do: {div(cr, cn), div(cg, cn), div(cb, cn)}
      distance = slot_distance(signature, Enum.at(refs, i))

      state =
        slot_state(
          distance,
          max_distance,
          white_pct,
          min_white,
          saturation,
          min_s,
          vivid_pct,
          min_vivid
        )

      %{
        brightness: brightness,
        saturation: saturation,
        vivid_pct: vivid_pct,
        white_pct: white_pct,
        signature: signature,
        distance: distance,
        state: state
      }
    end
  end

  # The reference match wins when there IS one; otherwise the white countdown
  # glyph vetoes, and colour is the last word.
  defp slot_state(
         distance,
         max_distance,
         white_pct,
         min_white,
         saturation,
         min_s,
         vivid,
         min_vivid
       ) do
    cond do
      distance != nil -> if distance <= max_distance, do: :ready, else: :cooldown
      white_pct >= min_white -> :cooldown
      saturation >= min_s or vivid >= min_vivid -> :ready
      true -> :cooldown
    end
  end

  defp slot_distance({r, g, b}, {rr, rg, rb}),
    do: round(:math.sqrt((r - rr) ** 2 + (g - rg) ** 2 + (b - rb) ** 2))

  defp slot_distance(_signature, _ref), do: nil

  @doc "The per-slot skill states (`:ready | :cooldown`), left→right. See `skill_slots/2`."
  def skill_states(%Frame{} = frame, opts \\ []),
    do: frame |> skill_slots(opts) |> Enum.map(& &1.state)

  @doc """
  Does this frame LOOK like the calibrated HP bar at all? A real bar is made of exactly two
  pixel populations — the WARM coloured fill and the near-black track (plus a thin white
  number) — so their combined share is high. When the party window is MINIMIZED the region
  shows something else entirely (game world / window chrome: bright, blue-ish, colourful),
  the known share collapses, and the fill% becomes garbage — which read as "low HP" and made
  the survival combo open/close the window in a loop, burning potions and revives (Lucas,
  2026-07-11). Callers treat an implausible frame as UNKNOWN (nil HP → never act), same
  fail-safe rule as everywhere else.

  Options: `:min_brightness`/`:min_saturation` (the fill predicate, same defaults as
  `hp_fill_pct/2`), `:min_known_pct` (55) — the floor on (fill + track) share — and
  `:max_track_brightness` (75), how bright the EMPTY track is allowed to be. That last one
  is per-client: Poké Alliance's pokebar track is (45,69,69), so a ceiling of 60 counted
  every emptying column as neither fill nor track and the share fell WITH the HP, blanking
  the reading below ~65% — blind exactly where the potion and the rescue live.
  """
  def hp_region_plausible?(frame, opts \\ [])

  def hp_region_plausible?(%Frame{width: w, height: h, rgba: rgba}, opts)
      when w > 0 and h > 0 do
    min_b = Keyword.get(opts, :min_brightness) || 45
    min_s = Keyword.get(opts, :min_saturation) || 30
    min_known = Keyword.get(opts, :min_known_pct) || 55
    min_bright = Keyword.get(opts, :min_bright_pct) || 10
    max_track = Keyword.get(opts, :max_track_brightness) || 75

    {known, bright, total} = hp_known_px(rgba, min_b, min_s, max_track, 0, 0, 0)

    # A UNIFORMLY DARK region is a covered window, not an empty bar.
    known * 100 >= min_known * total and bright * 100 >= min_bright * total
  end

  def hp_region_plausible?(_frame, _opts), do: false

  defp hp_known_px(<<r, g, b, _a, rest::binary>>, min_b, min_s, max_track, known, lit, total) do
    bright = max(r, max(g, b))
    sat = bright - min(r, min(g, b))
    fill? = bright >= min_b and sat >= min_s and b <= max(r, g)
    track? = bright <= max_track

    hp_known_px(
      rest,
      min_b,
      min_s,
      max_track,
      known + if(fill? or track?, do: 1, else: 0),
      lit + if(bright > 60, do: 1, else: 0),
      total + 1
    )
  end

  defp hp_known_px(<<>>, _min_b, _min_s, _max_track, known, lit, total),
    do: {known, lit, max(total, 1)}

  @doc """
  Fill percentage (0..100) of a horizontal HP bar frame — the fraction of COLUMNS that hold a
  COLOURED pixel, so an emptying bar reads lower.

  COLOUR-AGNOSTIC by design: the fill changes hue as HP drops (green → olive → brown → red), so we
  can't key on "green". A column counts as filled when it holds a WARM, COLOURED pixel:
    * `saturation >= min_saturation` (colourful) — excludes the black background/track AND the white
      "current/max" number, both of which are colourless (~0 saturation);
    * `brightness >= min_brightness` — excludes near-black noise;
    * blue is NOT the dominant channel (`b <= max(r, g)`) — excludes the BLUE game background that
      can leak into a loosely-drawn box (it's highly saturated blue). Every HP tone (green/yellow/
      orange/red) has blue as its low channel, so this keeps them all.
  Options `:min_brightness` (45), `:min_saturation` (30). Empty/zero frame → 0. For an accurate %,
  calibrate the box tightly on the coloured track (no icons row, no background above/beside it).
  """
  # The HP numbers are near-white whatever the bar underneath is doing.
  @hp_text_bright 170
  @hp_text_sat 40

  def hp_fill_pct(frame, opts \\ [])

  def hp_fill_pct(%Frame{width: w, height: h, rgba: rgba}, opts) when w > 0 and h > 0 do
    min_b = Keyword.get(opts, :min_brightness, 45)
    min_s = Keyword.get(opts, :min_saturation, 30)

    {filled, text_only} = column_kinds(rgba, w, min_b, min_s)

    # The NUMBERS are drawn ON TOP of the bar, and a column hidden entirely behind a white digit
    # says nothing about the fill.
    judged = w - text_only

    if judged > 0, do: round(filled * 100 / judged), else: 0
  end

  def hp_fill_pct(_frame, _opts), do: 0

  # Per column: does it hold FILL, and is it nothing but the white number?
  defp column_kinds(rgba, w, min_b, min_s) do
    {filled, lettered} = column_scan(rgba, 0, w, min_b, min_s, MapSet.new(), MapSet.new())
    text_only = lettered |> MapSet.difference(filled) |> MapSet.size()
    {MapSet.size(filled), text_only}
  end

  defp column_scan(<<r, g, b, _a, rest::binary>>, i, w, min_b, min_s, filled, lettered) do
    bright = max(r, max(g, b))
    sat = bright - min(r, min(g, b))
    column = rem(i, w)

    warm? = bright >= min_b and sat >= min_s and b <= max(r, g)
    # the digits: bright and washed out, whatever the bar's colour underneath
    text? = bright >= @hp_text_bright and sat <= @hp_text_sat

    column_scan(
      rest,
      i + 1,
      w,
      min_b,
      min_s,
      if(warm?, do: MapSet.put(filled, column), else: filled),
      if(text?, do: MapSet.put(lettered, column), else: lettered)
    )
  end

  defp column_scan(<<>>, _i, _w, _min_b, _min_s, filled, lettered), do: {filled, lettered}

  defp skill_slot_acc(<<r, g, b, _a, rest::binary>>, i, w, count, slot_w, acc) do
    slot = min(div(rem(i, w), slot_w), count - 1)
    bright = max(r, max(g, b))
    sat = bright - min(r, min(g, b))
    vivid = if sat >= @vivid_sat and bright >= @vivid_bright, do: 1, else: 0
    # PURE white — the countdown glyph's body. min-channel high AND colourless, so a bright
    # coloured icon (yellow: b low) or a light grey chrome never counts.
    white? = min(r, min(g, b)) >= 200 and sat <= 30
    white = if white?, do: 1, else: 0
    # The NON-WHITE colour signature: what the icon looks like with the countdown glyph
    # (and any white icon art) taken out — the reference-match compares only this, so the
    # number can't contaminate the reading in either direction.
    {cr, cg, cb, cn} = if white?, do: {0, 0, 0, 0}, else: {r, g, b, 1}

    acc =
      Map.update(acc, slot, {bright, sat, vivid, white, cr, cg, cb, cn, 1}, fn
        {sb, ss, sv, sw, sr, sg, sbl, sn, n} ->
          {sb + bright, ss + sat, sv + vivid, sw + white, sr + cr, sg + cg, sbl + cb, sn + cn,
           n + 1}
      end)

    skill_slot_acc(rest, i + 1, w, count, slot_w, acc)
  end

  defp skill_slot_acc(<<>>, _i, _w, _count, _slot_w, acc), do: acc

  # Salience ranks for downsample/2: a cell is tagged with the HIGHEST-ranked
  # pixel class present anywhere inside it, so a thin HP bar or lock ring in an
  # otherwise-dark cell still surfaces instead of being averaged into gray.
  @rank_dark 0
  @rank_other 1
  @rank_cyan 2
  @rank_hp_green 3
  @rank_lock_red 4
  @rank_pokeball_red 5

  @doc """
  Downsamples a Frame into a coarse `cols`×`rows` grid — a compact, human/AI-readable
  "what the bot sees" map for the JSON diagnostics dump and an on-screen colour grid.

  Each cell carries the AVERAGE `{r, g, b}` over its source pixels (a colour swatch)
  and a `class` — the single most SALIENT pixel class present anywhere in the cell:
  `:pokeball_red` > `:lock_red` > `:hp_green` > `:cyan` > `:other` > `:dark`, reusing
  the same colour predicates the live detectors use. Presence-wins (not average-then-
  classify) so a thin HP bar / lock ring inside an otherwise-dark cell is not diluted
  into gray.

  Options: `:cols` (default 24, clamped to `[1, width]`) and `:rows` (default keeps the
  frame's aspect ratio, clamped to `[1, height]`).

  Returns `%{cols, rows, cell_w, cell_h, cells}` where `cells` is a row-major list of
  rows (top→bottom), each a list of `%{r, g, b, class}` (left→right).
  """
  def downsample(%Frame{width: w, height: h, rgba: rgba}, opts \\ []) do
    cols = opts |> Keyword.get(:cols, 24) |> clamp(1, w)
    rows = opts |> Keyword.get(:rows, max(div(h * cols, w), 1)) |> clamp(1, h)
    cell_w = max(div(w, cols), 1)
    cell_h = max(div(h, rows), 1)

    acc = downsample_acc(rgba, 0, w, cols, rows, cell_w, cell_h, %{})

    cells =
      for r <- 0..(rows - 1)//1 do
        for c <- 0..(cols - 1)//1 do
          {sr, sg, sb, n, rank} = Map.get(acc, {r, c}, {0, 0, 0, 0, @rank_dark})
          n = max(n, 1)
          %{r: div(sr, n), g: div(sg, n), b: div(sb, n), class: rank_to_class(rank)}
        end
      end

    %{cols: cols, rows: rows, cell_w: cell_w, cell_h: cell_h, cells: cells}
  end

  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)

  defp downsample_acc(<<r, g, b, _a, rest::binary>>, i, w, cols, rows, cw, ch, acc) do
    c = min(div(rem(i, w), cw), cols - 1)
    rr = min(div(div(i, w), ch), rows - 1)
    rank = pixel_rank(r, g, b)

    acc =
      Map.update(acc, {rr, c}, {r, g, b, 1, rank}, fn {sr, sg, sb, n, mx} ->
        {sr + r, sg + g, sb + b, n + 1, max(mx, rank)}
      end)

    downsample_acc(rest, i + 1, w, cols, rows, cw, ch, acc)
  end

  defp downsample_acc(<<>>, _i, _w, _cols, _rows, _cw, _ch, acc), do: acc

  # Same colour families as the detectors above: pokeball/bright red (red_count),
  # dark target red (red_row_counts), green HP bar (hp_bar_px?), teal bubble
  # (bubble_count). Near-black is `:dark`; anything else is `:other`.
  defp pixel_rank(r, g, b) do
    cond do
      pokeball_red?(r, g, b) -> @rank_pokeball_red
      lock_red?(r, g, b) -> @rank_lock_red
      hp_green?(r, g, b) -> @rank_hp_green
      bubble_pixel?(r, g, b, 60) -> @rank_cyan
      r + g + b <= 60 -> @rank_dark
      true -> @rank_other
    end
  end

  defp pokeball_red?(r, g, b), do: r >= 200 and g <= 60 and b <= 60
  defp lock_red?(r, g, b), do: r >= 130 and g <= 70 and b <= 70
  defp hp_green?(r, g, b), do: g >= 120 and g >= r + 40 and g >= b + 40

  defp rank_to_class(@rank_pokeball_red), do: :pokeball_red
  defp rank_to_class(@rank_lock_red), do: :lock_red
  defp rank_to_class(@rank_hp_green), do: :hp_green
  defp rank_to_class(@rank_cyan), do: :cyan
  defp rank_to_class(@rank_other), do: :other
  defp rank_to_class(@rank_dark), do: :dark
end
