defmodule Pokex.Bots.MinimapStepTest do
  @moduledoc """
  Walking by clicking the minimap — the primitive the cavebot will stand on.

  The scale is measured, not chosen: between two committed captures the printed
  coordinate moved (-5, -11) tiles while the map image shifted (+10, +22)
  pixels, at 98.5% correlation. Two pixels per tile, on both axes.
  """
  use ExUnit.Case, async: false

  alias Pokex.{Layout, ScreenFixtures, Settings}
  alias Pokex.Bots.Body

  setup do
    {:ok, fix} = Layout.locate(ScreenFixtures.frame!("ultrawide_3440x1440_time"))
    {:ok, _} = Pokex.Rig.Fake.start_link()
    %{fix: fix}
  end

  defp click_point(dx, dy, fix) do
    assert {:ok, point} = Body.minimap_step(dx, dy, layout: fix)
    point
  end

  test "standing still clicks the player's own tile — the map's centre", %{fix: fix} do
    {x, y, w, h} = Layout.region(:minimap_map, fix)

    assert click_point(0, 0, fix) == {x + div(w, 2), y + div(h, 2)}
  end

  test "a step east is two pixels east, per the measured scale", %{fix: fix} do
    {cx, cy} = click_point(0, 0, fix)
    scale = Settings.get(:minimap_px_per_tile)

    assert click_point(1, 0, fix) == {cx + scale, cy}
    assert click_point(0, 1, fix) == {cx, cy + scale}
    assert click_point(-10, -10, fix) == {cx - 10 * scale, cy - 10 * scale}
  end

  test "a destination beyond the map is clamped INSIDE it, never onto the frame", %{fix: fix} do
    {x, y, w, h} = Layout.region(:minimap_map, fix)

    {far_x, far_y} = click_point(10_000, 10_000, fix)
    assert far_x < x + w and far_y < y + h
    assert far_x > x and far_y > y

    {near_x, near_y} = click_point(-10_000, -10_000, fix)
    assert near_x > x and near_y > y
  end

  test "the click really goes through the Body, as a left click", %{fix: fix} do
    point = click_point(3, -4, fix)

    assert Enum.any?(Pokex.Rig.Fake.calls(), &match?({:click, :left, ^point}, &1))
  end

  # A test that asserts an ABSENCE has to create that absence. `layout: nil` does
  # not disable the fallback — Body falls through to Layout.current(), which reads
  # the global fact and then the persisted file. So this passed only while no
  # other test happened to leave a layout behind, and broke the day one did.
  @tag :tmp_dir
  test "with no layout it refuses instead of clicking somewhere plausible", %{tmp_dir: tmp} do
    Pokex.Perception.WorldState.forget(:layout)
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

    assert Body.minimap_step(1, 1, layout: nil) == {:error, :no_layout}
  end
end
