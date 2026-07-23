defmodule Pokex.Bots.Cavebot.StoreTest do
  use ExUnit.Case, async: false
  alias Pokex.Bots.Cavebot.{Route, Store}

  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)
    :ok
  end

  @moduletag :tmp_dir

  test "round-trip de rota com waypoints" do
    {:ok, r} = Route.append(Route.new("cavena", "cavena-dg"), {10, 20, 7})
    assert :ok = Store.add(r)
    [got] = Store.all()
    assert got.name == "cavena"
    assert got.dungeon == "cavena-dg"
    assert got.waypoints == [%{x: 10, y: 20, z: 7}]
  end

  test "arquivo corrompido vira lista vazia, não derruba", %{tmp_dir: tmp} do
    File.write!(Path.join(tmp, "routes.json"), "{ not json")
    assert Store.all() == []
  end

  test "arquivo ausente vira lista vazia" do
    assert Store.all() == []
  end

  test "add sobre nome existente substitui em vez de duplicar" do
    {:ok, a} = Route.append(Route.new("cavena"), {1, 2, 7})
    {:ok, b} = Route.append(Route.new("cavena"), {3, 4, 7})
    :ok = Store.add(a)
    :ok = Store.add(b)

    matching = Enum.filter(Store.all(), &(&1.name == "cavena"))
    assert length(matching) == 1
    assert hd(matching).waypoints == [%{x: 3, y: 4, z: 7}]
  end

  test "nome vazio é recusado" do
    assert Store.add(%Route{name: ""}) == {:error, :invalid_name}
    assert Store.all() == []
  end

  test "delete remove só a nomeada e é seguro em nome inexistente" do
    {:ok, a} = Route.append(Route.new("cavena"), {1, 2, 7})
    {:ok, b} = Route.append(Route.new("outra"), {5, 6, 3})
    :ok = Store.add(a)
    :ok = Store.add(b)

    assert :ok = Store.delete("cavena")
    assert Enum.map(Store.all(), & &1.name) == ["outra"]
    assert :ok = Store.delete("cavena")
  end

  test "set_enabled sobrevive ao round-trip" do
    {:ok, r} = Route.append(Route.new("cavena"), {1, 2, 7})
    :ok = Store.add(r)

    assert :ok = Store.set_enabled("cavena", false)
    refute Enum.find(Store.all(), &(&1.name == "cavena")).enabled?
  end

  test "dungeon ausente no JSON vira nil", %{tmp_dir: tmp} do
    body =
      JSON.encode!(%{
        "routes" => [
          %{
            "name" => "sem-dg",
            "z" => 7,
            "enabled" => true,
            "waypoints" => [%{"x" => 1, "y" => 2, "z" => 7}]
          }
        ]
      })

    File.write!(Path.join(tmp, "routes.json"), body)

    [got] = Store.all()
    assert got.name == "sem-dg"
    assert got.dungeon == nil
    assert got.waypoints == [%{x: 1, y: 2, z: 7}]
  end
end
