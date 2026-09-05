defmodule Pokex.Vision.CreatureMarks do
  @moduledoc """
  Where every creature on the field IS, read from the health bar the client
  draws over each one — the one picture that is the same for a Feraligatr, a
  Venusaur and the character.

  Measured on his own client (2026-09-05, a 1812×1440 capture around the
  character at `tile_px` 151): a 27×4 black rectangle with a 25×2 interior,
  filled from the left with saturated ink for as much health as the creature
  has. Name colour is NOT used: in this client the name is drawn in the
  health colour (green when full), so "red name = hostile" only ever held for
  creatures already bleeding.

  Two signatures ride with the bar:

    * a **skull** above it, ~118 near-white pixels in a 16×17 icon. In his
      game every level-150+ monster carries one, and an area either has
      skulls on everyone or on nobody.
    * a **number box** under it, a wide black box behind a number, drawn only
      under his own pokémon.

  Every size here is a fraction of the tile, so a client zoom that moves
  `tile_px` moves the whole ruler with it.
  """

  alias Pokex.Vision.Frame

  @reference_tile 151
  @bar_w 27
  @bar_h 4
  @skull_px 118
  @skull_above {14, 40}
  @skull_half_w 12
  @skull_share 0.6
  @box_bars 2

  @black_max 60
  @white_min 150
  @white_spread 40
  @ink_max_min 140
  @ink_min_max 60

  @type mark :: %{
          point: {integer, integer},
          hp_pct: 0..100,
          skull?: boolean,
          pet?: boolean
        }

  @type geometry :: %{
          bar_w: pos_integer,
          bar_h: pos_integer,
          skull_above: {pos_integer, pos_integer},
          skull_half_w: pos_integer,
          skull_px: pos_integer,
          box_w: pos_integer
        }

  @doc "The bar and signature sizes at this tile ruler, scaled from the measured reference."
  @spec geometry(pos_integer) :: geometry
  def geometry(tile_px) when is_integer(tile_px) and tile_px > 0 do
    ratio = tile_px / @reference_tile
    {above_min, above_max} = @skull_above

    %{
      bar_w: max(round(@bar_w * ratio), 5),
      bar_h: max(round(@bar_h * ratio), 4),
      skull_above: {max(round(above_min * ratio), 2), max(round(above_max * ratio), 4)},
      skull_half_w: max(round(@skull_half_w * ratio), 3),
      skull_px: max(round(@skull_px * ratio * ratio), 8),
      box_w: max(round(@bar_w * ratio) * @box_bars, 10)
    }
  end

  @doc """
  Every creature mark in `frame`, top to bottom. `point` is the centre of the
  bar in FRAME pixels; the body stands one tile below it.

  Options: `:tile_px` — the tile ruler in frame pixels (default the reference).
  """
  @spec find(Frame.t(), keyword) :: [mark]
  def find(%Frame{} = frame, opts \\ []) do
    geo = geometry(Keyword.get(opts, :tile_px, @reference_tile))

    frame
    |> candidates(geo)
    |> Enum.flat_map(&bars_at(frame, &1, geo))
    |> Enum.uniq_by(fn {x, y, _fill} -> {x, y} end)
    |> Enum.map(&mark(frame, &1, geo))
    |> Enum.sort_by(fn %{point: {x, y}} -> {y, x} end)
  end

  # --- candidates: runs of fill ink on sampled rows -------------------------
  #
  # The bar's two interior rows have different parity, so sampling every other
  # row meets exactly one of them. A run of ink narrower than the interior is
  # where a bar MAY start; the rectangle test decides.
  defp candidates(%Frame{height: h, width: w, rgba: rgba}, geo) do
    for y <- 0..(h - 1)//2, reduce: [] do
      acc -> row_runs(binary_part(rgba, y * w * 4, w * 4), 0, nil, y, geo, acc)
    end
  end

  defp row_runs(<<r, g, b, _a, rest::binary>>, x, run, y, geo, acc) do
    cond do
      ink?(r, g, b) -> row_runs(rest, x + 1, run || x, y, geo, acc)
      run == nil -> row_runs(rest, x + 1, nil, y, geo, acc)
      true -> row_runs(rest, x + 1, nil, y, geo, keep(acc, run, x - 1, y, geo))
    end
  end

  defp row_runs(<<>>, x, run, y, geo, acc) do
    if run, do: keep(acc, run, x - 1, y, geo), else: acc
  end

  defp keep(acc, start, last, y, geo) do
    if last - start + 1 <= geo.bar_w - 2, do: [{start, y} | acc], else: acc
  end

  # The run is one of the interior rows; the bar's top-left is one column to
  # the left and one to `bar_h - 2` rows up.
  defp bars_at(frame, {start, y}, geo) do
    for k <- 1..(geo.bar_h - 2),
        {:ok, fill} <- [rectangle(frame, start - 1, y - k, geo)],
        do: {start - 1, y - k, fill}
  end

  # --- the rectangle ------------------------------------------------------

  defp rectangle(frame, bx, by, %{bar_w: bw, bar_h: bh}) do
    inside? = bx >= 0 and by >= 0 and bx + bw <= frame.width and by + bh <= frame.height

    with true <- inside?,
         true <- horizontal_borders?(frame, bx, by, bw, bh),
         true <- vertical_borders?(frame, bx, by, bw, bh),
         {:ok, fill} <- fill(frame, bx, by, bw, bh) do
      {:ok, fill}
    else
      _not_a_bar -> :no
    end
  end

  defp horizontal_borders?(frame, bx, by, bw, bh) do
    Enum.all?(0..(bw - 1), fn i ->
      black_at?(frame, bx + i, by) and black_at?(frame, bx + i, by + bh - 1)
    end)
  end

  defp vertical_borders?(frame, bx, by, bw, bh) do
    Enum.all?(0..(bh - 1), fn j ->
      black_at?(frame, bx, by + j) and black_at?(frame, bx + bw - 1, by + j)
    end)
  end

  # Interior columns are ink from the left and black after; anything else is
  # not a health bar. Zero fill is refused: a plain black rectangle is not a
  # creature, and a creature at zero health is a corpse.
  defp fill(frame, bx, by, bw, bh) do
    rows = 1..(bh - 2)

    kinds =
      for i <- 1..(bw - 2) do
        column = Enum.map(rows, &kind_at(frame, bx + i, by + &1))

        cond do
          Enum.all?(column, &(&1 == :ink)) -> :ink
          Enum.all?(column, &(&1 == :black)) -> :black
          true -> :other
        end
      end

    fill = kinds |> Enum.take_while(&(&1 == :ink)) |> length()
    rest_black? = kinds |> Enum.drop(fill) |> Enum.all?(&(&1 == :black))

    if fill > 0 and rest_black?, do: {:ok, fill}, else: :no
  end

  # --- the mark and its signatures ----------------------------------------

  defp mark(frame, {bx, by, fill}, geo) do
    %{
      point: {bx + div(geo.bar_w, 2), by + div(geo.bar_h, 2)},
      hp_pct: round(100 * fill / (geo.bar_w - 2)),
      skull?: skull?(frame, bx, by, geo),
      pet?: box_below?(frame, bx, by, geo)
    }
  end

  defp skull?(frame, bx, by, geo) do
    cx = bx + div(geo.bar_w, 2)
    {above_min, above_max} = geo.skull_above

    count =
      for y <- (by - above_max)..(by - above_min)//1,
          x <- (cx - geo.skull_half_w)..(cx + geo.skull_half_w)//1,
          white_at?(frame, x, y),
          reduce: 0 do
        n -> n + 1
      end

    count >= round(geo.skull_px * @skull_share)
  end

  # The bottom border of his pokémon's bar is part of the number box's top
  # edge: one black run at least two bars wide. A hostile's bottom border is
  # the bar alone.
  defp box_below?(frame, bx, by, geo) do
    cx = bx + div(geo.bar_w, 2)
    row = by + geo.bar_h - 1

    left =
      cx |> Stream.iterate(&(&1 - 1)) |> Enum.take_while(&black_at?(frame, &1, row)) |> length()

    right =
      (cx + 1)
      |> Stream.iterate(&(&1 + 1))
      |> Enum.take_while(&black_at?(frame, &1, row))
      |> length()

    left + right >= geo.box_w
  end

  # --- pixels -------------------------------------------------------------

  defp kind_at(frame, x, y) do
    case pixel(frame, x, y) do
      {r, g, b} when r <= @black_max and g <= @black_max and b <= @black_max -> :black
      {r, g, b} -> if ink?(r, g, b), do: :ink, else: :other
      nil -> :other
    end
  end

  defp black_at?(frame, x, y), do: kind_at(frame, x, y) == :black

  defp white_at?(frame, x, y) do
    case pixel(frame, x, y) do
      {r, g, b} ->
        low = min(min(r, g), b)
        high = max(max(r, g), b)
        low > @white_min and high - low < @white_spread

      nil ->
        false
    end
  end

  # Fill ink is one channel high and another near zero: sand (224,192,128) and
  # skin never qualify, green/yellow/red health always does.
  defp ink?(r, g, b), do: max(max(r, g), b) > @ink_max_min and min(min(r, g), b) < @ink_min_max

  defp pixel(%Frame{width: w, height: h, rgba: rgba}, x, y)
       when x >= 0 and y >= 0 and x < w and y < h do
    <<r, g, b, _a>> = binary_part(rgba, (y * w + x) * 4, 4)
    {r, g, b}
  end

  defp pixel(_frame, _x, _y), do: nil
end
