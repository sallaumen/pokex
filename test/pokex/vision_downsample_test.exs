defmodule Pokex.VisionDownsampleTest do
  use ExUnit.Case, async: true
  import Pokex.FrameFixtures
  alias Pokex.Vision

  describe "downsample/2 grid geometry" do
    test "keeps the frame aspect ratio by default and returns a row-major grid" do
      grid = Vision.downsample(uniform(10, 6, {0, 0, 0}), cols: 5)

      assert grid.cols == 5
      assert grid.rows == 3
      assert grid.cell_w == 2
      assert grid.cell_h == 2
      assert length(grid.cells) == 3
      assert Enum.all?(grid.cells, &(length(&1) == 5))
    end

    test "clamps cols/rows to the frame size (never more cells than pixels)" do
      grid = Vision.downsample(uniform(8, 4, {0, 0, 0}), cols: 1000, rows: 1000)
      assert grid.cols == 8
      assert grid.rows == 4
    end
  end

  describe "downsample/2 classification" do
    test "uniform colours classify by their pixel family" do
      assert cell_class(uniform(8, 8, {0, 200, 0}), cols: 2, rows: 2) == :hp_green
      assert cell_class(uniform(8, 8, {0, 0, 0}), cols: 2, rows: 2) == :dark
      assert cell_class(uniform(8, 8, {0, 180, 200}), cols: 2, rows: 2) == :cyan
      assert cell_class(uniform(8, 8, {255, 0, 0}), cols: 2, rows: 2) == :pokeball_red
      assert cell_class(uniform(8, 8, {150, 30, 30}), cols: 2, rows: 2) == :lock_red
      assert cell_class(uniform(8, 8, {100, 100, 100}), cols: 2, rows: 2) == :other
    end

    test "the most salient class PRESENT in a cell wins over a diluted average" do
      # A single green pixel in an otherwise-black cell still surfaces as hp_green,
      # while the cell's average stays nearly black (proving class != classify(avg)).
      frame = put_px(uniform(4, 4, {0, 0, 0}), 0, 0, {0, 200, 0})
      [[cell | _] | _] = Vision.downsample(frame, cols: 2, rows: 2).cells

      assert cell.class == :hp_green
      assert cell.g < 60
    end

    test "the average RGB is reported per cell" do
      [[cell | _] | _] = Vision.downsample(uniform(4, 4, {10, 20, 30}), cols: 2, rows: 2).cells
      assert {cell.r, cell.g, cell.b} == {10, 20, 30}
    end
  end

  defp cell_class(frame, opts) do
    [[cell | _] | _] = Vision.downsample(frame, opts).cells
    cell.class
  end
end
