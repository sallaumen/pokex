defmodule Pokex.Vision do
  @moduledoc "Pure pixel analysis over Frames. No I/O here, ever."

  alias Pokex.Vision.Frame

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

  @doc """
  Locates the hostile creature inside the arena frame by clustering pure-red
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
  it works day and night. A bubble is teal — green and blue both above red AND
  green not far below blue. The navy water is blue-DOMINANT (measured night water
  (14,28,59): green is only ~0.47·blue), so the `5·g >= 3·b` (green ≥ 0.6·blue)
  ratio rejects water at ANY brightness while teal bubbles pass. `min_sum` floors
  out near-black sensor noise. Earlier absolute thresholds (g,b ≥ 150) missed the
  dimmer night bubbles entirely (the "0px at night" bug).
  """
  def bubble_count(%Frame{rgba: rgba}, opts \\ []) do
    min_sum = Keyword.get(opts, :min_sum, 60)
    teal_pixels(rgba, min_sum, 0)
  end

  defp teal_pixels(<<r, g, b, _a, rest::binary>>, min_sum, n)
       when g > r and b > r and 5 * g >= 3 * b and g + b >= min_sum,
       do: teal_pixels(rest, min_sum, n + 1)

  defp teal_pixels(<<_::32, rest::binary>>, min_sum, n),
    do: teal_pixels(rest, min_sum, n)

  defp teal_pixels(<<>>, _min_sum, n), do: n

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
  Per-row count of pure-red pixels inside the battle body, one entry per battle
  row. Bands start at `top` (frame px) and are `band` (frame px) tall — pixels
  above `top` (the header) and below the last band are ignored. Same pure-red
  predicate as `red_count/1`. Lets the state machine attribute a lock to the row
  it clicked, instead of trusting one aggregate over all rows.
  """
  @spec red_row_counts(Frame.t(), keyword) :: [non_neg_integer]
  def red_row_counts(%Frame{width: w, rgba: rgba}, opts) do
    top = Keyword.fetch!(opts, :top)
    band = Keyword.fetch!(opts, :band)
    rows = Keyword.fetch!(opts, :rows)
    counts = red_band_counts(rgba, 0, w, top, band, rows, %{})
    for i <- 0..(rows - 1), do: Map.get(counts, i, 0)
  end

  # Clause order matters: the red-predicate clause MUST come before the catch-all
  # <<_::32, ...>> (which matches any 4 bytes). Mirrors pokeball_row_counts.
  defp red_band_counts(<<r, g, b, _a, rest::binary>>, index, width, top, band, rows, acc)
       when r >= 200 and g <= 60 and b <= 60 do
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
  row in the PXG battle list carries a thin horizontal HP bar; detecting the bars
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
end
