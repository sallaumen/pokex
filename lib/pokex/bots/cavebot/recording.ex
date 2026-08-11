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
  What he MEANT to press, out of what he actually pressed.

  A recorded combo looks like `1,1,3,3,3,4,4,4,4,4,5,5,5`: he holds the key
  down on a cooldown until it goes off, so the same skill appears many times
  in a row. The INTENTION is `1,3,4,5` — consecutive repeats collapse, but a
  key pressed again LATER (after other skills) stays, because coming back to
  a skill is a real decision.
  """
  @spec combo_intent([String.t()]) :: [String.t()]
  def combo_intent(combo) when is_list(combo) do
    combo
    |> Enum.chunk_by(& &1)
    |> Enum.map(&hd/1)
  end

  @doc """
  Cleans a route's marks up: every kill spot keeps its own, and each one gets
  exactly ONE gathering leading into it.

  His first real mob route came back with two "até aqui" in a row and a
  warning nobody could act on ("eu mesmo errei alguns combos ali",
  2026-08-11) — a middle click he made twice, or one made where no stretch
  had been walked. The marks are his; what is wrong is only their pairing.
  """
  @spec tidy(Route.t()) :: {Route.t(), String.t()}
  def tidy(%Route{} = route) do
    kills = kill_spots(route)

    cleaned =
      route.waypoints
      |> Enum.with_index()
      |> Enum.reduce(route, fn {_wp, index}, acc ->
        Route.set_action(acc, index, tidy_action(index, kills))
      end)

    {cleaned, tidy_note(route, cleaned)}
  end

  defp kill_spots(%Route{waypoints: waypoints}) do
    for {wp, index} <- Enum.with_index(waypoints),
        wp.action == :lure_end or :sweep in wp.stops or wp.park_point != nil,
        do: index
  end

  # A gathering starts on the waypoint AFTER a kill spot — and only when the
  # next kill spot is further along, because two in a row have no walk between
  # them to gather on.
  defp tidy_action(index, kills) do
    cond do
      index in kills -> :lure_end
      starts_gathering?(index, kills) -> :lure_start
      true -> :walk
    end
  end

  defp starts_gathering?(index, kills) do
    previous_end = index == 0 or (index - 1) in kills
    next_kill = Enum.find(kills, &(&1 > index))

    previous_end and next_kill != nil
  end

  defp tidy_note(before, after_route) do
    changed =
      Enum.count(Enum.zip(before.waypoints, after_route.waypoints), fn {a, b} ->
        a.action != b.action
      end)

    case {changed, Route.lure_issue(after_route)} do
      {0, _issue} -> "as marcas já estavam certas"
      {n, nil} -> "arrumei #{n} marca(s): cada matança com uma mobada só"
      {n, _issue} -> "arrumei #{n} marca(s), mas ainda sobrou marca sem par"
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
