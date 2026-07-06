defmodule Pokex.VisionTest do
  use ExUnit.Case, async: true
  import Pokex.FrameFixtures
  alias Pokex.Vision

  test "distance is mean absolute rgb difference" do
    a = uniform(2, 2, {10, 10, 10})
    b = uniform(2, 2, {10, 10, 10})
    assert Vision.distance(a, b) == 0.0

    c = uniform(2, 2, {13, 10, 16})
    assert_in_delta Vision.distance(a, c), 3.0, 0.001
  end

  test "glow? compares against the CLOSEST baseline (animation tolerance)" do
    frame_a = uniform(4, 4, {0, 60, 120})
    frame_b = uniform(4, 4, {0, 80, 140})
    baselines = [frame_a, frame_b]

    assert Vision.glow?(uniform(4, 4, {200, 220, 255}), baselines, 15.0)
    refute Vision.glow?(uniform(4, 4, {0, 82, 142}), baselines, 15.0)
  end

  test "suggested_threshold has margin over natural variation, floor of 12" do
    quiet = [uniform(2, 2, {0, 60, 120}), uniform(2, 2, {0, 61, 121})]
    assert Vision.suggested_threshold(quiet) == 12.0

    wavy = [uniform(2, 2, {0, 60, 120}), uniform(2, 2, {0, 90, 150})]
    assert_in_delta Vision.suggested_threshold(wavy), 30.0, 0.001
  end
end
