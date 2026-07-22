defmodule Pokex.Pokedex.ClansTest do
  use ExUnit.Case, async: true

  alias Pokex.Pokedex.Clans

  describe "parse/1 — matéria → clã(s), medido nas 178 strings da base real" do
    test "matéria simples é o próprio clã" do
      assert Clans.parse("Seavell") == ["Seavell"]
    end

    test "o tier (Enhanced/Superior/Mastered) é ruído" do
      assert Clans.parse("Malefic Superior") == ["Malefic"]
      assert Clans.parse("Naturia Enhanced") == ["Naturia"]
      assert Clans.parse("Gardestrike Mastered") == ["Gardestrike"]
    end

    test "'ou' divide em dois clãs, ordem da página" do
      assert Clans.parse("Naturia ou Malefic") == ["Naturia", "Malefic"]
      assert Clans.parse("Naturia Enhanced ou Wingeon Enhanced") == ["Naturia", "Wingeon"]
    end

    test "as três sujeiras da wiki: 'or' inglês, 'e', e o typo Oreboun" do
      assert Clans.parse("Seavell or Wingeon") == ["Seavell", "Wingeon"]
      assert Clans.parse("Orebound Superior e Psycraft Superior") == ["Orebound", "Psycraft"]
      assert Clans.parse("Oreboun") == ["Orebound"]
    end

    test "Ironhard é o décimo clã" do
      assert Clans.parse("Ironhard Superior") == ["Ironhard"]
    end

    test "sem matéria, sem clã — e palavra desconhecida NUNCA vira clã" do
      assert Clans.parse(nil) == []
      assert Clans.parse("") == []
      assert Clans.parse("Bazinga Superior") == []
    end

    test "clã repetido não duplica" do
      assert Clans.parse("Psycraft ou Psycraft Superior") == ["Psycraft"]
    end
  end

  test "all/0 lista os 10 clãs canônicos" do
    assert length(Clans.all()) == 10
    assert "Volcanic" in Clans.all()
    assert "Ironhard" in Clans.all()
  end
end
