defmodule Pokex.Pokedex.IndexTest do
  use ExUnit.Case, async: true

  alias Pokex.Pokedex.Index

  # A REAL slice of https://wiki.pokealliance.com/api/pokemon, downloaded
  # 2026-08-25 — it pins the API's shape the way the old HTML fixtures pinned
  # the wiki's markup.
  defp raw, do: "test/fixtures/pokedex/api_index.json" |> File.read!() |> JSON.decode!()

  defp entry(name), do: Enum.find(Index.parse(raw()), &(&1.name == name))

  describe "parse/1" do
    test "a normal species carries its number, generation and level as integers" do
      bulbasaur = entry("Bulbasaur")

      assert bulbasaur.number == 1
      assert bulbasaur.generation == 1
      assert bulbasaur.level == 1
      assert bulbasaur.variant == "normal"
      assert bulbasaur.path == "gen/1/001_bulbasaur"
      assert bulbasaur.image == "/pokemon/001.png"
    end

    test "elements arrive capitalised, the way the rest of the app spells them" do
      assert entry("Bulbasaur").elements == ["Grass", "Poison"]
    end

    test "a shiny is marked as one and shares its base form's number" do
      shiny = entry("Shiny Bulbasaur")

      assert shiny.variant == "shiny"
      assert shiny.number == 1
      assert shiny.image == "/pokemon/001.1.png"
    end

    test "the tier shown is the display one, so a tier-1 ULTIMATE reads as ULTIMATE" do
      assert entry("Mewtwo").tier == "ULTIMATE"
    end

    test "a named tier survives as its name" do
      assert entry("Shiny Gengar").tier == "Legendary"
    end

    test "a numeric tier becomes the string the filter chips compare against" do
      assert entry("Bulbasaur").tier == "6"
    end

    test "a missing tier or role is nil, never the string None" do
      unown = entry("Unown A")

      assert unown.tier == nil
      assert unown.role == nil
    end

    test "a PVP species keeps its role" do
      assert entry("Groudon").role == "PVP"
    end

    test "every parsed entry has a name and a path" do
      entries = Index.parse(raw())

      assert length(entries) == 9
      assert Enum.all?(entries, &(is_binary(&1.name) and is_binary(&1.path)))
    end
  end

  describe "element_icons/1" do
    test "maps each capitalised element to the icon the API points at" do
      icons = Index.element_icons(raw())

      assert icons["Grass"] == "/elements/4.png"
      assert icons["Poison"] == "/elements/8.png"
    end
  end
end
