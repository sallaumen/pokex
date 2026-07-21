defmodule Pokex.VisionStarTest do
  use ExUnit.Case, async: true

  alias Pokex.Vision
  alias Pokex.Vision.Frame

  # Lucas's REAL battle list (2026-07-21): row 0 = Wigglytuff (normal, with the
  # quest pokeball), row 1 = Shiny Seadra (gold ★ before the name). This is the
  # ground truth the star detector is tuned against — if PXG ever restyles the
  # list, this test breaks loudly instead of the bot silently going blind.
  @fixture "test/fixtures/battle/shiny_star_list.png"

  # the two rows of the real capture: 95px tall, ~47px per row
  defp bands, do: [top: 8, band: 47, rows: 2]

  defp frame! do
    {:ok, frame} = Frame.from_png_file(@fixture)
    frame
  end

  test "finds the star ONLY on the shiny's row" do
    rows = Vision.star_rows(frame!(), bands() ++ [min_cluster: 10])

    assert [{1, cluster}] = rows
    # measured: the glyph packs 15+ gold px into its densest 3 columns
    assert cluster >= 15
  end

  test "the per-row clusters separate the shiny from the normal row by a mile" do
    assert [normal, shiny] = Vision.star_row_clusters(frame!(), bands())

    # The non-shiny row reads ~0: the only gold near it is the topmost pixel of
    # the star BELOW, clipped in by the band boundary (the row height here is a
    # test-chosen approximation of the live geometry). One stray pixel against
    # the glyph's 15+ is exactly why DENSITY, not presence, is the rule.
    assert normal <= 2
    assert shiny >= 15
    assert shiny > normal * 5
  end

  test "a threshold above the measured star finds nothing (the tuning knob works)" do
    assert Vision.star_rows(frame!(), bands() ++ [min_cluster: 999]) == []
  end

  test "the red pokeball never reads as a star" do
    # a frame of pure pokeball red (255,28,28) — high R, but G is far too low
    rows = for _y <- 1..40, do: List.duplicate({255, 28, 28, 255}, 60)
    path = Pokex.PngFixtures.write!(Path.join(System.tmp_dir!(), "pokeball_red.png"), rows)
    {:ok, red} = Frame.from_png_file(path)

    assert Vision.star_rows(red, top: 0, band: 20, rows: 2, min_cluster: 10) == []
  end
end
