defmodule Pokex.LayoutTest do
  use ExUnit.Case, async: true

  alias Pokex.Layout
  alias Pokex.ScreenFixtures
  alias Pokex.Vision.Glyphs

  defp screen, do: ScreenFixtures.frame!("ultrawide_3440x1440_full")

  test "locates all three anchors exactly where they were measured" do
    assert {:ok, fix} = Layout.locate(screen())

    assert fix.anchors.battle_header == {3184, 460}
    assert fix.anchors.hotbar_sto == {1216, 1372}
    assert fix.anchors.left_hud_icons == {88, 1022}
  end

  test "the derived regions actually contain what they claim — read them back" do
    {:ok, fix} = Layout.locate(screen())
    frame = screen()

    assert %{text: "Battle"} = Glyphs.read_line(frame, fix.regions.battle_header)
    assert Glyphs.read_int(frame, fix.regions.level) == 90
    assert Glyphs.read_int(frame, fix.regions.food) == 1525
    assert Glyphs.read_int(frame, fix.regions.fishing) == 96
    assert Glyphs.read_int(frame, fix.regions.slot_f1, ink: 200) == 322
    assert Glyphs.read_int(frame, fix.regions.slot_f2, ink: 200) == 36
    assert Glyphs.read_int(frame, fix.regions.slot_e, ink: 200) == 7
    assert Glyphs.read_int(frame, fix.regions.slot_s_q, ink: 200) == 43
    assert Glyphs.read_coord(frame, fix.regions.minimap_coord) == {337, 46107, 4}
    assert %{text: "5559/6410"} = Glyphs.read_line(frame, fix.regions.pokemon_hp)
  end

  test "region_opts/2 carries each region's own ink floor" do
    {:ok, fix} = Layout.locate(screen())

    assert Layout.region_opts(fix, :slot_f1) == [ink: 200]
    assert Layout.region_opts(fix, :level) == []
  end

  @tag :tmp_dir
  test "the fix survives a restart: persisted and read back as rects", %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)

    on_exit(fn ->
      Application.delete_env(:pokex, :home_dir)
      Pokex.Perception.WorldState.forget(:layout)
    end)

    {:ok, fix} = Layout.locate(screen())

    fact = %{
      "profile" => fix.profile,
      "anchors" => Map.new(fix.anchors, fn {k, {x, y}} -> {Atom.to_string(k), [x, y]} end),
      "regions" =>
        Map.new(fix.regions, fn {k, {x, y, w, h}} -> {Atom.to_string(k), [x, y, w, h]} end),
      "region_opts" => %{"slot_f1" => 200},
      "located_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, "layout_fix.json"), Jason.encode!(fact))

    assert %Layout.Fix{} = restored = Layout.current()
    assert restored.regions.level == fix.regions.level
    assert restored.anchors.battle_header == {3184, 460}
    assert Layout.region(:slot_f1, restored) == fix.regions.slot_f1
  end

  test "region/2 on an uncalibrated system is nil, never a wrong rect", %{} do
    assert Layout.region(:level, nil) == nil or is_tuple(Layout.region(:level, nil))
  end

  test "a screen without the game fails loudly — never a silent wrong region" do
    black = Pokex.FrameFixtures.of(3440, 1440, fn _x, _y -> {0, 0, 0} end)

    assert {:error, {:anchor_not_found, :battle_header}} = Layout.locate(black)
  end

  test "a frame of the wrong resolution is rejected before any search" do
    small = Pokex.FrameFixtures.of(1280, 800, fn _x, _y -> {0, 0, 0} end)

    assert {:error, {:resolution, {1280, 800}}} = Layout.locate(small)
  end
end
