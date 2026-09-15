defmodule Pokex.Vision.StockDigits do
  @moduledoc "Reads exact stock counts; unknown shapes and abbreviations are unreadable."

  alias Pokex.Vision.{Frame, Glyphs}

  # Measured eight-pixel glyphs: hotbar_f1_827 and minimapa_1512x982_1053_1358_6.
  @samples [
    {5, ~w(11110 10000 10000 11110 10001 00001 10011 01100)},
    {0, ~w(00100 01010 10001 10001 10001 10001 01010 00100)},
    {6, ~w(001110 011000 110000 111110 110011 110011 110011 011110)},
    {8, ~w(011110 110011 110011 011110 110010 110010 110011 011110)},
    {2, ~w(011110 110011 000011 000100 101100 011000 110000 111111)},
    {7, ~w(111111 000011 000110 000110 001100 001100 011000 011010)},
    {1, ~w(0110 1110 0100 0100 0100 0100 0110 1111)},
    {2, ~w(011110 110011 000011 000110 001100 011010 110000 111111)},
    {3, ~w(011110 110011 000011 001110 000011 000011 110011 011110)},
    {2, ~w(011110 110011 000011 000110 001100 011000 110000 111111)},
    {4, ~w(000010 000110 001110 010110 100110 111111 000110 000110)},
    {7, ~w(111111 000011 000110 000110 001100 001100 011000 011000)},
    {9, ~w(011110 110011 110011 110011 011111 000011 000110 011100)}
  ]
  @digits Map.new(@samples, fn {digit, rows} -> {Enum.join(rows, ";"), digit} end)

  @spec read(Frame.t()) :: {:ok, non_neg_integer()} | :unread
  def read(%Frame{width: width, height: height} = frame) do
    columns =
      for x <- 0..(width - 1) do
        for y <- 0..(height - 1), do: ink?(Frame.at(frame, x, y))
      end

    digits =
      columns
      |> Enum.chunk_by(&Enum.any?/1)
      |> Enum.filter(fn [column | _] -> Enum.any?(column) end)
      |> Enum.map(&digit/1)

    if digits != [] and Enum.all?(digits, &is_integer/1),
      do: {:ok, Enum.reduce(digits, 0, &(&2 * 10 + &1))},
      else: :unread
  end

  defp digit(columns) do
    rows =
      columns
      |> Enum.zip_with(& &1)
      |> Enum.drop_while(&(not Enum.any?(&1)))
      |> Enum.reverse()
      |> Enum.drop_while(&(not Enum.any?(&1)))
      |> Enum.reverse()
      |> Enum.map(fn row -> Enum.map(row, &if(&1, do: 1, else: 0)) end)

    key = Enum.map_join(rows, ";", &Enum.join/1)

    case Map.fetch(@digits, key) do
      {:ok, digit} -> digit
      :error -> atlas_digit(rows)
    end
  end

  defp atlas_digit(rows) do
    case Map.get(Glyphs.atlas(), Glyphs.signature(rows)) do
      <<digit>> when digit in ?0..?9 -> digit - ?0
      _unknown -> nil
    end
  end

  defp ink?({r, g, b}),
    do: min(r, min(g, b)) >= 180 and max(r, max(g, b)) - min(r, min(g, b)) <= 40
end
