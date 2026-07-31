defmodule Pokex.Bots.Cavebot.Route do
  @moduledoc """
  Cavebot hunt route: an ordered waypoint sequence on a single floor.

  Pure struct — no process, screen, Settings or IO. Central invariant is the
  single floor (`z`): the first waypoint fixes the route's floor and all others
  must share the same `z`.
  """

  @enforce_keys [:name]
  defstruct name: nil,
            dungeon: nil,
            z: nil,
            enabled?: true,
            waypoints: []

  @type waypoint :: %{x: integer, y: integer, z: integer}

  @type t :: %__MODULE__{
          name: String.t(),
          dungeon: String.t() | nil,
          z: integer | nil,
          enabled?: boolean,
          waypoints: [waypoint]
        }

  @doc """
  Creates an empty route. `waypoints: []`, `z: nil`, `enabled?: true`.
  """
  @spec new(String.t(), String.t() | nil) :: t
  def new(name, dungeon \\ nil) when is_binary(name) do
    %__MODULE__{name: name, dungeon: dungeon}
  end

  @doc """
  Appends a waypoint to the end of the route.

  The first waypoint's `z` fixes the route's floor; waypoints on another floor
  are refused with `{:error, :floor_mismatch}`.
  """
  @spec append(t, {integer, integer, integer}) :: {:ok, t} | {:error, :floor_mismatch}
  def append(%__MODULE__{z: nil} = route, {x, y, z})
      when is_integer(x) and is_integer(y) and is_integer(z) do
    {:ok, %{route | z: z, waypoints: route.waypoints ++ [%{x: x, y: y, z: z}]}}
  end

  def append(%__MODULE__{z: z} = route, {x, y, z})
      when is_integer(x) and is_integer(y) and is_integer(z) do
    {:ok, %{route | waypoints: route.waypoints ++ [%{x: x, y: y, z: z}]}}
  end

  def append(%__MODULE__{}, {_x, _y, _z}), do: {:error, :floor_mismatch}

  @doc """
  Validates the route: at least one waypoint, all on the same floor.
  """
  @spec validate(t) :: :ok | {:error, :empty} | {:error, :floor_mismatch}
  def validate(%__MODULE__{waypoints: []}), do: {:error, :empty}

  def validate(%__MODULE__{waypoints: [%{z: z} | _] = waypoints}) do
    if Enum.all?(waypoints, &(&1.z == z)) do
      :ok
    else
      {:error, :floor_mismatch}
    end
  end
end
