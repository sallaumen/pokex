defmodule Pokex.Bots.Cavebot.Route do
  @moduledoc """
  Cavebot hunt route: an ordered waypoint sequence, walked as a loop.

  Pure struct — no process, screen, Settings or IO. A waypoint is a PLACE
  (`x`, `y`, `z`) plus a list of STOPS (`t:stop/0` — what the hunt does there
  once the fighting ends).

  ## The map says WHERE, never WHEN to fight

  It used to carry a job too — `:lure_start`/`:lure_end`, the brackets of a
  gathering stretch — and the hunt read them to decide whether one monster on
  screen was worth stopping for. That decision does not belong to a recording:
  it belongs to the count of creatures actually around him RIGHT NOW, which is
  the brain's whole subject (`Engine.Logic`, the ruler). The marks were laid
  automatically from how long he stood still, nobody tuned them, and where they
  said "not gathering" a SINGLE monster stopped the hunt while the brain's
  ruler was set to five. They are gone; the road now holds only when the brain
  says `route: :hold`.

  A route may climb: `floors/1` is every floor it visits, derived from the
  waypoints themselves, and it is the Logic — not this struct — that refuses a
  floor nobody marked.
  """

  alias Pokex.Bots.HuntMode

  @enforce_keys [:name]
  defstruct name: nil,
            dungeon: nil,
            enabled?: true,
            # WHICH combat strategy this route hunts with; nil hands the answer
            # to the global default (`Pokex.Bots.HuntMode`). A dungeon of strong
            # monsters and a cheap corridor are not the same fight, and this is
            # the only field that says so.
            mode: nil,
            waypoints: []

  @typedoc """
  What the hunt DOES at a waypoint once it gets there and the fighting stops.

  `:cooldown_revive` is the recall/max-revive/release combo (`Q`, `Shift+Q` on
  the portrait, `Q`) — reviving resets every skill cooldown, which buys the
  next fight a full bar instead of a wait. `:wait` simply stands still long
  enough for cooldowns to come back on their own.

  They run in THIS order, whichever are marked: the revive is instant and
  should reset the bar before anything else spends time, and the wait is the
  last resort that only costs seconds.

  There was a third, `:sweep` — throw a ball at every tile around before
  walking on. It was removed on 2026-08-28: the Catcher only sweeps in the
  standing mode (`player_mode == "still"`), so during a hunt the request was
  refused at the door and the corner paid the grace window standing still for
  nothing. A stop that costs seconds and does nothing is worse than no stop.
  """
  @type stop :: :cooldown_revive | :wait

  @stops [:cooldown_revive, :wait]

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
          stops: [stop],
          at: DateTime.t() | nil,
          dwell_ms: non_neg_integer | nil,
          fight_ms: non_neg_integer | nil,
          gather_ms: non_neg_integer | nil
        }

  @type t :: %__MODULE__{
          name: String.t(),
          dungeon: String.t() | nil,
          enabled?: boolean,
          mode: HuntMode.t() | nil,
          waypoints: [waypoint]
        }

  @doc """
  Creates an empty route. `waypoints: []`, `enabled?: true`.
  """
  @spec new(String.t(), String.t() | nil) :: t
  def new(name, dungeon \\ nil) when is_binary(name) do
    %__MODULE__{name: name, dungeon: dungeon}
  end

  @doc """
  Appends a waypoint to the end of the route.

  A waypoint on ANOTHER floor is appended like any other: a hunt with stairs is
  an ordinary hunt (2026-08-10 — refusing it stopped the first real route Lucas
  tried to record). Which floors the route touches is `floors/1`, read off the
  waypoints; the struct keeps no floor of its own.

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
      stops: [],
      at: Keyword.get(opts, :at),
      dwell_ms: nil,
      fight_ms: nil,
      gather_ms: nil
    }

    {:ok, %{route | waypoints: route.waypoints ++ [waypoint]}}
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
  Corrects WHERE the waypoint at `index` is, keeping everything else it carries.

  "Tem como eu editar na mao pontos da rota?" (Lucas, 2026-08-11): a thin
  staircase whose exact tile the recording missed by one tile, and no way to
  say so except walking the whole route again. The route's own `z` is NOT
  rewritten — it means "the floor it starts on", and correcting a point is not
  starting over.
  """
  @spec move_to(t, non_neg_integer, {integer, integer, integer}) :: t
  def move_to(%__MODULE__{waypoints: waypoints} = route, index, {x, y, z})
      when is_integer(index) and is_integer(x) and is_integer(y) and is_integer(z) do
    case Enum.at(waypoints, index) do
      nil -> route
      wp -> %{route | waypoints: List.replace_at(waypoints, index, %{wp | x: x, y: y, z: z})}
    end
  end

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
  What HE did at this waypoint, measured from his own hands.

  `fight_ms` is how long the kill took (shift+1 to shift+3: shift+1 means he is going to kill,
  shift+3 that he has finished killing) and `gather_ms` how long he waited between parking the
  pokémon and firing the first skill.

  MEASUREMENT, never orders — and now that is all it is. The hunt reads neither:
  what it waits for is the brain's own `engine_bunch_ms`, decided on the pile it
  can actually see. These two numbers exist so the page can show him what a
  corner cost, which is the only thing they were ever good at (the eight kill
  spots of one route measured anywhere from 569 ms to 4534 ms — a lottery, not a
  ruler).
  """
  @spec set_timing(t, non_neg_integer, keyword) :: t
  def set_timing(%__MODULE__{waypoints: waypoints} = route, index, fields) do
    case Enum.at(waypoints, index) do
      nil ->
        route

      wp ->
        wp = Enum.reduce(fields, wp, fn {key, value}, acc -> put_timing(acc, key, value) end)
        %{route | waypoints: List.replace_at(waypoints, index, wp)}
    end
  end

  defp put_timing(wp, key, value) when key in [:fight_ms, :gather_ms] and is_integer(value),
    do: Map.put(wp, key, value)

  defp put_timing(wp, _unknown, _value), do: wp

  @doc "Every stop action there is, in the order they run."
  @spec stops() :: [stop]
  def stops, do: @stops

  @doc """
  Turns one stop action on or off at `index`.

  Stops are a SECOND axis, not more jobs: the waypoint where a gathered pile dies is exactly the
  one worth reviving at, and it is already carrying the kill-spot mark. Making them compete for
  one slot would make the most useful combination the impossible one.

  An index nobody has, or an action nobody knows, leaves the route untouched.
  """
  @spec set_stop(t, non_neg_integer, stop, boolean) :: t
  def set_stop(%__MODULE__{} = route, index, stop, on?)
      when is_integer(index) and stop in @stops and is_boolean(on?),
      do: toggle_in(route, index, :stops, @stops, stop, on?)

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
  WHICH combat strategy this route hunts with — `nil` gives the answer back to
  the global default.

  Whitelisted through `HuntMode.parse/1`, so a mode this build does not know
  (a hand-edited file, a route written by a newer build) reads as absence and
  the hunt runs the default instead of raising mid-fight.
  """
  @spec set_mode(t, HuntMode.t() | String.t() | nil) :: t
  def set_mode(%__MODULE__{} = route, mode), do: %{route | mode: HuntMode.parse(mode)}

  # Kept in the canonical order and not in the clicking order: two routes with
  # the same stops have to run the same sequence.
  defp toggle_in(%__MODULE__{waypoints: waypoints} = route, index, field, canonical, value, on?) do
    case Enum.at(waypoints, index) do
      nil ->
        route

      wp ->
        carried = wp[field] || []
        kept = if on?, do: [value | carried], else: carried -- [value]
        wp = Map.put(wp, field, Enum.filter(canonical, &(&1 in kept)))
        %{route | waypoints: List.replace_at(waypoints, index, wp)}
    end
  end

  @doc """
  Pairs of corners the hunt can never WALK between: same floor, and closer to
  each other than the arrival tolerance, so reaching the first already counts
  as reaching the second.

  His own route (2026-08-15) carried sixteen of them in seventy corners, and
  the journal shows the result — three corners ticked off in the same second,
  which is what he read as "usando todas as esquinas antes da hora".

  Reported, never removed: `tidy/1` moves marks, never the road (that is the
  promise its own tests make), and which of the two corners deserves to stay
  is a decision about the walk.
  """
  @spec unwalkable_pairs(t, non_neg_integer) :: [non_neg_integer]
  def unwalkable_pairs(%__MODULE__{waypoints: waypoints}, tolerance) do
    waypoints
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.with_index()
    |> Enum.filter(fn {[a, b], _index} ->
      a.z == b.z and abs(a.x - b.x) <= tolerance and abs(a.y - b.y) <= tolerance
    end)
    |> Enum.map(&elem(&1, 1))
  end

  @doc """
  Corners that send the character UP a staircase and straight back DOWN onto
  the tile he left — a round trip that walks two floors to arrive where it
  started.

  Found in his own route (2026-08-15): 66 at `2310,30021` on floor 5, 67 at
  `2310,30023` on floor 6, 68 back at `2310,30021` on floor 5. That is the
  "ficou subindo e descendo na escada" he reported, and it was never a bug in
  the walking — it is written in the marks.

  Returned, never fixed: a room upstairs he farms and comes back from is the
  same shape, and only he knows which one this is.
  """
  @spec stair_round_trips(t) :: [non_neg_integer]
  def stair_round_trips(%__MODULE__{waypoints: waypoints}) do
    waypoints
    |> Enum.with_index()
    |> Enum.filter(fn {_wp, index} -> round_trip_at?(waypoints, index) end)
    |> Enum.map(&elem(&1, 1))
  end

  defp round_trip_at?(waypoints, index) do
    with %{} = here <- Enum.at(waypoints, index),
         %{} = up <- Enum.at(waypoints, index + 1),
         %{} = back <- Enum.at(waypoints, index + 2) do
      up.z != here.z and back.z == here.z and back.x == here.x and back.y == here.y
    else
      _end_of_route -> false
    end
  end

  @doc """
  Empties the route, floor included: the next recording starts on whatever
  floor the character is actually standing on.
  """
  @spec clear(t) :: t
  def clear(%__MODULE__{} = route), do: %{route | waypoints: []}

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
  The leg LEAVING `index`, when it is a staircase step: `{:stair, sx, sy}` with the direction to
  press, `nil` otherwise.

  Taking a staircase is ONE key that moves TWO tiles: the step and the tile past it. As he
  measured it, going from one point to another on his left makes the coordinate rise by two, one
  block for the staircase and one for the block after it, in a single step. He marks the corner
  right before and the one right after, so the pair describes the whole staircase.

  The signature is therefore exact and narrow: the floor changes AND one axis moved exactly two
  tiles while the other did not move at all. Seven of the fourteen floor changes in the three
  recorded routes the tests assert match it; the other seven have extra walking folded into the
  same corner and are left to the ring search, which is what that search is for.

  Same leg convention as `lure_leg?/2` and `floor_change/2`: the closing leg of the loop is a
  real leg, and one of his routes takes its stairs there.
  """
  @spec stair_leg([waypoint], non_neg_integer) :: {:stair, -1..1, -1..1} | nil
  def stair_leg(waypoints, index) when is_list(waypoints) and is_integer(index) do
    count = length(waypoints)

    with true <- index in 0..(count - 1)//1,
         %{x: x1, y: y1, z: z1} <- Enum.at(waypoints, index),
         %{x: x2, y: y2, z: z2} when z2 != z1 <- Enum.at(waypoints, rem(index + 1, count)),
         {dx, dy} when abs(dx) + abs(dy) == 2 and (dx == 0 or dy == 0) <- {x2 - x1, y2 - y1} do
      {:stair, sign(dx), sign(dy)}
    else
      _not_a_stair -> nil
    end
  end

  defp sign(0), do: 0
  defp sign(n) when n > 0, do: 1
  defp sign(_negative), do: -1

  @doc """
  The staircase tile itself: the midpoint of the pair — `nil` unless the leg
  leaving `index` is a stair.

  Derivable, never calibrated: two tiles apart with the step in between is what
  makes the midpoint exact. The screen shows it so he can see the route agrees
  with the map.
  """
  @spec stair_step([waypoint], non_neg_integer) :: {integer, integer} | nil
  def stair_step(waypoints, index) when is_list(waypoints) and is_integer(index) do
    with {:stair, _sx, _sy} <- stair_leg(waypoints, index),
         %{x: x1, y: y1} <- Enum.at(waypoints, index),
         %{x: x2, y: y2} <- Enum.at(waypoints, rem(index + 1, length(waypoints))) do
      {div(x1 + x2, 2), div(y1 + y2, 2)}
    else
      _not_a_stair -> nil
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
