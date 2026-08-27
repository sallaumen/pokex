defmodule Pokex.Perception.BattleOwnRowTest do
  @moduledoc """
  His window with nothing in it but his own pokémon, captured 2026-08-27 at the
  moment he pulled the panic corner.

  The area had just killed all six Magnetons. One row was left — his Steelix,
  at 69% — and the bot counted it as an enemy and stood there firing at it for
  nineteen seconds ("ele estava parado quando não tinha mais monstro nenhum
  tentando usar skill").

  Nothing about that row was unreadable. The health was on screen, the Pokebar
  was reading the same number from the other side of the HUD, and the panel had
  been answering `enemies_detail: []` all night because the auto-located layout
  he does not use was the only way to describe a row.
  """
  use ExUnit.Case, async: false

  alias Pokex.Bots.Engine.Situation
  alias Pokex.Perception.Interpret
  alias Pokex.Vision.Frame

  @alone "test/fixtures/battle/so_o_meu_pokemon.png"
  @five "test/fixtures/battle/lista_cinco_linhas_alvo_na_ultima.png"

  # measured on both fixtures: bars every 30pt, the first centred at 41
  @settings %{
    battle_row_height: 30,
    battle_first_row_y: 31,
    battle_max_rows: 10,
    target_locked_min_pixels: 120,
    shiny_star_min_columns: 4
  }

  defp frame!(path) do
    {:ok, frame} = Frame.from_png_file(path)
    frame
  end

  # No `layout` — he runs on hand-drawn regions, which is the whole point.
  defp calib(frame) do
    %Pokex.Calibration{
      scale: 1.0,
      screen_w: 3440,
      screen_h: 1440,
      battle_region: {8, 600, frame.width, frame.height},
      neutral_point: {500, 500}
    }
  end

  defp read(path), do: path |> frame!() |> then(&Interpret.battle(&1, calib(&1), @settings))

  test "the row is described even with no located layout" do
    assert [%{row: 0, name: nil, shiny?: false, hp_pct: pct}] = read(@alone).enemies_detail

    # the Pokebar read 69 at the same instant
    assert_in_delta pct, 0.68, 0.02
  end

  test "every creature's health is read, not just the fact that it has a bar" do
    assert read(@five).enemies_detail |> Enum.map(& &1.hp_pct) == [
             1.0,
             0.977,
             0.574,
             0.574,
             0.349
           ]
  end

  # The health track is 128px wide and the pokeball strip is cropped by a
  # constant measured on the old client — 30px, which on this panel eats the
  # last 16px of every bar. Read on the body, a full bar answers 87%.
  test "the bar is measured on the whole frame, so a full one reads full" do
    assert read(@five).enemies_detail |> hd() |> Map.fetch!(:hp_pct) == 1.0
  end

  test "the lock ring is still found where the game painted it" do
    assert read(@five).locked_row == 4
  end

  describe "the picture the brain builds from it" do
    defp picture(path, own) do
      Situation.build(
        Map.merge(%{battle: read(path), own_out?: true, own_name: "Steelix"}, own),
        %{engage_from: 3},
        0
      )
    end

    test "his own row is found by health when no glyph can spell it" do
      assert %{rows: 1, enemies: 0, own_row_seen?: :by_hp} = picture(@alone, %{own_hp: 69})
    end

    # The fallback that shipped: his own measurement of 2026-08-18 says row 0 is
    # his in 134 of 140 readings, and it is what a tie must defer to.
    test "with no health to compare, the first unreadable row is still his" do
      assert %{rows: 1, enemies: 0, own_row_seen?: :unnamed} = picture(@alone, %{own_hp: nil})
    end

    test "a health nowhere near his takes no row away by health" do
      assert %{rows: 5, enemies: 4, own_row_seen?: :unnamed} = picture(@five, %{own_hp: 20})
    end

    # Two rows at 57% and his own at 57: a coin toss is not a reading.
    test "two rows at his health fall back to the first, not to a guess" do
      assert %{rows: 5, enemies: 4, own_row_seen?: :unnamed} = picture(@five, %{own_hp: 57})
    end

    test "one row at his health is his, wherever it sits in the list" do
      assert %{enemies: 4, own_row_seen?: :by_hp} = picture(@five, %{own_hp: 35})
    end

    # He is not on the field: an unreadable row is a creature whose name the
    # glyphs do not know, and taking it off the count leaves it alive.
    test "nothing is discounted when his pokémon is not out" do
      assert %{rows: 1, enemies: 1, own_row_seen?: false} =
               Situation.build(
                 %{battle: read(@alone), own_out?: false, own_hp: 69, own_name: "Steelix"},
                 %{engage_from: 3},
                 0
               )
    end
  end
end
