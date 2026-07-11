defmodule Pokex.Rig do
  @moduledoc """
  Hands and eyes of the bot. The only layer allowed to touch the OS.
  Coordinates are macOS screen POINTS, origin at top-left.
  """

  @type point :: {integer, integer}
  @type region :: {integer, integer, integer, integer}

  @callback press(String.t()) :: :ok | {:error, term}
  @callback press_many([String.t()], keyword) :: :ok | {:error, term}
  @callback key_down(String.t()) :: :ok | {:error, term}
  @callback key_up(String.t()) :: :ok | {:error, term}
  @callback click(:left | :right, point) :: :ok | {:error, term}
  @callback move(point) :: :ok | {:error, term}
  @callback capture_sequence(point) :: :ok | {:error, term}
  @callback capture(region, filename :: String.t()) :: {:ok, String.t()} | {:error, term}
  @callback capture_screen() :: {:ok, String.t()} | {:error, term}
  @callback cursor_position() :: {:ok, point} | {:error, term}

  def impl, do: Application.get_env(:pokex, :rig, Pokex.Rig.Mac)
end
