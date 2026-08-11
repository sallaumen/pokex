defmodule Pokex.Bots.Cavebot.StoreTest do
  use ExUnit.Case, async: false
  alias Pokex.Bots.Cavebot.{Route, Store}

  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)
    :ok
  end

  @moduletag :tmp_dir

  test "route round-trip with waypoints" do
    {:ok, r} = Route.append(Route.new("cavena", "cavena-dg"), {10, 20, 7})
    assert :ok = Store.add(r)
    [got] = Store.all()
    assert got.name == "cavena"
    assert got.dungeon == "cavena-dg"
    assert got.waypoints == [%{x: 10, y: 20, z: 7, action: :walk, stops: []}]
  end

  test "a corrupted file becomes an empty list instead of crashing", %{tmp_dir: tmp} do
    File.write!(Path.join(tmp, "routes.json"), "{ not json")
    assert Store.all() == []
  end

  test "a missing file becomes an empty list" do
    assert Store.all() == []
  end

  test "add over an existing name replaces instead of duplicating" do
    {:ok, a} = Route.append(Route.new("cavena"), {1, 2, 7})
    {:ok, b} = Route.append(Route.new("cavena"), {3, 4, 7})
    :ok = Store.add(a)
    :ok = Store.add(b)

    matching = Enum.filter(Store.all(), &(&1.name == "cavena"))
    assert length(matching) == 1
    assert hd(matching).waypoints == [%{x: 3, y: 4, z: 7, action: :walk, stops: []}]
  end

  test "an empty name is rejected" do
    assert Store.add(%Route{name: ""}) == {:error, :invalid_name}
    assert Store.all() == []
  end

  test "delete removes only the named route and is safe on a missing name" do
    {:ok, a} = Route.append(Route.new("cavena"), {1, 2, 7})
    {:ok, b} = Route.append(Route.new("outra"), {5, 6, 3})
    :ok = Store.add(a)
    :ok = Store.add(b)

    assert :ok = Store.delete("cavena")
    assert Enum.map(Store.all(), & &1.name) == ["outra"]
    assert :ok = Store.delete("cavena")
  end

  test "set_enabled survives the round-trip" do
    {:ok, r} = Route.append(Route.new("cavena"), {1, 2, 7})
    :ok = Store.add(r)

    assert :ok = Store.set_enabled("cavena", false)
    refute Enum.find(Store.all(), &(&1.name == "cavena")).enabled?
  end

  test "a dungeon missing from the JSON becomes nil", %{tmp_dir: tmp} do
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
    assert got.waypoints == [%{x: 1, y: 2, z: 7, action: :walk, stops: []}]
  end

  # Waypoints gained a JOB after his routes were already recorded and walked:
  # every one of them must keep working, which means a missing key is a plain
  # walking corner — never a crash, never a lost route.
  describe "the job a waypoint carries survives the disk" do
    test "a marked route round-trips" do
      {:ok, route} = Route.append(Route.new("mob"), {1, 2, 7})
      {:ok, route} = Route.append(route, {3, 4, 7})

      :ok = Store.add(Route.set_action(route, 1, :lure_start))

      assert [%Route{waypoints: [%{action: :walk}, %{action: :lure_start}]}] = Store.all()
    end

    test "a route recorded before jobs existed reads as plain walking", %{tmp_dir: tmp} do
      body =
        JSON.encode!(%{
          "routes" => [
            %{"name" => "antiga", "z" => 7, "waypoints" => [%{"x" => 1, "y" => 2, "z" => 7}]}
          ]
        })

      File.write!(Path.join(tmp, "routes.json"), body)

      assert [%Route{waypoints: [%{action: :walk}]}] = Store.all()
    end

    # Stops shipped for an hour as a single boolean before becoming a list.
    # Whatever he marked in that window still reads.
    test "a waypoint written with the old sweep flag reads as the sweep stop", %{tmp_dir: tmp} do
      body =
        JSON.encode!(%{
          "routes" => [
            %{
              "name" => "antiga",
              "z" => 7,
              "waypoints" => [%{"x" => 1, "y" => 2, "z" => 7, "sweep" => true}]
            }
          ]
        })

      File.write!(Path.join(tmp, "routes.json"), body)

      assert [%Route{waypoints: [%{stops: [:sweep]}]}] = Store.all()
    end

    test "the stop list round-trips, in running order", %{tmp_dir: tmp} do
      {:ok, route} = Route.append(Route.new("paradas"), {1, 2, 7})

      route
      |> Route.set_stop(0, :wait, true)
      |> Route.set_stop(0, :cooldown_revive, true)
      |> Store.add()

      assert [%Route{waypoints: [%{stops: [:cooldown_revive, :wait]}]}] = Store.all()
      assert File.read!(Path.join(tmp, "routes.json")) =~ "cooldown_revive"
    end

    test "a job nobody knows reads as plain walking, never a new atom", %{tmp_dir: tmp} do
      body =
        JSON.encode!(%{
          "routes" => [
            %{
              "name" => "estranha",
              "z" => 7,
              "waypoints" => [%{"x" => 1, "y" => 2, "z" => 7, "action" => "abracadabra_xyz"}]
            }
          ]
        })

      File.write!(Path.join(tmp, "routes.json"), body)

      assert [%Route{waypoints: [%{action: :walk}]}] = Store.all()
      assert_raise ArgumentError, fn -> String.to_existing_atom("abracadabra_xyz") end
    end
  end
end
