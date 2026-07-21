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
  test "ordenação: level, tipo, fraqueza, shiny, edição da wiki — e inversão" do
    # ascending by level; entries WITHOUT a level sink to the bottom
    names = Pokedex.search(%{sort: :level}) |> Enum.map(& &1.name)
    assert names == ["Seadra", "Venusaur", "Shiny Seadra", "Charizard"]

    # descending flips only the ranked part — the level-less still sink
    desc = Pokedex.search(%{sort: :level, desc: true}) |> Enum.map(& &1.name)
    assert hd(desc) == "Charizard"

    # by element / by weakness (first value of each list)
    assert %{name: "Charizard", elements: ["Fire" | _]} =
             Pokedex.search(%{sort: :element}) |> hd()

    assert %{name: "Charizard"} = Pokedex.search(%{sort: :weak_to, desc: true}) |> hd()

    # shiny sort groups each variant beside its base form
    shiny_first = Pokedex.search(%{sort: :shiny}) |> Enum.map(& &1.name)
    assert hd(shiny_first) == "Shiny Seadra"

    # by the WIKI's edit date — only Seadra has one, so it leads
    assert %{name: "Seadra"} = Pokedex.search(%{sort: :edited}) |> hd()
  end

  @tag :tmp_dir
  test "novidade = frescor da WIKI (auto-recicla): dentro da janela, fora, e desconhecida",
       %{tmp_dir: tmp} do
    today = ~D[2026-07-21]

    dataset =
      update_in(@dataset["species"], fn species ->
        Enum.map(species, fn
          # editado ONTEM → novidade
          %{"name" => "Seadra"} = s -> Map.put(s, "edited_at", "2026-07-20")
          # editado há 30 dias → não é mais novidade (o tempo reciclou sozinho)
          %{"name" => "Charizard"} = s -> Map.put(s, "edited_at", "2026-06-21")
          # sem data conhecida → nunca é novidade
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

  describe "page/3 — paginação por cursor (keyset)" do
    # 250 espécies, MUITAS empatadas no mesmo level: é onde uma paginação sem
    # desempate estável duplica ou pula linhas na virada de página
    defp big_dataset do
      species =
        for i <- 1..250 do
          %{
            "name" => "Mon#{String.pad_leading("#{i}", 3, "0")}",
            "number" => i,
            # só 5 levels distintos → empates em massa
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
    test "percorre a base inteira em páginas, sem repetir nem pular", %{tmp_dir: tmp} do
      load_big(tmp)

      {all, pages} = drain(%{}, nil, [], 0)

      assert length(all) == 250
      assert Enum.uniq(all) == all
      # a ordem paginada é EXATAMENTE a da busca completa
      assert all == Enum.map(Pokedex.search(%{}), & &1.name)
      assert pages == 3
    end

    @tag :tmp_dir
    test "com empates no level (ordenação instável seria fatal) também fecha certo",
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
    test "cursor nil na última página; total é o filtrado, não o carregado", %{tmp_dir: tmp} do
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
    test "o filtro entra na paginação (total e páginas seguem o filtro)", %{tmp_dir: tmp} do
      load_big(tmp)

      page = Pokedex.page(%{min_level: 50}, nil, 100)
      assert page.total == 50
      assert length(page.entries) == 50
      assert page.cursor == nil
      assert Enum.all?(page.entries, &(&1.level >= 50))
    end

    @tag :tmp_dir
    test "entradas SEM valor de ordenação continuam no fim, e paginam", %{tmp_dir: tmp} do
      # metade sem level: o bucket dos ausentes tem que ser atravessado também
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

    # walks every page, accumulating names in order
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
