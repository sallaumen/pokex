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
  test "contexto do MEU time: matchup nos dois sentidos, badge e adicionar direto da página", %{
    conn: conn
  } do
    # time vazio → dica de cadastrar + botões de adicionar
    {:ok, view, _} = live(conn, ~p"/pokedex/Charizard")
    assert render(view) =~ "cadastra teu time"

    view |> element(~s(button[phx-value-where="team"])) |> render_click()
    assert view |> element("#membership-badge") |> render() =~ "no teu time"
    assert [%{name: "Charizard"}] = Pokex.Pokedex.Team.members()

    # na página do Venusaur: Charizard fere ele com Fire (e nada apanha)
    {:ok, venu, _} = live(conn, ~p"/pokedex/Venusaur")
    matchup = venu |> element("#entry-matchup") |> render()
    assert matchup =~ "Charizard"
    assert matchup =~ "fere ele com Fire"

    # Venusaur pro time: na página do Charizard ele deve APANHAR de Fire
    {:ok, _} = Pokex.Pokedex.Team.add("Venusaur", :team)
    {:ok, chari, _} = live(conn, ~p"/pokedex/Charizard")
    matchup = chari |> element("#entry-matchup") |> render()
    assert matchup =~ "Venusaur"
    assert matchup =~ "APANHA de Fire"

    # + banco direto da página
    {:ok, horsea, _} = live(conn, ~p"/pokedex/Horsea")
    horsea |> element(~s(button[phx-value-where="bank"])) |> render_click()
    assert horsea |> element("#membership-badge") |> render() =~ "no teu banco"
  end

  @tag :tmp_dir
  test "caixa de salto: pula direto pra outro Pokémon; desconhecido avisa", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/pokedex/Horsea")

    view |> form("#jump-form", %{"name" => "Seadra"}) |> render_submit()
    assert_patch(view, "/pokedex/Seadra")
    assert render(view) =~ "ver Shiny Seadra"

    view |> form("#jump-form", %{"name" => "Digimon"}) |> render_submit()
    assert view |> element("#jump-msg") |> render() =~ "não conheço"
  end

  @tag :tmp_dir
  test "a colheita completa na página: movimentos, habilidades, pedras, descrição, neutro", %{
    conn: conn
  } do
    {:ok, view, html} = live(conn, ~p"/pokedex/Seadra")

    # descrição como citação
    assert view |> element("#entry-description") |> render() =~ "farpas venenosas"

    # movimentos: slot, nome, elemento próprio, cooldown, tag e level
    moves = view |> element("#entry-moves") |> render()
    assert moves =~ "M1"
    assert moves =~ "Mud Shot"
    assert moves =~ "Ground"
    assert moves =~ "⏱ 15s"
    assert moves =~ "Blind"
    assert moves =~ "lv 50"
    # a passiva destacada, sem cooldown
    assert moves =~ "Dragon Rage"
    assert moves =~ "Passive"
    # ruído cortado: a tag "Focus Blocked" não polui a linha
    refute moves =~ "Focus Blocked"

    # habilidades & itens
    info = view |> element("#entry-info") |> render()
    assert info =~ "Surf"
    assert info =~ "Water Stone"
    assert info =~ "Seavell"

    # efetividade completa: o bucket neutro entra
    assert view |> element("#entry-neutral") |> render() =~ "Fighting"

    # nada de dica de re-sync numa entrada completa
    refute html =~ "antes da colheita"
  end

  @tag :tmp_dir
  test "entrada antiga (sem moves no JSON): dica de re-sync cirúrgico, sem crash", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/pokedex/Horsea")
    assert view |> element("#entry-moves-stale") |> render() =~ "sincroniza a wiki"
    refute has_element?(view, "#entry-moves")
  end

  @tag :tmp_dir
  test "nome desconhecido: aviso amigável com volta, sem crash", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/pokedex/Digimon")
    assert html =~ "Não achei"
    assert html =~ "Digimon"
    assert has_element?(view, ~s(a[href="/pokedex"]))
  end
end
