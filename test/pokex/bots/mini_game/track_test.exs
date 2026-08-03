defmodule Pokex.Bots.MiniGame.TrackTest do
  use ExUnit.Case, async: true

  alias Pokex.Bots.MiniGame.{Detector, Track}
  alias Pokex.Vision.Frame

  @track_color {26, 30, 48}
  @blue {0, 160, 255}
  @fish {120, 100, 0}
  @floor {200, 170, 120}

  # A 220x220 frame with the track column at x 100..112. `rows` maps y-ranges
  # to what sits on the track there; everything else is floor.
  defp frame(rows), do: Pokex.FrameFixtures.of(220, 220, &pixel(rows, &1, &2))

  defp pixel(_rows, x, _y) when x < 100 or x > 112, do: @floor

  defp pixel(rows, _x, y),
    do: Enum.find_value(rows, @floor, fn {range, color} -> y in range && color end)

  @bar %{x: 106, width: 13}

  test "reads fish and capsule positions normalized to the track bounds" do
    frame =
      frame([
        {20..59, @track_color},
        {60..80, @blue},
        {81..119, @track_color},
        {120..140, @fish},
        {141..200, @track_color}
      ])

    assert {:ok, reading} = Track.read(frame, @bar)
    # bounds 20..200 (span 180): fish centroid 130 -> 0.611, capsule 70 -> 0.278
    assert_in_delta reading.fish_y, 0.611, 0.02
    assert_in_delta reading.bar_y, 0.278, 0.02
    assert reading.bar_source == :blue
  end

  test "full occlusion (fish over the capsule) reads bar_y = fish_y" do
    frame =
      frame([
        {20..119, @track_color},
        {120..140, @fish},
        {141..200, @track_color}
      ])

    assert {:ok, reading} = Track.read(frame, @bar)
    assert reading.bar_y == reading.fish_y
    assert reading.bar_source == :fish
    assert_in_delta reading.fish_y, 0.611, 0.02
  end

  test "fish pegged at the track top (too little dark above to bracket) clamps to 0.0" do
    # only a 6-row dark sliver above the fish: the bounds extension cannot
    # commit across it, so the fish falls outside the bounds — the edge rule
    # must still find it and target the extreme instead of releasing.
    frame =
      frame([
        {30..35, @track_color},
        {36..56, @fish},
        {57..200, @track_color}
      ])

    assert {:ok, reading} = Track.read(frame, @bar)
    assert reading.fish_y == 0.0
    assert reading.bar_y == 0.0
    assert reading.bar_source == :fish
  end

  test "a fish pegged at the BOTTOM beats bounded clutter past the TOP edge" do
    # Real incident (live traces, 2026-07-20): the fish sat at the track BOTTOM
    # with too little dark below to bracket it, while a bounded clutter blob sat
    # just past the TOP edge. The old top-first edge order elected the clutter —
    # the reading snapped to EXACTLY 0.0 for ~4 frames and the pilot flew the
    # capsule to the track top with the real fish waiting at the bottom. The
    # fish sprite is the LARGER run: when both edges hold a candidate, the
    # longer one is the fish.
    frame =
      frame([
        # bounded clutter just past the top edge: 12 other-rows, dark beyond
        {0..7, @track_color},
        {8..19, @floor},
        {20..190, @track_color},
        # the REAL fish, pegged at the bottom: only 7 dark rows beyond it
        {191..205, @fish},
        {206..212, @track_color}
      ])

    assert {:ok, reading} = Track.read(frame, @bar)
    assert reading.fish_y == 1.0
    assert reading.bar_y == 1.0
    assert reading.bar_source == :fish
  end

  test "dark clutter outside the track does not stretch the bounds" do
    # dark decoration far above the track (like the print's bench shadows)
    frame =
      frame([
        {0..6, @track_color},
        {40..99, @track_color},
        {100..120, @fish},
        {121..180, @track_color}
      ])

    assert {:ok, reading} = Track.read(frame, @bar)
    # bounds must be 40..180 (span 140), NOT 0..180: fish centroid 110 -> 0.5
    assert_in_delta reading.fish_y, 0.5, 0.02
  end

  test "no track column -> :no_track" do
    assert {:error, :no_track} = Track.read(frame([]), @bar)
  end

  test "track without a fish -> :no_fish" do
    frame = frame([{20..200, @track_color}])
    assert {:error, :no_fish} = Track.read(frame, @bar)
  end

  test "reads the REAL open mini-game frame (fish sitting on the capsule)" do
    {:ok, frame} = Frame.from_png_file("test/fixtures/mini_game/real_open.png")

    detection =
      Detector.detect(frame,
        anchor_x: div(frame.width, 2),
        anchor_tolerance: frame.width,
        anchor_y_tolerance: frame.height,
        min_confidence: 0.62,
        min_dark_ratio: 0.34
      )

    assert detection.present?
    assert {:ok, reading} = Track.read(frame, detection.bar)

    # Measured on this frame (2026-07-10): track 235..696, fish 642..673 with
    # the capsule split around it (636..641 + 675..696) — both near the bottom.
    assert reading.fish_y > 0.7
    assert reading.bar_y > 0.7
    assert_in_delta reading.fish_y, reading.bar_y, 0.08
  end
end
