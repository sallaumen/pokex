defmodule PokexWeb.CalibrationClick do
  @moduledoc """
  The ONE conversion from a browser click to a screen point — pure, so it can
  be tested against the exact payloads real browsers send.

  It lived inline in the LiveView and crashed the whole calibration page on
  the FIRST click of the wizard (2026-08-07): the trace called
  `Float.round(x, 1)` and the browser sends `166`, an INTEGER, whenever the
  click lands on an exact pixel. The test that approved it used `25.0` —
  float payloads only. Every numeric guarantee about clicks now lives here,
  where the regression test IS the crash payload.

  The math: `x / cw` is the fraction of the displayed image (the hook reads
  the post-transform `getBoundingClientRect`, so zoom cancels out), `× nw`
  lands on the screenshot pixel, `÷ scale` converts pixels to screen points.
  """

  @doc """
  `{:ok, point, trace}` for a click payload, or `{:error, :empty_box}` when
  the image had no measurable size yet (an `<img>` still loading reports 0 —
  dividing would crash, and a point computed from it would be garbage).

  `trace` is the X-ray entry the page shows: raw numbers in, point out.
  """
  def read(%{"x" => x, "y" => y, "cw" => cw, "ch" => ch, "nw" => nw, "nh" => nh}, scale, zoomed?)
      when is_number(x) and is_number(y) and cw > 0 and ch > 0 and nw > 0 and nh > 0 and
             scale > 0 do
    point = {round(x * nw / cw / scale), round(y * nh / ch / scale)}

    trace = %{
      raw: {r1(x), r1(y)},
      box: {r1(cw), r1(ch)},
      natural: {trunc(nw), trunc(nh)},
      zoomed?: zoomed?,
      recorded?: zoomed?,
      point: point
    }

    {:ok, point, trace}
  end

  def read(_params, _scale, _zoomed?), do: {:error, :empty_box}

  # `n / 1` is a float for integers and floats alike — Float.round/2 on a bare
  # integer is exactly the crash this module exists to prevent.
  defp r1(n), do: Float.round(n / 1, 1)
end
