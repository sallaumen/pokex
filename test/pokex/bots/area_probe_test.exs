defmodule Pokex.Bots.AreaProbeTest do
  @moduledoc """
  Measuring how far his area skill actually reaches, from his own hunt.

  It exists because `Sim.World` resolves every area press with `aoe_radius: 4`
  under a comment saying the number is invented — and that invented 4 is why a
  full sweep of the engine's knobs (24 seeds × 4 scenarios) found not one that
  moved kills/min by more than 5%.
  """
  # async: false — scopes the global :home_dir env per test.
  use ExUnit.Case, async: false

  alias Pokex.Bots.AreaProbe
  alias Pokex.{Calibration, SettingsStash}
  alias Pokex.Vision.Frame

  @moduletag :tmp_dir

  @tile 80
  @screen 1600
  @green <<5, 166, 67, 255>>
  @orange <<240, 118, 13, 255>>

  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Pokex.TestHome.restore() end)

    SettingsStash.stash!(tile_px: @tile, crowd_scan_radius_tiles: 6, area_probe_enabled: false)

    Calibration.save(%Calibration{
      scale: 1.0,
      screen_w: @screen,
      screen_h: @screen,
      player_point: {800, 800}
    })

    :ok
  end

  describe "one look" do
    test "a damage number two tiles from his pokémon reads as two tiles" do
      # The green NAME sits a tile above the pokémon; a damage number sits ON
      # what it hit. Giving both the same lift is what would make every measured
      # radius exactly one tile too long.
      assert {:ok, sample} = look(own: {0, -1}, hits: [{2, 0}])

      assert sample.anchor == :pokemon
      assert sample.hits == 1
      assert sample.tiles == [2.0]
    end

    test "the furthest hit is what a cast can prove" do
      assert {:ok, %{tiles: tiles}} = look(own: {0, -1}, hits: [{1, 0}, {3, 0}, {0, 2}])
      assert Enum.max(tiles) == 3.0
    end

    test "no green name means the origin is unknown, and it says so" do
      assert {:ok, %{anchor: :character}} = look(hits: [{2, 0}])
    end

    test "a cast that hit nothing is still a look, not an error" do
      assert {:ok, %{hits: 0, tiles: []}} = look(own: {0, -1})
    end

    test "a capture that fails is a reason, never a zero-radius reading" do
      assert {:error, :no_display} =
               AreaProbe.look(capture: fn _r, _n -> {:error, :no_display} end)
    end
  end

  describe "what the filed casts say" do
    test "nothing filed says nothing, rather than guessing a radius" do
      assert AreaProbe.summary([]) == nil
      assert AreaProbe.summary([%{anchor: :pokemon, hits: 0, tiles: []}]) == nil
    end

    test "it summarises the FURTHEST hit per cast, not every hit" do
      # Three casts reaching 2, 3 and 9 tiles. The 9 is what one other player's
      # Thunderbolt landing on the same screen looks like, and it must not
      # become the answer — so the headline is the median, with the top beside it.
      s = AreaProbe.summary([cast([1.0, 2.0]), cast([3.0]), cast([1.0, 9.0])])

      assert s.casts == 3
      assert s.p50 == 3.0
      assert s.top == 9.0
      assert s.hits == 5
    end

    test "casts measured from the character are counted, never averaged in" do
      s = AreaProbe.summary([cast([2.0]), %{anchor: :character, hits: 1, tiles: [9.0]}])

      assert s.casts == 1
      assert s.discarded == 1
      assert s.top == 2.0
    end
  end

  describe "filing" do
    test "a look survives a round trip through the file" do
      SettingsStash.stash!(area_probe_enabled: true)

      assert :ok = file(own: {0, -1}, hits: [{2, 0}])
      assert :ok = file(own: {0, -1}, hits: [{3, 0}])

      assert %{casts: 2, p50: 2.0, top: 3.0} = AreaProbe.summary()
    end

    test "clearing throws the casts away — a new pokémon has a new reach" do
      assert :ok = file(own: {0, -1}, hits: [{2, 0}])
      AreaProbe.clear()

      assert AreaProbe.summary() == nil
    end

    test "no file at all reads as no casts, not as a crash" do
      assert AreaProbe.samples() == []
      assert AreaProbe.summary() == nil
    end
  end

  test "the mode is OFF unless he turned it on: it costs a capture per cast" do
    refute AreaProbe.on?()
    SettingsStash.stash!(area_probe_enabled: true)
    assert AreaProbe.on?()
  end

  # --- a screen with a green name and orange numbers painted on it ---------

  defp cast(tiles), do: %{anchor: :pokemon, hits: length(tiles), tiles: tiles}

  defp file(opts), do: AreaProbe.file(capture: capture(opts))

  defp look(opts), do: AreaProbe.look(capture: capture(opts))

  defp capture(opts) do
    own = Keyword.get(opts, :own)
    hits = Keyword.get(opts, :hits, [])

    fn {rx, ry, w, h}, _name ->
      place = fn {dx, dy} -> {800 + dx * @tile - rx, 800 + dy * @tile - ry} end

      shapes =
        Enum.map(hits, &{place.(&1), @orange, 40}) ++
          if own, do: [{place.(own), @green, 56}], else: []

      {:ok, scene(w, h, shapes)}
    end
  end

  defp scene(w, h, shapes) do
    boxes = Enum.map(shapes, fn {{x, y}, colour, bw} -> {x - div(bw, 2), y - 5, bw, colour} end)

    rgba =
      for y <- 0..(h - 1), x <- 0..(w - 1), into: <<>> do
        on_shape(boxes, x, y) || <<90, 90, 90, 255>>
      end

    %Frame{width: w, height: h, rgba: rgba, scale: 1.0}
  end

  defp on_shape(boxes, x, y) do
    Enum.find_value(boxes, fn {bx, by, bw, colour} ->
      if x >= bx and x < bx + bw and y >= by and y < by + 10, do: colour
    end)
  end
end
