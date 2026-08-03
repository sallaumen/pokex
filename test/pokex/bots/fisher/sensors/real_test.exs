defmodule Pokex.Bots.Fisher.Sensors.RealTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.Fisher.Sensors
  alias Pokex.Calibration
  alias Pokex.Rig.Fake

  defp rows(w, h, {r, g, b}), do: List.duplicate(List.duplicate({r, g, b, 255}, w), h)

  defp calib(tmp, baseline_path) do
    %Calibration{
      scale: 2.0,
      screen_w: 1000,
      screen_h: 700,
      water_point: {400, 300},
      glow_region: {368, 268, 64, 64},
      battle_region: {700, 100, 260, 200},
      neutral_point: {420, 350}
    }
  end

  @tag :tmp_dir
  test "glow returns the focused fishing signal (driver applies the threshold)", %{tmp_dir: tmp} do
    baseline = Pokex.PngFixtures.write!(Path.join(tmp, "base.png"), rows(8, 8, {0, 60, 120}))

    bubbly =
      Pokex.PngFixtures.write!(
        Path.join(tmp, "bubbly.png"),
        for y <- 0..63 do
          for x <- 0..63 do
            cond do
              x in 28..35 and y in 28..35 -> {210, 55, 30, 255}
              x in 10..53 and y in 10..53 -> {40, 180, 220, 255}
              true -> {30, 80, 150, 255}
            end
          end
        end
      )

    {:ok, _} = Fake.start_link(%{capture: [{:ok, bubbly}]})

    assert {:ok, %{glow: signal, cursor: {500, 500}}} =
             Sensors.Real.observe(
               [:cursor, :glow],
               calib(tmp, baseline),
               Pokex.Settings.defaults()
             )

    assert signal.line_present?
    assert signal.lure_count == 64
    assert signal.bubble_count > 1_000
    assert {:capture, {176, 76, 448, 448}, "glow.png"} in Fake.calls()
  end

  @tag :tmp_dir
  test "glow reads ~0 on calm (dark-blue, low-green) water", %{tmp_dir: tmp} do
    baseline = Pokex.PngFixtures.write!(Path.join(tmp, "base.png"), rows(8, 8, {0, 60, 120}))
    # dark blue water: green is too low to count as a cyan bubble
    calm = Pokex.PngFixtures.write!(Path.join(tmp, "calm.png"), rows(16, 16, {30, 80, 150}))

    {:ok, _} = Fake.start_link(%{capture: [{:ok, calm}]})

    assert {:ok, %{glow: signal}} =
             Sensors.Real.observe([:glow], calib(tmp, baseline), Pokex.Settings.defaults())

    assert signal == %{bubble_count: 0, lure_count: 0, line_present?: false}
  end

  @tag :tmp_dir
  test "hostile observation converts frame pixels to screen points", %{tmp_dir: tmp} do
    baseline = Pokex.PngFixtures.write!(Path.join(tmp, "base.png"), rows(8, 8, {0, 60, 120}))

    hostile_rows =
      for y <- 0..99 do
        for x <- 0..99 do
          if x in 44..55 and y in 28..31, do: {255, 30, 30, 255}, else: {20, 80, 40, 255}
        end
      end

    hostile = Pokex.PngFixtures.write!(Path.join(tmp, "hostile.png"), hostile_rows)
    {:ok, _} = Fake.start_link(%{capture: [{:ok, hostile}]})

    assert {:ok, %{hostile: {217, 57}}} =
             Sensors.Real.observe([:hostile], calib(tmp, baseline), Pokex.Settings.defaults())
  end

  @tag :tmp_dir
  test "wild observation reads the battle strip", %{tmp_dir: tmp} do
    baseline = Pokex.PngFixtures.write!(Path.join(tmp, "base.png"), rows(8, 8, {0, 60, 120}))

    strip_rows =
      for y <- 0..99 do
        for x <- 0..29 do
          if x in 10..17 and y in 20..23, do: {230, 40, 40, 255}, else: {30, 30, 30, 255}
        end
      end

    strip = Pokex.PngFixtures.write!(Path.join(tmp, "strip.png"), strip_rows)
    {:ok, _} = Fake.start_link(%{capture: [{:ok, strip}]})

    assert {:ok, %{wild: true}} =
             Sensors.Real.observe([:wild], calib(tmp, baseline), Pokex.Settings.defaults())
  end

  @tag :tmp_dir
  test "wild detection falls back to default min_count when settings omit the key", %{
    tmp_dir: tmp
  } do
    baseline = Pokex.PngFixtures.write!(Path.join(tmp, "base.png"), rows(8, 8, {0, 60, 120}))

    strip_rows =
      for y <- 0..99 do
        for x <- 0..29 do
          if x in 10..17 and y in 20..23, do: {230, 40, 40, 255}, else: {30, 30, 30, 255}
        end
      end

    strip = Pokex.PngFixtures.write!(Path.join(tmp, "strip.png"), strip_rows)
    {:ok, _} = Fake.start_link(%{capture: [{:ok, strip}]})

    assert {:ok, %{wild: true}} =
             Sensors.Real.observe([:wild], calib(tmp, baseline), %{})
  end

  @tag :tmp_dir
  test "battle_lock reads per-row red bands (points × scale)", %{tmp_dir: tmp} do
    baseline = Pokex.PngFixtures.write!(Path.join(tmp, "base.png"), rows(8, 8, {0, 60, 120}))

    # battle_body of the calib is {700,100,230,200}; at scale 2.0 the frame is
    # 460×400. battle_row_height 52 → band = 104; the top is CENTERED on the click
    # point, so top = 18*2 - 104/2 = -16, and band 1 spans frame-y [88,192). Paint
    # the ring's red squarely inside band 1.
    body_rows =
      for y <- 0..399 do
        for x <- 0..459 do
          if x in 0..200 and y in 100..180, do: {230, 40, 40, 255}, else: {20, 20, 20, 255}
        end
      end

    body = Pokex.PngFixtures.write!(Path.join(tmp, "body.png"), body_rows)
    {:ok, _} = Fake.start_link(%{capture: [{:ok, body}]})

    assert {:ok, %{battle_lock: counts}} =
             Sensors.Real.observe([:battle_lock], calib(tmp, baseline), Pokex.Settings.defaults())

    assert length(counts) == 6
    assert Enum.at(counts, 1) > 0
    assert Enum.at(counts, 0) == 0
    assert Enum.at(counts, 2) == 0
    assert Enum.all?(Enum.drop(counts, 2), &(&1 == 0))
  end

  @tag :tmp_dir
  test "battle_lock falls back to default band/rows when settings omit the keys", %{tmp_dir: tmp} do
    baseline = Pokex.PngFixtures.write!(Path.join(tmp, "base.png"), rows(8, 8, {0, 60, 120}))
    body = Pokex.PngFixtures.write!(Path.join(tmp, "body.png"), rows(20, 20, {20, 20, 20}))
    {:ok, _} = Fake.start_link(%{capture: [{:ok, body}]})

    # empty settings → band/rows fall back to defaults 30/6, list length still 6
    assert {:ok, %{battle_lock: counts}} =
             Sensors.Real.observe([:battle_lock], calib(tmp, baseline), %{})

    assert length(counts) == 6
    assert Enum.all?(counts, &(&1 == 0))
  end

  # :battle is ONE full-region screenshot sliced in memory into the body (HP bars + lock ring)
  # and the rightmost pokeball strip. Geometry: calib battle_region {700,100,260,200} → frame
  # 520×400 at scale 2.0; strip_px = 30·2 = 60, so body = cols 0..459, strip = cols 460..519.
  # Bands (battle_row_height 52): {top -16, height 104} → row0 [-16,88) row1 [88,192)
  # row2 [192,296) row3 [296,400). HP bar = green in the body; pokeball = red in the strip; the
  # lock ring = wide red in the body. A single Fake capture returns the whole region.
  #
  # opts: :hp (green HP-bar body rows), :ball (red pokeball strip rows), :ring (wide red body rows)
  defp battle_png(tmp, name, opts) do
    hp = opts[:hp] || []
    ball = opts[:ball] || []
    ring = opts[:ring] || []

    frame =
      for y <- 0..399 do
        for x <- 0..519 do
          cond do
            y in hp and x in 0..149 -> {40, 200, 60, 255}
            y in ring and x in 0..200 -> {230, 40, 40, 255}
            y in ball and x in 460..479 -> {230, 40, 40, 255}
            true -> {20, 20, 20, 255}
          end
        end
      end

    Pokex.PngFixtures.write!(Path.join(tmp, name), frame)
  end

  defp observe_battle(tmp, opts) do
    baseline = Pokex.PngFixtures.write!(Path.join(tmp, "base.png"), rows(8, 8, {0, 60, 120}))
    png = battle_png(tmp, "battle.png", opts)
    {:ok, _} = Fake.start_link(%{capture: [{:ok, png}]})
    Sensors.Real.observe([:battle], calib(tmp, baseline), Pokex.Settings.defaults())
  end

  @tag :tmp_dir
  test "a pokeball on a row does NOT erase it — quest-catchable enemies carry one", %{
    tmp_dir: tmp
  } do
    # Measured live (2026-07-20): a "Catch Pokémon" quest marks the CATCHABLE
    # enemy's battle row with a pokeball — the very creature the bot must
    # attack — while the own pokemon (out of its ball, HP readable) does not
    # appear in the list at all. The old "pokeball = own pokemon" subtraction
    # erased the only enemy: battle read 0 forever and combat never fought
    # back. Rows with an HP bar are enemies, pokeball or not; the lock ring
    # (and the game's own Tab, which cannot target your pokemon) is what
    # confirms a real target.
    assert {:ok, %{battle: %{enemies: [0, 1, 3]}}} =
             observe_battle(tmp, hp: [40, 120, 340], ball: [40])
  end

  @tag :tmp_dir
  test "the SOLE enemy row keeps its pokeball and is still attackable (the 2026-07-20 hang)",
       %{tmp_dir: tmp} do
    assert {:ok, %{battle: %{enemies: [1]}}} = observe_battle(tmp, hp: [120], ball: [120])
  end

  @tag :tmp_dir
  test "with no pokeball, every HP-bar row is an enemy (all attackable)", %{tmp_dir: tmp} do
    assert {:ok, %{battle: %{enemies: [1, 2]}}} = observe_battle(tmp, hp: [120, 240])
  end

  @tag :tmp_dir
  test "battle also returns the per-row lock ring (red) for confirmation", %{tmp_dir: tmp} do
    # a confirmed target at row 2: HP bar + a wide red ring → enemies [2] and red[2] over 350.
    {:ok, %{battle: %{enemies: enemies, red: red}}} =
      observe_battle(tmp, hp: [240], ring: 200..280)

    assert enemies == [2]
    assert Enum.at(red, 2) > 350
    assert Enum.at(red, 0) == 0
    assert Enum.at(red, 1) == 0
  end

  @tag :tmp_dir
  test "battle enemies is [] and the ring is all-zero when the list is empty", %{tmp_dir: tmp} do
    assert {:ok, %{battle: %{enemies: [], red: red}}} = observe_battle(tmp, [])
    assert Enum.all?(red, &(&1 == 0))
  end

  @tag :tmp_dir
  test "propagates rig errors", %{tmp_dir: tmp} do
    baseline = Pokex.PngFixtures.write!(Path.join(tmp, "base.png"), rows(8, 8, {0, 60, 120}))
    {:ok, _} = Fake.start_link(%{capture: [{:error, :denied}]})

    assert {:error, {:glow, :denied}} =
             Sensors.Real.observe([:glow], calib(tmp, baseline), Pokex.Settings.defaults())
  end
end
