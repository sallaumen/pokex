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
  test "add/members/remove round-trip, idempotent" do
    assert Team.members() == []

    assert {:ok, ["Seadra"]} = Team.add("Seadra")
    # owning the Shiny is real — variants are allowed
    assert {:ok, ["Seadra", "Shiny Seadra"]} = Team.add("Shiny Seadra")
    # duplicate add is a no-op
    assert {:ok, ["Seadra", "Shiny Seadra"]} = Team.add("Seadra")
    assert Team.members() == ["Seadra", "Shiny Seadra"]

    assert Team.remove("Seadra") == ["Shiny Seadra"]
    assert Team.members() == ["Shiny Seadra"]
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
  end
end
