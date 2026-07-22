defmodule Pokex.CalibrationMiniGameTest do
  @moduledoc """
  The mini-game strip is auto-located, not hand-marked.

  It looked like a world point (it is inside the game viewport), which is why
  the original design left it manual — but it is FIXED on screen, proven by
  Lucas's own profiles: `2-moni-8skill` was calibrated when the battle panel
  sat at y=287, he later enlarged the minimap and pushed that panel to y=460,
  and the strip stayed correct. Its rect here IS that profile's measured
  value.
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

  test "the layout carries the measured strip", %{fix: fix} do
    assert Layout.region(:mini_game, fix) == @measured
  end

  test "a FIXED region ignores where the anchors landed — anchored ones do not" do
    profile = Layout.profile()
    frame = Pokex.ScreenFixtures.frame!("ultrawide_3440x1440_full")

    # pretend the battle panel sits 173px higher (where it was in 2-moni-8skill)
    higher = put_in(profile, ["anchors", "battle_header", "measured_at"], [3184, 287])

    {:ok, now} = Layout.locate(frame, profile)
    {:ok, then_} = Layout.locate(frame, higher)

    # anchored regions follow the panel — the strip does not
    assert Layout.region(:battle_list, now) == Layout.region(:battle_list, then_)
    assert Layout.region(:mini_game, now) == @measured
    assert Layout.region(:mini_game, then_) == @measured
  end

  test "the located layout WINS over a drifted hand-marked value", %{fix: fix} do
    hand_marked = %Calibration{
      scale: 1.0,
      screen_w: 3440,
      screen_h: 1440,
      # the value that had drifted in his live calibration.json
      mini_game_region: {2976, 555, 113, 773},
      layout: fix
    }

    assert Calibration.mini_game_region(hand_marked) == @measured
  end

  test "the override is never silent — the page says the layout is in charge", %{fix: fix} do
    # a user who marks the strip by hand must not be left wondering why the bot
    # searches somewhere else
    assert Layout.region(:mini_game, fix) != nil
    assert Layout.region(:mini_game, nil) == nil
  end

  test "without a layout it falls back to the hand-marked value, then the arena" do
    blind = %Calibration{scale: 1.0, mini_game_region: {1, 2, 3, 4}, layout: nil}
    assert Calibration.mini_game_region(blind) == {1, 2, 3, 4}

    arena_only = %Calibration{scale: 1.0, arena_region: {10, 20, 30, 40}, layout: nil}
    assert Calibration.mini_game_region(arena_only) == {10, 20, 30, 40}

    whole_screen = %Calibration{scale: 1.0, screen_w: 3440, screen_h: 1440, layout: nil}
    assert Calibration.mini_game_region(whole_screen) == {0, 0, 3440, 1440}
  end
end
