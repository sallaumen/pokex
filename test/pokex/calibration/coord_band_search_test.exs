defmodule Pokex.Calibration.CoordBandSearchTest do
  @moduledoc """
  The coordinate band used to take 2 precise clicks on a screenshot that could
  not even SHOW the text (the game only draws it under a hovering mouse — and
  during calibration the mouse is in the browser). Lucas marked it blind and
  the real 2026-08-10 band came out 13pt tall, clipped and misplaced. The
  search inverts the burden: given the map rectangle he CAN see, scan candidate
  bands for a readable "(x, y, z)" and let the living proof pick the band.
  """
  use ExUnit.Case, async: true

  alias Pokex.Calibration.CoordBandSearch
  alias Pokex.{Layout, ScreenFixtures}
  alias Pokex.Vision.Frame

  @coords %{
    "ultrawide_3440x1440_full" => {337, 46_107, 4},
    "ultrawide_3440x1440_outro_mapa" => {2782, 30_571, 5},
    "ultrawide_3440x1440_terceiro" => {2777, 30_560, 5},
    "ultrawide_3440x1440_time" => {2597, 30_640, 6}
  }

  test "finds a readable band on every real capture, from the map rectangle alone" do
    for {name, expected} <- @coords do
      frame = ScreenFixtures.frame!(name)
      {:ok, fix} = Layout.locate(frame)
      map = Layout.region(:minimap, fix)

      assert {:ok, band, ^expected, _ink} = CoordBandSearch.search(frame, map, 1.0, ink: 120),
             "não achei a faixa em #{name}"

      # the found band must agree with where the layout knows the strip lives
      {bx, by, bw, bh} = band
      {cx, cy, cw, ch} = Layout.region(:minimap_coord, fix)
      assert by >= cy - 6 and by + bh <= cy + ch + 6, "faixa fora da altura em #{name}"
      assert bx >= cx - 6 and bx <= cx + 12, "faixa fora do x em #{name}"
      assert bw >= div(cw, 2), "faixa estreita demais em #{name}: #{inspect(band)}"
    end
  end

  test "the found band re-reads on its own — the exact rectangle that gets saved" do
    frame = ScreenFixtures.frame!("ultrawide_3440x1440_full")
    {:ok, fix} = Layout.locate(frame)

    {:ok, band, _pos, ink} =
      CoordBandSearch.search(frame, Layout.region(:minimap, fix), 1.0, ink: 120)

    assert Pokex.Vision.Glyphs.read_coord(frame, band, ink: ink) == {337, 46_107, 4}
  end

  test "the hover bar pushes the label deep below the marked top — still found" do
    # Hovering slides a control bar over the map's top ~30pt and the label
    # draws BELOW it, so with the widget marked whole the text sits 30-55pt
    # under the marked top. Simulated on the fixture by describing a map whose
    # top is 40pt above the strip: the label lands at offset +46.
    frame = ScreenFixtures.frame!("ultrawide_3440x1440_full")
    {:ok, fix} = Layout.locate(frame)
    {_cx, cy, _cw, _ch} = Layout.region(:minimap_coord, fix)

    assert {:ok, _band, {337, 46_107, 4}, _ink} =
             CoordBandSearch.search(frame, {3150, cy - 46, 290, 458}, 1.0, ink: 120)
  end

  # The 2026-08-10 field photo, saved whole: the mouse was over the minimap, so
  # the client rendered the CLOCK and pushed the coordinate 83pt down — a
  # different place from where the day-to-day reading looks. Lucas's own
  # validator: a clock in the picture means the mouse is where it must not be,
  # and calibrating from that photo saves the exception.
  test "a hover-state photo is refused by its clock, not calibrated from" do
    {:ok, frame} = Frame.from_png_file("test/fixtures/screen/minimap_hover_widget.png")

    assert CoordBandSearch.search(frame, {0, 0, 259, 231}, 1.0, ink: 120) == :hovered
  end

  # Same photo, the coordinate row alone: over bright terrain the label's own
  # anti-aliasing welds to the map at the taught floor (120) and reads nothing
  # — measured, 45- and 59-column blobs. The sweep searches the FLOOR too, and
  # reports the one that worked so the reader can use the same.
  test "over bright terrain the sweep finds the ink floor that reads" do
    {:ok, frame} = Frame.from_png_file("test/fixtures/screen/minimap_coord_on_terrain.png")

    assert Pokex.Vision.Glyphs.read_coord(frame, {0, 0, 259, 50}, ink: 120) == nil

    assert {:ok, _band, {2671, 30_439, 5}, ink} =
             CoordBandSearch.search(frame, {0, 0, 259, 50}, 1.0, ink: 120)

    assert ink > 120
  end

  test "a map with no coordinate text anywhere answers :error" do
    frame = ScreenFixtures.frame!("ultrawide_3440x1440_full")
    # a textless patch of the same capture posing as the map rectangle
    assert CoordBandSearch.search(frame, {600, 600, 290, 458}, 1.0, ink: 120) == :error
  end

  test "points in, points out: a Retina description searches pixels but answers points" do
    frame = ScreenFixtures.frame!("ultrawide_3440x1440_full")
    {:ok, fix} = Layout.locate(frame)
    {mx, my, mw, mh} = Layout.region(:minimap, fix)

    # the same capture described as a 2x screen: the map is half-sized in
    # points, the probes must land on the SAME pixels, and the band comes back
    # in points — the unit the calibration file speaks
    assert {:ok, {bx, by, _bw, _bh}, {337, 46_107, 4}, _ink} =
             CoordBandSearch.search(
               frame,
               {div(mx, 2), div(my, 2), div(mw, 2), div(mh, 2)},
               2.0,
               ink: 120
             )

    {cx, cy, _cw, _ch} = Layout.region(:minimap_coord, fix)
    assert_in_delta bx, div(cx, 2), 4
    assert_in_delta by, div(cy, 2), 4
  end
end
