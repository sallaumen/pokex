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
end
