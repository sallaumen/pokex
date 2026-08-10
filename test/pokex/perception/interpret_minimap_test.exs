defmodule Pokex.Perception.InterpretMinimapTest do
  @moduledoc """
  The character position as the cavebot receives it: regions come from
  `Calibration` (manual marks win, layout is fallback) and the ink floor is the
  `minimap_coord_ink` setting. Default 120 is measured behavior: digit cores are
  240+ but anti-aliasing spreads 160-239 and the atlas was taught at floor 120,
  so raising it starves the shapes and blinds the atlas (165 failed all four
  real captures).
  """
  use ExUnit.Case, async: true

  alias Pokex.{Calibration, Layout, ScreenFixtures}
  alias Pokex.Perception.Interpret.Minimap
  alias Pokex.Vision.Frame

  @coords %{
    "ultrawide_3440x1440_full" => {337, 46_107, 4},
    "ultrawide_3440x1440_outro_mapa" => {2782, 30_571, 5},
    "ultrawide_3440x1440_terceiro" => {2777, 30_560, 5},
    "ultrawide_3440x1440_time" => {2597, 30_640, 6}
  }

  defp located(name) do
    frame = ScreenFixtures.frame!(name)
    {:ok, fix} = Layout.locate(frame)
    panel = Frame.crop(frame, Layout.region(:minimap, fix))
    {fix, panel}
  end

  test "the default ink floor reads all four real captures via layout fallback" do
    for {name, expected} <- @coords do
      {fix, panel} = located(name)
      calib = %Calibration{scale: 1.0, layout: fix}

      assert {%{pos: ^expected}, _state} = Minimap.interpret(panel, calib, %{}, nil),
             "did not read the coordinate in #{name}"
    end
  end

  test "hand-marked regions read without any layout" do
    {fix, panel} = located("ultrawide_3440x1440_time")

    calib = %Calibration{
      scale: 1.0,
      layout: nil,
      minimap_region: Layout.region(:minimap, fix),
      minimap_coord_region: Layout.region(:minimap_coord, fix)
    }

    assert {%{pos: {2597, 30_640, 6}}, _state} = Minimap.interpret(panel, calib, %{}, nil)
  end

  # manual marks point at the same regions the layout resolves: a shifted layout
  # with correct manual marks would read wrong on the old path, so a matching
  # result proves the manual path is the one taken
  test "manual marks win over a present layout" do
    {fix, panel} = located("ultrawide_3440x1440_time")

    calib = %Calibration{
      scale: 1.0,
      layout: fix,
      minimap_region: Layout.region(:minimap, fix),
      minimap_coord_region: Layout.region(:minimap_coord, fix)
    }

    assert {%{pos: {2597, 30_640, 6}}, _state} = Minimap.interpret(panel, calib, %{}, nil)
  end

  test "the minimap_coord_ink setting reaches the reader — an impossible floor blinds it" do
    {fix, panel} = located("ultrawide_3440x1440_full")
    calib = %Calibration{scale: 1.0, layout: fix}

    assert {%{pos: nil}, _state} =
             Minimap.interpret(panel, calib, %{minimap_coord_ink: 255}, nil)
  end

  test "no region at all (neither manual nor layout) yields pos nil, never a crash" do
    {_fix, panel} = located("ultrawide_3440x1440_full")
    calib = %Calibration{scale: 1.0, layout: nil}

    assert {%{pos: nil}, _state} = Minimap.interpret(panel, calib, %{}, nil)
    assert {%{pos: nil}, _state} = Minimap.interpret(panel, nil, %{}, nil)
  end

  # The real 2026-08-10 failure: the hand-marked map region started BELOW the
  # coord band, and the feed captured the map region alone — the band was
  # decapitated before the reader ever saw a pixel. The feed now captures
  # minimap_capture_region (the union of both marks), and the reader subtracts
  # the SAME origin, so a band poking outside the map can never be clipped.
  test "a coord band poking outside the map region still reads — the capture is the union" do
    frame = ScreenFixtures.frame!("ultrawide_3440x1440_full")
    {:ok, fix} = Layout.locate(frame)

    calib = %Calibration{
      scale: 1.0,
      layout: nil,
      # starts 34pt below the band on purpose
      minimap_region: {3171, 40, 269, 418},
      minimap_coord_region: Layout.region(:minimap_coord, fix)
    }

    panel = Frame.crop(frame, Calibration.minimap_capture_region(calib))
    assert {%{pos: {337, 46_107, 4}}, _state} = Minimap.interpret(panel, calib, %{}, nil)
  end

  describe "Calibration resolvers" do
    test "manual wins over layout; layout is fallback; nothing yields nil" do
      {fix, _panel} = located("ultrawide_3440x1440_full")

      manual = %Calibration{
        scale: 1.0,
        layout: fix,
        minimap_region: {10, 20, 300, 400},
        minimap_coord_region: {12, 22, 160, 30},
        minimap_player_point: {160, 220}
      }

      assert Calibration.minimap_region(manual) == {10, 20, 300, 400}
      assert Calibration.minimap_coord_region(manual) == {12, 22, 160, 30}
      assert Calibration.minimap_map_region(manual) == {10, 20, 300, 400}
      assert Calibration.minimap_player_point(manual) == {160, 220}

      fallback = %Calibration{scale: 1.0, layout: fix}
      assert Calibration.minimap_region(fallback) == Layout.region(:minimap, fix)
      assert Calibration.minimap_map_region(fallback) == Layout.region(:minimap_map, fix)
      {mx, my, mw, mh} = Layout.region(:minimap_map, fix)
      assert Calibration.minimap_player_point(fallback) == {mx + div(mw, 2), my + div(mh, 2)}

      blind = %Calibration{scale: 1.0, layout: nil}
      assert Calibration.minimap_region(blind) == nil
      assert Calibration.minimap_player_point(blind) == nil
    end

    @tag :tmp_dir
    test "the three minimap fields round-trip through the file", %{tmp_dir: tmp} do
      path = Path.join(tmp, "calibration.json")

      calib = %Calibration{
        scale: 1.0,
        screen_w: 3440,
        screen_h: 1440,
        water_point: {1, 2},
        glow_region: {0, 0, 4, 4},
        battle_region: {0, 0, 4, 4},
        neutral_point: {3, 4},
        minimap_region: {3150, 100, 290, 458},
        minimap_player_point: {3295, 329},
        minimap_coord_region: {3171, 106, 160, 30}
      }

      Calibration.save(calib, path)
      {:ok, loaded} = Calibration.load(path)

      assert loaded.minimap_region == {3150, 100, 290, 458}
      assert loaded.minimap_player_point == {3295, 329}
      assert loaded.minimap_coord_region == {3171, 106, 160, 30}
    end
  end
end
