defmodule PokexWeb.CalibrationOverlayTest do
  use PokexWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PokexWeb.CalibrationOverlay

  describe "screen_warning" do
    test "says nothing when the screen agrees, or when nothing can be compared" do
      assert render_component(&CalibrationOverlay.screen_warning/1, check: :same) =~ ""
      refute render_component(&CalibrationOverlay.screen_warning/1, check: :same) =~ "tela"
      refute render_component(&CalibrationOverlay.screen_warning/1, check: :unknown) =~ "tela"
    end

    # One calibration per MONITOR (Lucas, 2026-08-07): a monitor calibrated
    # before offers its last calibration back in one click; only a truly new
    # monitor is asked for the wizard.
    test "a different screen offers its last calibration back — or the wizard when new" do
      html =
        render_component(&CalibrationOverlay.screen_warning/1,
          check: {:another_screen, {3440, 1440}, {1512, 982}}
        )

      assert html =~ "outra tela"
      assert html =~ "3440×1440"
      assert html =~ "1512×982"
      # no snapshot for 1512×982 in this test env → the wizard path, said plainly
      assert html =~ "nunca foi calibrada"
      refute html =~ "rescale_calibration"
    end

    test "a pure scale error offers the one-click repair instead of 10 steps" do
      html =
        render_component(&CalibrationOverlay.screen_warning/1,
          check: {:rescalable, {4952, 2073}, {3440, 1440}}
        )

      assert html =~ "régua errada"
      assert html =~ "3440×1440"
      assert html =~ "rescale_calibration"
    end
  end

  describe "scan_region overlay" do
    test "draws the corpse search square as a percentage of the screen" do
      html =
        render_component(&CalibrationOverlay.overlays/1,
          screen: %{w: 1000, h: 500},
          scan_region: {100, 50, 200, 100}
        )

      assert html =~ "busca de corpos"
      assert html =~ "left:10.0%;top:10.0%;width:20.0%;height:20.0%"
    end

    test "draws nothing without a search square" do
      html = render_component(&CalibrationOverlay.overlays/1, screen: %{w: 1000, h: 500})

      refute html =~ "busca de corpos"
    end
  end
end
