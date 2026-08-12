defmodule Pokex.Vision.RecolorTest do
  use ExUnit.Case, async: true

  alias Pokex.Vision.{Frame, Recolor}

  defp frame(pixels), do: %Frame{width: length(pixels), height: 1, rgba: bytes(pixels)}

  defp bytes(pixels), do: for({r, g, b, a} <- pixels, into: <<>>, do: <<r, g, b, a>>)

  defp pixels(%Frame{rgba: rgba}),
    do: for(<<r, g, b, a <- rgba>>, do: {r, g, b, a})

  describe "moving a palette without touching the drawing" do
    test "no adjustment hands back the very same frame" do
      original = frame([{200, 40, 40, 255}])

      assert Recolor.apply(original, hue: 0, saturation: 100, brightness: 100) == original
      assert Recolor.apply(original) == original
    end

    test "a 120 degree turn walks red to green, green to blue, blue to red" do
      painted =
        Recolor.apply(frame([{255, 0, 0, 255}, {0, 255, 0, 255}, {0, 0, 255, 255}]), hue: 120)

      assert pixels(painted) == [{0, 255, 0, 255}, {0, 0, 255, 255}, {255, 0, 0, 255}]
    end

    test "turning the hue a full circle lands back where it started" do
      original = frame([{200, 40, 90, 255}, {17, 200, 30, 255}])

      once = Recolor.apply(original, hue: 180)
      twice = Recolor.apply(once, hue: 180)

      assert pixels(twice) == pixels(original)
    end

    test "saturation at zero leaves grey, brightness scales it" do
      grey = Recolor.apply(frame([{255, 0, 0, 255}]), saturation: 0)
      assert [{255, 255, 255, 255}] = pixels(grey)

      dark = Recolor.apply(frame([{255, 0, 0, 255}]), saturation: 0, brightness: 50)
      assert [{128, 128, 128, 255}] = pixels(dark)
    end

    test "grey has no hue to turn" do
      original = frame([{120, 120, 120, 255}])
      assert pixels(Recolor.apply(original, hue: 90)) == pixels(original)
    end

    # The crop's background is not part of the sprite. Dragging its hue around
    # would teach the ground along with the corpse — and the ground already
    # scores ~0.84 on its own (measured 2026-07-30), which is above the match
    # threshold.
    test "fully transparent pixels are left exactly as they are" do
      painted = Recolor.apply(frame([{10, 20, 30, 0}, {255, 0, 0, 255}]), hue: 120)

      assert [{10, 20, 30, 0}, {0, 255, 0, 255}] = pixels(painted)
    end

    test "alpha rides through untouched on painted pixels" do
      painted = Recolor.apply(frame([{255, 0, 0, 128}]), hue: 120)
      assert [{0, 255, 0, 128}] = pixels(painted)
    end

    test "absurd knobs are clamped instead of producing garbage" do
      painted =
        Recolor.apply(frame([{200, 100, 50, 255}]), hue: 900, saturation: -50, brightness: 9_000)

      assert [{r, g, b, 255}] = pixels(painted)
      assert r in 0..255 and g in 0..255 and b in 0..255
    end

    test "a whole frame keeps its shape" do
      original = %Frame{
        width: 2,
        height: 2,
        rgba: bytes([{255, 0, 0, 255}, {0, 255, 0, 255}, {0, 0, 255, 255}, {9, 9, 9, 255}])
      }

      painted = Recolor.apply(original, hue: 60)

      assert painted.width == 2
      assert painted.height == 2
      assert byte_size(painted.rgba) == byte_size(original.rgba)
    end
  end
end
