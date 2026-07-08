defmodule Pokex.Vision.FrameTest do
  use ExUnit.Case, async: true
  alias Pokex.Vision.Frame

  @tag :tmp_dir
  test "round-trips our encoder through ExPng into a Frame", %{tmp_dir: tmp} do
    path = Path.join(tmp, "fixture.png")

    Pokex.PngFixtures.write!(path, [
      [{255, 0, 0, 255}, {0, 255, 0, 255}],
      [{0, 0, 255, 255}, {10, 20, 30, 255}]
    ])

    assert {:ok, %Frame{width: 2, height: 2} = frame} = Frame.from_png_file(path)
    assert Frame.at(frame, 0, 0) == {255, 0, 0}
    assert Frame.at(frame, 1, 0) == {0, 255, 0}
    assert Frame.at(frame, 0, 1) == {0, 0, 255}
    assert Frame.at(frame, 1, 1) == {10, 20, 30}
  end

  test "crop extracts a sub-rectangle into a new Frame" do
    # 4x3 frame; each pixel encodes its (x,y) as {x*10, y*10, 0}
    rgba =
      for y <- 0..2, x <- 0..3, into: <<>>, do: <<x * 10, y * 10, 0, 255>>

    frame = %Frame{width: 4, height: 3, rgba: rgba}

    # crop the right 2 columns of the bottom 2 rows → {2, 1, 2, 2}
    cropped = Frame.crop(frame, {2, 1, 2, 2})
    assert %Frame{width: 2, height: 2} = cropped
    assert Frame.at(cropped, 0, 0) == {20, 10, 0}
    assert Frame.at(cropped, 1, 0) == {30, 10, 0}
    assert Frame.at(cropped, 0, 1) == {20, 20, 0}
    assert Frame.at(cropped, 1, 1) == {30, 20, 0}
  end

  @tag :tmp_dir
  test "png_dimensions reads only the header", %{tmp_dir: tmp} do
    path = Path.join(tmp, "dims.png")
    Pokex.PngFixtures.write!(path, [[{1, 2, 3, 255}, {4, 5, 6, 255}, {7, 8, 9, 255}]])
    assert Frame.png_dimensions(path) == {:ok, {3, 1}}

    assert {:error, :not_png} =
             tap(Path.join(tmp, "x.txt"), &File.write!(&1, "no")) |> Frame.png_dimensions()
  end
end
