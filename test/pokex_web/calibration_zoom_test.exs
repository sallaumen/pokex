defmodule PokexWeb.CalibrationZoomTest do
  @moduledoc """
  The magnifier was suspected twice of misplacing marks (2026-08-06) and could
  not be checked: no test, only a derivation on paper. These pin the two
  properties the marking flow actually depends on.
  """
  use ExUnit.Case, async: true

  alias PokexWeb.CalibrationZoom

  @screen %{w: 1512, h: 982}
  @factor 3.5

  describe "style/3" do
    test "nothing zoomed, or a screen with no size, means no transform" do
      assert CalibrationZoom.style(nil, @screen, @factor) == nil
      assert CalibrationZoom.style({100, 100}, %{w: 0, h: 982}, @factor) == nil
      assert CalibrationZoom.style({100, 100}, %{w: 1512, h: 0}, @factor) == nil
    end

    test "a zoomed point scales from the top-left and translates" do
      style = CalibrationZoom.style({756, 491}, @screen, @factor)

      # dead centre: 0.5 - 0.5*3.5 = -1.25 → -125%
      assert style =~ "translate(-125.0%, -125.0%)"
      assert style =~ "scale(3.5)"
      assert style =~ "transform-origin: 0 0"
    end
  end

  describe "visible_at/2 — the property that matters" do
    # THE 2026-07-20 BUG: with transform-origin pinning, the skill bar's
    # bottom-right corner fell OUTSIDE the zoom window and read as "não consigo
    # clicar na última skill". Whatever you zoom on must be reachable.
    test "every point of the screen stays inside the window it zooms into" do
      for f <- [0.0, 0.001, 0.125, 0.25, 0.5, 0.75, 0.9285, 0.999, 1.0],
          factor <- [2.0, 3.5, 6.0] do
        at = CalibrationZoom.visible_at(f, factor)

        assert at >= -0.001 and at <= 1.001,
               "fraction #{f} at #{factor}× landed at #{at} — outside the window"
      end
    end

    test "a point far from the edges lands dead centre" do
      assert_in_delta CalibrationZoom.visible_at(0.5, @factor), 0.5, 0.001
      assert_in_delta CalibrationZoom.visible_at(0.3, @factor), 0.5, 0.001
    end

    # Clamping is what keeps the magnified image flush with the edges: near a
    # border the point CANNOT be centred without showing blank gutter, so it
    # stops short — visible, just not in the middle.
    test "near the edges the window stops instead of showing blank gutter" do
      assert CalibrationZoom.translate_pct(0.02, @factor) == 0.0
      assert CalibrationZoom.translate_pct(0.99, @factor) == -250.0
      assert CalibrationZoom.visible_at(0.0, @factor) == 0.0
      assert_in_delta CalibrationZoom.visible_at(1.0, @factor), 1.0, 0.001
    end
  end
end
