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

  test "without a manual mark, the default search is the central box — never the layout strip", %{
    fix: fix
  } do
    unmarked = %Calibration{scale: 1.0, screen_w: 3440, screen_h: 1440, layout: fix}

    assert Calibration.mini_game_region(unmarked) == {860, 360, 1720, 720}
  end

  test "the central box prefers the arena's middle (the game's middle) over the screen's" do
    arena_only = %Calibration{scale: 1.0, arena_region: {1000, 100, 2000, 1200}, layout: nil}
    assert Calibration.mini_game_region(arena_only) == {1500, 400, 1000, 600}

    whole_screen = %Calibration{scale: 1.0, screen_w: 3440, screen_h: 1440, layout: nil}
    assert Calibration.mini_game_region(whole_screen) == {860, 360, 1720, 720}

    blind = %Calibration{scale: 1.0, mini_game_region: {1, 2, 3, 4}, layout: nil}
    assert Calibration.mini_game_region(blind) == {1, 2, 3, 4}

    assert Calibration.mini_game_region(%Calibration{scale: 1.0}) == nil
  end
end
