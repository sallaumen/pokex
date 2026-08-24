defmodule Pokex.Vision.GlyphsCoordChipTest do
  @moduledoc """
  The coordinate as a bare chip: "2944, 2211, 7", no parentheses anywhere.

  The client Lucas moved to on 2026-08-21 draws the minimap position inside a
  fixed UI chip, without the "(x, y, z)" wrapping the reader anchored on — so a
  chip that read perfectly still parsed to nil. Both fixtures are real crops of
  that chip (hand-marked band, 2026-08-24), and their font is one the shipped
  atlas has never seen: each test teaches the glyphs first, which is the same
  bootstrap a fresh installation of that client needs.
  """
  # async: false — teaching writes a learned atlas into a tmp home AND clears
  # the process-wide glyph cache, both global (same reason as GlyphsTeachTest).
  use ExUnit.Case, async: false

  alias Pokex.Vision.{Frame, Glyphs}

  @fixtures [
    {"test/fixtures/screen/coord_chip_bare_2944_2211_7.png", "2944,2211,7", {2944, 2211, 7}},
    {"test/fixtures/screen/coord_chip_bare_2979_2265_5.png", "2979,2265,5", {2979, 2265, 5}}
  ]
  # 120 is the runtime default (minimap_coord_ink) AND the floor that keeps the
  # chip's commas: measured on both fixtures, 170+ drops the two width-2 commas
  # and 240 shatters digits — this chip wants the default, not the PXG hunt floors.
  @ink 120

  describe "parse_coord/1" do
    test "reads the wrapped shape" do
      assert Glyphs.parse_coord("(337, 46107, 4)") == {337, 46_107, 4}
    end

    test "reads the bare shape" do
      assert Glyphs.parse_coord("2944, 2211, 7") == {2944, 2211, 7}
    end

    test "rejects a half-wrapped line" do
      assert Glyphs.parse_coord("(2944, 2211, 7") == nil
      assert Glyphs.parse_coord("2944, 2211, 7)") == nil
    end

    test "rejects lines that are not a coordinate" do
      assert Glyphs.parse_coord("13:37") == nil
      assert Glyphs.parse_coord("2944, 2211") == nil
      assert Glyphs.parse_coord("") == nil
    end
  end

  describe "read_coord/3 on the bare chip" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "pokex-chip-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      Application.put_env(:pokex, :home_dir, tmp)
      Glyphs.clear()

      on_exit(fn ->
        Pokex.TestHome.restore()
        File.rm_rf!(tmp)
        Glyphs.clear()
      end)

      :ok
    end

    test "a taught chip reads whole without parentheses" do
      for {path, chars, expected} <- @fixtures do
        frame = frame!(path)
        band = {0, 0, frame.width, frame.height}
        teach_band(frame, band, chars)

        assert Glyphs.read_coord(frame, band, ink: @ink) == expected
      end
    end
  end

  defp frame!(path) do
    {:ok, frame} = Frame.from_png_file(path)
    frame
  end

  defp teach_band(frame, band, chars) do
    glyphs = frame |> Glyphs.segment(band, ink: @ink) |> Enum.sort_by(& &1.x0)
    expected = String.graphemes(chars)

    assert length(glyphs) == length(expected),
           "segmented #{length(glyphs)} glyphs for #{length(expected)} chars (#{chars})"

    for {glyph, char} <- Enum.zip(glyphs, expected) do
      case Glyphs.teach(Glyphs.signature(glyph.bitmap), char) do
        {:ok, _total} -> :ok
        {:error, :already_known} -> :ok
      end
    end
  end
end
