defmodule PokexWeb.PokedexDetailLiveTest do
  use PokexWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  @dataset %{
    "species" => [
      %{
        "name" => "Horsea",
        "number" => 116,
        "level" => 20,
        "elements" => ["Water"],
        "weak_to" => ["Grass", "Electric"],
        "resists" => ["Fire", "Water"],
        "evolutions" => [%{"name" => "Seadra", "level" => 50}],
        "sprite" => nil,
        "shiny_of" => nil,
        "shiny_name" => nil
      },
      %{
        "name" => "Seadra",
        "number" => 117,
        "level" => 50,
        "elements" => ["Water"],
        "weak_to" => ["Grass", "Electric"],
        "resists" => ["Fire"],
        "neutral" => ["Normal", "Fighting"],
        "habilidades" => ["Surf", "Headbutt"],
        "materia" => "Seavell",
        "evolution_stones" => ["Water Stone", "Crystal Stone"],
        "description" => "As farpas venenosas em todo o corpo são altamente valorizadas.",
        "moves" => [
          %{
            "slot" => "M1",
            "name" => "Mud Shot",
            "cooldown_s" => 15,
            "element" => "Ground",
            "tags" => ["Target", "Focus Blocked", "Damage", "Blind"],
            "level" => 50
          },
          %{
            "slot" => "P",
            "name" => "Dragon Rage",
            "cooldown_s" => nil,
            "element" => "Dragon",
            "tags" => ["Passive", "Buff"],
            "level" => nil
          }
        ],
        "moves_pvp" => [
          %{
            "slot" => "M1",
            "name" => "Mud Shot",
            "cooldown_s" => 40,
            "element" => "Ground",
            "tags" => ["Damage"],
            "level" => 50
          }
        ],
        "evolutions" => [],
        "sprite" => nil,
        "shiny_of" => nil,
        "shiny_name" => "Shiny Seadra",
        "edited_at" => "2026-02-06",
        "boost" => "+50 hp"
      },
      %{
        "name" => "Shiny Seadra",
        "number" => 117,
        "level" => 80,
        "elements" => ["Water"],
        "weak_to" => ["Grass"],
        "resists" => [],
        "evolutions" => [],
        "sprite" => nil,
        "shiny_of" => "Seadra",
        "shiny_name" => nil
      },
      %{
        "name" => "Charizard",
        "number" => 6,
        "level" => 100,
        "elements" => ["Fire"],
        "weak_to" => ["Water"],
        "resists" => [],
        "evolutions" => [],
        "sprite" => nil,
        "shiny_of" => nil,
        "shiny_name" => nil
      },
      %{
        "name" => "Dragonite",
        "number" => 149,
        "level" => 100,
        "elements" => ["Dragon"],
        "weak_to" => ["Ice"],
        "resists" => [],
        "evolutions" => [],
        "sprite" => nil,
        "shiny_of" => nil,
        "shiny_name" => nil
      },
      %{
        "name" => "Florges",
        "number" => 671,
        "level" => 100,
        "elements" => ["Fairy"],
        "weak_to" => ["Poison", "Steel"],
        "resists" => ["Fighting", "Bug", "Dark", "Grass"],
        "immune" => ["Dragon"],
        "effectiveness" => [
          %{"label" => "Super efetivo", "kind" => "weak", "elements" => ["Poison", "Steel"]},
          %{"label" => "Inefetivo", "kind" => "resists", "elements" => ["Grass"]},
          %{
            "label" => "Muito inefetivo",
            "kind" => "resists",
            "elements" => ["Fighting", "Bug", "Dark"]
          },
          %{"label" => "Nulo", "kind" => "immune", "elements" => ["Dragon"]}
        ],
        "evolutions" => [],
        "moves" => [%{"slot" => "M1", "name" => "Tackle", "cooldown_s" => 8, "tags" => []}],
        "sprite" => nil,
        "shiny_of" => nil,
        "shiny_name" => nil
      },
      %{
        "name" => "Venusaur",
        "number" => 3,
        "level" => 60,
        "elements" => ["Grass"],
        "weak_to" => ["Fire"],
        "resists" => [],
        "evolutions" => [],
        "sprite" => nil,
        "shiny_of" => nil,
        "shiny_name" => nil
      }
    ],
    "lures" => [
      %{
        "name" => "Shrimp",
        "tiers" => [%{"fishing_level" => 50, "pokemon" => ["Seadra"]}]
      }
    ]
  }

  setup %{tmp_dir: tmp} do
    path = Path.join(tmp, "pokedex.json")
    File.write!(path, JSON.encode!(@dataset))
    Application.put_env(:pokex, :pokedex_path, path)
    Application.put_env(:pokex, :home_dir, tmp)

    on_exit(fn ->
      Application.delete_env(:pokex, :pokedex_path)
      Application.delete_env(:pokex, :home_dir)
    end)

    :ok
  end

  @tag :tmp_dir
  test "the detail page shows everything: chips, weaknesses, lures and shiny", %{
    conn: conn
  } do
    {:ok, view, html} = live(conn, ~p"/pokedex/Seadra")

    assert html =~ "Seadra"
    assert html =~ "#117"
    assert html =~ "lv 50"
    assert html =~ "boost +50 hp"
    assert html =~ "wiki editada em 2026-02-06"

    assert view |> element("#entry-card") |> render() =~ "Grass"
    assert render(view) =~ "ele RESISTE"

    assert view |> element("#entry-lures") |> render() =~ "Shrimp · lv 50"
    assert view |> element("#entry-shiny-links") |> render() =~ "ver Shiny Seadra (lv 80)"
  end

  @tag :tmp_dir
  test "navigation: list card → detail, evolution → detail, shiny → base form", %{
    conn: conn
  } do
    {:ok, list, _} = live(conn, ~p"/pokedex")
    assert has_element?(list, ~s(#pokedex-results a[href="/pokedex/Horsea"]))

    {:ok, view, _} = live(conn, ~p"/pokedex/Horsea")
    assert view |> element("#entry-evolutions") |> render() =~ "Seadra"

    view |> element(~s(#entry-evolutions a), "Seadra") |> render_click()
    assert_patch(view, "/pokedex/Seadra")
    assert render(view) =~ "ver Shiny Seadra"

    {:ok, shiny, _} = live(conn, ~p"/pokedex/#{"Shiny Seadra"}")
    assert shiny |> element("#entry-shiny-links") |> render() =~ "forma base: Seadra"
  end

  @tag :tmp_dir
  test "my-team context: matchup both ways, badge, and adding straight from the page", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/pokedex/Charizard")
    assert render(view) =~ "cadastra teu time"

    view |> element(~s(button[phx-value-where="team"])) |> render_click()
    assert view |> element("#membership-badge") |> render() =~ "no teu time"
    assert [%{name: "Charizard"}] = Pokex.Pokedex.Team.members()

    {:ok, venu, _} = live(conn, ~p"/pokedex/Venusaur")
    matchup = venu |> element("#entry-matchup") |> render()
    assert matchup =~ "Charizard"
    assert matchup =~ "fere ele com Fire"

    {:ok, _} = Pokex.Pokedex.Team.add("Venusaur", :team)
    {:ok, chari, _} = live(conn, ~p"/pokedex/Charizard")
    matchup = chari |> element("#entry-matchup") |> render()
    assert matchup =~ "Venusaur"
    assert matchup =~ "APANHA de Fire"

    {:ok, horsea, _} = live(conn, ~p"/pokedex/Horsea")
    horsea |> element(~s(button[phx-value-where="bank"])) |> render_click()
    assert horsea |> element("#membership-badge") |> render() =~ "no teu banco"
  end

  @tag :tmp_dir
  test "jump box: jumps straight to another Pokémon; an unknown name warns", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/pokedex/Horsea")

    view |> form("#jump-form", %{"name" => "Seadra"}) |> render_submit()
    assert_patch(view, "/pokedex/Seadra")
    assert render(view) =~ "ver Shiny Seadra"

    view |> form("#jump-form", %{"name" => "Digimon"}) |> render_submit()
    assert view |> element("#jump-msg") |> render() =~ "não conheço"
  end

  @tag :tmp_dir
  test "the full harvest on the page: moves, habilidades, stones, description, neutral", %{
    conn: conn
  } do
    {:ok, view, html} = live(conn, ~p"/pokedex/Seadra")

    assert view |> element("#entry-description") |> render() =~ "farpas venenosas"

    moves = view |> element("#entry-moves") |> render()
    assert moves =~ "M1"
    assert moves =~ "Mud Shot"
    assert moves =~ "Ground"
    assert moves =~ "⏱ 15s"
    assert moves =~ "Blind"
    assert moves =~ "lv 50"
    assert moves =~ "Dragon Rage"
    assert moves =~ "Passive"
    refute moves =~ "Focus Blocked"

    info = view |> element("#entry-info") |> render()
    assert info =~ "Surf"
    assert info =~ "Water Stone"
    assert info =~ "Seavell"

    assert view |> element("#entry-neutral") |> render() =~ "Fighting"

    refute html =~ "antes da colheita"
    refute html =~ "sincroniza a wiki"
  end

  @tag :tmp_dir
  test "no moves in the JSON: points to the wiki instead of demanding a sync", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/pokedex/Horsea")

    refute has_element?(view, "#entry-moves")
    refute html =~ "sincroniza a wiki"
    refute html =~ "sincronização"

    missing = view |> element("#entry-moves-missing") |> render()
    assert missing =~ "sem tabela de golpes"
    assert missing =~ "https://wiki.pokexgames.com/index.php/Horsea"

    assert html =~ "Horsea"
    assert view |> element("#entry-evolutions") |> render() =~ "Seadra"
  end

  @tag :tmp_dir
  test "the clan appears in the header and clicks through to the filtered list", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/pokedex/Seadra")

    chip = view |> element("#entry-clans") |> render()
    assert chip =~ "Seavell"
    assert chip =~ "clans[]=Seavell"

    {:ok, shiny, _} = live(conn, ~p"/pokedex/#{"Shiny Seadra"}")
    assert shiny |> element("#entry-clans") |> render() =~ "Seavell"
  end

  @tag :tmp_dir
  test "every page links to the original wiki, with composite names URL-encoded", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/pokedex/Seadra")

    assert view |> element("#wiki-link") |> render() =~
             "https://wiki.pokexgames.com/index.php/Seadra"

    {:ok, shiny, _} = live(conn, ~p"/pokedex/#{"Shiny Seadra"}")

    assert shiny |> element("#wiki-link") |> render() =~
             "https://wiki.pokexgames.com/index.php/Shiny_Seadra"
  end

  @tag :tmp_dir
  test "effectiveness: tiers labeled when the wiki has two, and what is Nulo against it", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/pokedex/Florges")

    card = view |> element("#entry-card") |> render()
    assert card =~ "Inefetivo"
    assert card =~ "Muito inefetivo"
    refute card =~ "Super efetivo"

    assert view |> element("#entry-immune") |> render() =~ "Dragon"
  end

  @tag :tmp_dir
  test "matchup warns when my pokémon's element is null against the target", %{conn: conn} do
    {:ok, _} = Pokex.Pokedex.Team.add("Dragonite", :team)

    {:ok, view, _} = live(conn, ~p"/pokedex/Florges")
    matchup = view |> element("#entry-matchup") |> render()

    assert matchup =~ "Dragonite"
    assert matchup =~ "Dragon não fere ele"
  end

  @tag :tmp_dir
  test "unknown name: friendly notice with a way back, no crash", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/pokedex/Digimon")
    assert html =~ "Não achei"
    assert html =~ "Digimon"
    assert has_element?(view, ~s(a[href="/pokedex"]))
  end
end
