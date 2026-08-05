defmodule PokexWeb.CharacterSwitchTest do
  @moduledoc """
  Switching character in the header has to reach the PAGE THAT IS OPEN.

  The bug behind this: `/time` kept listing the previous character's team until
  an F5 (Lucas, 2026-07-23) — the disk was right and the screen was lying. It
  is the same LiveView and the same socket, so nothing reloads on its own:
  whoever owns character data implements `PokexWeb.CharacterAware`, and that is
  what these tests guard.
  """
  use PokexWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Pokex.Characters
  alias Pokex.Pokedex.Team

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

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    File.write!(Path.join(tmp, "pokedex.json"), JSON.encode!(@dataset))
    Application.put_env(:pokex, :pokedex_path, Path.join(tmp, "pokedex.json"))
    Application.put_env(:pokex, :home_dir, tmp)

    # Settings is global and shared by the whole suite: leaving a character
    # active here would leak into later tests (Team.file/0 would keep pointing
    # at chars/<slug>/team.json).
    on_exit(fn ->
      Characters.set_active("")
      Application.delete_env(:pokex, :pokedex_path)
      Application.delete_env(:pokex, :home_dir)
    end)

    {:ok, main} = Characters.create("Main")
    {:ok, lowbie} = Characters.create("Lowbie")

    %{main: main, lowbie: lowbie}
  end

  test "/time swaps the team on the spot, no F5", %{conn: conn, main: main, lowbie: lowbie} do
    :ok = Characters.set_active(main)
    {:ok, _} = Team.add("Charizard", :team)

    :ok = Characters.set_active(lowbie)
    {:ok, _} = Team.add("Caterpie", :team)

    :ok = Characters.set_active(main)
    {:ok, view, _html} = live(conn, ~p"/time")
    assert view |> element("#team-list") |> render() =~ "Charizard"

    view
    |> form("#character-picker-form", %{"character" => lowbie})
    |> render_change()

    team = view |> element("#team-list") |> render()
    assert team =~ "Caterpie"
    refute team =~ "Charizard"
  end

  test "a tab parked on another page follows a switch made anywhere", %{
    conn: conn,
    main: main,
    lowbie: lowbie
  } do
    :ok = Characters.set_active(main)
    {:ok, _} = Team.add("Charizard", :team)

    {:ok, view, _html} = live(conn, ~p"/time")
    assert view |> element("#team-list") |> render() =~ "Charizard"

    # nobody touched THIS tab — the switch came from outside (another tab, the bot)
    :ok = Characters.set_active(lowbie)

    refute view |> element("#team-list") |> render() =~ "Charizard"
    assert view |> element("#character-picker") |> render() =~ ~s(value="#{lowbie}" selected)
  end

  test "the switch says out loud who you are now", %{conn: conn, lowbie: lowbie} do
    {:ok, view, _html} = live(conn, ~p"/world")

    html =
      view
      |> form("#character-picker-form", %{"character" => lowbie})
      |> render_change()

    assert html =~ "Agora você é Lowbie"
  end

  test "renaming from the header follows the active character", %{conn: conn, main: main} do
    :ok = Characters.set_active(main)
    {:ok, view, _html} = live(conn, ~p"/world")

    html =
      view
      |> form("#character-rename-#{main}", %{"slug" => main, "name" => "Principal"})
      |> render_submit()

    assert html =~ "Agora chama Principal"
    # the folder moved, so a pointer left behind would be an orphan on the spot
    assert Characters.active() == "principal"
    assert view |> element("#character-picker") |> render() =~ ~s(value="principal" selected)
  end

  test "deleting the active character leaves the picker with no character", %{
    conn: conn,
    main: main
  } do
    :ok = Characters.set_active(main)
    {:ok, view, _html} = live(conn, ~p"/world")

    html = view |> element("#character-delete-#{main}") |> render_click()

    assert html =~ "Main apagado"
    assert Characters.active() == ""
    refute has_element?(view, "#character-row-#{main}")
    assert view |> element("#character-picker") |> render() =~ ~s(value="" selected)
  end

  test "creating with a name already taken says so and keeps the current one", %{
    conn: conn,
    main: main
  } do
    :ok = Characters.set_active(main)
    {:ok, view, _html} = live(conn, ~p"/world")

    html = view |> form("#character-create-form", %{"name" => "Main"}) |> render_submit()

    assert html =~ "já existe um personagem chamado Main"
    assert Characters.active() == main
  end
end
