defmodule Pokex.Bots.Engine.BattleRowsTest do
  use ExUnit.Case, async: true

  alias Pokex.Bots.Engine.BattleRows

  defp row(name, hp \\ nil), do: %{name: name, hp_pct: hp}

  defp own(overrides \\ %{}),
    do: Map.merge(%{name: "Vespiquen", hp: 100, out?: true}, overrides)

  describe "the count is a derivation, not an arithmetic" do
    test "an empty list is nobody's" do
      split = BattleRows.split([], own())

      assert split == %{mine: [], theirs: [], how: false}
      assert BattleRows.enemies(split) == 0
    end

    test "the enemy count is the length of the enemy list" do
      split = BattleRows.split([row("Vespiquen", 1.0), row("Venonat", 1.0)], own())

      assert BattleRows.enemies(split) == length(split.theirs)
      assert BattleRows.enemies(split) == 1
    end
  end

  describe "by name" do
    test "his row leaves the enemy list" do
      split = BattleRows.split([row("Venonat"), row("Vespiquen"), row("Oddish")], own())

      assert split.how == :by_name
      assert split.mine == [row("Vespiquen")]
      assert Enum.map(split.theirs, & &1.name) == ["Venonat", "Oddish"]
    end

    test "the shiny prefix is the creature's, not the row's" do
      split = BattleRows.split([row("Vileplume")], own(%{name: "Shiny Vileplume"}))

      assert split.how == :by_name
      assert split.theirs == []
    end

    # #571: descontar TODO xará fazia uma pilha inteira sumir da conta.
    test "only ONE namesake is his — the rest are real monsters" do
      cinco = for hp <- [1.0, 0.5, 0.4, 0.3, 0.2], do: row("Vileplume", hp)
      split = BattleRows.split(cinco, own(%{name: "Vileplume", hp: 100}))

      assert length(split.mine) == 1
      assert BattleRows.enemies(split) == 4
    end
  end

  # O DEFEITO NOVO: a cláusula do nome não olhava `out?`. Caçando a espécie que
  # ele tem no time, com o pokémon RECOLHIDO (o revive acabou de guardá-lo), uma
  # linha de xará saía da conta como se fosse dele — um inimigo real a menos
  # justo no instante em que ele está sem pokémon pra responder.
  describe "with his pokémon off the field" do
    test "a namesake is a monster, not him" do
      split = BattleRows.split([row("Vileplume", 1.0)], own(%{name: "Vileplume", out?: false}))

      assert split.how == false
      assert split.mine == []
      assert BattleRows.enemies(split) == 1
    end

    test "an unreadable row is a monster whose name the glyphs do not know" do
      split = BattleRows.split([row(nil, 1.0)], own(%{out?: false}))

      assert BattleRows.enemies(split) == 1
    end

    # `:unknown` não é `false`: descontar numa leitura que não aconteceu tira
    # um inimigo real da conta por falta de informação.
    test "an unknown reading discounts nobody" do
      split = BattleRows.split([row(nil, 1.0)], own(%{out?: :unknown}))

      assert split.how == false
      assert BattleRows.enemies(split) == 1
    end
  end

  describe "by health, when no name can be read" do
    test "the row whose bar agrees with the Pokebar is his" do
      split = BattleRows.split([row(nil, 0.30), row(nil, 0.68)], own(%{hp: 69}))

      assert split.how == :by_hp
      assert split.mine == [row(nil, 0.68)]
      assert BattleRows.enemies(split) == 1
    end

    # A REGRA ANTIGA DESISTIA AQUI. Ela exigia UMA só candidata dentro da
    # folga, e uma pilha recém-chegada está toda com 100% — igual a ele, que
    # acabou de voltar do revive. Desistir mandava a resposta pro chute
    # posicional exatamente na tela mais cheia, que é a mais perigosa.
    test "several rows near his health no longer fall back to a guess" do
      split =
        BattleRows.split(
          [row(nil, 0.98), row(nil, 1.00), row(nil, 0.97)],
          own(%{hp: 100})
        )

      assert split.how == :by_hp
      assert split.mine == [row(nil, 1.00)]
      assert BattleRows.enemies(split) == 2
    end

    test "a legible list that does not contain him takes nothing away" do
      split = BattleRows.split([row("Venonat", 1.0), row("Oddish", 1.0)], own())

      assert split.how == false
      assert BattleRows.enemies(split) == 2
    end
  end

  # THE NAME AS DRAWN. No glyph spells the list's 7px lettering, but the game
  # draws the same name the same way every time: a learned word is his row's
  # identity, and it depends on neither the health nor the order.
  describe "by the word — the name as it is drawn" do
    defp drawn(word, hp), do: %{name: nil, word: word, hp_pct: hp}

    test "his word picks his row where health alone would pick the wrong one" do
      rows = [drawn(2, 1.0), drawn(2, 1.0), drawn(1, 1.0)]
      split = BattleRows.split(rows, own(%{word: 1}))

      assert split.how == :by_name
      assert split.mine == [drawn(1, 1.0)]
      assert BattleRows.enemies(split) == 2
    end

    test "a word no row carries leaves the old ways in charge" do
      split = BattleRows.split([drawn(2, 0.30), drawn(3, 0.68)], own(%{hp: 69, word: 1}))

      assert split.how == :by_hp
      assert split.mine == [drawn(3, 0.68)]
    end

    test "with his pokemon off the field, a row with his word is a monster" do
      split = BattleRows.split([drawn(1, 1.0)], own(%{word: 1, out?: false}))

      assert split.how == false
      assert BattleRows.enemies(split) == 1
    end
  end

  describe "sole_near_hp? — the evidence strong enough to learn from" do
    test "exactly one row near his health" do
      assert BattleRows.sole_near_hp?([row(nil, 0.30), row(nil, 0.68)], 69)
    end

    test "two rows near his health are a coin toss" do
      refute BattleRows.sole_near_hp?([row(nil, 0.70), row(nil, 0.68)], 69)
    end

    test "no health read, no evidence" do
      refute BattleRows.sole_near_hp?([row(nil, 0.68)], nil)
    end
  end

  describe "by position — the guess, named as one" do
    test "with no health to compare, the first unreadable row is taken" do
      split = BattleRows.split([row(nil), row(nil)], own(%{hp: nil}))

      assert split.how == :by_position
      assert length(split.mine) == 1
      assert BattleRows.enemies(split) == 1
    end

    # A MORTE DE 12/09, 16:00. Sobrou UMA linha na janela de batalha, sem nome
    # legível e com a barra em 0%, contra uma Pokebar de 98%. O palpite deu a
    # ela o crachá de "sou eu", `enemies` virou 0, e por 12,5 SEGUNDOS o
    # cérebro respondeu "nada aqui — seguindo a rota" enquanto o olho via um
    # shiny com caveira a 2 tiles, em 4% de vida, e o pokémon dele fora de
    # campo. Uma barra LIDA a 98 pontos da dele não é dúvida: é prova.
    test "a lone row whose bar contradicts the Pokebar is NOT his" do
      split = BattleRows.split([row(nil, 0.0)], own(%{hp: 98}))

      assert split.how == false
      assert split.mine == []
      assert BattleRows.enemies(split) == 1
    end

    # …MAS COM PILHA NA TELA O PALPITE SEGUE VALENDO. Chutar uma linha entre
    # cinco custa um inimigo a menos numa conta de cinco e a caçada continua
    # lutando; é com UMA linha que o mesmo chute apaga a luta inteira. E o
    # palpite é o que salva a linha própria quando o nome não se deixa ler
    # (linha 0 é a dele em 134 de 140 leituras, 18/08).
    test "with a pile on screen the guess still decides" do
      split = BattleRows.split([row(nil, 0.10), row(nil, 0.20)], own(%{hp: 100}))

      assert split.how == :by_position
      assert BattleRows.enemies(split) == 1
    end

    # …MAS UMA LINHA SEM BARRA SEGUE SENDO DÚVIDA, e a dúvida é do palpite: é
    # ele que salva a linha própria quando a barra não se deixa ler. Basta UMA
    # candidata sem barra pra o palpite voltar a decidir.
    test "and a lone row with no bar at all is still a guess, not an enemy" do
      split = BattleRows.split([row(nil)], own(%{hp: 100}))

      assert split.how == :by_position
      assert BattleRows.enemies(split) == 0
    end
  end
end
