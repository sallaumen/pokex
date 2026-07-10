defmodule Pokex.Perception.Interpret do
  @moduledoc "Pure frame → observation interpreters, one per feed. See Task 5."

  def battle(_frame, _calib, _settings),
    do: %{enemies: [], red: [], locked?: false, locked_row: nil}

  def arena(_frame, _calib, _settings), do: %{hostile: nil}
end
