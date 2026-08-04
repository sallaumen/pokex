defmodule Pokex.CalibrationMiniGameTest do
  @moduledoc """
  Mini-game region: the hand-marked value always wins (2026-07-30 inversion). The layout
  strip assumed the game window never moved — it did (same root as the y=-132 minimap),
  pointing wrong AND silently vetoing manual calibration. Without a hand mark the default
  search is a central half-by-half box (arena middle, else screen), never the layout strip.
  """
  use ExUnit.Case, async: false

  alias Pokex.{Calibration, Layout}
  alias Pokex.Perception.WorldState

  @measured {3067, 800, 28, 479}

  setup do
    on_exit(fn -> WorldState.forget(:layout) end)
    {:ok, fix} = Layout.locate(Pokex.ScreenFixtures.frame!("ultrawide_3440x1440_full"))
    %{fix: fix}
  end

  test "the layout still carries the measured strip (data, not authority)", %{fix: fix} do
    assert Layout.region(:mini_game, fix) == @measured
  end

  test "a FIXED region ignores where the anchors landed — anchored ones do not" do
    profile = Layout.profile()
    frame = Pokex.ScreenFixtures.frame!("ultrawide_3440x1440_full")

    higher = put_in(profile, ["anchors", "battle_header", "measured_at"], [3184, 287])

    {:ok, now} = Layout.locate(frame, profile)
    {:ok, then_} = Layout.locate(frame, higher)

    assert Layout.region(:battle_list, now) == Layout.region(:battle_list, then_)
    assert Layout.region(:mini_game, now) == @measured
    assert Layout.region(:mini_game, then_) == @measured
  end

  test "a manual mark beats the layout strip", %{fix: fix} do
    hand_marked = %Calibration{
      scale: 1.0,
      screen_w: 3440,
      screen_h: 1440,
      mini_game_region: {2976, 555, 113, 773},
      layout: fix
    }

    assert Calibration.mini_game_region(hand_marked) == {2976, 555, 113, 773}
  end

  test "without a manual mark, the default search hugs the character — never the layout strip", %{
    fix: fix
  } do
    unmarked = %Calibration{scale: 1.0, screen_w: 3440, screen_h: 1440, layout: fix}

    assert Calibration.mini_game_region(unmarked) == {1456, 456, 528, 880}
  end

  # The bar shows up over the CHARACTER, so he is the anchor. This used to be
  # the middle of a hand-marked "arena" — a rectangle inside a rectangle that
  # cost two clicks and taught the bot nothing.
  test "the default box follows the character, and is clamped to the screen" do
    off_centre = %Calibration{
      scale: 1.0,
      screen_w: 3440,
      screen_h: 1440,
      player_point: {1000, 500},
      layout: nil
    }

    assert Calibration.mini_game_region(off_centre) == {736, 236, 528, 880}

    at_the_edge = %Calibration{
      scale: 1.0,
      screen_w: 3440,
      screen_h: 1440,
      player_point: {3400, 1400},
      layout: nil
    }

    assert Calibration.mini_game_region(at_the_edge) == {2912, 560, 528, 880}

    whole_screen = %Calibration{scale: 1.0, screen_w: 3440, screen_h: 1440, layout: nil}
    assert Calibration.mini_game_region(whole_screen) == {1456, 456, 528, 880}

    blind = %Calibration{scale: 1.0, mini_game_region: {1, 2, 3, 4}, layout: nil}
    assert Calibration.mini_game_region(blind) == {1, 2, 3, 4}

    assert Calibration.mini_game_region(%Calibration{scale: 1.0}) == nil
  end

  test "a screen smaller than the box never yields a negative rectangle" do
    tiny = %Calibration{scale: 1.0, screen_w: 200, screen_h: 100, player_point: {10, 10}}

    assert Calibration.mini_game_region(tiny) == {0, 0, 200, 100}
  end

  # Every strip Lucas ever marked by hand (six saved profiles, character around
  # {1690,695}) must fall inside the automatic box — otherwise the bar he fishes
  # with is outside the search and the mini-game never sees it.
  test "the automatic box contains every strip he marked by hand" do
    calib = %Calibration{
      scale: 1.0,
      screen_w: 3440,
      screen_h: 1440,
      player_point: {1690, 695}
    }

    {bx, by, bw, bh} = Calibration.mini_game_region(calib)

    for {x, y, w, h} <- [{1674, 648, 29, 471}, {1580, 800, 240, 479}, {1580, 648, 240, 594}] do
      assert x >= bx and y >= by and x + w <= bx + bw and y + h <= by + bh,
             "hand-marked #{inspect({x, y, w, h})} escapes #{inspect({bx, by, bw, bh})}"
    end
  end
end
