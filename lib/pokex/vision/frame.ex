defmodule Pokex.Vision.Frame do
  @moduledoc """
  Decoded image in raw RGBA (4 bytes/pixel, row-major). The ONLY module that
  talks to the PNG decoder — if ExPng's API ever changes, fix it here only.
  Frame coordinates are PIXELS; screen coordinates elsewhere are POINTS.
  """

  # `scale` is how many PIXELS of this frame make one screen POINT, stamped by
  # whoever captured it — only the capture knows the region it asked for. It is
  # a property of the BACKEND, not of the screen: measured 2026-08-03 on the
  # same 196×215-point minimap region, ScreenCaptureKit answered 196×215 (1×)
  # while `screencapture` answered 392×430 (2×). Taking the scale from the
  # calibration file instead makes every conversion wrong by 2× the moment the
  # backend changes, which reads as the bot aiming at the top-left corner.
  defstruct [:width, :height, :rgba, scale: 1.0]

  @type t :: %__MODULE__{
          width: pos_integer,
          height: pos_integer,
          rgba: binary,
          scale: float
        }

  @doc "Stamps the scale a region asked in POINTS implies for this frame."
  def with_scale(%__MODULE__{width: w} = frame, region_w)
      when is_integer(region_w) and region_w > 0,
      do: %{frame | scale: w / region_w}

  def with_scale(%__MODULE__{} = frame, _unknown_region), do: frame

  @doc """
  Decodes a PNG file into a `Frame`.

  Adapter note: `ExPng.Image.from_file/1` does NOT return flat iodata in a
  `:pixels` field of bytes — it returns `pixels: [[<<r,g,b,a>>, ...], ...]`,
  a list of rows where each row is a list of 4-byte RGBA binaries (one binary
  per pixel; see `ExPng.Color.t/0`). We flatten the rows and concatenate the
  per-pixel binaries to get the flat row-major RGBA binary this struct needs.
  """
  def from_png_file(path) do
    case ExPng.Image.from_file(path) do
      {:ok, %ExPng.Image{width: w, height: h, pixels: rows}} ->
        rgba = rows |> List.flatten() |> IO.iodata_to_binary()
        {:ok, %__MODULE__{width: w, height: h, rgba: rgba}}

      {:error, reason, _path} ->
        {:error, reason}
    end
  end

  def at(%__MODULE__{} = frame, x, y) do
    <<r, g, b, _a>> = binary_part(frame.rgba, (y * frame.width + x) * 4, 4)
    {r, g, b}
  end

  @doc """
  Crop a sub-rectangle `{x, y, w, h}` (pixels) into a new Frame. Lets ONE screenshot of the
  whole battle region be sliced in memory into the body (HP bars + lock ring) and the
  rightmost pokeball strip — one `screencapture` per tick instead of two.
  """
  def crop(%__MODULE__{width: fw, rgba: rgba}, {x, y, w, h}) do
    row_bytes = w * 4

    data =
      for j <- 0..(h - 1)//1, into: <<>> do
        binary_part(rgba, ((y + j) * fw + x) * 4, row_bytes)
      end

    %__MODULE__{width: w, height: h, rgba: data}
  end

  def png_dimensions(path) do
    case File.read(path) do
      {:ok, <<137, "PNG", 13, 10, 26, 10, _len::32, "IHDR", w::32, h::32, _::binary>>} ->
        {:ok, {w, h}}

      {:ok, _} ->
        {:error, :not_png}

      error ->
        error
    end
  end
end
