defmodule Pokex.ScreenshotTest do
  use ExUnit.Case, async: false

  alias Pokex.Rig.Fake
  alias Pokex.Screenshot

  @moduletag :tmp_dir

  test "the screen is the display that was filmed, measured in points", %{tmp_dir: tmp} do
    fake_captures(tmp, screen: {3024, 1964}, probe: 200)

    assert {:ok, shot} = Screenshot.take("s.png")
    assert shot.scale == 2.0
    assert {shot.w, shot.h} == {1512, 982}
  end

  test "a retina-free display measures one pixel per point", %{tmp_dir: tmp} do
    fake_captures(tmp, screen: {3440, 1440}, probe: 100)

    assert {:ok, shot} = Screenshot.take("s.png")
    assert shot.scale == 1.0
    assert {shot.w, shot.h} == {3440, 1440}
  end

  test "an unmeasurable display makes the picture its own ruler", %{tmp_dir: tmp} do
    screen = png!(tmp, "screen.png", 800, 600)
    Agent.stop(Fake)
    {:ok, _} = Fake.start_link(%{capture_screen: [{:ok, screen}], capture: [{:error, :nope}]})

    assert {:ok, shot} = Screenshot.take("s.png")
    assert shot.scale == 1.0
    assert {shot.w, shot.h} == {800, 600}
  end

  defp fake_captures(tmp, screen: {px_w, px_h}, probe: probe_px) do
    screen = png!(tmp, "screen.png", px_w, px_h)
    probe = png!(tmp, "probe.png", probe_px, probe_px)
    Agent.stop(Fake)
    {:ok, _} = Fake.start_link(%{capture_screen: [{:ok, screen}], capture: [{:ok, probe}]})
  end

  defp png!(dir, name, w, h),
    do: Pokex.PngFixtures.solid!(Path.join(dir, name), w, h, {9, 9, 9, 255})

  setup do
    {:ok, _} = Fake.start_link()
    :ok
  end
end
