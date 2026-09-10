defmodule Pokex.Bots.Engine.BattleRows do
  @moduledoc """
  WHICH ROW IS HIS, and which rows are the enemy — the battle list split in two.

  ## Why this is a module and not three private functions

  "A lista não deveria ser só uma lista, e sim uma lista de inimigos e uma lista
  de Pokémon próprios" (10/09). Until now `Situation` SUBTRACTED his row from a
  count instead of SEPARATING it: everything downstream got a bare `enemies`
  number, and nobody could ask which row was his or how sure the answer was.
  A number that is an arithmetic can be wrong by one in silence; a number that
  is `length(theirs)` cannot be wrong without the list being wrong too.

  So the split happens once, here, and `enemies` becomes a derivation of it.

  ## Three ways to know, in order of trust

  1. `:by_name` — the row's name IS his pokémon's. Precise, and the only one
     that survives the list changing order.
  2. `:by_hp` — no legible name, but the Pokebar and the row's own track are two
     independent readings of the same health, and the closest one is his.
  3. `:by_position` — nothing to go on but "row 0, in 134 of 140 readings"
     (his measurement of 2026-08-18). A GUESS, named as one.

  Measured in his own journal, 2026-09-09 and 2026-09-10: `:by_name` fired ZERO
  times in two nights, `:by_hp` 49%, `:by_position` 33%. The name path is
  written, tested and dead in the field — his pokémon's row name comes back
  `nil` from the glyph reader — which is exactly why the caller has to be told
  WHICH way answered, and why the answer is filed in the diary.
  """

  @typedoc "A battle row as the perception hands it over."
  @type row :: %{optional(:name) => String.t() | nil, optional(:hp_pct) => number | nil}

  @typedoc """
  How his row was found. `false` = he is not in the list at all; `nil` = the
  rows carry no description, so the question cannot be asked.
  """
  @type how :: :by_name | :by_hp | :by_position | false | nil

  @type split :: %{mine: [row], theirs: [row], how: how}

  # Wide because the two readings are two different CAPTURES: the battle feed
  # and the party bar are read on their own clocks, and a pokémon losing health
  # fast is a different number in each.
  @hp_slack 8

  @doc """
  Splits `rows` into what is his and what is the enemy.

  `own_out?` is the veto: `false` means the support PROVED he is off the field,
  and then NO row is his — not even one wearing his species' name.
  """
  @spec split([row], %{name: String.t() | nil, hp: integer | nil, out?: boolean | :unknown}) ::
          split
  def split([], _own), do: %{mine: [], theirs: [], how: false}

  def split(rows, %{out?: false}), do: %{mine: [], theirs: rows, how: false}

  def split(rows, own) do
    case Enum.split_with(rows, &named?(&1, own.name)) do
      {[], _none_by_name} -> by_absence(rows, own)
      {namesakes, others} -> pick(namesakes, others, own, :by_name)
    end
  end

  @doc "How many of them there are — a derivation, never an arithmetic."
  @spec enemies(split) :: non_neg_integer
  def enemies(%{theirs: theirs}), do: length(theirs)

  # …E SÓ COM ELE PROVADAMENTE EM CAMPO. `out?` é `true | false | :unknown`, e
  # descontar uma linha no `:unknown` seria tirar da conta um inimigo real por
  # causa de uma leitura que não aconteceu. `false` já foi vetado lá em cima;
  # aqui o que sobra é a diferença entre "sei que ele está" e "não sei".
  defp by_absence(rows, %{out?: out}) when out != true,
    do: %{mine: [], theirs: rows, how: false}

  # NOTHING MATCHED BY NAME, and he IS on the field — so one of these rows is
  # his and the reader could not spell it. Only the ILLEGIBLE rows are
  # candidates: a legible list that does not contain him means he really is not
  # in it.
  defp by_absence(rows, own) do
    case Enum.split_with(rows, &(Map.get(&1, :name) == nil)) do
      {[], _all_legible} -> %{mine: [], theirs: rows, how: false}
      {unreadable, legible} -> pick(unreadable, legible, own, :by_hp)
    end
  end

  # ONE of the candidates is his, never all of them. Hunting the species he has
  # on the field made the whole pile read as his own row once (five Vileplumes
  # on screen, `enemies` 0, the brain answering "seguindo a rota" to a pile that
  # was eating him) — so the ones not picked go back to the enemy list.
  defp pick([_ | _] = candidates, others, own, how) do
    case closest(candidates, own.hp) do
      nil ->
        [first | rest] = candidates
        %{mine: [first], theirs: others ++ rest, how: fell_back(how)}

      row ->
        %{mine: [row], theirs: others ++ List.delete(candidates, row), how: by_hp_or(how)}
    end
  end

  # THE CLOSEST, not "the only one within the slack". The old rule refused to
  # decide whenever several rows were near his health — which is every fresh
  # pile, because a pile that just arrived is at 100% and so is he, the revive
  # having just handed it back. Refusing there sent the answer to the positional
  # guess exactly when the screen was fullest, which is the dangerous case. The
  # slack still bounds it: nobody far from his health is ever picked.
  defp closest(candidates, own_hp) when is_integer(own_hp) do
    candidates
    |> Enum.filter(&near?(&1, own_hp))
    |> Enum.min_by(&distance(&1, own_hp), fn -> nil end)
  end

  defp closest(_candidates, _no_hp), do: nil

  defp near?(row, own_hp), do: distance(row, own_hp) <= @hp_slack

  defp distance(%{hp_pct: pct}, own_hp) when is_number(pct), do: abs(round(pct * 100) - own_hp)
  defp distance(_row_without_bar, _own_hp), do: @hp_slack + 1

  # The name already answered it; the health only chose WHICH namesake.
  defp by_hp_or(:by_name), do: :by_name
  defp by_hp_or(other), do: other

  defp fell_back(:by_name), do: :by_name
  defp fell_back(_no_name), do: :by_position

  defp named?(_row, nil), do: false

  defp named?(%{name: name}, own_name) when is_binary(name) and is_binary(own_name),
    do: bare(name) == bare(own_name)

  defp named?(_row, _own_name), do: false

  # `team.json` says "Shiny Vileplume"; the panel reads "Vileplume" (his capture
  # of 2026-08-11). The prefix is a property of the creature, not of the row, and
  # it must never make the bot count itself among its enemies.
  defp bare(name) do
    name
    |> String.trim()
    |> String.downcase()
    |> String.replace_prefix("shiny ", "")
  end
end
