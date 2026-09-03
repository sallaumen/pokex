defmodule PokexWeb.CavebotLiveTest do
  # async: false — writes the shared blackboard (:minimap) and the routes'
  # home_dir, both global to the test node.
  use PokexWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Pokex.Bots.Cavebot.{Route, Store}
  alias Pokex.Perception.WorldState

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    # one shared blackboard: start from an empty world, never from the last test's
    WorldState.clear()

    Application.put_env(:pokex, :home_dir, tmp)
    WorldState.forget(:minimap)

    on_exit(fn ->
      Pokex.TestHome.restore()
      WorldState.forget(:minimap)
    end)

    :ok
  end

  defp put_pos(pos) do
    WorldState.put(:minimap, %{pos: pos}, System.monotonic_time(:millisecond))
  end

  test "marking a waypoint records the current position on the active route", %{conn: conn} do
    put_pos({10, 20, 7})

    {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

    view
    |> form("#new-route-form", %{"name" => "cavena", "dungeon" => "cavena-dg"})
    |> render_submit()

    html = view |> element("#mark-waypoint") |> render_click()

    assert [%Route{name: "cavena", dungeon: "cavena-dg", waypoints: waypoints}] = Store.all()

    assert [%{x: 10, y: 20, z: 7, action: :walk, stops: [], at: %DateTime{}}] = waypoints
    assert has_element?(view, "#waypoint-0")
    assert html =~ "waypoint 1 marcado"
    assert view |> element("#cavebot-notice") |> render() =~ "text-pk-ok"
  end

  test "deleting a waypoint removes it from the list and the Store", %{conn: conn} do
    {:ok, route} = Route.append(Route.new("cavena"), {1, 2, 7})
    {:ok, route} = Route.append(route, {3, 4, 7})
    :ok = Store.add(route)

    {:ok, view, html} = live(conn, ~p"/cavebot?modo=editar")
    assert html =~ "1, 2"

    view |> element("#waypoint-delete-0") |> render_click()

    assert [%Route{waypoints: [%{x: 3, y: 4, z: 7}]}] = Store.all()
    refute render(view) =~ "1, 2"
    assert has_element?(view, "#waypoint-0")
    refute has_element?(view, "#waypoint-1")
  end

  # The 2026-08-01 case: one monitor, fresh calibration, minimap trio never
  # marked — the page sat silent while the cavebot could not learn a single
  # position. The gap must say WHERE to fix itself.
  test "without a minimap calibration the page says so and points at the calibration",
       %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/cavebot?modo=editar")

    assert html =~ "minimapa não está calibrado"
    assert html =~ ~s(href="/calibration")
  end

  test "with the minimap trio calibrated there is no warning banner", %{conn: conn, tmp_dir: tmp} do
    File.write!(
      Path.join(tmp, "calibration.json"),
      JSON.encode!(%{
        "scale" => 1.0,
        "screen_w" => 1512,
        "screen_h" => 982,
        "minimap_region" => [1200, 100, 290, 458],
        "minimap_coord_region" => [1200, 560, 290, 20],
        "minimap_player_point" => [1345, 320]
      })
    )

    {:ok, _view, html} = live(conn, ~p"/cavebot?modo=editar")

    refute html =~ "minimapa não está calibrado"
  end

  test "without a position read, marking warns and records nothing", %{conn: conn} do
    :ok = Store.add(Route.new("cavena"))

    {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

    html = view |> element("#mark-waypoint") |> render_click()

    assert html =~ "não estou lendo tua posição"
    assert [%Route{waypoints: []}] = Store.all()
  end

  # It used to be REFUSED ("a rota é do andar 7"), which stopped the first
  # two-floor hunt Lucas tried to record (2026-08-10). A route may climb.
  test "a position from another floor is recorded, and the route says both floors",
       %{conn: conn} do
    {:ok, route} = Route.append(Route.new("cavena"), {1, 2, 7})
    :ok = Store.add(route)
    put_pos({5, 6, 3})

    {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

    html = view |> element("#mark-waypoint") |> render_click()

    assert html =~ "waypoint 2 marcado (andar 3)"
    assert [%Route{waypoints: [%{z: 7}, %{z: 3}]} = saved] = Store.all()
    assert Route.floors(saved) == [3, 7]
  end

  test "selecting another route directs marking to it", %{conn: conn} do
    :ok = Store.add(Route.new("primeira"))
    :ok = Store.add(Route.new("segunda"))
    put_pos({10, 20, 7})

    {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

    view
    |> form("#route-select-form", %{"name" => "segunda"})
    |> render_change()

    view |> element("#mark-waypoint") |> render_click()

    assert %Route{waypoints: [%{x: 10, y: 20, z: 7}]} =
             Enum.find(Store.all(), &(&1.name == "segunda"))

    assert %Route{waypoints: []} = Enum.find(Store.all(), &(&1.name == "primeira"))
  end

  test "creating a route with an existing name just selects it, without erasing waypoints", %{
    conn: conn
  } do
    {:ok, route} = Route.append(Route.new("cavena"), {1, 2, 7})
    :ok = Store.add(route)

    {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

    html =
      view
      |> form("#new-route-form", %{"name" => "cavena", "dungeon" => ""})
      |> render_submit()

    assert html =~ "já existe"
    assert [%Route{waypoints: [%{x: 1, y: 2, z: 7}]}] = Store.all()
  end

  # The flow that actually works: arm recording, go to the game, walk. One click
  # per waypoint is impossible — clicking fronts the browser, steals the game's
  # focus and can cover the minimap the position is read from. render/1 between
  # steps forces the flush: LiveView processes messages async, and without it all
  # three handle_info would read the SAME (last) position.
  test "recording while walking: waypoints enter on their own as the position changes", %{
    conn: conn
  } do
    put_pos({10, 20, 7})
    {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

    view
    |> form("#new-route-form", %{"name" => "cavena", "dungeon" => ""})
    |> render_submit()

    view |> element("#toggle-recording") |> render_click()

    put_pos({10, 20, 7})
    send(view.pid, {:world, :minimap, %{pos: {10, 20, 7}}})
    render(view)
    put_pos({20, 20, 7})
    send(view.pid, {:world, :minimap, %{pos: {20, 20, 7}}})
    render(view)
    put_pos({21, 20, 7})
    send(view.pid, {:world, :minimap, %{pos: {21, 20, 7}}})
    render(view)

    assert [%Route{waypoints: waypoints}] = Store.all()

    # every recorded waypoint now carries the clock: WHEN he laid it
    assert [
             %{x: 10, y: 20, z: 7, action: :walk, stops: [], at: %DateTime{}},
             %{x: 20, y: 20, z: 7, action: :walk, stops: [], at: %DateTime{}}
           ] = waypoints

    view |> element("#toggle-recording") |> render_click()
    assert render(view) =~ "gravação parada"
  end

  # "eu geralmente clico com o botão do meio do mouse em um ponto da minha
  # tela" (Lucas, 2026-08-11) — the marker he makes with his own hand, and the
  # spot the pokémon is parked on when the hunt runs this route.
  describe "the middle click marks the kill spot" do
    setup do
      {:ok, _} = Pokex.Rig.Fake.start_link(%{})
      :ok
    end

    # the Fake answers from its SCRIPT, and repeats the last entry forever
    # the Fake answers from its SCRIPT, and repeats the last entry forever
    # UM watch responde uma vez. O `Rig.Fake` repete a última entrada do roteiro
    # pra sempre (certo pra uma leitura de estado, como a posição do cursor, e
    # mentira pra um watch, que reporta "o que aconteceu desde a última vez").
    # Sem o silêncio no fim, um tique a mais — e numa máquina lenta ele vem —
    # relê os mesmos eventos e o combo sai duplicado: o CI pegou `["3", "3"]`
    # onde a máquina daqui sempre viu `["3"]` (25/08).
    defp clicks!(count, point, at \\ 0) do
      Agent.update(Pokex.Rig.Fake, fn state ->
        put_in(state.script[:middle_watch], [
          {:ok, %{count: count, point: point, at: at}},
          {:ok, %{count: 0, point: {0, 0}, at: 0}}
        ])
      end)
    end

    defp presses!(events) do
      Agent.update(Pokex.Rig.Fake, fn state ->
        put_in(state.script[:key_watch], [{:ok, events}, {:ok, []}])
      end)
    end

    test "a click while recording marks the spot and remembers the point", %{conn: conn} do
      put_pos({10, 20, 7})
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      view |> form("#new-route-form", %{"name" => "mob", "dungeon" => ""}) |> render_submit()
      view |> element("#toggle-recording") |> render_click()

      put_pos({10, 20, 7})
      send(view.pid, {:world, :minimap, %{pos: {10, 20, 7}}})
      render(view)

      # the first watch only learns the baseline — a session with clicks
      # already behind it must not mark on the first tick
      clicks!(7, {1000, 500})
      send(view.pid, :watch_middle)
      render(view)
      assert [%Route{waypoints: [%{action: :walk, park_point: nil}]}] = Store.all()

      # now HE clicks
      clicks!(8, {1240, 655})
      send(view.pid, :watch_middle)
      html = render(view)

      assert [%Route{waypoints: [wp]}] = Store.all()
      assert wp.action == :lure_end
      assert wp.park_point == {1240, 655}
      assert html =~ "clique do meio em 1240, 655"
    end

    # "shift+3 é pq eu já terminei de matar tudo, shift+1 é por que vou matar
    # monstro" (Lucas, 2026-08-11): the fight's boundaries, told by his hands.
    test "his own keys measure the fight, the huddle and the combo", %{conn: conn} do
      put_pos({10, 20, 7})
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      view |> form("#new-route-form", %{"name" => "mob", "dungeon" => ""}) |> render_submit()
      view |> element("#toggle-recording") |> render_click()

      put_pos({10, 20, 7})
      send(view.pid, {:world, :minimap, %{pos: {10, 20, 7}}})
      render(view)

      clicks!(1, {0, 0}, 0)
      send(view.pid, :watch_middle)
      render(view)

      # he parks the pokémon at 1_000 on the helper's clock
      clicks!(2, {1240, 655}, 1_000)
      presses!([])
      send(view.pid, :watch_middle)
      render(view)

      {:ok, one} = Pokex.Rig.Mac.Commands.keycode("1")
      {:ok, three} = Pokex.Rig.Mac.Commands.keycode("3")
      {:ok, five} = Pokex.Rig.Mac.Commands.keycode("5")

      # shift+1 opens the fight, skills fly, shift+3 closes it
      presses!([
        %{code: one, shift?: true, at: 4_000},
        %{code: five, shift?: false, at: 4_600},
        %{code: three, shift?: false, at: 5_000},
        %{code: three, shift?: true, at: 12_000}
      ])

      send(view.pid, :watch_middle)
      html = render(view)

      assert [%Route{waypoints: [wp]}] = Store.all()
      # from parking to the first skill — the huddle, MEASURED
      assert wp.gather_ms == 3_600
      assert wp.fight_ms == 8_000
      assert wp.combo == ["5", "3"]
      assert html =~ "luta de 8s medida aqui"
    end

    # The shape half of Meganium 1 has (2026-08-12): he kills the pile, takes
    # ONE step, and only then presses the shift+3 that closes the fight. The
    # lesson belongs to the "até aqui" he just closed — the only waypoint the
    # hunt ever reads it from — and the notice has to say so, because it is
    # not being written where he is standing.
    test "a fight closed one tile past the kill spot lands on the kill spot", %{conn: conn} do
      now = DateTime.utc_now()
      {:ok, route} = Route.append(Route.new("mob"), {10, 20, 7}, at: now)
      {:ok, route} = Route.append(route, {11, 20, 7}, at: now)

      route = Route.set_action(route, 0, :lure_end)
      :ok = Store.add(route)

      put_pos({11, 20, 7})
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")
      view |> element("#toggle-recording") |> render_click()

      send(view.pid, {:world, :minimap, %{pos: {11, 20, 7}}})
      render(view)

      clicks!(1, {0, 0}, 0)
      send(view.pid, :watch_middle)
      render(view)

      {:ok, one} = Pokex.Rig.Mac.Commands.keycode("1")
      {:ok, three} = Pokex.Rig.Mac.Commands.keycode("3")

      # shift+1 opens the fight on the kill spot behind him, a skill flies,
      # shift+3 closes it a tile later
      presses!([
        %{code: one, shift?: true, at: 1_000},
        %{code: three, shift?: false, at: 1_500},
        %{code: three, shift?: true, at: 9_000}
      ])

      send(view.pid, :watch_middle)
      html = render(view)

      assert [%Route{waypoints: [kill, standing]}] = Store.all()
      assert kill.fight_ms == 8_000
      assert kill.combo == ~w(3)
      assert standing.fight_ms == nil
      assert standing.combo == []

      # the waypoint numbers he reads on the page are 1-based
      assert html =~ "anotada no waypoint 1"
    end

    # Writing the combo per drain meant reading, decoding, encoding and
    # rewriting the WHOLE routes file eight times a second while he fought.
    # It is collected in memory and written on a conclusion.
    test "the combo is not written to disk until the fight closes", %{conn: conn} do
      put_pos({10, 20, 7})
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      view |> form("#new-route-form", %{"name" => "mob", "dungeon" => ""}) |> render_submit()
      view |> element("#toggle-recording") |> render_click()

      put_pos({10, 20, 7})
      send(view.pid, {:world, :minimap, %{pos: {10, 20, 7}}})
      render(view)

      clicks!(1, {0, 0}, 0)
      send(view.pid, :watch_middle)
      render(view)

      {:ok, one} = Pokex.Rig.Mac.Commands.keycode("1")
      {:ok, three} = Pokex.Rig.Mac.Commands.keycode("3")

      # mid-fight: skills flying, nothing concluded
      presses!([%{code: one, shift?: true, at: 1_000}, %{code: three, shift?: false, at: 1_200}])
      send(view.pid, :watch_middle)
      render(view)

      presses!([%{code: one, shift?: false, at: 1_400}])
      send(view.pid, :watch_middle)
      render(view)

      assert [%Route{waypoints: [%{combo: []}]}] = Store.all()

      # he closes it with shift+3: NOW the disk hears the whole thing
      presses!([%{code: three, shift?: true, at: 5_000}])
      send(view.pid, :watch_middle)
      render(view)

      assert [%Route{waypoints: [%{combo: ~w(3 1), fight_ms: 4_000}]}] = Store.all()
    end

    test "a combo he never closed is still written when recording stops", %{conn: conn} do
      put_pos({10, 20, 7})
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      view |> form("#new-route-form", %{"name" => "mob", "dungeon" => ""}) |> render_submit()
      view |> element("#toggle-recording") |> render_click()

      put_pos({10, 20, 7})
      send(view.pid, {:world, :minimap, %{pos: {10, 20, 7}}})
      render(view)

      clicks!(1, {0, 0}, 0)
      send(view.pid, :watch_middle)
      render(view)

      {:ok, five} = Pokex.Rig.Mac.Commands.keycode("5")
      presses!([%{code: five, shift?: false, at: 900}])
      send(view.pid, :watch_middle)
      render(view)

      view |> element("#toggle-recording") |> render_click()

      assert [%Route{waypoints: [%{combo: ~w(5)}]}] = Store.all()
    end

    # The helper polls inside its own loop and cannot know the recording
    # ended: without an off switch it reads ten key states every 8ms forever,
    # competing with the game he is playing.
    test "stopping the recording disarms the key watcher", %{conn: conn} do
      put_pos({10, 20, 7})
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      view |> form("#new-route-form", %{"name" => "mob", "dungeon" => ""}) |> render_submit()
      view |> element("#toggle-recording") |> render_click()
      view |> element("#toggle-recording") |> render_click()

      assert {:key_watch, []} in Pokex.Rig.Fake.calls()
    end

    test "no click, no mark", %{conn: conn} do
      put_pos({10, 20, 7})
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      view |> form("#new-route-form", %{"name" => "mob", "dungeon" => ""}) |> render_submit()
      view |> element("#toggle-recording") |> render_click()

      put_pos({10, 20, 7})
      send(view.pid, {:world, :minimap, %{pos: {10, 20, 7}}})
      render(view)

      clicks!(3, {1000, 500})
      send(view.pid, :watch_middle)
      send(view.pid, :watch_middle)
      render(view)

      assert [%Route{waypoints: [%{action: :walk, park_point: nil}]}] = Store.all()
    end
  end

  # The route knows a lot about his hunt now; the page has to SHOW it, or he
  # cannot judge a recording before running it.
  describe "what the waypoint learned, on screen" do
    test "a kill spot shows the point, the huddle, the fight and the combo", %{conn: conn} do
      {:ok, route} = Route.append(Route.new("mob"), {10, 10, 7})

      :ok =
        route
        |> Route.set_park_point(0, {2490, 417})
        |> Route.set_timing(0,
          gather_ms: 3_300,
          fight_ms: 9_900,
          combo: ~w(1 1 3 3 3 4 4 5)
        )
        |> Store.add()

      {:ok, _view, html} = live(conn, ~p"/cavebot?modo=editar")

      assert html =~ "🖱️ 2490, 417"
      assert html =~ "bolo 3.3s"
      assert html =~ "luta 9.9s"
      # the INTENT, not the mashing
      assert html =~ "💥 1 3 4 5"
      refute html =~ "1 1 3 3 3"
    end

    test "a plain corner says nothing — forty empty lines would bury the four", %{conn: conn} do
      route_with([{10, 10, 7}, {20, 10, 7}])

      {:ok, _view, html} = live(conn, ~p"/cavebot?modo=editar")

      refute html =~ ~s(id="waypoint-taught-0")
      refute html =~ ~s(id="waypoint-taught-1")
    end

    # "as telas tao mal integradas poxa" — the keys live here, what they MEAN
    # lives on the team page, and neither one used to mention the other.
    test "a recorded combo points at the page that says what the keys do", %{conn: conn} do
      {:ok, route} = Route.append(Route.new("mob"), {10, 10, 7})
      {:ok, route} = Route.append(route, {20, 10, 7})

      :ok =
        route
        |> Route.set_timing(0, combo: ~w(3 4))
        |> Route.set_timing(1, fight_ms: 4_000)
        |> Store.add()

      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      assert view |> element("#waypoint-taught-0") |> render() =~ ~s(href="/time")
      # the waypoint that only timed a fight has no keys to explain
      refute view |> element("#waypoint-taught-1") |> render() =~ ~s(href="/time")
    end
  end

  # THE bug of the first timed recording (2026-08-11): all 52 waypoints of his
  # first real route came back with dwell nil. Standing still is exactly when
  # the client STOPS drawing the coordinate, so the reader answers nil and two
  # equal readings never arrive — stillness was being measured with the one
  # signal that vanishes during it.
  describe "how long he stood there" do
    defp recording!(view) do
      view |> form("#new-route-form", %{"name" => "medida", "dungeon" => ""}) |> render_submit()
      view |> element("#toggle-recording") |> render_click()
    end

    defp reading!(view, pos) do
      put_pos(pos)
      send(view.pid, {:world, :minimap, %{pos: pos}})
      render(view)
    end

    test "the dwell is counted even when the coordinate goes unreadable", %{conn: conn} do
      Pokex.SettingsStash.stash!(
        cavebot_record_dwell_ms: 500,
        cavebot_record_fight_dwell_ms: 1_000
      )

      put_pos({10, 20, 7})
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")
      recording!(view)

      reading!(view, {10, 20, 7})

      # he stops: the client stops drawing the coordinate, so every reading
      # from here on is nil — which is the SYMPTOM of standing still
      Process.sleep(1_100)
      reading!(view, nil)

      assert [%Route{waypoints: waypoints}] = Store.all()
      assert %{dwell_ms: dwell} = List.last(waypoints)
      assert dwell >= 1_000

      # …and the stop was long enough to be read as a kill spot
      assert %{action: :lure_end} = List.last(waypoints)
    end

    test "walking on keeps every dwell short and marks nothing", %{conn: conn} do
      Pokex.SettingsStash.stash!(
        cavebot_record_dwell_ms: 500,
        cavebot_record_fight_dwell_ms: 1_000
      )

      put_pos({10, 20, 7})
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")
      recording!(view)

      reading!(view, {10, 20, 7})
      reading!(view, {20, 20, 7})
      reading!(view, {30, 20, 7})

      assert [%Route{waypoints: waypoints}] = Store.all()
      assert Enum.all?(waypoints, &(&1.action == :walk))
    end
  end

  # The tile at the top of a staircase shares x/y with the one at its foot, so
  # the "far enough to be a new corner" rule would drop the one waypoint that
  # teaches the route the upper floor exists — and then the hunt blocks up
  # there on a floor it never heard of.
  test "a CLIMB is always recorded, however little the tile moved", %{conn: conn} do
    put_pos({10, 20, 7})
    {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

    view |> form("#new-route-form", %{"name" => "escada", "dungeon" => ""}) |> render_submit()
    view |> element("#toggle-recording") |> render_click()

    put_pos({10, 20, 7})
    send(view.pid, {:world, :minimap, %{pos: {10, 20, 7}}})
    render(view)

    # one tile up the stairs: same x, y one apart — nowhere near min_tiles
    put_pos({10, 19, 6})
    send(view.pid, {:world, :minimap, %{pos: {10, 19, 6}}})
    render(view)

    assert [%Route{waypoints: [%{z: 7}, %{z: 6}]} = route] = Store.all()
    assert Route.floors(route) == [6, 7]
  end

  test "recording without an active route warns instead of recording into the void", %{conn: conn} do
    put_pos({10, 20, 7})
    {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

    html = view |> element("#toggle-recording") |> render_click()

    assert html =~ "crie ou selecione uma rota"
    assert Store.all() == []
  end

  # the coordinate read is all-or-nothing (a doubtful glyph reads "?"); occasional
  # failures don't block recording, but the ok/fail ratio tells whether the
  # recorded route can be trusted
  test "shows read health: how many reads succeeded and how many failed",
       %{conn: conn} do
    put_pos({10, 20, 7})
    {:ok, view, _html} = live(conn, ~p"/cavebot")

    put_pos({10, 20, 7})
    send(view.pid, {:world, :minimap, %{pos: {10, 20, 7}}})
    render(view)

    WorldState.put(:minimap, %{pos: nil}, System.monotonic_time(:millisecond))
    send(view.pid, {:world, :minimap, %{pos: nil}})

    html = render(view)
    assert html =~ "1 ok"
    assert html =~ "1 falhas"
  end

  # ---------------------------------------------------------------------------
  # The control room: the world beside the route, and a route you can EDIT.
  # ---------------------------------------------------------------------------

  defp route_with(waypoints, name \\ "cavena") do
    route =
      Enum.reduce(waypoints, Route.new(name), fn pos, r ->
        {:ok, r} = Route.append(r, pos)
        r
      end)

    :ok = Store.add(route)
    route
  end

  test "the world strip reads the facts the bot reads", %{conn: conn} do
    put_pos({10, 20, 7})

    {:ok, _view, html} = live(conn, ~p"/cavebot")

    assert html =~ ~s(id="tile-pos")
    assert html =~ ~s(id="tile-read")
    assert html =~ ~s(id="tile-enemies")
    assert html =~ ~s(id="tile-hunt")
    assert html =~ ~s(id="tile-capture")
    # every tile spells its state in WORDS beside the colour
    assert html =~ "lendo tua posição" or html =~ "ainda não li"
    assert html =~ "corpos na fila"
  end

  test "the hunt's own snapshot lands on the strip", %{conn: conn} do
    put_pos({10, 20, 7})
    {:ok, view, _html} = live(conn, ~p"/cavebot")

    send(
      view.pid,
      {:cavebot, %{state: :stuck, hold_reason: "parei: bati numa parede", capture_pending: 3}}
    )

    html = render(view)
    assert html =~ "presa"
    assert html =~ "parei: bati numa parede"

    # Through the TILE, never through `">3<"`: that shape asserted the
    # formatter's line breaks, and it broke the day a class list grew long
    # enough for `mix format` to reflow the value onto its own line.
    assert view |> element("#tile-capture") |> render() =~ "3"
  end

  test "the route is DRAWN: waypoints, the character, and the walked order", %{conn: conn} do
    route_with([{10, 10, 7}, {20, 10, 7}, {20, 25, 7}])
    put_pos({12, 10, 7})

    {:ok, _view, html} = live(conn, ~p"/cavebot?modo=editar")

    assert html =~ ~s(id="route-map")
    assert html =~ ~s(id="map-waypoint-0")
    assert html =~ ~s(id="map-waypoint-2")
    assert html =~ ~s(id="map-here")
    # the text alternative to the drawing, for screen readers
    assert html =~ "Mapa da rota: 3 waypoints, 25 tiles"
  end

  test "clicking a waypoint on the map selects it in the editor", %{conn: conn} do
    route_with([{10, 10, 7}, {20, 10, 7}])
    {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

    html = view |> element("#map-waypoint-1") |> render_click()
    assert html =~ "border-pk-warn bg-pk-warn-dim"

    # clicking it again lets it go
    html = view |> element("#map-waypoint-1") |> render_click()
    refute html =~ "border-pk-warn bg-pk-warn-dim"
  end

  test "waypoints reorder, insert at a place and clear — no re-walking", %{conn: conn} do
    route_with([{10, 10, 7}, {20, 10, 7}, {30, 10, 7}])
    put_pos({15, 10, 7})

    {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

    view |> element("#waypoint-down-0") |> render_click()
    assert [%Route{waypoints: [%{x: 20}, %{x: 10}, %{x: 30}]}] = Store.all()

    view |> element("#waypoint-up-1") |> render_click()
    assert [%Route{waypoints: [%{x: 10}, %{x: 20}, %{x: 30}]}] = Store.all()

    # the missing corner in the MIDDLE: stand there and insert
    view |> element("#waypoint-insert-1") |> render_click()
    assert [%Route{waypoints: [%{x: 10}, %{x: 15}, %{x: 20}, %{x: 30}]}] = Store.all()

    view |> element("#clear-route") |> render_click()
    assert [%Route{waypoints: []}] = Store.all()
  end

  test "the ends of a route move nothing — the button is a no-op, never an error", %{conn: conn} do
    route_with([{10, 10, 7}, {20, 10, 7}])
    {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

    assert view |> element("#waypoint-up-0") |> render() =~ "disabled"
    assert view |> element("#waypoint-down-1") |> render() =~ "disabled"
  end

  test "a route can be switched off without being deleted, and deleted with its photos", %{
    conn: conn
  } do
    route_with([{10, 10, 7}])
    {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

    view |> element("#toggle-route-enabled") |> render_click()
    assert [%Route{enabled?: false}] = Store.all()

    view |> element("#delete-route") |> render_click()
    assert Store.all() == []
  end

  test "the hunt's narration lands on the page — 'parou' becomes 'parou por quê'", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/cavebot")

    send(view.pid, {:cavebot_log, :macro, "caçada: waypoint 2/4 alcançado"})
    send(view.pid, {:cavebot_log, :debug, "caçada: passo 5,0"})

    html = render(view)
    assert html =~ ~s(id="cavebot-log")
    assert html =~ "waypoint 2/4 alcançado"

    # step-by-step chatter is diagnosis, and it drowns the feed he reads at a
    # glance: it waits behind the debug switch, exactly like the panel's
    refute html =~ "passo 5,0"
    assert view |> element("#cavebot-log-debug") |> render_click() =~ "passo 5,0"
  end

  # A revive that failed belongs where he is watching the hunt, not only in the
  # panel he does not have open.
  test "the support's own lines land in the hunt's feed too", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/cavebot")

    send(view.pid, {:game_log, :macro, "🚑 stun do resgate: 1"})
    send(view.pid, {:rule_alarm, "💀 o revive do caído NÃO saiu"})

    html = render(view)
    assert html =~ "stun do resgate"
    assert html =~ "revive do caído"
  end

  # Na tela que ele mandou em 28/08, SEIS das catorze linhas eram a mesma frase
  # repetida no mesmo segundo. Colapsar não esconde — o ×N fica visível, que é
  # o que deixa a repetição diagnosticável em vez de só ilegível.
  test "a mesma linha repetida vira uma linha com contador", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/cavebot")

    for _ <- 1..3, do: send(view.pid, {:cavebot_log, :macro, "caçada: waypoint 7/40 ⏭ pulei"})

    feed = view |> element("#cavebot-log-lines") |> render()

    assert feed =~ "×3"

    assert feed |> String.split("waypoint 7/40") |> length() == 2,
           "a linha não pode aparecer duas vezes"
  end

  test "linhas diferentes seguem sendo linhas diferentes", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/cavebot")

    send(view.pid, {:cavebot_log, :macro, "caçada: waypoint 7/40"})
    send(view.pid, {:cavebot_log, :macro, "caçada: waypoint 8/40"})
    send(view.pid, {:cavebot_log, :macro, "caçada: waypoint 7/40"})

    feed = view |> element("#cavebot-log-lines") |> render()

    refute feed =~ "×"
    assert feed |> String.split("waypoint 7/40") |> length() == 3
  end

  # A PERGUNTA DA MADRUGADA. Cada linha deste selo tem uma noite atrás dela: o
  # resgate desligado deixou o cérebro pedir revive 556 vezes sem que uma tecla
  # saísse (27/08), e o estoque acabou às 23:43 e ele moeu 4,9 horas com o
  # pokémon no chão (28/08). Os fatos já estavam todos na tela, espalhados e em
  # voz baixa; o selo junta e responde UMA coisa.
  describe "pronto pra noite" do
    test "com tudo armado, o selo diz que pode dormir", %{conn: conn} do
      Pokex.SettingsStash.stash!(
        rescue_enabled: true,
        engine_band_yellow_pct: 60,
        revive_stock: 0
      )

      {:ok, view, _html} = live(conn, ~p"/cavebot")

      assert view |> element("#cavebot-ready") |> render() =~ "pronto pra noite"
      refute has_element?(view, "#cavebot-ready-list")
    end

    test "o resgate desligado é dito por extenso, não escondido num title", %{conn: conn} do
      Pokex.SettingsStash.stash!(rescue_enabled: false, engine_band_yellow_pct: 60)

      {:ok, view, _html} = live(conn, ~p"/cavebot")

      assert view |> element("#cavebot-ready") |> render() =~ "1 coisa antes de dormir"
      assert view |> element("#cavebot-ready-list") |> render() =~ "ninguém revive o pokémon"
    end

    test "o estoque zerado entra na conta junto", %{conn: conn} do
      Pokex.SettingsStash.stash!(
        rescue_enabled: false,
        engine_band_yellow_pct: 0,
        revive_stock: 3
      )

      Pokex.Bots.ReviveLedger.reset()
      Enum.each(1..3, fn _ -> Pokex.Bots.ReviveLedger.note() end)
      on_exit(&Pokex.Bots.ReviveLedger.reset/0)

      {:ok, view, _html} = live(conn, ~p"/cavebot")
      lista = view |> element("#cavebot-ready-list") |> render()

      assert view |> element("#cavebot-ready") |> render() =~ "3 coisas antes de dormir"
      assert lista =~ "revives acabaram"
      assert lista =~ "faixa amarela está em 0"
    end
  end

  # "Queria conseguir JOGAR o jogo totalmente pela tela do cave bot (…) preciso
  # da tela me dando um pouco mais de detalhes do que a IA tá vendo sobre o
  # mundo, até para eu tb ajudar a dar feedbacks sobre pontos que ela tá vendo
  # errado — já aconteceu antes onde o problema não era no algoritmo da engine
  # e sim na detecção correta de dados pelas imagens" (28/08).
  describe "o que ele está vendo" do
    defp see_world(pokemon_hp, player_hp, rows) do
      now = System.monotonic_time(:millisecond)
      WorldState.put(:pokemon, %{hp_pct: pokemon_hp, readable?: true, fainted?: false}, now)
      # O FATO `:player` CARREGA AS DUAS VIDAS: `hp_pct` é a do POKÉMON (a
      # Pokebar que o suporte lê) e `player_hp` é a DELE. Esta fixture dizia o
      # contrário e por isso o cartão passava lendo o campo errado (03/09).
      WorldState.put(:player, %{hp_pct: pokemon_hp, player_hp: player_hp, readable?: true}, now)

      WorldState.put(
        :battle,
        %{enemies: Enum.to_list(0..(length(rows) - 1)//1), enemies_detail: rows, locked?: false},
        now
      )

      on_exit(fn -> Enum.each([:pokemon, :player, :battle], &WorldState.forget/1) end)
    end

    test "as duas vidas viram barra: a dele e a do pokémon", %{conn: conn} do
      see_world(61, 83, [])

      {:ok, view, _html} = live(conn, ~p"/cavebot")
      vision = view |> element("#cavebot-vision") |> render()

      assert vision =~ "você"
      assert vision =~ "83%"
      assert vision =~ "61%"
      assert vision =~ "width: 83%"
    end

    # Sem leitura NÃO é zero: uma barra vazia com cara de 0% é como uma janela
    # minimizada vira "meu pokémon está morrendo".
    test "sem leitura, a barra diz que não sabe em vez de mostrar zero", %{conn: conn} do
      see_world(nil, nil, [])

      {:ok, view, _html} = live(conn, ~p"/cavebot")
      vision = view |> element("#cavebot-vision") |> render()

      assert vision =~ "sem leitura"
      assert vision =~ "marque na calibração"
    end

    # A lista LIDA, linha por linha: é onde um erro de detecção aparece antes
    # de virar decisão errada.
    test "cada linha da lista de batalha aparece com a vida que ele leu", %{conn: conn} do
      see_world(100, 100, [
        %{row: 0, name: "Magneton", hp_pct: 1.0, shiny?: false},
        %{row: 1, name: nil, hp_pct: 0.35, shiny?: false}
      ])

      {:ok, view, _html} = live(conn, ~p"/cavebot")
      vision = view |> element("#cavebot-vision") |> render()

      assert vision =~ "Magneton"
      assert vision =~ "100%"
      assert vision =~ "35%"
      # a linha sem nome legível é dita como tal, nunca inventada
      assert vision =~ "?"
    end

    # "É legal que a UI deixe claro sempre que o primeiro monstro ali é o meu
    # próprio, para não ficar confuso" (28/08). Quem decide qual linha é dele é
    # o CÉREBRO (`Situation.named` já vem sem ela); a tela repete a decisão.
    test "a linha do próprio pokémon é marcada, e não conta como inimigo", %{conn: conn} do
      see_world(100, 100, [
        %{row: 0, name: "Steelix", hp_pct: 0.7, shiny?: false},
        %{row: 1, name: "Magneton", hp_pct: 1.0, shiny?: false}
      ])

      # O quadro sai do CÉREBRO de verdade, não de um mapa à mão: a tela lê a
      # decisão dele, e um mapa inventado aqui provaria outra coisa.
      quadro =
        Pokex.Bots.Engine.Situation.build(
          %{
            battle: %{
              enemies: [0, 1],
              enemies_detail: [
                %{row: 0, name: "Steelix", hp_pct: 0.7, shiny?: false},
                %{row: 1, name: "Magneton", hp_pct: 1.0, shiny?: false}
              ]
            },
            own_name: "Steelix",
            own_out?: true,
            own_hp: 70
          },
          %{engage_from: 3},
          System.monotonic_time(:millisecond)
        )

      WorldState.put(:situation, quadro, System.monotonic_time(:millisecond))

      on_exit(fn -> WorldState.forget(:situation) end)

      {:ok, view, _html} = live(conn, ~p"/cavebot")
      vision = view |> element("#cavebot-vision") |> render()

      # a contagem é a do cérebro (1 inimigo), não o número de linhas (2)
      assert quadro.enemies == 1
      assert quadro.own_row_seen? == true
      # a linha dele tem o marcador; a do Magneton não
      assert vision =~ "hero-user-circle"
      assert vision =~ "text-pk-ok"
    end

    # A caixa não pode pular de altura a cada bicho que entra ou sai: o que ele
    # estava lendo embaixo dela some do lugar.
    test "a caixa da lista tem altura fixa, com ou sem mobada", %{conn: conn} do
      see_world(100, 100, [%{row: 0, name: "Magneton", hp_pct: 1.0, shiny?: false}])

      {:ok, view, _html} = live(conn, ~p"/cavebot")

      assert view |> element("#cavebot-battle-rows") |> render() =~ "h-[4.5rem]"
    end

    test "tela limpa é dita, não deixada em branco", %{conn: conn} do
      see_world(100, 100, [])

      {:ok, view, _html} = live(conn, ~p"/cavebot")

      assert view |> element("#cavebot-vision") |> render() =~ "nada na lista"
    end
  end

  test "the rehearsal names WHICH link broke, not just 'não andou'", %{conn: conn} do
    route_with([{10, 10, 7}])
    {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

    # no position read: nothing is pressed, and the screen says why
    send(view.pid, {:walk_test, {:error, :no_position}})
    html = render(view)
    assert html =~ ~s(id="walk-test-result")
    assert html =~ "coordenada não está sendo lida"

    send(view.pid, {:walk_test, {:error, :did_not_move}})
    assert render(view) =~ "teclas não estão chegando no jogo"

    send(
      view.pid,
      {:walk_test, {:ok, %{from: {10, 10, 7}, to: {13, 10, 7}, tiles: 3, presses: ["right"]}}}
    )

    html = render(view)
    assert html =~ "andou 3 tile(s)"
    assert html =~ "10, 10 → 13, 10"
  end

  test "the rehearsal button is there and arms without a hunt", %{conn: conn} do
    route_with([{10, 10, 7}])
    {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

    html = view |> element("#walk-test") |> render_click()
    assert html =~ "andando…"
  end

  # A task that dies must never leave the button spinning with nothing to
  # click — the state it was left in when its default hands did not exist.
  test "a rehearsal that dies mid-way says so instead of spinning forever", %{conn: conn} do
    route_with([{10, 10, 7}])
    {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

    view |> element("#walk-test") |> render_click()
    ref = :sys.get_state(view.pid).socket.assigns.walk_ref
    send(view.pid, {:DOWN, ref, :process, self(), {:badarg, []}})

    html = render(view)
    assert html =~ "o teste morreu no meio"
    refute html =~ "andando…"
  end

  test "the route photos have their place before they exist", %{conn: conn} do
    route_with([{10, 10, 7}])
    {:ok, _view, html} = live(conn, ~p"/cavebot?modo=editar")

    assert html =~ ~s(id="route-photos")
    assert html =~ "início da rota"
    assert html =~ "fim da rota"
    assert html =~ "sai sozinha quando você gravar"
  end

  # 2026-08-11, live: two routes armed at once, the hunt walked the OTHER one
  # and blocked on the first step while the page said this one was "a que a
  # caçada vai andar".
  describe "which route the hunt actually walks" do
    test "arming one disarms the others, and the page says which is armed", %{conn: conn} do
      {:ok, a} = Route.append(Route.new("teste"), {10, 10, 5})
      {:ok, b} = Route.append(Route.new("azumaril"), {10, 10, 1})
      :ok = Store.add(%{a | enabled?: true})
      :ok = Store.add(%{b | enabled?: true})

      {:ok, view, html} = live(conn, ~p"/cavebot?modo=editar")

      # "teste" is the one the hunt would take (first armed); the page is
      # showing it, so no warning yet
      refute html =~ ~s(id="armed-elsewhere")

      view |> form("#route-select-form", %{"name" => "azumaril"}) |> render_change()
      html = render(view)
      assert html =~ ~s(id="armed-elsewhere")
      assert html =~ "a caçada vai andar &quot;teste&quot;"

      # the warning carries its own cure: with two armed, the on/off toggle
      # would turn THIS one off, which is the opposite of what he wants
      html = view |> element("#arm-this-route") |> render_click()
      refute html =~ ~s(id="armed-elsewhere")
      assert Store.all() |> Enum.filter(& &1.enabled?) |> Enum.map(& &1.name) == ["azumaril"]
    end

    test "no route armed at all says so", %{conn: conn} do
      {:ok, a} = Route.append(Route.new("teste"), {10, 10, 5})
      :ok = Store.add(%{a | enabled?: false})

      {:ok, _view, html} = live(conn, ~p"/cavebot?modo=editar")

      assert html =~ ~s(id="none-armed")
    end
  end

  # "to fazendo justamente uma rota com 2 andares, com escadas" (Lucas,
  # 2026-08-10). A flat drawing puts both floors on top of each other, so
  # where the floor changes has to be WRITTEN.
  describe "a route with stairs" do
    defp stairs_route! do
      {:ok, route} = Route.append(Route.new("escada"), {10, 10, 7})
      {:ok, route} = Route.append(route, {15, 10, 7})
      {:ok, route} = Route.append(route, {15, 10, 6})
      :ok = Store.add(route)
    end

    test "the header counts the floors, not just the first", %{conn: conn} do
      stairs_route!()
      {:ok, _view, html} = live(conn, ~p"/cavebot?modo=editar")

      assert html =~ "andares 6 e 7"
      refute html =~ "andar 7</span>"
    end

    test "the climb is written on the waypoint it lands on, and drawn dotted", %{conn: conn} do
      stairs_route!()
      {:ok, _view, html} = live(conn, ~p"/cavebot?modo=editar")

      assert html =~ "⇅ andar 6"
      assert html =~ ~s(stroke-dasharray="1 2")
      assert html =~ "Mapa da rota: 3 waypoints"
      assert html =~ "andares 6 e 7"
    end

    # "seria legal cores diferentes no mapa com as marcacoes vistas de acordo
    # com o andar que estou" (Lucas, 2026-08-11) — a flat drawing stacks the
    # floors on top of each other otherwise.
    test "the map fades everything that is not on MY floor", %{conn: conn} do
      stairs_route!()
      put_pos({10, 10, 7})

      {:ok, _view, html} = live(conn, ~p"/cavebot?modo=editar")

      assert html =~ ~s(id="map-floor-legend")
      assert html =~ "andar 7 · outros apagados"
      assert html =~ ~s(opacity="0.3")
    end

    test "with every waypoint on my floor there is nothing to fade", %{conn: conn} do
      route_with([{10, 10, 7}, {20, 10, 7}])
      put_pos({10, 10, 7})

      {:ok, _view, html} = live(conn, ~p"/cavebot?modo=editar")

      refute html =~ ~s(id="map-floor-legend")
    end

    test "a one-floor route says nothing about floors on its waypoints", %{conn: conn} do
      route_with([{10, 10, 7}, {20, 10, 7}])
      {:ok, _view, html} = live(conn, ~p"/cavebot?modo=editar")

      assert html =~ "andar 7"
      refute html =~ "⇅ andar"
      refute html =~ ~s(stroke-dasharray="1 2")
    end
  end

  # "tem como eu editar na mao pontos da rota?" (Lucas, 2026-08-11) — the thin
  # staircase whose exact tile the walk rounded past.
  describe "correcting a point by hand" do
    test "typing the tile moves the waypoint and keeps its marks", %{conn: conn} do
      route_with([{10, 10, 7}, {20, 10, 7}])
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      view |> element("#map-waypoint-1") |> render_click()
      view |> element("#waypoint-1-lure_end") |> render_click()

      html =
        view
        |> form("#waypoint-place-1", %{"x" => "21", "y" => "11", "z" => "6"})
        |> render_submit()

      assert [%Route{waypoints: [_first, %{x: 21, y: 11, z: 6, action: :lure_end}]}] = Store.all()
      assert html =~ "waypoint 2 corrigido: 21, 11 (andar 6)"
    end

    test "a blank field keeps what was there", %{conn: conn} do
      route_with([{10, 10, 7}])
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      view |> element("#map-waypoint-0") |> render_click()
      view |> form("#waypoint-place-0", %{"x" => "15", "y" => "", "z" => ""}) |> render_submit()

      assert [%Route{waypoints: [%{x: 15, y: 10, z: 7}]}] = Store.all()
    end

    test "garbage is refused, and nothing moves", %{conn: conn} do
      route_with([{10, 10, 7}])
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      view |> element("#map-waypoint-0") |> render_click()
      html = view |> form("#waypoint-place-0", %{"x" => "abc"}) |> render_submit()

      assert html =~ "coordenada inválida"
      assert [%Route{waypoints: [%{x: 10, y: 10, z: 7}]}] = Store.all()
    end

    test "'é aqui que eu estou' uses the live position", %{conn: conn} do
      route_with([{10, 10, 7}])
      put_pos({33, 44, 5})
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      view |> element("#map-waypoint-0") |> render_click()
      html = view |> element("#waypoint-place-here-0") |> render_click()

      assert [%Route{waypoints: [%{x: 33, y: 44, z: 5}]}] = Store.all()
      assert html =~ "agora é 33, 44"
    end
  end

  # "um ponto que eu senti falta aqui é eu poder calibrar melhor a parte de
  # onde ele clica com o botão do meio. Talvez até uma distância do meu
  # personagem, algo assim mais fácil de eu poder medir e algo que eu possa
  # configurar ali pela interface" (Lucas, 2026-08-11).
  describe "where the pokémon is sent, in tiles" do
    setup do
      Pokex.Calibration.save(%Pokex.Calibration{
        scale: 1.0,
        screen_w: 3440,
        screen_h: 1440,
        player_point: {1700, 700}
      })

      before = Pokex.Settings.get(:tile_px)
      on_exit(fn -> Pokex.Settings.put(:tile_px, before) end)
      Pokex.Settings.put(:tile_px, 100)
      :ok
    end

    test "typing a distance saves it, and the hint says where it lands", %{conn: conn} do
      route_with([{10, 10, 7}])
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      view |> element("#map-waypoint-0") |> render_click()

      html =
        view
        |> form("#waypoint-park-0", %{"park_x" => "6", "park_y" => "-2", "tile_px" => "100"})
        |> render_submit()

      assert [%Route{waypoints: [%{park_tiles: {6, -2}}]}] = Store.all()
      assert html =~ "pokémon a 6, -2 tiles de você"
      # 1700 + 6×100, 700 − 2×100
      assert view |> element("#waypoint-park-hint-0") |> render() =~ "2300, 500"
    end

    # His recorded click is the same answer written in the window's
    # coordinates: the form opens with it already converted.
    test "a recorded click opens as a distance", %{conn: conn} do
      {:ok, route} = Route.append(Route.new("cavena"), {10, 10, 7})
      :ok = route |> Route.set_park_point(0, {2300, 500}) |> Store.add()

      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")
      view |> element("#map-waypoint-0") |> render_click()

      assert view |> element("#waypoint-park-0") |> render() =~ ~s(value="6")
    end

    test "the ruler saved with it is the unit of the numbers above it", %{conn: conn} do
      route_with([{10, 10, 7}])
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      view |> element("#map-waypoint-0") |> render_click()

      view
      |> form("#waypoint-park-0", %{"park_x" => "1", "park_y" => "0", "tile_px" => "131"})
      |> render_submit()

      assert Pokex.Settings.get(:tile_px) == 131
      assert view |> element("#waypoint-park-hint-0") |> render() =~ "1831, 700"
    end

    test "'virar padrão' answers for every kill spot that has none", %{conn: conn} do
      route_with([{10, 10, 7}, {20, 10, 7}])

      before =
        {Pokex.Settings.get(:cavebot_park_tiles_x), Pokex.Settings.get(:cavebot_park_tiles_y)}

      on_exit(fn ->
        Pokex.Settings.put(:cavebot_park_tiles_x, elem(before, 0))
        Pokex.Settings.put(:cavebot_park_tiles_y, elem(before, 1))
      end)

      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      view |> element("#map-waypoint-0") |> render_click()

      view
      |> form("#waypoint-park-0", %{"park_x" => "-3", "park_y" => "1", "tile_px" => "100"})
      |> render_submit()

      view |> element("#waypoint-park-default-0") |> render_click()

      assert Pokex.Settings.get(:cavebot_park_tiles_x) == -3
      assert Pokex.Settings.get(:cavebot_park_tiles_y) == 1

      # …and the waypoint with nothing of its own now says so
      view |> element("#map-waypoint-1") |> render_click()
      assert view |> element("#waypoint-park-hint-1") |> render() =~ "padrão da caçada: -3, 1"
    end

    test "tirar takes the waypoint back to having no spot", %{conn: conn} do
      route_with([{10, 10, 7}])
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      view |> element("#map-waypoint-0") |> render_click()

      view
      |> form("#waypoint-park-0", %{"park_x" => "6", "park_y" => "-2", "tile_px" => "100"})
      |> render_submit()

      view |> element("#waypoint-park-clear-0") |> render_click()

      assert [%Route{waypoints: [%{park_tiles: nil, park_point: nil}]}] = Store.all()
    end
  end

  # "quero poder configurar individualmente cada bolinha, para dar uma
  # funcionalidade dela, tipo 'mobar daqui' e marcar em outra 'até aqui'"
  # (Lucas, 2026-08-10).
  describe "a waypoint carries a job" do
    test "the job buttons appear on the SELECTED waypoint and nowhere else", %{conn: conn} do
      route_with([{10, 10, 7}, {20, 10, 7}])
      {:ok, view, html} = live(conn, ~p"/cavebot?modo=editar")

      refute html =~ ~s(id="waypoint-job-0")

      html = view |> element("#map-waypoint-0") |> render_click()
      assert html =~ ~s(id="waypoint-job-0")
      refute html =~ ~s(id="waypoint-job-1")
      assert html =~ "mobar daqui"
    end

    test "marking a stretch persists it and paints the leg blue", %{conn: conn} do
      route_with([{10, 10, 7}, {20, 10, 7}, {20, 20, 7}])
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      view |> element("#map-waypoint-0") |> render_click()
      view |> element("#waypoint-0-lure_start") |> render_click()

      view |> element("#map-waypoint-1") |> render_click()
      html = view |> element("#waypoint-1-lure_end") |> render_click()

      assert [%Route{waypoints: [%{action: :lure_start}, %{action: :lure_end}, %{action: :walk}]}] =
               Store.all()

      # the drawing says it in blue, the badge and the summary say it in words
      assert html =~ "var(--color-pk-info)"
      assert html =~ ~s(id="map-lure-legend")
      assert html =~ "1 perna(s) em modo mob"
    end

    test "a plain route is not blue anywhere", %{conn: conn} do
      route_with([{10, 10, 7}, {20, 10, 7}, {20, 20, 7}])
      {:ok, _view, html} = live(conn, ~p"/cavebot?modo=editar")

      refute html =~ "var(--color-pk-info)"
      refute html =~ ~s(id="map-lure-legend")
    end

    # A start nobody closed lures the WHOLE loop — which on screen looks like
    # "the hunt stopped fighting", with no error anywhere.
    test "a stretch left open warns, and closing it takes the warning away", %{conn: conn} do
      route_with([{10, 10, 7}, {20, 10, 7}])
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      view |> element("#map-waypoint-0") |> render_click()
      html = view |> element("#waypoint-0-lure_start") |> render_click()
      assert html =~ ~s(id="lure-warning")
      assert html =~ "sem &quot;até aqui&quot;"

      view |> element("#map-waypoint-1") |> render_click()
      html = view |> element("#waypoint-1-lure_end") |> render_click()
      refute html =~ ~s(id="lure-warning")
    end

    # The job and the stops are separate axes: the waypoint that ends the
    # gathering is exactly the one worth reviving at, so the two marks must not
    # compete for the one slot.
    test "a waypoint can gather AND reset cooldowns AND wait", %{conn: conn} do
      route_with([{10, 10, 7}, {20, 10, 7}])
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      view |> element("#map-waypoint-1") |> render_click()
      view |> element("#waypoint-1-lure_end") |> render_click()
      view |> element("#waypoint-1-wait") |> render_click()
      html = view |> element("#waypoint-1-cooldown_revive") |> render_click()

      assert [
               %Route{
                 waypoints: [_first, %{action: :lure_end, stops: [:cooldown_revive, :wait]}]
               }
             ] = Store.all()

      assert html =~ "resetar cooldown"
      assert html =~ "esperar"

      # and each toggles back off on its own
      view |> element("#waypoint-1-wait") |> render_click()
      assert [%Route{waypoints: [_first, %{stops: [:cooldown_revive]}]}] = Store.all()
    end

    # A route recorded before 2026-08-28 carries `"sweep"` in its stops, and the
    # Catcher refused it in every hunt anyway. It loads without the mark rather
    # than crashing, and nothing on the page offers it back.
    test "a route saved with the old varrer stop loads without it", %{conn: conn} do
      route_with([{10, 10, 7}, {20, 10, 7}])
      [%Route{name: name}] = Store.all()
      path = Path.join(Pokex.Home.dir(), "routes.json")

      patched =
        path
        |> File.read!()
        |> JSON.decode!()
        |> update_in(["routes"], fn routes ->
          Enum.map(routes, fn route ->
            update_in(route, ["waypoints"], fn [first | rest] ->
              [Map.put(first, "stops", ["sweep", "cooldown_revive"]) | rest]
            end)
          end)
        end)

      File.write!(path, JSON.encode!(patched))

      assert [%Route{name: ^name, waypoints: [%{stops: [:cooldown_revive]} | _rest]}] =
               Store.all()

      {:ok, view, html} = live(conn, ~p"/cavebot?modo=editar")
      refute html =~ "varrer"
      refute has_element?(view, "#waypoint-0-sweep")
    end

    # "eu mesmo errei alguns combos ali" — the marks are his, the pairing is
    # what gets fixed.
    test "arrumar marcas pairs one gathering per kill spot", %{conn: conn} do
      {:ok, route} = Route.append(Route.new("mob"), {10, 10, 7})
      {:ok, route} = Route.append(route, {20, 10, 7})
      {:ok, route} = Route.append(route, {30, 10, 7})

      :ok =
        route
        |> Route.set_action(1, :lure_end)
        |> Route.set_action(2, :lure_end)
        |> Store.add()

      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      html = view |> element("#tidy-marks") |> render_click()

      # the two kill spots stay (two piles at the same corner is real), and a
      # gathering now leads into the first
      assert [%Route{waypoints: [a, b, c]}] = Store.all()
      assert {a.action, b.action, c.action} == {:lure_start, :lure_end, :lure_end}
      refute html =~ ~s(id="lure-warning")
      assert html =~ "arrumei"
    end

    test "a job can be taken back", %{conn: conn} do
      route_with([{10, 10, 7}, {20, 10, 7}])
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      view |> element("#map-waypoint-0") |> render_click()
      view |> element("#waypoint-0-lure_start") |> render_click()
      view |> element("#waypoint-0-walk") |> render_click()

      assert [%Route{waypoints: [%{action: :walk}, %{action: :walk}]}] = Store.all()
    end
  end

  # "sinto falta dele falar ali qual pokémon que eu tô usando (…) pra eu saber
  # que os combos que ele tá me mostrando ali na caçada são de acordo com aquele
  # meu pokémon" (Lucas, 2026-08-12).
  describe "who the hunt is fighting as" do
    defp classify!(name, profile) do
      File.write!(
        Path.join(Pokex.Home.dir(), "pokedex.json"),
        JSON.encode!(%{
          "species" => [%{"name" => name, "number" => 1, "elements" => ["Bug"]}],
          "lures" => []
        })
      )

      Application.put_env(:pokex, :pokedex_path, Path.join(Pokex.Home.dir(), "pokedex.json"))
      on_exit(fn -> Application.delete_env(:pokex, :pokedex_path) end)

      {:ok, _} = Pokex.Pokedex.Team.add(name)
      Pokex.Pokedex.Team.set_skills(name, profile)
      Pokex.Pokedex.Team.set_active(name)
    end

    test "with nobody chosen it says so and points at /time", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot")

      card = view |> element("#cavebot-loadout") |> render()
      assert card =~ "ninguém escolhido"
      assert card =~ ~s(href="/time")
    end

    # His real Vespiquen: 1 stun (reserved), 2 defence aura, 3/4/5 damage.
    test "it names the pokémon and what its keys decide", %{conn: conn} do
      classify!("Vespiquen", %{
        "1" => :crowd,
        "2" => :buffs,
        "3" => :aoe,
        "4" => :aoe,
        "5" => :aoe
      })

      {:ok, view, _html} = live(conn, ~p"/cavebot")

      card = view |> element("#cavebot-loadout") |> render()
      assert card =~ "Vespiquen"
      assert card =~ "3 4 5"
      assert card =~ "guarda 1"
      assert card =~ "aura 2"
      # stopped, the page is honest about reading the configuration
      assert card =~ "configurado"
      refute card =~ "ao vivo"
    end

    # The proof he asked for: the RUNNING fight's own answer, not the file's.
    test "a running fight makes the card live, with what it last pressed", %{conn: conn} do
      classify!("Vespiquen", %{"1" => :crowd, "3" => :aoe})

      {:ok, view, _html} = live(conn, ~p"/cavebot")

      send(
        view.pid,
        {:combat,
         %{
           state: :fighting,
           counters: %{},
           error: nil,
           locked_row: 0,
           scenery: 0,
           hold_reason: nil,
           last_action: %{text: "3, 4", at: 0},
           loadout: %{
             name: "Vespiquen",
             opening: ["3"],
             reserved: ["1"],
             buffs: [],
             heal: []
           }
         }}
      )

      card = view |> element("#cavebot-loadout") |> render()
      assert card =~ "ao vivo"
      refute card =~ "configurado"
      assert view |> element("#cavebot-last-press") |> render() =~ "3, 4"
    end
  end

  # "importante na tela de cavebot mostrar de forma clara como se fossem
  # quadradinhos com os botões, que que tá em cooldown, que que não tá, e
  # quanto tempo falta em contagem regressiva (…) pra eu ir ajudando a debugar
  # problemas de leitura do jogo" (Lucas, 2026-08-27).
  describe "a fileira da barra" do
    setup do
      Pokex.Bots.SkillClock.wipe()
      on_exit(&Pokex.Bots.SkillClock.wipe/0)
      :ok
    end

    defp bar_reads(keys),
      do: WorldState.put(:skill_bar, %{ready_keys: keys}, System.monotonic_time(:millisecond))

    defp steelix! do
      classify!("Steelix", %{"1" => :crowd, "3" => :aoe, "4" => :aoe, "6" => :single})
      Pokex.Pokedex.Team.set_cooldowns("Steelix", %{"3" => 40_000, "4" => 50_000})
    end

    test "cada tecla é um quadrado, com o que ela faz e se está pronta", %{conn: conn} do
      steelix!()
      bar_reads(~w(1 3 4 6))

      {:ok, view, _html} = live(conn, ~p"/cavebot")

      rack = view |> element("#cavebot-rack") |> render()
      assert rack =~ "4/4 prontas"
      assert rack =~ "controle"
      assert rack =~ "pronta"
      refute rack =~ "barra não lida"
    end

    test "uma tecla apertada conta o tempo dela pra trás", %{conn: conn} do
      steelix!()
      bar_reads(~w(1 6))
      Pokex.Bots.SkillClock.pressed("4")

      {:ok, view, _html} = live(conn, ~p"/cavebot")

      rack = view |> element("#cavebot-rack") |> render()
      assert rack =~ "2/4 prontas"
      assert rack =~ "50s"
    end

    # O DEFEITO DE 27/08 na tela: a barra oferecendo a tecla que o jogo está
    # contando. Ele não tinha como ver isso em lugar nenhum.
    test "quando a tela e o relógio discordam, a peça diz qual das duas", %{conn: conn} do
      steelix!()
      bar_reads(~w(1 3 4 6))
      Pokex.Bots.SkillClock.pressed("3")

      {:ok, view, _html} = live(conn, ~p"/cavebot")

      rack = view |> element("#cavebot-rack") |> render()
      assert rack =~ "tela × relógio"
      # O motivo saiu de DENTRO da peça (onde cabia como "tela diz em …") e
      # virou uma linha embaixo do rack, dizendo o que fazer.
      assert rack =~ "cavebot-rack-conflict"
      assert rack =~ "a rotação obedece o relógio"
      # e a contagem obedece o relógio, que é o que a rotação obedece
      assert rack =~ "40s"
    end

    test "a tecla sem tempo escrito é contada e o /time é oferecido", %{conn: conn} do
      steelix!()
      bar_reads(~w(1 3 4 6))

      {:ok, view, _html} = live(conn, ~p"/cavebot")

      rack = view |> element("#cavebot-rack") |> render()
      assert rack =~ "2 tecla(s) sem o tempo escrito"
      assert rack =~ ~s(href="/time")
    end
  end

  describe "skills e respiro no editor" do
    # `put/1` and not `add/1`: this route has to be the ONLY one, or which of
    # them the page opens as active is luck, and `[route] = Store.all()` in the
    # assertions becomes a flake. Waypoint 0 is the kill spot because that is
    # where the huddle field shows up.
    setup do
      {:ok, route} = Route.append(Route.new("meganium"), {10, 10, 5})
      {:ok, route} = Route.append(route, {12, 10, 5})
      :ok = Store.put([Route.set_action(route, 0, :lure_end)])
      :ok
    end

    # The chips live where the job and the stops live — on the SELECTED
    # waypoint. Five of them on each of his 67 corners was 335 buttons for the
    # handful of corners that carry one.
    test "os chips só existem no waypoint selecionado", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/cavebot?modo=editar")

      refute html =~ ~s(id="waypoint-skill-0-buffs")

      html = view |> element("#map-waypoint-0") |> render_click()
      assert html =~ ~s(id="waypoint-skill-0-buffs")
      refute html =~ ~s(id="waypoint-skill-1-buffs")
    end

    test "clicar no chip liga a categoria no waypoint", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      view |> element("#map-waypoint-0") |> render_click()

      view
      |> element("#waypoint-skill-0-buffs")
      |> render_click()

      [route] = Store.all()
      assert Route.skills_at(route.waypoints, 0) == [:buffs]
    end

    test "clicar de novo desliga", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      view |> element("#map-waypoint-0") |> render_click()
      view |> element("#waypoint-skill-0-buffs") |> render_click()
      view |> element("#waypoint-skill-0-buffs") |> render_click()

      [route] = Store.all()
      assert Route.skills_at(route.waypoints, 0) == []
    end

    # A category nobody knows can only arrive forged — the chips emit
    # whitelisted values and nothing else. It used to KILL the page: the
    # whitelist correctly answered nil, and the notice then asked
    # `SkillProfile.label/1` to name it, which has one clause per category and
    # no catch-all.
    test "uma categoria forjada não derruba a página", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      render_click(view, "toggle_waypoint_skill", %{"index" => "0", "skill" => "swim"})

      assert render(view) =~ ~s(id="cavebot-waypoints")
      [route] = Store.all()
      assert Route.skills_at(route.waypoints, 0) == []
    end

    # The row keeps a read-only badge so the list still says which corners
    # carry an order, without carrying the buttons that change it.
    test "a linha mostra em selo o que o canto carrega, e só onde carrega", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      view |> element("#map-waypoint-0") |> render_click()
      view |> element("#waypoint-skill-0-buffs") |> render_click()
      html = view |> element("#waypoint-skill-0-heal") |> render_click()

      assert html =~ ~s(id="waypoint-skills-0")
      refute html =~ ~s(id="waypoint-skills-1")

      badge = view |> element("#waypoint-skills-0") |> render()
      assert badge =~ "✨"
      assert badge =~ "❤️"
      assert badge =~ "aura de dano, cura"
      # read-only: the badge is a label, never a button
      refute badge =~ "phx-click"
    end

    test "a régua da rota é salva", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      view
      |> form("#route-gather-wait", %{"gather_wait_ms" => "1800"})
      |> render_submit()

      [route] = Store.all()
      assert route.gather_wait_ms == 1_800
    end

    # The number is one he dials DOWN over and over, so both forms carry the
    # same "guardar" the park form has: typing 1200 and clicking away must not
    # be the way he loses it.
    test "as duas réguas têm onde clicar pra guardar", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      assert has_element?(view, "#route-gather-wait-save")
      assert has_element?(view, "#waypoint-gather-wait-save-0")
    end

    test "campo vazio devolve o comando pro número global", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      view |> form("#route-gather-wait", %{"gather_wait_ms" => "1800"}) |> render_submit()
      view |> form("#route-gather-wait", %{"gather_wait_ms" => ""}) |> render_submit()

      [route] = Store.all()
      assert route.gather_wait_ms == nil
    end

    test "o respiro do waypoint é salvo e ganha da rota", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      view |> form("#route-gather-wait", %{"gather_wait_ms" => "1800"}) |> render_submit()

      view
      |> form("#waypoint-gather-wait-0", %{"gather_wait_ms" => "600"})
      |> render_submit()

      [route] = Store.all()
      assert Route.gather_wait(route, hd(route.waypoints), 4_000) == 600
    end

    # Zero is an ORDER — "wait for nothing here" — and it has to survive the
    # trip through the form, where an empty field means the opposite ("I have
    # no ruler here, ask the route").
    test "zero é guardado como zero, não como campo vazio", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      view |> form("#waypoint-gather-wait-0", %{"gather_wait_ms" => "0"}) |> render_submit()

      [route] = Store.all()
      assert hd(route.waypoints)[:gather_wait_ms] == 0
      assert Route.gather_wait(route, hd(route.waypoints), 4_000) == 0
    end

    # The huddle exists where the pile closes and nowhere else: waypoint 1 is a
    # plain corner.
    test "o campo do respiro não existe num canto comum", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      assert has_element?(view, "#waypoint-gather-wait-0")
      refute has_element?(view, "#waypoint-gather-wait-1")
    end
  end

  # The one piece of thinking in the editor: what his hands measured is offered
  # as a starting point, and only when it could plausibly BE a huddle. 12s
  # measured at a kill spot is the recorder having timed something else.
  defp kill_spot_with(gather_ms) do
    {:ok, route} = Route.append(Route.new("meganium"), {10, 10, 5})

    route = Route.set_action(route, 0, :lure_end)
    route = if gather_ms, do: Route.set_timing(route, 0, gather_ms: gather_ms), else: route
    :ok = Store.put([route])
  end

  describe "a medição das mãos, oferecida" do
    test "uma medição plausível é oferecida", %{conn: conn} do
      # inside cavebot_gather_wait_min_ms..cavebot_gather_wait_max_ms (500..8000)
      kill_spot_with(3_300)

      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      assert view |> element("#waypoint-gather-wait-0") |> render() =~
               "suas mãos esperaram 3300ms aqui"
    end

    test "uma medição fora da faixa não é oferecida", %{conn: conn} do
      kill_spot_with(12_000)

      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      refute view |> element("#waypoint-gather-wait-0") |> render() =~ "suas mãos esperaram"
    end

    test "uma medição curta demais também não", %{conn: conn} do
      kill_spot_with(120)

      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      refute view |> element("#waypoint-gather-wait-0") |> render() =~ "suas mãos esperaram"
    end

    test "sem medição nenhuma, nada é oferecido", %{conn: conn} do
      kill_spot_with(nil)

      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      refute view |> element("#waypoint-gather-wait-0") |> render() =~ "suas mãos esperaram"
    end

    # Reading the number off the screen and retyping it is the same work twice:
    # one click writes the measurement into this corner's ruler.
    test "um clique adota a medição como régua do waypoint", %{conn: conn} do
      kill_spot_with(3_300)

      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      view |> element("#waypoint-gather-wait-adopt-0") |> render_click()

      [route] = Store.all()
      assert hd(route.waypoints)[:gather_wait_ms] == 3_300
      assert Route.gather_wait(route, hd(route.waypoints), 4_000) == 3_300
    end

    test "sem medição não existe botão pra adotar", %{conn: conn} do
      kill_spot_with(nil)

      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      refute has_element?(view, "#waypoint-gather-wait-adopt-0")
    end
  end

  describe "the stop banner" do
    test "a blocked hunt is announced with its reason", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      send(view.pid, {:cavebot, %{state: :blocked, hold_reason: "a caçada parou (escada)"}})

      assert view |> element("#cavebot-blocked") |> render() =~ "a caçada parou (escada)"
      refute has_element?(view, "#cavebot-held")
    end

    # A hunt about to re-enter the route on its own must not read like one
    # asking to be rescued: the difference between "vai lá consertar" and
    # "deixa que ela volta" is the whole tone of a 3am screen.
    test "a hunt with a comeback scheduled says it will try again", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      send(
        view.pid,
        {:cavebot,
         %{
           state: :blocked,
           comeback?: true,
           hold_reason: "parei: travado — tento de novo em 30s (tentativa 1 de 3)"
         }}
      )

      assert view |> element("#cavebot-comeback") |> render() =~ "tentativa 1 de 3"
      refute has_element?(view, "#cavebot-blocked")
    end

    test "a held hunt shows the hold without the alarm", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      send(
        view.pid,
        {:cavebot, %{state: :walking, hold_reason: "vida em 40% — a rota segue quando voltar"}}
      )

      assert view |> element("#cavebot-held") |> render() =~ "vida em 40%"
      refute has_element?(view, "#cavebot-blocked")
    end

    test "a walking hunt with no hold shows no banner", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      send(view.pid, {:cavebot, %{state: :walking, hold_reason: nil}})
      render(view)

      refute has_element?(view, "#cavebot-blocked")
      refute has_element?(view, "#cavebot-held")
    end
  end

  # "não consigo ver direito em que momento ele está na rota" (Lucas,
  # 2026-08-14): the page marked the corner being EDITED and never the one
  # being WALKED TO, so a running hunt was invisible on its own map.
  describe "where the hunt is right now" do
    setup do
      {:ok, route} = Route.append(Route.new("cavena"), {1, 1, 7})
      {:ok, route} = Route.append(route, {8, 1, 7})
      {:ok, route} = Route.append(route, {8, 8, 7})
      :ok = Store.add(route)
      :ok
    end

    defp hunting!(view, index, route \\ "cavena") do
      send(
        view.pid,
        {:cavebot,
         %{state: :walking, route: route, wp_index: index, wp_total: 3, hold_reason: nil}}
      )

      render(view)
    end

    test "the corner it walks to is marked on the map and on the list", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")
      hunting!(view, 1)

      assert has_element?(view, "#map-heading-1")
      refute has_element?(view, "#map-heading-0")
      assert view |> element("#waypoint-1") |> render() =~ "▶"
    end

    test "the header counts the progress while it runs", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/cavebot?modo=editar")
      refute html =~ "waypoint 2/3"

      hunting!(view, 1)
      assert render(view) =~ "waypoint 2/3"
    end

    # He edits one route while another is armed: a mark on the list he happens
    # to be looking at would be a lie.
    test "another route's hunt marks nothing here", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")
      hunting!(view, 1, "outra")

      refute has_element?(view, "#map-heading-1")
      refute view |> element("#waypoint-1") |> render() =~ "▶"
    end

    # The mark only helps if it is ON SCREEN: 7 rows of 70 are visible, so the
    # list carries the target for the client hook that follows it.
    test "the list publishes the target for the follow hook", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")
      hunting!(view, 2)

      list = view |> element("#waypoint-list") |> render()
      assert list =~ ~s(phx-hook="FollowHunt")
      assert list =~ ~s(data-heading-to="2")
    end

    # The morning question is "o que ocorreu", and corners alone do not answer
    # it. Incidents only take space when they happened.
    test "the incidents show up beside the progress, and stay quiet at zero", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      send(
        view.pid,
        {:cavebot,
         %{
           state: :walking,
           route: "cavena",
           wp_index: 1,
           wp_total: 3,
           hold_reason: nil,
           counters: %{waypoints: 40, steps: 900, aborts: 0, comebacks: 0, blocks: 0}
         }}
      )

      refute has_element?(view, "#cavebot-tally")

      send(
        view.pid,
        {:cavebot,
         %{
           state: :walking,
           route: "cavena",
           wp_index: 1,
           wp_total: 3,
           hold_reason: nil,
           counters: %{waypoints: 40, steps: 900, aborts: 2, comebacks: 1, blocks: 0}
         }}
      )

      tally = view |> element("#cavebot-tally") |> render()
      assert tally =~ "2 mobada(s) largada(s)"
      assert tally =~ "1 volta(s)"
      refute tally =~ "parada(s)"
    end

    test "a stopped hunt marks nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      send(
        view.pid,
        {:cavebot, %{state: :idle, route: "cavena", wp_index: 1, wp_total: 3, hold_reason: nil}}
      )

      render(view)

      refute has_element?(view, "#map-heading-1")
    end
  end

  # The two defects his real route carries (2026-08-15), told with the corner
  # numbers he can act on — and silent on a route that has neither.
  # "Algo elegante pra deixar claro quando tá rodando (…) que vai ali
  # atualizando com o que a gente conseguir de estatística do sistema e da run"
  # (28/08). A tira responde de longe as duas perguntas que a tela inteira não
  # respondia: isso ainda está rodando, e está rendendo?
  describe "o resumo da noite" do
    defp running!(view, started_ms_ago, counters \\ %{}, extra \\ %{}) do
      base = %{waypoints: 0, steps: 0, aborts: 0, comebacks: 0, blocks: 0}

      snapshot =
        Map.merge(
          %{
            state: :walking,
            route: "cavena",
            wp_index: 1,
            wp_total: 12,
            hold_reason: nil,
            luring?: false,
            started_at: System.system_time(:millisecond) - started_ms_ago,
            ended_at: nil,
            counters: Map.merge(base, counters)
          },
          extra
        )

      send(view.pid, {:cavebot, snapshot})
      render(view)
      view |> element("#cavebot-resumo") |> render()
    end

    test "sem caçada nenhuma o mostrador fica em traços, não em zeros", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot")

      resumo = view |> element("#cavebot-resumo") |> render()

      assert resumo =~ "--:--"
      assert resumo =~ "sem caçada ainda"
    end

    test "rodando, ela conta o tempo e diz desde quando", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot")

      # 2h01m de caçada: os segundos andam sozinhos entre o envio e o desenho,
      # então o que se afirma é a hora e o minuto.
      resumo = running!(view, 2 * 3_600_000 + 61_000)

      assert resumo =~ "2:01:"
      assert resumo =~ "rodando"
      assert resumo =~ "desde "
    end

    test "a caçada parada congela a duração e diz a que horas parou", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot")

      started = System.system_time(:millisecond) - 5_400_000
      ended = started + 3_600_000

      send(
        view.pid,
        {:cavebot,
         %{
           state: :idle,
           route: nil,
           wp_index: 0,
           wp_total: 0,
           hold_reason: nil,
           luring?: false,
           started_at: started,
           ended_at: ended,
           counters: %{waypoints: 24, steps: 900, aborts: 0, comebacks: 0, blocks: 0}
         }}
      )

      render(view)
      resumo = view |> element("#cavebot-resumo") |> render()

      # UMA hora, não uma hora e meia: o relógio para no halt em vez de seguir
      # contando a madrugada inteira depois que a caçada acabou.
      assert resumo =~ "1:00:00"
      assert resumo =~ "parada às"
    end

    test "as voltas saem dos cantos divididos pelo tamanho da rota", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot")

      resumo = running!(view, 600_000, %{waypoints: 40, steps: 1_200})

      assert view |> element("#resumo-voltas") |> render() =~ "3"
      assert view |> element("#resumo-voltas") |> render() =~ "40 canto(s)"

      # Ponto de milhar: `1200` sem ele é uma parede de dígitos que se lê
      # contando com o dedo, e ele lê esta tela de óculos.
      assert resumo =~ "1.200"
    end

    # O ritmo é o número que diz se a noite está indo bem — e é mentira antes de
    # a caçada ter tempo suficiente pra dividir.
    test "o ritmo só aparece depois de cinco minutos de caçada", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot")

      running!(view, 60_000, %{steps: 100})
      refute view |> element("#resumo-passos") |> render() =~ "/h"

      running!(view, 3_600_000, %{steps: 100})
      assert view |> element("#resumo-passos") |> render() =~ "100/h"
    end

    test "as lutas, as capturas e os revives vêm de quem os conta", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot")

      send(view.pid, {:combat, %{counters: %{fights: 42, captures: 0, failures: 0}}})
      send(view.pid, {:catcher, %{counters: %{captures: 18, throws: 30, ignored: 2}}})
      send(view.pid, {:game, %{counters: %{rescues: 7, heals: 3, potions: 1}}})
      running!(view, 600_000)

      assert view |> element("#resumo-lutas") |> render() =~ "42"
      assert view |> element("#resumo-capturas") |> render() =~ "18"
      assert view |> element("#resumo-revives") |> render() =~ "7"
    end

    test "o estoque de revive no fim fica âmbar ao lado do gasto", %{conn: conn} do
      Pokex.SettingsStash.stash!(revive_stock: 12)
      Pokex.Bots.ReviveLedger.reset()
      Enum.each(1..5, fn _ -> Pokex.Bots.ReviveLedger.note() end)
      on_exit(&Pokex.Bots.ReviveLedger.reset/0)

      {:ok, view, _html} = live(conn, ~p"/cavebot")
      send(view.pid, :health)
      render(view)

      revives = view |> element("#resumo-revives") |> render()
      assert revives =~ "7 no bolso"
      assert revives =~ "text-pk-warn"
    end

    # As paradas são a má notícia; largar uma mobada por vida e voltar depois de
    # tropeçar são as boas. Somadas num número só, as três sumiriam.
    test "as paradas são o número e o resto do estrago vai na linha de baixo", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot")

      running!(view, 600_000, %{blocks: 2, aborts: 3, comebacks: 1})
      paradas = view |> element("#resumo-paradas") |> render()

      assert paradas =~ "2"
      assert paradas =~ "3 largada(s)"
      assert paradas =~ "1 reentro(s)"
      assert paradas =~ "text-pk-warn"
    end

    # O mostrador anda com a batida de 1s da página, e não com o broadcast da
    # caçada: sem isso ele congelaria entre um waypoint e o próximo.
    test "o relógio anda na batida da página, sem broadcast novo", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot")

      send(
        view.pid,
        {:cavebot,
         %{
           state: :walking,
           route: "cavena",
           wp_index: 0,
           wp_total: 4,
           hold_reason: nil,
           luring?: false,
           started_at: System.system_time(:millisecond) - 3_599_000,
           ended_at: nil,
           counters: %{waypoints: 0, steps: 0, aborts: 0, comebacks: 0, blocks: 0}
         }}
      )

      assert view |> element("#cavebot-resumo") |> render() =~ "59:5"

      Process.sleep(1_100)
      send(view.pid, :health)
      render(view)

      assert view |> element("#cavebot-resumo") |> render() =~ "1:00:0"
    end

    # Assistir e editar querem coisas diferentes: o placar da noite mora na
    # tira, e o cabeçalho do editor guarda o seu resumo de uma linha.
    test "a tira é do modo assistir; no editor o placar segue no cabeçalho", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      refute has_element?(view, "#cavebot-resumo")
    end
  end

  describe "the route doctor" do
    test "names the corners the hunt cannot walk between", %{conn: conn} do
      {:ok, route} = Route.append(Route.new("cavena"), {2305, 30_014, 5})
      {:ok, route} = Route.append(route, {2304, 30_014, 5})
      {:ok, route} = Route.append(route, {2290, 30_014, 5})
      :ok = Store.add(route)

      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      doctor = view |> element("#route-doctor") |> render()
      assert doctor =~ "1 canto(s) em cima do anterior"
      assert doctor =~ "sem andar"
    end

    test "names a staircase that goes up and comes straight back", %{conn: conn} do
      {:ok, route} = Route.append(Route.new("cavena"), {2310, 30_021, 5})
      {:ok, route} = Route.append(route, {2310, 30_023, 6})
      {:ok, route} = Route.append(route, {2310, 30_021, 5})
      :ok = Store.add(route)

      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      assert view |> element("#route-doctor") |> render() =~ "escada de ida e volta"
    end

    test "a healthy route says nothing at all", %{conn: conn} do
      {:ok, route} = Route.append(Route.new("cavena"), {2300, 30_014, 5})
      {:ok, route} = Route.append(route, {2310, 30_014, 5})
      :ok = Store.add(route)

      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      refute has_element?(view, "#route-doctor")
    end
  end

  # The engine's reasoning had no way to be seen: the tiles show facts, the
  # fight narrates itself, but how many it counted and what it would DO about
  # them only ever existed inside a process.
  describe "what the engine is thinking" do
    defp thinking(situation, orders) do
      at = System.monotonic_time(:millisecond)
      WorldState.put(:situation, situation, at)
      WorldState.put(:orders, orders, at)
    end

    defp picture(overrides \\ %{}) do
      Map.merge(%{enemies: 4, growing?: false, stable_for_ms: 1_800}, overrides)
    end

    test "shows the count, the settling and the reason", %{conn: conn} do
      thinking(picture(), %{
        band: :green,
        why: "4 inimigos e pararam de chegar: estourando a área"
      })

      {:ok, view, _html} = live(conn, ~p"/cavebot")

      brain = view |> element("#engine-brain") |> render()
      assert brain =~ "4 inimigos"
      assert brain =~ "parados há 1.8s"
      assert brain =~ "estourando a área"
      assert brain =~ "verde"
    end

    # The band is health, and health may never be colour alone.
    test "names the band in words, not only in colour", %{conn: conn} do
      thinking(picture(), %{band: :yellow, why: "amarelo (47%): stun antes de gastar tudo"})

      {:ok, view, _html} = live(conn, ~p"/cavebot")

      assert view |> element("#engine-brain") |> render() =~ "amarelo"
    end

    # Zero and "I cannot see" are opposite facts wearing the same number.
    test "an unreadable list says so instead of showing a zero", %{conn: conn} do
      thinking(
        picture(%{enemies: nil}),
        %{band: :green, why: "não estou vendo a lista de batalha — não mando nada"}
      )

      {:ok, view, _html} = live(conn, ~p"/cavebot")

      brain = view |> element("#engine-brain") |> render()
      assert brain =~ "não vejo a lista"
      refute brain =~ "0 inimigos"
    end

    test "stays off the screen entirely while the engine has said nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      refute has_element?(view, "#engine-brain")
    end
  end

  describe "the map marks" do
    test "a kill spot is drawn solid, not like a plain mark", %{conn: conn} do
      {:ok, route} = Route.append(Route.new("cavena"), {1, 1, 7})
      {:ok, route} = Route.append(route, {8, 1, 7})
      {:ok, route} = Route.append(route, {8, 8, 7})

      route =
        route
        |> Route.set_action(1, :lure_start)
        |> Route.set_action(2, :lure_end)

      :ok = Store.add(route)

      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      assert view |> element("#map-waypoint-2") |> render() =~ ~s{fill="var(--color-pk-info)"}

      assert view |> element("#map-waypoint-1") |> render() =~
               ~s{fill="var(--color-pk-info-dim)"}

      assert view |> element("#map-lure-legend") |> render() =~ "matança"
    end
  end

  describe "the safety card" do
    setup do
      Pokex.SettingsStash.stash!(
        rescue_enabled: false,
        heal_skill_enabled: true,
        potion_enabled: false
      )

      :ok
    end

    test "shows each net by its state, in words", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot")

      assert view |> element("#safety-rescue") |> render() =~ "resgate desligado"
      assert view |> element("#safety-heal") |> render() =~ "cura armada"
      assert view |> element("#safety-potion") |> render() =~ "poção desligada"
    end

    test "arms the rescue from the hunt page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot")

      view |> element("#safety-rescue") |> render_click()

      assert Pokex.Settings.get(:rescue_enabled) == true
      assert view |> element("#safety-rescue") |> render() =~ "resgate armado"
      assert view |> element("#cavebot-notice") |> render() =~ "resgate armado"
    end

    test "disarms an armed net and says so", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot")

      view |> element("#safety-heal") |> render_click()

      assert Pokex.Settings.get(:heal_skill_enabled) == false
      assert view |> element("#safety-heal") |> render() =~ "cura desligada"
    end

    # "a parte de waypoints tem que caber na minha tela com uma caixa que
    # dentro dela tem o scroll" (Lucas, 2026-08-15). The page is a viewport-tall
    # column of strips plus a workbench that takes what is left, and each side
    # of the workbench scrolls inside itself — a structural promise, so it gets
    # a structural test instead of being re-broken by the next spacing tweak.
    test "the workbench is bounded by the screen and scrolls inside itself", %{conn: conn} do
      {:ok, route} = Route.append(Route.new("cavena"), {1, 1, 7})
      :ok = Store.add(route)

      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      bench = view |> element("#cavebot-workbench") |> render()
      assert bench =~ "lg:flex-1"
      assert bench =~ "lg:overflow-y-auto"

      assert view |> element("#cavebot-waypoints ol") |> render() =~ "overflow-y-auto"
    end

    test "saves how many times the hunt comes back, and how long it waits", %{conn: conn} do
      Pokex.SettingsStash.stash_keys!([:cavebot_block_retries, :cavebot_block_retry_ms])

      {:ok, view, _html} = live(conn, ~p"/cavebot")

      view
      |> form("#comeback-form", %{"retries" => "5", "wait_s" => "45"})
      |> render_submit()

      assert Pokex.Settings.get(:cavebot_block_retries) == 5
      assert Pokex.Settings.get(:cavebot_block_retry_ms) == 45_000
      assert view |> element("#cavebot-notice") |> render() =~ "45s"
    end

    test "a comeback wait outside the range changes nothing", %{conn: conn} do
      Pokex.SettingsStash.stash!(cavebot_block_retries: 3, cavebot_block_retry_ms: 30_000)

      {:ok, view, _html} = live(conn, ~p"/cavebot")

      view
      |> form("#comeback-form", %{"retries" => "5", "wait_s" => "0"})
      |> render_submit()

      assert Pokex.Settings.get(:cavebot_block_retries) == 3
      assert Pokex.Settings.get(:cavebot_block_retry_ms) == 30_000
      assert view |> element("#cavebot-notice") |> render() =~ "1 a 600"
    end
  end

  # Seven of the fourteen floor changes in his three recorded routes are marked
  # the way a staircase is — the corner right before and the corner right after,
  # two tiles apart with the step in the middle. The other seven have extra
  # walking folded into the same corner, and those are the ones still paying for
  # the ring search. He cannot tell them apart until the page says so.
  #
  # Every assertion here is scoped to ONE ROW: a badge on the wrong row is the
  # exact defect these tests exist to catch, and a page-wide `html =~` cannot
  # see it.
  describe "the staircase legs on the page" do
    setup do
      {:ok, route} = Route.append(Route.new("meganium"), {2368, 30_030, 5})
      {:ok, route} = Route.append(route, {2368, 30_028, 6})
      {:ok, route} = Route.append(route, {2360, 30_025, 5})
      :ok = Store.put([route])
      :ok
    end

    # Waypoint 1 → 2 is the clean one: dx = 0, dy = −2, one key, and the step is
    # the tile in between. Like every other badge in that row, it lands on the
    # waypoint the leg ARRIVES at — waypoint 2, `#waypoint-1`.
    test "a clean stair leg says where the step is", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      row = view |> element("#waypoint-1") |> render()

      assert row =~ "🪜"
      assert row =~ "2368, 30029"
    end

    # Waypoint 2 → 3 changes floor with dx = −8, dy = −3: extra walking folded
    # into the corner. It must be called out, not silently left to the ring
    # search — and named with the rule he can act on.
    test "a dirty stair leg is named as dirty", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      row = view |> element("#waypoint-2") |> render()

      assert row =~ "não está limpa"
      assert row =~ "marque o canto logo ANTES e o logo DEPOIS"
    end

    # The step is the midpoint of two tiles exactly two apart, so it exists only
    # once the pair is clean. On a folded corner the staircase's real position is
    # not in the recording at all: the page says what is wrong and what the rule
    # is, and never guesses a coordinate.
    test "a dirty stair leg is given no coordinates", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      refute view |> element("#waypoint-2") |> render() =~ "o degrau é"
    end

    # The pairing, pinned: reading the leg that LEAVES a waypoint instead of the
    # one that arrives at it splits a staircase across two rows and parks "não
    # está limpa" beside the climb that is actually clean.
    test "the step and its own climb sit on the same row", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      clean = view |> element("#waypoint-1") |> render()
      crooked = view |> element("#waypoint-2") |> render()

      assert clean =~ "⇅ andar 6"
      assert clean =~ "2368, 30029"
      refute clean =~ "não está limpa"

      assert crooked =~ "⇅ andar 5"
      refute crooked =~ "escada: o degrau"

      # …and the corner the staircase leaves FROM carries neither badge.
      refute has_element?(view, "#waypoint-stair-0")
    end
  end

  # A route that never changes floor has nothing to say about stairs: no badge,
  # and no empty element left behind either.
  test "a one-floor route says nothing about stairs", %{conn: conn} do
    route_with([{10, 10, 7}, {20, 10, 7}, {20, 20, 7}])

    {:ok, view, html} = live(conn, ~p"/cavebot?modo=editar")

    refute html =~ "escada: o degrau"
    refute html =~ "não está limpa"
    refute has_element?(view, "[id^='waypoint-stair-']")
  end

  describe "o interruptor de juntar pilha" do
    setup do
      antes = Pokex.Settings.get(:engine_gather_piles)
      on_exit(fn -> Pokex.Settings.put(:engine_gather_piles, antes) end)
      :ok
    end

    test "aparece no card do cérebro e inverte o ajuste", %{conn: conn} do
      Pokex.Settings.put(:engine_gather_piles, true)
      at = System.monotonic_time(:millisecond)
      WorldState.put(:situation, %{enemies: 2, growing?: true, stable_for_ms: 0}, at)
      WorldState.put(:orders, %{band: :green, why: "contando quem chega"}, at)

      {:ok, view, _html} = live(conn, ~p"/cavebot")
      assert has_element?(view, "#toggle-gather-piles")

      view |> element("#toggle-gather-piles") |> render_click()

      refute Pokex.Settings.get(:engine_gather_piles)
      assert render(view) =~ "sem juntar pilha"
    end
  end

  # R3b: a chave que decide se o F4 é resgate ou também reset de cooldown. O
  # simulador mediu +13% de monstros com ela ligada e zero quedas a mais — mas
  # ela gasta tecla numa mecânica do jogo que ninguém conferiu, então nasce
  # desligada e o card é o único lugar onde ela existe.
  describe "a chave do F4 como reset de cooldown" do
    setup do
      antes = Pokex.Settings.get(:engine_reset_revive)
      on_exit(fn -> Pokex.Settings.put(:engine_reset_revive, antes) end)
      :ok
    end

    test "aparece no card do cérebro, inverte o ajuste e avisa o que conferir", %{conn: conn} do
      Pokex.Settings.put(:engine_reset_revive, false)
      at = System.monotonic_time(:millisecond)
      WorldState.put(:situation, %{enemies: 4, growing?: false, stable_for_ms: 2_000}, at)
      WorldState.put(:orders, %{band: :green, why: "matando o que já abriu"}, at)

      {:ok, view, _html} = live(conn, ~p"/cavebot")
      assert has_element?(view, "#toggle-reset-revive")
      assert render(view) =~ "revive só no resgate"

      html = view |> element("#toggle-reset-revive") |> render_click()

      assert Pokex.Settings.get(:engine_reset_revive)
      assert html =~ "revive reseta cooldown"
      assert html =~ "meça antes em /sim", "ligar sem dizer o que conferir é ligar no escuro"
    end
  end

  # OS COOLDOWNS, VISTOS. Ele desconfiava que a rotação não estava usando
  # algumas skills e não tinha como olhar — o rastro da noite dizia 6 de 8
  # teclas prontas o tempo todo enquanto a luta apertava só duas.
  describe "a barra de skills na Central" do
    setup do
      Pokex.TeamFixtures.ready!("Dugtrio",
        count: 10,
        skills: %{
          "1" => :crowd,
          "2" => :buffs,
          "3" => :aoe,
          "4" => :aoe,
          "5" => :aoe,
          "6" => :aoe,
          "7" => :single,
          "8" => :single,
          "9" => :single,
          "0" => :single
        }
      )

      :ok
    end

    @tag :tmp_dir
    test "mostra cada tecla na ordem da fileira, com o zero por último", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/cavebot")

      teclas =
        Regex.scan(~r/title="(\d): ([^"]+)"/, html)
        |> Enum.map(fn [_, key, rest] -> {key, rest} end)

      assert Enum.map(teclas, &elem(&1, 0)) == ~w(1 2 3 4 5 6 7 8 9 0)
      assert {"1", "controle (guardado pro revive)" <> _} = hd(teclas)
    end

    # Não saber é diferente de estar em cooldown, e sem leitura da barra as duas
    # coisas se pareciam. Agora a fileira inteira diz que está cega, e cada
    # peça diz que o relógio é quem está respondendo.
    @tag :tmp_dir
    test "e sem leitura da barra diz que não sabe, em vez de dizer que esfriou", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/cavebot")

      assert html =~ "barra não lida"
      assert html =~ "tela: não sabe"
    end

    # UM INTERVALO ALTO não parece nada num arquivo de ajustes e é o teto de dano
    # da caçada inteira: 500ms com rajada de 2 são 1s por rajada.
    @tag :tmp_dir
    test "e avisa quando o intervalo entre teclas está estrangulando a rajada", %{conn: conn} do
      Pokex.SettingsStash.stash!(combat_skill_gap_ms: 500, combat_skill_burst_size: 2)

      {:ok, _live, html} = live(conn, ~p"/cavebot")

      assert html =~ "rajada: 2 tecla(s) a cada 500ms"
      assert html =~ "é isso que limita o dano da caçada"
    end

    @tag :tmp_dir
    test "e cala a boca quando ele está no padrão", %{conn: conn} do
      Pokex.SettingsStash.stash!(combat_skill_gap_ms: 35, combat_skill_burst_size: 3)

      {:ok, _live, html} = live(conn, ~p"/cavebot?modo=editar")

      refute html =~ "é isso que limita o dano da caçada"
    end
  end

  # "eu não consigo enxergar tudo na minha tela (…) eu quero ver sempre o mapa
  # inteiro aberto na minha tela" (Lucas, 2026-08-28). Watching a hunt and
  # editing a route stopped sharing one long page: each half gets the screen,
  # and the map is on both.
  describe "assistir e editar" do
    test "assistir is what the bare URL opens, and it carries no route editor", %{conn: conn} do
      route_with([{10, 10, 7}, {20, 10, 7}])
      {:ok, view, html} = live(conn, ~p"/cavebot")

      # the cockpit: the drawing, the fight, the world and the feed
      assert has_element?(view, "#cavebot-cockpit")
      assert has_element?(view, "#cavebot-map")
      assert has_element?(view, "#cavebot-loadout")
      assert has_element?(view, "#cavebot-world")
      assert has_element?(view, "#cavebot-log")
      assert has_element?(view, "#cavebot-safety")

      # …and nothing that edits a route
      refute has_element?(view, "#cavebot-workbench")
      refute has_element?(view, "#cavebot-waypoints")
      refute has_element?(view, "#cavebot-routes")
      refute has_element?(view, "#toggle-recording")
      refute html =~ "Marcar um só"
    end

    test "editar carries the map too, beside the route and its corners", %{conn: conn} do
      route_with([{10, 10, 7}, {20, 10, 7}])
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      assert has_element?(view, "#cavebot-workbench")
      # the drawing is on BOTH sides: editing a corner without seeing it is the
      # scrolling exercise this replaced
      assert has_element?(view, "#cavebot-map")
      assert has_element?(view, "#cavebot-routes")
      assert has_element?(view, "#cavebot-waypoints")
      assert has_element?(view, "#cavebot-recorder")
      assert has_element?(view, "#toggle-recording")

      refute has_element?(view, "#cavebot-cockpit")
      refute has_element?(view, "#cavebot-log")
    end

    # The mode is a `patch`, not a reload: the tab he leaves open all night
    # keeps the feed, the selected corner and a recording in progress.
    test "switching modes keeps the page alive, and the selected corner with it", %{conn: conn} do
      route_with([{10, 10, 7}, {20, 10, 7}])
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      view |> element("#map-waypoint-1") |> render_click()
      assert has_element?(view, "#waypoint-detail")

      view |> element("#cavebot-mode-watch") |> render_click()
      assert has_element?(view, "#cavebot-cockpit")
      refute has_element?(view, "#waypoint-detail")

      view |> element("#cavebot-mode-edit") |> render_click()
      assert has_element?(view, "#waypoint-detail")
    end

    test "a mode nobody knows is watching, not a blank page", %{conn: conn} do
      route_with([{10, 10, 7}])
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=trapezio")

      assert has_element?(view, "#cavebot-cockpit")
      assert has_element?(view, "#cavebot-mode-watch[aria-current='page']")
    end

    # An alert is worth nothing on the half of the page he is not looking at.
    test "the banners are on both sides", %{conn: conn} do
      route_with([{10, 10, 7}])

      for mode <- ["", "?modo=editar"] do
        {:ok, _view, html} = live(conn, "/cavebot" <> mode)
        assert html =~ "O minimapa não está calibrado nesta tela"
      end
    end

    # The instruments measure the fight and answer to nobody: they belong under
    # a click, not on the screen he watches the hunt on.
    test "the instruments are folded away, and only in assistir", %{conn: conn} do
      route_with([{10, 10, 7}])

      {:ok, view, html} = live(conn, ~p"/cavebot")
      assert has_element?(view, "#cavebot-instruments")
      assert has_element?(view, "#cavebot-crowd")
      refute html =~ ~s(<details id="cavebot-instruments" open)

      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")
      refute has_element?(view, "#cavebot-instruments")
    end
  end
end
