defmodule Pokex.Bots.CrowdScanTest do
  @moduledoc """
  Marks on the screen become tiles from HIM and from his pokemon.
  """
  # async: false — scopes the global :home_dir env per test.
  use ExUnit.Case, async: false

  alias Pokex.Bots.CrowdScan
  alias Pokex.{Calibration, SettingsStash}
  alias Pokex.Vision.Frame

  @moduletag :tmp_dir

  @tile 100
  @screen 1600
  @me {800, 800}

  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Pokex.TestHome.restore() end)

    # radius 3: the painted capture is 600×600 instead of 1200×1200; the
    # geometry under test is the same and the test runs in a blink.
    SettingsStash.stash!(tile_px: @tile, crowd_scan_radius_tiles: 3)

    Calibration.save(%Calibration{
      scale: 1.0,
      screen_w: @screen,
      screen_h: @screen,
      player_point: @me
    })

    :ok
  end

  # A mark whose BODY stands `{dx, dy}` tiles from him: the bar is one tile up.
  defp mark({dx, dy}, opts \\ []) do
    {px, py} = @me

    %{
      point: {px + dx * @tile, py + dy * @tile - @tile},
      hp_pct: Keyword.get(opts, :hp, 100),
      skull?: Keyword.get(opts, :skull?, false),
      pet?: Keyword.get(opts, :pet?, false)
    }
  end

  describe "placing marks" do
    test "a creature two right and two down is two tiles from him" do
      placed = CrowdScan.place([mark({2, 2})], @me, @tile)

      assert placed.read?
      assert placed.pet == nil

      assert [%{dx: 2, dy: 2, from_me: 2, from_pet: nil, hp_pct: 100, skull?: false}] =
               placed.hostiles
    end

    test "distance is Chebyshev in whole tiles" do
      assert [%{from_me: 3, dx: 0, dy: 3}] = CrowdScan.place([mark({0, 3})], @me, @tile).hostiles

      assert [%{from_me: 3, dx: -3, dy: 1}] =
               CrowdScan.place([mark({-3, 1})], @me, @tile).hostiles
    end

    test "hostiles come nearest to him first" do
      placed = CrowdScan.place([mark({5, 0}), mark({1, 1}), mark({-3, 0})], @me, @tile)
      assert Enum.map(placed.hostiles, & &1.from_me) == [1, 3, 5]
    end

    test "the mark standing on his own tile is him, not a hostile" do
      placed = CrowdScan.place([mark({0, 0}), mark({2, 0})], @me, @tile)
      assert length(placed.hostiles) == 1
    end
  end

  describe "his pokemon" do
    test "is the number-boxed mark nearest to him, and every hostile is also measured from it" do
      placed =
        CrowdScan.place([mark({0, 2}, pet?: true), mark({1, 3}), mark({-4, 2})], @me, @tile)

      assert %{dx: 0, dy: 2, tiles: 2, hp_pct: 100} = placed.pet
      assert [%{from_me: 3, from_pet: 1}, %{from_me: 4, from_pet: 4}] = placed.hostiles
    end

    test "another boxed creature farther away is a hostile, not a second pet" do
      placed = CrowdScan.place([mark({0, 2}, pet?: true), mark({5, 5}, pet?: true)], @me, @tile)

      assert placed.pet.dx == 0
      assert [%{dx: 5, dy: 5}] = placed.hostiles
    end

    test "without a boxed mark there is no pet and from_pet is nil" do
      placed = CrowdScan.place([mark({1, 1})], @me, @tile)
      assert placed.pet == nil
      assert [%{from_pet: nil}] = placed.hostiles
    end
  end

  describe "looking at the screen" do
    test "a capture that fails says so instead of reporting an empty field" do
      reading = CrowdScan.look(capture: fn _region, _name -> {:error, :no_display} end)
      assert reading == %{read?: false, reason: :no_display}
    end

    test "no calibration is a reason, not a zero" do
      File.rm!(Pokex.Home.calibration_file())

      assert %{read?: false, reason: :not_calibrated} =
               CrowdScan.look(capture: fn _r, _n -> {:error, :never_called} end)
    end

    test "a bar painted on the captured box comes back placed, with the box and the clock" do
      reading = look_at([{2, 2}], listed: 3)

      assert reading.read?
      assert reading.listed == 3
      assert is_integer(reading.at)
      assert {500, 500, 600, 600} = reading.box
      assert [%{dx: 2, dy: 2, from_me: 2, hp_pct: 100}] = reading.hostiles
      assert reading.evidence == nil
    end

    test "asked for, the evidence is a picture a browser can draw" do
      reading = look_at([{2, 2}], evidence: true)

      assert "data:image/bmp;base64," <> b64 = reading.evidence
      assert {:ok, <<"BM", _rest::binary>>} = Base.decode64(b64)
    end
  end

  # Paints a full green health bar, sized by the ruler for this tile, one tile
  # above each body point inside the box the scan asks for, and hands it to
  # `look/1` as the capture.
  defp look_at(bodies, opts) do
    {px, py} = @me
    %{bar_w: bw, bar_h: bh} = geo = Pokex.Vision.CreatureMarks.geometry(@tile)

    capture = fn {rx, ry, w, h}, _name ->
      bars =
        Enum.map(bodies, fn {dx, dy} ->
          {px + dx * @tile - div(bw, 2) - rx, py + dy * @tile - @tile - div(bh, 2) - ry}
        end)

      rgba = for y <- 0..(h - 1), x <- 0..(w - 1), into: <<>>, do: pixel(bars, geo, x, y)
      {:ok, %Frame{width: w, height: h, rgba: rgba, scale: 1.0}}
    end

    CrowdScan.look(Keyword.put(opts, :capture, capture))
  end

  # Green inside a bar, black on its border, sand everywhere else.
  defp pixel(bars, geo, x, y) do
    case Enum.find(bars, &covers?(&1, geo, x, y)) do
      nil -> <<224, 192, 128, 255>>
      bar -> if border?(bar, geo, x, y), do: <<0, 0, 0, 255>>, else: <<0, 188, 0, 255>>
    end
  end

  defp covers?({bx, by}, %{bar_w: bw, bar_h: bh}, x, y),
    do: x >= bx and x < bx + bw and y >= by and y < by + bh

  defp border?({bx, by}, %{bar_w: bw, bar_h: bh}, x, y),
    do: x == bx or x == bx + bw - 1 or y == by or y == by + bh - 1
end
