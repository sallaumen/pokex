defmodule Pokex.Vision.IconsTest do
  @moduledoc """
  Reads WHICH pokémon sits in each C+N row of the real panel. The C+N order
  genuinely changes between the committed captures, and the learned portraits
  must follow the pokémon, not the key.
  """
  use ExUnit.Case, async: true

  alias Pokex.ScreenFixtures
  alias Pokex.Vision.Icons

  # measured by pixel probe: the disc's grey ring sits at x18-19 and x70-71, so
  # the portrait is 54px wide centred on x 44/45, repeating every 67px
  @first_centre {45, 1137}
  @radius 27
  @pitch 67

  # the capture whose team order was confirmed in writing (see TIME.md)
  @taught %{
    "Xatu" => 0,
    "Tentacruel" => 1,
    "Pidgeot" => 2,
    "Wigglytuff" => 3,
    "Ditto" => 4
  }

  defp centre(row) do
    {cx, cy} = @first_centre
    {cx, cy + row * @pitch, @radius}
  end

  defp learned do
    frame = ScreenFixtures.frame!("ultrawide_3440x1440_time")
    Map.new(@taught, fn {name, row} -> {name, Icons.signature(frame, centre(row))} end)
  end

  defp read_row(fixture, row, learned) do
    ScreenFixtures.frame!(fixture)
    |> Icons.signature(centre(row))
    |> Icons.match(learned)
  end

  test "reads back the panel it learned from, row for row" do
    learned = learned()

    for {name, row} <- @taught do
      assert {^name, score} = read_row("ultrawide_3440x1440_time", row, learned)
      assert score > 0.9, "#{name} devia se reconhecer quase perfeitamente"
    end
  end

  test "follows the pokémon when the order changes" do
    learned = learned()

    taught_order = ["Xatu", "Tentacruel", "Pidgeot", "Wigglytuff", "Ditto"]

    read_order =
      for row <- 0..4//1 do
        case read_row("ultrawide_3440x1440_outro_mapa", row, learned) do
          {name, _score} -> name
          nil -> nil
        end
      end

    identified = Enum.reject(read_order, &is_nil/1)

    assert identified != [], "nenhuma linha identificada na captura antiga"
    assert Enum.all?(identified, &(&1 in taught_order))
    assert read_order != taught_order, "a ordem devia ter mudado entre as capturas"
    assert length(Enum.uniq(identified)) == length(identified), "um pokémon em duas linhas"
  end

  test "a row it has never been taught reads as unknown, not as a guess" do
    frame = ScreenFixtures.frame!("ultrawide_3440x1440_time")
    only_xatu = %{"Xatu" => Icons.signature(frame, centre(0))}

    assert {"Xatu", _} = read_row("ultrawide_3440x1440_time", 0, only_xatu)

    for row <- 1..4//1 do
      assert read_row("ultrawide_3440x1440_time", row, only_xatu) == nil,
             "linha #{row} chutou Xatu"
    end
  end

  test "nothing learned means nothing claimed" do
    frame = ScreenFixtures.frame!("ultrawide_3440x1440_time")

    assert Icons.match(Icons.signature(frame, centre(0)), %{}) == nil
  end

  test "the right portrait wins by a mile, not by a hair" do
    learned = learned()
    frame = ScreenFixtures.frame!("ultrawide_3440x1440_time")

    scores =
      learned
      |> Map.new(fn {name, _sig} ->
        {name, Icons.similarity(Icons.signature(frame, centre(@taught[name])), learned[name])}
      end)

    wrong =
      for {name, row} <- @taught, {other, reference} <- learned, other != name do
        Icons.similarity(Icons.signature(frame, centre(row)), reference)
      end

    assert Enum.min(Map.values(scores)) > 0.9
    assert Enum.max(wrong) < 0.6, "um portrait errado chegou perto demais"
  end
end
