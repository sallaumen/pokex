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

  describe "the roll the calibration page picks from" do
    # His two monitors, 14/09: the game on the built-in, the bot on the ultrawide.
    @telas [
      %{id: 4, w: 3440, h: 1440, x: 0, y: 0, scale: 1.0, main?: true},
      %{id: 1, w: 1512, h: 982, x: 3440, y: 1007, scale: 2.0, main?: false}
    ]

    test "each screen is told apart by its FORMAT, the same string the profiles use" do
      [grande, pequena] =
        Display.roll(@telas, {:ok, {1512, 982}}, "", fn _screen -> true end)

      assert grande.size == "3440x1440"
      assert pequena.size == "1512x982"
      refute grande.filmed?
      assert pequena.filmed?
    end

    test "a format never calibrated is flagged, not hidden — it is the 'new screen' case" do
      calibrada? = fn {w, _h} -> w == 3440 end

      [grande, pequena] = Display.roll(@telas, :unknown, "", calibrada?)

      assert grande.calibrated?
      refute pequena.calibrated?
      # No proof of what is being filmed is not "the main one is".
      refute grande.filmed?
      refute pequena.filmed?
    end

    test "the pinned format is the one he chose, whatever is being filmed right now" do
      # Pinned the notebook while the eye still films the ultrawide: the page has
      # to show BOTH facts, because the difference is exactly what tells him the
      # camera has not restarted yet.
      [grande, pequena] =
        Display.roll(@telas, {:ok, {3440, 1440}}, "1512x982", fn _screen -> true end)

      refute grande.pinned?
      assert pequena.pinned?
      assert grande.filmed?
      refute pequena.filmed?
    end
  end

  test "the main display at the origin is not 'another screen'" do
    Display.put({0, 0, 3440, 1440})

    assert Display.main?()
    assert Display.to_global({10, 20}) == {10, 20}
  end
end
