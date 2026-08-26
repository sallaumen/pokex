defmodule Pokex.Bots.CrowdScanTest do
  @moduledoc """
  The reading that answers "how many of them are CLOSE".

  The battle list has always answered how many exist. Firing an area skill at a
  pile eight tiles away is the waste he described, and no reading could see it.
  """
  # async: false — scopes the global :home_dir env per test.
  use ExUnit.Case, async: false

  alias Pokex.Bots.CrowdScan
  alias Pokex.{Calibration, SettingsStash}
  alias Pokex.Vision.Frame

  @moduletag :tmp_dir

  # The character dead centre of a roomy screen, so a tile of distance is a round
  # number in every direction. The tile is kept BIGGER than a name label, as it
  # is in the game (151px against "Pikachu"'s 56): shrink it below that and two
  # creatures on neighbouring tiles carry labels that touch, which is a fact
  # about this fixture and not about his screen.
  @tile 80
  @screen 1600

  @red <<220, 0, 0, 255>>
  @green <<5, 166, 67, 255>>

  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Pokex.TestHome.restore() end)

    SettingsStash.stash!(tile_px: @tile, crowd_scan_radius_tiles: 6)

    Calibration.save(%Calibration{
      scale: 1.0,
      screen_w: @screen,
      screen_h: @screen,
      player_point: {800, 800}
    })

    :ok
  end

  describe "placing them" do
    test "a name label two tiles away reads as two tiles away" do
      # The label is drawn ONE TILE ABOVE the creature, so a creature two tiles
      # right and two down carries its label at two right, one down.
      reading = look([{2, 1}])

      assert reading.read?
      assert reading.seen == 1
      assert [%{tiles: 2, dx: 2, dy: 2}] = reading.spots
    end

    test "distance is the tile ruler, not pixels" do
      reading = look([{0, 2}])
      assert [%{tiles: 3, dx: 0, dy: 3}] = reading.spots
    end

    test "it reports the battle-list total beside its own count" do
      # The two disagreeing is the most useful fact about how far to trust the
      # reading on any given screen, so it is never collapsed into one number.
      reading = look([{2, 1}], listed: 5)

      assert reading.seen == 1
      assert reading.listed == 5
    end

    test "several labels come back nearest first" do
      reading = look([{5, 1}, {1, 1}, {-3, 1}])

      assert reading.seen == 3
      assert Enum.map(reading.spots, & &1.tiles) == [2, 3, 5]
    end
  end

  describe "what it measures FROM" do
    test "the green name of his own pokémon is the origin" do
      # An area skill leaves the pokémon. Same hostile, same screen: TWO tiles
      # from the pokémon that would fire at it, three from the trainer standing
      # behind. The next test measures the identical scene from the character.
      reading = look([{3, 1}], own: {3, 3})

      assert reading.anchor == :pokemon
      assert [%{tiles: 2}] = reading.spots
    end

    test "without the green name it falls back to the character AND says so" do
      # A distance whose origin is unknown is worse than no distance, because it
      # looks exactly like a good one.
      reading = look([{3, 1}])

      assert reading.anchor == :character
      assert [%{tiles: 3}] = reading.spots
    end

    test "his own pokémon is never one of the spots" do
      reading = look([{3, 1}], own: {3, 3})

      assert reading.seen == 1
    end
  end

  describe "showing its work" do
    test "evidence is off unless asked for" do
      refute look([{2, 1}]).evidence
    end

    test "asked for, it returns a picture a browser can draw" do
      reading = look([{2, 1}], evidence: true)

      assert "data:image/bmp;base64," <> b64 = reading.evidence
      assert {:ok, <<"BM", _rest::binary>>} = Base.decode64(b64)
    end
  end

  describe "the question a rule asks" do
    test "within/2 counts only what is inside the reach" do
      reading = look([{5, 1}, {1, 1}, {-3, 1}])

      assert CrowdScan.within(reading, 2) == 1
      assert CrowdScan.within(reading, 3) == 2
      assert CrowdScan.within(reading, 9) == 3
    end

    test "nearest/1 is the closest one" do
      assert CrowdScan.nearest(look([{4, 1}, {1, 1}])) == 2
    end

    test "an unread scan answers ZERO close and no nearest, never a guess" do
      unread = %{read?: false, reason: :no_frame}

      assert CrowdScan.within(unread, 3) == 0
      assert CrowdScan.nearest(unread) == nil
    end
  end

  describe "when it cannot look" do
    test "a capture that fails says so instead of reporting an empty field" do
      reading = CrowdScan.look(capture: fn _region, _name -> {:error, :no_display} end)

      assert reading == %{read?: false, reason: :no_display}
    end

    test "no calibration is a reason, not a zero" do
      File.rm!(Pokex.Home.calibration_file())

      assert %{read?: false, reason: :not_calibrated} =
               CrowdScan.look(capture: fn _r, _n -> {:error, :never_called} end)
    end
  end

  # --- a screen with labels painted on it ----------------------------------

  defp look(tiles, opts \\ []) do
    own = Keyword.get(opts, :own)
    place = fn {dx, dy} -> {800 + dx * @tile, 800 + dy * @tile} end

    capture = fn {rx, ry, w, h}, _name ->
      shift = fn {x, y} -> {x - rx, y - ry} end

      points =
        Enum.map(tiles, &{shift.(place.(&1)), @red}) ++
          if own, do: [{shift.(place.(own)), @green}], else: []

      {:ok, scene(w, h, points)}
    end

    CrowdScan.look(opts |> Keyword.drop([:own]) |> Keyword.put(:capture, capture))
  end

  # Ground, with a name-shaped bar painted centred on each point: 56×10 is what
  # "Pikachu" measured on his own display, red for a hostile and green for his.
  defp scene(w, h, points) do
    boxes = Enum.map(points, fn {{x, y}, colour} -> {x - 28, y - 5, colour} end)

    rgba =
      for y <- 0..(h - 1), x <- 0..(w - 1), into: <<>> do
        on_bar(boxes, x, y) || <<90, 90, 90, 255>>
      end

    %Frame{width: w, height: h, rgba: rgba, scale: 1.0}
  end

  # The label's colour where a label is painted, nil on bare ground. Extracted
  # in #352 to keep the comprehension shallow; it answers a colour now, because
  # a green name and a red one have to stay tellable apart.
  defp on_bar(boxes, x, y) do
    Enum.find_value(boxes, fn {bx, by, colour} ->
      if x >= bx and x < bx + 56 and y >= by and y < by + 10, do: colour
    end)
  end
end
