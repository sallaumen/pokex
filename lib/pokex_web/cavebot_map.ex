defmodule PokexWeb.CavebotMap do
  @moduledoc """
  The route as a MAP instead of a column of numbers.

  A waypoint list reads like `2396, 30621` — true, and unusable: a corner
  marked one tile off looks exactly like a corner marked right, and the shape
  of the walk (the thing being recorded) is nowhere on screen. Here the same
  waypoints are plotted in the game's own coordinate space, with the character
  on top of them, so a wrong corner is SEEN rather than deduced.

  Pure geometry: it answers where to look (the SVG viewBox) and how big a dot
  should be at that zoom. The drawing itself is the component's job, and the
  projection is the SVG's — game coordinates ARE the view coordinates (x east,
  y south, exactly like the client), so nothing is transformed twice.
  """

  @typedoc "A waypoint or the character: anything with x/y in game tiles."
  @type point :: %{x: integer, y: integer}

  @min_span 12
  @pad_ratio 0.12
  @dot_ratio 0.022

  @doc """
  The view over `points`: `%{box: {x, y, w, h}, unit: float}` in game tiles, or
  `nil` when there is nothing to show.

  The box always covers every point with a margin, never collapses (a
  single-waypoint route would otherwise be an infinitely deep zoom), and is
  kept SQUARE so a north-south route and an east-west one are drawn at the same
  scale — a route that changes shape when you add a corner cannot be read.
  """
  @spec view([point]) :: %{box: {number, number, number, number}, unit: float} | nil
  def view([]), do: nil

  def view(points) do
    xs = Enum.map(points, & &1.x)
    ys = Enum.map(points, & &1.y)

    {cx, cy} = {mid(xs), mid(ys)}
    span = span(xs, ys)
    half = span / 2

    %{box: {cx - half, cy - half, span, span}, unit: span * @dot_ratio}
  end

  defp mid(values), do: (Enum.min(values) + Enum.max(values)) / 2

  defp span(xs, ys) do
    widest = max(Enum.max(xs) - Enum.min(xs), Enum.max(ys) - Enum.min(ys))
    max(widest * (1 + 2 * @pad_ratio), @min_span)
  end

  @doc """
  `"x y w h"` — the viewBox attribute for `view/1`'s box.
  """
  @spec box_attr(%{box: {number, number, number, number}}) :: String.t()
  def box_attr(%{box: {x, y, w, h}}) do
    Enum.map_join([x, y, w, h], " ", &(&1 |> :erlang.float() |> Float.round(2)))
  end

  @doc """
  The polyline `points` attribute for the walked order.
  """
  @spec path_attr([point]) :: String.t()
  def path_attr(points), do: Enum.map_join(points, " ", &"#{&1.x},#{&1.y}")

  @doc """
  Where the arrow between two waypoints goes: the midpoint, and the rotation
  (degrees) that turns a right-pointing marker onto the segment. Direction is
  what a list of coordinates can never show — which way the hunt runs.
  """
  @spec arrow(point, point) :: %{x: float, y: float, angle: float}
  def arrow(%{x: x1, y: y1}, %{x: x2, y: y2}) do
    %{
      x: (x1 + x2) / 2,
      y: (y1 + y2) / 2,
      angle: :math.atan2(y2 - y1, x2 - x1) * 180 / :math.pi()
    }
  end

  @doc """
  Tiles between two points, walked (no diagonals in a tile grid: the client
  walks one axis at a time), or nil when either side is missing. This is the
  number that says "this corner is 3 tiles from the last one" — the difference
  between a route with corners and a route with noise.
  """
  @spec tiles_between(point | nil, point | nil) :: non_neg_integer | nil
  def tiles_between(%{x: x1, y: y1}, %{x: x2, y: y2}), do: abs(x2 - x1) + abs(y2 - y1)
  def tiles_between(_missing, _other), do: nil

  @doc """
  The route's total length in walked tiles — the honest measure of "how long is
  this hunt", which the waypoint COUNT never was (four corners can be four
  tiles or four hundred).
  """
  @spec total_tiles([point]) :: non_neg_integer
  def total_tiles(points) do
    points
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(0, fn [a, b], sum -> sum + tiles_between(a, b) end)
  end
end
