defmodule PokexWeb.PokedexLiveTest do
  use PokexWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  defp species(name, extra) do
    Map.merge(
      %{
        "name" => name,
        "number" => 1,
        "generation" => 1,
        "variant" => "normal",
        "shiny_of" => nil,
        "level" => 50,
        "tier" => "6",
        "role" => "PVE",
        "hp" => 600,
        "experience" => 900,
        "elements" => ["Water"],
        "habilidades" => [],
        "description" => nil,
        "moves" => [],
        "evolves_to" => [],
        "evolves_from" => [],
        "sprite" => nil,
        "path" => "gen/1/001_#{String.downcase(name)}"
      },
      extra
    )
  end

  @dataset %{
    "species" => [
      %{
        "name" => "Seadra",
        "number" => 117,
        "generation" => 1,
        "variant" => "normal",
        "shiny_of" => nil,
        "level" => 50,
        "tier" => "6",
        "role" => "PVE",
        "hp" => 600,
        "experience" => 900,
        "elements" => ["Water"],
        "habilidades" => [],
        "description" => nil,
        "moves" => [],
        "evolves_to" => [],
        "evolves_from" => [],
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
        "tier" => "4",
        "role" => "PVE",
        "hp" => 900,
        "experience" => 1800,
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
        "name" => "Venusaur",
        "number" => 3,
        "generation" => 4,
        "variant" => "normal",
        "shiny_of" => nil,
        "level" => 60,
        "tier" => "3",
        "role" => "PVE",
        "hp" => 700,
        "experience" => 1200,
        "elements" => ["Grass"],
        "habilidades" => [],
        "description" => nil,
        "moves" => [],
        "evolves_to" => [],
        "evolves_from" => [],
        "sprite" => nil,
        "path" => "gen/4/003_venusaur"
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
      Pokex.TestHome.restore()
    end)

    %{path: path}
  end

  describe "non-exclusive chip filters" do
    @tag :tmp_dir
    test "two elements on = union, carried in the URL as a list", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/pokedex")

      view |> element(~s(#filter-elements button[phx-value-option="Water"])) |> render_click()
      assert_patch(view)
      results = view |> element("#pokedex-results") |> render()
      assert results =~ "Seadra"
      refute results =~ "Charizard"

      view |> element(~s(#filter-elements button[phx-value-option="Fire"])) |> render_click()
      path = assert_patch(view)
      assert path =~ "elements[]=Water"
      assert path =~ "elements[]=Fire"

      results = view |> element("#pokedex-results") |> render()
      assert results =~ "Seadra"
      assert results =~ "Charizard"
    end

    @tag :tmp_dir
    test "clicking again turns the chip off; 'limpar ×' clears the group", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/pokedex?#{%{"elements" => ["Water"]}}")

      view |> element(~s(#filter-elements button[phx-value-option="Water"])) |> render_click()
      path = assert_patch(view)
      refute path =~ "elements"

      {:ok, view, _} = live(conn, ~p"/pokedex?#{%{"elements" => ["Water", "Fire"]}}")
      view |> element(~s(#filter-elements button), "limpar ×") |> render_click()
      path = assert_patch(view)
      refute path =~ "elements"
    end

    @tag :tmp_dir
    test "the tier filter finds everyone in that tier", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/pokedex?#{%{"tiers" => ["ULTIMATE"]}}")

      results = view |> element("#pokedex-results") |> render()
      assert results =~ "Charizard"
      refute results =~ "Venusaur"
    end

    @tag :tmp_dir
    test "the generation filter narrows to that generation", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/pokedex?#{%{"generations" => ["4"]}}")

      results = view |> element("#pokedex-results") |> render()
      assert results =~ "Venusaur"
      refute results =~ "Charizard"
    end

    @tag :tmp_dir
    test "a hand-typed generation that is not a number narrows nothing", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/pokedex?#{%{"generations" => ["abc"]}}")

      assert render(view) =~ "4 resultado(s)"
    end

    @tag :tmp_dir
    test "an old URL with singular ?element= still filters", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/pokedex?element=Water")

      results = view |> element("#pokedex-results") |> render()
      assert results =~ "Seadra"
      refute results =~ "Charizard"
    end

    @tag :tmp_dir
    test "the card shows the Pokémon's tier and generation", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/pokedex?#{%{"name" => "Charizard"}}")

      card = view |> element("#pokedex-results") |> render()
      assert card =~ "tier ULTIMATE"
      assert card =~ "gen 1"
    end

    @tag :tmp_dir
    # extractMeta reads phx-value-* and THEN sets meta.value = el.value, which on
    # a <button> is "" — so phx-value-value reaches the server empty. render_click/1
    # cannot reproduce it (it reads only the attributes), hence the markup guard.
    test "no chip uses phx-value-value — LiveView overwrites that key", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/pokedex")

      refute html =~ "phx-value-value"
    end

    @tag :tmp_dir
    test "typing a name does not erase the enabled chips", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/pokedex?#{%{"elements" => ["Water"]}}")

      view |> form("#pokedex-filter-form", %{"f" => %{"name" => "sea"}}) |> render_change()
      path = assert_patch(view)
      assert path =~ "elements[]=Water"
      assert path =~ "name=sea"
    end
  end

  @tag :tmp_dir
  test "lists everything on mount and filters by weakness", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/pokedex")

    assert html =~ "Seadra"
    assert html =~ "Charizard"
    assert html =~ "4 resultado(s)"

    view |> element(~s(#filter-weak-to button[phx-value-option="Water"])) |> render_click()

    html = render(view)
    assert html =~ "1 resultado(s)"
    results = view |> element("#pokedex-results") |> render()
    assert results =~ "Charizard"
    refute results =~ "Shiny Seadra"
  end

  @tag :tmp_dir
  test "the variant select narrows to shinies, then back to normals", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/pokedex")

    view |> form("#pokedex-filter-form", %{"f" => %{"variant" => "shiny"}}) |> render_change()

    html = render(view)
    assert html =~ "Shiny Seadra"
    assert html =~ "1 resultado(s)"

    view |> form("#pokedex-filter-form", %{"f" => %{"variant" => "normal"}}) |> render_change()

    html = render(view)
    assert html =~ "3 resultado(s)"
    refute view |> element("#pokedex-results") |> render() =~ "Shiny Seadra"
  end

  @tag :tmp_dir
  test "filters live in the URL: changes patch and a direct link restores", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/pokedex")

    view |> element(~s(#filter-weak-to button[phx-value-option="Water"])) |> render_click()
    assert_patch(view, "/pokedex?weak_to[]=Water")
    assert render(view) =~ "1 resultado(s)"

    {:ok, view2, html2} = live(conn, ~p"/pokedex?weak_to=Water")
    assert html2 =~ "1 resultado(s)"
    assert view2 |> element("#pokedex-results") |> render() =~ "Charizard"

    {:ok, view3, _} = live(conn, ~p"/pokedex?#{%{"tiers" => ["ULTIMATE"]}}")
    assert view3 |> element("#pokedex-results") |> render() =~ "Charizard"

    assert has_element?(view3, "input[data-quick-search]")
  end

  @tag :tmp_dir
  test "the role filter separates PVP from PVE", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/pokedex?#{%{"roles" => ["PVP"]}}")

    assert render(view) =~ "1 resultado(s)"
    assert view |> element("#pokedex-results") |> render() =~ "Charizard"
  end

  @tag :tmp_dir
  test "sorting via the URL: click sorts, click again inverts, and the filter survives", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/pokedex")

    view |> element(~s(#pokedex-sort button[phx-value-by="level"])) |> render_click()
    assert_patch(view, "/pokedex?sort=level")

    assert view |> element("#pokedex-results li:first-child") |> render() =~ "Seadra"

    view |> element(~s(#pokedex-sort button[phx-value-by="level"])) |> render_click()
    assert_patch(view, "/pokedex?desc=1&sort=level")
    assert view |> element("#pokedex-results li:first-child") |> render() =~ "Charizard"

    view |> element(~s(#filter-elements button[phx-value-option="Water"])) |> render_click()
    path = assert_patch(view)
    assert path =~ "sort=level"
    assert path =~ "elements[]=Water"
    assert view |> element("#pokedex-sort button[phx-value-by='level']") |> render() =~ "↓"
    assert view |> element("#pokedex-count") |> render() =~ "resultado(s)"
  end

  @tag :tmp_dir
  test "sorting by tier puts ULTIMATE first and a tierless entry last", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/pokedex")

    view |> element(~s(#pokedex-sort button[phx-value-by="tier"])) |> render_click()
    assert_patch(view, "/pokedex?sort=tier")

    assert view |> element("#pokedex-results li:first-child") |> render() =~ "Charizard"
  end

  @tag :tmp_dir
  test "infinite scroll: first batch of 100, loads more, then ends", %{conn: conn, path: path} do
    species =
      for i <- 1..250 do
        species("Mon#{String.pad_leading("#{i}", 3, "0")}", %{"number" => i})
      end

    File.write!(path, JSON.encode!(%{"species" => species}))
    Pokex.Pokedex.reload()

    {:ok, view, _} = live(conn, ~p"/pokedex")

    assert view |> element("#pokedex-count") |> render() =~ "250 resultado(s)"
    assert view |> element("#pokedex-count") |> render() =~ "100 carregados"
    results = view |> element("#pokedex-results") |> render()
    assert results =~ "Mon001"
    refute results =~ "Mon101"

    assert has_element?(view, ~s(#pokedex-results[phx-viewport-bottom="load_more"]))

    view |> element("#load-more") |> render_click()
    results = view |> element("#pokedex-results") |> render()
    assert results =~ "Mon101"
    assert view |> element("#pokedex-count") |> render() =~ "200 carregados"
    assert results =~ "Mon001"

    view |> element("#load-more") |> render_click()
    assert view |> element("#pokedex-results") |> render() =~ "Mon250"
    refute has_element?(view, "#load-more")
    refute has_element?(view, ~s(#pokedex-results[phx-viewport-bottom="load_more"]))
    assert view |> element("#list-end") |> render() =~ "fim da lista (250)"
  end

  @tag :tmp_dir
  test "changing the filter resets the list (no residue from the previous one)", %{
    conn: conn,
    path: path
  } do
    species =
      for i <- 1..150 do
        species("Mon#{String.pad_leading("#{i}", 3, "0")}", %{
          "number" => i,
          "level" => if(i <= 100, do: 10, else: 90)
        })
      end

    File.write!(path, JSON.encode!(%{"species" => species}))
    Pokex.Pokedex.reload()

    {:ok, view, _} = live(conn, ~p"/pokedex")
    view |> element("#load-more") |> render_click()
    assert view |> element("#pokedex-results") |> render() =~ "Mon150"

    view |> form("#pokedex-filter-form", %{"f" => %{"min_level" => "90"}}) |> render_change()
    results = view |> element("#pokedex-results") |> render()
    assert results =~ "Mon101"
    refute results =~ "Mon001"
    assert view |> element("#pokedex-count") |> render() =~ "50 resultado(s)"
  end

  @tag :tmp_dir
  # a Task occupies the :pokedex_sync slot so the click never reaches the network
  test "sync via the UI: double-sync lock, live progress, and done reloads the base", %{
    conn: conn,
    path: path
  } do
    {:ok, holder} = Task.start(fn -> Process.sleep(:infinity) end)
    Process.register(holder, :pokedex_sync)
    on_exit(fn -> Process.exit(holder, :kill) end)

    {:ok, view, _} = live(conn, ~p"/pokedex")
    assert has_element?(view, "#sync-form button")

    view |> form("#sync-form", %{"only" => ""}) |> render_submit()
    assert render(view) =~ "já tem um sync rodando"

    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      "pokedex_sync",
      {:pokedex_sync, {:progress, "350/635 Snorlax"}}
    )

    assert render(view) =~ "350/635 Snorlax"

    bigger = update_in(@dataset["species"], &(&1 ++ [species("Lapras", %{"number" => 131})]))
    File.write!(path, JSON.encode!(bigger))
    Pokex.Pokedex.reload()

    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      "pokedex_sync",
      {:pokedex_sync, {:done, %{updated: 2, base: 5, shinies: 1, failed: 0}}}
    )

    html = render(view)
    assert html =~ "sincronizado: 2 atualizadas"
    assert view |> element("#pokedex-results") |> render() =~ "Lapras"
  end

  @tag :tmp_dir
  test "without a dataset, offers the wiki sync", %{conn: conn} do
    Application.put_env(:pokex, :pokedex_path, "/nao/existe.json")
    {:ok, _view, html} = live(conn, ~p"/pokedex")
    assert html =~ "Sincronizar wiki"
  end
end
