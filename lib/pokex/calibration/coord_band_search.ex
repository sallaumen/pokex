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

  @type found :: {:ok, {integer, integer, integer, integer}, {integer, integer, integer}, integer}

  @doc """
  `{:ok, band, {x, y, z}, ink}` — the band (points) and the ink floor that
  already read the position on `frame` — `:hovered` when the picture shows the
  minimap's hover state (mouse over the widget, wrong state to calibrate), or
  `:error` when nothing readable was found.
  """
  @spec search(Frame.t(), {integer, integer, integer, integer}, number, keyword) ::
          found | :hovered | :error
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

  defp sweep(frame, {mx, my, mw, mh}, scale, opts) do
    Enum.find_value(candidates(mh, opts), fn {offset, height, ink} ->
      band = scale_rect({mx, my + offset, mw, height}, scale)

      case probe(frame, band, round(scale * @margin), ink) do
        {:ok, tight, pos} -> {:ok, to_points(tight, scale), pos, ink}
        :error -> nil
      end
    end) || :error
  end

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
      slacked = put_elem(tight, 2, elem(tight, 2) + 2 * h)

      Enum.find_value([slacked, tight], &read_band(frame, &1, ink)) || :error
    else
      _no_brackets -> :error
    end
  end

  defp read_band(frame, rect, ink) do
    case Glyphs.read_coord(frame, rect, ink: ink) do
      {_x, _y, _z} = pos -> {:ok, rect, pos}
      nil -> nil
    end
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
