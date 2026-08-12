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

  # When two kill spots are ONE kill spot. Measured on his own recording
  # (2026-08-11): the runs a single fight's middle clicks leave behind sit 1-5
  # tiles and 1-2 SECONDS apart, while between real piles he walks 10 tiles or
  # more and 15-23 seconds pass — a pile takes that long to die.
  #
  # The clock is the decisive one and the distance is its sanity bound. A route
  # recorded before the recorder read the clock has no `at` at all; there,
  # distance is all there is, so it has to be tight enough to be safe alone.
  @merge_tiles 6
  @merge_seconds 10
  @merge_tiles_blind 3

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
  The skill keys he uses HABITUALLY across these routes: the ones that show up
  at most of his kill spots.

  The editor offers ten keys and his hands use four. Which four cannot be the
  union of everything he ever pressed — his real route pressed `1 3 4 5` at
  five kill spots and `2 6 7 8` at exactly one, the one he told us he fumbled
  ("eu mesmo errei alguns combos ali", 2026-08-11). The union answers "eight of
  your nine keys", which is not an answer.

  So a key counts when it appears at HALF or more of the kill spots that have a
  combo. A slip happens once; a combo happens every time.
  """
  @spec habitual_skills([Route.t()]) :: [String.t()]
  def habitual_skills(routes) when is_list(routes) do
    combos =
      for %Route{waypoints: waypoints} <- routes,
          waypoint <- waypoints,
          intent = combo_intent(Map.get(waypoint, :combo) || []),
          intent != [],
          do: Enum.uniq(intent)

    case length(combos) do
      0 ->
        []

      spots ->
        combos
        |> List.flatten()
        |> Enum.frequencies()
        |> Enum.filter(fn {_key, seen} -> seen * 2 >= spots end)
        |> Enum.map(&elem(&1, 0))
    end
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
    {merged, merges} = merge_kill_spots(route)
    {cleaned, note} = pair_marks(merged)
    {cleaned, merge_note(merges) <> note}
  end

  # A RUN of kill spots within a few tiles of each other is ONE kill spot,
  # recorded several times — the middle clicks of a single fight (see
  # `mark_park/4`). The LAST of the run survives: it is where the pile actually
  # died, and it is the one his recording gave the combo and the huddle to. The
  # others go back to being plain corners, keeping the SHAPE of the walk while
  # giving up their marks — deleting them would move the path.
  defp merge_kill_spots(%Route{waypoints: waypoints} = route) do
    runs = route |> kill_spots() |> group_runs(waypoints)
    demoted = runs |> Enum.flat_map(fn run -> Enum.drop(run, -1) end)

    {Enum.reduce(demoted, route, &demote/2), length(demoted)}
  end

  # Consecutive kill spots close enough to be the same fight, grouped in order.
  defp group_runs(kills, waypoints) do
    kills
    |> Enum.sort()
    |> Enum.chunk_while([], &keep_or_close(&1, &2, waypoints), &close_run/1)
    |> Enum.filter(&(length(&1) > 1))
  end

  defp keep_or_close(index, [], _waypoints), do: {:cont, [index]}

  defp keep_or_close(index, [last | _rest] = run, waypoints) do
    if same_fight?(Enum.at(waypoints, last), Enum.at(waypoints, index)),
      do: {:cont, [index | run]},
      else: {:cont, Enum.reverse(run), [index]}
  end

  defp close_run([]), do: {:cont, []}
  defp close_run(run), do: {:cont, Enum.reverse(run), []}

  # Same fight: near in space AND, when the recording knows, near in time. The
  # reach is a parameter because the recorder may be told another one.
  defp same_fight?(one, other, reach \\ @merge_tiles)

  defp same_fight?(%{at: %DateTime{} = a} = one, %{at: %DateTime{} = b} = other, reach),
    do: tiles_between(one, other) <= reach and abs(DateTime.diff(a, b)) <= @merge_seconds

  defp same_fight?(one, other, _no_clock),
    do: tiles_between(one, other) <= @merge_tiles_blind

  # A demoted kill spot keeps its place in the walk and loses everything that
  # made it a spot: the job, the stops, and the park point of a click that was
  # only moving the pokémon mid-fight.
  defp demote(index, route) do
    route
    |> Route.set_action(index, :walk)
    |> Route.set_park_point(index, nil)
    |> Route.set_park_tiles(index, nil)
    |> then(fn r -> Enum.reduce(Route.stops(), r, &Route.set_stop(&2, index, &1, false)) end)
  end

  defp merge_note(0), do: ""

  defp merge_note(count),
    do: "juntei #{count} marca(s) de uma matança só (cliques do meio da mesma luta); "

  defp pair_marks(%Route{} = route) do
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
    cond do
      Enum.at(route.waypoints, index) == nil ->
        {route, nil}

      # ONE fight, several clicks. He middle-clicks three, five, eight times
      # while a pile dies — moving the pokémon around — and each click used to
      # open a kill spot of its OWN: his 2026-08-11 recording came back with
      # eight "até aqui" in ten seconds, one per tile, each with its own park
      # point and its own sweep. A click next door to a kill spot belongs to
      # that kill spot: it moves where the pokémon waits and marks nothing new.
      spot = same_fight_spot(route, index, opts) ->
        {Route.set_park_point(route, spot, point), moved_note(point, spot)}

      true ->
        {route, _note} = mark_kill_spot(route, index, nil, Keyword.get(opts, :hand_marked, []))
        {Route.set_park_point(route, index, point), park_note(point)}
    end
  end

  @doc """
  Marks the kill spot his own hand announced: shift+1 is the game's attack
  mode, and pressing it means "saio do modo mobado, vou matar" — so the fight
  starts HERE, and this is a stop on the route ("toda luta é uma parada na
  rota", Lucas, 2026-08-11).

  The same marker as the middle click, with the same guard: a fight already
  marked next door is not marked twice — shift+1 pressed again mid-pile, or
  pressed right after the click that parked the pokémon, is the same fight.
  A quiet `nil` note is the answer then, because nothing happened.
  """
  @spec mark_fight_start(Route.t(), non_neg_integer, keyword) ::
          {Route.t(), String.t() | nil}
  def mark_fight_start(%Route{} = route, index, opts \\ []) do
    cond do
      Enum.at(route.waypoints, index) == nil ->
        {route, nil}

      same_fight_spot(route, index, opts) ->
        {route, nil}

      true ->
        {marked, _note} =
          mark_kill_spot(route, index, nil, Keyword.get(opts, :hand_marked, []))

        {marked, "⚔️ shift+1: aqui é matança — marquei \"até aqui\" + varrer"}
    end
  end

  @doc """
  Marks where the gathering STARTS AGAIN — his shift+3, the game's defence mode
  ("o shift+3 é o modo mobando", Lucas, 2026-08-11).

  Two silences, both deliberate. Pressed ON the spot he just closed — which is
  where he presses it most of the time, right after the pile dies — it says
  nothing new: the gathering resumes on the NEXT corner, which is exactly what
  `mark_kill_spot/4` already infers, and marking here would erase the "até
  aqui" he just made. Pressed on a corner that already says "mobar daqui", it
  says nothing twice.

  Anywhere else it is information nothing else has: the corners between the
  kill spot and this one are where he kept FIGHTING, and only his hand knows
  where that ended.
  """
  @spec mark_gathering_start(Route.t(), non_neg_integer, keyword) ::
          {Route.t(), String.t() | nil}
  def mark_gathering_start(%Route{} = route, index, _opts \\ []) do
    case Enum.at(route.waypoints, index) do
      %{action: :walk} ->
        {Route.set_action(route, index, :lure_start), "🛡️ shift+3: daqui pra frente é mobada"}

      _closed_spot_or_already_said ->
        {route, nil}
    end
  end

  # The LAST kill spot close enough to be the same fight. Distance, not
  # adjacency: between two real piles he walks ten tiles or more (measured on
  # his own route), and inside one fight he moves one or two.
  defp same_fight_spot(%Route{waypoints: waypoints} = route, index, opts) do
    reach = Keyword.get(opts, :merge_tiles, @merge_tiles)
    here = Enum.at(waypoints, index)

    route
    |> kill_spots()
    |> Enum.reject(&(&1 == index))
    |> Enum.filter(&same_fight?(Enum.at(waypoints, &1), here, reach))
    |> Enum.max(fn -> nil end)
  end

  defp tiles_between(%{x: ax, y: ay, z: az}, %{x: bx, y: by, z: bz}) do
    if az == bz, do: abs(ax - bx) + abs(ay - by), else: 1_000
  end

  defp park_note({x, y}),
    do: "🖱️ clique do meio em #{x}, #{y} — marquei \"até aqui\" + varrer e guardei o ponto"

  defp moved_note({x, y}, spot),
    do: "🖱️ #{x}, #{y} — mesma matança do waypoint #{spot + 1}; só mudei onde o pokémon fica"

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

    cond do
      start >= index -> nil
      start in hand_marked -> nil
      # he already said where it starts (his shift+3) — inventing a second
      # "mobar daqui" earlier would swallow the corners he meant to fight on
      gathering_between?(route, start, index) -> nil
      true -> start
    end
  end

  defp gathering_between?(route, from, to) do
    route.waypoints
    |> Enum.slice(from..(to - 1)//1)
    |> Enum.any?(&(&1.action == :lure_start))
  end

  defp note(nil, _start), do: nil

  defp note(dwell, start) do
    seconds = round(dwell / 1000)
    base = "#{seconds}s parado — marquei \"até aqui\" + varrer"

    if start, do: base <> " (e \"mobar daqui\" no waypoint #{start + 1})", else: base
  end
end
