defmodule Pokex.Perception.BattleListRealTest do
  @moduledoc """
  His own battle list, captured 2026-08-24: five creatures, the last one locked.

  The read came back with two creatures and no lock — and combat, which asks
  the list "am I fighting?", answered no while a pokémon beat him. Three
  measured reasons, all in this one picture: a damaged bar is AMBER in this
  client (neither the green nor the red the pixel rule knew), the rows repeat
  every 30pt instead of the configured 52, and row 0's band is centered at 31,
  not at the 18 the old client's list used.
  """
  use ExUnit.Case, async: false

  alias Pokex.Perception.Interpret
  alias Pokex.Vision.Frame

  @fixture "test/fixtures/battle/lista_cinco_linhas_alvo_na_ultima.png"
  # measured on the fixture: bars at 41, 71, 101, 131, 161
  @settings %{battle_row_height: 30, battle_first_row_y: 31, target_locked_min_pixels: 120}

  defp frame! do
    {:ok, frame} = Frame.from_png_file(@fixture)
    frame
  end

  defp calib(frame) do
    %Pokex.Calibration{
      scale: 1.0,
      screen_w: 3440,
      screen_h: 1440,
      battle_region: {8, 600, frame.width, frame.height},
      neutral_point: {500, 500}
    }
  end

  test "every creature is seen, damaged ones included" do
    frame = frame!()

    assert Pokex.Vision.hp_bar_row_positions(frame) == [41, 71, 101, 131, 161]
  end

  test "the five creatures land on five distinct rows" do
    frame = frame!()

    assert Interpret.battle(frame, calib(frame), @settings).enemies == [0, 1, 2, 3, 4]
  end

  test "the locked target is found, and it is the row the game painted red" do
    frame = frame!()
    obs = Interpret.battle(frame, calib(frame), @settings)

    assert obs.locked? == true
    assert obs.locked_row == 4
  end

  # The threshold that shipped (350) was measured on the old client's lock ring.
  # Here the whole red — box plus name — is 278px, and every other row is 0: the
  # signal is unmistakable, it was only the ruler that did not fit it.
  test "the red of the locked row stands alone against every other row" do
    frame = frame!()
    obs = Interpret.battle(frame, calib(frame), %{@settings | target_locked_min_pixels: 350})

    assert obs.locked_row == nil
  end
end
