defmodule Pokex.Perception.BattleRowWordTest do
  @moduledoc """
  His battle list on 2026-09-11: his Venusaur on top and five Golems under it.

  The names are 7px, anti-aliased, and no ink floor splits them into whole
  letters — so the list never spelled a single one, and his own row always read
  "?". What IS stable is the rendering: a row's `word` is a hash of the name as
  drawn, and this capture is the proof that it tells his row from the enemy's.
  """
  use ExUnit.Case, async: false

  alias Pokex.Perception.Interpret
  alias Pokex.Vision.Frame

  @capture "test/fixtures/battle/venusaur_e_cinco_golems.png"

  # measured on this capture: bars every 30pt, the first centred at 30
  @settings %{
    battle_row_height: 30,
    battle_first_row_y: 31,
    battle_max_rows: 10,
    target_locked_min_pixels: 120
  }

  defp read! do
    {:ok, frame} = Frame.from_png_file(@capture)
    Interpret.battle(frame, nil, @settings)
  end

  test "every row carries a word" do
    detail = read!().enemies_detail

    assert length(detail) == 6
    assert Enum.all?(detail, &is_integer(&1.word))
  end

  test "five Golems render the same word" do
    [_his | golems] = read!().enemies_detail

    assert golems |> Enum.map(& &1.word) |> Enum.uniq() |> length() == 1
  end

  test "his Venusaur renders a different word from every Golem" do
    [his | golems] = read!().enemies_detail

    assert Enum.all?(golems, &(&1.word != his.word))
  end
end
