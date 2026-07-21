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
        "shiny_name" => "Shiny Seadra",
        "edited_at" => "2026-02-06"
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
        "shiny_name" => "Shiny Venusaur"
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
    # the team file lives under the Pokex home — scope it too
    Application.put_env(:pokex, :home_dir, tmp)

    on_exit(fn ->
      Application.delete_env(:pokex, :pokedex_path)
      Application.delete_env(:pokex, :home_dir)
    end)

    %{path: path}
  end

  @tag :tmp_dir
  test "lists everything on mount and filters by weakness", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/pokedex")

    assert html =~ "Seadra"
    assert html =~ "Charizard"
    assert html =~ "4 resultado(s)"

    view
    |> form("#pokedex-filter-form", %{"f" => %{"weak_to" => "Water"}})
    |> render_change()

    html = render(view)
    assert html =~ "1 resultado(s)"
    results = view |> element("#pokedex-results") |> render()
    assert results =~ "Charizard"
    refute results =~ "Shiny Seadra"
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
  test "filtros vivem na URL: mudar patcheia, link direto restaura, isca inclusa", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/pokedex")

    view |> form("#pokedex-filter-form", %{"f" => %{"weak_to" => "Water"}}) |> render_change()
    assert_patch(view, "/pokedex?weak_to=Water")
    assert render(view) =~ "1 resultado(s)"

    # a pasted/bookmarked link lands on the SAME view (o voltar do navegador idem)
    {:ok, view2, html2} = live(conn, ~p"/pokedex?weak_to=Water")
    assert html2 =~ "1 resultado(s)"
    assert view2 |> element("#pokedex-results") |> render() =~ "Charizard"

    # a visão por isca também é um link
    {:ok, view3, _} = live(conn, ~p"/pokedex?isca=Shrimp")
    assert view3 |> element("#lure-tiers") |> render() =~ "pesca lv 50"
    assert has_element?(view3, "#lure-shiny-count")

    # e o atalho "/" tem alvo na página
    assert has_element?(view3, "input[data-quick-search]")
  end

  @tag :tmp_dir
  test "o filtro por data de edição da wiki estreita os resultados", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/pokedex")

    view
    |> form("#pokedex-filter-form", %{"f" => %{"edited_after" => "2026-01-01"}})
    |> render_change()

    html = render(view)
    assert html =~ "1 resultado(s)"
    assert view |> element("#pokedex-results") |> render() =~ "Seadra"
  end

  @tag :tmp_dir
  test "ordenação pela URL: clicar ordena, clicar de novo inverte, e o filtro sobrevive", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/pokedex")

    view |> element(~s(#pokedex-sort button[phx-value-by="level"])) |> render_click()
    assert_patch(view, "/pokedex?sort=level")

    # o primeiro card é o de MENOR level (Seadra 50)
    assert view |> element("#pokedex-results li:first-child") |> render() =~ "Seadra"

    # clicar no ordenador ATIVO inverte a direção
    view |> element(~s(#pokedex-sort button[phx-value-by="level"])) |> render_click()
    assert_patch(view, "/pokedex?desc=1&sort=level")
    assert view |> element("#pokedex-results li:first-child") |> render() =~ "Charizard"

    # e a ordenação sobrevive a um filtro novo (os dois viajam na URL)
    view |> form("#pokedex-filter-form", %{"f" => %{"element" => "Water"}}) |> render_change()
    assert view |> element("#pokedex-sort button[phx-value-by='level']") |> render() =~ "↓"
    assert view |> element("#pokedex-count") |> render() =~ "resultado(s)"
  end

  @tag :tmp_dir
  test "novidades = frescor da wiki: badge NOVO e o chip que se recicla sozinho", %{
    conn: conn,
    path: path
  } do
    hoje = Date.utc_today()

    dataset =
      update_in(@dataset["species"], fn species ->
        Enum.map(species, fn
          # editado ontem na wiki → NOVO
          %{"name" => "Charizard"} = s ->
            Map.put(s, "edited_at", Date.to_iso8601(Date.add(hoje, -1)))

          # editado há 60 dias → sem badge
          %{"name" => "Venusaur"} = s ->
            Map.put(s, "edited_at", Date.to_iso8601(Date.add(hoje, -60)))

          s ->
            Map.delete(s, "edited_at")
        end)
      end)

    File.write!(path, JSON.encode!(dataset))
    Pokex.Pokedex.reload()

    {:ok, view, _} = live(conn, ~p"/pokedex")

    results = view |> element("#pokedex-results") |> render()
    assert results =~ "NOVO"
    # só o recém-editado carrega o badge
    assert Regex.scan(~r/NOVO/, results) |> length() == 1

    # o chip isola só as novidades da wiki
    view |> element(~s(#pokedex-sort button[phx-click="toggle_novelty"])) |> render_click()
    assert_patch(view, "/pokedex?novidades=true")

    assert render(view) =~ "1 resultado(s)"
    assert view |> element("#pokedex-results") |> render() =~ "Charizard"
  end

  @tag :tmp_dir
  test "scroll infinito: primeira leva de 100, carrega mais, e termina", %{conn: conn, path: path} do
    species =
      for i <- 1..250 do
        %{
          "name" => "Mon#{String.pad_leading("#{i}", 3, "0")}",
          "number" => i,
          "level" => 50,
          "elements" => ["Water"],
          "weak_to" => [],
          "resists" => [],
          "evolutions" => [],
          "sprite" => nil,
          "shiny_of" => nil,
          "shiny_name" => nil
        }
      end

    File.write!(path, JSON.encode!(%{"species" => species, "lures" => []}))
    Pokex.Pokedex.reload()

    {:ok, view, _} = live(conn, ~p"/pokedex")

    # a contagem fala do TOTAL, mas só 100 vieram
    assert view |> element("#pokedex-count") |> render() =~ "250 resultado(s)"
    assert view |> element("#pokedex-count") |> render() =~ "100 carregados"
    results = view |> element("#pokedex-results") |> render()
    assert results =~ "Mon001"
    refute results =~ "Mon101"

    # o gatilho do viewport está armado enquanto houver cursor
    assert has_element?(view, ~s(#pokedex-results[phx-viewport-bottom="load_more"]))

    # segunda leva (o botão dispara o MESMO evento do scroll)
    view |> element("#load-more") |> render_click()
    results = view |> element("#pokedex-results") |> render()
    assert results =~ "Mon101"
    assert view |> element("#pokedex-count") |> render() =~ "200 carregados"
    # o stream APENDA: o que já estava continua no DOM
    assert results =~ "Mon001"

    # terceira e última: cursor zera, gatilho e botão somem, marcador de fim entra
    view |> element("#load-more") |> render_click()
    assert view |> element("#pokedex-results") |> render() =~ "Mon250"
    refute has_element?(view, "#load-more")
    refute has_element?(view, ~s(#pokedex-results[phx-viewport-bottom="load_more"]))
    assert view |> element("#list-end") |> render() =~ "fim da lista (250)"
  end

  @tag :tmp_dir
  test "mudar o filtro RESETA a lista (não acumula com a anterior)", %{conn: conn, path: path} do
    species =
      for i <- 1..150 do
        %{
          "name" => "Mon#{String.pad_leading("#{i}", 3, "0")}",
          "number" => i,
          "level" => if(i <= 100, do: 10, else: 90),
          "elements" => ["Water"],
          "weak_to" => [],
          "resists" => [],
          "evolutions" => [],
          "sprite" => nil,
          "shiny_of" => nil,
          "shiny_name" => nil
        }
      end

    File.write!(path, JSON.encode!(%{"species" => species, "lures" => []}))
    Pokex.Pokedex.reload()

    {:ok, view, _} = live(conn, ~p"/pokedex")
    view |> element("#load-more") |> render_click()
    assert view |> element("#pokedex-results") |> render() =~ "Mon150"

    # filtro novo → lista nova, sem restos da anterior
    view |> form("#pokedex-filter-form", %{"f" => %{"min_level" => "90"}}) |> render_change()
    results = view |> element("#pokedex-results") |> render()
    assert results =~ "Mon101"
    refute results =~ "Mon001"
    assert view |> element("#pokedex-count") |> render() =~ "50 resultado(s)"
  end

  @tag :tmp_dir
  test "sync pela UI: trava de sync duplo, progresso ao vivo e done recarrega a base", %{
    conn: conn,
    path: path
  } do
    # occupy the sync slot: the click must NEVER reach the network in a test
    {:ok, holder} = Task.start(fn -> Process.sleep(:infinity) end)
    Process.register(holder, :pokedex_sync)
    on_exit(fn -> Process.exit(holder, :kill) end)

    {:ok, view, _} = live(conn, ~p"/pokedex")
    assert has_element?(view, "#sync-form button")

    view |> form("#sync-form", %{"only" => ""}) |> render_submit()
    assert render(view) =~ "já tem um sync rodando"

    # progress rides PubSub — any tab shows it
    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      "pokedex_sync",
      {:pokedex_sync, {:progress, "350/635 Snorlax"}}
    )

    assert render(view) =~ "350/635 Snorlax"

    # done: the sync task reloads the dataset; the page must pick the NEW base up
    bigger = update_in(@dataset["species"], &(&1 ++ [%{"name" => "Lapras", "number" => 131}]))
    File.write!(path, JSON.encode!(bigger))
    Pokex.Pokedex.reload()

    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      "pokedex_sync",
      {:pokedex_sync, {:done, %{updated: 2, base: 5, shinies: 1}}}
    )

    html = render(view)
    assert html =~ "sincronizado: 2 atualizadas"
    assert view |> element("#pokedex-results") |> render() =~ "Lapras"
  end

  @tag :tmp_dir
  test "sem dataset, aponta o mix pokedex.scrape", %{conn: conn} do
    Application.put_env(:pokex, :pokedex_path, "/nao/existe.json")
    {:ok, _view, html} = live(conn, ~p"/pokedex")
    assert html =~ "Sincronizar wiki"
  end
end
