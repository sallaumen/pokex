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
  Moves the waypoint at `index` one place `:up` or `:down`.

  Recording lays waypoints in the order walked, and a route walked in the wrong
  order is a route walked backwards — which used to mean deleting everything
  and walking it again. Out-of-range moves (the first up, the last down) return
  the route untouched: the button that cannot act is a no-op, never an error.
  """
  @spec move(t, non_neg_integer, :up | :down) :: t
  def move(%__MODULE__{waypoints: waypoints} = route, index, direction)
      when is_integer(index) and direction in [:up, :down] do
    target = if direction == :up, do: index - 1, else: index + 1

    if index in 0..(length(waypoints) - 1)//1 and target in 0..(length(waypoints) - 1)//1 do
      moved = Enum.at(waypoints, index)
      other = Enum.at(waypoints, target)

      %{
        route
        | waypoints: waypoints |> List.replace_at(index, other) |> List.replace_at(target, moved)
      }
    else
      route
    end
  end

  @doc """
  Inserts a waypoint AT `index`, pushing the rest down — the fix for "faltou um
  canto no meio", which appending could never give.

  Same floor invariant as `append/2`.
  """
  @spec insert_at(t, non_neg_integer, {integer, integer, integer}) ::
          {:ok, t} | {:error, :floor_mismatch}
  def insert_at(%__MODULE__{} = route, index, {x, y, z} = pos)
      when is_integer(index) and is_integer(x) and is_integer(y) and is_integer(z) do
    with {:ok, appended} <- append(route, pos) do
      {popped, rest} = List.pop_at(appended.waypoints, -1)
      {:ok, %{appended | waypoints: List.insert_at(rest, index, popped)}}
    end
  end

  @doc """
  Empties the route, floor included: the next recording starts on whatever
  floor the character is actually standing on.
  """
  @spec clear(t) :: t
  def clear(%__MODULE__{} = route), do: %{route | waypoints: [], z: nil}

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
