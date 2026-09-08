defmodule Pokex.Screen.TileTest do
  use ExUnit.Case, async: true

  alias Pokex.Screen.Tile

  test "his two screens, as measured" do
    assert Tile.for_screen({3440, 1440}) == {:ok, 151}
    assert Tile.for_screen({1512, 982}) == {:ok, 36}
  end

  test "a screen nobody measured has no tile, and a missing screen neither" do
    assert Tile.for_screen({2000, 1200}) == :unknown
    assert Tile.for_screen({nil, nil}) == :unknown
    assert Tile.for_screen(nil) == :unknown
  end

  test "the known screens read largest first, in one sentence" do
    assert Tile.known() == [{{3440, 1440}, 151}, {{1512, 982}, 36}]
    assert Tile.known_text() == "3440×1440 → 151, 1512×982 → 36"
  end
end
