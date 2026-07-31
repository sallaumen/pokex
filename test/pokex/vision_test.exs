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
    assert Vision.bubble_count(uniform(4, 4, {40, 180, 220})) == 16
    assert Vision.bubble_count(uniform(4, 4, {20, 125, 170})) == 16
    assert Vision.bubble_count(uniform(4, 4, {120, 210, 230})) == 0
    assert Vision.bubble_count(uniform(4, 4, {20, 95, 170})) == 0
    assert Vision.bubble_count(uniform(4, 4, {30, 80, 150})) == 0
    assert Vision.bubble_count(uniform(4, 4, {200, 60, 30})) == 0
  end

  test "fishing_signal ignores cyan map glints when no lure is present" do
    frame = uniform(64, 64, {20, 125, 170})

    assert Vision.fishing_signal(frame) == %{
             bubble_count: 0,
             lure_count: 0,
             line_present?: false
           }
  end

  test "fishing_signal counts cyan near the red lure only" do
    frame = uniform(96, 96, {30, 80, 150})

    frame =
      for x <- 44..51, y <- 44..51, reduce: frame do
        acc -> put_px(acc, x, y, {210, 55, 30})
      end

    frame =
      for x <- 34..61, y <- 34..61, reduce: frame do
        acc ->
          if x in 44..51 and y in 44..51 do
            acc
          else
            put_px(acc, x, y, {20, 125, 170})
          end
      end

    frame =
      for x <- 0..15, y <- 0..15, reduce: frame do
        acc -> put_px(acc, x, y, {20, 125, 170})
      end

    signal = Vision.fishing_signal(frame, bubble_radius_px: 24)
    assert signal.line_present?
    assert signal.lure_count == 64
    assert signal.bubble_count == 28 * 28 - 64
  end

  test "fishing_signal does not treat lure-coloured pixels alone as a live line" do
    frame = uniform(96, 96, {30, 80, 150})

    frame =
      for x <- 44..56, y <- 44..56, reduce: frame do
        acc -> put_px(acc, x, y, {210, 55, 30})
      end

    signal = Vision.fishing_signal(frame, bubble_radius_px: 24)
    assert signal.lure_count > 20
    assert signal.bubble_count == 0
    refute signal.line_present?
  end

  test "fishing_signal prefers the lure candidate near the expected center" do
    frame = uniform(160, 160, {30, 80, 150})

    frame =
      for x <- 70..77, y <- 78..85, reduce: frame do
        acc -> put_px(acc, x, y, {210, 55, 30})
      end

    frame =
      for x <- 64..92, y <- 70..98, reduce: frame do
        acc ->
          if x in 70..77 and y in 78..85 do
            acc
          else
            put_px(acc, x, y, {20, 125, 170})
          end
      end

    frame =
      for x <- 116..150, y <- 116..150, reduce: frame do
        acc -> put_px(acc, x, y, {210, 55, 30})
      end

    signal = Vision.fishing_signal(frame, expected_center: {80, 80}, bubble_radius_px: 32)
    assert signal.line_present?
    assert signal.bubble_count > 600
    assert signal.lure_count < 200
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

      frame =
        for x <- 44..55, y <- 28..31, reduce: frame do
          acc -> put_px(acc, x, y, {255, 30, 30})
        end

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

    # measured in-game: a locked target's name+ring are dark red ~(160,25,25),
    # below the old r>=200 cutoff — a clearly locked Horsea read ~0px
    test "red_row_counts catches the DARK red of a target name/ring, not just bright red" do
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

      frame =
        for x <- 0..(w - 1)//2, reduce: uniform(w, 20, {30, 30, 30}) do
          acc -> put_px(acc, x, 10, {40, 200, 60})
        end

      refute Vision.battle_has_creature?(frame)
    end
  end

  describe "hp_bar_count/2" do
    import Pokex.FrameFixtures

    test "counts distinct HP bars, GREEN or RED (a low-HP creature still counts)" do
      frame =
        for {yrange, color} <- [{10..14, {40, 200, 60}}, {62..66, {200, 40, 40}}],
            y <- yrange,
            x <- 0..40,
            reduce: uniform(60, 120, {30, 30, 30}) do
          acc -> put_px(acc, x, y, color)
        end

      assert Vision.hp_bar_count(frame) == 2
    end

    test "no bars → 0 (empty rows have no HP bar, unlike a post-click lock ring)" do
      assert Vision.hp_bar_count(uniform(60, 60, {30, 30, 30})) == 0
    end

    test "thin speckle / a sparse red name is not a bar" do
      frame =
        for x <- 0..5, reduce: uniform(60, 60, {30, 30, 30}) do
          acc -> put_px(acc, x, 20, {200, 40, 40})
        end

      assert Vision.hp_bar_count(frame) == 0
    end
  end

  describe "hp_bar_row_positions/2" do
    import Pokex.FrameFixtures

    test "returns the CENTER y of each HP bar, GREEN or RED, top→bottom" do
      frame =
        for {yrange, color} <- [{10..14, {40, 200, 60}}, {62..66, {200, 40, 40}}],
            y <- yrange,
            x <- 0..40,
            reduce: uniform(60, 120, {30, 30, 30}) do
          acc -> put_px(acc, x, y, color)
        end

      assert Vision.hp_bar_row_positions(frame) == [12, 64]
    end

    test "no bars → [] (empty rows carry no HP bar)" do
      assert Vision.hp_bar_row_positions(uniform(60, 60, {30, 30, 30})) == []
    end

    test "a run shorter than min_run (speckle / sparse red name) yields no position" do
      frame =
        for x <- 0..5, reduce: uniform(60, 60, {30, 30, 30}) do
          acc -> put_px(acc, x, 20, {200, 40, 40})
        end

      assert Vision.hp_bar_row_positions(frame) == []
    end
  end

  describe "pokeball_row_positions/2 (own-pokemon rows)" do
    import Pokex.FrameFixtures

    test "returns the CENTER y of EVERY pokeball icon (all wilds, not just the topmost)" do
      frame =
        for yrange <- [8..13, 40..45],
            y <- yrange,
            x <- 0..15,
            reduce: uniform(30, 60, {20, 20, 20}) do
          acc -> put_px(acc, x, y, {230, 40, 40})
        end

      assert Vision.pokeball_row_positions(frame) == [10, 42]
    end

    test "no pokeball → []" do
      assert Vision.pokeball_row_positions(uniform(30, 60, {20, 20, 20})) == []
    end

    test "a run shorter than min_count (stray red pixel) is not a pokeball" do
      frame =
        for x <- 0..3, reduce: uniform(30, 60, {20, 20, 20}) do
          acc -> put_px(acc, x, 20, {230, 40, 40})
        end

      assert Vision.pokeball_row_positions(frame) == []
    end
  end
end
