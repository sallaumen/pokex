defmodule Pokex.Vision.TileRulerTest do
  @moduledoc """
  A régua que ele enxerga: o quadrado do jogo, e não o pixel.
  """
  use ExUnit.Case, async: false

  alias Pokex.Calibration
  alias Pokex.Vision.TileRuler

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Pokex.TestHome.restore() end)

    Calibration.save(%Calibration{
      scale: 1.0,
      screen_w: 3440,
      screen_h: 1440,
      tile_px: 151,
      water_point: {1, 1},
      glow_region: {0, 0, 8, 8},
      battle_region: {3247, 321, 166, 337},
      neutral_point: {500, 500},
      player_point: {1695, 686}
    })

    :ok
  end

  test "a floor that barely matches gets the word, not a zero" do
    assert TileRuler.label(25) == "quase nada"
    assert TileRuler.label(nil) == "—"
  end

  test "under one tile it says so in his own words" do
    # meio tile de 151 pontos
    assert TileRuler.label(div(151 * 151, 2)) == "0,5 de um tile"
  end

  # O gatilho real da regra dele em 09/09: catorze tiles e meio de cor sólida.
  test "his own trigger reads as fourteen tiles and is out of reach" do
    assert TileRuler.label(332_835) == "14,6 tiles"
    assert TileRuler.unreachable?(332_835)
    refute TileRuler.unreachable?(2 * 151 * 151)
  end

  test "with no calibration it falls back instead of crashing" do
    File.rm_rf!(Pokex.Home.calibration_file())

    assert is_binary(TileRuler.label(1_000))
    refute TileRuler.unreachable?(1_000)
  end
end
