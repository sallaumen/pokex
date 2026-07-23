defmodule PokexWeb.CharacterSwitchTest do
  @moduledoc """
  Trocar de personagem no header tem que chegar na PÁGINA ABERTA.

  O bug que originou isto: o `/time` continuava listando o time do personagem
  anterior até um F5 (Lucas, 2026-07-23) — o disco estava certo e a tela
  mentindo. Como é o mesmo LiveView e o mesmo socket, nada recarrega sozinho:
  quem tem dado de personagem implementa `PokexWeb.CharacterAware`, e é isso
  que estes testes guardam.
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

  setup %{tmp_dir: tmp} do
    File.write!(Path.join(tmp, "pokedex.json"), JSON.encode!(@dataset))
    Application.put_env(:pokex, :pokedex_path, Path.join(tmp, "pokedex.json"))
    Application.put_env(:pokex, :home_dir, tmp)

    # O Settings é global e a camada do personagem mora ao lado do settings.json
    # da suíte: deixar um personagem ativo aqui vazaria pros testes seguintes
    # (Team.file/0 passa a apontar pra chars/<slug>/team.json).
    on_exit(fn ->
      Characters.set_active("")
      Application.delete_env(:pokex, :pokedex_path)
      Application.delete_env(:pokex, :home_dir)
      File.rm_rf!(Path.join(Path.dirname(Pokex.Home.settings_file()), "chars"))
    end)

    {:ok, main} = Characters.create("Main")
    {:ok, lowbie} = Characters.create("Lowbie")

    %{main: main, lowbie: lowbie}
  end

  @tag :tmp_dir
  test "o /time troca de time na hora, sem F5", %{conn: conn, main: main, lowbie: lowbie} do
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

    time = view |> element("#team-list") |> render()
    assert time =~ "Caterpie"
    refute time =~ "Charizard"
  end

  @tag :tmp_dir
  test "uma aba parada em OUTRA página acompanha a troca feita em qualquer lugar",
       %{conn: conn, main: main, lowbie: lowbie} do
    :ok = Characters.set_active(main)
    {:ok, _} = Team.add("Charizard", :team)

    {:ok, view, _html} = live(conn, ~p"/time")
    assert view |> element("#team-list") |> render() =~ "Charizard"

    # ninguém tocou nesta aba — a troca veio de fora (outra aba, o próprio bot)
    :ok = Characters.set_active(lowbie)

    assert render(view) =~ "cadastra teus Pokémon"
    assert view |> element("#character-picker") |> render() =~ ~s(value="#{lowbie}" selected)
  end

  @tag :tmp_dir
  test "os ajustes do painel são DO personagem: trocar troca os controles", %{
    conn: conn,
    main: main,
    lowbie: lowbie
  } do
    :ok = Characters.set_active(main)
    :ok = Settings.put(:skill_keys, ["7", "8"])

    :ok = Characters.set_active(lowbie)
    :ok = Settings.put(:skill_keys, ["1"])

    :ok = Characters.set_active(main)
    {:ok, view, _html} = live(conn, ~p"/")
    assert view |> element("#skills-form input[name=skills]") |> render() =~ ~s(value="7 8")
    assert view |> element("#settings-owner") |> render() =~ "Main"

    view
    |> form("#character-picker-form", %{"character" => lowbie})
    |> render_change()

    assert view |> element("#skills-form input[name=skills]") |> render() =~ ~s(value="1")
    assert view |> element("#settings-owner") |> render() =~ "Lowbie"
  end

  @tag :tmp_dir
  test "sem personagem o painel diz que você está editando a base", %{conn: conn} do
    :ok = Characters.set_active("")
    {:ok, view, _html} = live(conn, ~p"/")

    assert view |> element("#settings-owner") |> render() =~ "configuração base"
  end

  @tag :tmp_dir
  test "editar com um personagem ativo NÃO vaza pro outro", %{main: main, lowbie: lowbie} do
    :ok = Characters.set_active(main)
    :ok = Settings.put(:require_pokemon_hp, true)

    :ok = Characters.set_active(lowbie)
    assert Settings.get(:require_pokemon_hp) == Settings.defaults()[:require_pokemon_hp]

    :ok = Characters.set_active(main)
    assert Settings.get(:require_pokemon_hp) == true
  end
end
