defmodule Pokex.Screen.DisplayTest do
  # async: false — the filmed display is ONE :persistent_term for the whole VM,
  # the same trap calibration has: whatever a test writes, every other test
  # reads. Put it back in on_exit or the next suite runs on another monitor.
  use ExUnit.Case, async: false

  alias Pokex.Screen.Display

  setup do
    antes = Display.region()

    on_exit(fn ->
      case antes do
        :unknown -> Display.forget()
        region -> Display.put(region)
      end
    end)

    :ok
  end

  describe "with no proof" do
    test "the main display is assumed, which is the behaviour the house always had" do
      Display.forget()

      assert Display.region() == :unknown
      assert Display.origin() == {0, 0}
      assert Display.main?()
      assert Display.to_global({100, 200}) == {100, 200}
      assert Display.to_local({100, 200}) == {100, 200}
    end
  end

  describe "with the game on another monitor" do
    setup do
      # Measured on Lucas's machine 2026-09-14: the built-in screen sits to the
      # right of and below the ultrawide.
      Display.put({3440, 1007, 1512, 982})
      :ok
    end

    test "a point the eye read reaches the mouse on the right screen" do
      assert Display.origin() == {3440, 1007}
      refute Display.main?()

      # his calibrated player_point on the notebook profile
      assert Display.to_global({749, 507}) == {4189, 1514}
    end

    test "a point the mouse reported comes back in the coordinates the eye uses" do
      assert Display.to_local({4189, 1514}) == {749, 507}
    end

    test "the round trip is the identity — crossing twice is the bug this guards" do
      point = {749, 507}
      assert point |> Display.to_global() |> Display.to_local() == point
      refute Display.to_global(Display.to_global(point)) == Display.to_global(point)
    end

    test "a calibrated region travels as a rectangle, keeping its size" do
      assert Display.to_global_region({45, 314, 121, 12}) == {3485, 1321, 121, 12}
    end
  end

  test "the main display at the origin is not 'another screen'" do
    Display.put({0, 0, 3440, 1440})

    assert Display.main?()
    assert Display.to_global({10, 20}) == {10, 20}
  end
end
