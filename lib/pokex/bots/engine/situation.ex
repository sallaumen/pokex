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

  Whether his pokémon appears in that list at all is, as of this writing, an
  open measurement: `interpret.ex:44` records a live reading saying it does NOT
  appear; he says it is always the first row. `own_row_seen?` is what settles it
  with field data instead of with either of our memories.
  """

  @doc """
  Builds the picture from what was read this tick.

  `inputs` carries `:battle` (the fact's observation, or `nil` when missing or
  stale), `:own_hp`, `:own_out?`, `:own_name` (the pokémon on the field),
  `:ready_keys` (or `nil` when the bar could not be read), `:damage_keys` (this
  pokémon's area + single keys), `:stun_at` (when a control skill last fired
  with a receipt) and `:prev` — the previous picture, which is what makes "is
  the pile still growing?" answerable.

  `config` carries `:engage_from` and `:stun_sleep_ms`.
  """
  @spec build(map, map, integer) :: map
  def build(inputs, config, now) do
    battle = read_battle(Map.get(inputs, :battle), Map.get(inputs, :own_name))
    {growing?, stable_since} = settle(battle.enemies, Map.get(inputs, :prev), now)
    asleep_until = sleep_until(Map.get(inputs, :stun_at), config)

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
      own_out?: Map.get(inputs, :own_out?, false),
      ready_keys: Map.get(inputs, :ready_keys),
      spent?: spent?(Map.get(inputs, :damage_keys, []), Map.get(inputs, :ready_keys)),
      asleep_until: asleep_until,
      asleep?: asleep_until != nil and now < asleep_until,
      blind?: Map.get(inputs, :battle) == nil,
      at: now
    }
  end

  # No reading at all: everything about the screen is unknown. Not zero.
  defp read_battle(nil, _own_name),
    do: %{rows: nil, enemies: nil, named: [], own_row_seen?: nil}

  defp read_battle(battle, own_name) do
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
        %{rows: rows, enemies: length(theirs), named: theirs, own_row_seen?: mine != []}
    end
  end

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

  # R4: the stun is a clock and nothing contradicts it. The receipt proves the
  # key fired; the sleep landing is assumed, deliberately — "mesmo não tendo
  # pego, se estamos com pouca vida e a maior parte da tela stunada, essa é a
  # melhor hora pra usar o revive" (2026-08-17).
  defp sleep_until(nil, _config), do: nil
  defp sleep_until(at, config), do: at + Map.fetch!(config, :stun_sleep_ms)
end
