defmodule Pokex.CalibrationLayoutTest do
  # async: false — re-points the global :home_dir and clears the :layout fact
  use ExUnit.Case, async: false

  alias Pokex.Calibration
  alias Pokex.Perception.WorldState

  # The persisted ultrawide fix exactly as found on disk on 2026-08-01,
  # minimap region hanging above the screen at y=-132.
  @ultrawide_fact %{
    "profile" => "ultrawide_3440x1440",
    "anchors" => %{"battle_header" => [3184, 328]},
    "regions" => %{
      "minimap" => [3150, -132, 290, 458],
      "minimap_coord" => [3150, 326, 290, 20],
      "battle_list" => [3140, 373, 300, 310],
      "hud_bottom" => [1200, 1330, 1140, 110]
    },
    "region_opts" => %{"slot_f1" => 200},
    "located_at" => "2026-07-30T21:40:37Z"
  }

  setup %{tmp_dir: tmp} do
    # one shared blackboard: start from an empty world, never from the last test's
    WorldState.clear()

    Application.put_env(:pokex, :home_dir, tmp)
    WorldState.forget(:layout)

    on_exit(fn ->
      Pokex.TestHome.restore()
      WorldState.forget(:layout)
    end)

    %{tmp: tmp}
  end

  defp write_layout!(tmp, fact),
    do: File.write!(Path.join(tmp, "layout_fix.json"), Jason.encode!(fact))

  defp write_calibration!(tmp, attrs) do
    path = Path.join(tmp, "calibration.json")

    base = %{
      "scale" => 1.0,
      "screen_w" => 1512,
      "screen_h" => 982,
      "battle_region" => [1321, 333, 187, 252]
    }

    File.write!(path, JSON.encode!(Map.merge(base, attrs)))
    path
  end

  @tag :tmp_dir
  test "a persisted layout from another screen is dropped on load — regions resolve to nil, not to x=3150",
       %{tmp: tmp} do
    write_layout!(tmp, @ultrawide_fact)
    path = write_calibration!(tmp, %{})

    assert {:ok, calib} = Calibration.load(path)

    assert calib.layout == nil
    assert Calibration.minimap_region(calib) == nil
    assert Calibration.minimap_coord_region(calib) == nil
  end

  @tag :tmp_dir
  test "with the foreign layout dropped, the battle feed falls back to the hand-marked region",
       %{tmp: tmp} do
    write_layout!(tmp, @ultrawide_fact)
    path = write_calibration!(tmp, %{})

    {:ok, calib} = Calibration.load(path)

    assert (Pokex.Layout.region(:battle_list, calib.layout) || calib.battle_region) ==
             {1321, 333, 187, 252}
  end

  @tag :tmp_dir
  test "a layout that fits the calibrated screen is kept", %{tmp: tmp} do
    fitting =
      @ultrawide_fact
      |> Map.put("regions", %{"minimap" => [1200, 100, 290, 458]})

    write_layout!(tmp, fitting)
    path = write_calibration!(tmp, %{})

    {:ok, calib} = Calibration.load(path)

    assert Calibration.minimap_region(calib) == {1200, 100, 290, 458}
  end

  @tag :tmp_dir
  test "a calibration that does not know its screen keeps the layout — no proof, no drop",
       %{tmp: tmp} do
    write_layout!(tmp, @ultrawide_fact)
    path = write_calibration!(tmp, %{"screen_w" => nil, "screen_h" => nil})

    {:ok, calib} = Calibration.load(path)

    assert Calibration.minimap_region(calib) == {3150, -132, 290, 458}
  end

  # 2026-08-27: `Pokex.Layout.current/0` came back `:undef` for a few ticks (the
  # dev code reloader had the module purged mid-recompile). The raise escaped
  # `load/1` — whose contract is {:ok, t} | {:error, reason} — and terminated the
  # always-on support monitor, which reloads the calibration every 120ms. Three
  # deaths in 360ms exhausted BotSupervisor's restart intensity, then the
  # application's, and the whole VM went down. The layout is an ENRICHMENT: the
  # hand marks in the file are valid without it, and every consumer already
  # handles a nil layout.
  @tag :tmp_dir
  @tag :capture_log
  test "a layout the reader cannot turn into a Fix leaves layout nil and keeps the hand marks",
       %{tmp: tmp} do
    write_layout!(tmp, Map.delete(@ultrawide_fact, "anchors"))
    path = write_calibration!(tmp, %{})

    assert {:ok, calib} = Calibration.load(path)

    assert calib.layout == nil
    assert calib.battle_region == {1321, 333, 187, 252}
  end

  @tag :tmp_dir
  @tag :capture_log
  test "a layout whose regions have the wrong shape leaves layout nil", %{tmp: tmp} do
    write_layout!(tmp, Map.put(@ultrawide_fact, "regions", %{"minimap" => [3150, -132]}))
    path = write_calibration!(tmp, %{})

    assert {:ok, calib} = Calibration.load(path)

    assert calib.layout == nil
  end

  @tag :tmp_dir
  test "a calibration whose own numbers are unreadable is an error, not a raise", %{tmp: tmp} do
    path = Path.join(tmp, "calibration.json")
    File.write!(path, JSON.encode!(%{"screen_w" => 1512, "screen_h" => 982}))

    assert {:error, _reason} = Calibration.load(path)
  end
end
