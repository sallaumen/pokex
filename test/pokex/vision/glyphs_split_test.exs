defmodule Pokex.Vision.GlyphsSplitTest do
  @moduledoc """
  Two digits welded by a background bridge used to demand teaching the PAIR:
  Lucas's learned file really carried "04" and "70" as single glyphs — and
  with 100 possible pairs that treadmill never ends. The bridge is a 2-pixel
  crumb the projection cannot see past: it hangs off ONE digit's blob, so no
  column between the digits is ever empty. An unknown glyph WIDER THAN TALL is
  now cut at its faintest interior columns and each half read on its own, with
  ±1 column of width tolerance — the weld eats an anti-aliased edge, so a half
  comes out a column narrower than its standalone self. Both halves must
  resolve, each unambiguously (measured on these real bitmaps: a true half
  lands 0-5 pixels from its character, the nearest OTHER character 35+ away).

  The fixtures are the REAL fused bitmaps from the field, not synthetic welds.
  """
  use ExUnit.Case, async: false

  alias Pokex.PngFixtures
  alias Pokex.Vision.{Frame, Glyphs}

  @fused_04 "0,0,0,0,1,1,1,1,1,0,0,0,0,0,0,0,0,0,0,1,1,1,0,0;0,0,1,1,1,1,1,1,1,1,0,0,0,0,0,0,0,0,1,1,1,1,0,0;0,0,1,1,1,0,0,1,1,1,1,0,0,0,0,0,0,1,1,1,1,1,0,0;0,1,1,1,0,0,0,0,1,1,1,0,0,0,0,0,1,1,1,1,1,1,0,0;0,1,1,1,0,0,0,0,1,1,1,0,0,0,0,0,1,1,0,1,1,1,0,0;0,1,1,0,0,0,0,0,0,1,1,1,0,0,0,1,1,1,0,1,1,1,0,0;1,1,1,0,0,0,0,0,0,1,1,1,0,0,1,1,1,0,0,1,1,1,0,0;1,1,1,0,0,0,0,0,0,1,1,0,0,1,1,1,0,0,0,1,1,1,0,0;1,1,1,0,0,0,0,0,0,1,1,0,1,1,1,0,0,0,0,1,1,1,0,0;0,1,1,0,0,0,0,0,0,1,1,0,1,1,1,1,1,1,1,1,1,1,1,1;0,1,1,1,0,0,0,0,1,1,1,0,1,1,1,1,1,1,1,1,1,1,1,0;0,1,1,1,0,0,0,0,1,1,1,0,0,0,0,0,0,0,0,1,1,1,0,0;0,0,1,1,1,0,0,1,1,1,1,0,0,0,0,0,0,0,0,1,1,1,0,0;0,0,1,1,1,1,1,1,1,1,0,0,0,0,0,0,0,0,0,1,1,1,0,0;0,0,0,0,1,1,1,1,1,0,0,0,0,0,0,0,0,0,0,1,1,1,0,0"
  @fused_70 "1,1,1,1,1,1,1,1,1,1,1,1,0,0,0,0,1,1,1,1,1,0,0,0,0;1,1,1,1,1,1,1,1,1,1,1,1,0,0,0,1,1,1,1,1,1,1,1,0,0;0,0,0,0,0,0,0,0,1,1,1,0,0,0,1,1,1,0,0,0,1,1,1,0,0;0,0,0,0,0,0,0,0,1,1,1,0,0,1,1,1,1,0,0,0,0,1,1,1,0;0,0,0,0,0,0,0,1,1,1,1,0,0,1,1,1,0,0,0,0,0,1,1,1,0;0,0,0,0,0,0,0,1,1,1,0,0,0,1,1,1,0,0,0,0,0,1,1,1,1;0,0,0,0,0,0,1,1,1,1,0,0,0,1,1,1,0,0,0,0,0,0,1,1,1;0,0,0,0,0,0,1,1,1,0,0,0,1,1,1,1,0,0,0,0,0,0,1,1,1;0,0,0,0,0,1,1,1,1,0,0,0,1,1,1,1,0,0,0,0,0,0,1,1,1;0,0,0,0,0,1,1,1,0,0,0,0,1,1,1,1,0,0,0,0,0,0,1,1,1;0,0,0,0,1,1,1,1,0,0,0,0,0,1,1,1,0,0,0,0,0,0,1,1,1;0,0,0,0,1,1,1,0,0,0,0,0,0,1,1,1,0,0,0,0,0,1,1,1,1;0,0,0,1,1,1,1,0,0,0,0,0,0,1,1,1,0,0,0,0,0,1,1,1,0;0,0,0,1,1,1,0,0,0,0,0,0,0,1,1,1,1,0,0,0,0,1,1,1,0;0,0,1,1,1,1,0,0,0,0,0,0,0,0,1,1,1,0,0,0,1,1,1,0,0;0,0,1,1,1,0,0,0,0,0,0,0,0,0,0,1,1,1,1,1,1,1,1,0,0;0,1,1,1,1,0,0,0,0,0,0,0,0,0,0,0,1,1,1,1,1,0,0,0,0"
  # the standalone 17-row "7" Lucas taught this install (17x12 — one column
  # WIDER than the 17x11 left half of the fused "70": the padding path)
  @seven "1,1,1,1,1,1,1,1,1,1,1,1;1,1,1,1,1,1,1,1,1,1,1,1;0,0,0,0,0,0,0,0,1,1,1,0;0,0,0,0,0,0,0,0,1,1,1,0;0,0,0,0,0,0,0,1,1,1,1,0;0,0,0,0,0,0,0,1,1,1,0,0;0,0,0,0,0,0,1,1,1,1,0,0;0,0,0,0,0,0,1,1,1,0,0,0;0,0,0,0,0,1,1,1,1,0,0,0;0,0,0,0,0,1,1,1,0,0,0,0;0,0,0,0,1,1,1,1,0,0,0,0;0,0,0,0,1,1,1,0,0,0,0,0;0,0,0,1,1,1,1,0,0,0,0,0;0,0,0,1,1,1,0,0,0,0,0,0;0,0,1,1,1,1,0,0,0,0,0,0;0,0,1,1,1,0,0,0,0,0,0,0;0,1,1,1,1,0,0,0,0,0,0,0"

  setup do
    tmp = Path.join(System.tmp_dir!(), "pokex-glyphs-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:pokex, :home_dir, tmp)
    Glyphs.clear()

    on_exit(fn ->
      Application.delete_env(:pokex, :home_dir)
      File.rm_rf!(tmp)
      Glyphs.clear()
    end)

    {:ok, tmp: tmp}
  end

  defp decode(signature) do
    signature
    |> String.split(";")
    |> Enum.map(fn row -> row |> String.split(",") |> Enum.map(&String.to_integer/1) end)
  end

  # The bitmap painted white-on-black with a margin, through the real pipeline:
  # PNG -> Frame -> segment -> read. Connectivity and column gaps are exactly
  # the field's — the signature IS the segmented field bitmap.
  defp frame_of(signature, tmp) do
    bitmap = decode(signature)
    margin = 3
    width = length(hd(bitmap)) + margin * 2
    height = length(bitmap) + margin * 2
    black = {0, 0, 0, 255}
    blank = List.duplicate(List.duplicate(black, width), margin)

    body =
      Enum.map(bitmap, fn row ->
        List.duplicate(black, margin) ++
          Enum.map(row, fn
            1 -> {255, 255, 255, 255}
            0 -> black
          end) ++ List.duplicate(black, margin)
      end)

    path = PngFixtures.write!(Path.join(tmp, "fused-#{System.unique_integer([:positive])}.png"), blank ++ body ++ blank)
    {:ok, frame} = Frame.from_png_file(path)
    {frame, {0, 0, width, height}}
  end

  test "the field's fused 04 reads as two digits with no pair taught", %{tmp: tmp} do
    {frame, region} = frame_of(@fused_04, tmp)

    assert [_one_glyph] = Glyphs.segment(frame, region)
    assert %{text: "04", confidence: 1.0} = Glyphs.read_line(frame, region)
    assert Glyphs.unknown_in(frame, region) == []
  end

  test "the fused 70 refuses without a single 7, resolves once ONE character is taught", %{tmp: tmp} do
    {frame, region} = frame_of(@fused_70, tmp)

    # the shipped atlas has no 17-row 7: the left half resolves to nothing
    # (nearest other character is 51 pixels away — far over the ceiling), so
    # the split refuses and the glyph stays honestly teachable
    assert %{text: "?", confidence: +0.0} = Glyphs.read_line(frame, region)
    assert [%{signature: _}] = Glyphs.unknown_in(frame, region)

    # teaching the SINGLE 7 — not the pair — closes it
    assert {:ok, _total} = Glyphs.teach(@seven, "7")
    assert %{text: "70", confidence: 1.0} = Glyphs.read_line(frame, region)
    assert Glyphs.unknown_in(frame, region) == []
  end

  test "an unknown glyph that is not wider than tall is never split", %{tmp: tmp} do
    # a 5x5 noise cross: unknown, square — the split must not even try
    noise = [[1, 0, 0, 0, 1], [0, 1, 0, 1, 0], [0, 0, 1, 0, 0], [0, 1, 0, 1, 0], [1, 0, 0, 0, 1]]
    {frame, region} = frame_of(Glyphs.signature(noise), tmp)

    assert %{text: "?", confidence: +0.0} = Glyphs.read_line(frame, region)
  end
end
