defmodule Pokex.Sim.World do
  @moduledoc """
  The game, as a pure function.

  `new/2` builds a world from one of his REAL recorded routes, `step/2` advances
  it by a number of milliseconds, and `press/2` turns a key into an effect. No
  process, no ETS, no clock, no randomness that is not seeded — the time comes
  in as a parameter and the luck lives in the struct.

  That is what makes a hunt a table test, and what makes the same seed replay
  the same hunt.

  ## Walking is HELD, not tapped

  The cavebot walks with `Body.hold/1` (`cavebot/worker.ex:968`), which becomes
  `key_down`/`key_up` on the rig. So movement here is continuous while a key is
  down, not one tile per event, and two keys down walk both axes — the diagonal
  is real in the game.

  The sign convention is the cavebot's, not a choice: `cavebot/worker.ex:1025-1030`
  reads `dx > 0` as "right" and `dy > 0` as "down", with `dx` being target minus
  current. So **right raises x and down raises y**. Getting it backwards would
  walk away from every corner, and no unit test of the cavebot would notice.

  ## The remainder is kept, in integers

  At 320ms per tile a 50ms tick is a fraction of a tile. Rounding per tick would
  turn 320ms/tile into 350ms/tile and the error would compound across a whole
  leg, so the leftover is carried in `walk_debt_ms`.

  It carries MILLISECONDS, not a fraction of a tile, and that is not cosmetic:
  accumulating `dt / ms_per_tile` as a float loses tiles outright. Ten ticks of
  30ms at 100ms/tile sum to 2.9999999999999996 and walk two tiles where three
  were owed. Integer milliseconds with `div`/`rem` cannot drift.

  ## Every number carries a label

  `@default_knobs` marks each value `measured` (from his own recordings),
  `inherited` (from Settings/team.json) or `invented` (a guess of mine). A
  simulator tuned by eye teaches what I think, not what the game does — so the
  guesses are named as guesses, here and on the screen.
  """

  alias Pokex.Bots.Cavebot.Route

  @default_knobs %{
    # invented — nobody has ever measured tiles/s in this game. `cavebot_measure_walk`
    # exists in /config for exactly this and has never been run, so every conclusion
    # about ROUTE TIMING drawn from this simulator is worth what this guess is worth.
    ms_per_tile: 320
  }

  @directions %{"right" => {1, 0}, "left" => {-1, 0}, "down" => {0, 1}, "up" => {0, -1}}

  defstruct route: nil,
            stairs: [],
            unsimulated_stairs: [],
            pos: nil,
            held: [],
            walk_debt_ms: 0,
            mobs: [],
            own: nil,
            keys: %{},
            clock: 0,
            rand: nil,
            knobs: %{}

  @type t :: %__MODULE__{}

  @doc """
  A world standing on the route's first waypoint.

  `opts` takes `:seed` (default 42) and `:knobs`, which overrides
  `@default_knobs` key by key.
  """
  @spec new(Route.t(), keyword) :: t
  def new(%Route{} = route, opts \\ []) do
    seed = Keyword.get(opts, :seed, 42)
    knobs = Map.merge(@default_knobs, Keyword.get(opts, :knobs, %{}))
    start = List.first(route.waypoints)

    {stairs, refused} = stairs_of(route)

    %__MODULE__{
      route: route,
      stairs: stairs,
      unsimulated_stairs: refused,
      pos: {start.x, start.y, start.z},
      rand: :rand.seed_s(:exsss, {seed, seed, seed}),
      knobs: knobs
    }
  end

  @doc "Advances the world by `dt_ms`."
  @spec step(t, non_neg_integer) :: t
  def step(world, dt_ms) do
    world
    |> walk(dt_ms)
    |> Map.update!(:clock, &(&1 + dt_ms))
  end

  @doc """
  Turns one key event into an effect.

  The shapes are exactly what `Pokex.Rig.Sim` reports, so the simulated hands
  need no translation layer between them and the world.
  """
  @spec press(t, tuple) :: t
  def press(world, {:key_down, key}) when is_map_key(@directions, key),
    do: %{world | held: Enum.uniq(world.held ++ [key])}

  def press(world, {:key_up, key}), do: %{world | held: world.held -- [key]}

  def press(world, _not_a_direction), do: world

  defp walk(%{held: []} = world, _dt_ms), do: world

  defp walk(world, dt_ms) do
    owed = world.walk_debt_ms + dt_ms
    per_tile = world.knobs.ms_per_tile
    tiles = div(owed, per_tile)

    %{world | pos: advance(world, tiles), walk_debt_ms: rem(owed, per_tile)}
  end

  defp advance(world, tiles) do
    heading = heading(world.held)

    Enum.reduce(1..tiles//1, world.pos, fn _tile, pos ->
      one_tile(pos, heading, world.stairs)
    end)
  end

  defp heading(held) do
    Enum.reduce(held, {0, 0}, fn key, {ax, ay} ->
      {kx, ky} = Map.fetch!(@directions, key)
      {ax + kx, ay + ky}
    end)
  end

  # Landing on the step WITH the stair's own heading spends one key on two tiles
  # and changes floor. Any other heading crosses the same ground normally — the
  # tile is only a staircase from the direction it was recorded from.
  defp one_tile({x, y, z}, {dx, dy}, stairs) do
    next = {x + dx, y + dy, z}

    case Enum.find(stairs, &(&1.at == next and &1.dir == {dx, dy})) do
      nil -> next
      stair -> {x + dx * 2, y + dy * 2, stair.to_z}
    end
  end

  # A staircase is ONE key that walks TWO tiles and changes floor. He marks the
  # corner right before and right after, so the step is the MIDPOINT of the pair
  # — and only a clean pair (±2 on one axis, 0 on the other) still carries it. A
  # dirty pair lost the real position at recording time, and offering a
  # correction for one is exactly what must never happen here.
  #
  # But refusing SILENTLY is its own lie: measured against his real routes,
  # `Meganium and Venoss` and `Meganium 1` are 2/2 clean, `Xatu easy` is 4 of 8,
  # and `Azumaril easy` has ZERO — simulating that one, the character would cross
  # the stair tile and stay on the floor, looking like a bug in the bot. So every
  # refusal is reported, and the screen says which routes cannot fully be walked.
  defp stairs_of(%Route{waypoints: waypoints}) do
    waypoints
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce({[], []}, fn [a, b], {stairs, refused} ->
      case stair_between(a, b) do
        :same_floor -> {stairs, refused}
        {:ok, stair} -> {stairs ++ [stair], refused}
        :dirty -> {stairs, refused ++ [%{from: point(a), to: point(b)}]}
      end
    end)
  end

  defp stair_between(%{z: z}, %{z: z}), do: :same_floor

  defp stair_between(a, b) do
    dx = b.x - a.x
    dy = b.y - a.y

    if {abs(dx), abs(dy)} in [{2, 0}, {0, 2}] do
      {:ok,
       %{at: {a.x + div(dx, 2), a.y + div(dy, 2), a.z}, dir: {sign(dx), sign(dy)}, to_z: b.z}}
    else
      :dirty
    end
  end

  defp point(%{x: x, y: y, z: z}), do: {x, y, z}

  defp sign(0), do: 0
  defp sign(n) when n > 0, do: 1
  defp sign(_negative), do: -1
end
