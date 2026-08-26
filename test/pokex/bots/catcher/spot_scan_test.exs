defmodule Pokex.Bots.Catcher.SpotScanTest do
  # async: false — the library lives in the global home (:home_dir) and the knobs are
  # global Settings (stash restores them).
  use ExUnit.Case, async: false

  alias Pokex.Bots.Catcher.{CorpseLibrary, SpotScan}
  alias Pokex.{Calibration, SettingsStash}

  @moduletag :tmp_dir

  # Small exact geometry: tile 40, box 24, coarse step 20, refine 4.
  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Pokex.TestHome.restore() end)

    SettingsStash.stash!(
      tile_px: 40,
      corpse_scan_radius_tiles: 2,
      corpse_sprite_box_px: 24,
      corpse_scan_step_px: 20,
      corpse_scan_refine_px: 4,
      corpse_scan_refine_peaks: 4,
      corpse_match_min_similarity: 0.72,
      corpse_match_tolerance_px: 32
    )

    :ok
  end

  defp calib(overrides \\ []) do
    struct!(
      %Calibration{
        scale: 1.0,
        screen_w: 1000,
        screen_h: 700,
        water_point: {1, 1},
        glow_region: {0, 0, 8, 8},
        battle_region: {900, 0, 80, 400},
        neutral_point: {500, 500},
        player_point: {500, 400}
      },
      overrides
    )
  end

  @red {230, 40, 40}
  @ground {100, 90, 60}

  # Injected capture: ground across the whole requested region, plus a 24px red square
  # centered on each listed SCREEN point.
  defp capture_with_corpses_at(screen_points) do
    fn {rx, ry, rw, rh}, _filename ->
      {:ok, Pokex.FrameFixtures.of(rw, rh, &corpse_pixel(&1, &2, {rx, ry}, screen_points))}
    end
  end

  defp corpse_pixel(x, y, {rx, ry}, screen_points) do
    on_a_corpse? =
      Enum.any?(screen_points, fn {cx, cy} ->
        abs(x + rx - cx) <= 12 and abs(y + ry - cy) <= 12
      end)

    if on_a_corpse?, do: @red, else: @ground
  end

  defp teach_red!(name \\ "Corsola") do
    solid = Pokex.FrameFixtures.uniform(24, 24, @red)
    {:ok, _n} = CorpseLibrary.add(name, solid)
    :ok
  end

  describe "the dynamic scan box" do
    # Field case: the calibrated arena ended at y=642 while the player stood at y=697 —
    # the box must follow the player, not the arena.
    test "the region is centered on the player and ignores the calibrated arena" do
      teach_red!()
      test_pid = self()

      capture = fn {_rx, _ry, rw, rh} = region, _f ->
        send(test_pid, {:region, region})
        {:ok, Pokex.FrameFixtures.uniform(rw, rh, @ground)}
      end

      SpotScan.scan(calib(player_point: {500, 600}), capture)

      assert_received {:region, {rx, ry, rw, rh}}
      assert {rx, ry, rw, rh} == {400, 500, 200, 200}
    end

    test "works with no arena calibrated at all" do
      teach_red!()

      obs =
        SpotScan.scan(
          calib(player_point: {500, 400}),
          capture_with_corpses_at([{540, 400}])
        )

      assert obs.scanning?
      assert obs.corpses != []
    end

    test "without a marked player, the center is the screen's (not the arena's)" do
      teach_red!()
      test_pid = self()

      capture = fn region, _f ->
        send(test_pid, {:region, region})
        {:ok, Pokex.FrameFixtures.uniform(elem(region, 2), elem(region, 3), @ground)}
      end

      SpotScan.scan(calib(player_point: nil), capture)

      assert_received {:region, {400, 250, 200, 200}}
    end

    test "the region never leaves the screen (the broker's quarantine would reject it)" do
      teach_red!()
      test_pid = self()

      capture = fn {rx, ry, rw, rh} = region, _f ->
        send(test_pid, {:region, region})
        assert rx >= 0 and ry >= 0 and rx + rw <= 1000 and ry + rh <= 700
        {:ok, Pokex.FrameFixtures.uniform(rw, rh, @ground)}
      end

      SpotScan.scan(calib(player_point: {20, 20}), capture)
      assert_received {:region, _}
    end

    test "the box stretches to embrace the pokemon point when it falls outside" do
      teach_red!()
      test_pid = self()

      capture = fn {_rx, _ry, rw, rh} = region, _f ->
        send(test_pid, {:region, region})
        {:ok, Pokex.FrameFixtures.uniform(rw, rh, @ground)}
      end

      SpotScan.scan(calib(player_point: {500, 500}, pokemon_spot_point: {500, 200}), capture)

      assert_received {:region, {_rx, ry, _rw, rh}}
      assert ry <= 160, "o topo tem que subir pra abraçar o pokémon (com folga de 1 tile)"
      assert ry + rh >= 600
    end
  end

  describe "the dense scan (kills grid misalignment)" do
    # Measured: on the old tile lattice this off-grid box landed on ground and scored ~0.39
    # (the real Kingler-on-the-ground case).
    test "finds the corpse even off any tile grid" do
      teach_red!("Kingler")

      obs = SpotScan.scan(calib(), capture_with_corpses_at([{537, 417}]))

      assert [point] = obs.corpses
      assert %{name: "Kingler", score: score} = obs.known[point]
      assert score > 0.9, "a janela vencedora deve enquadrar quase igual ao ensino"
    end

    test "the aim is the corpse's center, not the edge nor the tile center" do
      teach_red!()

      obs = SpotScan.scan(calib(), capture_with_corpses_at([{537, 417}]))

      assert [{x, y}] = obs.corpses
      assert abs(x - 537) <= 6, "aim off-center in x: #{x}"
      assert abs(y - 417) <= 6, "aim off-center in y: #{y}"
    end

    test "two corpses become two targets — and a single corpse only one" do
      teach_red!()

      obs = SpotScan.scan(calib(), capture_with_corpses_at([{450, 350}, {560, 460}]))

      assert length(obs.corpses) == 2, "esperava 2 alvos, veio #{inspect(obs.corpses)}"
    end

    test "pure ground yields no target, and the best rejected window still carries name and score" do
      teach_red!("Corsola")

      obs = SpotScan.scan(calib(), capture_with_corpses_at([]))

      assert obs.corpses == []
      assert %{name: "Corsola", score: score} = obs.best
      assert score < obs.threshold
    end

    test "an empty library yields no targets and a nil best, without crashing" do
      obs = SpotScan.scan(calib(), capture_with_corpses_at([{537, 417}]))

      assert obs.corpses == []
      assert obs.best == nil
      assert obs.windows == 0
    end
  end

  describe "live anchors never become targets" do
    test "the player's tile is a forbidden zone (a live sprite would match by palette)" do
      teach_red!()

      obs = SpotScan.scan(calib(), capture_with_corpses_at([{500, 400}]))

      assert obs.corpses == []
    end

    test "the pokemon's tile is forbidden too" do
      teach_red!()
      c = calib(pokemon_spot_point: {560, 400})

      obs = SpotScan.scan(c, capture_with_corpses_at([{560, 400}]))

      assert obs.corpses == []
    end
  end

  describe "diagnostics" do
    test "blindness has a name and never confirms a ball in flight" do
      obs = SpotScan.scan(calib(screen_w: nil, screen_h: nil, player_point: nil), nil)

      assert %{scanning?: false, reason: :no_anchor, corpses: []} = obs
    end

    test "the observation counts the scored windows" do
      teach_red!()

      obs = SpotScan.scan(calib(), capture_with_corpses_at([]))

      assert obs.windows > 0
      assert obs.threshold == 0.72
      assert {_x, _y, _w, _h} = obs.region
    end
  end
end
