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

  test "bubble_count counts bright-cyan bubble pixels, not dark water or the red bait" do
    assert Vision.bubble_count(uniform(4, 4, {100, 200, 220})) == 16
    assert Vision.bubble_count(uniform(4, 4, {30, 80, 150})) == 0
    assert Vision.bubble_count(uniform(4, 4, {200, 60, 30})) == 0
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

  describe "red_row_counts/2 and locked_row/2" do
    import Pokex.FrameFixtures

    test "red_row_counts catches the DARK red of a target name/ring, not just bright red" do
      # MEASURED on the real game: a locked target's red NAME + ring are dark red
      # ~(160,25,25) — red-dominant but BELOW the old r>=200 cutoff, so a clearly
      # locked Horsea read ~0px. The lock predicate must catch r 130-200 too.
      frame = uniform(60, 104, {20, 20, 20})

      frame =
        for x <- 0..40, y <- 52..70, reduce: frame do
          acc -> put_px(acc, x, y, {160, 25, 25})
        end

      counts = Vision.red_row_counts(frame, top: 0, band: 52, rows: 2)
      assert Enum.at(counts, 1) > 300
      assert Enum.at(counts, 0) == 0
    end

    test "red_row_counts rejects white/gray names and green HP bars (not red-dominant)" do
      frame = uniform(60, 52, {20, 20, 20})

      frame =
        for x <- 0..40, reduce: frame do
          acc ->
            acc
            |> put_px(x, 10, {230, 230, 230})
            |> put_px(x, 20, {130, 130, 130})
            |> put_px(x, 30, {40, 200, 60})
        end

      assert Vision.red_row_counts(frame, top: 0, band: 52, rows: 1) == [0]
    end

    test "red_row_counts splits red by band" do
      # 60 wide x 312 tall = 6 bands of 52 at top 0; paint a red block in band 2
      frame = uniform(60, 312, {20, 20, 20})

      frame =
        for x <- 0..30, y <- 104..135, reduce: frame do
          acc -> put_px(acc, x, y, {230, 40, 40})
        end

      counts = Vision.red_row_counts(frame, top: 0, band: 52, rows: 6)
      assert length(counts) == 6
      assert Enum.at(counts, 2) == 31 * 32
      assert Enum.at(counts, 0) == 0
      assert Enum.at(counts, 1) == 0
      assert Enum.at(counts, 3) == 0
    end

    test "locked_row picks the loudest band over threshold" do
      assert Vision.locked_row([80, 0, 610, 0, 90, 0], 350) == {:ok, 2}
    end

    test "locked_row is :none when no band reaches min" do
      assert Vision.locked_row([80, 80, 150, 0, 0, 0], 350) == :none
    end

    test "locked_row ties break to the lowest index" do
      assert Vision.locked_row([0, 610, 0, 610, 0, 0], 350) == {:ok, 1}
    end

    test "red_row_counts respects the top offset (header ignored)" do
      # paint red ABOVE the first band's top → not attributed to any band
      frame = uniform(60, 200, {20, 20, 20})

      frame =
        for x <- 0..30, y <- 0..15, reduce: frame do
          acc -> put_px(acc, x, y, {230, 40, 40})
        end

      counts = Vision.red_row_counts(frame, top: 18, band: 52, rows: 6)
      assert Enum.all?(counts, &(&1 == 0))
    end
  end

  describe "hp_bar_rows/2" do
    import Pokex.FrameFixtures

    test "returns the center Y of each green HP bar, top to bottom" do
      # three green bars (each ~5px tall, wide enough to clear min_run) at rows
      # centered on y 12, 64, 116
      frame =
        for yrange <- [10..14, 62..66, 114..118],
            y <- yrange,
            x <- 0..40,
            reduce: uniform(60, 160, {30, 30, 30}) do
          acc -> put_px(acc, x, y, {40, 200, 60})
        end

      assert Vision.hp_bar_rows(frame) == [12, 64, 116]
    end

    test "ignores green runs narrower than min_run (sprite speckle, not a bar)" do
      frame =
        for x <- 0..5, reduce: uniform(60, 60, {30, 30, 30}) do
          acc -> put_px(acc, x, 20, {40, 200, 60})
        end

      assert Vision.hp_bar_rows(frame) == []
    end

    test "a bright bar that isn't GREEN-dominant is not an HP bar" do
      # grayish-white (g barely over r/b) and teal (g not over b by the margin)
      # both fail — only a true green HP bar counts
      gray =
        for x <- 0..40, y <- 10..14, reduce: uniform(60, 40, {30, 30, 30}) do
          acc -> put_px(acc, x, y, {200, 210, 200})
        end

      teal =
        for x <- 0..40, y <- 10..14, reduce: uniform(60, 40, {30, 30, 30}) do
          acc -> put_px(acc, x, y, {40, 200, 200})
        end

      assert Vision.hp_bar_rows(gray) == []
      assert Vision.hp_bar_rows(teal) == []
    end

    test "no bars → empty list" do
      assert Vision.hp_bar_rows(uniform(60, 60, {30, 30, 30})) == []
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

  describe "battle_has_creature?/2" do
    import Pokex.FrameFixtures

    test "true when a scanline holds a consecutive GREEN-dominant run >= min_run" do
      w = 40
      # min_run defaults to max(div(w, 4), 4) = 10
      frame =
        for x <- 0..9, reduce: uniform(w, 20, {30, 30, 30}) do
          acc -> put_px(acc, x, 10, {40, 200, 60})
        end

      assert Vision.battle_has_creature?(frame)
    end

    test "true when a scanline holds a consecutive RED-dominant run >= min_run" do
      w = 40

      frame =
        for x <- 0..9, reduce: uniform(w, 20, {30, 30, 30}) do
          acc -> put_px(acc, x, 10, {200, 30, 30})
        end

      assert Vision.battle_has_creature?(frame)
    end

    test "false on a dark background (well below thresholds)" do
      refute Vision.battle_has_creature?(uniform(40, 20, {10, 10, 10}))
    end

    test "false on white/light pixels (names/text, not a bar)" do
      w = 40

      frame =
        for x <- 0..(w - 1), reduce: uniform(w, 20, {30, 30, 30}) do
          acc -> put_px(acc, x, 10, {230, 230, 230})
        end

      refute Vision.battle_has_creature?(frame)
    end

    test "false on speckle — isolated matching pixels that never form a run >= min_run" do
      w = 40
      # green every other pixel: longest consecutive run is 1, well under min_run (10)
      frame =
        for x <- 0..(w - 1)//2, reduce: uniform(w, 20, {30, 30, 30}) do
          acc -> put_px(acc, x, 10, {40, 200, 60})
        end

      refute Vision.battle_has_creature?(frame)
    end
  end
end
