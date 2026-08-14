defmodule Pokex.Bots.Cavebot.StoreTest do
  use ExUnit.Case, async: false
  alias Pokex.Bots.Cavebot.{Route, Store}

  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Pokex.TestHome.restore() end)
    :ok
  end

  @moduletag :tmp_dir

  test "route round-trip with waypoints" do
    {:ok, r} = Route.append(Route.new("cavena", "cavena-dg"), {10, 20, 7})
    assert :ok = Store.add(r)
    [got] = Store.all()
    assert got.name == "cavena"
    assert got.dungeon == "cavena-dg"

    assert got.waypoints == [
             %{
               x: 10,
               y: 20,
               z: 7,
               action: :walk,
               stops: [],
               at: nil,
               dwell_ms: nil,
               park_point: nil,
               park_tiles: nil,
               fight_ms: nil,
               gather_ms: nil,
               combo: [],
               skills: [],
               gather_wait_ms: nil
             }
           ]
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

    assert hd(matching).waypoints == [
             %{
               x: 3,
               y: 4,
               z: 7,
               action: :walk,
               stops: [],
               at: nil,
               dwell_ms: nil,
               park_point: nil,
               park_tiles: nil,
               fight_ms: nil,
               gather_ms: nil,
               combo: [],
               skills: [],
               gather_wait_ms: nil
             }
           ]
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

  # 2026-08-11, live: "teste" (andar 5) and "Azumaril easy" (andares 1 e 2)
  # were BOTH enabled. The hunt takes the first enabled one it finds, so it
  # walked "teste" while he stood in the Azumaril — every position on a floor
  # that route never visits, and it blocked on the first step ("BLOQUEADO:
  # mudou de andar"). One route is armed at a time, or the screen is lying.
  test "arming a route disarms every other one" do
    {:ok, a} = Route.append(Route.new("teste"), {1, 2, 5})
    {:ok, b} = Route.append(Route.new("azumaril"), {1, 2, 1})
    :ok = Store.add(a)
    :ok = Store.add(b)

    assert :ok = Store.set_enabled("teste", true)
    assert :ok = Store.set_enabled("azumaril", true)

    armed = Store.all() |> Enum.filter(& &1.enabled?) |> Enum.map(& &1.name)
    assert armed == ["azumaril"]
  end

  test "disarming leaves everyone else alone — including nobody armed at all" do
    {:ok, a} = Route.append(Route.new("teste"), {1, 2, 5})
    {:ok, b} = Route.append(Route.new("azumaril"), {1, 2, 1})
    :ok = Store.add(a)
    :ok = Store.add(b)
    :ok = Store.set_enabled("azumaril", true)

    assert :ok = Store.set_enabled("azumaril", false)
    assert Store.all() |> Enum.filter(& &1.enabled?) == []
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

    assert got.waypoints == [
             %{
               x: 1,
               y: 2,
               z: 7,
               action: :walk,
               stops: [],
               at: nil,
               dwell_ms: nil,
               park_point: nil,
               park_tiles: nil,
               fight_ms: nil,
               gather_ms: nil,
               combo: [],
               skills: [],
               gather_wait_ms: nil
             }
           ]
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

  describe "the new fields on disk" do
    test "skills and both rulers round-trip" do
      {:ok, route} = Route.append(Route.new("meganium"), {10, 10, 5})

      route =
        route
        |> Route.set_skill(0, :buffs, true)
        |> Route.set_skill(0, :aoe, true)
        |> Route.set_gather_wait(1_800)
        |> Route.set_gather_wait(0, 600)

      :ok = Store.add(route)
      [read] = Store.all()

      assert read.gather_wait_ms == 1_800
      assert Route.skills_at(read.waypoints, 0) == [:buffs, :aoe]
      assert Route.gather_wait(read, hd(read.waypoints), 4_000) == 600
    end

    test "nil does not become zero on the way there and back" do
      {:ok, route} = Route.append(Route.new("sem régua"), {10, 10, 5})
      :ok = Store.add(route)
      [read] = Store.all()

      assert read.gather_wait_ms == nil
      assert hd(read.waypoints)[:gather_wait_ms] == nil
      assert Route.gather_wait(read, hd(read.waypoints), 4_000) == 4_000
    end

    # The file is hand-editable: a typo in it can neither mint an atom nor break
    # the reading of the whole route. Same rule the action and the stops follow.
    #
    # The literal JSON also pins the ruler's NAME on disk, at both levels. A
    # round-trip test goes through encode AND decode, so renaming both sides at
    # once would keep it green while resetting every route he already has to
    # `nil` — his five routes live on this disk, not in a fixture.
    test "a category nobody knows is dropped, and the ruler is read by its name" do
      File.write!(Path.join(Pokex.Home.dir(), "routes.json"), """
      {"routes":[{"name":"suja","dungeon":null,"z":5,"enabled":true,"gather_wait_ms":1800,
      "waypoints":[{"x":1,"y":2,"z":5,"skills":["buffs","voar","aoe"],"gather_wait_ms":600}]}]}
      """)

      [read] = Store.all()

      assert Route.skills_at(read.waypoints, 0) == [:buffs, :aoe]
      assert read.gather_wait_ms == 1_800
      assert hd(read.waypoints)[:gather_wait_ms] == 600
      assert Route.gather_wait(read, hd(read.waypoints), 4_000) == 600
    end

    # The five routes he already has were recorded before these fields existed.
    test "an old route, without the fields, reads as empty" do
      File.write!(Path.join(Pokex.Home.dir(), "routes.json"), """
      {"routes":[{"name":"antiga","dungeon":null,"z":5,"enabled":true,
      "waypoints":[{"x":1,"y":2,"z":5,"action":"lure_end","stops":["sweep"]}]}]}
      """)

      [read] = Store.all()

      assert read.gather_wait_ms == nil
      assert Route.skills_at(read.waypoints, 0) == []
      assert Route.gather_wait(read, hd(read.waypoints), 4_000) == 4_000
    end
  end

  # `File.write!/2` truncates and then fills, and `all/0` answers a decode error
  # with "empty" — so a reader landing inside a write does not see a failure, it
  # sees ZERO ROUTES. Measured 2026-08-14 with the old write: 6 of ~20k reads
  # came back empty while one writer looped. The cavebot rewrites this file ~8x/s
  # while recording a fight, and a hunt reading it then would believe it had no
  # route to walk. Home.write! renames into place, so a reader gets the whole old
  # file or the whole new one.
  test "a reader never catches the routes file half-written" do
    :ok = Store.add(Route.new("mob", nil))
    parent = self()

    writer =
      spawn_link(fn ->
        Enum.each(1..400, fn i ->
          Store.add(%Route{
            Route.new("mob", nil)
            | waypoints: List.duplicate(%{x: i, y: i, z: 7}, 40)
          })
        end)

        send(parent, :done)
      end)

    empty_reads =
      Enum.reduce_while(1..20_000, 0, fn _read, empty ->
        empty = if Store.all() == [], do: empty + 1, else: empty

        receive do
          :done -> {:halt, empty}
        after
          0 -> {:cont, empty}
        end
      end)

    Process.exit(writer, :kill)
    assert empty_reads == 0
  end
end
