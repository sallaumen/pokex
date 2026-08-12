defmodule Pokex.Vision.Recolor do
  @moduledoc """
  Repaints a crop — the way to teach a corpse nobody has killed yet.

  Lucas hunts shiny Tentacool and shiny Krabby. A shiny is a RECOLOR: same
  sprite, different palette. He cannot photograph a corpse he has never made,
  and the library matches by colour, so until the day one dies the aim has
  nothing to recognise. So he takes the corpse of the ORDINARY species, turns
  the hue until it looks like the shiny he is after, and teaches that.

  A hand-painted sample is a stand-in, and the library says so: when the real
  body finally drops, he re-teaches from the photograph and the guess retires.

  Hue rotates, saturation and brightness scale. Nothing else — the point is to
  move a palette, not to edit an image, and every extra knob is another way for
  a taught corpse to stop looking like the thing on the ground.
  """

  alias Pokex.Vision.Frame

  @doc """
  `frame` with every pixel shifted by `hue` degrees (-180..180) and scaled by
  `saturation`/`brightness` (percent, 100 = unchanged).

  Fully transparent pixels are left exactly as they are: the crop's background
  is not part of the sprite, and dragging its hue around would teach the ground
  as much as the corpse.
  """
  @spec apply(Frame.t(), keyword) :: Frame.t()
  def apply(%Frame{} = frame, opts \\ []) do
    hue = opts |> Keyword.get(:hue, 0) |> clamp(-180, 180)
    saturation = opts |> Keyword.get(:saturation, 100) |> clamp(0, 300)
    brightness = opts |> Keyword.get(:brightness, 100) |> clamp(10, 300)

    if hue == 0 and saturation == 100 and brightness == 100 do
      frame
    else
      %{frame | rgba: repaint(frame.rgba, hue, saturation / 100, brightness / 100, <<>>)}
    end
  end

  defp repaint(<<>>, _hue, _sat, _bri, acc), do: acc

  defp repaint(<<r, g, b, 0, rest::binary>>, hue, sat, bri, acc),
    do: repaint(rest, hue, sat, bri, acc <> <<r, g, b, 0>>)

  defp repaint(<<r, g, b, a, rest::binary>>, hue, sat, bri, acc) do
    {h, s, v} = to_hsv(r, g, b)
    {nr, ng, nb} = to_rgb(rotate(h, hue), clamp_unit(s * sat), clamp_unit(v * bri))
    repaint(rest, hue, sat, bri, acc <> <<nr, ng, nb, a>>)
  end

  defp rotate(hue, degrees) do
    shifted = hue + degrees

    cond do
      shifted < 0 -> shifted + 360
      shifted >= 360 -> shifted - 360
      true -> shifted
    end
  end

  # -- HSV, the small way (no library, and the crop is 56x56) -----------------

  defp to_hsv(r, g, b) do
    max = Enum.max([r, g, b])
    min = Enum.min([r, g, b])
    delta = max - min
    v = max / 255
    s = if max == 0, do: 0.0, else: delta / max

    {h, _} =
      cond do
        delta == 0 -> {0.0, nil}
        max == r -> {60 * rem_float((g - b) / delta, 6), nil}
        max == g -> {60 * ((b - r) / delta + 2), nil}
        true -> {60 * ((r - g) / delta + 4), nil}
      end

    {if(h < 0, do: h + 360, else: h), s, v}
  end

  defp to_rgb(h, s, v) do
    c = v * s
    x = c * (1 - abs(rem_float(h / 60, 2) - 1))
    m = v - c

    {r, g, b} =
      cond do
        h < 60 -> {c, x, 0.0}
        h < 120 -> {x, c, 0.0}
        h < 180 -> {0.0, c, x}
        h < 240 -> {0.0, x, c}
        h < 300 -> {x, 0.0, c}
        true -> {c, 0.0, x}
      end

    {byte(r + m), byte(g + m), byte(b + m)}
  end

  defp rem_float(value, modulus) do
    rest = value - modulus * Float.floor(value / modulus)
    if rest < 0, do: rest + modulus, else: rest
  end

  defp byte(value), do: value |> Kernel.*(255) |> round() |> clamp(0, 255)

  defp clamp_unit(value), do: value |> Kernel.max(0.0) |> Kernel.min(1.0)

  defp clamp(value, min, max), do: value |> Kernel.max(min) |> Kernel.min(max)
end
