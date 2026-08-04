defmodule Pokex.Screenshot do
  @moduledoc """
  A full screenshot and the screen it belongs to — the ONE recipe /calibration
  and /diagnostics share.

  They used to measure the screen differently (one asked the window server, the
  other a probe), so the same picture meant two different coordinate spaces and
  only one of them matched what the bot clicks. The screen here is always the
  display the capture backend filmed (see `Pokex.Bots.Capture.screen_with_points/2`).
  """

  alias Pokex.Bots.Capture
  alias Pokex.Vision.Frame

  @doc """
  `{:ok, %{path: path, scale: pixels_per_point, w: points, h: points}}`.

  A point marked on this picture is a SCREEN point: divide the click by `scale`
  and the bot can click it back.
  """
  def take(filename) do
    with {:ok, path, points} <- Capture.screen_with_points(filename),
         {:ok, pixels} <- Frame.png_dimensions(path) do
      {:ok, measured(path, pixels, points)}
    end
  end

  defp measured(path, {px_w, _px_h}, {pt_w, pt_h}) when pt_w > 0 and pt_h > 0,
    do: %{path: path, scale: px_w / pt_w, w: pt_w, h: pt_h}

  # Nothing could measure the display, so the picture is its own ruler. Wrong
  # only on a Retina screen with a dead probe — and wrong loudly (the saved
  # screen size will not match the next reading) instead of silently skewed.
  defp measured(path, {px_w, px_h}, _unmeasurable),
    do: %{path: path, scale: 1.0, w: px_w, h: px_h}
end
