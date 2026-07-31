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
        "materia" => "Seavell",
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
        "shiny_name" => nil,
        "materia" => "Volcanic Superior"
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

  describe "element normalization (the wiki writes dual types 5 ways)" do
    @tag :tmp_dir
    test "separators and case always normalize to the same element list", %{tmp_dir: tmp} do
      dataset =
        put_in(@dataset["species"], [
          %{"name" => "Rayquaza", "elements" => ["Dragon &amp; Flying"], "number" => 384},
          %{"name" => "Girafarig", "elements" => ["Normal e Psychic"], "number" => 203},
          %{"name" => "Qwilfish", "elements" => ["water"], "number" => 211},
          %{"name" => "Delibird", "elements" => ["Ice. Poison"], "number" => 225},
          %{"name" => "Beautifly", "elements" => ["flying and\nbug"], "number" => 267},
          %{"name" => "Qwilfish2", "elements" => ["Ice Poison"], "number" => 212},
          %{
            "name" => "Typo",
            "elements" => ["Groud"],
            "weak_to" => ["Posion", "Fly"],
            "number" => 999
          },
          %{"name" => "Venusaur", "elements" => ["Grass / Poison"], "number" => 3}
        ])

      File.write!(Path.join(tmp, "pokedex.json"), JSON.encode!(dataset))
      Pokex.Pokedex.reload()

      assert %{elements: ["Dragon", "Flying"]} = Pokedex.get("Rayquaza")
      assert %{elements: ["Normal", "Psychic"]} = Pokedex.get("Girafarig")
      assert %{elements: ["Water"]} = Pokedex.get("Qwilfish")
      assert %{elements: ["Ice", "Poison"]} = Pokedex.get("Delibird")
      assert %{elements: ["Flying", "Bug"]} = Pokedex.get("Beautifly")
      assert %{elements: ["Grass", "Poison"]} = Pokedex.get("Venusaur")

      assert %{elements: ["Ice", "Poison"]} = Pokedex.get("Qwilfish2")
      assert %{elements: ["Ground"], weak_to: ["Poison", "Flying"]} = Pokedex.get("Typo")

      assert Pokedex.elements() == [
               "Bug",
               "Dragon",
               "Flying",
               "Grass",
               "Ground",
               "Ice",
               "Normal",
               "Poison",
               "Psychic",
               "Water"
             ]

      assert "Rayquaza" in (Pokedex.search(%{elements: ["Flying"]}) |> Enum.map(& &1.name))
    end
  end

  describe "clans derived from matéria" do
    @tag :tmp_dir
    test "each entry gets its clans; a shiny without matéria inherits from its base form" do
      assert %{clans: ["Seavell"]} = Pokedex.get("Seadra")
      assert %{clans: ["Volcanic"]} = Pokedex.get("Charizard")

      assert %{clans: ["Seavell"]} = Pokedex.get("Shiny Seadra")
    end

    @tag :tmp_dir
    test "an entry without matéria and without a base form has no clan" do
      assert %{clans: []} = Pokedex.get("Venusaur")
    end
  end

  describe "multi-value filters — OR within a group, AND between groups" do
    @tag :tmp_dir
    test "elements: [Grass, Water] is the union" do
      names = Pokedex.search(%{elements: ["Grass", "Water"]}) |> Enum.map(& &1.name)

      assert "Venusaur" in names
      assert "Seadra" in names
      refute "Charizard" in names
    end

    @tag :tmp_dir
    test "an empty list is a disabled filter" do
      assert length(Pokedex.search(%{elements: []})) == length(Pokedex.search(%{}))
    end

    @tag :tmp_dir
    test "different groups still compose with AND" do
      names =
        Pokedex.search(%{elements: ["Grass", "Water"], min_level: 55})
        |> Enum.map(& &1.name)

      assert "Venusaur" in names
      refute "Seadra" in names
    end

    @tag :tmp_dir
    test "weak_to as a list matches weakness to any of the elements" do
      names = Pokedex.search(%{weak_to: ["Rock", "Electric"]}) |> Enum.map(& &1.name)

      assert "Charizard" in names
      assert "Seadra" in names
    end

    @tag :tmp_dir
    test "clans filters by the derived clan" do
      names = Pokedex.search(%{clans: ["Seavell"]}) |> Enum.map(& &1.name)

      assert "Seadra" in names
      assert "Shiny Seadra" in names
      refute "Charizard" in names
    end

    @tag :tmp_dir
    test "the old singular keys still work (bookmarked URLs)" do
      assert Pokedex.search(%{element: "Water"}) |> Enum.map(& &1.name) |> Enum.member?("Seadra")
      assert Pokedex.search(%{weak_to: "Rock"}) |> Enum.map(& &1.name) == ["Charizard"]
    end
  end

  @tag :tmp_dir
  test "search composes name/element/weakness/level/shiny filters" do
    assert [%{name: "Seadra"}, %{name: "Shiny Seadra"}] =
             Pokedex.search(%{name: "seadra"})

    assert [%{name: "Charizard"}] = Pokedex.search(%{weak_to: "Water"})

    assert [%{name: "Charizard"}] = Pokedex.search(%{element: "Fire"})

    assert [%{name: "Venusaur"}, %{name: "Charizard"}, %{name: "Shiny Seadra"}] =
             Pokedex.search(%{min_level: 60})

    assert [%{name: "Shiny Seadra"}] = Pokedex.search(%{only_shiny: true})
    assert [%{name: "Seadra"}] = Pokedex.search(%{max_level: 50, element: "Water"})

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
  # scoring: +2 super-effective hit, +1 shiny variant; resisting the element
  # disqualifies a target outright
  test "hunt_suggestions ranks who my team hits hard, and who hits back" do
    %{targets: targets, threats: threats} = Pokedex.hunt_suggestions(["Charizard"])

    assert [%{entry: %{name: "Venusaur"}, member: "Charizard", hits: ["Fire"], score: 3}] =
             targets

    assert [%{entry: %{name: "Seadra"}, members: ["Charizard"], via: ["Water"]}] = threats

    %{targets: [row]} = Pokedex.hunt_suggestions(["Seadra"])
    assert row.entry.name == "Charizard"
    assert row.score == 2
  end

  @tag :tmp_dir
  test "level window: targets near the player's strength; an empty window falls back to the closest below" do
    assert %{window: :all, targets: [%{entry: %{name: "Venusaur"}}]} =
             Pokedex.hunt_suggestions(["Charizard"])

    assert %{window: {:window, 50, 80}, targets: [%{entry: %{name: "Venusaur"}}]} =
             Pokedex.hunt_suggestions(["Charizard"], %{player_level: 65, level_margin: 15})

    assert %{window: {:below, 88}, targets: [%{entry: %{name: "Venusaur"}}]} =
             Pokedex.hunt_suggestions(["Charizard"], %{player_level: 88, level_margin: 15})

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
  test "sorting: level, element, weakness, shiny, wiki edit — and inversion" do
    names = Pokedex.search(%{sort: :level}) |> Enum.map(& &1.name)
    assert names == ["Seadra", "Venusaur", "Shiny Seadra", "Charizard"]

    desc = Pokedex.search(%{sort: :level, desc: true}) |> Enum.map(& &1.name)
    assert hd(desc) == "Charizard"

    assert %{name: "Charizard", elements: ["Fire" | _]} =
             Pokedex.search(%{sort: :element}) |> hd()

    assert %{name: "Charizard"} = Pokedex.search(%{sort: :weak_to, desc: true}) |> hd()

    shiny_first = Pokedex.search(%{sort: :shiny}) |> Enum.map(& &1.name)
    assert hd(shiny_first) == "Shiny Seadra"

    assert %{name: "Seadra"} = Pokedex.search(%{sort: :edited}) |> hd()
  end

  @tag :tmp_dir
  test "novelty = wiki freshness (auto-recycles): inside the window, outside, and unknown",
       %{tmp_dir: tmp} do
    today = ~D[2026-07-21]

    dataset =
      update_in(@dataset["species"], fn species ->
        Enum.map(species, fn
          %{"name" => "Seadra"} = s -> Map.put(s, "edited_at", "2026-07-20")
          %{"name" => "Charizard"} = s -> Map.put(s, "edited_at", "2026-06-21")
          s -> Map.delete(s, "edited_at")
        end)
      end)

    File.write!(Path.join(tmp, "pokedex.json"), JSON.encode!(dataset))
    Pokedex.reload()

    assert {:wiki, 1} = Pokedex.novelty(Pokedex.get("Seadra"), today)
    assert Pokedex.novelty(Pokedex.get("Charizard"), today) == nil
    assert Pokedex.novelty(Pokedex.get("Venusaur"), today) == nil
    assert Pokedex.wiki_age_days(Pokedex.get("Charizard"), today) == 30
    assert Pokedex.novelty_days() == 7
  end

  describe "page/3 — cursor (keyset) pagination" do
    # 250 species with heavy level ties: where pagination without a stable
    # tiebreaker duplicates or skips rows at the page turn
    defp big_dataset do
      species =
        for i <- 1..250 do
          %{
            "name" => "Mon#{String.pad_leading("#{i}", 3, "0")}",
            "number" => i,
            # only 5 distinct levels → mass ties
            "level" => rem(i, 5) * 10 + 10,
            "elements" => ["Water"],
            "weak_to" => [],
            "resists" => [],
            "evolutions" => [],
            "sprite" => nil,
            "shiny_of" => nil,
            "shiny_name" => nil
          }
        end

      %{"species" => species, "lures" => []}
    end

    defp load_big(tmp) do
      File.write!(Path.join(tmp, "pokedex.json"), JSON.encode!(big_dataset()))
      Pokedex.reload()
    end

    @tag :tmp_dir
    test "walks the whole base in pages, without repeating or skipping", %{tmp_dir: tmp} do
      load_big(tmp)

      {all, pages} = drain(%{}, nil, [], 0)

      assert length(all) == 250
      assert Enum.uniq(all) == all
      assert all == Enum.map(Pokedex.search(%{}), & &1.name)
      assert pages == 3
    end

    @tag :tmp_dir
    test "level ties (where unstable ordering would be fatal) also page cleanly",
         %{tmp_dir: tmp} do
      load_big(tmp)

      {asc, _} = drain(%{sort: :level}, nil, [], 0)
      assert length(asc) == 250
      assert Enum.uniq(asc) == asc
      assert asc == Enum.map(Pokedex.search(%{sort: :level}), & &1.name)

      {desc, _} = drain(%{sort: :level, desc: true}, nil, [], 0)
      assert length(desc) == 250
      assert Enum.uniq(desc) == desc
      assert desc == Enum.map(Pokedex.search(%{sort: :level, desc: true}), & &1.name)
    end

    @tag :tmp_dir
    test "cursor is nil on the last page; total is the filtered count, not the loaded count", %{
      tmp_dir: tmp
    } do
      load_big(tmp)

      first = Pokedex.page(%{}, nil, 100)
      assert length(first.entries) == 100
      assert first.total == 250
      assert first.cursor != nil

      last = Pokedex.page(%{}, Pokedex.page(%{}, first.cursor, 100).cursor, 100)
      assert length(last.entries) == 50
      assert last.cursor == nil
    end

    @tag :tmp_dir
    test "filters apply to pagination (total and pages follow the filter)", %{tmp_dir: tmp} do
      load_big(tmp)

      page = Pokedex.page(%{min_level: 50}, nil, 100)
      assert page.total == 50
      assert length(page.entries) == 50
      assert page.cursor == nil
      assert Enum.all?(page.entries, &(&1.level >= 50))
    end

    @tag :tmp_dir
    test "entries without a sort value still sink to the end, and page", %{tmp_dir: tmp} do
      species =
        for i <- 1..150 do
          base = %{
            "name" => "Mon#{String.pad_leading("#{i}", 3, "0")}",
            "number" => i,
            "elements" => ["Water"],
            "weak_to" => [],
            "resists" => [],
            "evolutions" => [],
            "sprite" => nil,
            "shiny_of" => nil,
            "shiny_name" => nil
          }

          if rem(i, 2) == 0, do: Map.put(base, "level", 50), else: base
        end

      File.write!(
        Path.join(tmp, "pokedex.json"),
        JSON.encode!(%{"species" => species, "lures" => []})
      )

      Pokedex.reload()

      {all, _} = drain(%{sort: :level}, nil, [], 0)
      assert length(all) == 150
      assert Enum.uniq(all) == all
      assert all == Enum.map(Pokedex.search(%{sort: :level}), & &1.name)
    end

    defp drain(filters, cursor, acc, pages) do
      page = Pokedex.page(filters, cursor, 100)
      acc = acc ++ Enum.map(page.entries, & &1.name)

      case page.cursor do
        nil -> {acc, pages + 1}
        next -> drain(filters, next, acc, pages + 1)
      end
    end
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
