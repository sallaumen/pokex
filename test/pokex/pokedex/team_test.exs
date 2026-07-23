defmodule Pokex.Pokedex.TeamTest do
  # async: false — scopes the global :home_dir/:pokedex_path env per test
  use ExUnit.Case, async: false

  alias Pokex.Pokedex.Team

  @dataset %{
    "species" => [
      %{"name" => "Seadra", "number" => 117, "elements" => ["Water"]},
      %{
        "name" => "Shiny Seadra",
        "number" => 117,
        "elements" => ["Water"],
        "shiny_of" => "Seadra"
      },
      %{"name" => "Venusaur", "number" => 3, "elements" => ["Grass"]}
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
  test "add/members/remove round-trip, idempotent across the two lists" do
    assert Team.members() == []
    assert Team.bank() == []

    assert {:ok, _} = Team.add("Seadra")
    # owning the Shiny is real — variants are allowed
    assert {:ok, _} = Team.add("Shiny Seadra")
    # duplicate add is a no-op (the name lives in ONE place)
    assert {:ok, _} = Team.add("Seadra")
    assert Team.member_names() == ["Seadra", "Shiny Seadra"]

    Team.remove("Seadra")
    assert Team.member_names() == ["Shiny Seadra"]
  end

  @tag :tmp_dir
  test "banco: adicionar direto, mover pra lá e voltar mantendo o level" do
    assert {:ok, _} = Team.add("Venusaur", :bank)
    assert Enum.map(Team.bank(), & &1.name) == ["Venusaur"]
    assert Team.members() == []

    Team.set_level("Venusaur", 72)
    Team.move("Venusaur", :team)
    assert [%{name: "Venusaur", level: 72}] = Team.members()
    assert Team.bank() == []

    Team.move("Venusaur", :bank)
    assert [%{name: "Venusaur", level: 72}] = Team.bank()

    # adding an existing bank name to the TEAM relocates it (never duplicates)
    assert {:ok, _} = Team.add("Venusaur", :team)
    assert Team.bank() == []
    assert Team.member_names() == ["Venusaur"]
  end

  @tag :tmp_dir
  test "meu level + janela persistem; margem tem default 15" do
    assert Team.player_level() == nil
    assert Team.level_margin() == 15

    Team.set_player_level(88)
    Team.set_level_margin(20)
    assert Team.player_level() == 88
    assert Team.level_margin() == 20

    Team.set_player_level(nil)
    assert Team.player_level() == nil
  end

  @tag :tmp_dir
  test "um team.json v1 (lista de nomes) carrega como time sem levels" do
    File.write!(
      Path.join(Pokex.Home.dir(), "team.json"),
      JSON.encode!(%{members: ["Seadra", "Venusaur"]})
    )

    # v3 adds the hotkey slot; a v1 file simply has none yet
    assert Team.members() == [
             %{name: "Seadra", level: nil, slot: nil},
             %{name: "Venusaur", level: nil, slot: nil}
           ]

    assert Team.bank() == []
    assert Team.level_margin() == 15
  end

  @tag :tmp_dir
  test "a name the Pokédex doesn't know is rejected" do
    assert Team.add("Digimon") == {:error, :unknown}
    assert Team.members() == []
  end

  @tag :tmp_dir
  test "a corrupt team file degrades to empty" do
    File.write!(Path.join(Pokex.Home.dir(), "team.json"), "{lixo")
    assert Team.members() == []
    assert Team.bank() == []
  end

  # file/0 reads the GLOBAL Settings (via Characters.active/0), so these tests
  # set :active_character globally — SettingsStash restores it on exit.
  @tag :tmp_dir
  test "sem personagem lê o team.json legado; com personagem lê chars/<slug>", %{tmp_dir: tmp} do
    Pokex.SettingsStash.stash_keys!([:active_character])

    Pokex.Settings.put(:active_character, "")
    assert Team.file() == Path.join(tmp, "team.json")

    Pokex.Settings.put(:active_character, "lowbie")
    assert Team.file() == Path.join([tmp, "chars", "lowbie", "team.json"])
  end

  @tag :tmp_dir
  test "round-trip por personagem: grava em chars/<slug> e o legado reaparece ao voltar",
       %{tmp_dir: tmp} do
    Pokex.SettingsStash.stash_keys!([:active_character])

    # no character selected: the legacy team
    Pokex.Settings.put(:active_character, "")
    assert {:ok, _} = Team.add("Venusaur")
    assert Team.member_names() == ["Venusaur"]

    # switching to a character starts from ITS OWN (empty) team...
    Pokex.Settings.put(:active_character, "lowbie")
    assert Team.members() == []

    # ...and writes land under chars/<slug>/team.json
    assert {:ok, _} = Team.add("Seadra")
    assert Team.member_names() == ["Seadra"]
    assert File.exists?(Path.join([tmp, "chars", "lowbie", "team.json"]))

    # back to no character: the legacy team reappears untouched
    Pokex.Settings.put(:active_character, "")
    assert Team.member_names() == ["Venusaur"]
  end
end
