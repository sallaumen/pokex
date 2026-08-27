defmodule Pokex.Calibration.CoordBandSearchTest do
  @moduledoc """
  The coordinate band used to take 2 precise clicks on a screenshot that could
  not even SHOW the text (the game only draws it under a hovering mouse — and
  during calibration the mouse is in the browser). Lucas marked it blind and
  the real 2026-08-10 band came out 13pt tall, clipped and misplaced. The
  search inverts the burden: given the map rectangle he CAN see, scan candidate
  bands for a readable "(x, y, z)" and let the living proof pick the band.
  """
  # Not async: teaching a glyph moves the home AND drops the cached atlas, both
  # global — a test reading glyphs beside it would see this file's atlas.
  use ExUnit.Case, async: false

  alias Pokex.Calibration.CoordBandSearch
  alias Pokex.{Layout, ScreenFixtures}
  alias Pokex.Vision.{Frame, Glyphs}

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

      assert {:ok, band, ^expected, _ink, _text, _glyphs} =
               CoordBandSearch.search(frame, map, 1.0, ink: 120),
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

    {:ok, band, _pos, ink, _text, _glyphs} =
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

    assert {:ok, _band, {337, 46_107, 4}, _ink, _text, _glyphs} =
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

    assert {:ok, _band, {2671, 30_439, 5}, ink, _text, _glyphs} =
             CoordBandSearch.search(frame, {0, 0, 259, 50}, 1.0, ink: 120)

    assert ink > 120
  end

  # 2026-08-17, the region Lucas came here to hunt: every Y is 308xx, so every
  # coordinate on this map carries an 8 — and the 8 of THIS render lands 19
  # pixels from the atlas's, one over the 18-pixel ceiling. The sweep found the
  # right band, segmented all 14 glyphs and read 13 of them, then threw the band
  # away because `read_coord` demands a perfect line. Calibration became
  # impossible on the one screen that needed teaching, and teaching needs a
  # calibrated band: a closed loop with no door.
  describe "a band whose shape is proven but whose glyphs are not all known" do
    setup do
      {:ok, frame} = Frame.from_png_file("test/fixtures/screen/minimap_coord_unknown_digit.png")
      %{frame: frame, map: {0, 0, 262, 50}}
    end

    test "answers :unread with the band, the partial line and the glyphs", ctx do
      assert {:unread, band, ink, text, glyphs} =
               CoordBandSearch.search(ctx.frame, ctx.map, 1.0, ink: 170)

      assert text == "(2310, 30?04, 6)"
      assert length(glyphs) == 14
      assert ink == 170

      {bx, by, bw, bh} = band
      assert by >= 0 and by + bh <= 50
      assert bx >= 0 and bw >= 100
    end

    test "reads whole once the single unknown glyph is named", ctx do
      {:unread, _band, ink, _text, glyphs} =
        CoordBandSearch.search(ctx.frame, ctx.map, 1.0, ink: 170)

      teach_line(glyphs, "(2310,30804,6)")

      assert {:ok, _band, {2310, 30_804, 6}, ^ink, _text, _glyphs} =
               CoordBandSearch.search(ctx.frame, ctx.map, 1.0, ink: 170)
    end
  end

  test "a line that reads whole wins over one that only has the shape" do
    frame = ScreenFixtures.frame!("ultrawide_3440x1440_full")
    {:ok, fix} = Layout.locate(frame)

    assert {:ok, _band, {337, 46_107, 4}, _ink, _text, _glyphs} =
             CoordBandSearch.search(frame, Layout.region(:minimap, fix), 1.0, ink: 120)
  end

  defp teach_line(glyphs, line) do
    home = Path.join(System.tmp_dir!(), "pokex_teach_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    Application.put_env(:pokex, :home_dir, home)

    on_exit(fn ->
      Pokex.TestHome.restore()
      Glyphs.clear()
      File.rm_rf!(home)
    end)

    glyphs
    |> Enum.zip(String.graphemes(line))
    |> Enum.each(&Glyphs.teach(Glyphs.signature(elem(&1, 0).bitmap), elem(&1, 1)))

    Glyphs.clear()
  end

  # His real widget on 2026-08-24, in the client he moved to: the position is
  # printed BARE ("3015, 2213, 7"), with no parentheses for the old anchoring to
  # hold on to, and a clock chip sits permanently 50pt to its right — on the
  # SAME row, which in the old client only ever happened under a hovering mouse.
  describe "the bare chip, with a clock beside it" do
    # Not even the punctuation of this render is in the shipped atlas, and the
    # shape needs its commas read: this is the same bootstrap the wrapped path
    # has always had, one render deeper.
    @chip {14, 24, 70, 22}

    setup do
      {:ok, frame} = Frame.from_png_file("test/fixtures/screen/minimap_widget_bare_chip.png")
      %{frame: frame, map: {0, 0, 195, 248}}
    end

    test "proximity finds the label with no brackets to anchor on", ctx do
      teach_chip(ctx.frame, "3015,2213,7")

      assert {:ok, band, {3015, 2213, 7}, ink, _text, _glyphs} =
               CoordBandSearch.search(ctx.frame, ctx.map, 1.0, ink: 120)

      assert Glyphs.read_coord(ctx.frame, band, ink: ink) == {3015, 2213, 7}
    end

    # The saved band keeps a right slack so a longer coordinate still fits it
    # tomorrow — but the slack stops short of the clock, whose leftmost glyph
    # stands at x=130 in this fixture.
    test "the band grows toward the clock and stops before it", ctx do
      teach_chip(ctx.frame, "3015,2213,7")

      assert {:ok, {bx, _by, bw, _bh} = band, _pos, _ink, _text, _glyphs} =
               CoordBandSearch.search(ctx.frame, ctx.map, 1.0, ink: 120)

      assert bx + bw < 130, "a faixa alcançou o relógio: #{inspect(band)}"
      assert bw > 80, "a faixa não deixou folga para uma coordenada maior: #{inspect(band)}"
    end

    test "a clock on the label's own row is furniture, not the hover state", ctx do
      teach_chip(ctx.frame, "3015,2213,7")

      refute CoordBandSearch.search(ctx.frame, ctx.map, 1.0, ink: 120) == :hovered
    end

    # 2026-08-24, live: the setting still carried the 170 the OLD client's bright
    # terrain needed, and at that floor this chip's two-pixel commas are not
    # there — no commas, no shape, and the assistant answered "não achei" on a
    # label anyone could read. The sweep has to be able to leave the floor it
    # was handed, and to report the one that worked so it gets saved.
    test "recovers from an ink floor inherited from another render", ctx do
      teach_chip(ctx.frame, "3015,2213,7")

      assert Glyphs.read_coord(ctx.frame, {14, 24, 108, 22}, ink: 170) == nil

      assert {:ok, _band, {3015, 2213, 7}, 120, _text, _glyphs} =
               CoordBandSearch.search(ctx.frame, ctx.map, 1.0, ink: 170)
    end

    # The door out of the closed loop, on a render where only the punctuation is
    # known: two commas with digit runs between them prove the rectangle, and
    # the digits get named from the answer to "what number is on your screen?".
    test "with only its commas named the shape still answers :unread", ctx do
      teach_chip(ctx.frame, "3015,2213,7", only: [4, 9])

      assert {:unread, _band, _ink, text, glyphs} =
               CoordBandSearch.search(ctx.frame, ctx.map, 1.0, ink: 120)

      assert text == "????, ????, ?"
      assert length(glyphs) == 11
    end

    defp teach_chip(frame, line, opts \\ []) do
      only = Keyword.get(opts, :only)
      keep = fn index -> only == nil or index in only end

      glyphs =
        frame
        |> Glyphs.segment(@chip, ink: 120)
        |> Enum.sort_by(& &1.x0)
        |> Enum.with_index()
        |> Enum.filter(fn {_glyph, index} -> keep.(index) end)
        |> Enum.map(&elem(&1, 0))

      chars =
        line
        |> String.graphemes()
        |> Enum.with_index()
        |> Enum.filter(fn {_char, index} -> keep.(index) end)
        |> Enum.map_join("", &elem(&1, 0))

      teach_line(glyphs, chars)
    end
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
    assert {:ok, {bx, by, _bw, _bh}, {337, 46_107, 4}, _ink, _text, _glyphs} =
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
