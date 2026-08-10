defmodule PokexWeb.CavebotMapTest do
  @moduledoc """
  The route drawn instead of listed. The geometry is pure, so the property that
  matters — every point is INSIDE the view — is checkable without rendering
  anything.
  """
  use ExUnit.Case, async: true

  alias PokexWeb.CavebotMap

  defp inside?(%{box: {bx, by, w, h}}, %{x: x, y: y}),
    do: x >= bx and x <= bx + w and y >= by and y <= by + h

  test "the view covers every point, with margin around the extremes" do
    points = [%{x: 100, y: 200}, %{x: 140, y: 260}, %{x: 90, y: 210}]
    view = CavebotMap.view(points)

    assert Enum.all?(points, &inside?(view, &1))

    # margin: the extremes are not ON the edge
    {bx, by, w, h} = view.box
    assert bx < 90 and by < 200
    assert bx + w > 140 and by + h > 260
  end

  test "a single waypoint gets a floor span, never an infinite zoom" do
    view = CavebotMap.view([%{x: 10, y: 10}])
    {_bx, _by, w, h} = view.box

    assert w >= 12 and h >= 12
    assert view.unit > 0
  end

  test "the box is square: shape must not change with the route's direction" do
    tall = CavebotMap.view([%{x: 0, y: 0}, %{x: 2, y: 80}])
    wide = CavebotMap.view([%{x: 0, y: 0}, %{x: 80, y: 2}])

    {_x, _y, tw, th} = tall.box
    {_x2, _y2, ww, wh} = wide.box

    assert tw == th
    assert ww == wh
    assert tw == ww
  end

  test "nothing to draw is nil, not an empty box" do
    assert CavebotMap.view([]) == nil
  end

  test "arrow/2 sits at the midpoint and points along the segment" do
    assert %{x: 5.0, y: +0.0, angle: +0.0} = CavebotMap.arrow(%{x: 0, y: 0}, %{x: 10, y: 0})
    # y grows SOUTH in the game, so a southward leg points +90
    assert %{x: +0.0, y: 5.0, angle: 90.0} = CavebotMap.arrow(%{x: 0, y: 0}, %{x: 0, y: 10})
  end

  test "distances are walked tiles — the honest length of a hunt" do
    points = [%{x: 0, y: 0}, %{x: 3, y: 0}, %{x: 3, y: 4}]

    assert CavebotMap.tiles_between(Enum.at(points, 0), Enum.at(points, 1)) == 3
    assert CavebotMap.tiles_between(nil, Enum.at(points, 1)) == nil
    assert CavebotMap.total_tiles(points) == 7
    assert CavebotMap.total_tiles([]) == 0
  end

  test "the attributes render as SVG expects them" do
    view = CavebotMap.view([%{x: 0, y: 0}, %{x: 10, y: 10}])

    assert CavebotMap.box_attr(view) =~ ~r/^-?\d+\.\d+ -?\d+\.\d+ \d+\.\d+ \d+\.\d+$/
    assert CavebotMap.path_attr([%{x: 1, y: 2}, %{x: 3, y: 4}]) == "1,2 3,4"
  end
end
