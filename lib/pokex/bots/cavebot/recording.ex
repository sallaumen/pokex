defmodule Pokex.Bots.Cavebot.Recording do
  @moduledoc """
  Reading what he was DOING from how long he stood still.

  A recorded route used to be a list of PLACES, and marking what happened at
  each one was work he had to redo by hand afterwards — "hoje está bem difícil
  de gravar" (Lucas, 2026-08-11). But the clock already knows: a corner marked
  in passing is a corner he walked through, and a spot he stood on for half a
  minute is a spot where he killed a pile and picked it up.

  So the recorder reads the dwell:

    * a long stop is a KILL SPOT — `:lure_end` (the gathering ended here, this
      is where everything dies) plus the `:sweep` stop (the corpses are on
      this tile);
    * the stretch BETWEEN two kill spots is the GATHERING — `:lure_start` on
      the first waypoint after the previous kill spot. His loop is exactly
      that: kill, walk gathering the next pile, kill again. Nothing is
      guessed; the route already says it.

  Everything here is a starting point, not a verdict: every mark is editable
  on the page afterwards, and a waypoint he marked by hand is never touched.
  """

  alias Pokex.Bots.Cavebot.Route

  @doc """
  Marks the waypoint at `index` from its dwell, and the gathering that led to
  it. Returns the route unchanged when the stop was short.
  """
  @spec infer(Route.t(), non_neg_integer, pos_integer, keyword) :: Route.t()
  def infer(route, index, fight_ms, opts \\ []) do
    {route, _note} = infer_with_note(route, index, fight_ms, opts)
    route
  end

  @doc """
  Same, plus a line saying what it decided — `nil` when it decided nothing.

  A recorder that marks things silently is a recorder he cannot trust: the
  note is what makes the inference reviewable while it is still fresh.
  """
  @spec infer_with_note(Route.t(), non_neg_integer, pos_integer, keyword) ::
          {Route.t(), String.t() | nil}
  def infer_with_note(%Route{} = route, index, fight_ms, opts \\ []) do
    hand_marked = Keyword.get(opts, :hand_marked, [])

    with false <- index in hand_marked,
         %{dwell_ms: dwell} when is_integer(dwell) and dwell >= fight_ms <-
           Enum.at(route.waypoints, index) do
      mark_kill_spot(route, index, dwell, hand_marked)
    else
      _short_or_hand_marked -> {route, nil}
    end
  end

  @doc """
  Marks a kill spot he pointed out HIMSELF — the middle click that parks his
  pokémon, which is the marker he asked for over the clock: "é uma marca muito
  mais fácil de eu te passar" (2026-08-11), and unlike standing still it is
  never invisible to the reader.
  """
  @spec mark_park(Route.t(), non_neg_integer, {integer, integer}, keyword) ::
          {Route.t(), String.t() | nil}
  def mark_park(%Route{} = route, index, point, opts \\ []) do
    if Enum.at(route.waypoints, index) do
      {route, _note} = mark_kill_spot(route, index, nil, Keyword.get(opts, :hand_marked, []))
      {Route.set_park_point(route, index, point), park_note(point)}
    else
      {route, nil}
    end
  end

  defp park_note({x, y}),
    do: "🖱️ clique do meio em #{x}, #{y} — marquei \"até aqui\" + varrer e guardei o ponto"

  defp mark_kill_spot(route, index, dwell, hand_marked) do
    route =
      route
      |> Route.set_action(index, :lure_end)
      |> Route.set_stop(index, :sweep, true)

    case gathering_start(route, index, hand_marked) do
      nil ->
        {route, note(dwell, nil)}

      start ->
        {Route.set_action(route, start, :lure_start), note(dwell, start)}
    end
  end

  # The first waypoint AFTER the previous kill spot — that is where he started
  # gathering this pile. `nil` when there is nothing in between: two piles on
  # the same corner are two kill spots, not a walk, and a zero-length stretch
  # would put "mobar daqui" on the kill spot itself.
  defp gathering_start(route, index, hand_marked) do
    previous =
      route.waypoints
      |> Enum.take(index)
      |> Enum.with_index()
      |> Enum.filter(fn {wp, _i} -> wp.action == :lure_end end)
      |> List.last()

    start = if previous, do: elem(previous, 1) + 1, else: 0

    if start < index and start not in hand_marked, do: start, else: nil
  end

  defp note(nil, _start), do: nil

  defp note(dwell, start) do
    seconds = round(dwell / 1000)
    base = "#{seconds}s parado — marquei \"até aqui\" + varrer"

    if start, do: base <> " (e \"mobar daqui\" no waypoint #{start + 1})", else: base
  end
end
