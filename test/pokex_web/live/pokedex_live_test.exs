defmodule PokexWeb.PokedexLiveTest do
  use PokexWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  @dataset %{
    "species" => [
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
        "shiny_name" => "Shiny Seadra"
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
      }
    ],
    "lures" => [
      %{
        "name" => "Shrimp",
        "tiers" => [
          %{"fishing_level" => 50, "pokemon" => ["Seadra"]},
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
  test "lists everything on mount and filters by weakness", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/pokedex")

    assert html =~ "Seadra"
    assert html =~ "Charizard"
    assert html =~ "3 resultado(s)"

    view
    |> form("#pokedex-filter-form", %{"f" => %{"weak_to" => "Water"}})
    |> render_change()

    html = render(view)
    assert html =~ "Charizard"
    refute html =~ "Shiny Seadra"
    assert html =~ "1 resultado(s)"
  end

  @tag :tmp_dir
  test "só shinies + a visão por isca destacando os shinies", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/pokedex")

    view
    |> form("#pokedex-filter-form", %{"f" => %{"only_shiny" => "true"}})
    |> render_change()

    html = render(view)
    assert html =~ "Shiny Seadra"
    assert html =~ "1 resultado(s)"

    view |> form("#lure-form", %{"lure" => "Shrimp"}) |> render_change()
    html = render(view)
    assert html =~ "pesca lv 50"
    assert html =~ "pesca lv 60"
    assert has_element?(view, "#lure-shiny-count")
    assert html =~ "1 shiny(s)"
  end

  @tag :tmp_dir
  test "sem dataset, aponta o mix pokedex.scrape", %{conn: conn} do
    Application.put_env(:pokex, :pokedex_path, "/nao/existe.json")
    {:ok, _view, html} = live(conn, ~p"/pokedex")
    assert html =~ "mix pokedex.scrape"
  end
end
