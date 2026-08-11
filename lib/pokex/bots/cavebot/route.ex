defmodule Pokex.Bots.Cavebot.Route do
  @moduledoc """
  Cavebot hunt route: an ordered waypoint sequence, walked as a loop.

  Pure struct — no process, screen, Settings or IO. A waypoint is a place
  (`x`, `y`, `z`) plus two independent things it can carry: a JOB
  (`t:action/0` — the mob-stretch brackets) and a list of STOPS
  (`t:stop/0` — what the hunt does there once the fighting ends).

  A route may climb: `z` is the floor it STARTS on, `floors/1` is every floor
  it visits, and it is the Logic — not this struct — that refuses a floor
  nobody marked.
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

  @typedoc """
  What the hunt DOES at a waypoint once it gets there and the fighting stops.

  `:cooldown_revive` is the recall/max-revive/release combo (`Q`, `Shift+Q` on
  the portrait, `Q`) — reviving resets every skill cooldown, which buys the
  next fight a full bar instead of a wait. `:sweep` throws a ball at every
  tile around, `:wait` simply stands still long enough for cooldowns to come
  back on their own.

  They run in THIS order, whichever are marked: the revive is instant and
  should reset the bar before anything else spends time, the sweep spends that
  time usefully, and the wait is the last resort that only costs seconds.
  """
  @type stop :: :cooldown_revive | :sweep | :wait

  @stops [:cooldown_revive, :sweep, :wait]

  @typedoc """
  A place, what it is FOR, what happens there — and WHEN it was recorded.

  `at` is the wall clock of the moment it was laid and `dwell_ms` how long he
  stood on it. Both are how the recording stopped being a list of places and
  became a list of intentions (see `Pokex.Bots.Cavebot.Recording`); both are
  nil on every route recorded before the clock was read.
  """
  @type waypoint :: %{
          x: integer,
          y: integer,
          z: integer,
          action: action,
          stops: [stop],
          at: DateTime.t() | nil,
          dwell_ms: non_neg_integer | nil,
          park_point: {integer, integer} | nil
        }

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

  A waypoint on ANOTHER floor is appended like any other: a hunt with stairs is
  an ordinary hunt (2026-08-10 — refusing it stopped the first real route Lucas
  tried to record). The route's `z` keeps meaning "the floor it starts on",
  which is what the screen labels it with; `floors/1` is the whole set.

  The safety this used to provide did not disappear, it moved to where it
  belongs: the Logic blocks on a floor the route does NOT know, which is the
  hole-and-teleport case it was really about.
  """
  @spec append(t, {integer, integer, integer}, keyword) :: {:ok, t}
  def append(%__MODULE__{} = route, {x, y, z}, opts \\ [])
      when is_integer(x) and is_integer(y) and is_integer(z) do
    waypoint = %{
      x: x,
      y: y,
      z: z,
      action: :walk,
      stops: [],
      at: Keyword.get(opts, :at),
      dwell_ms: nil,
      park_point: nil
    }

    {:ok, %{route | z: route.z || z, waypoints: route.waypoints ++ [waypoint]}}
  end

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
  """
  @spec insert_at(t, non_neg_integer, {integer, integer, integer}, keyword) :: {:ok, t}
  def insert_at(%__MODULE__{} = route, index, {x, y, z} = pos, opts \\ [])
      when is_integer(index) and is_integer(x) and is_integer(y) and is_integer(z) do
    with {:ok, appended} <- append(route, pos, opts) do
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
  How long he stood on the waypoint at `index`, in ms.

  Written while recording, and the whole input to `Recording.infer/4`: a
  corner marked in passing is a corner he walked through, a spot he stood on
  for half a minute is where he killed a pile.
  """
  @spec set_dwell(t, non_neg_integer, non_neg_integer) :: t
  def set_dwell(%__MODULE__{waypoints: waypoints} = route, index, dwell_ms)
      when is_integer(index) and is_integer(dwell_ms) and dwell_ms >= 0 do
    case Enum.at(waypoints, index) do
      nil -> route
      wp -> %{route | waypoints: List.replace_at(waypoints, index, %{wp | dwell_ms: dwell_ms})}
    end
  end

  @doc """
  Where the active pokémon is PARKED at this waypoint, in screen pixels.

  "Quando a gente termina de mobar, a gente normalmente manda o pokémon ficar
  em algum lugar da tela específico para facilitar um grupo ao redor dele —
  eu geralmente clico com o botão do meio do mouse em um ponto da minha tela"
  (Lucas, 2026-08-11). The recorder captures the point from his own middle
  click; the hunt reproduces it on arrival, and the pile closes in around the
  pokémon instead of around him.
  """
  @spec set_park_point(t, non_neg_integer, {integer, integer} | nil) :: t
  def set_park_point(%__MODULE__{waypoints: waypoints} = route, index, point)
      when is_nil(point) or (is_tuple(point) and tuple_size(point) == 2) do
    case Enum.at(waypoints, index) do
      nil -> route
      wp -> %{route | waypoints: List.replace_at(waypoints, index, %{wp | park_point: point})}
    end
  end

  @doc "Every stop action there is, in the order they run."
  @spec stops() :: [stop]
  def stops, do: @stops

  @doc """
  Turns one stop action on or off at `index`.

  Stops are a SECOND axis, not more jobs: the waypoint where a gathered pile
  dies is exactly the one worth sweeping and reviving at, and it is already
  carrying "até aqui". Making them compete for one slot would make the most
  useful combination the impossible one.

  An index nobody has, or an action nobody knows, leaves the route untouched.
  """
  @spec set_stop(t, non_neg_integer, stop, boolean) :: t
  def set_stop(%__MODULE__{waypoints: waypoints} = route, index, stop, on?)
      when is_integer(index) and stop in @stops and is_boolean(on?) do
    case Enum.at(waypoints, index) do
      nil ->
        route

      wp ->
        kept = if on?, do: [stop | wp.stops], else: wp.stops -- [stop]
        wp = %{wp | stops: Enum.filter(@stops, &(&1 in kept))}
        %{route | waypoints: List.replace_at(waypoints, index, wp)}
    end
  end

  def set_stop(%__MODULE__{} = route, _index, _unknown, _on?), do: route

  @doc "What the hunt does at the waypoint `index` — `[]` for an index nobody has."
  @spec stops_at([waypoint], non_neg_integer) :: [stop]
  def stops_at(waypoints, index) when is_list(waypoints) and is_integer(index) do
    case Enum.at(waypoints, index) do
      %{stops: stops} -> stops
      _absent -> []
    end
  end

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
  Every floor the route visits, ascending — what the Logic treats as EXPECTED.
  """
  @spec floors(t) :: [integer]
  def floors(%__MODULE__{waypoints: waypoints}),
    do: waypoints |> Enum.map(& &1.z) |> Enum.uniq() |> Enum.sort()

  @doc """
  The floor the leg LEAVING `index` arrives on, or `nil` when it stays put.

  Same leg convention as `lure_leg?/2`, closing leg included: a loop that goes
  up has to come back down, and that descent is a real leg of the walk.
  """
  @spec floor_change([waypoint], non_neg_integer) :: integer | nil
  def floor_change(waypoints, index) when is_list(waypoints) and is_integer(index) do
    count = length(waypoints)

    with true <- index in 0..(count - 1)//1,
         %{z: from} <- Enum.at(waypoints, index),
         %{z: to} when to != from <- Enum.at(waypoints, rem(index + 1, count)) do
      to
    else
      _same_floor_or_out_of_range -> nil
    end
  end

  @doc """
  Validates the route: at least one waypoint.

  Floors are no longer part of this — see `append/2`. The check that matters
  moved to the Logic, which knows something a route cannot: where the
  character actually IS.
  """
  @spec validate(t) :: :ok | {:error, :empty}
  def validate(%__MODULE__{waypoints: []}), do: {:error, :empty}
  def validate(%__MODULE__{}), do: :ok
end
