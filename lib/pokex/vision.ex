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
  Counts the bright-cyan pixels of the fishing "bite" bubbles — the light-cyan
  rings that flash around the bait when a fish bites. Calm water is a darker,
  low-green blue and reads ~0; a bite lights up hundreds of these pixels
  (measured in-game: bite ≈ 512 px, calm ≈ 0). Lighting/species independent.
  """
  def bubble_count(%Frame{rgba: rgba}, opts \\ []) do
    min_g = Keyword.get(opts, :min_g, 150)
    min_b = Keyword.get(opts, :min_b, 150)
    cyan_pixels(rgba, min_g, min_b, 0)
  end

  defp cyan_pixels(<<r, g, b, _a, rest::binary>>, min_g, min_b, n)
       when g >= min_g and b >= min_b and r < g,
       do: cyan_pixels(rest, min_g, min_b, n + 1)

  defp cyan_pixels(<<_::32, rest::binary>>, min_g, min_b, n),
    do: cyan_pixels(rest, min_g, min_b, n)

  defp cyan_pixels(<<>>, _min_g, _min_b, n), do: n

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
end
