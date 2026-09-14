defmodule Pokex.Screen.BarOffsetTest do
  use ExUnit.Case, async: true

  alias Pokex.Screen.BarOffset

  # THE RULER IS HIS OWN CHARACTER, the only hand-marked point on the screen.
  # In the black box of 14/09 (`20260914T025428Z-shiny`, frame 000) his
  # `player_point` is (1695, 686), his own name line sits at y 617 — 69 px above
  # it — and the Golem standing one tile below him publishes (1720, 918) while
  # its drawn body is at y ~808. The published point is one tile below the bar by
  # construction (`CrowdScan.place/4`) and the bar floats only 69 px over the
  # creature's foot, so the point lands 110 px UNDER the body.
  describe "the vector from the published point to the body" do
    test "on his ultrawide it lifts the aim by the tile the eye added" do
      assert {:ok, {0, -110}} = BarOffset.for_screen({3440, 1440})
    end

    # A BOLA JOGAVA PRA BAIXO. Whatever the sign argument, the aim must end up
    # ABOVE the point the eye published — never below it, which is the defect
    # Lucas saw on 14/09 ("ele jogou pra baixo, tem que ser mais pra cima").
    test "every measured screen aims ABOVE the published point, never below" do
      for {screen, {_dx, dy}} <- BarOffset.known() do
        assert dy < 0, "#{inspect(screen)} empurra a bola pra baixo: #{dy}"
      end
    end

    test "a screen nobody measured refuses instead of guessing" do
      assert :unknown = BarOffset.for_screen({1512, 982})
      assert :unknown = BarOffset.for_screen({nil, nil})
    end
  end
end
