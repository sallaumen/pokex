defmodule Pokex.Bots.Engine.Situation do
  @moduledoc """
  The shared tactical picture: what is TRUE right now, before anybody decides
  anything.

  Three processes have been answering "how many monsters are there?" separately
  — and the one that revives the pokémon never asked at all. `PlayerSupport`
  decides on a health bar and nothing else, which is why a revive fires at 60%
  in the middle of a live pile, with every cooldown still up, throwing away both
  halves of what a revive is worth (Lucas, 2026-08-17: "quem manda ser tomada
  uma poção ou reviver um pokémon não deveria ser só um observador da vida,
  puramente, porque não é puro assim").

  So the reading moves here, once, and everyone reads the same picture.

  Pure on purpose: it takes observations already pulled off the blackboard and a
  monotonic `now`, and returns a map. No ETS, no clock, no captures — the whole
  thing is a table test.

  ## `own_out?` has three answers, not two

  `true` is "the bar reads, so the pokemon is on the field". `false` is a
  PROVEN absence — the support saw a live bar fall below the faint line and then
  vanish for two straight reads. `:unknown` is everything else: a minimised
  party window, a stale fact, a frame the reader did not recognise.

  Two answers were enough while nobody acted on the absence. They stopped being
  enough the moment `Logic` gained a rule that refuses to fight without a body
  on the field: with `false` also meaning "I could not read it", one bad frame
  would have stopped the hunt.

  ## `nil` is a legal answer

  An empty screen and an unreadable screen are the same pixels to a counter and
  opposite facts to a decision. Zero means "nothing is there"; `nil` means "I
  cannot see". Whoever consumes this decides what to do with not knowing — that
  choice belongs to the consumer's fail-open rule, never to the picture.

  ## The own row

  `enemies` deliberately excludes his own pokémon, "lembrando de não contar o
  próprio" (2026-08-17). It is excluded BY NAME, not by position: the panel's
  order is the game's business, and a rule that trusts "row 0 is mine" breaks
  the day it isn't.

  The name comes from `enemies_detail`, which only exists once the layout has
  been located (`interpret.ex:120`). Without it the count stays RAW and
  `own_row_seen?` is `nil` — because a guessed subtraction here is exactly the
  difference between attacking a pile and walking away from it.

  ## The measurement is closed, and he was right

  Whether his pokémon takes a row was an open question — `interpret.ex:44` had a
  reading saying it does not appear; he said it is always the first row. His
  hunt of 2026-08-18 settled it: row 0 was his pokémon in **134 of 140**
  readings, and `own_row_seen?` came back `false` in **all 134** filed
  decisions. It appears, and the by-name discount never fired.

  The reason is the trap: his Vespiquen's name reads as `nil` (the glyphs for it
  were never taught), and a name that cannot be read can never match. So every
  count that night was inflated by exactly one — which opened the area on 12
  piles of two, and walked away from 6 monsters that were still alive.

  So the name is no longer the only way to find his row. When his pokémon is on
  the field and NO row matched by name, the first unreadable row is his. That is
  narrower than subtracting one in the dark: it keeps the named list and the
  count consistent, it does nothing when every row is legible, and it does
  nothing when his pokémon is not out. `own_row_seen?` answers `:unnamed` there,
  so the screen can say which of the two ways found it — a discount made on a
  guess must never look like one made on a name.
  """

  @doc """
  Builds the picture from what was read this tick.

  `inputs` carries `:battle` (the fact's observation, or `nil` when missing or
  stale), `:own_hp`, `:own_out?` (`true | false | :unknown`), `:own_name`,
  `:ready_keys` (or `nil` when the bar could not be read), `:damage_keys` (this
  pokémon's area + single keys), and `:prev` — the previous picture, which is
  what makes "is the pile still growing?" answerable.

  `config` carries `:engage_from`.
  """
  @spec build(map, map, integer) :: map
  def build(inputs, config, now) do
    battle =
      read_battle(
        Map.get(inputs, :battle),
        Map.get(inputs, :own_name),
        Map.get(inputs, :own_out?, :unknown)
      )

    {growing?, stable_since} = settle(battle.enemies, Map.get(inputs, :prev), now)

    %{
      rows: battle.rows,
      enemies: battle.enemies,
      named: battle.named,
      own_row_seen?: battle.own_row_seen?,
      worth_fighting?: worth_fighting?(battle.enemies, config),
      growing?: growing?,
      stable_since: stable_since,
      stable_for_ms: now - stable_since,
      own_hp: Map.get(inputs, :own_hp),
      own_out?: Map.get(inputs, :own_out?, :unknown),
      ready_keys: Map.get(inputs, :ready_keys),
      spent?: spent?(Map.get(inputs, :damage_keys, []), Map.get(inputs, :ready_keys)),
      blind?: Map.get(inputs, :battle) == nil,
      at: now
    }
  end

  # No reading at all: everything about the screen is unknown. Not zero.
  defp read_battle(nil, _own_name, _own_out?),
    do: %{rows: nil, enemies: nil, named: [], own_row_seen?: nil}

  defp read_battle(battle, own_name, own_out?) do
    rows = length(Map.get(battle, :enemies, []))
    detail = Map.get(battle, :enemies_detail, [])

    cond do
      rows == 0 ->
        %{rows: 0, enemies: 0, named: [], own_row_seen?: false}

      detail == [] ->
        # The layout is not located, so no row has a name and the own row cannot
        # be told from an enemy. Raw count, unknown stated.
        %{rows: rows, enemies: rows, named: [], own_row_seen?: nil}

      true ->
        {mine, theirs} = Enum.split_with(detail, &mine?(&1, own_name))
        by_name_or_by_absence(rows, mine, theirs, own_out?)
    end
  end

  # Found by name: the precise way, and the only one that works when his pokémon
  # is not the first row.
  defp by_name_or_by_absence(rows, mine, theirs, _own_out?) when mine != [],
    do: %{rows: rows, enemies: length(theirs), named: theirs, own_row_seen?: true}

  # Nothing matched by name, but his pokémon IS on the field — so one of these
  # rows is his and the reader could not spell it. The first unreadable one is
  # the candidate, and if every row is legible nothing is taken away: a legible
  # list that does not contain him means he really is not in it.
  defp by_name_or_by_absence(rows, _none, theirs, true) do
    case Enum.split_with(theirs, &(&1.name == nil)) do
      {[], _all_legible} ->
        %{rows: rows, enemies: rows, named: theirs, own_row_seen?: false}

      {[_first_unreadable | rest_unreadable], legible} ->
        others = legible ++ rest_unreadable
        %{rows: rows, enemies: length(others), named: others, own_row_seen?: :unnamed}
    end
  end

  # He is not on the field, so no row is his — an unreadable row here is a
  # monster whose name the glyphs do not know yet, and taking it off the count
  # would be walking away from something real.
  defp by_name_or_by_absence(rows, _none, theirs, _not_out),
    do: %{rows: rows, enemies: rows, named: theirs, own_row_seen?: false}

  defp mine?(_row, nil), do: false

  defp mine?(%{name: name}, own_name) when is_binary(name) and is_binary(own_name),
    do: bare(name) == bare(own_name)

  defp mine?(_row, _own_name), do: false

  # `team.json` says "Shiny Vileplume"; the panel reads "Vileplume" (his capture
  # of 2026-08-11). The prefix is a property of the creature, not of the row, and
  # it must never make the bot count itself among its enemies.
  defp bare(name) do
    name
    |> String.trim()
    |> String.downcase()
    |> String.replace_prefix("shiny ", "")
  end

  # "Pararam de chegar" is the signal a gathering ends on, so only GROWTH
  # restarts the clock. A pile that is dying shrinks the list, and that is the
  # opposite of one still walking in.
  defp settle(nil, _prev, now), do: {false, now}

  defp settle(enemies, %{enemies: was, stable_since: since}, now)
       when is_integer(was) and is_integer(since) do
    if enemies > was, do: {true, now}, else: {false, since}
  end

  defp settle(_enemies, _no_history, now), do: {false, now}

  # R1, his ruler: "se tem 1 ou 2 monstros, eu às vezes até ignoro aquele mob e
  # sigo a minha vida (…) eu realmente mato quando tem uns três". Not knowing is
  # not worth fighting either — that call belongs to the consumer.
  defp worth_fighting?(enemies, config) when is_integer(enemies),
    do: enemies >= Map.fetch!(config, :engage_from)

  defp worth_fighting?(_unknown, _config), do: false

  # The revive is worth most when the cooldowns are already gone (R3), so the
  # picture has to be able to say that they are. Half or fewer of this pokémon's
  # damage keys ready counts as spent; no bar reading, or no classified keys, is
  # an unknown rather than a false.
  defp spent?([], _ready), do: nil
  defp spent?(_damage, nil), do: nil

  defp spent?(damage, ready) do
    Enum.count(damage, &(&1 in ready)) <= div(length(damage), 2)
  end
end
