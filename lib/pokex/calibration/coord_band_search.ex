defmodule Pokex.Calibration.CoordBandSearch do
  @moduledoc """
  Finds the coordinate band by READING, so nobody has to mark it blind.

  The band used to take 2 precise clicks on a screenshot that could not even
  show the text: the game draws "(x, y, z)" only while the position CHANGES
  (or while the mouse hovers the minimap), and the wizard's screenshot had
  neither. Given the map rectangle and a shot taken while walking, this module
  sweeps candidate bands across the whole widget, at several ink floors, and
  confirms each with a full `read_coord` — the band that gets saved is a band
  that already read a position.

  ## The two things the field taught this sweep (2026-08-10)

  * **Depth.** With the widget marked whole, the label sat 83pt below the
    marked top; the old fixed offset list stopped at 64 and never looked. The
    sweep is now derived from the map rectangle's own height.
  * **Ink.** Over bright terrain the label's own anti-aliasing welds to the
    map: at floor 120 the coordinate row segmented into 45- and 59-column
    blobs and read nothing, while at 170 the same row read
    "(2671, 3?439, 5)". The floor that reads is not knowable in advance, so it
    is searched too — and RETURNED, because the reader has to use the same one.

  ## The hover guard

  The clock only renders while the mouse is over the minimap (Lucas,
  2026-08-10) — so a clock in the picture means the mouse is where it must not
  be, and the label it shows is in the hover position, ~40pt below where the
  day-to-day reading looks. Such a photo answers `:hovered`: refusing it is
  what keeps the exception state out of the saved calibration.

  ## The door out of the closed loop (2026-08-17)

  A band used to be confirmed by a WHOLE `read_coord`, and that made one
  unknown character fatal. Measured on the region Lucas came to hunt: every Y
  there is 308xx, and the `8` of that render lands 19 pixels from the atlas's
  against an 18-pixel ceiling. The sweep found the right rectangle, segmented
  all 14 glyphs and read 13 — `"(2310, 30?04, 6)"` — then threw the rectangle
  away. Calibration was impossible on the one screen that needed teaching, and
  the teach page needs a calibrated band: a loop with no door.

  The digits are not what proves the rectangle. Two parentheses, two commas and
  the digit runs between them are a shape the map does not counterfeit, so a
  line with that shape answers `:unread` — carrying the band, the partial text
  and the glyphs, which is everything the wizard needs to ask "what number is
  on your screen?" and teach the whole render from the answer. A line that
  reads WHOLE still wins wherever the sweep finds one.

  Everything in POINTS in and out (the unit the calibration file speaks);
  pixels are internal, via `scale`.
  """

  alias Pokex.Vision.{Frame, Glyphs}

  # Measured on the real failures: 120 is the floor the atlas was taught at and
  # it wins over dark map; 170 is where bright terrain stops welding to the
  # strokes; 200 survives near-white ground.
  @ink_floors [170, 200]
  @heights [20, 26]
  @step 4
  @above 24
  @margin 2
  # The colon with a digit beside it: a coordinate never carries one, and the
  # clock's own digits do not always resolve over the map behind them.
  @clock ~r/\d:|:\d/
  # The coordinate's shape with its digits allowed to be unread. `?` is what
  # `read_line` renders an unknown glyph as, and it is literal inside the class.
  @shape ~r/^\(([\d?]+),\s?([\d?]+),\s?([\d?]+)\)$/

  @type band :: {integer, integer, integer, integer}
  @type found :: {:ok, band, {integer, integer, integer}, integer}
  @type unread :: {:unread, band, integer, String.t(), [map]}

  @doc """
  `{:ok, band, {x, y, z}, ink}` — the band (points) and the ink floor that
  already read the position on `frame`.

  `{:unread, band, ink, text, glyphs}` when a band carries the coordinate's
  SHAPE but not every glyph resolved: the band is proven, `text` is the partial
  line (`"(2310, 30?04, 6)"`) and `glyphs` are its characters left to right, so
  the caller can name them. `:hovered` when the picture shows the minimap's
  hover state (mouse over the widget, wrong state to calibrate), and `:error`
  when nothing coordinate-shaped was found at all.
  """
  @spec search(Frame.t(), band, number, keyword) :: found | unread | :hovered | :error
  def search(%Frame{} = frame, {_mx, _my, _mw, _mh} = map, scale, opts \\ []) do
    if hovered?(frame, map, scale, opts) do
      :hovered
    else
      sweep(frame, map, scale, opts)
    end
  end

  # The clock is the hover state's own signature — cheaper and far more
  # specific than measuring where the label landed.
  defp hovered?(frame, {mx, my, mw, _mh}, scale, opts) do
    Enum.any?(inks(opts), fn ink ->
      band = scale_rect({mx, my, mw, 60}, scale)
      Regex.match?(@clock, Glyphs.read_line(frame, band, ink: ink).text)
    end)
  end

  # One pass, and a whole reading wins from ANYWHERE in it: the shape-only band
  # is merely remembered — the first one, the shallowest — while the sweep keeps
  # looking for a band that reads. Two passes would double the cost of the very
  # case that already scans every candidate.
  defp sweep(frame, {mx, my, mw, mh}, scale, opts) do
    mh
    |> candidates(opts)
    |> Enum.reduce_while(nil, fn {offset, height, ink}, unread ->
      band = scale_rect({mx, my + offset, mw, height}, scale)

      case probe(frame, band, round(scale * @margin), ink) do
        {:read, tight, pos} ->
          {:halt, {:ok, to_points(tight, scale), pos, ink}}

        {:shape, tight, text, glyphs} ->
          {:cont, unread || unread(tight, scale, ink, text, glyphs)}

        :error ->
          {:cont, unread}
      end
    end) || :error
  end

  defp unread(tight, scale, ink, text, glyphs),
    do: {:unread, to_points(tight, scale), ink, text, glyphs}

  # Shallow first: with no mouse on the widget the label rides at its top.
  defp candidates(map_height, opts) do
    for offset <- -@above..max(map_height - @step, 0)//@step,
        height <- @heights,
        ink <- inks(opts),
        do: {offset, height, ink}
  end

  defp inks(opts) do
    case Keyword.get(opts, :ink) do
      nil -> @ink_floors
      ink -> Enum.uniq([ink | @ink_floors])
    end
  end

  # A candidate does not need to read whole to matter: a resolvable "(" and ")"
  # anchor the text's true columns, and the band tightened onto them (plus a
  # right slack for a longer future coordinate) is what must read. Slack first;
  # if map junk in the slack ruins the read, the tight rectangle wins.
  defp probe(frame, {_x, y, _w, h} = band, margin, ink) do
    glyphs = Glyphs.segment(frame, band, ink: ink)
    atlas = Glyphs.atlas()

    with {:ok, open} <- bracket(glyphs, atlas, "("),
         {:ok, close} <- bracket(glyphs, atlas, ")"),
         true <- close.x1 > open.x0 do
      tight = {max(open.x0 - margin, 0), y, close.x1 - open.x0 + 2 * margin + 1, h}
      rects = [put_elem(tight, 2, elem(tight, 2) + 2 * h), tight]

      Enum.find_value(rects, &read_band(frame, &1, ink)) ||
        Enum.find_value(rects, &shape_band(frame, &1, ink)) || :error
    else
      _no_brackets -> :error
    end
  end

  defp read_band(frame, rect, ink) do
    case Glyphs.read_coord(frame, rect, ink: ink) do
      {_x, _y, _z} = pos -> {:read, rect, pos}
      nil -> nil
    end
  end

  # Both rectangles are asked to READ before either is asked for its shape, so a
  # slack whose map junk only ruins the last character can never beat the tight
  # rectangle that reads the whole line.
  defp shape_band(frame, rect, ink) do
    text = Glyphs.read_line(frame, rect, ink: ink).text

    if Regex.match?(@shape, text),
      do: {:shape, rect, text, Glyphs.segment(frame, rect, ink: ink)},
      else: nil
  end

  defp bracket(glyphs, atlas, char) do
    case Enum.find(glyphs, fn glyph -> Glyphs.lookup(glyph.bitmap, atlas) == char end) do
      nil -> :error
      glyph -> {:ok, glyph}
    end
  end

  defp scale_rect({x, y, w, h}, scale),
    do: {round(x * scale), max(round(y * scale), 0), round(w * scale), round(h * scale)}

  defp to_points({x, y, w, h}, scale),
    do: {round(x / scale), round(y / scale), round(w / scale), round(h / scale)}
end
