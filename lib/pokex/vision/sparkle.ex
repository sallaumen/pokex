defmodule Pokex.Vision.Sparkle do
  @moduledoc """
  The SHINY SPARKLE: the yellow star the client draws beside the name of every
  shiny creature, once he switched that option on (11/09).

  "Esquece tudo que a gente já fez. Vamos focar nesse brilho." It is the first
  precise input this hunt has had: a glyph of the interface, drawn in the same
  pixels for every species, over the world but never lit by it, and only ever
  beside the NAME of a creature — which sits right above its health bar, the
  thing the eye already finds (`CreatureMarks`). So there is nothing to teach
  per species and nothing the cave's light can change.

  Measured on his video of 11/09 (Shiny Feraligatr, H.264, tile 151): a
  4-point star of 11×13 px (38-63 px, 7×10 at its smallest) with a small one
  beside it, both a strong yellow (r 228-252, g 196-224, b 44-96) with NO
  black outline — the letters of the name next to it are outlined, and the
  desert's sand, the loudest yellow of that map (r 216-243, g 180-214), keeps
  its blue channel above 110. The star stands 45-60 px left of the bar's
  centre and 0-16 px above it for a name the length of "Feraligatr"; a
  shorter name brings it closer.

  And measured on the guard's own raw photos of the first hunt (17:01 of
  11/09, the false sightings): the sand puts SPECKS beside names — nine in
  twelve photos, 4×4 to 5×5 px, (216-248, 184-192, 88-104) — so the yellow
  asks for green ≥ 192 and blue ≤ 100, and a star is at least 30 px on a
  6 px side. Every speck sat below both.

  Pure: the frame and the eye's marks in, the sparkles and the bar each one
  belongs to out, all in FRAME pixels.
  """

  alias Pokex.Vision.{CreatureMarks, Frame}

  @type hit :: %{
          point: {integer, integer},
          bar: {integer, integer},
          px: pos_integer,
          box: {integer, integer, integer, integer}
        }

  # the yellow of the glyph, with room for the capture path
  @r_min 244
  @g_min 192
  @b_max 100
  @r_minus_b_min 120
  # the glyph's size in POINTS (scaled by the frame's own scale)
  @side_min 6
  @side_max 20
  @px_min 30
  @fill_min 0.18
  # ink: the font's outline, or a black floor
  @ink_max 60
  # the window beside the name, in bar widths (27 pt) and bar heights (4 pt)
  @left_far 4.5
  @left_near 0.8
  @above 5.5
  @below 1.0

  @doc """
  Every sparkle sitting beside a creature's name, one per mark at most (the
  biggest star), with the bar it belongs to.
  """
  @spec find(Frame.t(), [CreatureMarks.mark() | %{point: {integer, integer}}]) :: [hit]
  def find(%Frame{} = frame, marks) do
    scale = frame.scale || 1.0
    geo = CreatureMarks.geometry(scale)

    marks
    |> Enum.map(&sparkle_beside(frame, &1.point, geo, scale))
    |> Enum.reject(&is_nil/1)
  end

  defp sparkle_beside(frame, {bx, by} = bar, geo, scale) do
    x0 = bx - round(@left_far * geo.bar_w)
    x1 = bx - round(@left_near * geo.bar_w)
    y0 = by - round(@above * geo.bar_h)
    y1 = by + round(@below * geo.bar_h)

    yellow = yellow_pixels(frame, x0, y0, x1, y1)

    blobs = components(yellow)

    blobs
    |> Enum.filter(&star?(&1, blobs, frame, scale))
    |> Enum.max_by(&MapSet.size/1, fn -> nil end)
    |> case do
      nil ->
        nil

      star ->
        {x_min, y_min, x_max, y_max} = bbox(star)

        %{
          point: {div(x_min + x_max, 2), div(y_min + y_max, 2)},
          bar: bar,
          px: MapSet.size(star),
          box: {x_min, y_min, x_max - x_min + 1, y_max - y_min + 1}
        }
    end
  end

  # --- the yellow ---------------------------------------------------------------

  defp yellow_pixels(%Frame{width: w, height: h, rgba: rgba}, x0, y0, x1, y1) do
    x0 = max(x0, 0)
    y0 = max(y0, 0)
    x1 = min(x1, w - 1)
    y1 = min(y1, h - 1)

    if x1 < x0 or y1 < y0 do
      MapSet.new()
    else
      for y <- y0..y1, x <- x0..x1, yellow?(rgba, w, x, y), into: MapSet.new(), do: {x, y}
    end
  end

  defp yellow?(rgba, w, x, y) do
    <<r, g, b, _a>> = binary_part(rgba, (y * w + x) * 4, 4)
    r >= @r_min and g >= @g_min and b <= @b_max and r - b >= @r_minus_b_min and g <= r
  end

  # --- the shape ----------------------------------------------------------------

  # 8-connected components of a small set of pixels.
  defp components(pixels), do: components(pixels, [])

  defp components(pixels, done) do
    case Enum.take(pixels, 1) do
      [] ->
        done

      [seed] ->
        component = grow(MapSet.new([seed]), [seed], pixels)
        components(MapSet.difference(pixels, component), [component | done])
    end
  end

  defp grow(component, [], _pixels), do: component

  defp grow(component, [{x, y} | queue], pixels) do
    fresh =
      for dx <- -1..1,
          dy <- -1..1,
          {dx, dy} != {0, 0},
          p = {x + dx, y + dy},
          MapSet.member?(pixels, p),
          not MapSet.member?(component, p),
          do: p

    grow(Enum.into(fresh, component), fresh ++ queue, pixels)
  end

  # A star is a small, well-filled blob standing ALONE: the letters of a
  # yellow name (the name goes green → yellow → red with the creature's
  # health) are the same colour and the same size, but each one has the next
  # letter a pixel or two away, and each wears the font's black outline over
  # a ground that is not black. The star has neither.
  defp star?(component, blobs, frame, scale) do
    {x_min, y_min, x_max, y_max} = bbox(component)
    w = x_max - x_min + 1
    h = y_max - y_min + 1
    px = MapSet.size(component)

    side_min = @side_min * scale
    side_max = @side_max * scale

    w >= side_min and w <= side_max and h >= side_min and h <= side_max and
      px >= @px_min * scale * scale and px >= @fill_min * w * h and
      cross?(component, {x_min, y_min, x_max, y_max}) and
      alone?({x_min, y_min, x_max, y_max}, component, blobs, scale) and
      not outlined?(component, frame)
  end

  # A 4-POINT STAR IS A CROSS: its middle column runs the whole height and its
  # middle row most of the width. Measured on the raw frames of 11/09: the
  # real star fills 100 % of its middle column and 57-62 % of its middle row;
  # the 38 px "staircase" of 17:25:55 (three offset blocks of the same yellow
  # beside a common creature's name) filled 33 % and 36 %.
  @cross_column_min 0.8
  @cross_row_min 0.5

  defp cross?(component, {x_min, y_min, x_max, y_max}) do
    cx = div(x_min + x_max, 2)
    cy = div(y_min + y_max, 2)

    column =
      Enum.count(y_min..y_max, fn y ->
        Enum.any?((cx - 1)..(cx + 1), &MapSet.member?(component, {&1, y}))
      end)

    row =
      Enum.count(x_min..x_max, fn x ->
        Enum.any?((cy - 1)..(cy + 1), &MapSet.member?(component, {x, &1}))
      end)

    column >= @cross_column_min * (y_max - y_min + 1) and
      row >= @cross_row_min * (x_max - x_min + 1)
  end

  # letters sit a pixel or two apart on one baseline; a star has no such neighbour
  @neighbour_gap 4

  # …and a neighbour only counts when it is letter-sized next to this one: the
  # glyph's own small twin stars (4-6 px tall beside a 16 px star, 17:26 and
  # 17:28 of 11/09) sat 3 px from the big star and were read as "the next
  # letter", and two real shinies went unseen.
  @letter_height_share 0.6

  defp alone?({x_min, y_min, x_max, y_max}, component, blobs, scale) do
    gap = round(@neighbour_gap * scale)
    height = y_max - y_min + 1

    not Enum.any?(blobs, fn other ->
      other != component and MapSet.size(other) >= 3 and
        (
          {ox_min, oy_min, ox_max, oy_max} = bbox(other)

          oy_max - oy_min + 1 >= @letter_height_share * height and
            ox_min <= x_max + gap and ox_max >= x_min - gap and
            oy_min <= y_max and oy_max >= y_min
        )
    end)
  end

  # The font's outline is ONE pixel of ink hugging the letter, with the ground
  # right behind it; over a black floor everything around is ink, and that is
  # not an outline.
  defp outlined?(component, frame) do
    ring1 = ring(component, component, 1)
    around = MapSet.union(component, MapSet.new(ring1))
    ring2 = ring(MapSet.new(ring1), around, 1)

    ink_share(ring1, frame) >= 0.6 and ink_share(ring2, frame) < 0.5
  end

  defp ring(component, taken, radius) do
    for {x, y} <- component,
        dx <- -radius..radius,
        dy <- -radius..radius,
        p = {x + dx, y + dy},
        not MapSet.member?(taken, p),
        uniq: true,
        do: p
  end

  defp ink_share(pixels, %Frame{width: w, height: h, rgba: rgba}) do
    inside = Enum.filter(pixels, fn {x, y} -> x >= 0 and y >= 0 and x < w and y < h end)

    case inside do
      [] ->
        0.0

      _ ->
        ink =
          Enum.count(inside, fn {x, y} ->
            <<r, g, b, _a>> = binary_part(rgba, (y * w + x) * 4, 4)
            max(r, max(g, b)) <= @ink_max
          end)

        ink / length(inside)
    end
  end

  defp bbox(component) do
    Enum.reduce(component, {1_000_000, 1_000_000, -1, -1}, fn {x, y}, {x0, y0, x1, y1} ->
      {min(x0, x), min(y0, y), max(x1, x), max(y1, y)}
    end)
  end
end
