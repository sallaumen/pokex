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
        "materia" => "Seavell",
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
        "shiny_name" => nil,
        "materia" => "Volcanic Superior"
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
    test "the clan filter finds the members (inheriting shiny included)", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/pokedex?#{%{"clans" => ["Seavell"]}}")

      results = view |> element("#pokedex-results") |> render()
      assert results =~ "Seadra"
      assert results =~ "Shiny Seadra"
      refute results =~ "Charizard"
    end

    @tag :tmp_dir
    test "an old URL with singular ?element= still filters", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/pokedex?element=Water")

      results = view |> element("#pokedex-results") |> render()
      assert results =~ "Seadra"
      refute results =~ "Charizard"
    end

    @tag :tmp_dir
    test "the card shows the Pokémon's clan", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/pokedex?#{%{"name" => "Charizard"}}")

      assert view |> element("#pokedex-results") |> render() =~ "Volcanic"
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
  test "only shinies + the per-lure view highlighting the shinies", %{conn: conn} do
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
  test "filters live in the URL: changes patch, a direct link restores, lure included", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/pokedex")

    view |> element(~s(#filter-weak-to button[phx-value-option="Water"])) |> render_click()
    assert_patch(view, "/pokedex?weak_to[]=Water")
    assert render(view) =~ "1 resultado(s)"

    {:ok, view2, html2} = live(conn, ~p"/pokedex?weak_to=Water")
    assert html2 =~ "1 resultado(s)"
    assert view2 |> element("#pokedex-results") |> render() =~ "Charizard"

    {:ok, view3, _} = live(conn, ~p"/pokedex?isca=Shrimp")
    assert view3 |> element("#lure-tiers") |> render() =~ "pesca lv 50"
    assert has_element?(view3, "#lure-shiny-count")

    assert has_element?(view3, "input[data-quick-search]")
  end

  @tag :tmp_dir
  test "the wiki edit-date filter narrows the results", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/pokedex")

    view
    |> form("#pokedex-filter-form", %{"f" => %{"edited_after" => "2026-01-01"}})
    |> render_change()

    html = render(view)
    assert html =~ "1 resultado(s)"
    assert view |> element("#pokedex-results") |> render() =~ "Seadra"
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
  test "novelty = wiki freshness: the NOVO badge and the self-recycling chip", %{
    conn: conn,
    path: path
  } do
    hoje = Date.utc_today()

    dataset =
      update_in(@dataset["species"], fn species ->
        Enum.map(species, fn
          %{"name" => "Charizard"} = s ->
            Map.put(s, "edited_at", Date.to_iso8601(Date.add(hoje, -1)))

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
    assert Regex.scan(~r/NOVO/, results) |> length() == 1

    view |> element(~s(#pokedex-sort button[phx-click="toggle_novelty"])) |> render_click()
    assert_patch(view, "/pokedex?novidades=true")

    assert render(view) =~ "1 resultado(s)"
    assert view |> element("#pokedex-results") |> render() =~ "Charizard"
  end

  @tag :tmp_dir
  test "infinite scroll: first batch of 100, loads more, then ends", %{conn: conn, path: path} do
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
  test "without a dataset, offers the wiki sync", %{conn: conn} do
    Application.put_env(:pokex, :pokedex_path, "/nao/existe.json")
    {:ok, _view, html} = live(conn, ~p"/pokedex")
    assert html =~ "Sincronizar wiki"
  end
end
