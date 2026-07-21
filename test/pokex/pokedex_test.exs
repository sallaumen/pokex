defmodule Pokex.PokedexTest do
  # async: false — scopes the global :pokedex_path env per test
  use ExUnit.Case, async: false

  alias Pokex.Pokedex

  @dataset %{
    "species" => [
      %{
        "name" => "Seadra",
        "number" => 117,
        "level" => 50,
        "elements" => ["Water"],
        "weak_to" => ["Grass", "Electric"],
        "resists" => ["Fire"],
        "evolutions" => [%{"name" => "Horsea", "level" => 10}],
        "sprite" => "images/pokedex/seadra.gif",
        "shiny_of" => nil,
        "shiny_name" => "Shiny Seadra"
      },
      %{
        "name" => "Shiny Seadra",
        "number" => 117,
        "level" => 80,
        "elements" => ["Water"],
        "weak_to" => ["Grass", "Electric"],
        "resists" => [],
        "evolutions" => [],
        "sprite" => "images/pokedex/shiny-seadra.png",
        "shiny_of" => "Seadra",
        "shiny_name" => nil
      },
      %{
        "name" => "Charizard",
        "number" => 6,
        "level" => 100,
        "elements" => ["Fire", "Flying"],
        "weak_to" => ["Water", "Rock"],
        "resists" => ["Grass"],
        "evolutions" => [],
        "sprite" => nil,
        "shiny_of" => nil,
        "shiny_name" => nil
      }
    ],
    "lures" => [
      %{
        "name" => "Shrimp",
        "tiers" => [
          %{"fishing_level" => 50, "pokemon" => ["Seadra", "Poliwhirl"]},
          %{"fishing_level" => 60, "pokemon" => ["Shiny Seadra"]}
        ]
      }
    ]
  }

  setup %{tmp_dir: tmp} do
    path = Path.join(tmp, "pokedex.json")
    File.write!(path, JSON.encode!(@dataset))
    Application.put_env(:pokex, :pokedex_path, path)
    on_exit(fn -> Application.delete_env(:pokex, :pokedex_path) end)
    :ok
  end

  @tag :tmp_dir
  test "search composes name/element/weakness/level/shiny filters" do
    assert [%{name: "Seadra"}, %{name: "Shiny Seadra"}] =
             Pokedex.search(%{name: "seadra"})

    # THE query Lucas asked for: who is weak to my element?
    assert [%{name: "Charizard"}] = Pokedex.search(%{weak_to: "Water"})

    assert [%{name: "Charizard"}] = Pokedex.search(%{element: "Fire"})
    assert [%{name: "Charizard"}, %{name: "Shiny Seadra"}] = Pokedex.search(%{min_level: 60})
    assert [%{name: "Shiny Seadra"}] = Pokedex.search(%{only_shiny: true})
    assert [%{name: "Seadra"}] = Pokedex.search(%{max_level: 50, element: "Water"})

    # empty-string filters are OFF, results sorted by dex number
    assert [%{name: "Charizard"} | _] = Pokedex.search(%{name: "", element: ""})
  end

  @tag :tmp_dir
  test "shinies_for_lure lists the shiny tiers of one lure" do
    assert Pokedex.shinies_for_lure("Shrimp") == [
             %{name: "Shiny Seadra", fishing_level: 60}
           ]

    assert Pokedex.shinies_for_lure("inexistente") == []
  end

  @tag :tmp_dir
  test "missing dataset degrades to empty, loaded? false" do
    Application.put_env(:pokex, :pokedex_path, "/nao/existe.json")
    refute Pokedex.loaded?()
    assert Pokedex.search(%{}) == []
    assert Pokedex.lures() == []
  end
end
