defmodule PokexWeb.ScreenMismatchStripTest do
  @moduledoc """
  The strip that says "esta calibração não é desta tela" — on every page, and
  on the calibration page carrying the fix itself.

  These guarantees used to belong to a box inside /calibration only, which is
  precisely why switching monitors told him nothing (Lucas, 2026-08-10).
  """
  use PokexWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PokexWeb.Layouts

  defp strip(check, page \\ :panel),
    do: render_component(&Layouts.screen_mismatch_strip/1, check: check, current_page: page)

  test "says nothing when the screens agree, or when nothing can be compared" do
    refute strip(:same) =~ "tela"
    refute strip(:unknown) =~ "tela"
  end

  # One calibration per MONITOR (Lucas, 2026-08-07): a monitor calibrated before
  # offers its last calibration back in one click; only a truly new monitor is
  # asked for the wizard.
  test "a different screen offers its last calibration back — or the wizard when new" do
    html = strip({:another_screen, {3440, 1440}, {1512, 982}}, :calibration)

    assert html =~ "outra tela"
    assert html =~ "3440×1440"
    assert html =~ "1512×982"
    # no snapshot for 1512×982 in this test env → the wizard path, said plainly
    assert html =~ "nunca foi calibrada"
    refute html =~ "rescale_calibration"
  end

  test "a pure scale error offers the one-click repair instead of 10 steps" do
    html = strip({:rescalable, {4952, 2073}, {3440, 1440}}, :calibration)

    assert html =~ "régua errada"
    assert html =~ "3440×1440"
    assert html =~ "rescale_calibration"
  end

  # The fix is a LiveView event on the calibration page: rendering the button
  # anywhere else would be a click that goes nowhere. Off that page the strip
  # links TO it instead.
  test "off the calibration page it links there instead of pretending to fix" do
    html = strip({:rescalable, {4952, 2073}, {3440, 1440}}, :panel)

    refute html =~ "rescale_calibration"
    assert html =~ "/calibration"
    assert html =~ "Resolver"
  end
end
