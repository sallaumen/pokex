defmodule Pokex.Pokedex.PageParserTest do
  use ExUnit.Case, async: true

  alias Pokex.Pokedex.PageParser

  # REAL pages from https://wiki.pokealliance.com/api/page/..., downloaded
  # 2026-08-25. Every one of them is the `pokemon-v4` template, which was the
  # template on 40 out of 40 sampled pages — these break loudly if it moves.
  defp parsed(name) do
    {:ok, attributes} =
      "test/fixtures/pokedex/#{name}.json"
      |> File.read!()
      |> JSON.decode!()
      |> Map.fetch!("content")
      |> PageParser.parse()

    attributes
  end

  describe "parse/1 — a complete page" do
    test "reads the four basic-information numbers" do
      bulbasaur = parsed("bulbasaur")

      assert bulbasaur.hp == 600
      assert bulbasaur.experience == 900
      assert bulbasaur.level == 1
      assert bulbasaur.tier == "6"
      assert bulbasaur.role == "PVE"
    end

    test "reads the pokédex description" do
      assert parsed("bulbasaur").description =~ "strange seed was planted"
    end

    test "reads every move slot with its cooldown in seconds and its own element" do
      moves = parsed("bulbasaur").moves

      assert length(moves) == 8
      assert %{slot: "M1", name: "Tackle", cooldown_s: 12, element: "Normal"} = hd(moves)

      assert %{slot: "M2", name: "Razor Leaf", cooldown_s: 10, element: "Grass"} =
               Enum.at(moves, 1)
    end

    test "reads the field abilities" do
      assert parsed("bulbasaur").habilidades == ["Cut", "Strength", "Headbutt"]
    end

    test "reads what it evolves into, with the level and the items the evolution asks for" do
      assert [%{name: "Ivysaur", level: 40, items: ["Leaf Stone"]}] =
               parsed("bulbasaur").evolves_to
    end
  end

  describe "parse/1 — pages missing sections" do
    test "a page with no moves table reports no moves instead of failing" do
      assert parsed("groudon").moves == []
    end

    test "a page with no abilities reports an empty list" do
      assert parsed("shiny_rattata").habilidades == []
    end

    test "the placeholder description reads as no description at all" do
      assert parsed("mewtwo").description == nil
    end

    test "a species with nothing to evolve into carries empty evolution lists" do
      mewtwo = parsed("mewtwo")

      assert mewtwo.evolves_to == []
      assert mewtwo.evolves_from == []
    end

    test "a shiny still reports its own numbers" do
      shiny = parsed("shiny_rattata")

      assert is_integer(shiny.hp)
      assert is_integer(shiny.level)
    end
  end

  describe "parse/1 — a page that is not a species" do
    test "html without the basic-information table is unrecognized" do
      assert PageParser.parse("<div><h1>Boost</h1><p>texto</p></div>") == {:error, :unrecognized}
    end

    test "an empty body is unrecognized" do
      assert PageParser.parse("") == {:error, :unrecognized}
    end
  end
end
