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

  # A captured frame never leaves this machine and lives for milliseconds, so
  # compressing it is pure waste: MEASURED 2026-08-11 on the 3.2 Mpx capture
  # square, 4752ms to decode as PNG against 7ms to read as raw. The helper now
  # writes RGBA8 behind a 13-byte header when the caller asks for `.raw`.
  describe "reading a frame in whichever format it arrived" do
    defp raw_bytes(width, height, pixels),
      do: <<"PXRW", 1, width::32, height::32>> <> pixels

    @tag :tmp_dir
    test "raw pixels are read straight out of the file", %{tmp_dir: tmp} do
      path = Path.join(tmp, "frame.raw")
      pixels = <<255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 10, 20, 30, 255>>
      File.write!(path, raw_bytes(2, 2, pixels))

      assert {:ok, %Frame{width: 2, height: 2} = frame} = Frame.from_file(path)
      assert Frame.at(frame, 0, 0) == {255, 0, 0}
      assert Frame.at(frame, 1, 1) == {10, 20, 30}
    end

    # The format is decided by the MAGIC BYTES, never by the name: with
    # ScreenCaptureKit down, the `screencapture` fallback serves a request for
    # `foo.raw` as a PNG under that very name. Trusting the extension would read
    # a PNG header as pixels and hand back garbage that still looks like a frame.
    @tag :tmp_dir
    test "a PNG served under a .raw name is still read as a PNG", %{tmp_dir: tmp} do
      path = Path.join(tmp, "fallback.raw")
      Pokex.PngFixtures.write!(path, [[{1, 2, 3, 255}, {4, 5, 6, 255}]])

      assert {:ok, %Frame{width: 2, height: 1} = frame} = Frame.from_file(path)
      assert Frame.at(frame, 0, 0) == {1, 2, 3}
    end

    # A short read is a broken file, not a small frame — every pixel lookup past
    # the end would raise deep inside some Vision loop instead of here.
    @tag :tmp_dir
    test "a truncated raw file is an error, never a half frame", %{tmp_dir: tmp} do
      path = Path.join(tmp, "torn.raw")
      File.write!(path, raw_bytes(2, 2, <<255, 0, 0, 255>>))

      assert {:error, _reason} = Frame.from_file(path)
    end

    test "a file that is not there answers with the reason" do
      assert {:error, :enoent} = Frame.from_file("/nao/existe/frame.raw")
    end
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
