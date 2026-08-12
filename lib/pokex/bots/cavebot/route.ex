defmodule Pokex.Bots.Cavebot.Route do
  @moduledoc """
  Cavebot hunt route: an ordered waypoint sequence, walked as a loop.

  Pure struct — no process, screen, Settings or IO. A waypoint is a place
  (`x`, `y`, `z`) plus three independent things it can carry: a JOB
  (`t:action/0` — the mob-stretch brackets), a list of STOPS
  (`t:stop/0` — what the hunt does there once the fighting ends) and a list of
  SKILLS (`t:skill/0` — what the pokémon fires there, said by category).

  A route may climb: `z` is the floor it STARTS on, `floors/1` is every floor
  it visits, and it is the Logic — not this struct — that refuses a floor
  nobody marked.
  """

  @enforce_keys [:name]
  defstruct name: nil,
            dungeon: nil,
            z: nil,
            enabled?: true,
            # THIS route's huddle ruler; nil hands the answer to the global
            # number in /config
            gather_wait_ms: nil,
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
  What work the pokémon does HERE, said by category and never by key.

  Third axis of the waypoint, beside the job and the stops, for the same reason
  that split the first two: the corner where he casts the aura is usually
  exactly the corner already marked "até aqui", and making the two compete for
  one slot would make the most useful combination the impossible one.

  Category, never key: the key comes from whichever pokémon is out at the
  moment of pressing, so swapping Vileplume (aura on 1) for Vespiquen (aura on
  2) does not make the route lie. Written ONLY by his hand — the recorder never
  touches this.
  """
  @type skill :: :buffs | :aoe | :single | :heal | :crowd

  @skills [:buffs, :aoe, :single, :heal, :crowd]

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
          park_point: {integer, integer} | nil,
          park_tiles: {integer, integer} | nil,
          fight_ms: non_neg_integer | nil,
          gather_ms: non_neg_integer | nil,
          combo: [String.t()],
          skills: [skill],
          gather_wait_ms: non_neg_integer | nil
        }

  @typedoc """
  WHERE the pokémon is sent, said in one of the two languages that make sense.

  `{:point, {x, y}}` is a screen point — his own middle click, exactly where he
  made it, true for as long as the game window does not move. `{:tiles, {dx,
  dy}}` is a distance from the character, which survives the window moving and
  is the one he can measure by eye ("6 tiles à direita, 2 acima").
  """
  @type spot :: {:point, {integer, integer}} | {:tiles, {integer, integer}}

  @type t :: %__MODULE__{
          name: String.t(),
          dungeon: String.t() | nil,
          z: integer | nil,
          enabled?: boolean,
          gather_wait_ms: non_neg_integer | nil,
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
      park_point: nil,
      park_tiles: nil,
      fight_ms: nil,
      gather_ms: nil,
      combo: [],
      skills: [],
      gather_wait_ms: nil
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

  @doc """
  Where the pokémon is parked, said as a DISTANCE FROM THE CHARACTER in tiles —
  right and down positive.

  Writing it clears the recorded screen point: they are two answers to the same
  question, and a waypoint carrying both would need a rule nobody can see. His
  hand correcting the distance is the newer answer.

  `nil` takes the waypoint back to having no spot of its own.
  """
  @spec set_park_tiles(t, non_neg_integer, {integer, integer} | nil) :: t
  def set_park_tiles(%__MODULE__{waypoints: waypoints} = route, index, tiles)
      when is_nil(tiles) or (is_tuple(tiles) and tuple_size(tiles) == 2) do
    case Enum.at(waypoints, index) do
      nil ->
        route

      wp ->
        wp = %{wp | park_tiles: tiles, park_point: nil}
        %{route | waypoints: List.replace_at(waypoints, index, wp)}
    end
  end

  @doc """
  Where the pokémon goes at this waypoint: its own distance, its own recorded
  click, or the hunt's default distance — in that order, `nil` when none of the
  three says anything.

  The default is what makes a kill spot he never marked still park the pokémon
  away from him: two of his five kill spots (2026-08-11) carry no point at all,
  so the pile closed in around HIM.
  """
  @spec park_spot(waypoint, {integer, integer} | nil) :: spot | nil
  def park_spot(waypoint, default_tiles \\ nil)
  def park_spot(%{park_tiles: {_dx, _dy} = tiles}, _default), do: {:tiles, tiles}
  def park_spot(%{park_point: {_x, _y} = point}, _default), do: {:point, point}
  def park_spot(_waypoint, {0, 0}), do: nil
  def park_spot(_waypoint, {_dx, _dy} = default), do: {:tiles, default}
  def park_spot(_waypoint, _no_default), do: nil

  @doc """
  What HE did at this waypoint, measured from his own hands.

  `fight_ms` is how long the kill took (shift+1 to shift+3 — "shift+3 é pq eu
  já terminei de matar tudo, shift+1 é por que vou matar monstro"),
  `gather_ms` how long he waited between parking the pokémon and firing the
  first skill (the huddle, measured instead of guessed at four seconds), and
  `combo` the skills he actually pressed there, in order.

  Learning material, not orders: since 2026-08-12 the hunt no longer obeys
  `gather_ms` — the eight kill spots of Meganium 1 measured anywhere from 569ms
  to 4534ms, which is a lottery and not a ruler. What the hunt obeys is
  `gather_wait/3`; the measurement is only what the screen offers as a starting
  point. The strategy engine will read `combo`.
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

  defp put_timing(wp, :combo, keys) when is_list(keys), do: Map.put(wp, :combo, keys)
  defp put_timing(wp, _unknown, _value), do: wp

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

  @doc "Every category a waypoint can carry, in the order they come out."
  @spec skills() :: [skill]
  def skills, do: @skills

  @doc """
  Turns one category on or off at the waypoint `index`.

  Kept in the canonical order and not in the clicking order: two routes with
  the same skills have to press the same sequence. An index nobody has, or a
  category nobody knows, returns the route untouched — same rule as
  `set_stop/4`.
  """
  @spec set_skill(t, non_neg_integer, skill, boolean) :: t
  def set_skill(%__MODULE__{} = route, index, skill, on?)
      when is_integer(index) and skill in @skills and is_boolean(on?),
      do: toggle_in(route, index, :skills, @skills, skill, on?)

  def set_skill(%__MODULE__{} = route, _index, _unknown, _on?), do: route

  # The one rule both toggled axes obey, written once: take what the waypoint
  # carries in `field`, add or drop `value`, and store the result in the
  # CANONICAL order rather than the clicking order — two waypoints marked the
  # same have to run the same sequence.
  #
  # Read through Access and written with `Map.put/3`, never `%{wp | field}`: a
  # waypoint decoded from a routes.json older than the field has no such key
  # (there is no migration by design), and toggling it must work rather than
  # raise. An index nobody has is a no-op, never an error.
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

  @doc "The categories of the waypoint `index` — `[]` for an index nobody has."
  @spec skills_at([waypoint], non_neg_integer) :: [skill]
  def skills_at(waypoints, index) when is_list(waypoints) and is_integer(index) do
    case Enum.at(waypoints, index) do
      %{skills: skills} when is_list(skills) -> skills
      _absent_or_old -> []
    end
  end

  @doc """
  THIS route's huddle ruler — how long it waits for the pile to close in before
  firing the first skill. `nil` hands the answer back to the global number.

  It exists because what the recording measured does not work as an order: the
  eight kill spots of Meganium 1 measured anywhere from 569ms to 4534ms. A
  number he can dial DOWN is what makes the route faster; the measurement is
  only where to start.
  """
  @spec set_gather_wait(t, non_neg_integer | nil) :: t
  def set_gather_wait(%__MODULE__{} = route, ms) when is_nil(ms) or (is_integer(ms) and ms >= 0),
    do: %{route | gather_wait_ms: ms}

  @doc "THIS waypoint's huddle; `nil` hands the answer back to the route's ruler."
  @spec set_gather_wait(t, non_neg_integer, non_neg_integer | nil) :: t
  def set_gather_wait(%__MODULE__{waypoints: waypoints} = route, index, ms)
      when is_integer(index) and (is_nil(ms) or (is_integer(ms) and ms >= 0)) do
    case Enum.at(waypoints, index) do
      nil ->
        route

      wp ->
        %{route | waypoints: List.replace_at(waypoints, index, Map.put(wp, :gather_wait_ms, ms))}
    end
  end

  @doc """
  How long to wait for the pile to close in at this waypoint: his hand on the
  corner, else the route's ruler, else the global number — in that order.

  `nil` is absence and zero is an answer ("wait for nothing here") — but zero
  is truthy in Elixir, so `||` would honour it just as well. `is_integer/1`
  earns its place against the OTHER shape: a `"600"` or a `600.0` decoded from
  a hand-edited `routes.json` is truthy too, and `||` would hand it back as a
  wait. Only an integer answers here; anything else falls through.
  """
  @spec gather_wait(t, waypoint, non_neg_integer) :: non_neg_integer
  def gather_wait(%__MODULE__{gather_wait_ms: route_ms}, waypoint, default) do
    waypoint_ms = waypoint[:gather_wait_ms]

    cond do
      is_integer(waypoint_ms) -> waypoint_ms
      is_integer(route_ms) -> route_ms
      true -> default
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
  `nil` unless a gathering can never END — the one mark that actually breaks
  the hunt.

  Counting starts against ends was too crude, and cried wolf on shapes that
  are perfectly fine: two kill spots in a row (two piles at the same corner)
  and two gatherings closing on one end are both legitimate, and both were
  being reported. An EXTRA "até aqui" costs nothing — it just marks another
  kill spot. A "mobar daqui" that never closes costs everything: the hunt
  walks the whole route refusing to fight.
  """
  @spec lure_issue(t) :: nil | :start_without_end
  def lure_issue(%__MODULE__{waypoints: waypoints}) do
    starts? = Enum.any?(waypoints, &(&1.action == :lure_start))
    ends? = Enum.any?(waypoints, &(&1.action == :lure_end))

    if starts? and not ends?, do: :start_without_end
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
