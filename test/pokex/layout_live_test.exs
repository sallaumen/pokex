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
      assert {:ok, fix} = Layout.locate(ScreenFixtures.frame!(name)), "did not locate in #{name}"
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

      assert level in 1..999, "unreadable level in #{name}: #{inspect(level)}"
      assert fishing in 1..999, "unreadable fishing in #{name}: #{inspect(fishing)}"
      assert food in 1..99_999, "unreadable food in #{name}: #{inspect(food)}"
      assert f1 in 0..99_999, "unreadable F1 stock in #{name}: #{inspect(f1)}"
      assert %{text: text, confidence: 1.0} = hp
      assert text =~ ~r"^\d+/\d+$", "unreadable HP in #{name}: #{inspect(text)}"

      assert {x, y, z} = Glyphs.read_coord(frame, fix.regions.minimap_coord),
             "posição ilegível em #{name}"

      assert x > 0 and y > 0 and z in 0..15
    end
  end

  # level reads 90, 91, 90 — going DOWN is real, not a misread: dying in PXG
  # costs experience, and the player died between captures two and three.
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

    assert first.hp == "5559/6410"
    assert second.hp == "9300/9300"
    assert third.hp == "8932/9215"
    assert [first.f1, second.f1, third.f1] == [322, 561, 457]
    assert [first.e, second.e, third.e] == [7, 404, 401]

    assert [first.level, second.level, third.level] == [90, 91, 90]
  end

  # a "?" is a glyph the atlas has never seen — the exact failure seen live in the panel
  test "no HUD field comes back unreadable on any real capture" do
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

  # a zero's strokes are strong and its arcs fade; a single ink floor split it into two bars
  test "a zero reads as a single glyph, not two bars" do
    frame = ScreenFixtures.frame!("ultrawide_3440x1440_outro_mapa")
    {:ok, fix} = Layout.locate(frame)

    assert Glyphs.read_int(frame, fix.regions.slot_e, Layout.region_opts(fix, :slot_e)) == 404
  end

  # a template cut from a semi-transparent panel carries the map behind it
  test "every anchor template comes from opaque chrome" do
    assert map_size(Layout.profile()["anchors"]) == 1
    assert Map.has_key?(Layout.profile()["anchors"], "battle_header")
  end
end
