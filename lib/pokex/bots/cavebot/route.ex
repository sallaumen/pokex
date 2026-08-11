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

  @typedoc """
  What a waypoint is FOR, beyond being a place.

  `:walk` is the plain corner every recording lays down. `:lure_start` and
  `:lure_end` bracket a stretch walked GATHERING mobs instead of fighting them
  ("mobar daqui" … "até aqui").
  """
  @type action :: :walk | :lure_start | :lure_end

  @actions [:walk, :lure_start, :lure_end]

  @type waypoint :: %{x: integer, y: integer, z: integer, action: action}

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
    {:ok, %{route | z: z, waypoints: route.waypoints ++ [%{x: x, y: y, z: z, action: :walk}]}}
  end

  def append(%__MODULE__{z: z} = route, {x, y, z})
      when is_integer(x) and is_integer(y) and is_integer(z) do
    {:ok, %{route | waypoints: route.waypoints ++ [%{x: x, y: y, z: z, action: :walk}]}}
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
  Gives the waypoint at `index` a job (`t:action/0`).

  An index nobody has, or a job nobody knows, leaves the route untouched —
  same rule as `move/3`: a control that cannot act is a no-op, never an error.
  """
  @spec set_action(t, non_neg_integer, action) :: t
  def set_action(%__MODULE__{waypoints: waypoints} = route, index, action)
      when is_integer(index) and action in @actions do
    case Enum.at(waypoints, index) do
      nil ->
        route

      waypoint ->
        %{route | waypoints: List.replace_at(waypoints, index, %{waypoint | action: action})}
    end
  end

  def set_action(%__MODULE__{} = route, _index, _unknown), do: route

  @doc """
  Is the leg LEAVING the waypoint at `index` walked while luring?

  The leg out of a waypoint carries that waypoint's job: arriving at "mobar
  daqui" is what starts the gathering, arriving at "até aqui" is what ends it.
  So the answer is "which mark comes last, at or before this waypoint" — read
  BACKWARDS around the loop, because the route is a loop and a stretch may well
  wrap past the first waypoint.

  A `:lure_start` nobody closed therefore lures the whole route. That is the
  honest reading of the marks, and `lure_issue/1` is how the editor warns
  about it.
  """
  @spec lure_leg?([waypoint], non_neg_integer) :: boolean
  def lure_leg?(waypoints, index) when is_list(waypoints) and is_integer(index) do
    count = length(waypoints)

    if index in 0..(count - 1)//1 do
      0..(count - 1)//1
      |> Enum.map(&Enum.at(waypoints, Integer.mod(index - &1, count)))
      |> Enum.find(&(&1.action != :walk))
      |> then(&match?(%{action: :lure_start}, &1))
    else
      false
    end
  end

  @doc """
  `nil` when the lure marks pair up, or which side is missing.

  In a loop an end BEFORE its start is perfectly fine (the stretch wraps), so
  what makes a pair is the count, not the order.
  """
  @spec lure_issue(t) :: nil | :start_without_end | :end_without_start
  def lure_issue(%__MODULE__{waypoints: waypoints}) do
    starts = Enum.count(waypoints, &(&1.action == :lure_start))
    ends = Enum.count(waypoints, &(&1.action == :lure_end))

    cond do
      starts > ends -> :start_without_end
      ends > starts -> :end_without_start
      true -> nil
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
