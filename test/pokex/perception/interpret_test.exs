defmodule Pokex.Perception.InterpretTest do
  use ExUnit.Case, async: false

  alias Pokex.Calibration
  alias Pokex.Perception.Interpret
  alias Pokex.Settings
  alias Pokex.Vision.Frame

  # battle_region 80x400 at scale 1.0; strip_width points cover the pokeball column.
  defp calib do
    %Calibration{
      scale: 1.0,
      screen_w: 1000,
      screen_h: 700,
      water_point: {1, 1},
      glow_region: {0, 0, 8, 8},
      battle_region: {0, 0, 80, 400},
      neutral_point: {500, 500}
    }
  end

  defp settings, do: Settings.all()

  defp frame(w, h, paint), do: Pokex.FrameFixtures.of(w, h, paint)

  test "an all-dark battle frame has no enemies and no lock" do
    f = frame(80, 400, fn _x, _y -> {9, 9, 9} end)
    obs = Interpret.battle(f, calib(), settings())
    assert obs.enemies == []
    assert obs.locked? == false
    assert obs.locked_row == nil
  end

  test "a dark-red band inside row 0's lock band reads as locked" do
    # row band geometry at scale 1.0: Calibration.row_band_geometry(1.0, row_height)
    {top, band} = Calibration.row_band_geometry(1.0, Settings.get(:battle_row_height))

    f =
      frame(80, 400, fn _x, y ->
        if y >= max(top, 0) and y < top + band, do: {160, 20, 20}, else: {9, 9, 9}
      end)

    obs = Interpret.battle(f, calib(), settings())
    assert obs.locked? == true
    assert obs.locked_row == 0
  end

  describe "skills/3" do
    # Dois slots de 50×8 com o rótulo da tecla (glifo branco 2×6 sobre fundo
    # escuro) em cada um — é o que faz o quadro SER a barra. O primeiro tem
    # duas linhas de amarelo vivo (pronta); o segundo é só o painel escuro (fria).
    defp two_slot_bar do
      rgba =
        for y <- 0..7, x <- 0..99, into: <<>> do
          cond do
            rem(x, 50) in 10..11 and y in 2..7 -> <<240, 240, 240, 255>>
            x < 50 and y < 2 -> <<200, 200, 0, 255>>
            true -> <<20, 20, 20, 255>>
          end
        end

      %Frame{width: 100, height: 8, rgba: rgba}
    end

    test "a valid bar frame reads per-slot states and ready keys" do
      frame = two_slot_bar()
      Pokex.TeamFixtures.ready!("Bulbasaur", count: 2)

      assert Interpret.skills(frame, calib(), settings()) ==
               %{states: [:ready, :cooldown], ready_keys: ["1"]}
    end

    test "a frame that no longer looks like the bar is UNKNOWN — nils, never a guess" do
      # uniform mid-grey (window moved/covered): no hotkey label in any slot
      rgba = :binary.copy(<<120, 120, 120, 255>>, 800)
      frame = %Frame{width: 100, height: 8, rgba: rgba}

      assert Interpret.skills(frame, %{calib() | skill_bar_count: 2}, settings()) ==
               %{states: nil, ready_keys: nil}
    end
  end
end
