defmodule Pokex.Vision.CreatureMarksTest do
  use ExUnit.Case, async: true

  alias Pokex.FrameFixtures
  alias Pokex.Vision.{CreatureMarks, Frame}

  @tile 151
  @sand {224, 192, 128}
  @black {0, 0, 0}
  @green {0, 188, 0}
  @white {255, 255, 255}

  # Paints the game's health bar as measured on his client: a 27×4 black
  # rectangle whose 25×2 interior is `fill` columns of ink from the left and
  # black after. Optional skull above and number box below.
  defp scene(w, h, bars) do
    FrameFixtures.of(w, h, fn x, y -> Enum.find_value(bars, @sand, &paint(&1, x, y)) end)
  end

  defp paint(bar, x, y) do
    cond do
      on_bar?(bar, x, y) -> bar_pixel(bar, x, y)
      on_skull?(bar, x, y) -> @white
      on_box?(bar, x, y) -> @black
      true -> nil
    end
  end

  defp on_bar?(%{x: bx, y: by}, x, y), do: x >= bx and x < bx + 27 and y >= by and y < by + 4

  # Interior columns are ink up to `fill`, black after; the border is black.
  defp bar_pixel(%{x: bx, y: by} = bar, x, y) do
    inside_x = x - bx - 1
    inside_y = y - by - 1
    filled? = inside_x in 0..24 and inside_y in 0..1 and inside_x < Map.get(bar, :fill, 25)

    if filled?, do: Map.get(bar, :ink, @green), else: @black
  end

  defp on_skull?(%{x: bx, y: by} = bar, x, y) do
    Map.get(bar, :skull?, false) and x in (bx + 6)..(bx + 21) and y in (by - 30)..(by - 15)
  end

  defp on_box?(%{x: bx, y: by} = bar, x, y) do
    Map.get(bar, :box?, false) and x in (bx - 25)..(bx + 51) and y in (by + 3)..(by + 18)
  end

  describe "a full health bar on bare ground" do
    test "is one mark at the bar's centre with 100% health" do
      frame = scene(200, 120, [%{x: 60, y: 50}])

      assert [%{point: {73, 52}, hp_pct: 100, skull?: false, pet?: false}] =
               CreatureMarks.find(frame, tile_px: @tile)
    end
  end

  describe "health" do
    test "the fill length is the health" do
      frame = scene(200, 120, [%{x: 60, y: 50, fill: 12}])
      assert [%{hp_pct: 48}] = CreatureMarks.find(frame, tile_px: @tile)
    end

    test "one column of red ink is a creature nearly dead, not nothing" do
      frame = scene(200, 120, [%{x: 60, y: 50, fill: 1, ink: {200, 30, 30}}])
      assert [%{hp_pct: 4}] = CreatureMarks.find(frame, tile_px: @tile)
    end

    test "a black rectangle with no ink is not a creature" do
      frame = scene(200, 120, [%{x: 60, y: 50, fill: 0}])
      assert CreatureMarks.find(frame, tile_px: @tile) == []
    end
  end

  describe "signatures" do
    test "a skull above the bar marks the heavy monster" do
      frame = scene(200, 120, [%{x: 60, y: 50, skull?: true}])
      assert [%{skull?: true, pet?: false}] = CreatureMarks.find(frame, tile_px: @tile)
    end

    test "a number box under the bar marks his own pokemon" do
      frame = scene(200, 120, [%{x: 60, y: 50, box?: true}])
      assert [%{pet?: true, skull?: false}] = CreatureMarks.find(frame, tile_px: @tile)
    end
  end

  describe "the ruler" do
    test "sizes scale with the tile" do
      assert %{bar_w: 27, bar_h: 4, box_w: 54, skull_px: 118} = CreatureMarks.geometry(151)
      assert %{bar_w: 54, bar_h: 8, box_w: 108, skull_px: 472} = CreatureMarks.geometry(302)
    end

    test "a bar drawn at a doubled tile is found with the doubled ruler and not with the reference" do
      # 54×8 rectangle, 52×6 interior, 30 of 52 columns filled
      frame =
        FrameFixtures.of(200, 120, fn x, y ->
          if x in 60..113 and y in 50..57 do
            if x in 61..112 and y in 51..56 and x - 61 < 30, do: @green, else: @black
          else
            @sand
          end
        end)

      assert [%{point: {87, 54}, hp_pct: 58}] = CreatureMarks.find(frame, tile_px: 302)
      assert CreatureMarks.find(frame, tile_px: 151) == []
    end
  end

  describe "noise" do
    test "a red crest and sand are not bars" do
      frame =
        FrameFixtures.of(200, 120, fn x, y ->
          if x in 40..60 and y in 30..60, do: {150, 30, 50}, else: @sand
        end)

      assert CreatureMarks.find(frame, tile_px: @tile) == []
    end

    test "two bars on the same row are two marks" do
      frame = scene(300, 120, [%{x: 20, y: 50}, %{x: 200, y: 50, fill: 5}])

      assert [%{point: {33, 52}, hp_pct: 100}, %{point: {213, 52}, hp_pct: 20}] =
               CreatureMarks.find(frame, tile_px: @tile)
    end
  end

  describe "his own screen" do
    test "the pile: three skulls and his Venusaur" do
      {:ok, frame} = Frame.from_png_file("test/fixtures/crowd/feraligatr_pile.png")

      marks = CreatureMarks.find(frame, tile_px: @tile)

      assert Enum.count(marks, & &1.skull?) == 3
      # 24 of 25 columns: the Venusaur had taken a bite (the Pokebar read 96%).
      assert [%{point: {306, 358}, hp_pct: 96}] = Enum.filter(marks, & &1.pet?)
      assert marks |> Enum.reject(& &1.pet?) |> Enum.all?(&(&1.hp_pct == 100))

      assert Enum.sort(Enum.map(marks, & &1.point)) ==
               Enum.sort([{155, 207}, {457, 207}, {306, 358}, {457, 358}])
    end

    test "one far Feraligatr alone" do
      {:ok, frame} = Frame.from_png_file("test/fixtures/crowd/feraligatr_far.png")

      assert [%{point: {121, 61}, hp_pct: 100, skull?: true, pet?: false}] =
               CreatureMarks.find(frame, tile_px: @tile)
    end
  end
end
