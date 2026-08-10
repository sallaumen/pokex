defmodule Pokex.Bots.MinimapStepTest do
  @moduledoc """
  Walking by clicking the minimap — the primitive the cavebot will stand on.

  The scale is measured, not chosen: between two committed captures the printed
  coordinate moved (-5, -11) tiles while the map image shifted (+10, +22)
  pixels, at 98.5% correlation. Two pixels per tile, on both axes.
  """
  use ExUnit.Case, async: false

  alias Pokex.Bots.Body
  alias Pokex.Bots.InputGate
  alias Pokex.Layout
  alias Pokex.Perception.WorldState
  alias Pokex.Rig.Fake
  alias Pokex.ScreenFixtures
  alias Pokex.Settings

  setup do
    # one shared blackboard: start from an empty world, never from the last test's
    WorldState.clear()

    # Every step here is a CLICK, and the safety gate that allows it is global:
    # a suite that left it shut turned all of these into
    # {:error, :input_gate_closed}. State the precondition instead of inheriting it.
    InputGate.set_corner_ok(true)
    InputGate.set_focus_ok(true)

    {:ok, fix} = Layout.locate(ScreenFixtures.frame!("ultrawide_3440x1440_time"))
    {:ok, _} = Fake.start_link()
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

  # Hovering slides controls over the map's edges (clock bar top, floor arrows
  # left, zoom right, buttons bottom) and the cursor IS hovering on every walk
  # click — an edge-clamped click would press a control instead of walking.
  test "the clamp stays clear of the hover-control ring, not just the frame", %{fix: fix} do
    {x, y, w, h} = Layout.region(:minimap_map, fix)

    {far_x, far_y} = click_point(10_000, 10_000, fix)
    assert far_x <= x + w - 1 - 28 and far_y <= y + h - 1 - 28

    {near_x, near_y} = click_point(-10_000, -10_000, fix)
    assert near_x >= x + 28 and near_y >= y + 32
  end

  test "the click really goes through the Body, as a left click", %{fix: fix} do
    point = click_point(3, -4, fix)

    assert Enum.any?(Fake.calls(), &match?({:click, :left, ^point}, &1))
  end

  # A test that asserts an ABSENCE has to create that absence. `layout: nil` does
  # not disable the fallback — Body falls through to Layout.current(), which reads
  # the global fact and then the persisted file. So this passed only while no
  # other test happened to leave a layout behind, and broke the day one did.
  @tag :tmp_dir
  test "with no layout it refuses instead of clicking somewhere plausible", %{tmp_dir: tmp} do
    WorldState.forget(:layout)
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

    assert Body.minimap_step(1, 1, layout: nil) == {:error, :no_layout}
  end

  # The Rig swallows input with the gate closed and answers `:ok` — on purpose; the rest of
  # the fleet depends on that. A walker cannot inherit that answer: a suppressed click
  # returned as `{:ok, point}` makes Logic believe progress that never happened (this
  # silently downed the fleet when Iniciar was clicked in the browser).
  test "with the input gate closed it refuses instead of lying that it clicked", %{fix: fix} do
    InputGate.set_focus_ok(false)
    on_exit(fn -> InputGate.set_focus_ok(true) end)

    assert Body.minimap_step(3, -4, layout: fix) == {:error, :input_gate_closed}
    refute Enum.any?(Fake.calls(), &match?({:click, :left, _point}, &1))
  end

  describe "the calibrated cross (the hand rules the step)" do
    test "the step starts from the marked cross, not the rectangle's center", %{fix: fix} do
      {x, y, w, h} = Layout.region(:minimap_map, fix)
      cross = {x + div(w, 2) + 5, y + div(h, 2) - 8}

      calib = %Pokex.Calibration{
        scale: 1.0,
        layout: fix,
        minimap_player_point: cross
      }

      scale = Settings.get(:minimap_px_per_tile)
      assert {:ok, point} = Body.minimap_step(0, 0, calib: calib)
      assert point == cross

      assert {:ok, east} = Body.minimap_step(1, 0, calib: calib)
      assert east == {elem(cross, 0) + scale, elem(cross, 1)}
    end

    test "a manual minimap region works as the click area — with no layout at all" do
      calib = %Pokex.Calibration{
        scale: 1.0,
        layout: nil,
        minimap_region: {3000, 100, 200, 200},
        minimap_player_point: {3100, 200}
      }

      assert {:ok, {3100, 200}} = Body.minimap_step(0, 0, calib: calib)

      assert {:ok, {cx, _cy}} = Body.minimap_step(500, 0, calib: calib)
      assert cx <= 3000 + 200 - 1 - 6
    end
  end

  # Lucas's 2026-08-10 direction: walking is ARROW KEYS now — one press = one
  # sqm in the right direction, and the position CHANGE is what makes the
  # coordinate label render. The minimap click stays as a primitive, but the
  # cavebot stands on this.
  describe "arrow_step" do
    test "presses the dominant axis's arrow; the game's y grows SOUTH" do
      assert {:ok, "right"} = Body.arrow_step(5, 2)
      assert {:ok, "left"} = Body.arrow_step(-3, 1)
      assert {:ok, "down"} = Body.arrow_step(1, 4)
      assert {:ok, "up"} = Body.arrow_step(0, -2)

      assert Enum.filter(Fake.calls(), &match?({:press, _}, &1)) ==
               [{:press, "right"}, {:press, "left"}, {:press, "down"}, {:press, "up"}]
    end

    # The calibration's step: an UNGATED press (Rig.Mac.tap/1) — the gate's
    # corner flag is proven by the Guardian, which only polls with the fleet
    # up, so nothing could ever press during calibration. Here the wiring is
    # what is provable: the Body's {:tap, _} reaches the Rig as a tap.
    test "a {:tap, key} action reaches the Rig on its own path" do
      assert Body.perform([{:tap, "right"}]) == :ok
      assert Enum.any?(Fake.calls(), &match?({:tap, "right"}, &1))
    end

    # The rehearsal's DEFAULT hands, all the way down to the Rig: this is the
    # chain that was broken in the field (a nested module that resolved to
    # nothing), and the fake body in its own test could never have caught it.
    test "the rehearsal's hands press for real, through the Body, ungated" do
      assert Pokex.Bots.Cavebot.Hands.arrow_step(4, 1, []) == {:ok, "right"}
      assert Enum.any?(Fake.calls(), &match?({:tap, "right"}, &1))
    end

    test "refuses out loud: no direction, and a shut gate" do
      assert Body.arrow_step(0, 0) == {:error, :no_direction}

      InputGate.set_focus_ok(false)
      on_exit(fn -> InputGate.set_focus_ok(true) end)
      assert Body.arrow_step(3, 0) == {:error, :input_gate_closed}
    end
  end
end
