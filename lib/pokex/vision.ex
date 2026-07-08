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
  Per-row count of TARGET-red pixels inside the battle body, one entry per battle
  row. Bands start at `top` (frame px) and are `band` (frame px) tall — pixels
  above `top` (the header) and below the last band are ignored. Lets the state
  machine attribute a lock to the row it clicked, instead of trusting one
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
  need to be scanned to the end. Lets combat go IDLE (zero mouse actions) when
  the Battle list is empty, instead of clicking a row over black space every
  tick and starving the fishing bot of the shared mouse.

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

  defp hp_bar_px?(r, g, b) do
    (g >= 120 and g >= r + 40 and g >= b + 40) or
      (r >= 120 and r >= g + 40 and r >= b + 40)
  end

  @doc """
  Per-slot skill-bar state: splits the frame into `count` equal-width vertical slots
  (the skill hotbar) and returns a detailed map per slot — average `brightness`
  (`max(r,g,b)`), average `saturation` (`max-min`), and a `state`.

  A READY skill shows a bright, saturated icon; a skill on COOLDOWN is darkened by a
  dim overlay with a small white countdown number. The overlay kills the icon's colour,
  so `saturation` is the primary signal: a slot is `:ready` when it is bright ENOUGH or
  saturated ENOUGH, and `:cooldown` only when it is BOTH dark AND grey. This keeps a
  dark-but-colourful ready icon (e.g. a green one) from being misread as cooldown.

  Both thresholds are tunable (measured live from the diagnostic dump, which exports
  these per-slot numbers). Options: `:count` (7), `:min_brightness` (140),
  `:min_saturation` (40). Returns `[%{brightness, saturation, state}]`, left→right.
  """
  def skill_slots(%Frame{width: w, rgba: rgba}, opts \\ []) do
    count = opts |> Keyword.get(:count, 7) |> clamp(1, w)
    min_b = Keyword.get(opts, :min_brightness, 140)
    min_s = Keyword.get(opts, :min_saturation, 40)
    slot_w = max(div(w, count), 1)

    acc = skill_slot_acc(rgba, 0, w, count, slot_w, %{})

    for i <- 0..(count - 1)//1 do
      {sb, ss, n} = Map.get(acc, i, {0, 0, 0})
      n = max(n, 1)
      brightness = div(sb, n)
      saturation = div(ss, n)
      state = if brightness >= min_b or saturation >= min_s, do: :ready, else: :cooldown
      %{brightness: brightness, saturation: saturation, state: state}
    end
  end

  @doc "The per-slot skill states (`:ready | :cooldown`), left→right. See `skill_slots/2`."
  def skill_states(%Frame{} = frame, opts \\ []),
    do: frame |> skill_slots(opts) |> Enum.map(& &1.state)

  defp skill_slot_acc(<<r, g, b, _a, rest::binary>>, i, w, count, slot_w, acc) do
    slot = min(div(rem(i, w), slot_w), count - 1)
    bright = max(r, max(g, b))
    sat = bright - min(r, min(g, b))

    acc =
      Map.update(acc, slot, {bright, sat, 1}, fn {sb, ss, n} -> {sb + bright, ss + sat, n + 1} end)

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
      r >= 200 and g <= 60 and b <= 60 -> @rank_pokeball_red
      r >= 130 and g <= 70 and b <= 70 -> @rank_lock_red
      g >= 120 and g >= r + 40 and g >= b + 40 -> @rank_hp_green
      g > r and b > r and 5 * g >= 3 * b and g + b >= 60 -> @rank_cyan
      r + g + b <= 60 -> @rank_dark
      true -> @rank_other
    end
  end

  defp rank_to_class(@rank_pokeball_red), do: :pokeball_red
  defp rank_to_class(@rank_lock_red), do: :lock_red
  defp rank_to_class(@rank_hp_green), do: :hp_green
  defp rank_to_class(@rank_cyan), do: :cyan
  defp rank_to_class(@rank_other), do: :other
  defp rank_to_class(@rank_dark), do: :dark
end
