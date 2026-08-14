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
  alias Pokex.Settings

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
      Pokex.TestHome.restore()
      # the character layer lives beside the suite's settings.json — leaving a
      # chars/ behind would let one test's skills reach the next one
      File.rm_rf!(Path.join(Path.dirname(Pokex.Home.settings_file()), "chars"))
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

  # the skills form lives in the ⚙️ overlay (settings_sections), not on the dashboard
  test "the skills are the CHARACTER's: switching switches the controls", %{
    conn: conn,
    main: main,
    lowbie: lowbie
  } do
    :ok = Characters.set_active(main)
    :ok = Settings.put(:skill_keys, ["7", "8"])

    :ok = Characters.set_active(lowbie)
    :ok = Settings.put(:skill_keys, ["1"])

    :ok = Characters.set_active(main)
    {:ok, view, _html} = live(conn, ~p"/config")
    assert view |> element("#skills-form input[name=skills]") |> render() =~ ~s(value="7 8")

    view
    |> form("#character-picker-form", %{"character" => lowbie})
    |> render_change()

    assert view |> element("#skills-form input[name=skills]") |> render() =~ ~s(value="1")
  end

  test "the ⚙️ says whose settings these are, and marks the fields that follow him", %{
    conn: conn,
    main: main
  } do
    :ok = Characters.set_active(main)
    {:ok, view, _html} = live(conn, ~p"/config")

    owner = view |> element("#settings-owner") |> render()
    assert owner =~ "Main"
    refute owner =~ "configuração base"

    # the marker has to sit ON the fields that follow the character — the banner
    # alone leaves "which ones?" to guessing
    assert has_element?(view, ~s(#hook-skills-form [data-testid="character-key"]))
    assert has_element?(view, ~s(#fishing-hp-form [data-testid="character-key"]))
    assert has_element?(view, ~s(#automation-require-cooldowns [data-testid="character-key"]))
    assert has_element?(view, ~s(#automation-require-pokemon-hp [data-testid="character-key"]))
  end

  test "with no character the ⚙️ says you are editing the base, and marks nothing", %{conn: conn} do
    :ok = Characters.set_active("")
    {:ok, view, _html} = live(conn, ~p"/config")

    assert view |> element("#settings-owner") |> render() =~ "configuração base"
    refute has_element?(view, ~s([data-testid="character-key"]))
  end

  test "editing with a character active does NOT leak to the other", %{main: main, lowbie: lowbie} do
    :ok = Characters.set_active(main)
    :ok = Settings.put(:require_pokemon_hp, true)

    :ok = Characters.set_active(lowbie)
    assert Settings.get(:require_pokemon_hp) == Settings.defaults()[:require_pokemon_hp]

    :ok = Characters.set_active(main)
    assert Settings.get(:require_pokemon_hp) == true
  end

  test "what describes the MACHINE stays shared between characters", %{
    main: main,
    lowbie: lowbie
  } do
    original = Settings.get(:glow_threshold)
    on_exit(fn -> Settings.put(:glow_threshold, original) end)

    :ok = Characters.set_active(main)
    :ok = Settings.put(:glow_threshold, 1234)

    :ok = Characters.set_active(lowbie)
    assert Settings.get(:glow_threshold) == 1234
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
