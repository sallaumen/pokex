defmodule PokexWeb.CalibrationOverlayTest do
  use PokexWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PokexWeb.CalibrationOverlay

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
