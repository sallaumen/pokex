defmodule PokexWeb.TeamLiveTest do
  use PokexWeb.ConnCase, async: false

  alias Pokex.Bots.Cavebot.Route
  alias Pokex.Bots.Cavebot.Store, as: RouteStore
  alias Pokex.Pokedex.Team
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
  test "team and bank: add, move between lists, per-member level, and remove", %{conn: conn} do
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

    view
    |> element(~s(#team-list form[phx-change="set_level"]))
    |> render_change(%{"name" => "Charizard", "level" => "95"})

    assert [%{name: "Charizard", level: 95}] = Team.members()

    view |> element(~s(button[phx-value-name="Venusaur"][phx-value-to="team"])) |> render_click()
    assert view |> element("#team-list") |> render() =~ "Venusaur"
    refute view |> element("#bank-list") |> render() =~ "Venusaur"

    view |> form("#team-add-form", %{"member" => "Digimon", "where" => "team"}) |> render_submit()
    assert render(view) =~ "não conheço"

    view |> element(~s(button[phx-click="remove"][phx-value-name="Charizard"])) |> render_click()
    refute view |> element("#team-list") |> render() =~ "Charizard"
  end

  @tag :tmp_dir
  test "suggestions respect my level window; the lv-5 disappears when I am strong", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/time")

    view
    |> form("#team-add-form", %{"member" => "Charizard", "where" => "team"})
    |> render_submit()

    targets = view |> element("#hunt-targets") |> render()
    assert targets =~ "Venusaur"
    assert targets =~ "Caterpie"

    view
    |> form("#hunt-window-form", %{"player_level" => "65", "level_margin" => "15"})
    |> render_change()

    targets = view |> element("#hunt-targets") |> render()
    assert targets =~ "Venusaur"
    refute targets =~ "Caterpie"
    assert view |> element("#hunt-window-note") |> render() =~ "alvos entre lv 50 e 80"

    view
    |> form("#hunt-window-form", %{"player_level" => "300", "level_margin" => "15"})
    |> render_change()

    assert view |> element("#hunt-window-note") |> render() =~ "ABAIXO do teu lv 300"
    assert view |> element("#hunt-targets") |> render() =~ "Venusaur"

    assert has_element?(view, ~s(#hunt-targets a[href="/pokedex/Venusaur"]))
  end

  @tag :tmp_dir
  test "the list page links to /time and no longer carries the team card", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/pokedex")
    assert has_element?(view, ~s(a[href="/time"]))
    refute html =~ "Meu Time"
    refute html =~ "cuidado — batem forte"
  end

  @tag :tmp_dir
  test "the portrait section explains WHY the slot is not configurable", %{
    conn: conn,
    tmp_dir: tmp
  } do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

    {:ok, view, html} = live(conn, ~p"/time")

    assert has_element?(view, "#portraits")
    assert html =~ "ordem dos atalhos C+N muda"
    refute html =~ "slot-form-"
  end

  # A combo written as "aperta 4, depois 1, depois 3 e 5" only ever works for
  # the pokémon whose bar it was written against. Here each pokémon says what
  # ITS keys are for, so one written plan can drive all of them.
  describe "what each skill is for" do
    defp add!(view, name, where \\ "team") do
      view |> form("#team-add-form", %{"member" => name, "where" => where}) |> render_submit()
    end

    @tag :tmp_dir
    test "the editor opens on ONE pokémon at a time", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/time")
      add!(view, "Charizard")
      add!(view, "Venusaur")

      refute has_element?(view, "#skills-form-Charizard")

      view |> element("#skills-toggle-Charizard") |> render_click()
      assert has_element?(view, "#skills-form-Charizard")
      refute has_element?(view, "#skills-form-Venusaur")

      view |> element("#skills-toggle-Charizard") |> render_click()
      refute has_element?(view, "#skills-form-Charizard")
    end

    @tag :tmp_dir
    test "a job saves, shows in the summary, and MOVES when reassigned", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/time")
      add!(view, "Charizard")
      view |> element("#skills-toggle-Charizard") |> render_click()

      # the form reports EVERY select on every change — the shape a browser
      # actually sends, which the first cut of this editor could not have read
      form = "#skills-form-Charizard"

      view
      |> form(form)
      |> render_change(%{"skill" => %{"3" => "aoe", "4" => "heal", "5" => "aoe"}})

      assert Team.skills("Charizard") == %{"3" => :aoe, "5" => :aoe, "4" => :heal}
      assert view |> element("#skills-form-Charizard") |> render() =~ "3+5"

      # one job per key: choosing another MOVES it
      view
      |> form(form)
      |> render_change(%{"skill" => %{"3" => "crowd", "4" => "heal", "5" => "aoe"}})

      assert Team.skills("Charizard") == %{"3" => :crowd, "5" => :aoe, "4" => :heal}

      # and "—" takes it away
      view
      |> form(form)
      |> render_change(%{"skill" => %{"3" => "none", "4" => "heal", "5" => "aoe"}})

      assert Team.skills("Charizard") == %{"5" => :aoe, "4" => :heal}
    end

    # The bug the first cut had: six selects sharing one name and the key
    # riding in phx-value-*, which a FORM event never carries. Submitting the
    # form as rendered has to save — that is the whole contract.
    @tag :tmp_dir
    test "the form as RENDERED saves, without params invented by the test", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/time")
      add!(view, "Charizard")
      view |> element("#skills-toggle-Charizard") |> render_click()

      html = view |> element("#skills-form-Charizard") |> render()
      assert html =~ ~s(name="skill[1]")
      assert html =~ ~s(name="skill[6]")
      refute html =~ ~s(name="category")

      # every select answers on its own name, so a change to ONE of them still
      # reports the other five and nothing is lost
      view
      |> form("#skills-form-Charizard", %{"skill" => %{"2" => "buffs"}})
      |> render_change()

      assert Team.skills("Charizard") == %{"2" => :buffs}
    end

    # "ja marquei os pokmons como parte do meu time, mas nao sei como
    # configurar o combo de cada um" (Lucas, 2026-08-11). Six rows that render
    # NOTHING when unconfigured read as "there is nothing to do here".
    @tag :tmp_dir
    test "an unclassified team member says so; the bank stays quiet", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/time")
      add!(view, "Charizard")
      add!(view, "Venusaur", "bank")

      assert view |> element("#team-list") |> render() =~ "nenhuma skill classificada"
      refute view |> element("#bank-list") |> render() =~ "nenhuma skill classificada"
    end

    # "eu seleciono, mas o combo não é uma junção" (2026-08-11). His exact
    # screenshot: 3 4 5 6 as area, 1 as aura, 2 as control — and the page
    # answered "combo: 1 → 2 → 3 → 4 → 5 → 6", which is four different moments
    # glued into one sequence.
    @tag :tmp_dir
    test "the kill is area-then-target; the aura and the control stay OUT", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/time")
      add!(view, "Charizard")
      view |> element("#skills-toggle-Charizard") |> render_click()

      view
      |> form("#skills-form-Charizard")
      |> render_change(%{
        "skill" => %{
          "1" => "buffs",
          "2" => "crowd",
          "3" => "aoe",
          "4" => "aoe",
          "5" => "aoe",
          "6" => "aoe",
          "7" => "single"
        }
      })

      editor = view |> element("#skills-form-Charizard") |> render()
      assert editor =~ "3+4+5+6 → 🎯 7"
      refute editor =~ "1 → 2 →"

      # the jobs that are not the kill say WHEN they are, and the control says
      # out loud why it is not in the combo
      moments = view |> element("#skills-moments-Charizard") |> render()
      assert moments =~ "na mobada, no meio do bolo"
      assert moments =~ "reservada pro stun antes do revive"
      assert moments =~ "não está lá pro revive"

      # and the collapsed row leads with the kill, the rest dimmer behind it
      view |> element("#skills-toggle-Charizard") |> render_click()
      row = view |> element("#team-list") |> render()
      assert row =~ "3+4+5+6 → 🎯 7"
      refute row =~ "nenhuma skill classificada"
    end

    # A pokémon whose keys are all reserved has nothing to kill with, and a
    # silent empty combo is how that ships unnoticed.
    @tag :tmp_dir
    test "classifying ONLY control leaves the kill empty, and the page says so", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/time")
      add!(view, "Charizard")
      view |> element("#skills-toggle-Charizard") |> render_click()

      view
      |> form("#skills-form-Charizard")
      |> render_change(%{"skill" => %{"2" => "crowd", "8" => "heal"}})

      assert view |> element("#skills-form-Charizard") |> render() =~
               "classifica pelo menos uma como área"

      view |> element("#skills-toggle-Charizard") |> render_click()
      assert view |> element("#team-list") |> render() =~ "falta uma skill de área"
    end

    @tag :tmp_dir
    test "a pokémon in the BANK is configured the same way", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/time")
      add!(view, "Venusaur", "bank")
      view |> element("#skills-toggle-Venusaur") |> render_click()

      view
      |> form("#skills-form-Venusaur")
      |> render_change(%{"skill" => %{"1" => "crowd"}})

      assert Team.skills("Venusaur") == %{"1" => :crowd}
    end
  end

  # "as telas tao mal integradas poxa" — three screens hold his keys and none
  # of them used to admit the other two existed.
  describe "where his keys already live" do
    defp record!(name, combo) do
      {:ok, route} = Route.append(Route.new(name), {10, 20, 7})

      route
      |> Route.set_timing(0, combo: combo)
      |> RouteStore.add()
    end

    @tag :tmp_dir
    test "the page names the recorded route and the combat, and links to both", %{conn: conn} do
      :ok = record!("Azumaril easy", ~w(1 1 3 3 4 4 4 5))

      {:ok, view, _html} = live(conn, ~p"/time")

      # his own keys, mashing collapsed, in firing order
      assert view |> element("#skills-map-recorded") |> render() =~ "1 3 4 5"
      # and the OTHER place keys live, which is not the same list
      assert view |> element("#skills-map-combat") |> render() =~ "1 2 3"

      map = view |> element("#skills-map") |> render()
      assert map =~ ~s(href="/cavebot")
      assert map =~ ~s(href="/config")
    end

    @tag :tmp_dir
    test "the editor marks the keys his hands actually press", %{conn: conn} do
      :ok = record!("Azumaril easy", ~w(3 3 4))

      {:ok, view, _html} = live(conn, ~p"/time")
      add!(view, "Charizard")
      view |> element("#skills-toggle-Charizard") |> render_click()

      editor = view |> element("#skills-form-Charizard") |> render()
      assert editor =~ "(3 4)"
      assert editor =~ "começa por elas"
    end

    @tag :tmp_dir
    test "with nothing recorded the page says so instead of an empty gap", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/time")

      assert view |> element("#skills-map-recorded") |> render() =~ "nenhuma"
    end

    # `RouteStore.all/0` reads and decodes the whole routes file; doing it on
    # every level keystroke is the disk-hammering the recording audit killed.
    @tag :tmp_dir
    test "the routes file is not re-read on every team edit", %{conn: conn} do
      :ok = record!("Azumaril easy", ~w(3 4))

      {:ok, view, _html} = live(conn, ~p"/time")
      add!(view, "Charizard")

      File.rm!(Path.join(Pokex.Home.dir(), "routes.json"))

      view
      |> element(~s(#team-list form[phx-change="set_level"]))
      |> render_change(%{"name" => "Charizard", "level" => "95"})

      assert view |> element("#skills-map-recorded") |> render() =~ "3 4"
    end
  end
end
