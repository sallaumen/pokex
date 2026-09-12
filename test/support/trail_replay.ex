defmodule Pokex.TrailReplay do
  @moduledoc """
  Replays a black-box episode through `Pokex.Bots.Catcher.Trail`, one eye look
  at a time, the way `Catcher.Worker.follow/2` and `hunt/2` feed it live.

  The fixture is a jsonl (`test/fixtures/captura/*.jsonl`) cut from an
  episode's `manifest.jsonl`: one line per frame that carried an eye reading —
  `t` (ms since the episode opened), `me`, `pos` (minimap), `hostiles`
  (`[x, y, hp]`), `pet` (`[x, y]` or null), `vistos` (the guard's sparkle
  points, `[x, y, px]`), `listed` (the raw battle list, HIS OWN row included —
  1 means the pile is dead) and `route`. Frames are ~2 s apart (the film), so
  the trail's "three looks" take seconds here, not the 0.75 s of a live fight:
  the replay proves WHAT falls and WHERE, not when to the millisecond.

  No names, no player handles: the fixtures are public.
  """

  alias Pokex.Bots.Catcher.Trail
  alias Pokex.Bots.CrowdScan

  @tile 151
  @rule "Shiny (brilho)"

  @type look :: map
  @type result :: %{
          anchors: [map],
          falls: [%{t: integer, screen: {integer, integer}, world: {float, float}}],
          hunted: map | nil,
          looks: non_neg_integer
        }

  @doc "Every look of the fixture, in order."
  @spec load(Path.t()) :: [look]
  def load(path) do
    path
    |> File.stream!()
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> Enum.map(&Jason.decode!/1)
  end

  @doc "Feeds the whole fixture to a fresh trail and reports what fell."
  @spec run(Path.t()) :: result
  def run(path), do: replay(load(path))

  @doc "Same, over looks already loaded (a test may trim or edit them)."
  @spec replay([look]) :: result
  def replay(looks) do
    {trail, falls} =
      Enum.reduce(looks, {Trail.new(), []}, fn look, {trail, falls} ->
        ref = ref(look)

        seen =
          Enum.map(look["vistos"], fn [x, y, px] -> %{name: @rule, px: px, point: {x, y}} end)

        after_look = look(trail, look, seen, ref)
        {after_look, falls ++ fresh_falls(trail, after_look, ref, look["t"])}
      end)

    last = List.last(looks)
    ref = ref(last)
    at = last["t"]

    %{
      anchors: Trail.anchors(trail, ref, at),
      falls: falls,
      hunted: Trail.hunted(trail, ref),
      looks: length(looks)
    }
  end

  # ONE LOOK, as the worker does it: the eye's reading with the guard's mark
  # (`CrowdScan.mark_special/3`), the two flags the trail reads (`shiny_on?`,
  # `pile_dead?`), then the guard's own blob joins a track (`hunt_at/6`, half a
  # tile under the sparkle point — the body centre the eye reports).
  defp look(trail, look, seen, ref) do
    reading =
      %{
        read?: true,
        me: ref.me,
        hostiles: Enum.map(look["hostiles"], fn [x, y, _hp] -> %{point: {x, y}} end),
        pet: pet(look["pet"])
      }
      |> CrowdScan.mark_special(seen, ref.tile)
      |> Map.merge(%{shiny_on?: seen != [], pile_dead?: (look["listed"] || 99) <= 1})

    trail = Trail.observe(trail, reading, ref, look["t"])
    half = div(ref.tile, 2)

    Enum.reduce(seen, trail, fn %{point: {x, y}, name: name, px: px}, trail ->
      Trail.hunt_at(trail, {x, y + half}, name, px, ref, look["t"])
    end)
  end

  defp fresh_falls(before, after_look, ref, t) do
    known = Enum.map(Trail.anchors(before, ref, t), & &1.world)

    for %{world: world, screen: screen} <- Trail.anchors(after_look, ref, t),
        world not in known,
        do: %{t: t, screen: screen, world: world}
  end

  defp ref(%{"me" => [mx, my]} = look), do: %{me: {mx, my}, tile: @tile, pos: pos(look["pos"])}

  defp pos([x, y, z]), do: {x, y, z}
  defp pos(_unread), do: nil

  defp pet([x, y]), do: %{point: {x, y}}
  defp pet(_none), do: nil
end
