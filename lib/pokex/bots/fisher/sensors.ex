defmodule Pokex.Bots.Fisher.Sensors do
  @moduledoc "Turns raw captures into the typed observations Logic consumes."

  @callback observe([atom], Pokex.Calibration.t() | nil, map) :: {:ok, map} | {:error, term}

  def impl, do: Application.get_env(:pokex, :sensors, Pokex.Bots.Fisher.Sensors.Real)
end
