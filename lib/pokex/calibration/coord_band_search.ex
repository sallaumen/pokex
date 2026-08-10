defmodule Pokex.Calibration.CoordBandSearch do
  @moduledoc """
  Finds the coordinate band by READING, so nobody has to mark it blind.

  The band used to take 2 precise clicks on a screenshot that could not even
  show the text: the game draws "(x, y, z)" only while the mouse hovers the
  minimap, and during calibration the mouse is in the browser. The real
  2026-08-10 hand mark came out 13pt tall, clipped and misplaced — marked from
  memory. Given the map rectangle (which IS always visible) and a shot taken
  under a hover, this module scans candidate bands anchored on the map's top
  edge, looks for a resolvable "(" … ")" bracket pair, tightens the band onto
  it and confirms with a full `read_coord` — the band that gets saved is a
  band that already read a position.

  Everything in POINTS in and out (the unit the calibration file speaks);
  pixels are internal, via `scale`.
  """

  alias Pokex.Vision.{Frame, Glyphs}

  # The label anchors on the map's top-left — but HOVERING redraws the widget:
  # a control bar (clock, lock, book) slides OVER the map's top ~30pt and the
  # label draws BELOW it (Lucas's screenshots, 2026-08-10), so the text can sit
  # 30-55pt under the top of whatever he marked. Downward offsets run deep and
  # first; the shallow negatives cover a band marked above a tight map rect.
  @y_offsets [0, 2, 4, 6, 8, 10, 12, 14, 16] ++
               [20, 24, 28, 32, 36, 40, 44, 48, 52, 56, 60, 64] ++
               [-2, -4, -6, -8, -10, -12, -16, -20, -24]
  # Text measures 15-21 px of glyph rows plus outline; a band shorter than the
  # line clips the bitmaps into strangers. TALLER bands (24/28) are not noise:
  # terrain welded to the text is dropped by how far it OVERSHOOTS the text
  # band, and a short window clips the overshoot below the threshold — the
  # 2026-08-10 fixture only reads once the window is tall enough to show the
  # terrain for what it is.
  @heights [16, 18, 14, 20, 24, 28]
  @margin 2

  @doc """
  `{:ok, band, {x, y, z}}` — the band (points) that already read the position
  on `frame` — or `:error` when no candidate produced a readable coordinate.
  """
  def search(%Frame{} = frame, {mx, my, mw, _mh}, scale, opts \\ []) do
    Enum.find_value(candidates(), fn {offset, height} ->
      band_px = {
        round(mx * scale),
        max(round((my + offset) * scale), 0),
        round(mw * scale),
        round(height * scale)
      }

      case probe(frame, band_px, round(scale * @margin), opts) do
        {:ok, tight_px, pos} -> {:ok, to_points(tight_px, scale), pos}
        :error -> nil
      end
    end) || :error
  end

  defp candidates, do: for(offset <- @y_offsets, height <- @heights, do: {offset, height})

  # A candidate does not need to read whole to matter: a resolvable "(" and ")"
  # anchor the text's true columns, and the band tightened onto them (plus a
  # right slack for a longer future coordinate — "(2782, 30571, 5)" is wider
  # than "(337, 46107, 4)") is what must read. Slack first; if map junk in the
  # slack ruins the read, the tight rectangle wins.
  defp probe(frame, {_x, y, _w, h} = band, margin, opts) do
    glyphs = Glyphs.segment(frame, band, opts)
    atlas = Glyphs.atlas()

    with {:ok, open} <- bracket(glyphs, atlas, "("),
         {:ok, close} <- bracket(glyphs, atlas, ")"),
         true <- close.x1 > open.x0 do
      tight = {max(open.x0 - margin, 0), y, close.x1 - open.x0 + 2 * margin + 1, h}
      slacked = put_elem(tight, 2, elem(tight, 2) + 2 * h)

      Enum.find_value([slacked, tight], &read_band(frame, &1, opts)) || :error
    else
      _no_brackets -> :error
    end
  end

  defp read_band(frame, rect, opts) do
    case Glyphs.read_coord(frame, rect, opts) do
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

  defp to_points({x, y, w, h}, scale),
    do: {round(x / scale), round(y / scale), round(w / scale), round(h / scale)}
end
