defmodule Pokex.Vision.EvidenceTest do
  @moduledoc """
  The picture the code read, with its findings drawn on.

  It exists because a number could not say WHICH thing was wrong: four hostiles
  on his screen and a reading of two is the detector being blind, or the anchor
  in the wrong place, or the tile ruler off — three bugs, one "2".
  """
  use ExUnit.Case, async: true

  alias Pokex.Vision.{Evidence, Frame}

  defp flat(w, h, colour) do
    %Frame{width: w, height: h, rgba: for(_ <- 1..(w * h), into: <<>>, do: colour), scale: 1.0}
  end

  defp decode("data:image/bmp;base64," <> b64), do: Base.decode64!(b64)

  # BMP rows run BOTTOM-UP and are padded to 4 bytes, which is exactly the kind
  # of detail a hand-rolled encoder gets wrong silently.
  defp pixel(bmp, w, h, x, y) do
    row_size = div(w * 3 + 3, 4) * 4
    <<b, g, r>> = binary_part(bmp, 54 + (h - 1 - y) * row_size + x * 3, 3)
    {r, g, b}
  end

  test "a browser gets a real BMP, the right size" do
    bmp = flat(40, 20, <<10, 20, 30, 255>>) |> Evidence.data_url(shrink: 1) |> decode()

    assert <<"BM", _size::little-32, 0::32, 54::little-32, 40::little-32, 40::little-32,
             20::little-32, 1::little-16, 24::little-16, _rest::binary>> = bmp
  end

  test "the picture survives the trip, top row and all" do
    bmp = flat(8, 4, <<10, 20, 30, 255>>) |> Evidence.data_url(shrink: 1) |> decode()

    assert pixel(bmp, 8, 4, 0, 0) == {10, 20, 30}
    assert pixel(bmp, 8, 4, 7, 3) == {10, 20, 30}
  end

  test "shrinking divides both sides" do
    bmp = flat(40, 20, <<10, 20, 30, 255>>) |> Evidence.data_url(shrink: 4) |> decode()

    assert <<"BM", _::little-32, 0::32, 54::little-32, 40::little-32, 10::little-32, 5::little-32,
             _rest::binary>> = bmp
  end

  test "a box is drawn as an OUTLINE, so what it frames stays visible" do
    url =
      flat(20, 20, <<0, 0, 0, 255>>)
      |> Evidence.data_url(shrink: 1, boxes: [%{x: 5, y: 5, w: 6, h: 6, colour: {0, 220, 255}}])

    bmp = decode(url)

    assert pixel(bmp, 20, 20, 4, 8) == {0, 220, 255}
    assert pixel(bmp, 20, 20, 11, 8) == {0, 220, 255}
    # …and the middle is untouched: a filled box would hide the very thing he
    # opened the picture to look at.
    assert pixel(bmp, 20, 20, 8, 8) == {0, 0, 0}
  end

  test "a mark is a cross at the point, not a dot to hunt for" do
    url =
      flat(20, 20, <<0, 0, 0, 255>>)
      |> Evidence.data_url(shrink: 1, marks: [{10, 10, {255, 0, 255}}])

    bmp = decode(url)

    assert pixel(bmp, 20, 20, 10, 10) == {255, 0, 255}
    assert pixel(bmp, 20, 20, 13, 10) == {255, 0, 255}
    assert pixel(bmp, 20, 20, 10, 13) == {255, 0, 255}
    assert pixel(bmp, 20, 20, 13, 13) == {0, 0, 0}
  end

  test "boxes and marks are given in FRAME pixels and shrink with the picture" do
    url =
      flat(40, 40, <<0, 0, 0, 255>>)
      |> Evidence.data_url(shrink: 4, boxes: [%{x: 20, y: 20, w: 8, h: 8, colour: {0, 220, 255}}])

    # The box was asked for at frame (20,20); at shrink 4 its edge lands at 4.
    assert pixel(decode(url), 10, 10, 4, 6) == {0, 220, 255}
  end
end
