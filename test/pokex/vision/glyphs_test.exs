defmodule Pokex.Vision.GlyphsTest do
  use ExUnit.Case, async: true

  alias Pokex.ScreenFixtures
  alias Pokex.Vision.Glyphs

  defp label!(expected) do
    Enum.find(ScreenFixtures.labels(), &(&1["expected"] == expected)) ||
      flunk("no label for #{expected}")
  end

  defp segment!(expected) do
    %{"fixture" => f, "region" => [x, y, w, h]} = label = label!(expected)
    Glyphs.segment(ScreenFixtures.frame!(f), {x, y, w, h}, ScreenFixtures.opts(label))
  end

  test "segments 5559/6410 into 9 glyphs, left to right" do
    glyphs = segment!("5559/6410")

    assert length(glyphs) == 9
    assert glyphs == Enum.sort_by(glyphs, & &1.x0)
    assert Enum.all?(glyphs, fn g -> g.bitmap != [] and hd(g.bitmap) != [] end)
  end

  test "every labeled region segments into exactly its character count" do
    for %{"expected" => exp} = label <- ScreenFixtures.labels() do
      %{"fixture" => f, "region" => [x, y, w, h]} = label
      glyphs = Glyphs.segment(ScreenFixtures.frame!(f), {x, y, w, h}, ScreenFixtures.opts(label))
      want = exp |> String.replace(" ", "") |> String.length()

      assert length(glyphs) == want,
             "#{exp}: got #{length(glyphs)} glyphs, want #{want} — the region rect is off"
    end
  end

  test "the ink floor separates text from the bright item sprite behind it" do
    # "322" sits on the red pokeball sprite whose grey highlights pass a loose
    # floor and MERGE with the digits — the per-region floor is what keeps the
    # slot counts readable.
    %{"fixture" => f, "region" => [x, y, w, h]} = label!("322")
    frame = ScreenFixtures.frame!(f)

    assert length(Glyphs.segment(frame, {x, y, w, h}, ink: 200)) == 3
    assert length(Glyphs.segment(frame, {x, y, w, h}, ink: 120)) != 3
  end

  test "reads every labeled region back exactly — the atlas round-trips the real screen" do
    for %{"expected" => exp, "kind" => kind} = label <- ScreenFixtures.labels() do
      %{"fixture" => f, "region" => [x, y, w, h]} = label
      frame = ScreenFixtures.frame!(f)
      region = {x, y, w, h}
      opts = ScreenFixtures.opts(label)

      case kind do
        "int" ->
          assert Glyphs.read_int(frame, region, opts) == String.to_integer(exp), "int #{exp}"

        "coord" ->
          assert Glyphs.read_coord(frame, region, opts) == {337, 46107, 4}

        "line" ->
          assert %{text: ^exp, confidence: 1.0} = Glyphs.read_line(frame, region, opts),
                 "line #{exp}"
      end
    end
  end

  test "an unknown glyph degrades confidence and never yields an int" do
    noise =
      Pokex.FrameFixtures.of(30, 16, fn x, y ->
        if rem(x * y, 3) == 0, do: {255, 255, 255}, else: {0, 0, 0}
      end)

    assert Glyphs.read_int(noise, {0, 0, 30, 16}) == nil
    assert %{confidence: c} = Glyphs.read_line(noise, {0, 0, 30, 16})
    assert c < 1.0
  end

  describe "lexicon closing" do
    @lexicon ["Pidgeot", "Pidgey", "Seadra", "Shiny Seadra", "Kingler"]

    test "an exact read passes straight through" do
      assert Glyphs.closest_name("Pidgeot", @lexicon) == "Pidgeot"
    end

    test "an unread glyph is closed by the lexicon" do
      assert Glyphs.closest_name("Pi?geot", @lexicon) == "Pidgeot"
      assert Glyphs.closest_name("S?adra", @lexicon) == "Seadra"
      assert Glyphs.closest_name("King?er", @lexicon) == "Kingler"
    end

    test "the glyph COUNT is evidence: a same-length name beats a longer one" do
      # 6 glyphs were segmented, so a 6-letter name fits and a 7-letter one costs
      # an extra insertion — Pidgey wins over Pidgeot on length alone.
      assert Glyphs.closest_name("Pidge?", @lexicon) == "Pidgey"
    end

    test "a real tie yields nil — a wrong name is worse than no name" do
      assert Glyphs.closest_name("Se?dra", ["Seadra", "Sendra"]) == nil
    end

    test "a mostly-unread region never resolves to a name of convenient length" do
      # "???????????" is 11 unknown glyphs; without this guard it would happily
      # become "Shiny Seadra" (12 chars) — a confident lie built from nothing.
      assert Glyphs.closest_name("???????????", @lexicon) == nil
      assert Glyphs.closest_name("Sea???", ["Seadra", "Sealeo"]) == nil
    end

    test "garbage and out-of-lexicon readings yield nil" do
      assert Glyphs.closest_name("???????????", @lexicon) == nil
      assert Glyphs.closest_name("Charizard", @lexicon) == nil
    end

    test "read_name reads Pidgeot off the real battle list" do
      %{"fixture" => f, "region" => [x, y, w, h]} = label!("Pidgeot")

      assert Glyphs.read_name(ScreenFixtures.frame!(f), {x, y, w, h}, Pokex.Pokedex.names()) ==
               "Pidgeot"
    end
  end

  test "coloured bars are never ink — only neutral text is" do
    # the HP bar is (100,240,100): bright, but far from neutral
    green = Pokex.FrameFixtures.of(40, 12, fn _x, _y -> {100, 240, 100} end)
    assert Glyphs.segment(green, {0, 0, 40, 12}) == []
  end
end
