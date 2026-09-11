defmodule Pokex.Bots.Catcher.Trail do
  @moduledoc """
  The shiny's identity, travelling with its health bar until it falls.

  "Cor nenhuma resolve isso" (11/09): the guard sees the shiny ALIVE by its
  colour, but the corpse is different art — the Shiny Golem's live shell is a
  purplish dark (47,43,46), the dead one a neutral grey — and the cave's light
  changes both again. Measured on his frames of 09:13: the corpse was on
  screen with ZERO pixels of the taught tone. So the corpse cannot be found by
  what the live creature looked like. It CAN be found by where the live
  creature was when its bar disappeared.

  The eye (`CrowdWatch`) already reads every creature's bar a few times a
  second, as SCREEN points. This module keeps those readings as TRACKS in
  WORLD tiles — the minimap's position plus the screen offset over the tile —
  so a track survives the character walking, and follows each creature from
  look to look by nearest neighbour with a small velocity guess. The guard's
  blob (`CrowdScan.mark_special/3`) names ONE of those tracks the hunted one;
  when the hunted bar is gone for a couple of looks, its last place is the
  ANCHOR: the tile the corpse is lying on, colour or no colour, item light or
  not. His own pokémon standing on the hunted creature (it covered the Golem
  one look after the sighting, 09:12:55) is an occlusion, not a death: the
  track coasts while the pet is on it.

  Pure: the worker feeds it readings and asks for the anchor in today's screen.
  """

  # A creature walks about a tile a second and the eye looks 4× a second in a
  # fight, 1× walking: a tile and a half also absorbs the minimap's whole-tile
  # jitter between two readings taken from the same place.
  @gate_tiles 1.5
  # looks without a bar before an ordinary track is forgotten
  @lost_after 4
  # …and before a HUNTED bar gone is a corpse: two looks (half a second in a
  # fight) is a bar hidden by an animation frame, not a death — three is a death
  @fall_after 3
  # the pet on top of the hunted track: it is covered, not dead — but not forever
  @occluded_max 12
  # how long a corpse is worth a ball (the item light lasts ~34 s; a corpse minutes)
  @anchor_ttl_ms 120_000

  defstruct tracks: %{}, next_id: 1, anchors: [], pos: nil

  @type point :: {integer, integer}
  @type world :: {float, float}
  @type ref :: %{me: point, tile: pos_integer, pos: {integer, integer, integer} | nil}
  @type track :: %{
          id: pos_integer,
          world: world,
          prev: world | nil,
          screen: point,
          seen_at: integer,
          misses: non_neg_integer,
          occluded: non_neg_integer,
          hunted?: boolean,
          name: String.t() | nil,
          px: non_neg_integer | nil
        }
  @type anchor :: %{world: world, name: String.t(), px: non_neg_integer | nil, fallen_at: integer}
  @type t :: %__MODULE__{
          tracks: %{pos_integer => track},
          next_id: pos_integer,
          anchors: [anchor],
          pos: {integer, integer, integer} | nil
        }

  @spec new() :: t
  def new, do: %__MODULE__{}

  @doc """
  One look of the eye. Hostiles carrying `special?: true` (the guard's blob on
  their body, `CrowdScan.mark_special/3`) become — or stay — the hunted track.
  An unread look changes nothing: blindness is not absence.
  """
  @spec observe(t, map, ref, integer) :: t
  def observe(trail, %{read?: true, hostiles: hostiles} = reading, ref, now) do
    ref = frame(trail, ref)
    trail = %{trail | pos: ref.pos}
    seen = Enum.map(hostiles, &Map.put(&1, :world, to_world(&1.point, ref)))
    pet = pet_world(reading, ref)

    {tracks, left} =
      trail.tracks
      |> Map.values()
      |> Enum.sort_by(&{not &1.hunted?, -&1.seen_at})
      |> Enum.reduce({[], seen}, fn track, {done, left} ->
        case nearest(left, predict(track)) do
          {hostile, rest} -> {[hit(track, hostile, now) | done], rest}
          nil -> {[miss(track, pet)], left}
        end
      end)

    born =
      left
      |> Enum.with_index(trail.next_id)
      |> Enum.map(fn {hostile, id} -> birth(hostile, id, now) end)

    {fallen, alive} = Enum.split_with(tracks, &fallen?/1)
    kept = Enum.reject(alive, &lost?/1)

    %{
      trail
      | tracks: Map.new(kept ++ born, &{&1.id, &1}),
        next_id: trail.next_id + length(born),
        anchors: Enum.map(fallen, &fall(&1, now)) ++ trail.anchors
    }
  end

  def observe(trail, _unread, _ref, _now), do: trail

  @doc """
  The guard's blob when the eye's reading did not carry the mark: the track
  whose body the blob sits on becomes the hunted one; with no body there yet, a
  hunted track is born on the blob (the bar can come one look later).
  """
  @spec hunt_at(t, point, String.t(), non_neg_integer | nil, ref, integer) :: t
  def hunt_at(trail, {_, _} = point, name, px, ref, now) do
    ref = frame(trail, ref)
    world = to_world(point, ref)

    case nearest(Map.values(trail.tracks), world) do
      {track, _rest} ->
        put_track(trail, %{track | hunted?: true, name: name, px: px})

      nil ->
        track = birth(%{point: point, world: world}, trail.next_id, now)

        put_track(%{trail | next_id: trail.next_id + 1}, %{
          track
          | hunted?: true,
            name: name,
            px: px
        })
    end
  end

  @doc "The hunted creature still standing, with today's screen point — or nil."
  @spec hunted(t, ref) :: %{screen: point, world: world, name: String.t() | nil} | nil
  def hunted(trail, ref) do
    case Enum.find(Map.values(trail.tracks), & &1.hunted?) do
      nil ->
        nil

      track ->
        %{screen: to_screen(track.world, frame(trail, ref)), world: track.world, name: track.name}
    end
  end

  @doc """
  Where the hunted creature fell, in today's screen — the corpse's tile. Fresh
  ones first; `nil` past the TTL or when nothing hunted ever fell.
  """
  @spec anchors(t, ref, integer) :: [
          %{
            screen: point,
            world: world,
            name: String.t(),
            px: non_neg_integer | nil,
            fallen_at: integer
          }
        ]
  def anchors(trail, ref, now) do
    ref = frame(trail, ref)

    for anchor <- trail.anchors, now - anchor.fallen_at <= @anchor_ttl_ms do
      Map.put(anchor, :screen, to_screen(anchor.world, ref))
    end
  end

  @doc "Every creature still standing, in today's screen — a ball never flies onto one."
  @spec standing(t, ref) :: [point]
  def standing(trail, ref) do
    ref = frame(trail, ref)
    for track <- Map.values(trail.tracks), track.misses == 0, do: to_screen(track.world, ref)
  end

  @doc "The ball flew at this anchor: it is spent."
  @spec spend(t, world) :: t
  def spend(trail, world),
    do: %{trail | anchors: Enum.reject(trail.anchors, &(&1.world == world))}

  @doc "The round is over and nothing is owed: forget every anchor."
  @spec clear_anchors(t) :: t
  def clear_anchors(trail), do: %{trail | anchors: []}

  # --- the frame ---------------------------------------------------------------

  # The minimap may be unreadable for a look; the last position it gave is the
  # best guess (the character rarely moves between two looks a quarter second
  # apart), and with none ever read the world is the screen over the tile.
  defp frame(trail, %{pos: nil} = ref), do: %{ref | pos: trail.pos || {0, 0, 0}}
  defp frame(_trail, ref), do: ref

  defp to_world({sx, sy}, %{me: {mx, my}, tile: tile, pos: {px, py, _z}}),
    do: {px + (sx - mx) / tile, py + (sy - my) / tile}

  defp to_screen({wx, wy}, %{me: {mx, my}, tile: tile, pos: {px, py, _z}}),
    do: {mx + round((wx - px) * tile), my + round((wy - py) * tile)}

  defp pet_world(%{pet: %{point: point}}, ref), do: to_world(point, ref)
  defp pet_world(_no_pet, _ref), do: nil

  # --- following ------------------------------------------------------------------

  # Where the creature should be now if it kept walking as it did: the guess
  # that keeps two creatures crossing paths from swapping identities.
  defp predict(%{world: {x, y}, prev: {px, py}, misses: 0}),
    do: {x + (x - px) / 2, y + (y - py) / 2}

  defp predict(%{world: world}), do: world

  defp nearest(hostiles, {gx, gy}) do
    hostiles
    |> Enum.map(&{distance(&1.world, {gx, gy}), &1})
    |> Enum.filter(fn {d, _h} -> d <= @gate_tiles end)
    |> Enum.min_by(fn {d, _h} -> d end, fn -> nil end)
    |> case do
      nil -> nil
      {_d, hostile} -> {hostile, List.delete(hostiles, hostile)}
    end
  end

  defp distance({ax, ay}, {bx, by}), do: max(abs(ax - bx), abs(ay - by))

  defp hit(track, hostile, now) do
    %{
      track
      | prev: track.world,
        world: hostile.world,
        screen: hostile.point,
        seen_at: now,
        misses: 0,
        occluded: 0,
        hunted?: track.hunted? or Map.get(hostile, :special?, false),
        name: Map.get(hostile, :special_name) || track.name,
        px: Map.get(hostile, :special_px) || track.px
    }
  end

  # The pet standing on a hunted creature hides its bar: covered, not gone.
  defp miss(%{hunted?: true} = track, pet) when pet != nil do
    if distance(track.world, pet) <= 1.0 and track.occluded < @occluded_max,
      do: %{track | occluded: track.occluded + 1},
      else: %{track | misses: track.misses + 1}
  end

  defp miss(track, _pet), do: %{track | misses: track.misses + 1}

  defp birth(hostile, id, now) do
    %{
      id: id,
      world: hostile.world,
      prev: nil,
      screen: hostile.point,
      seen_at: now,
      misses: 0,
      occluded: 0,
      hunted?: Map.get(hostile, :special?, false),
      name: Map.get(hostile, :special_name),
      px: Map.get(hostile, :special_px)
    }
  end

  defp fallen?(%{hunted?: true, misses: misses}), do: misses >= @fall_after
  defp fallen?(_track), do: false

  defp lost?(%{hunted?: true}), do: false
  defp lost?(%{misses: misses}), do: misses >= @lost_after

  defp fall(track, now),
    do: %{world: track.world, name: track.name || "shiny", px: track.px, fallen_at: now}

  defp put_track(trail, track), do: %{trail | tracks: Map.put(trail.tracks, track.id, track)}
end
