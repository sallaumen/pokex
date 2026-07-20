defmodule Pokex.FrameFixtures do
  @moduledoc "In-memory Frame builders for Vision tests."
  alias Pokex.Vision.Frame

  def uniform(w, h, {r, g, b}) do
    %Frame{width: w, height: h, rgba: :binary.copy(<<r, g, b, 255>>, w * h)}
  end

  @doc "A frame painted per-pixel: fun.(x, y) -> {r, g, b}."
  def of(width, height, paint) do
    rgba =
      for y <- 0..(height - 1), x <- 0..(width - 1), into: <<>> do
        {r, g, b} = paint.(x, y)
        <<r, g, b, 255>>
      end

    %Frame{width: width, height: height, rgba: rgba}
  end

  def put_px(%Frame{} = frame, x, y, {r, g, b}) do
    offset = (y * frame.width + x) * 4
    <<before::binary-size(offset), _::binary-size(4), rest::binary>> = frame.rgba
    %{frame | rgba: before <> <<r, g, b, 255>> <> rest}
  end
end
