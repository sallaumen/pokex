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
        "shiny_name" => "Shiny Seadra",
        "edited_at" => "2026-02-06"
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
      },
      %{
        "name" => "Venusaur",
        "number" => 3,
        "level" => 60,
        "elements" => ["Grass", "Poison"],
        "weak_to" => ["Fire", "Psychic", "Ice"],
        "resists" => ["Water"],
        "evolutions" => [],
        "sprite" => nil,
        "shiny_of" => nil,
        "shiny_name" => "Shiny Venusaur"
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

    assert [%{name: "Venusaur"}, %{name: "Charizard"}, %{name: "Shiny Seadra"}] =
             Pokedex.search(%{min_level: 60})

    assert [%{name: "Shiny Seadra"}] = Pokedex.search(%{only_shiny: true})
    assert [%{name: "Seadra"}] = Pokedex.search(%{max_level: 50, element: "Water"})

    # empty-string filters are OFF, results sorted by dex number
    assert [%{name: "Venusaur"}, %{name: "Charizard"} | _] =
             Pokedex.search(%{name: "", element: ""})
  end

  @tag :tmp_dir
  test "shinies_for_lure lists the shiny tiers of one lure" do
    assert Pokedex.shinies_for_lure("Shrimp") == [
             %{name: "Shiny Seadra", fishing_level: 60}
           ]

    assert Pokedex.shinies_for_lure("inexistente") == []
  end

  @tag :tmp_dir
  test "hunt_suggestions ranks who my team hits hard, and who hits back" do
    %{targets: targets, threats: threats} = Pokedex.hunt_suggestions(["Charizard"])

    # Venusaur takes Fire (+2), has a Shiny (+1), isn't fishable: score 3.
    # Seadra RESISTS Fire → no super-effective hit → never a target.
    assert [%{entry: %{name: "Venusaur"}, member: "Charizard", hits: ["Fire"], score: 3}] =
             targets

    # Seadra is Water — exactly what Charizard is weak to
    assert [%{entry: %{name: "Seadra"}, members: ["Charizard"], via: ["Water"]}] = threats

    # the fisherman's view: Seadra as the hunter → Charizard is the prey (+2 fishable? no)
    %{targets: [row]} = Pokedex.hunt_suggestions(["Seadra"])
    assert row.entry.name == "Charizard"
    assert row.score == 2
  end

  @tag :tmp_dir
  test "janela de level: alvos perto da força; nada na janela → os mais próximos ABAIXO" do
    # sem player_level: comportamento antigo, janela :all
    assert %{window: :all, targets: [%{entry: %{name: "Venusaur"}}]} =
             Pokedex.hunt_suggestions(["Charizard"])

    # lv 65 ±15 → 50..80: Venusaur (60) está na janela
    assert %{window: {:window, 50, 80}, targets: [%{entry: %{name: "Venusaur"}}]} =
             Pokedex.hunt_suggestions(["Charizard"], %{player_level: 65, level_margin: 15})

    # lv 88 ±15 → 73..103: NENHUM candidato na janela (Venusaur 60 fica fora)
    # → fallback: os mais próximos ABAIXO do level, nunca lista vazia
    assert %{window: {:below, 88}, targets: [%{entry: %{name: "Venusaur"}}]} =
             Pokedex.hunt_suggestions(["Charizard"], %{player_level: 88, level_margin: 15})

    # janela apertada SEM nada abaixo → degrada pra todos os com level
    assert %{window: :all, targets: [%{entry: %{name: "Venusaur"}}]} =
             Pokedex.hunt_suggestions(["Charizard"], %{player_level: 1, level_margin: 5})
  end

  @tag :tmp_dir
  test "edited_after keeps only pages edited on/after the date (unknown dates drop)" do
    assert [%{name: "Seadra"}] = Pokedex.search(%{edited_after: "2026-01-01"})
    assert [%{name: "Seadra"}] = Pokedex.search(%{edited_after: "2026-02-06"})
    assert [] = Pokedex.search(%{edited_after: "2026-02-07"})
  end

  @tag :tmp_dir
  test "lures_for finds every tier that hooks the species" do
    assert Pokedex.lures_for("Seadra") == [%{lure: "Shrimp", fishing_level: 50}]
    assert Pokedex.lures_for("Charizard") == []
  end

  @tag :tmp_dir
  test "reload swaps the cached dataset in place (the sync button's refresh)", %{tmp_dir: tmp} do
    assert Pokedex.get("Lapras") == nil

    bigger = update_in(@dataset["species"], &(&1 ++ [%{"name" => "Lapras", "number" => 131}]))
    File.write!(Path.join(tmp, "pokedex.json"), JSON.encode!(bigger))

    assert :ok = Pokedex.reload()
    assert %{name: "Lapras", number: 131} = Pokedex.get("Lapras")
  end

  @tag :tmp_dir
  test "missing dataset degrades to empty, loaded? false" do
    Application.put_env(:pokex, :pokedex_path, "/nao/existe.json")
    refute Pokedex.loaded?()
    assert Pokedex.search(%{}) == []
    assert Pokedex.lures() == []
  end
end
