defmodule Pokex.Bots.CornerTest do
  use ExUnit.Case, async: true
  alias Pokex.Bots.Corner

  test "the top-left corner (and any point within it) is the kill corner" do
    assert Corner.in_kill_corner?({0, 0})
    assert Corner.in_kill_corner?({10, 10})
    assert Corner.in_kill_corner?({0, 10})
    assert Corner.in_kill_corner?({10, 0})
  end

  test "just outside the corner is safe" do
    refute Corner.in_kill_corner?({11, 0})
    refute Corner.in_kill_corner?({0, 11})
    refute Corner.in_kill_corner?({11, 11})
    refute Corner.in_kill_corner?({500, 500})
  end

  # THE CERCA THAT THE MULTI-MONITOR WORK NEEDED. Cursor points are local to the
  # display the eye films, and a monitor above or to the left of the game's makes
  # them negative: with the game on Lucas's built-in screen, his whole ultrawide
  # is local x -3440..0, y -1007..433. An unbounded `<= 10` called all of that the
  # panic corner and the gate would have sat closed through most of a session.
  test "a point on ANOTHER monitor, left of or above the game, is not the corner" do
    refute Corner.in_kill_corner?({-3440, -1007})
    refute Corner.in_kill_corner?({-500, 5})
    refute Corner.in_kill_corner?({5, -500})
    refute Corner.in_kill_corner?({-1, -1})
  end

  test "garbage input is safe, not a crash" do
    refute Corner.in_kill_corner?(:not_a_point)
    refute Corner.in_kill_corner?(nil)
    refute Corner.in_kill_corner?({1, 2, 3})
    refute Corner.in_kill_corner?("0,0")
  end

  describe "command corner (top right)" do
    test "inside and outside, given the screen width; the panic corner never qualifies" do
      assert Corner.in_command_corner?({3435, 5}, 3440)
      assert Corner.in_command_corner?({3430, 10}, 3440)
      refute Corner.in_command_corner?({3420, 5}, 3440)
      refute Corner.in_command_corner?({3435, 30}, 3440)
      refute Corner.in_command_corner?({0, 0}, 3440)
    end

    # Same negative-coordinate trap as the panic corner: a monitor ABOVE the
    # game's makes y negative, and "above the top edge" is not "at the top edge".
    test "a point above the game's display is not the command corner" do
      refute Corner.in_command_corner?({3435, -1007}, 3440)
      refute Corner.in_command_corner?({1505, -5}, 1512)
    end

    test "without a screen width (missing calibration) there is no corner" do
      refute Corner.in_command_corner?({3435, 5}, nil)
      refute Corner.in_command_corner?(nil, 3440)
    end
  end
end
