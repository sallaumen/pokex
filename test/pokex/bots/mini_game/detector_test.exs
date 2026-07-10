defmodule Pokex.Bots.MiniGame.DetectorTest do
  use ExUnit.Case, async: true

  alias Pokex.Bots.MiniGame.Detector
  alias Pokex.Vision.Frame

  test "detects the long dark mini-game control bar" do
    frame =
      frame(220, 220, fn x, y ->
        if x in 104..116 and y in 24..202,
          do: {26, 30, 48},
          else: {150, 120, 86}
      end)

    reading = Detector.detect(frame, min_confidence: 0.6)

    assert reading.present?
    assert reading.confidence >= 0.6
    assert reading.bar.x in 104..116
  end

  test "detects the real mini-game bar proportions in a tall arena crop" do
    frame =
      frame(526, 845, fn x, y ->
        cond do
          x in 247..262 and y in 182..585 -> {28, 27, 35}
          x in 70..430 and y in 70..125 -> {215, 225, 210}
          true -> {20, 110, 180}
        end
      end)

    reading =
      Detector.detect(frame,
        anchor_x: 255,
        anchor_y: 420,
        min_confidence: 0.62,
        min_dark_ratio: 0.34
      )

    assert reading.present?
    assert reading.confidence >= 0.62
    assert reading.bar.x in 247..262
    assert reading.bar.y1 in 180..186
    assert reading.bar.y2 in 580..586
  end

  test "rejects a short dark patch" do
    frame =
      frame(220, 220, fn x, y ->
        if x in 104..116 and y in 24..58,
          do: {26, 30, 48},
          else: {150, 120, 86}
      end)

    refute Detector.detect(frame, min_confidence: 0.6).present?
  end

  test "rejects a long dark bar away from the player anchor" do
    frame =
      frame(220, 220, fn x, y ->
        if x in 24..36 and y in 24..202,
          do: {26, 30, 48},
          else: {150, 120, 86}
      end)

    refute Detector.detect(frame, min_confidence: 0.6, anchor_x: 110, anchor_tolerance: 24).present?
  end

  test "rejects a dark vertical object that does not cross the player anchor y" do
    frame =
      frame(526, 845, fn x, y ->
        if x in 247..262 and y in 20..400,
          do: {28, 27, 35},
          else: {20, 110, 180}
      end)

    refute Detector.detect(frame,
             anchor_x: 255,
             anchor_y: 520,
             anchor_y_tolerance: 28,
             min_confidence: 0.62,
             min_dark_ratio: 0.34
           ).present?
  end

  test "rejects scattered dark pixels near the player anchor" do
    frame =
      frame(220, 220, fn x, y ->
        if x in 104..116 and rem(y, 13) in 0..4,
          do: {26, 30, 48},
          else: {150, 120, 86}
      end)

    refute Detector.detect(frame, min_confidence: 0.6, step: 1, max_gap_px: 4).present?
  end

  defp frame(width, height, fun) do
    rgba =
      for y <- 0..(height - 1)//1, x <- 0..(width - 1)//1, into: <<>> do
        {r, g, b} = fun.(x, y)
        <<r, g, b, 255>>
      end

    %Frame{width: width, height: height, rgba: rgba}
  end
end
