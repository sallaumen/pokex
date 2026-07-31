defmodule Pokex.Vision.GlyphsMinimapTest do
  @moduledoc """
  The minimap coordinate flickered for two measured reasons: the atlas never
  learned the coordinate font's "9" (`read_coord/3` demands confidence 1.0, so
  any position containing a 9 read nil), and the greyscale map's walkable
  ground (measured 140..159) passes the ink floor 120, so lit ground scrolling
  into the band's margin rows left no empty columns and column-gap segmentation
  welded the whole coordinate into a single glyph.
  """
  use ExUnit.Case, async: true

  alias Pokex.{Layout, ScreenFixtures}
  alias Pokex.Vision.{Frame, Glyphs}

  # "(2777, 30560, 5)" is 16 characters, 2 of which are spaces drawing no ink:
  # 14 glyphs. This is what used to collapse into 1.
  @coord_glyphs 14
  @captures [
    "ultrawide_3440x1440_full",
    "ultrawide_3440x1440_outro_mapa",
    "ultrawide_3440x1440_terceiro",
    "ultrawide_3440x1440_time"
  ]

  describe "the 9 the atlas was missing" do
    test "reads the coordinate of the capture that contains a 9" do
      frame = ScreenFixtures.frame!("ultrawide_3440x1440_time")
      {:ok, fix} = Layout.locate(frame)

      assert Glyphs.read_coord(frame, fix.regions.minimap_coord) == {2597, 30640, 6}
    end

    test "none of the four real captures leaves an unknown glyph in the coordinate" do
      for name <- @captures do
        frame = ScreenFixtures.frame!(name)
        {:ok, fix} = Layout.locate(frame)

        assert %{confidence: 1.0} = Glyphs.read_line(frame, fix.regions.minimap_coord),
               "coordenada ilegível em #{name}"

        assert Glyphs.unknown_in(frame, fix.regions.minimap_coord) == [],
               "sobrou glifo desconhecido na coordenada de #{name}"
      end
    end
  end

  describe "lit map behind the coordinate" do
    # The game draws the coordinate at a fixed point and scrolls the map under
    # it. The scenario transplants this capture's own lit ground (measured
    # 140..159, neutral) onto the margin rows above the text — exactly what
    # appears after walking a few steps. Nothing is synthesized.
    setup do
      frame = ScreenFixtures.frame!("ultrawide_3440x1440_terceiro")
      {:ok, fix} = Layout.locate(frame)
      {px, py, pw, ph} = fix.regions.minimap
      {cx, cy, cw, _ch} = fix.regions.minimap_coord

      panel = Frame.crop(frame, {px, py, pw, ph})
      # the densest lit-ground patch of this minimap outside the coordinate
      # band — measured, not eyeballed
      lit = Frame.crop(frame, {3260, 192, cw, 4})

      %{
        panel: paste(panel, lit, {cx - px, cy - py}),
        band: {cx - px, cy - py, cw, 30},
        clean: panel
      }
    end

    test "the transplanted patch really is lit ground — ink under the current criterion", ctx do
      %{panel: panel, band: {bx, by, bw, _}} = ctx

      inked =
        Enum.count(bx..(bx + bw - 1), fn i ->
          Enum.any?(by..(by + 3), fn j ->
            {r, g, b} = Frame.at(panel, i, j)
            lo = min(r, min(g, b))
            max(r, max(g, b)) - lo <= 60 and lo >= 120
          end)
        end)

      assert inked > div(bw, 2),
             "só #{inked} de #{bw} colunas receberam tinta do mapa — o cenário não reproduz a falha"
    end

    test "the coordinate still segments into characters, not one blob", ctx do
      glyphs = Glyphs.segment(ctx.panel, ctx.band)

      assert length(glyphs) == @coord_glyphs,
             "a segmentação soldou os caracteres: #{length(glyphs)} glifos"

      assert Enum.all?(glyphs, &(&1.x1 - &1.x0 + 1 <= 14)),
             "algum glifo saiu largo demais para ser um caractere: " <>
               inspect(Enum.map(glyphs, &(&1.x1 - &1.x0 + 1)))
    end

    test "still reads the same position it reads with the dark map", ctx do
      assert Glyphs.read_coord(ctx.clean, ctx.band) == {2777, 30560, 5}
      assert Glyphs.read_coord(ctx.panel, ctx.band) == {2777, 30560, 5}
    end

    test "the teach-glyphs screen does not offer the blob as learnable", ctx do
      assert Glyphs.unknown_in(ctx.panel, ctx.band) == []
    end
  end

  describe "background rules" do
    # crumbs of 2-3px used to show up on the teach screen between digits
    test "a stray crumb between two digits does not weld them together" do
      frame = ScreenFixtures.frame!("ultrawide_3440x1440_terceiro")
      {:ok, fix} = Layout.locate(frame)
      {px, py, pw, ph} = fix.regions.minimap
      {cx, cy, cw, _} = fix.regions.minimap_coord
      panel = Frame.crop(frame, {px, py, pw, ph})
      band = {cx - px, cy - py, cw, 30}

      [_open, first, second | _] = Glyphs.segment(panel, band)
      gap = div(first.x1 + second.x0, 2)

      speckled = poke(panel, [{gap, 12}, {gap, 13}])

      assert length(Glyphs.segment(speckled, band)) == length(Glyphs.segment(panel, band))
    end

    # the dot of Sceptile's "i" is a separate blob outside the other letters'
    # band; discarding it would change a glyph the atlas knows
    test "a glyph's dot is not thrown away with the background" do
      frame = ScreenFixtures.frame!("ultrawide_3440x1440_outro_mapa")

      assert %{text: "Sceptile", confidence: 1.0} =
               Glyphs.read_line(frame, {3223, 547, 132, 21})
    end
  end

  defp paste(%Frame{} = frame, %Frame{} = patch, {x, y}) do
    rgba =
      for j <- 0..(patch.height - 1)//1, reduce: frame.rgba do
        acc ->
          line = binary_part(patch.rgba, j * patch.width * 4, patch.width * 4)
          at = ((y + j) * frame.width + x) * 4
          size = byte_size(line)
          <<head::binary-size(at), _old::binary-size(size), tail::binary>> = acc
          <<head::binary, line::binary, tail::binary>>
      end

    %Frame{frame | rgba: rgba}
  end

  defp poke(%Frame{} = frame, points) do
    rgba =
      Enum.reduce(points, frame.rgba, fn {x, y}, acc ->
        at = (y * frame.width + x) * 4
        <<head::binary-size(at), _old::binary-size(4), tail::binary>> = acc
        <<head::binary, 255, 255, 255, 255, tail::binary>>
      end)

    %Frame{frame | rgba: rgba}
  end
end
