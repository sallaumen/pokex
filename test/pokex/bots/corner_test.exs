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

    test "without a screen width (missing calibration) there is no corner" do
      refute Corner.in_command_corner?({3435, 5}, nil)
      refute Corner.in_command_corner?(nil, 3440)
    end
  end
end
