defmodule Pokex.Pokedex.ScraperTest do
  use ExUnit.Case, async: true

  alias Pokex.Pokedex.Scraper

  # REAL pages downloaded from wiki.pokexgames.com on 2026-07-20 — these pin
  # the wiki's markup: if the wiki changes format, these break loudly here
  # instead of silently producing an empty/garbled pokedex.json.
  defp fixture(name), do: File.read!(Path.join("test/fixtures/pokedex", name))

  describe "parse_species/1 (real Seadra page)" do
    test "extracts the full attribute map" do
      assert {:ok, seadra} = Scraper.parse_species(fixture("seadra.html"))

      assert seadra.name == "Seadra"
      assert seadra.number == 117
      assert seadra.level == 50
      assert seadra.elements == ["Water"]
      assert seadra.boost == "Water Stone (5)"

      # "Muito Efetivo" = what hits IT hard (the weakness query's source)
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

      # the MediaWiki footer date, ISO — the edited_after filter's source
      assert seadra.edited_at == "2026-02-06"
    end

    test "a colheita completa: habilidades, matéria, pedras, descrição e efetividade neutra" do
      assert {:ok, seadra} = Scraper.parse_species(fixture("seadra.html"))

      assert seadra.habilidades == ["Surf", "Headbutt"]
      assert seadra.materia == "Seavell"
      assert seadra.evolution_stones == ["Water Stone", "Crystal Stone"]
      assert seadra.description =~ "farpas venenosas"
      assert "Normal" in seadra.neutral
      assert length(seadra.neutral) == 13
    end

    test "a tabela de MOVIMENTOS: M1..M8 + passiva, com cooldown, elemento, tags e level" do
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

      # a passiva: sem cooldown, sem level, marcada como Passive
      passive = List.last(seadra.moves)
      assert %{slot: "P", name: "Dragon Rage", cooldown_s: nil, element: "Dragon"} = passive
      assert "Passive" in passive.tags

      # cada M tem o elemento PRÓPRIO — Hydro Cannon é Water mesmo num pokémon Water
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
