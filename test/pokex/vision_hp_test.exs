defmodule Pokex.VisionHpTest do
  use ExUnit.Case, async: true
  alias Pokex.Vision
  alias Pokex.Vision.Frame

  @green {40, 200, 60}
  @yellow {220, 200, 40}
  @dark {17, 17, 17}
  @white {240, 240, 240}

  # Build a Frame from a list of rows of {r,g,b} pixels (alpha 255).
  defp frame(rows) do
    h = length(rows)
    w = length(hd(rows))
    rgba = for row <- rows, {r, g, b} <- row, into: <<>>, do: <<r, g, b, 255>>
    %Frame{width: w, height: h, rgba: rgba}
  end

  defp bar(fill_cols, total_cols, fill_color, rows \\ 4) do
    for _y <- 1..rows do
      for x <- 1..total_cols, do: if(x <= fill_cols, do: fill_color, else: @dark)
    end
  end

  describe "hp_fill_pct/2" do
    test "a full green bar reads ~100%" do
      assert Vision.hp_fill_pct(frame(bar(20, 20, @green))) == 100
    end

    test "a half-filled bar reads ~50%" do
      assert Vision.hp_fill_pct(frame(bar(10, 20, @green))) == 50
    end

    test "an empty (all dark) bar reads 0%" do
      assert Vision.hp_fill_pct(frame(bar(0, 20, @green))) == 0
    end

    test "yellow and red fill count as health, not just green" do
      assert Vision.hp_fill_pct(frame(bar(10, 20, @yellow))) == 50
      assert Vision.hp_fill_pct(frame(bar(6, 20, {200, 40, 40}))) == 30
    end

    test "the white HP number overlaid on the fill does not eat the reading" do
      # a full green bar, but the middle row of every column is white (the '4304/4304' text).
      # Each column still has green above/below, so it still counts as filled.
      rows =
        for y <- 0..3 do
          for _x <- 1..20, do: if(y == 1, do: @white, else: @green)
        end

      assert Vision.hp_fill_pct(frame(rows)) == 100
    end

    test "a zero-size frame is a safe 0 (no crash)" do
      assert Vision.hp_fill_pct(%Frame{width: 0, height: 0, rgba: <<>>}) == 0
    end
  end
end
