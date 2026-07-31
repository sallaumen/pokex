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

  # Real frame from Lucas's screen (2026-07-10): mini-game OPEN while fishing.
  # Character center ≈ (300, 430); the game draws the bar OFFSET to the RIGHT of
  # the sprite (bar center = 342, ~40px right). Pins both the offset and why the
  # production anchor tolerance must be wider than the old ~4%-of-width default.
  test "detects the real overlay bar, which the game draws to the right of the character" do
    {:ok, frame} = Frame.from_png_file("test/fixtures/mini_game/real_open.png")

    reading =
      Detector.detect(frame,
        anchor_x: 300,
        anchor_y: 430,
        anchor_tolerance: 70,
        min_confidence: 0.62,
        min_dark_ratio: 0.34
      )

    assert reading.present?
    assert reading.bar.x in 335..350

    # the old default tolerance (max(20, 4% of width) = 32px here) rejects the
    # real bar from the ANCHORED pass — the exact "whistle never fires" bug. The
    # full-frame sweep now rescues it via the capsule evidence.
    rescued =
      Detector.detect(frame,
        anchor_x: 300,
        anchor_y: 430,
        min_confidence: 0.62,
        min_dark_ratio: 0.34
      )

    assert rescued.present?
    assert rescued.bar.via == :sweep
    assert rescued.bar.x in 335..350
  end

  test "sweep finds the real overlay even with a badly wrong player anchor" do
    {:ok, frame} = Frame.from_png_file("test/fixtures/mini_game/real_open.png")

    reading =
      Detector.detect(frame,
        anchor_x: 100,
        anchor_y: 100,
        anchor_tolerance: 70,
        min_confidence: 0.62,
        min_dark_ratio: 0.34
      )

    assert reading.present?
    assert reading.bar.via == :sweep
    assert reading.bar.x in 335..350
  end

  test "sweep demands capsule evidence: a bare dark column far from the anchor stays rejected" do
    frame =
      frame(220, 220, fn x, y ->
        if x in 24..36 and y in 24..202,
          do: {26, 30, 48},
          else: {150, 120, 86}
      end)

    refute Detector.detect(frame, min_confidence: 0.6, anchor_x: 180, anchor_tolerance: 24).present?
  end

  test "sweep accepts a far-from-anchor bar once the blue capsule is on it" do
    frame =
      frame(220, 220, fn x, y ->
        cond do
          x in 24..36 and y in 120..140 -> {30, 170, 235}
          x in 24..36 and y in 24..202 -> {26, 30, 48}
          true -> {150, 120, 86}
        end
      end)

    reading = Detector.detect(frame, min_confidence: 0.6, anchor_x: 180, anchor_tolerance: 24)

    assert reading.present?
    assert reading.bar.via == :sweep
    assert reading.bar.x in 24..36
  end

  # The overlay is drawn AT the character: nameplate/sprite pixels can interrupt
  # the dark column for far more than the anchored pass's 8px gap budget. The
  # sweep bridges sprite-sized interruptions (budgeted by frame height).
  test "sweep bridges a sprite-sized interruption over the bar" do
    frame =
      frame(220, 220, fn x, y ->
        cond do
          x in 104..116 and y in 95..125 -> {150, 120, 86}
          x in 104..116 and y in 160..180 -> {30, 170, 235}
          x in 104..116 and y in 24..202 -> {26, 30, 48}
          true -> {150, 120, 86}
        end
      end)

    reading = Detector.detect(frame, min_confidence: 0.6)

    assert reading.present?
    assert reading.bar.via == :sweep
    assert reading.bar.x in 104..116
  end

  # Real frame, NO mini-game: the dark dock fence at x≈210 is a tall dark column,
  # historically a false-positive source. The wider production tolerance must
  # still keep it outside the anchor window (player anchored at 323, 237).
  test "does not mistake the dark dock fence for the mini-game at the production tolerance" do
    {:ok, frame} = Frame.from_png_file("test/fixtures/mini_game/real_fence_no_game.png")

    refute Detector.detect(frame,
             anchor_x: 323,
             anchor_y: 237,
             anchor_tolerance: 70,
             min_confidence: 0.62,
             min_dark_ratio: 0.34
           ).present?
  end

  # Real frame from Lucas's screen (2026-07-20): the game open at the RIGHT EDGE
  # of the viewport, bar over dock wood + open water, pink fish + "-35%" label
  # over the bar, capsule at the bottom. Cropped to the strip a dedicated
  # mini_game_region calibration would capture: the crop-center anchor with
  # full-width tolerance (exactly what the worker passes for a dedicated
  # region) must detect it.
  test "detects the real right-edge bar inside a dedicated calibration strip" do
    {:ok, frame} = Frame.from_png_file("test/fixtures/mini_game/real_right_edge_strip.png")

    reading =
      Detector.detect(frame,
        anchor_x: div(frame.width, 2),
        anchor_tolerance: div(frame.width, 2) + 1,
        min_confidence: 0.62,
        min_dark_ratio: 0.34
      )

    assert reading.present?
    # anchored and sweep both fail here (bar+sidebar merge past max_width);
    # the capsule pass is what carries this frame
    assert reading.bar.via == :capsule
    assert reading.bar.x in 32..52
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

  defp frame(width, height, fun), do: Pokex.FrameFixtures.of(width, height, fun)
end
