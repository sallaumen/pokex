defmodule PokexWeb.PokedexDetailLiveTest do
  use PokexWeb.ConnCase, async: false

  alias Pokex.Pokedex.Team
  import Phoenix.LiveViewTest

  # Derived from config `:wiki_base`, not hardcoded: the domain lives in exactly
  # one place, and pointing the app at another wiki must not break these.
  defp wiki_url(path),
    do: Application.get_env(:pokex, :wiki_base) <> "/" <> path

  @dataset %{
    "species" => [
      %{
        "name" => "Horsea",
        "number" => 116,
        "generation" => 1,
        "variant" => "normal",
        "shiny_of" => nil,
        "level" => 20,
        "tier" => "7",
        "role" => "PVE",
        "hp" => 300,
        "experience" => 400,
        "elements" => ["Water"],
        "habilidades" => [],
        "description" => nil,
        "moves" => [],
        "evolves_to" => [%{"name" => "Seadra", "level" => 50, "items" => ["Water Stone"]}],
        "evolves_from" => [],
        "sprite" => nil,
        "path" => "gen/1/116_horsea"
      },
      %{
        "name" => "Seadra",
        "number" => 117,
        "generation" => 1,
        "variant" => "normal",
        "shiny_of" => nil,
        "level" => 50,
        "tier" => "5",
        "role" => "PVE",
        "hp" => 1200,
        "experience" => 2400,
        "elements" => ["Water"],
        "habilidades" => ["Surf", "Headbutt"],
        "description" => "As farpas venenosas em todo o corpo são altamente valorizadas.",
        "moves" => [
          %{"slot" => "M1", "name" => "Mud Shot", "cooldown_s" => 15, "element" => "Ground"},
          %{"slot" => "M2", "name" => "Dragon Rage", "cooldown_s" => 30, "element" => "Dragon"}
        ],
        "evolves_to" => [],
        "evolves_from" => [%{"name" => "Horsea", "level" => 50, "items" => ["Water Stone"]}],
        "sprite" => nil,
        "path" => "gen/1/117_seadra"
      },
      %{
        "name" => "Shiny Seadra",
        "number" => 117,
        "generation" => 1,
        "variant" => "shiny",
        "shiny_of" => "Seadra",
        "level" => 80,
        "tier" => "3",
        "role" => "PVE",
        "hp" => 1800,
        "experience" => 4800,
        "elements" => ["Water"],
        "habilidades" => [],
        "description" => nil,
        "moves" => [],
        "evolves_to" => [],
        "evolves_from" => [],
        "sprite" => nil,
        "path" => "shiny/117_shiny_seadra"
      },
      %{
        "name" => "Charizard",
        "number" => 6,
        "generation" => 1,
        "variant" => "normal",
        "shiny_of" => nil,
        "level" => 100,
        "tier" => "ULTIMATE",
        "role" => "PVP",
        "hp" => 500,
        "experience" => 800,
        "elements" => ["Fire"],
        "habilidades" => [],
        "description" => nil,
        "moves" => [],
        "evolves_to" => [],
        "evolves_from" => [],
        "sprite" => nil,
        "path" => "gen/1/006_charizard"
      },
      %{
        "name" => "Dragonite",
        "number" => 149,
        "generation" => 1,
        "variant" => "normal",
        "shiny_of" => nil,
        "level" => 100,
        "tier" => "1",
        "role" => "PVE",
        "hp" => 2000,
        "experience" => 5000,
        "elements" => ["Dragon"],
        "habilidades" => [],
        "description" => nil,
        "moves" => [],
        "evolves_to" => [],
        "evolves_from" => [],
        "sprite" => nil,
        "path" => "gen/1/149_dragonite"
      },
      %{
        "name" => "Florges",
        "number" => 671,
        "generation" => 6,
        "variant" => "normal",
        "shiny_of" => nil,
        "level" => 100,
        "tier" => "2",
        "role" => "PVE",
        "hp" => 1500,
        "experience" => 3000,
        "elements" => ["Fairy"],
        "habilidades" => [],
        "description" => nil,
        "moves" => [%{"slot" => "M1", "name" => "Tackle", "cooldown_s" => 8, "element" => nil}],
        "evolves_to" => [],
        "evolves_from" => [],
        "sprite" => nil,
        "path" => "gen/6/671_florges"
      },
      %{
        "name" => "Venusaur",
        "number" => 3,
        "generation" => 1,
        "variant" => "normal",
        "shiny_of" => nil,
        "level" => 60,
        "tier" => "3",
        "role" => "PVE",
        "hp" => 700,
        "experience" => 1200,
        "elements" => ["Grass", "Poison"],
        "habilidades" => [],
        "description" => nil,
        "moves" => [],
        "evolves_to" => [],
        "evolves_from" => [],
        "sprite" => nil,
        "path" => "gen/1/003_venusaur"
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
      Pokex.TestHome.restore()
    end)

    :ok
  end

  @tag :tmp_dir
  test "the detail page shows the Poké Alliance facts, the weaknesses and the shiny", %{
    conn: conn
  } do
    {:ok, view, html} = live(conn, ~p"/pokedex/Seadra")

    assert html =~ "Seadra"
    assert html =~ "#117"
    assert html =~ "lv 50"
    assert html =~ "tier 5"
    assert html =~ "gen 1"
    assert html =~ "1200"
    assert html =~ "2400"
    assert html =~ "PVE"

    assert view |> element("#entry-card") |> render() =~ "Grass"
    assert render(view) =~ "ele RESISTE"

    assert view |> element("#entry-shiny-links") |> render() =~ "ver Shiny Seadra (lv 80)"
  end

  @tag :tmp_dir
  test "navigation: list card → detail, evolution → detail, shiny → base form", %{
    conn: conn
  } do
    {:ok, list, _} = live(conn, ~p"/pokedex")
    assert has_element?(list, ~s(#pokedex-results a[href="/pokedex/Horsea"]))

    {:ok, view, _} = live(conn, ~p"/pokedex/Horsea")
    evolutions = view |> element("#entry-evolutions") |> render()
    assert evolutions =~ "Seadra"
    assert evolutions =~ "evolui para"
    assert evolutions =~ "Water Stone"

    view |> element(~s(#entry-evolutions a), "Seadra") |> render_click()
    assert_patch(view, "/pokedex/Seadra")
    assert render(view) =~ "ver Shiny Seadra"
    assert view |> element("#entry-evolutions") |> render() =~ "evolui de"

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
    assert [%{name: "Charizard"}] = Team.members()

    {:ok, venu, _} = live(conn, ~p"/pokedex/Venusaur")
    matchup = venu |> element("#entry-matchup") |> render()
    assert matchup =~ "Charizard"
    assert matchup =~ "fere ele com Fire"

    {:ok, _} = Team.add("Venusaur", :team)
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
  test "the full harvest on the page: moves, habilidades, description, neutral", %{
    conn: conn
  } do
    {:ok, view, html} = live(conn, ~p"/pokedex/Seadra")

    assert view |> element("#entry-description") |> render() =~ "farpas venenosas"

    moves = view |> element("#entry-moves") |> render()
    assert moves =~ "M1"
    assert moves =~ "Mud Shot"
    assert moves =~ "Ground"
    assert moves =~ "⏱ 15s"
    assert moves =~ "Dragon Rage"

    assert view |> element("#entry-info") |> render() =~ "Surf"

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
    assert missing =~ wiki_url("gen/1/116_horsea")

    assert html =~ "Horsea"
    assert view |> element("#entry-evolutions") |> render() =~ "Seadra"
  end

  @tag :tmp_dir
  test "the tier and the generation click through to the filtered list", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/pokedex/Seadra")

    assert view |> element("#entry-tier") |> render() =~ "tiers[]=5"
    assert view |> element("#entry-generation") |> render() =~ "generations[]=1"
  end

  @tag :tmp_dir
  test "every page links to the wiki page it was harvested from", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/pokedex/Seadra")

    assert view |> element("#wiki-link") |> render() =~ wiki_url("gen/1/117_seadra")

    {:ok, shiny, _} = live(conn, ~p"/pokedex/#{"Shiny Seadra"}")

    assert shiny |> element("#wiki-link") |> render() =~ wiki_url("shiny/117_shiny_seadra")
  end

  @tag :tmp_dir
  test "effectiveness: two resistance tiers get their labels, and immunity gets its own row", %{
    conn: conn
  } do
    # Grass/Poison resists Water at half and Grass at a quarter — two tiers
    {:ok, venusaur, _} = live(conn, ~p"/pokedex/Venusaur")

    card = venusaur |> element("#entry-card") |> render()
    assert card =~ "Inefetivo"
    assert card =~ "Muito Inefetivo"

    # Fairy takes nothing at all from Dragon
    {:ok, florges, _} = live(conn, ~p"/pokedex/Florges")
    assert florges |> element("#entry-immune") |> render() =~ "Dragon"
  end

  @tag :tmp_dir
  test "matchup warns when my pokémon's element is null against the target", %{conn: conn} do
    {:ok, _} = Team.add("Dragonite", :team)

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
