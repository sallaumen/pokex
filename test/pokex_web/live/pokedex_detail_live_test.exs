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
  test "a página individual mostra tudo do Pokémon: chips, fraquezas, iscas e shiny", %{
    conn: conn
  } do
    {:ok, view, html} = live(conn, ~p"/pokedex/Seadra")

    assert html =~ "Seadra"
    assert html =~ "#117"
    assert html =~ "lv 50"
    assert html =~ "boost +50 hp"
    assert html =~ "wiki editada em 2026-02-06"

    # weaknesses/resists in their sections
    assert view |> element("#entry-card") |> render() =~ "Grass"
    assert render(view) =~ "ele RESISTE"

    # fishable + the shiny cross-link
    assert view |> element("#entry-lures") |> render() =~ "Shrimp · pesca lv 50"
    assert view |> element("#entry-shiny-links") |> render() =~ "ver Shiny Seadra (lv 80)"
  end

  @tag :tmp_dir
  test "navegar entre páginas: card da lista → detalhe, evolução → detalhe, shiny → base", %{
    conn: conn
  } do
    # the list card is a real link now
    {:ok, list, _} = live(conn, ~p"/pokedex")
    assert has_element?(list, ~s(#pokedex-results a[href="/pokedex/Horsea"]))

    # evolution hop patches in place ("bem ágil")
    {:ok, view, _} = live(conn, ~p"/pokedex/Horsea")
    assert view |> element("#entry-evolutions") |> render() =~ "Seadra"

    view |> element(~s(#entry-evolutions a), "Seadra") |> render_click()
    assert_patch(view, "/pokedex/Seadra")
    assert render(view) =~ "ver Shiny Seadra"

    # the shiny page links back to the base form (name with a space, URL-encoded)
    {:ok, shiny, _} = live(conn, ~p"/pokedex/#{"Shiny Seadra"}")
    assert shiny |> element("#entry-shiny-links") |> render() =~ "forma base: Seadra"
  end

  @tag :tmp_dir
  test "nome desconhecido: aviso amigável com volta, sem crash", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/pokedex/Digimon")
    assert html =~ "Não achei"
    assert html =~ "Digimon"
    assert has_element?(view, ~s(a[href="/pokedex"]))
  end
end
