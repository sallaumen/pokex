defmodule Pokex.LayoutLiveTest do
  @moduledoc """
  The layout must survive REALITY, not just the capture it was measured from.

  The bug this exists for: two of the three original anchors were cut from
  SEMI-TRANSPARENT panels (the bottom hotbar and the left HUD), so their pixels
  carried whatever map was behind them. They matched the fixture perfectly and
  matched NOTHING on Lucas's screen once he walked onto different ground — the
  whole HUD read "não localizado" while every test stayed green.

  So: every assertion here runs against BOTH captures — taken hours apart, on
  different maps, with him at a different level and holding different items.
  One capture proves the arithmetic; two prove the robustness.
  """
  use ExUnit.Case, async: true

  alias Pokex.{Layout, ScreenFixtures}
  alias Pokex.Vision.Glyphs

  @captures [
    "ultrawide_3440x1440_full",
    "ultrawide_3440x1440_outro_mapa",
    "ultrawide_3440x1440_terceiro"
  ]

  test "locates on every real capture" do
    for name <- @captures do
      assert {:ok, fix} = Layout.locate(ScreenFixtures.frame!(name)), "não localizou em #{name}"
      assert fix.anchors.battle_header == {3184, 460}
    end
  end

  test "the fixed regions read real values on BOTH captures — no drift" do
    for name <- @captures do
      frame = ScreenFixtures.frame!(name)
      {:ok, fix} = Layout.locate(frame)

      level = Glyphs.read_int(frame, fix.regions.level)
      fishing = Glyphs.read_int(frame, fix.regions.fishing)
      food = Glyphs.read_int(frame, fix.regions.food)
      f1 = Glyphs.read_int(frame, fix.regions.slot_f1, ink: 200)
      hp = Glyphs.read_line(frame, fix.regions.pokemon_hp)

      assert level in 1..999, "level ilegível em #{name}: #{inspect(level)}"
      assert fishing in 1..999, "pesca ilegível em #{name}: #{inspect(fishing)}"
      assert food in 1..99_999, "comida ilegível em #{name}: #{inspect(food)}"
      assert f1 in 0..99_999, "estoque F1 ilegível em #{name}: #{inspect(f1)}"
      assert %{text: text, confidence: 1.0} = hp
      assert text =~ ~r"^\d+/\d+$", "HP ilegível em #{name}: #{inspect(text)}"

      # the position is the cavebot's whole foundation — it must read on both
      assert {x, y, z} = Glyphs.read_coord(frame, fix.regions.minimap_coord),
             "posição ilegível em #{name}"

      assert x > 0 and y > 0 and z in 0..15
    end
  end

  test "the readings track his session across all three captures" do
    reads =
      for name <- @captures do
        frame = ScreenFixtures.frame!(name)
        {:ok, fix} = Layout.locate(frame)

        %{
          level: Glyphs.read_int(frame, fix.regions.level),
          f1: Glyphs.read_int(frame, fix.regions.slot_f1, Layout.region_opts(fix, :slot_f1)),
          e: Glyphs.read_int(frame, fix.regions.slot_e, Layout.region_opts(fix, :slot_e)),
          hp: Glyphs.read_line(frame, fix.regions.pokemon_hp).text
        }
      end

    assert [first, second, third] = reads

    # different pokémon out, different stock, different health — all read
    assert first.hp == "5559/6410"
    assert second.hp == "9300/9300"
    assert third.hp == "8932/9215"
    assert [first.f1, second.f1, third.f1] == [322, 561, 457]
    assert [first.e, second.e, third.e] == [7, 404, 401]

    # The level reads 90, 91, 90 — it goes DOWN, and that is the game, not a
    # misread: dying in PXG costs experience, and Lucas died between the second
    # capture and the third. Worth pinning precisely because a reader who
    # assumes levels only climb would "fix" a correct reading.
    assert [first.level, second.level, third.level] == [90, 91, 90]
  end

  test "no HUD field comes back unreadable on any real capture" do
    # The eye is only useful if it reads what is actually there. A "?" here is
    # a glyph this atlas has never seen — which is what Lucas kept seeing in
    # the panel, and what hysteresis plus the teachable atlas exist to end.
    for name <- @captures do
      frame = ScreenFixtures.frame!(name)
      {:ok, fix} = Layout.locate(frame)

      for region <- [:level, :food, :fishing, :slot_f1, :slot_f2, :slot_e, :slot_s_q] do
        assert %{confidence: 1.0} =
                 Glyphs.read_line(frame, fix.regions[region], Layout.region_opts(fix, region)),
               "#{region} ilegível em #{name}"
      end

      assert %{confidence: 1.0} = Glyphs.read_line(frame, fix.regions.pokemon_hp)
      assert Glyphs.read_coord(frame, fix.regions.minimap_coord)
    end
  end

  test "a zero keeps its curves — the glyph that was breaking in two" do
    # Lucas, reading the teach screen: "acho que o 0 está sendo quebrado em 2".
    # He was right: a zero's strokes are strong and its arcs fade, so a single
    # floor left two bars and no way to tell they were one character.
    frame = ScreenFixtures.frame!("ultrawide_3440x1440_outro_mapa")
    {:ok, fix} = Layout.locate(frame)

    assert Glyphs.read_int(frame, fix.regions.slot_e, Layout.region_opts(fix, :slot_e)) == 404
  end

  test "every anchor template must come from OPAQUE chrome" do
    # A template cut from a semi-transparent panel carries the map behind it.
    # There is exactly one anchor left, and this is why.
    assert map_size(Layout.profile()["anchors"]) == 1
    assert Map.has_key?(Layout.profile()["anchors"], "battle_header")
  end
end
