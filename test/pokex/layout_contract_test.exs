defmodule Pokex.LayoutContractTest do
  @moduledoc """
  The layout must be resolved ONCE per tick and travel with the calibration.

  The bug this guards: the feed picked its capture region from one lookup and
  the interpreter offset its reads from another. A re-locate landing between
  the two shifts every reading — silently, because both lookups succeed.
  """
  use ExUnit.Case, async: false

  alias Pokex.{Calibration, Layout}
  alias Pokex.Perception.WorldState

  setup do
    # one shared blackboard: start from an empty world, never from the last test's
    WorldState.clear()

    on_exit(fn -> WorldState.forget(:layout) end)
    :ok
  end

  test "a loaded calibration carries the layout in force" do
    {:ok, fix} = Layout.locate(Pokex.ScreenFixtures.frame!("ultrawide_3440x1440_full"))

    WorldState.put(
      :layout,
      %{
        "profile" => fix.profile,
        "anchors" => Map.new(fix.anchors, fn {k, {x, y}} -> {Atom.to_string(k), [x, y]} end),
        "regions" =>
          Map.new(fix.regions, fn {k, {x, y, w, h}} -> {Atom.to_string(k), [x, y, w, h]} end),
        "region_opts" => %{},
        "located_at" => DateTime.to_iso8601(DateTime.utc_now())
      },
      System.monotonic_time(:millisecond)
    )

    assert %Calibration{layout: %Layout.Fix{}} = calib = calibration!()
    assert Layout.region(:hud_bottom, calib.layout) == fix.regions.hud_bottom
  end

  test "every layout-derived feed takes its region from the calibration it was handed" do
    # If a spec ever reaches for a fresh lookup instead, this fails: the calib
    # here carries a DELIBERATELY different fix than the one on the blackboard.
    {:ok, %Layout.Fix{} = real} =
      Layout.locate(Pokex.ScreenFixtures.frame!("ultrawide_3440x1440_full"))

    shifted = %Layout.Fix{
      real
      | regions: Map.new(real.regions, fn {k, {x, y, w, h}} -> {k, {x + 7, y + 7, w, h}} end)
    }

    calib = %Calibration{scale: 1.0, layout: shifted}

    for spec <- Pokex.Perception.feed_specs(), spec.key in [:hud, :team, :minimap] do
      {x, y, _w, _h} = spec.region.(calib)
      {rx, ry, _rw, _rh} = Map.fetch!(real.regions, region_key(spec.key))

      assert {x, y} == {rx + 7, ry + 7},
             "feed #{spec.key} ignored the calibration's layout and looked one up itself"
    end
  end

  defp region_key(:hud), do: :hud_bottom
  defp region_key(:team), do: :team_column
  defp region_key(:minimap), do: :minimap

  defp calibration! do
    {:ok, calib} = Calibration.load(fixture_path())
    calib
  end

  defp fixture_path do
    path = Path.join(System.tmp_dir!(), "pokex-layout-contract-calib.json")

    File.write!(
      path,
      JSON.encode!(%{
        "scale" => 1.0,
        "screen_w" => 3440,
        "screen_h" => 1440,
        "water_point" => [1, 1],
        "glow_region" => [0, 0, 8, 8],
        "battle_region" => [0, 0, 80, 400],
        "neutral_point" => [500, 500]
      })
    )

    path
  end
end
