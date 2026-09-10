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

  describe "by position — the guess, named as one" do
    test "with no health to compare, the first unreadable row is taken" do
      split = BattleRows.split([row(nil), row(nil)], own(%{hp: nil}))

      assert split.how == :by_position
      assert length(split.mine) == 1
      assert BattleRows.enemies(split) == 1
    end

    test "nobody within the slack is still a guess, not a wrong pick" do
      split = BattleRows.split([row(nil, 0.10), row(nil, 0.20)], own(%{hp: 100}))

      assert split.how == :by_position
      assert BattleRows.enemies(split) == 1
    end
  end
end
