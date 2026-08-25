defmodule Pokex.PokedexTest do
  # async: false — scopes the global :pokedex_path env per test
  use ExUnit.Case, async: false

  alias Pokex.Pokedex

  defp species(name, extra) do
    Map.merge(
      %{
        "name" => name,
        "number" => 1,
        "generation" => 1,
        "variant" => "normal",
        "shiny_of" => nil,
        "level" => 1,
        "tier" => "6",
        "role" => "PVE",
        "hp" => 600,
        "experience" => 900,
        "elements" => ["Water"],
        "habilidades" => [],
        "description" => nil,
        "moves" => [],
        "evolves_to" => [],
        "evolves_from" => [],
        "sprite" => nil,
        "path" => "gen/1/001_#{String.downcase(name)}"
      },
      extra
    )
  end

  @dataset %{
    "species" => [
      %{
        "name" => "Bulbasaur",
        "number" => 1,
        "generation" => 1,
        "variant" => "normal",
        "shiny_of" => nil,
        "level" => 1,
        "tier" => "6",
        "role" => "PVE",
        "hp" => 600,
        "experience" => 900,
        "elements" => ["Grass", "Poison"],
        "habilidades" => ["Cut"],
        "description" => "uma semente",
        "moves" => [
          %{"slot" => "M1", "name" => "Tackle", "cooldown_s" => 12, "element" => "Normal"}
        ],
        "evolves_to" => [%{"name" => "Ivysaur", "level" => 40, "items" => ["Leaf Stone"]}],
        "evolves_from" => [],
        "sprite" => "images/pokedex/001.png",
        "path" => "gen/1/001_bulbasaur"
      },
      %{
        "name" => "Shiny Bulbasaur",
        "number" => 1,
        "generation" => 1,
        "variant" => "shiny",
        "shiny_of" => "Bulbasaur",
        "level" => 40,
        "tier" => "5",
        "role" => "PVE",
        "hp" => 900,
        "experience" => 1800,
        "elements" => ["Grass", "Poison"],
        "habilidades" => [],
        "description" => nil,
        "moves" => [],
        "evolves_to" => [],
        "evolves_from" => [],
        "sprite" => "images/pokedex/001.1.png",
        "path" => "shiny/001_shiny_bulbasaur"
      },
      %{
        "name" => "Charizard",
        "number" => 6,
        "generation" => 1,
        "variant" => "normal",
        "shiny_of" => nil,
        "level" => 100,
        "tier" => "ULTIMATE",
        "role" => "PVE",
        "hp" => 500,
        "experience" => 800,
        "elements" => ["Fire", "Flying"],
        "habilidades" => ["Fly"],
        "description" => nil,
        "moves" => [],
        "evolves_to" => [],
        "evolves_from" => [],
        "sprite" => nil,
        "path" => "gen/1/006_charizard"
      },
      %{
        "name" => "Piplup",
        "number" => 393,
        "generation" => 4,
        "variant" => "normal",
        "shiny_of" => nil,
        "level" => 20,
        "tier" => nil,
        "role" => nil,
        "hp" => 400,
        "experience" => 600,
        "elements" => ["Water"],
        "habilidades" => [],
        "description" => nil,
        "moves" => [],
        "evolves_to" => [],
        "evolves_from" => [],
        "sprite" => nil,
        "path" => "gen/4/393_piplup"
      }
    ],
    "scraped_at" => "2026-08-25T10:00:00Z"
  }

  setup %{tmp_dir: tmp} do
    path = Path.join(tmp, "pokedex.json")
    File.write!(path, JSON.encode!(@dataset))
    Application.put_env(:pokex, :pokedex_path, path)
    on_exit(fn -> Application.delete_env(:pokex, :pokedex_path) end)
    :ok
  end

  describe "effectiveness derived from the type chart" do
    @tag :tmp_dir
    test "a Grass and Poison species is weak to what the canonical chart says" do
      assert Pokedex.get("Bulbasaur").weak_to == ["Fire", "Flying", "Ice", "Psychic"]
    end

    @tag :tmp_dir
    test "the buckets come from the chart, not from the file on disk" do
      bulbasaur = Pokedex.get("Bulbasaur")

      assert "Water" in bulbasaur.resists
      assert "Grass" in bulbasaur.resists
      assert bulbasaur.immune == []
      assert "Normal" in bulbasaur.neutral
      assert Enum.any?(bulbasaur.effectiveness, &(&1.label == "Muito Inefetivo"))
    end

    @tag :tmp_dir
    test "a shiny derives the same buckets as its base form, sharing its elements" do
      assert Pokedex.get("Shiny Bulbasaur").weak_to == Pokedex.get("Bulbasaur").weak_to
    end

    @tag :tmp_dir
    test "a quadruple weakness reads as its own tier" do
      charizard = Pokedex.get("Charizard")

      assert %{label: "Muito Efetivo", elements: ["Rock"]} = hd(charizard.effectiveness)
    end
  end

  describe "the Poké Alliance facts the entry carries" do
    @tag :tmp_dir
    test "an entry keeps its generation, tier, role, hp and experience" do
      bulbasaur = Pokedex.get("Bulbasaur")

      assert bulbasaur.generation == 1
      assert bulbasaur.tier == "6"
      assert bulbasaur.role == "PVE"
      assert bulbasaur.hp == 600
      assert bulbasaur.experience == 900
    end

    @tag :tmp_dir
    test "the two evolution directions carry the level and the items" do
      assert [%{name: "Ivysaur", level: 40, items: ["Leaf Stone"]}] =
               Pokedex.get("Bulbasaur").evolves_to

      assert Pokedex.get("Bulbasaur").evolves_from == []
    end

    @tag :tmp_dir
    test "wiki_url points at the species' own page on the Poké Alliance" do
      assert Pokedex.wiki_url(Pokedex.get("Bulbasaur")) ==
               "https://wiki.pokealliance.com/gen/1/001_bulbasaur"
    end
  end

  describe "multi-value filters — OR within a group, AND between groups" do
    @tag :tmp_dir
    test "elements: [Grass, Water] is the union" do
      names = Pokedex.search(%{elements: ["Grass", "Water"]}) |> Enum.map(& &1.name)

      assert "Bulbasaur" in names
      assert "Piplup" in names
      refute "Charizard" in names
    end

    @tag :tmp_dir
    test "an empty list is a disabled filter" do
      assert length(Pokedex.search(%{elements: []})) == length(Pokedex.search(%{}))
    end

    @tag :tmp_dir
    test "different groups still compose with AND" do
      names =
        Pokedex.search(%{elements: ["Grass", "Water"], min_level: 30})
        |> Enum.map(& &1.name)

      assert "Shiny Bulbasaur" in names
      refute "Bulbasaur" in names
    end

    @tag :tmp_dir
    test "weak_to as a list matches weakness to any of the elements" do
      names = Pokedex.search(%{weak_to: ["Rock", "Electric"]}) |> Enum.map(& &1.name)

      assert "Charizard" in names
      assert "Piplup" in names
    end

    @tag :tmp_dir
    test "the old singular keys still work (bookmarked URLs)" do
      assert Pokedex.search(%{element: "Water"}) |> Enum.map(& &1.name) == ["Piplup"]
      assert Pokedex.search(%{weak_to: "Rock"}) |> Enum.map(& &1.name) == ["Charizard"]
    end
  end

  describe "search/1 — the Poké Alliance axes" do
    @tag :tmp_dir
    test "filters by generation" do
      assert Pokedex.search(%{generations: [4]}) |> Enum.map(& &1.name) == ["Piplup"]
    end

    @tag :tmp_dir
    test "filters by tier, including the named ones" do
      assert Pokedex.search(%{tiers: ["ULTIMATE"]}) |> Enum.map(& &1.name) == ["Charizard"]
    end

    @tag :tmp_dir
    test "filters by role" do
      names = Pokedex.search(%{roles: ["PVE"]}) |> Enum.map(& &1.name)

      refute "Piplup" in names
      assert "Bulbasaur" in names
    end

    @tag :tmp_dir
    test "filters by variant" do
      assert Pokedex.search(%{variant: "shiny"}) |> Enum.map(& &1.name) == ["Shiny Bulbasaur"]

      refute "Shiny Bulbasaur" in (Pokedex.search(%{variant: "normal"}) |> Enum.map(& &1.name))
    end

    @tag :tmp_dir
    test "an entry with no tier survives a search that does not filter on tier" do
      assert "Piplup" in (Pokedex.search(%{}) |> Enum.map(& &1.name))
    end

    @tag :tmp_dir
    test "search composes name, element, weakness and level filters" do
      assert [%{name: "Bulbasaur"}, %{name: "Shiny Bulbasaur"}] =
               Pokedex.search(%{name: "bulbasaur"})

      assert [%{name: "Charizard"}] = Pokedex.search(%{element: "Fire"})
      assert [%{name: "Charizard"}] = Pokedex.search(%{min_level: 60})
      assert [%{name: "Piplup"}] = Pokedex.search(%{max_level: 20, element: "Water"})
    end
  end

  describe "sorting" do
    @tag :tmp_dir
    test "level, element, weakness and shiny — and inversion" do
      names = Pokedex.search(%{sort: :level}) |> Enum.map(& &1.name)
      assert names == ["Bulbasaur", "Piplup", "Shiny Bulbasaur", "Charizard"]

      desc = Pokedex.search(%{sort: :level, desc: true}) |> Enum.map(& &1.name)
      assert hd(desc) == "Charizard"

      assert %{name: "Charizard", elements: ["Fire" | _]} =
               Pokedex.search(%{sort: :element}) |> hd()

      # by FIRST weakness, descending: Fire (the Bulbasaur pair) over Electric
      # (Charizard and Piplup), name breaking the tie
      assert %{name: "Shiny Bulbasaur"} = Pokedex.search(%{sort: :weak_to, desc: true}) |> hd()

      shiny_first = Pokedex.search(%{sort: :shiny}) |> Enum.map(& &1.name)
      assert hd(shiny_first) == "Shiny Bulbasaur"
    end

    @tag :tmp_dir
    test "sorting by tier puts ULTIMATE ahead of the numbered tiers" do
      assert Pokedex.search(%{sort: :tier}) |> hd() |> Map.get(:name) == "Charizard"
    end

    @tag :tmp_dir
    test "an entry with no tier sinks to the bottom in both directions" do
      assert Pokedex.search(%{sort: :tier}) |> List.last() |> Map.get(:name) == "Piplup"

      assert Pokedex.search(%{sort: :tier, desc: true}) |> List.last() |> Map.get(:name) ==
               "Piplup"
    end

    @tag :tmp_dir
    test "sorting by generation orders ascending by default" do
      assert Pokedex.search(%{sort: :generation}) |> List.last() |> Map.get(:name) == "Piplup"
    end
  end

  describe "variant_of/2" do
    @tag :tmp_dir
    test "finds a species' shiny by the number they share" do
      assert Pokedex.variant_of(Pokedex.get("Bulbasaur"), "shiny").name == "Shiny Bulbasaur"
    end

    @tag :tmp_dir
    test "finds the base form from the shiny" do
      assert Pokedex.variant_of(Pokedex.get("Shiny Bulbasaur"), "normal").name == "Bulbasaur"
    end

    @tag :tmp_dir
    test "a species with no shiny answers nil" do
      assert Pokedex.variant_of(Pokedex.get("Charizard"), "shiny") == nil
    end
  end

  describe "the filter option lists" do
    @tag :tmp_dir
    test "generations, tiers and roles come from the dataset, sorted and deduped" do
      assert Pokedex.generations() == [1, 4]
      assert Pokedex.tiers() == ["ULTIMATE", "5", "6"]
      assert Pokedex.roles() == ["PVE"]
    end

    @tag :tmp_dir
    test "elements are the eighteen canonical ones, not just what the dataset holds" do
      assert length(Pokedex.elements()) == 18
      assert "Steel" in Pokedex.elements()
    end
  end

  # scoring: +2 super-effective hit, -2 per resisted element, +1 when a shiny
  # variant exists; resisting everything disqualifies a target outright
  @tag :tmp_dir
  test "hunt_suggestions ranks who my team hits hard, and who hits back" do
    %{targets: targets, threats: threats} = Pokedex.hunt_suggestions(["Charizard"])

    # Charizard is Fire AND Flying, and Grass/Poison is weak to both: two hits
    # at +2 each, plus +1 for the shiny that exists
    assert [
             %{
               entry: %{name: "Bulbasaur"},
               member: "Charizard",
               hits: ["Fire", "Flying"],
               score: 5
             }
           ] = targets

    assert [%{entry: %{name: "Piplup"}, members: ["Charizard"], via: ["Water"]}] = threats
  end

  @tag :tmp_dir
  test "level window: targets near the player's strength; an empty window falls back to the closest below" do
    assert %{window: :all, targets: [%{entry: %{name: "Bulbasaur"}}]} =
             Pokedex.hunt_suggestions(["Charizard"])

    assert %{window: {:window, 1, 16}, targets: [%{entry: %{name: "Bulbasaur"}}]} =
             Pokedex.hunt_suggestions(["Charizard"], %{player_level: 1, level_margin: 15})

    assert %{window: {:below, 88}, targets: [%{entry: %{name: "Bulbasaur"}}]} =
             Pokedex.hunt_suggestions(["Charizard"], %{player_level: 88, level_margin: 5})
  end

  describe "page/3 — cursor (keyset) pagination" do
    # 250 species with heavy level ties: where pagination without a stable
    # tiebreaker duplicates or skips rows at the page turn
    defp big_dataset do
      species =
        for i <- 1..250 do
          species("Mon#{String.pad_leading("#{i}", 3, "0")}", %{
            "number" => i,
            # only 5 distinct levels → mass ties
            "level" => rem(i, 5) * 10 + 10
          })
        end

      %{"species" => species}
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
          level = if rem(i, 2) == 0, do: 50
          species("Mon#{String.pad_leading("#{i}", 3, "0")}", %{"number" => i, "level" => level})
        end

      File.write!(Path.join(tmp, "pokedex.json"), JSON.encode!(%{"species" => species}))

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
  test "reload swaps the cached dataset in place (the sync button's refresh)", %{tmp_dir: tmp} do
    assert Pokedex.get("Lapras") == nil

    bigger = update_in(@dataset["species"], &(&1 ++ [species("Lapras", %{"number" => 131})]))
    File.write!(Path.join(tmp, "pokedex.json"), JSON.encode!(bigger))

    assert :ok = Pokedex.reload()
    assert %{name: "Lapras", number: 131} = Pokedex.get("Lapras")
  end

  @tag :tmp_dir
  test "missing dataset degrades to empty, loaded? false" do
    Application.put_env(:pokex, :pokedex_path, "/nao/existe.json")
    refute Pokedex.loaded?()
    assert Pokedex.search(%{}) == []
  end
end
