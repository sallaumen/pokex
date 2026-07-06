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

  describe "find_hostile/2" do
    import Pokex.FrameFixtures

    test "finds the centroid of the biggest red cluster" do
      frame = uniform(100, 100, {20, 80, 40})

      # nome do pokémon: bloco 12x4 de vermelho puro centrado em ~(50, 30)
      frame =
        for x <- 44..55, y <- 28..31, reduce: frame do
          acc -> put_px(acc, x, y, {255, 30, 30})
        end

      # ruído vermelho isolado longe (menor que o cluster)
      frame = frame |> put_px(5, 90, {255, 0, 0}) |> put_px(6, 90, {255, 0, 0})

      assert {:ok, {x, y}} = Pokex.Vision.find_hostile(frame)
      assert_in_delta x, 49, 2
      assert_in_delta y, 29, 2
    end

    test "not_found when too few red pixels" do
      frame = uniform(50, 50, {20, 80, 40}) |> put_px(10, 10, {255, 0, 0})
      assert Pokex.Vision.find_hostile(frame) == :not_found
    end

    test "green health bar and white text do not count as red" do
      frame = uniform(50, 50, {20, 80, 40})

      frame =
        for x <- 10..40, reduce: frame do
          acc -> acc |> put_px(x, 5, {0, 200, 0}) |> put_px(x, 8, {255, 255, 255})
        end

      assert Pokex.Vision.find_hostile(frame) == :not_found
    end
  end

  describe "wild_present?/2" do
    import Pokex.FrameFixtures

    test "true when enough pokeball-red pixels exist" do
      frame = uniform(30, 100, {30, 30, 30})

      frame =
        for x <- 10..17, y <- 20..23, reduce: frame do
          acc -> put_px(acc, x, y, {230, 40, 40})
        end

      assert Pokex.Vision.wild_present?(frame)
    end

    test "false on empty strip or sparse noise" do
      refute Pokex.Vision.wild_present?(uniform(30, 100, {30, 30, 30}))

      noisy =
        uniform(30, 100, {30, 30, 30}) |> put_px(1, 1, {255, 0, 0}) |> put_px(5, 50, {255, 0, 0})

      refute Pokex.Vision.wild_present?(noisy)
    end
  end

  describe "find_wild_row/2" do
    import Pokex.FrameFixtures

    test "returns the Y of the topmost pokeball row, skipping player rows" do
      frame = uniform(30, 100, {30, 30, 30})

      frame =
        for x <- 10..17, y <- 40..45, reduce: frame do
          acc -> put_px(acc, x, y, {230, 40, 40})
        end

      frame =
        for x <- 10..17, y <- 70..75, reduce: frame do
          acc -> put_px(acc, x, y, {230, 40, 40})
        end

      assert {:ok, y} = Pokex.Vision.find_wild_row(frame)
      assert y in 32..47
    end

    test "not_found when no pokeball icon (only players in the list)" do
      assert Pokex.Vision.find_wild_row(uniform(30, 100, {30, 30, 30})) == :not_found
    end
  end

  describe "target_locked?/2" do
    import Pokex.FrameFixtures

    test "true when the red selection border is present (enough red)" do
      frame =
        for x <- 5..25, y <- 5..25, reduce: uniform(60, 60, {30, 30, 30}) do
          acc -> put_px(acc, x, y, {230, 40, 40})
        end

      assert Pokex.Vision.target_locked?(frame)
    end

    test "false with only a little red (a blink or just names)" do
      frame = uniform(60, 60, {30, 30, 30}) |> put_px(1, 1, {255, 0, 0})
      refute Pokex.Vision.target_locked?(frame)
    end
  end
end
