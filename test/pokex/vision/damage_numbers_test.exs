defmodule Pokex.Vision.DamageNumbersTest do
  @moduledoc """
  The orange numbers the game prints over whatever just took a hit — the only
  thing on screen that can say how far an area skill actually reaches.
  """
  use ExUnit.Case, async: true

  alias Pokex.Vision.{DamageNumbers, Frame}

  defp scene(w, h, boxes) do
    rgba =
      for y <- 0..(h - 1), x <- 0..(w - 1), into: <<>> do
        painted(boxes, x, y) || <<90, 90, 90, 255>>
      end

    %Frame{width: w, height: h, rgba: rgba, scale: 1.0}
  end

  defp painted(boxes, x, y) do
    Enum.find_value(boxes, fn {bx, by, bw, bh, colour} ->
      if x >= bx and x < bx + bw and y >= by and y < by + bh, do: colour
    end)
  end

  test "a damage number is found where it was printed" do
    frame = scene(200, 80, [{40, 30, 40, 12, <<240, 118, 13, 255>>}])

    assert [n] = DamageNumbers.find(frame)
    assert n.kind == :damage
    assert n.x == 40
    assert n.w == 40
  end

  test "a hostile's RED name is not a damage number" do
    # (218, 0, 0): red dominates, but there is no green at all.
    frame = scene(200, 80, [{40, 30, 56, 10, <<218, 0, 0, 255>>}])

    assert DamageNumbers.find(frame) == []
  end

  test "a YELLOW skill banner is not a damage number" do
    # "AGILITY!" is ~(255, 200, 30) — the same red, far more green. It lands in
    # the same band as the numbers and would inflate every measured radius.
    frame = scene(200, 80, [{40, 30, 60, 12, <<255, 200, 30, 255>>}])

    assert DamageNumbers.find(frame) == []
  end

  test "his own pokémon's GREEN name is not a damage number" do
    frame = scene(200, 80, [{40, 30, 53, 10, <<5, 166, 67, 255>>}])

    assert DamageNumbers.find(frame) == []
  end

  test "two numbers side by side stay two" do
    frame =
      scene(300, 80, [
        {20, 30, 40, 12, <<240, 118, 13, 255>>},
        {120, 30, 40, 12, <<240, 118, 13, 255>>}
      ])

    assert length(DamageNumbers.find(frame)) == 2
  end

  test "a wide orange band is scenery, not a number" do
    frame = scene(300, 80, [{20, 30, 200, 12, <<240, 118, 13, 255>>}])

    assert DamageNumbers.find(frame) == []
  end
end
