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

  @tag :tmp_dir
  test "png_dimensions reads only the header", %{tmp_dir: tmp} do
    path = Path.join(tmp, "dims.png")
    Pokex.PngFixtures.write!(path, [[{1, 2, 3, 255}, {4, 5, 6, 255}, {7, 8, 9, 255}]])
    assert Frame.png_dimensions(path) == {:ok, {3, 1}}

    assert {:error, :not_png} =
             tap(Path.join(tmp, "x.txt"), &File.write!(&1, "no")) |> Frame.png_dimensions()
  end
end
