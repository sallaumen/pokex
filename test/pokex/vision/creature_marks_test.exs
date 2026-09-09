defmodule Pokex.Vision.CreatureMarksTest do
  use ExUnit.Case, async: true

  alias Pokex.FrameFixtures
  alias Pokex.Vision.{CreatureMarks, Frame}

  @sand {224, 192, 128}
  @black {0, 0, 0}
  @green {0, 188, 0}
  @white {255, 255, 255}
  # the antialiased edge of a partial fill, measured on his notebook
  @edge {60, 90, 20}

  # Paints the game's health bar as measured on his client: a 27×4 black
  # rectangle whose 25×2 interior is `fill` columns of ink from the left and
  # black after. Optional skull above, number box below, antialiased edges.
  defp scene(w, h, bars) do
    FrameFixtures.of(w, h, fn x, y -> Enum.find_value(bars, @sand, &paint(&1, x, y)) end)
  end

  defp paint(bar, x, y) do
    cond do
      on_bar?(bar, x, y) -> bar_pixel(bar, x, y)
      on_skull?(bar, x, y) -> @white
      on_skull_outline?(bar, x, y) -> @black
      on_box?(bar, x, y) -> @black
      true -> nil
    end
  end

  defp on_bar?(%{x: bx, y: by}, x, y), do: x >= bx and x < bx + 27 and y >= by and y < by + 4

  # Interior columns are ink up to `fill`, black after; the border is black.
  # With `edges?` the fill's first and last columns are the dim edge pixel.
  defp bar_pixel(%{x: bx, y: by} = bar, x, y) do
    inside_x = x - bx - 1
    inside_y = y - by - 1
    fill = Map.get(bar, :fill, 25)
    filled? = inside_x in 0..24 and inside_y in 0..1 and inside_x < fill
    edge? = Map.get(bar, :edges?, false) and inside_x in [0, fill - 1] and fill < 25

    cond do
      not filled? -> @black
      edge? -> @edge
      true -> Map.get(bar, :ink, @green)
    end
  end

  # An icon's worth of bright white (5×12 = 60 px; the real skull keeps 61 above
  # the 200 line), as tall as an icon…
  defp on_skull?(%{x: bx, y: by} = bar, x, y) do
    Map.get(bar, :skull?, false) and x in (bx + 11)..(bx + 15) and y in (by - 29)..(by - 18)
  end

  # …inside a black outline one pixel wide.
  defp on_skull_outline?(%{x: bx, y: by} = bar, x, y) do
    Map.get(bar, :skull?, false) and x in (bx + 10)..(bx + 16) and y in (by - 30)..(by - 17)
  end

  defp on_box?(%{x: bx, y: by} = bar, x, y) do
    Map.get(bar, :box?, false) and x in (bx - 25)..(bx + 51) and y in (by + 3)..(by + 18)
  end

  describe "a full health bar on bare ground" do
    test "is one mark at the bar's centre with 100% health" do
      frame = scene(200, 120, [%{x: 60, y: 50}])

      assert [%{point: {73, 52}, hp_pct: 100, skull?: false, pet?: false}] =
               CreatureMarks.find(frame)
    end
  end

  describe "health" do
    test "the fill length is the health" do
      frame = scene(200, 120, [%{x: 60, y: 50, fill: 12}])
      assert [%{hp_pct: 48}] = CreatureMarks.find(frame)
    end

    test "a partial fill has a dim pixel at each end, and they count as fill" do
      # 6 columns of ink between two edge pixels: 8 of 25 on his notebook's pile
      frame = scene(200, 120, [%{x: 60, y: 50, fill: 8, edges?: true}])
      assert [%{hp_pct: 32}] = CreatureMarks.find(frame)
    end

    test "one column of red ink is a creature nearly dead, not nothing" do
      frame = scene(200, 120, [%{x: 60, y: 50, fill: 1, ink: {200, 30, 30}}])
      assert [%{hp_pct: 4}] = CreatureMarks.find(frame)
    end

    test "a black rectangle with no ink is not a creature" do
      frame = scene(200, 120, [%{x: 60, y: 50, fill: 0}])
      assert CreatureMarks.find(frame) == []
    end
  end

  describe "signatures" do
    test "a skull above the bar marks the heavy monster" do
      frame = scene(200, 120, [%{x: 60, y: 50, skull?: true}])
      assert [%{skull?: true, pet?: false}] = CreatureMarks.find(frame)
    end

    test "a white flash above the bar is not a skull: no outline, too much white" do
      frame =
        FrameFixtures.of(200, 120, fn x, y ->
          if x in 40..100 and y in 10..36,
            do: @white,
            else: Enum.find_value([%{x: 60, y: 50}], @sand, &paint(&1, x, y))
        end)

      assert [%{skull?: false}] = CreatureMarks.find(frame)
    end

    test "a number box under the bar marks his own pokemon" do
      frame = scene(200, 120, [%{x: 60, y: 50, box?: true}])
      assert [%{pet?: true, skull?: false}] = CreatureMarks.find(frame)
    end
  end

  describe "the ruler is the frame's scale, not the tile" do
    test "sizes double on a 2x frame" do
      assert %{bar_w: 27, bar_h: 4, box_w: 54, skull_px: 61, skull_rows: 12} =
               CreatureMarks.geometry(1.0)

      assert %{bar_w: 54, bar_h: 8, box_w: 108, skull_px: 244, skull_rows: 24} =
               CreatureMarks.geometry(2.0)
    end

    test "a bar drawn at 2x is found on a 2x frame and not on a 1x one" do
      # 54×8 rectangle, 52×6 interior, 30 of 52 columns filled
      frame =
        FrameFixtures.of(200, 120, fn x, y ->
          if x in 60..113 and y in 50..57 do
            if x in 61..112 and y in 51..56 and x - 61 < 30, do: @green, else: @black
          else
            @sand
          end
        end)

      assert [%{point: {87, 54}, hp_pct: 58}] = CreatureMarks.find(%{frame | scale: 2.0})
      assert CreatureMarks.find(frame) == []
    end
  end

  describe "noise" do
    test "a red crest and sand are not bars" do
      frame =
        FrameFixtures.of(200, 120, fn x, y ->
          if x in 40..60 and y in 30..60, do: {150, 30, 50}, else: @sand
        end)

      assert CreatureMarks.find(frame) == []
    end

    test "two bars on the same row are two marks" do
      frame = scene(300, 120, [%{x: 20, y: 50}, %{x: 200, y: 50, fill: 5}])

      assert [%{point: {33, 52}, hp_pct: 100}, %{point: {213, 52}, hp_pct: 20}] =
               CreatureMarks.find(frame)
    end
  end

  describe "his ultrawide screen (tile 151)" do
    test "the pile: three skulls and his Venusaur" do
      {:ok, frame} = Frame.from_png_file("test/fixtures/crowd/feraligatr_pile.png")

      marks = CreatureMarks.find(frame)

      assert Enum.count(marks, & &1.skull?) == 3
      # 24 of 25 columns: the Venusaur had taken a bite (the Pokebar read 96%).
      assert [%{point: {306, 358}, hp_pct: 96}] = Enum.filter(marks, & &1.pet?)
      assert marks |> Enum.reject(& &1.pet?) |> Enum.all?(&(&1.hp_pct == 100))

      assert Enum.sort(Enum.map(marks, & &1.point)) ==
               Enum.sort([{155, 207}, {457, 207}, {306, 358}, {457, 358}])
    end

    # "Eles já renasceram com esse nome rosa, o que quer dizer que eles não são
    # agressivos para a gente." A creature that stood up again beside him is
    # drawn magenta — name and bar — and does not enter the battle list.
    test "the respawned Magneton's bar is magenta, and his Torterra's is not" do
      {:ok, frame} = Frame.from_png_file("test/fixtures/crowd/ultrawide_magneton_renascido.png")

      marks = CreatureMarks.find(frame)

      assert [
               %{point: {232, 127}, hp_pct: 100, passive?: true},
               %{point: {133, 278}, hp_pct: 100, passive?: false}
             ] = marks
    end

    test "one far Feraligatr alone" do
      {:ok, frame} = Frame.from_png_file("test/fixtures/crowd/feraligatr_far.png")

      assert [%{point: {121, 61}, hp_pct: 100, skull?: true, pet?: false}] =
               CreatureMarks.find(frame)
    end
  end

  describe "his notebook screen (tile 36, same bar)" do
    test "the Magneton pile: every bar is found, damaged, no skull, no box" do
      {:ok, frame} = Frame.from_png_file("test/fixtures/crowd/magneton_pile.png")

      marks = CreatureMarks.find(frame)

      assert length(marks) == 7
      assert Enum.all?(marks, &(&1.hp_pct in 20..45))
      # the white "168" and "126" damage numbers over the pile are not skulls
      refute Enum.any?(marks, & &1.skull?)
      refute Enum.any?(marks, & &1.pet?)
      # the bottom row: two tiles apart in the game, 72 px apart here (tile 36)
      bottom =
        marks
        |> Enum.filter(fn %{point: {_x, y}} -> y == 199 end)
        |> Enum.map(fn %{point: {x, _y}} -> x end)

      assert bottom == [56, 128, 200]
      # his Torterra, at 39% on the Pokebar: 9 of 25 columns
      assert %{hp_pct: 36} = Enum.find(marks, &(&1.point == {128, 127}))
    end

    test "his own bar over his head is a full bar" do
      {:ok, frame} = Frame.from_png_file("test/fixtures/crowd/notebook_me.png")

      assert [%{point: {55, 31}, hp_pct: 100, skull?: false, pet?: false}] =
               CreatureMarks.find(frame)
    end

    test "a magenta-named Magneton alone still has a bar" do
      {:ok, frame} = Frame.from_png_file("test/fixtures/crowd/notebook_loner.png")
      assert [%{point: {56, 31}, hp_pct: 100, skull?: false}] = CreatureMarks.find(frame)
    end
  end
end
