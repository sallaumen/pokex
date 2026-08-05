defmodule Pokex.CalibrationMiniGameTest do
  @moduledoc """
  Mini-game region: MANUAL ONLY — no mark, no guess.

  The history, because every ghost here bit in the field: the auto-layout strip
  assumed the game window never moved (it did — same root as the y=-132
  minimap) and silently vetoed manual calibration; the half-screen central box
  was "aquela área grandona" nobody recognised; and the character-anchored tile
  box read a dark trunk column + bright-blue flowers as "bar + capsule" at a
  rocky spot (2026-08-05), flapping enter/exit once a second and holding the
  whole fleet. Scenery is too creative to out-guess. Without a hand-marked
  strip the resolver answers nil and the watcher goes blind AND SAYS SO.
  """
  use ExUnit.Case, async: false

  alias Pokex.{Calibration, Layout}
  alias Pokex.Perception.WorldState

  @measured {3067, 800, 28, 479}

  setup do
    # one shared blackboard: start from an empty world, never from the last test's
    WorldState.clear()

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

  test "a manual mark is the ONLY authority — layout strip never resolves", %{fix: fix} do
    hand_marked = %Calibration{
      scale: 1.0,
      screen_w: 3440,
      screen_h: 1440,
      mini_game_region: {2976, 555, 113, 773},
      layout: fix
    }

    assert Calibration.mini_game_region(hand_marked) == {2976, 555, 113, 773}
  end

  test "without a manual mark the resolver answers nil — no guessed box, ever", %{fix: fix} do
    # both guessed defaults false-positived in the field; nil is what makes the
    # watcher go blind-and-declared instead of scanning scenery
    unmarked = %Calibration{scale: 1.0, screen_w: 3440, screen_h: 1440, layout: fix}
    assert Calibration.mini_game_region(unmarked) == nil

    with_player = %Calibration{
      scale: 1.0,
      screen_w: 3440,
      screen_h: 1440,
      player_point: {1690, 695},
      layout: nil
    }

    assert Calibration.mini_game_region(with_player) == nil

    assert Calibration.mini_game_region(%Calibration{scale: 1.0}) == nil
  end
end
