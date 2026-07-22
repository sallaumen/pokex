defmodule PokexWeb.TeamLiveTest do
  use PokexWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  @dataset %{
    "species" => [
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
        "name" => "Venusaur",
        "number" => 3,
        "level" => 60,
        "elements" => ["Grass"],
        "weak_to" => ["Fire"],
        "resists" => [],
        "evolutions" => [],
        "sprite" => nil,
        "shiny_of" => nil,
        "shiny_name" => "Shiny Venusaur"
      },
      %{
        "name" => "Caterpie",
        "number" => 10,
        "level" => 5,
        "elements" => ["Bug"],
        "weak_to" => ["Fire"],
        "resists" => [],
        "evolutions" => [],
        "sprite" => nil,
        "shiny_of" => nil,
        "shiny_name" => nil
      }
    ],
    "lures" => []
  }

  setup %{tmp_dir: tmp} do
    File.write!(Path.join(tmp, "pokedex.json"), JSON.encode!(@dataset))
    Application.put_env(:pokex, :pokedex_path, Path.join(tmp, "pokedex.json"))
    Application.put_env(:pokex, :home_dir, tmp)

    on_exit(fn ->
      Application.delete_env(:pokex, :pokedex_path)
      Application.delete_env(:pokex, :home_dir)
    end)

    :ok
  end

  @tag :tmp_dir
  test "time e banco: adicionar, mover entre listas, level por membro e remover", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/time")
    assert html =~ "cadastra teus Pokémon"

    view
    |> form("#team-add-form", %{"member" => "Charizard", "where" => "team"})
    |> render_submit()

    view
    |> form("#team-add-form", %{"member" => "Venusaur", "where" => "bank"})
    |> render_submit()

    assert view |> element("#team-list") |> render() =~ "Charizard"
    assert view |> element("#bank-list") |> render() =~ "Venusaur"

    # per-member level persists
    view
    |> element(~s(#team-list form[phx-change="set_level"]))
    |> render_change(%{"name" => "Charizard", "level" => "95"})

    assert [%{name: "Charizard", level: 95}] = Pokex.Pokedex.Team.members()

    # banco → time
    view |> element(~s(button[phx-value-name="Venusaur"][phx-value-to="team"])) |> render_click()
    assert view |> element("#team-list") |> render() =~ "Venusaur"
    refute view |> element("#bank-list") |> render() =~ "Venusaur"

    # nome desconhecido avisa sem tocar as listas
    view |> form("#team-add-form", %{"member" => "Digimon", "where" => "team"}) |> render_submit()
    assert render(view) =~ "não conheço"

    view |> element(~s(button[phx-click="remove"][phx-value-name="Charizard"])) |> render_click()
    refute view |> element("#team-list") |> render() =~ "Charizard"
  end

  @tag :tmp_dir
  test "sugestões respeitam a janela do meu level; lv-5 some quando estou forte", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/time")

    view
    |> form("#team-add-form", %{"member" => "Charizard", "where" => "team"})
    |> render_submit()

    # sem meu level: tudo compete — o lv 5 aparece
    targets = view |> element("#hunt-targets") |> render()
    assert targets =~ "Venusaur"
    assert targets =~ "Caterpie"

    # lv 65 ±15 → janela 50..80: só Venusaur; Caterpie (lv 5) some
    view
    |> form("#hunt-window-form", %{"player_level" => "65", "level_margin" => "15"})
    |> render_change()

    targets = view |> element("#hunt-targets") |> render()
    assert targets =~ "Venusaur"
    refute targets =~ "Caterpie"
    assert view |> element("#hunt-window-note") |> render() =~ "alvos entre lv 50 e 80"

    # lv 300: nada na janela → fallback abaixo, com a nota explicando
    view
    |> form("#hunt-window-form", %{"player_level" => "300", "level_margin" => "15"})
    |> render_change()

    assert view |> element("#hunt-window-note") |> render() =~ "ABAIXO do teu lv 300"
    assert view |> element("#hunt-targets") |> render() =~ "Venusaur"

    # cada sugestão é um link pra página individual
    assert has_element?(view, ~s(#hunt-targets a[href="/pokedex/Venusaur"]))
  end

  @tag :tmp_dir
  test "a página da lista linka pro /time e não tem mais o card do time", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/pokedex")
    assert has_element?(view, ~s(a[href="/time"]))
    refute html =~ "Meu Time"
    refute html =~ "cuidado — batem forte"
  end

  @tag :tmp_dir
  test "assigning a hotkey slot is what lets a combo swap by name", %{conn: conn, tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

    Pokex.Pokedex.Team.add("Charizard")

    {:ok, view, _html} = live(conn, ~p"/time")

    view
    |> element("#slot-form-Charizard")
    |> render_change(%{"name" => "Charizard", "slot" => "4"})

    assert Pokex.Pokedex.Team.slot_of("Charizard") == 4
    assert render(view) =~ "C+4"

    # clearing it takes the pokémon out of every combo's reach
    view
    |> element("#slot-form-Charizard")
    |> render_change(%{"name" => "Charizard", "slot" => ""})

    assert Pokex.Pokedex.Team.slot_of("Charizard") == nil
  end
end
