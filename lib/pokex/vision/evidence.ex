defmodule Pokex.Vision.Evidence do
  @moduledoc """
  The picture the code actually read, with what it found drawn on it.

  "ainda BEM impreciso" (Lucas, 2026-08-26) about the first proximity reading —
  and there was no way to tell WHY from a number. Four creatures on his screen,
  two counted: was the detector blind, was the anchor in the wrong place, was
  the tile ruler wrong? Three different bugs, one indistinguishable "2".

  So the reading carries its own evidence. Boxes on what it found, a cross on
  the point it measured from, shrunk to something a panel can hold. A miss stops
  being an argument about a compressed screenshot and becomes a thing to look at.

  BMP because this project carries no PNG encoder — the same reason
  `Pokex.Vision.SpriteLibrary` draws its thumbnails this way.
  """

  alias Pokex.Vision.Frame

  @type box :: %{
          x: integer,
          y: integer,
          w: pos_integer,
          h: pos_integer,
          colour: {0..255, 0..255, 0..255}
        }

  @doc """
  `frame` shrunk by `:shrink` (default 4), with each box outlined and a cross at
  each `:marks` point. Coordinates are in FRAME pixels; they are scaled here so
  callers never do the arithmetic twice.
  """
  @spec data_url(Frame.t(), keyword) :: String.t()
  def data_url(%Frame{} = frame, opts \\ []) do
    shrink = max(Keyword.get(opts, :shrink, 4), 1)
    w = max(div(frame.width, shrink), 1)
    h = max(div(frame.height, shrink), 1)

    boxes = Keyword.get(opts, :boxes, []) |> Enum.map(&scale_box(&1, shrink))

    marks =
      Keyword.get(opts, :marks, [])
      |> Enum.map(fn {x, y, c} -> {div(x, shrink), div(y, shrink), c} end)

    bmp(w, h, fn x, y ->
      paint(x, y, boxes, marks) || sample(frame, x * shrink, y * shrink)
    end)
  end

  defp scale_box(box, shrink) do
    %{
      x: div(box.x, shrink),
      y: div(box.y, shrink),
      w: max(div(box.w, shrink), 1),
      h: max(div(box.h, shrink), 1),
      colour: box.colour
    }
  end

  defp sample(%Frame{} = frame, x, y) do
    x = min(x, frame.width - 1)
    y = min(y, frame.height - 1)
    <<r, g, b, _a>> = binary_part(frame.rgba, (y * frame.width + x) * 4, 4)
    {r, g, b}
  end

  # A cross wins over a box outline, and both win over the picture: the marks
  # are the thing being checked.
  defp paint(x, y, boxes, marks) do
    Enum.find_value(marks, fn {mx, my, colour} ->
      if (x == mx and abs(y - my) <= 4) or (y == my and abs(x - mx) <= 4), do: colour
    end) ||
      Enum.find_value(boxes, fn box -> if on_edge?(box, x, y), do: box.colour end)
  end

  defp on_edge?(%{x: bx, y: by, w: bw, h: bh}, x, y) do
    inside_x = x >= bx - 1 and x <= bx + bw
    inside_y = y >= by - 1 and y <= by + bh
    inside_x and inside_y and (x in [bx - 1, bx + bw] or y in [by - 1, by + bh])
  end

  @doc """
  A 24bpp uncompressed BMP data-URL of a `w`×`h` image, `pixel.(x, y)` giving
  `{r, g, b}`. Bottom-up rows, each 4-byte aligned — the format's own rules.
  """
  @spec bmp(pos_integer, pos_integer, (integer, integer -> {0..255, 0..255, 0..255})) ::
          String.t()
  def bmp(w, h, pixel) when is_function(pixel, 2) do
    row_size = div(w * 3 + 3, 4) * 4
    pad = :binary.copy(<<0>>, row_size - w * 3)
    data_size = row_size * h

    rows =
      for y <- (h - 1)..0//-1, into: <<>> do
        row =
          for x <- 0..(w - 1), into: <<>>, do: (fn {r, g, b} -> <<b, g, r>> end).(pixel.(x, y))

        row <> pad
      end

    header =
      <<"BM", 14 + 40 + data_size::little-32, 0::32, 54::little-32, 40::little-32, w::little-32,
        h::little-32, 1::little-16, 24::little-16, 0::little-32, data_size::little-32,
        2835::little-32, 2835::little-32, 0::little-32, 0::little-32>>

    "data:image/bmp;base64," <> Base.encode64(header <> rows)
  end
end
