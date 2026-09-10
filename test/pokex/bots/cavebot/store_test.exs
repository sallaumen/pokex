defmodule Pokex.Bots.Cavebot.StoreTest do
  use ExUnit.Case, async: false
  alias Pokex.Bots.Cavebot.{Route, Store}

  import ExUnit.CaptureLog

  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Pokex.TestHome.restore() end)
    :ok
  end

  @moduletag :tmp_dir

  test "route round-trip keeps the combat mode" do
    route = Route.set_mode(Route.new("dungeon forte"), :economy)
    assert :ok = Store.add(route)
    assert [%{mode: :economy}] = Store.all()
  end

  test "a route that chose no mode reads back as nil" do
    assert :ok = Store.add(Route.new("rota nova"))
    assert [%{mode: nil}] = Store.all()
  end

  test "a mode this build does not know reads back as nil" do
    assert :ok = Store.add(Route.set_mode(Route.new("rota do futuro"), "modo_de_amanha"))
    assert [%{mode: nil}] = Store.all()
  end

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
               stops: [],
               at: nil,
               dwell_ms: nil,
               fight_ms: nil,
               gather_ms: nil
             }
           ]
  end

  # Surviving the corruption is right; doing it quietly is what made a broken
  # routes.json read exactly like "there are no routes" — the hunt with nothing
  # to walk and no way to tell why. The fallback stays, the silence does not.
  test "a corrupted file becomes an empty list, and says which file it was", %{tmp_dir: tmp} do
    File.write!(Path.join(tmp, "routes.json"), "{ not json")

    log = capture_log(fn -> assert Store.all() == [] end)

    assert log =~ "routes.json"
    assert log =~ "ilegível"
  end

  # Valid JSON of the wrong shape is what a hand-edit leaves behind, and it used
  # to fall through a catch-all clause without even reaching the rescue.
  test "a file with valid JSON but no routes key is just as loud", %{tmp_dir: tmp} do
    File.write!(Path.join(tmp, "routes.json"), ~s({"rotas": []}))

    log = capture_log(fn -> assert Store.all() == [] end)

    assert log =~ "routes.json"
  end

  test "a missing file becomes an empty list, and says nothing" do
    assert capture_log(fn -> assert Store.all() == [] end) == ""
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
               stops: [],
               at: nil,
               dwell_ms: nil,
               fight_ms: nil,
               gather_ms: nil
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
               stops: [],
               at: nil,
               dwell_ms: nil,
               fight_ms: nil,
               gather_ms: nil
             }
           ]
  end

  # Every route on his disk was written with a route-level `"z"` — the floor it
  # STARTED on. The struct dropped the field on 2026-08-28 (`Route.floors/1`
  # derives the whole set from the waypoints, which is what the Logic actually
  # asks for), and the five routes he already has must keep loading: the key is
  # read past, and it leaves the file the next time the route is saved.
  test "a route saved with the old floor field loads, and the field is not written back",
       %{tmp_dir: tmp} do
    body =
      JSON.encode!(%{
        "routes" => [
          %{
            "name" => "com-andar",
            "z" => 7,
            "enabled" => true,
            "waypoints" => [%{"x" => 1, "y" => 2, "z" => 7}, %{"x" => 3, "y" => 4, "z" => 6}]
          }
        ]
      })

    File.write!(Path.join(tmp, "routes.json"), body)

    [got] = Store.all()
    assert got.name == "com-andar"
    refute Map.has_key?(got, :z)
    assert Route.floors(got) == [6, 7]

    # saving it again is what drops the key — and the waypoints keep THEIR
    # floors, which are the ones anybody reads
    :ok = Store.add(got)
    written = Path.join(tmp, "routes.json") |> File.read!() |> JSON.decode!()

    refute Map.has_key?(hd(written["routes"]), "z")
    assert Enum.map(hd(written["routes"])["waypoints"], & &1["z"]) == [7, 6]
  end

  # Waypoints gained a JOB after his routes were already recorded and walked:
  # every one of them must keep working, which means a missing key is a plain
  # walking corner — never a crash, never a lost route.
  describe "what a waypoint carries survives the disk" do
    # `:sweep` was a stop until 2026-08-28, written first as a single boolean
    # and later inside the list. Both shapes are on his disk, and dropping the
    # stop must not cost him the waypoints that carried it: the name simply
    # matches nothing, and everything else the corner asks for still reads.
    test "a waypoint written with the sweep stop loads without it", %{tmp_dir: tmp} do
      body =
        JSON.encode!(%{
          "routes" => [
            %{
              "name" => "antiga",
              "z" => 7,
              "waypoints" => [
                %{"x" => 1, "y" => 2, "z" => 7, "sweep" => true},
                %{
                  "x" => 3,
                  "y" => 4,
                  "z" => 7,
                  "stops" => ["sweep", "cooldown_revive", "wait"]
                }
              ]
            }
          ]
        })

      File.write!(Path.join(tmp, "routes.json"), body)

      assert [%Route{waypoints: [old_flag, in_the_list]}] = Store.all()
      assert old_flag.stops == []
      assert in_the_list.stops == [:cooldown_revive, :wait]
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
  end

  # KEYS READ PAST. The mob-stretch marks and everything hanging off them left
  # the project; a file he already has still carries them and must load clean.
  describe "the retired keys on his disk" do
    test "a waypoint carrying the old marks loads without them" do
      File.write!(Path.join(Pokex.Home.dir(), "routes.json"), """
      {"routes":[{"name":"suja","dungeon":null,"z":5,"enabled":true,"gather_wait_ms":1800,
      "waypoints":[{"x":1,"y":2,"z":5,"action":"lure_end","combo":["3","4"],
      "skills":["buffs","aoe"],"gather_wait_ms":600,"stops":["wait"]}]}]}
      """)

      [read] = Store.all()
      [wp] = read.waypoints

      assert {wp.x, wp.y, wp.z} == {1, 2, 5}
      assert wp.stops == [:wait]
      refute Map.has_key?(wp, :action)
      refute Map.has_key?(wp, :combo)
      refute Map.has_key?(wp, :skills)
      refute Map.has_key?(wp, :gather_wait_ms)
      refute Map.has_key?(read, :gather_wait_ms)
    end

    test "and they are gone from the file the next time it is saved" do
      File.write!(Path.join(Pokex.Home.dir(), "routes.json"), """
      {"routes":[{"name":"suja","enabled":true,
      "waypoints":[{"x":1,"y":2,"z":5,"action":"lure_end","combo":["3"]}]}]}
      """)

      [read] = Store.all()
      :ok = Store.add(read)
      body = File.read!(Path.join(Pokex.Home.dir(), "routes.json"))

      refute body =~ "lure_end"
      refute body =~ "combo"
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

  # Every mutation here reads the whole file, changes one entry and writes the
  # whole file back. Two of those at once do not conflict and do not error —
  # one of them simply never happened. Measured 2026-08-14 before Pokex.StateFile:
  # two processes adding a route each, 60 times, ended with ONE route on disk.
  # Live, that is arming a route in the panel while the cavebot page files the
  # lesson of a fight.
  test "two writers at once both survive — neither write is lost" do
    parent = self()

    for name <- ~w(alfa beta) do
      spawn_link(fn ->
        Enum.each(1..60, fn i ->
          Store.add(%Route{Route.new(name, nil) | waypoints: [%{x: i, y: i, z: 7}]})
        end)

        send(parent, {:written, name})
      end)
    end

    assert_receive {:written, _one}, 30_000
    assert_receive {:written, _other}, 30_000

    assert Store.all() |> Enum.map(& &1.name) |> Enum.sort() == ["alfa", "beta"]
  end
end
