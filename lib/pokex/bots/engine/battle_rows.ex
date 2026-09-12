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
  @type row :: %{
          optional(:name) => String.t() | nil,
          optional(:hp_pct) => number | nil,
          optional(:word) => integer | nil
        }

  @typedoc """
  How his row was found.

  `:absent` = the list IS readable and he is demonstrably not in it — the
  strongest thing this module can say about a pokémon off the field, and the
  only shape of "not here" that may cost a revive (`Engine.Logic`, a caçada de
  12/09). `false` = not found, for a reason that proves nothing: a list with no
  rows, or a Pokebar that could not be read. `nil` = the rows carry no
  description, so the question cannot be asked.
  """
  @type how :: :by_name | :by_hp | :by_position | :absent | false | nil

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
  @spec split([row], %{
          required(:name) => String.t() | nil,
          required(:hp) => integer | nil,
          required(:out?) => boolean | :unknown,
          optional(:word) => integer | nil
        }) :: split
  def split([], _own), do: %{mine: [], theirs: [], how: false}

  def split(rows, %{out?: false}), do: %{mine: [], theirs: rows, how: false}

  def split(rows, own) do
    case Enum.split_with(rows, &same_word?(&1, Map.get(own, :word))) do
      {[_ | _] = by_word, others} -> pick(by_word, others, own, :by_name)
      {[], _none_by_word} -> by_glyph_name(rows, own)
    end
  end

  # THE NAME AS A PICTURE, before the name as text. The list draws each name in
  # a 7px anti-aliased font that no ink floor splits into whole letters (measured
  # on his capture of 2026-09-11: "Golem" shatters into 6 pieces, "Venusaur" into
  # 11), so spelling it is fragile and the lexicon match that follows costs 6ms a
  # row. The rendering itself is deterministic, though: five Golem rows hash to
  # the same `word`, and his Venusaur to a different one. A learned word is an
  # exact, O(1) identity.
  defp same_word?(%{word: word}, word) when is_integer(word), do: true
  defp same_word?(_row, _no_word), do: false

  defp by_glyph_name(rows, own) do
    case Enum.split_with(rows, &named?(&1, own.name)) do
      {[], _none_by_name} -> by_absence(rows, own)
      {namesakes, others} -> pick(namesakes, others, own, :by_name)
    end
  end

  @doc """
  Exactly one row sits within the health slack of `own_hp`.

  Closest-wins is good enough to COUNT, but not to LEARN from: a word taught on
  a coin toss would name the wrong row for the rest of the night. Learning asks
  for the stronger evidence.
  """
  @spec sole_near_hp?([row], integer | nil) :: boolean
  def sole_near_hp?(rows, own_hp) when is_integer(own_hp),
    do: Enum.count(rows, &near?(&1, own_hp)) == 1

  def sole_near_hp?(_rows, _no_hp), do: false

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
      {[], _all_legible} -> %{mine: [], theirs: rows, how: :absent}
      {unreadable, legible} -> pick(unreadable, legible, own, :by_hp)
    end
  end

  # ONE of the candidates is his, never all of them. Hunting the species he has
  # on the field made the whole pile read as his own row once (five Vileplumes
  # on screen, `enemies` 0, the brain answering "seguindo a rota" to a pile that
  # was eating him) — so the ones not picked go back to the enemy list.
  #
  # Sem ninguém dentro da folga a vida não decide, e quem responde é
  # `guess_or_none/4` — o palpite, com o limite que a morte de 12/09 escreveu.
  defp pick([_ | _] = candidates, others, own, how) do
    case closest(candidates, own.hp) do
      nil -> guess_or_none(candidates, others, own, how)
      row -> %{mine: [row], theirs: others ++ List.delete(candidates, row), how: by_hp_or(how)}
    end
  end

  # O NOME NÃO SE CONTESTA POR VIDA. Casado o nome, a linha é dele mesmo com a
  # barra longe: as duas leituras são CAPTURAS diferentes, e é pra isso que a
  # folga existe. Aqui a vida só escolhia ENTRE xarás, e sem escolha volta o
  # primeiro deles.
  defp guess_or_none(candidates, others, _own, :by_name) do
    [first | rest] = candidates
    %{mine: [first], theirs: others ++ rest, how: :by_name}
  end

  defp guess_or_none(candidates, others, own, how) do
    [first | rest] = candidates
    sobra = others ++ rest

    if sobra == [] and contradicted?(candidates, own.hp),
      do: %{mine: [], theirs: others ++ candidates, how: :absent},
      else: %{mine: [first], theirs: sobra, how: fell_back(how)}
  end

  # O PALPITE NÃO PODE SER O MOTIVO DE A TELA FICAR VAZIA.
  #
  # Com a pilha cheia, chutar a linha própria custa UM inimigo a menos numa
  # conta de cinco: a caçada continua lutando, e o chute é o que salva a linha
  # dele quando o nome não se deixa ler (medido em 18/08: linha 0 é a dele em
  # 134 de 140 leituras). Com uma linha só, o mesmo chute apaga a luta inteira.
  #
  # A morte de 12/09, 16:00: sobrou UMA linha, sem nome legível e com a barra em
  # 0%, contra uma Pokebar de 98%. O chute deu a ela o crachá de "sou eu",
  # `enemies` virou 0, e por 12,5 SEGUNDOS o cérebro respondeu "nada aqui —
  # seguindo a rota" enquanto o olho via um shiny com caveira a 2 tiles, em 4%
  # de vida, e o pokémon dele já fora de campo. O personagem morreu ali.
  #
  # Então: quando descontar deixaria a tela VAZIA e a barra da candidata é
  # legível e está longe da Pokebar, ela não é dele. Uma barra lida a 98 pontos
  # da dele não é uma dúvida — é prova. Errar pro outro lado custa o bot lutar
  # com um inimigo a mais; errar pra este lado custa a caçada virar as costas
  # pra um bicho em cima dele.
  defp contradicted?(candidates, own_hp) when is_integer(own_hp),
    do: Enum.all?(candidates, &is_number(Map.get(&1, :hp_pct)))

  defp contradicted?(_candidates, _no_pokebar), do: false

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

  # Só o `:by_hp` chega aqui: o nome casado é respondido antes, na primeira
  # cláusula de `guess_or_none/4`, e nunca vira palpite.
  defp fell_back(:by_hp), do: :by_position

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
