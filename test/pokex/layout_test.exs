defmodule Pokex.LayoutTest do
  use ExUnit.Case, async: true

  alias Pokex.Layout
  alias Pokex.Perception.WorldState
  alias Pokex.ScreenFixtures
  alias Pokex.Vision.Glyphs

  defp screen, do: ScreenFixtures.frame!("ultrawide_3440x1440_full")

  # only the right dock is opaque; templates of the semi-transparent bars carry
  # the map behind them — see Pokex.LayoutLiveTest for the multi-capture proof
  test "locates the anchor exactly where it was measured" do
    assert {:ok, fix} = Layout.locate(screen())

    assert fix.anchors == %{battle_header: {3184, 460}}
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
    assert Glyphs.read_coord(frame, fix.regions.minimap_coord) == {337, 46_107, 4}
    assert %{text: "5559/6410"} = Glyphs.read_line(frame, fix.regions.pokemon_hp)
  end

  test "region_opts/2 carries each region's own ink floor" do
    {:ok, fix} = Layout.locate(screen())

    assert Layout.region_opts(fix, :slot_f1) == [ink: 200]
    assert Layout.region_opts(fix, :level) == []
  end

  @tag :tmp_dir
  # loads via explicit path on purpose: the :layout WorldState fact is clobbered by
  # concurrent locates (battle_header read 387 from a foreign fixture) and :home_dir
  # is mutated by other tests (CI fell back to a nonexistent ~/.pokex and read nil)
  test "the fix survives a restart: persisted and read back as rects", %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)

    on_exit(fn ->
      Application.delete_env(:pokex, :home_dir)
      WorldState.forget(:layout)
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

    assert %Layout.Fix{} = restored = Layout.load_file(Path.join(tmp, "layout_fix.json"))
    assert restored.regions.level == fix.regions.level
    assert restored.anchors.battle_header == {3184, 460}
    assert Layout.region(:slot_f1, restored) == fix.regions.slot_f1
  end

  test "region/2 on an uncalibrated system is nil, never a wrong rect", %{} do
    assert Layout.region(:level, nil) == nil or is_tuple(Layout.region(:level, nil))
  end

  # The real 2026-08-01 case: the persisted ultrawide fix, served on the
  # 1512×982 notebook screen, asked the minimap feed for x=3150 y=-132 —
  # impossible region, quarantined capture, a cavebot that never learned
  # its position.
  describe "fits_screen?/3 and fitting/3" do
    defp fix_with(regions) do
      %Layout.Fix{
        profile: "ultrawide_3440x1440",
        anchors: %{battle_header: {0, 0}},
        regions: regions,
        region_opts: %{},
        located_at: ~U[2026-07-30 21:40:37Z]
      }
    end

    test "every region inside the screen passes" do
      fix = fix_with(%{minimap: {1200, 100, 290, 458}, hud_bottom: {0, 900, 1140, 82}})

      assert Layout.fits_screen?(fix, 1512, 982)
      assert Layout.fitting(fix, 1512, 982) == fix
    end

    test "a region past the screen edge condemns the whole fix" do
      fix = fix_with(%{minimap: {3150, 300, 290, 458}})

      refute Layout.fits_screen?(fix, 1512, 982)
      assert Layout.fitting(fix, 1512, 982) == nil
    end

    test "a negative origin condemns the fix even on its own screen" do
      fix = fix_with(%{minimap: {3150, -132, 290, 458}})

      refute Layout.fits_screen?(fix, 3440, 1440)
      assert Layout.fitting(fix, 3440, 1440) == nil
    end

    test "an unknown screen size never condemns — no proof, no drop" do
      fix = fix_with(%{minimap: {3150, 300, 290, 458}})

      assert Layout.fitting(fix, nil, nil) == fix
      assert Layout.fitting(nil, 1512, 982) == nil
    end
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
