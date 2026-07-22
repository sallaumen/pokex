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

  @captures ["ultrawide_3440x1440_full", "ultrawide_3440x1440_outro_mapa"]

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

  test "he levelled up and restocked between the two captures — the readings follow" do
    reads =
      for name <- @captures do
        frame = ScreenFixtures.frame!(name)
        {:ok, fix} = Layout.locate(frame)

        %{
          level: Glyphs.read_int(frame, fix.regions.level),
          f1: Glyphs.read_int(frame, fix.regions.slot_f1, ink: 200),
          hp: Glyphs.read_line(frame, fix.regions.pokemon_hp).text
        }
      end

    [before, later] = reads

    assert before.level == 90 and later.level == 91
    assert before.f1 == 322 and later.f1 == 561
    assert before.hp == "5559/6410" and later.hp == "9300/9300"
  end

  test "every anchor template must come from OPAQUE chrome" do
    # A template cut from a semi-transparent panel carries the map behind it.
    # There is exactly one anchor left, and this is why.
    assert map_size(Layout.profile()["anchors"]) == 1
    assert Map.has_key?(Layout.profile()["anchors"], "battle_header")
  end
end
