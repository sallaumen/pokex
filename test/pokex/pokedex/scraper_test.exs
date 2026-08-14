defmodule Pokex.Pokedex.ScraperTest do
  use ExUnit.Case, async: true

  alias Pokex.Pokedex.Scraper

  # REAL pages downloaded from the PokeTibia wiki on 2026-07-20 — these pin
  # the wiki's markup: if the wiki changes format, these break loudly here
  # instead of silently producing an empty/garbled pokedex.json.
  defp fixture(name), do: File.read!(Path.join("test/fixtures/pokedex", name))

  describe "upsert/2 — novelty timestamps" do
    defp entry(name, extra \\ %{}) do
      Map.merge(
        %{
          name: name,
          number: 1,
          level: 10,
          elements: ["Water"],
          scraped_at: "2026-07-21T10:00:00Z"
        },
        extra
      )
    end

    test "a brand-new entry gets first_seen_at and changed_at from the current sync" do
      [seadra] = Scraper.upsert([], [entry("Seadra")])

      assert seadra.first_seen_at == "2026-07-21T10:00:00Z"
      assert seadra.changed_at == "2026-07-21T10:00:00Z"
    end

    test "a re-scrape without changes preserves both dates" do
      [old] = Scraper.upsert([], [entry("Seadra")])
      old_json = old |> JSON.encode!() |> JSON.decode!()

      [again] =
        Scraper.upsert([old_json], [entry("Seadra", %{scraped_at: "2026-07-22T10:00:00Z"})])

      assert again.first_seen_at == "2026-07-21T10:00:00Z"
      assert again.changed_at == "2026-07-21T10:00:00Z"
    end

    test "changed content moves changed_at but keeps first_seen_at" do
      [old] = Scraper.upsert([], [entry("Seadra")])
      old_json = old |> JSON.encode!() |> JSON.decode!()

      [changed] =
        Scraper.upsert(
          [old_json],
          [entry("Seadra", %{level: 55, scraped_at: "2026-07-22T10:00:00Z"})]
        )

      assert changed.first_seen_at == "2026-07-21T10:00:00Z"
      assert changed.changed_at == "2026-07-22T10:00:00Z"
    end

    test "entries untouched by a partial run stay intact" do
      [seadra] = Scraper.upsert([], [entry("Seadra")])
      seadra_json = seadra |> JSON.encode!() |> JSON.decode!()

      merged = Scraper.upsert([seadra_json], [entry("Horsea", %{number: 116})])

      assert length(merged) == 2
      assert Enum.find(merged, &(Map.get(&1, "name") == "Seadra")) == seadra_json
    end
  end

  describe "parse_species/1 (real Seadra page)" do
    # "Muito Efetivo" on the wiki = what hits the species hard (weak_to's source);
    # edited_at is the MediaWiki footer date (the edited_after filter's source)
    test "extracts the full attribute map" do
      assert {:ok, seadra} = Scraper.parse_species(fixture("seadra.html"))

      assert seadra.name == "Seadra"
      assert seadra.number == 117
      assert seadra.level == 50
      assert seadra.elements == ["Water"]
      assert seadra.boost == "Water Stone (5)"

      assert seadra.weak_to == ["Grass", "Electric"]
      assert seadra.resists == ["Fire", "Water", "Ice", "Steel"]

      assert seadra.evolutions == [
               %{name: "Horsea", level: 10},
               %{name: "Seadra", level: 50},
               %{name: "Kingdra", level: 100}
             ]

      assert seadra.sprite_url == "/images/f/f0/117_-_Seadra.gif"

      assert seadra.shiny == %{
               name: "Shiny Seadra",
               page: "/index.php/Shiny_Seadra",
               sprite_url: "/images/2/2a/117-Sh_Seadra.png"
             }

      assert seadra.edited_at == "2026-02-06"
    end

    test "harvests habilidades, matéria, stones, description and neutral effectiveness" do
      assert {:ok, seadra} = Scraper.parse_species(fixture("seadra.html"))

      assert seadra.habilidades == ["Surf", "Headbutt"]
      assert seadra.materia == "Seavell"
      assert seadra.evolution_stones == ["Water Stone", "Crystal Stone"]
      assert seadra.description =~ "farpas venenosas"
      assert "Normal" in seadra.neutral
      assert length(seadra.neutral) == 13
    end

    test "parses the moves table: M1..M8 plus passive, with cooldown, element, tags and level" do
      assert {:ok, seadra} = Scraper.parse_species(fixture("seadra.html"))
      assert length(seadra.moves) == 9

      assert %{
               slot: "M1",
               name: "Mud Shot",
               cooldown_s: 15,
               element: "Ground",
               level: 50
             } = m1 = hd(seadra.moves)

      assert "Damage" in m1.tags
      assert "Blind" in m1.tags

      passive = List.last(seadra.moves)
      assert %{slot: "P", name: "Dragon Rage", cooldown_s: nil, element: "Dragon"} = passive
      assert "Passive" in passive.tags

      assert %{name: "Hydro Cannon", cooldown_s: 45, element: "Water"} =
               Enum.find(seadra.moves, &(&1.name == "Hydro Cannon"))
    end

    test "a page without the Nome field is unrecognized" do
      assert Scraper.parse_species("<html><body>nada</body></html>") ==
               {:error, :unrecognized}
    end

    test "dual types split (the wiki writes 'Grass / Poison')" do
      html = ~s(<b>Nome:</b> Bulbasaur<br /><b>Elemento:</b> Grass / Poison<br />)
      assert {:ok, %{elements: ["Grass", "Poison"], edited_at: nil}} = Scraper.parse_species(html)
    end
  end

  describe "upsert/2" do
    test "fresh entries replace by name, everything else stays (mixed key styles)" do
      existing = [
        %{"name" => "Seadra", "level" => 50},
        %{"name" => "Horsea", "level" => 10}
      ]

      fresh = [%{name: "Seadra", level: 55, edited_at: "2026-07-01"}]

      merged = Scraper.upsert(existing, fresh)

      assert length(merged) == 2
      assert %{"name" => "Horsea", "level" => 10} in merged
      assert %{name: "Seadra", level: 55, edited_at: "2026-07-01"} in merged
      refute %{"name" => "Seadra", "level" => 50} in merged
    end
  end

  describe "parse_species/1 (real Sceptile page — PVE + PVP)" do
    # bold move names on the wiki (<b>Leafage (30s)</b>) once parsed as "Level 80" rows
    test "splits the two movesets: same moves, different cooldowns" do
      assert {:ok, sceptile} = Scraper.parse_species(fixture("sceptile.html"))

      assert length(sceptile.moves) == 8
      assert length(sceptile.moves_pvp) == 8

      assert %{slot: "M5", name: "Leafage", cooldown_s: 30, element: "Grass", level: 80} =
               Enum.find(sceptile.moves, &(&1.slot == "M5"))

      assert %{slot: "M5", name: "Leafage", cooldown_s: 50} =
               Enum.find(sceptile.moves_pvp, &(&1.slot == "M5"))

      refute Enum.any?(sceptile.moves, &String.starts_with?(&1.name, "Level"))
      assert %{element: "Dark"} = Enum.find(sceptile.moves, &(&1.name == "Night Slash"))
    end

    test "an old page with a single table parses all moves as PVE and leaves PVP empty" do
      assert {:ok, seadra} = Scraper.parse_species(fixture("seadra.html"))
      assert length(seadra.moves) == 9
      assert seadra.moves_pvp == []
    end

    test "harvests the wiki's element icons for the UI" do
      assert %{"Grass" => "/images/c/c5/Grass.png", "Dark" => _} =
               Scraper.element_icons(fixture("sceptile.html"))
    end
  end

  # The wiki is NOT one format: pages written in different eras name the same
  # sections differently. These two REAL pages pin the drifts that silently
  # emptied 202 entries' movesets and 345 entries' weaknesses (measured on the
  # 2026-07-21 base) — every variant below was copied from the live markup.
  describe "parse_species/1 (Venusaur — 'Movimentos_PvE/PvP' sections)" do
    # this page lists PVP before PVE; each moveset must land on its own side
    test "finds both movesets when the id is 'Movimentos_PvE' (not 'Moveset_PVE')" do
      assert {:ok, venusaur} = Scraper.parse_species(fixture("venusaur.html"))

      assert length(venusaur.moves) == 11
      assert length(venusaur.moves_pvp) == 11

      assert %{slot: "M5", name: "Leech Seed", cooldown_s: 20} =
               Enum.find(venusaur.moves, &(&1.slot == "M5"))

      assert %{slot: "M5", name: "Leech Seed", cooldown_s: 30} =
               Enum.find(venusaur.moves_pvp, &(&1.slot == "M5"))
    end

    # this page also lists two resistance tiers: Inefetivo + Muito Inefetivo
    test "weakness also comes from the 'Efetivo' tier (pages without 'Muito Efetivo')" do
      assert {:ok, venusaur} = Scraper.parse_species(fixture("venusaur.html"))

      assert venusaur.weak_to == ["Fire", "Ice", "Flying", "Psychic"]
      assert venusaur.resists == ["Water", "Electric", "Fighting", "Fairy", "Grass"]
      assert venusaur.immune == []
    end

    test "an evolution with lowercase 'level' still counts" do
      assert {:ok, venusaur} = Scraper.parse_species(fixture("venusaur.html"))
      assert %{name: "Venusaur", level: 80} in venusaur.evolutions
    end
  end

  describe "parse_species/1 (Florges — new-generation page)" do
    test "uppercase 'Movimentos_PVE' is also a moveset" do
      assert {:ok, florges} = Scraper.parse_species(fixture("florges.html"))

      assert length(florges.moves) == 9
      assert length(florges.moves_pvp) == 9

      assert %{slot: "M6", name: "Floral Storm", cooldown_s: 50} =
               Enum.find(florges.moves, &(&1.slot == "M6"))

      assert %{slot: "M6", name: "Floral Storm", cooldown_s: 60} =
               Enum.find(florges.moves_pvp, &(&1.slot == "M6"))
    end

    test "'Super efetivo' is a weakness and 'Nulo' becomes immunity" do
      assert {:ok, florges} = Scraper.parse_species(fixture("florges.html"))

      assert florges.weak_to == ["Poison", "Steel"]
      assert florges.resists == ["Fighting", "Bug", "Dark"]
      assert florges.immune == ["Dragon"]
    end

    test "the '671.Florges.png' sprite yields both number and image" do
      assert {:ok, florges} = Scraper.parse_species(fixture("florges.html"))

      assert florges.number == 671
      assert florges.sprite_url == "/images/5/55/671.Florges.png"
    end

    test "the last element in the list does not carry the trailing period" do
      assert {:ok, florges} = Scraper.parse_species(fixture("florges.html"))

      assert "Fairy" in florges.neutral
      refute "Fairy." in florges.neutral
    end

    test "parses evolutions written with lowercase 'precisa de level'" do
      assert {:ok, florges} = Scraper.parse_species(fixture("florges.html"))

      assert florges.evolutions == [
               %{name: "Flabébé", level: 20},
               %{name: "Floette", level: 50},
               %{name: "Florges", level: 100}
             ]
    end
  end

  describe "parse_species/1 — immunity on old pages" do
    test "a page without 'Nulo' returns an empty list, not nil" do
      assert {:ok, seadra} = Scraper.parse_species(fixture("seadra.html"))
      assert seadra.immune == []
    end
  end

  describe "parse_index/1 (real index slice)" do
    test "extracts number+name+page per species row, deduped" do
      entries = Scraper.parse_index(fixture("index_slice.html"))

      assert %{number: 117, name: "Seadra", page: "/index.php/Seadra"} in entries
      assert %{number: 116, name: "Horsea", page: "/index.php/Horsea"} in entries
      assert length(entries) == length(Enum.uniq_by(entries, & &1.name))
    end
  end

  describe "parse_lures/1 (real Fishing slice)" do
    test "extracts lure tiers with species names, shiny entries included" do
      lures = Scraper.parse_lures(fixture("fishing_slice.html"))
      names = Enum.map(lures, & &1.name)

      assert "No Lure" in names
      assert "Shrimp" in names

      shrimp = Enum.find(lures, &(&1.name == "Shrimp"))
      levels = Enum.map(shrimp.tiers, & &1.fishing_level)
      assert levels == Enum.sort(levels)

      all_names = Enum.flat_map(shrimp.tiers, & &1.pokemon)
      assert "Seadra" in all_names
      assert Enum.any?(all_names, &String.starts_with?(&1, "Shiny "))
    end
  end
end
