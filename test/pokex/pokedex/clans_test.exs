defmodule Pokex.Pokedex.ClansTest do
  use ExUnit.Case, async: true

  alias Pokex.Pokedex.Clans

  describe "parse/1 — matéria to clan(s), measured on the 178 real base strings" do
    test "a plain matéria is the clan itself" do
      assert Clans.parse("Seavell") == ["Seavell"]
    end

    test "the tier (Enhanced/Superior/Mastered) is noise" do
      assert Clans.parse("Malefic Superior") == ["Malefic"]
      assert Clans.parse("Naturia Enhanced") == ["Naturia"]
      assert Clans.parse("Gardestrike Mastered") == ["Gardestrike"]
    end

    test "'ou' splits into two clans, in page order" do
      assert Clans.parse("Naturia ou Malefic") == ["Naturia", "Malefic"]
      assert Clans.parse("Naturia Enhanced ou Wingeon Enhanced") == ["Naturia", "Wingeon"]
    end

    test "handles the wiki's three quirks: English 'or', 'e', and the Oreboun typo" do
      assert Clans.parse("Seavell or Wingeon") == ["Seavell", "Wingeon"]
      assert Clans.parse("Orebound Superior e Psycraft Superior") == ["Orebound", "Psycraft"]
      assert Clans.parse("Oreboun") == ["Orebound"]
    end

    test "Ironhard is the tenth clan" do
      assert Clans.parse("Ironhard Superior") == ["Ironhard"]
    end

    test "no matéria means no clan — an unknown word never becomes a clan" do
      assert Clans.parse(nil) == []
      assert Clans.parse("") == []
      assert Clans.parse("Bazinga Superior") == []
    end

    test "a repeated clan is not duplicated" do
      assert Clans.parse("Psycraft ou Psycraft Superior") == ["Psycraft"]
    end
  end

  test "all/0 lists the 10 canonical clans" do
    assert length(Clans.all()) == 10
    assert "Volcanic" in Clans.all()
    assert "Ironhard" in Clans.all()
  end
end
