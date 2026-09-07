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

  ## The bar is a UI element: it does not zoom with the map

  Measured on both his screens (2026-09-07): the ultrawide draws the map at
  151 points a tile and the notebook at 36, and the bar is 27×4 POINTS on
  both. So every size here scales with the FRAME's scale (pixels per point,
  stamped by the capture), never with `tile_px`. The tile only matters to
  whoever turns a mark into a distance.

  ## A partial fill has soft ends

  Measured on the notebook's Magneton pile: a bar at 30% reads
  `k.IIIIII.kkk` — one dim pixel at each end of the ink, neither black nor
  saturated. The first eye refused every such bar, which is why a whole pile
  read as "vi 1". The dim ends count as fill.
  """

  alias Pokex.Vision.Frame

  @bar_w 27
  @bar_h 4
  # Bright white only (every channel above 200): the icon keeps 61 such pixels
  # on both his screens, a Magneton's grey metal ball at most 12.
  @skull_px 61
  @skull_above {14, 40}
  @skull_half_w 12
  @skull_share 0.6
  # More white than an icon can hold is a flash, not a skull; an icon also
  # carries a black outline, a flash carries none.
  @skull_ceiling 1.6
  @skull_outline_px 25
  # the icon is 17 rows tall; a damage number is 9
  @skull_rows 12
  @box_bars 2
  @soft_ends 2

  @black_max 60
  @white_min 200
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
          skull_outline_px: pos_integer,
          skull_rows: pos_integer,
          box_w: pos_integer
        }

  @doc "The bar and signature sizes at this frame scale (pixels per point), from the measured reference."
  @spec geometry(number) :: geometry
  def geometry(scale) when is_number(scale) and scale > 0 do
    {above_min, above_max} = @skull_above

    %{
      bar_w: max(round(@bar_w * scale), 5),
      bar_h: max(round(@bar_h * scale), 4),
      skull_above: {max(round(above_min * scale), 2), max(round(above_max * scale), 4)},
      skull_half_w: max(round(@skull_half_w * scale), 3),
      skull_px: max(round(@skull_px * scale * scale), 8),
      skull_outline_px: max(round(@skull_outline_px * scale * scale), 4),
      skull_rows: max(round(@skull_rows * scale), 4),
      box_w: max(round(@bar_w * scale) * @box_bars, 10)
    }
  end

  @doc """
  Every creature mark in `frame`, top to bottom. `point` is the centre of the
  bar in FRAME pixels; the body stands one tile below it. Sizes come from the
  frame's own `scale` (pixels per point).
  """
  @spec find(Frame.t()) :: [mark]
  def find(%Frame{} = frame) do
    geo = geometry(frame_scale(frame))

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
  # the left of the ink (two, when the fill starts with a soft pixel) and one
  # to `bar_h - 2` rows up.
  defp bars_at(frame, {start, y}, geo) do
    for left <- [start - 1, start - 2],
        k <- 1..(geo.bar_h - 2),
        {:ok, fill} <- [rectangle(frame, left, y - k, geo)],
        do: {left, y - k, fill}
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

  # Interior columns are the fill from the left and black after; anything else
  # is not a health bar. The fill is ink with at most one soft (dim) column at
  # each end. Zero ink is refused: a plain black rectangle is not a creature,
  # and a creature at zero health is a corpse.
  defp fill(frame, bx, by, bw, bh) do
    kinds = for i <- 1..(bw - 2), do: column_kind(frame, bx + i, by, bh)
    {filled, rest} = Enum.split_while(kinds, &(&1 != :black))

    if Enum.all?(rest, &(&1 == :black)) and fill_shaped?(filled),
      do: {:ok, length(filled)},
      else: :no
  end

  # One interior column, read down: all ink, all black, or something else.
  defp column_kind(frame, x, by, bh) do
    column = Enum.map(1..(bh - 2), &kind_at(frame, x, by + &1))

    cond do
      Enum.all?(column, &(&1 == :ink)) -> :ink
      Enum.all?(column, &(&1 == :black)) -> :black
      true -> :other
    end
  end

  # Ink with at most one soft column at each end, and at least one ink.
  defp fill_shaped?(filled) do
    soft_ends = soft_run(filled) + soft_run(Enum.reverse(filled))

    Enum.any?(filled, &(&1 == :ink)) and soft_run(filled) <= 1 and
      soft_run(Enum.reverse(filled)) <= 1 and
      Enum.count(filled, &(&1 == :other)) <= min(soft_ends, @soft_ends)
  end

  defp soft_run(kinds), do: kinds |> Enum.take_while(&(&1 == :other)) |> length()

  # --- the mark and its signatures ----------------------------------------

  defp mark(frame, {bx, by, fill}, geo) do
    %{
      point: {bx + div(geo.bar_w, 2), by + div(geo.bar_h, 2)},
      hp_pct: round(100 * fill / (geo.bar_w - 2)),
      skull?: skull?(frame, bx, by, geo),
      pet?: box_below?(frame, bx, by, geo)
    }
  end

  # An icon's worth of white, as TALL as an icon, with a black outline around
  # it. A spell flash is far more white and has no outline; a damage number
  # ("168" over the pile) is white with an outline but only a digit tall.
  defp skull?(frame, bx, by, geo) do
    cx = bx + div(geo.bar_w, 2)
    {above_min, above_max} = geo.skull_above

    {white, black, rows} =
      for y <- (by - above_max)..(by - above_min)//1,
          x <- (cx - geo.skull_half_w)..(cx + geo.skull_half_w)//1,
          reduce: {0, 0, MapSet.new()} do
        tally -> tally_icon(frame, x, y, tally)
      end

    white >= round(geo.skull_px * @skull_share) and
      white <= round(geo.skull_px * @skull_ceiling) and
      black >= geo.skull_outline_px and
      MapSet.size(rows) >= geo.skull_rows
  end

  defp tally_icon(frame, x, y, {white, black, rows}) do
    cond do
      black_at?(frame, x, y) -> {white, black + 1, rows}
      white_at?(frame, x, y) -> {white + 1, black, MapSet.put(rows, y)}
      true -> {white, black, rows}
    end
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

  defp frame_scale(%Frame{scale: scale}) when is_number(scale) and scale > 0, do: scale
  defp frame_scale(_frame), do: 1.0
end
