defmodule Pokex.Vision.GlyphsRealMinimapTest do
  @moduledoc """
  His real minimap, as the feed captured it during a hunt on 2026-08-12.

  "ele tá perdendo a posição nessa coordenada" — and the measurement said
  something worse than losing it. The band on screen read `(3415, 30964, 2)`
  and this reader answered `(3418, 30963, 3)`: three digits wrong, **with
  `confidence: 1.0`**.

  Not one glyph was an atlas hit. Every character came from `nearest/1`, whose
  slack at this render is wide enough to confuse 5 with 8 and 2 with 3 — and
  the z digit is the one the stairs depend on. The old confidence counted
  "did I produce a character", which a guess always does, so nothing anywhere
  could tell a read from a guess.
  """
  # async: false — the teach test writes a learned atlas into a tmp home AND
  # clears the process-wide glyph cache, both global. Left async it moved the
  # ground under whatever else was running: the screen-mismatch strip read an
  # empty home and reported a different screen (measured, consistently).
  use ExUnit.Case, async: false

  alias Pokex.Vision.{Frame, Glyphs}

  # The band inside this frame, from his own calibration: the coord region
  # offset by the minimap region's origin (the feed captures their union).
  @band {7, 0, 206, 26}
  @ink 170

  setup do
    {:ok, frame} = Frame.from_file("test/support/fixtures/minimap_real.raw")
    %{frame: frame}
  end

  test "the whole coordinate is GUESSED, and the reader now says so", %{frame: frame} do
    read = Glyphs.read_line(frame, @band, ink: @ink)

    # every glyph produced a character...
    assert read.confidence == 1.0
    # ...and not one of them was actually known
    assert read.guessed == 14
    assert read.text =~ ~r/^\(\d+, \d+, \d+\)$/
  end

  # The teach page asked "what can you not read?", to which the answer was
  # "nothing" — so it offered him nothing while every digit was a coin flip.
  test "the teach surface offers the guessed glyphs, not only the illegible ones", %{
    frame: frame
  } do
    uncertain = Glyphs.uncertain_in(frame, @band, ink: @ink)
    illegible = Glyphs.unknown_in(frame, @band, ink: @ink)

    assert length(uncertain) >= 10
    assert illegible == []

    # each carries what it WOULD have answered, so he confirms instead of typing
    assert Enum.all?(uncertain, &(&1.guess != nil))
    assert Enum.all?(uncertain, &(&1.signature != ""))
    refute Enum.any?(uncertain, & &1.exact?)
  end

  # Teaching one is what turns a guess into knowledge — and it is the fix for
  # this whole class, since the atlas simply had never seen this render.
  @tag :tmp_dir
  test "a taught glyph stops being uncertain", %{frame: frame, tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)

    on_exit(fn ->
      Application.delete_env(:pokex, :home_dir)
      Glyphs.clear()
    end)

    Glyphs.clear()
    [first | _] = Glyphs.uncertain_in(frame, @band, ink: @ink)
    before = length(Glyphs.uncertain_in(frame, @band, ink: @ink))

    assert {:ok, _count} = Glyphs.teach(first.signature, first.guess)

    assert length(Glyphs.uncertain_in(frame, @band, ink: @ink)) == before - 1
  end

  test "reading it does not crash on a real capture", %{frame: frame} do
    assert frame.width == 262
    assert frame.height == 228
    assert {_x, _y, _z} = Glyphs.read_coord(frame, @band, ink: @ink)
  end
end
