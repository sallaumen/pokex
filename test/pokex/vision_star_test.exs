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
    rows = Vision.star_rows(frame!(), bands() ++ [min_cluster: 3])

    assert [{1, run}] = rows
    # measured: five consecutive columns carry 4-7 gold pixels each
    assert run >= 5
  end

  test "the per-row runs separate the shiny from the normal row by a mile" do
    assert [normal, shiny] = Vision.star_row_clusters(frame!(), bands())

    assert normal == 0
    assert shiny >= 5
  end

  test "a threshold above the measured star finds nothing (the tuning knob works)" do
    assert Vision.star_rows(frame!(), bands() ++ [min_cluster: 99]) == []
  end

  test "a battle list full of YELLOW pokémon is not a battle list full of shinies" do
    # The false positive that made this rule necessary: five Magikarps, whose
    # fins are gold. Summing a 3-column window scored them 10 against the real
    # star's 19 — with the threshold at 10, every fish was a shiny.
    {:ok, frame} = Frame.from_png_file("test/fixtures/screen/ultrawide_3440x1440_outro_mapa.png")
    {:ok, fix} = Pokex.Layout.locate(frame)
    {x, y, w, h} = Pokex.Layout.region(:battle_list, fix)
    body = Frame.crop(Frame.crop(frame, {x, y, w, h}), {0, 0, w - 30, h})
    {top, band} = Pokex.Calibration.row_band_geometry(1.0, 46)

    assert Vision.star_rows(body, top: top, band: band, rows: 6) == []
    assert Enum.max(Vision.star_row_clusters(body, top: top, band: band, rows: 6)) <= 2
  end

  test "the red pokeball never reads as a star" do
    # a frame of pure pokeball red (255,28,28) — high R, but G is far too low
    rows = for _y <- 1..40, do: List.duplicate({255, 28, 28, 255}, 60)
    path = Pokex.PngFixtures.write!(Path.join(System.tmp_dir!(), "pokeball_red.png"), rows)
    {:ok, red} = Frame.from_png_file(path)

    assert Vision.star_rows(red, top: 0, band: 20, rows: 2, min_cluster: 3) == []
  end
end
