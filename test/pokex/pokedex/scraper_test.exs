defmodule Pokex.Pokedex.ScraperTest do
  use ExUnit.Case, async: true

  alias Pokex.Pokedex.Scraper

  # REAL pages downloaded from wiki.pokexgames.com on 2026-07-20 — these pin
  # the wiki's markup: if the wiki changes format, these break loudly here
  # instead of silently producing an empty/garbled pokedex.json.
  defp fixture(name), do: File.read!(Path.join("test/fixtures/pokedex", name))

  describe "upsert/2 — carimbos de novidade" do
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

    test "entrada inédita nasce com first_seen_at e changed_at do sync atual" do
      [seadra] = Scraper.upsert([], [entry("Seadra")])

      assert seadra.first_seen_at == "2026-07-21T10:00:00Z"
      assert seadra.changed_at == "2026-07-21T10:00:00Z"
    end

    test "re-scrape SEM mudança preserva as duas datas (não é novidade)" do
      [old] = Scraper.upsert([], [entry("Seadra")])
      old_json = old |> JSON.encode!() |> JSON.decode!()

      [again] =
        Scraper.upsert([old_json], [entry("Seadra", %{scraped_at: "2026-07-22T10:00:00Z"})])

      assert again.first_seen_at == "2026-07-21T10:00:00Z"
      assert again.changed_at == "2026-07-21T10:00:00Z"
    end

    test "conteúdo alterado move changed_at, mas first_seen_at fica" do
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

    test "entradas não tocadas pelo run parcial continuam intactas" do
      [seadra] = Scraper.upsert([], [entry("Seadra")])
      seadra_json = seadra |> JSON.encode!() |> JSON.decode!()

      merged = Scraper.upsert([seadra_json], [entry("Horsea", %{number: 116})])

      assert length(merged) == 2
      assert Enum.find(merged, &(Map.get(&1, "name") == "Seadra")) == seadra_json
    end
  end

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

  describe "parse_species/1 (real Sceptile page — PVE + PVP)" do
    test "separa os dois movesets: MESMOS golpes, cooldowns DIFERENTES" do
      assert {:ok, sceptile} = Scraper.parse_species(fixture("sceptile.html"))

      assert length(sceptile.moves) == 8
      assert length(sceptile.moves_pvp) == 8

      # o PVE (caçada) é o que vale pro bot
      assert %{slot: "M5", name: "Leafage", cooldown_s: 30, element: "Grass", level: 80} =
               Enum.find(sceptile.moves, &(&1.slot == "M5"))

      # mesmo golpe, cooldown de PVP
      assert %{slot: "M5", name: "Leafage", cooldown_s: 50} =
               Enum.find(sceptile.moves_pvp, &(&1.slot == "M5"))

      # nomes em NEGRITO na wiki (<b>Leafage (30s)</b>) não viram "Level 80"
      refute Enum.any?(sceptile.moves, &String.starts_with?(&1.name, "Level"))
      # e o elemento é o do GOLPE (Night Slash é Dark num Pokémon Grass)
      assert %{element: "Dark"} = Enum.find(sceptile.moves, &(&1.name == "Night Slash"))
    end

    test "página antiga com tabela única: tudo vira PVE, PVP vazio" do
      assert {:ok, seadra} = Scraper.parse_species(fixture("seadra.html"))
      assert length(seadra.moves) == 9
      assert seadra.moves_pvp == []
    end

    test "colhe os ícones de elemento da wiki pra UI" do
      assert %{"Grass" => "/images/c/c5/Grass.png", "Dark" => _} =
               Scraper.element_icons(fixture("sceptile.html"))
    end
  end

  # The wiki is NOT one format: pages written in different eras name the same
  # sections differently. These two REAL pages pin the drifts that silently
  # emptied 202 entries' movesets and 345 entries' weaknesses (measured on the
  # 2026-07-21 base) — every variant below was copied from the live markup.
  describe "parse_species/1 (Venusaur — seções 'Movimentos_PvE/PvP')" do
    test "acha os dois movesets mesmo com o id em 'Movimentos_PvE' (não 'Moveset_PVE')" do
      assert {:ok, venusaur} = Scraper.parse_species(fixture("venusaur.html"))

      assert length(venusaur.moves) == 11
      assert length(venusaur.moves_pvp) == 11

      # a página lista o PVP ANTES do PVE — cada um tem que cair no seu lado
      assert %{slot: "M5", name: "Leech Seed", cooldown_s: 20} =
               Enum.find(venusaur.moves, &(&1.slot == "M5"))

      assert %{slot: "M5", name: "Leech Seed", cooldown_s: 30} =
               Enum.find(venusaur.moves_pvp, &(&1.slot == "M5"))
    end

    test "a fraqueza também vem do tier 'Efetivo' (páginas sem 'Muito Efetivo')" do
      assert {:ok, venusaur} = Scraper.parse_species(fixture("venusaur.html"))

      assert venusaur.weak_to == ["Fire", "Ice", "Flying", "Psychic"]
      # dois tiers de resistência na mesma página: Inefetivo + Muito Inefetivo
      assert venusaur.resists == ["Water", "Electric", "Fighting", "Fairy", "Grass"]
      assert venusaur.immune == []
    end

    test "evolução com 'level' minúsculo conta igual" do
      assert {:ok, venusaur} = Scraper.parse_species(fixture("venusaur.html"))
      assert %{name: "Venusaur", level: 80} in venusaur.evolutions
    end
  end

  describe "parse_species/1 (Florges — página da geração nova)" do
    test "'Movimentos_PVE' em caixa alta também é moveset" do
      assert {:ok, florges} = Scraper.parse_species(fixture("florges.html"))

      assert length(florges.moves) == 9
      assert length(florges.moves_pvp) == 9

      assert %{slot: "M6", name: "Floral Storm", cooldown_s: 50} =
               Enum.find(florges.moves, &(&1.slot == "M6"))

      assert %{slot: "M6", name: "Floral Storm", cooldown_s: 60} =
               Enum.find(florges.moves_pvp, &(&1.slot == "M6"))
    end

    test "'Super efetivo' é fraqueza e 'Nulo' vira imunidade" do
      assert {:ok, florges} = Scraper.parse_species(fixture("florges.html"))

      assert florges.weak_to == ["Poison", "Steel"]
      assert florges.resists == ["Fighting", "Bug", "Dark"]
      assert florges.immune == ["Dragon"]
    end

    test "sprite '671.Florges.png' entrega número e imagem" do
      assert {:ok, florges} = Scraper.parse_species(fixture("florges.html"))

      assert florges.number == 671
      assert florges.sprite_url == "/images/5/55/671.Florges.png"
    end

    test "o último elemento da lista não carrega o ponto final" do
      assert {:ok, florges} = Scraper.parse_species(fixture("florges.html"))

      assert "Fairy" in florges.neutral
      refute "Fairy." in florges.neutral
    end

    test "evoluções com 'precisa de level' minúsculo" do
      assert {:ok, florges} = Scraper.parse_species(fixture("florges.html"))

      assert florges.evolutions == [
               %{name: "Flabébé", level: 20},
               %{name: "Floette", level: 50},
               %{name: "Florges", level: 100}
             ]
    end
  end

  describe "parse_species/1 — imunidade nas páginas antigas" do
    test "página sem 'Nulo' devolve lista vazia, não nil" do
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
