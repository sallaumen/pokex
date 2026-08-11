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
      Application.delete_env(:pokex, :home_dir)
      WorldState.forget(:minimap)
    end)

    :ok
  end

  defp put_pos(pos) do
    WorldState.put(:minimap, %{pos: pos}, System.monotonic_time(:millisecond))
  end

  test "marking a waypoint records the current position on the active route", %{conn: conn} do
    put_pos({10, 20, 7})

    {:ok, view, _html} = live(conn, ~p"/cavebot")

    view
    |> form("#new-route-form", %{"name" => "cavena", "dungeon" => "cavena-dg"})
    |> render_submit()

    html = view |> element("#mark-waypoint") |> render_click()

    assert [%Route{name: "cavena", dungeon: "cavena-dg", z: 7, waypoints: waypoints}] =
             Store.all()

    assert waypoints == [%{x: 10, y: 20, z: 7, action: :walk}]
    assert has_element?(view, "#waypoint-0")
    assert html =~ "waypoint 1 marcado"
    assert view |> element("#cavebot-notice") |> render() =~ "text-pk-ok"
  end

  test "deleting a waypoint removes it from the list and the Store", %{conn: conn} do
    {:ok, route} = Route.append(Route.new("cavena"), {1, 2, 7})
    {:ok, route} = Route.append(route, {3, 4, 7})
    :ok = Store.add(route)

    {:ok, view, html} = live(conn, ~p"/cavebot")
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
    {:ok, _view, html} = live(conn, ~p"/cavebot")

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

    {:ok, _view, html} = live(conn, ~p"/cavebot")

    refute html =~ "minimapa não está calibrado"
  end

  test "without a position read, marking warns and records nothing", %{conn: conn} do
    :ok = Store.add(Route.new("cavena"))

    {:ok, view, _html} = live(conn, ~p"/cavebot")

    html = view |> element("#mark-waypoint") |> render_click()

    assert html =~ "não estou lendo tua posição"
    assert [%Route{waypoints: []}] = Store.all()
  end

  test "a position from another floor is refused with a warning", %{conn: conn} do
    {:ok, route} = Route.append(Route.new("cavena"), {1, 2, 7})
    :ok = Store.add(route)
    put_pos({5, 6, 3})

    {:ok, view, _html} = live(conn, ~p"/cavebot")

    html = view |> element("#mark-waypoint") |> render_click()

    assert html =~ "outro andar"
    assert [%Route{waypoints: [%{x: 1, y: 2, z: 7}]}] = Store.all()
  end

  test "selecting another route directs marking to it", %{conn: conn} do
    :ok = Store.add(Route.new("primeira"))
    :ok = Store.add(Route.new("segunda"))
    put_pos({10, 20, 7})

    {:ok, view, _html} = live(conn, ~p"/cavebot")

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

    {:ok, view, _html} = live(conn, ~p"/cavebot")

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
    {:ok, view, _html} = live(conn, ~p"/cavebot")

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

    assert waypoints == [
             %{x: 10, y: 20, z: 7, action: :walk},
             %{x: 20, y: 20, z: 7, action: :walk}
           ]

    view |> element("#toggle-recording") |> render_click()
    assert render(view) =~ "gravação parada"
  end

  test "recording without an active route warns instead of recording into the void", %{conn: conn} do
    put_pos({10, 20, 7})
    {:ok, view, _html} = live(conn, ~p"/cavebot")

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
    assert html =~ ">3<"
  end

  test "the route is DRAWN: waypoints, the character, and the walked order", %{conn: conn} do
    route_with([{10, 10, 7}, {20, 10, 7}, {20, 25, 7}])
    put_pos({12, 10, 7})

    {:ok, _view, html} = live(conn, ~p"/cavebot")

    assert html =~ ~s(id="route-map")
    assert html =~ ~s(id="map-waypoint-0")
    assert html =~ ~s(id="map-waypoint-2")
    assert html =~ ~s(id="map-here")
    # the text alternative to the drawing, for screen readers
    assert html =~ "Mapa da rota: 3 waypoints, 25 tiles"
  end

  test "clicking a waypoint on the map selects it in the editor", %{conn: conn} do
    route_with([{10, 10, 7}, {20, 10, 7}])
    {:ok, view, _html} = live(conn, ~p"/cavebot")

    html = view |> element("#map-waypoint-1") |> render_click()
    assert html =~ "border-pk-warn bg-pk-warn-dim"

    # clicking it again lets it go
    html = view |> element("#map-waypoint-1") |> render_click()
    refute html =~ "border-pk-warn bg-pk-warn-dim"
  end

  test "waypoints reorder, insert at a place and clear — no re-walking", %{conn: conn} do
    route_with([{10, 10, 7}, {20, 10, 7}, {30, 10, 7}])
    put_pos({15, 10, 7})

    {:ok, view, _html} = live(conn, ~p"/cavebot")

    view |> element("#waypoint-down-0") |> render_click()
    assert [%Route{waypoints: [%{x: 20}, %{x: 10}, %{x: 30}]}] = Store.all()

    view |> element("#waypoint-up-1") |> render_click()
    assert [%Route{waypoints: [%{x: 10}, %{x: 20}, %{x: 30}]}] = Store.all()

    # the missing corner in the MIDDLE: stand there and insert
    view |> element("#waypoint-insert-1") |> render_click()
    assert [%Route{waypoints: [%{x: 10}, %{x: 15}, %{x: 20}, %{x: 30}]}] = Store.all()

    view |> element("#clear-route") |> render_click()
    assert [%Route{waypoints: [], z: nil}] = Store.all()
  end

  test "the ends of a route move nothing — the button is a no-op, never an error", %{conn: conn} do
    route_with([{10, 10, 7}, {20, 10, 7}])
    {:ok, view, _html} = live(conn, ~p"/cavebot")

    assert view |> element("#waypoint-up-0") |> render() =~ "disabled"
    assert view |> element("#waypoint-down-1") |> render() =~ "disabled"
  end

  test "a route can be switched off without being deleted, and deleted with its photos", %{
    conn: conn
  } do
    route_with([{10, 10, 7}])
    {:ok, view, _html} = live(conn, ~p"/cavebot")

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
    assert html =~ "passo 5,0"
  end

  test "the rehearsal names WHICH link broke, not just 'não andou'", %{conn: conn} do
    route_with([{10, 10, 7}])
    {:ok, view, _html} = live(conn, ~p"/cavebot")

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
    {:ok, view, _html} = live(conn, ~p"/cavebot")

    html = view |> element("#walk-test") |> render_click()
    assert html =~ "andando…"
  end

  # A task that dies must never leave the button spinning with nothing to
  # click — the state it was left in when its default hands did not exist.
  test "a rehearsal that dies mid-way says so instead of spinning forever", %{conn: conn} do
    route_with([{10, 10, 7}])
    {:ok, view, _html} = live(conn, ~p"/cavebot")

    view |> element("#walk-test") |> render_click()
    ref = :sys.get_state(view.pid).socket.assigns.walk_ref
    send(view.pid, {:DOWN, ref, :process, self(), {:badarg, []}})

    html = render(view)
    assert html =~ "o teste morreu no meio"
    refute html =~ "andando…"
  end

  test "the route photos have their place before they exist", %{conn: conn} do
    route_with([{10, 10, 7}])
    {:ok, _view, html} = live(conn, ~p"/cavebot")

    assert html =~ ~s(id="route-photos")
    assert html =~ "início da rota"
    assert html =~ "fim da rota"
    assert html =~ "sai sozinha quando você gravar"
  end

  # "quero poder configurar individualmente cada bolinha, para dar uma
  # funcionalidade dela, tipo 'mobar daqui' e marcar em outra 'até aqui'"
  # (Lucas, 2026-08-10).
  describe "a waypoint carries a job" do
    test "the job buttons appear on the SELECTED waypoint and nowhere else", %{conn: conn} do
      route_with([{10, 10, 7}, {20, 10, 7}])
      {:ok, view, html} = live(conn, ~p"/cavebot")

      refute html =~ ~s(id="waypoint-job-0")

      html = view |> element("#map-waypoint-0") |> render_click()
      assert html =~ ~s(id="waypoint-job-0")
      refute html =~ ~s(id="waypoint-job-1")
      assert html =~ "mobar daqui"
    end

    test "marking a stretch persists it and paints the leg blue", %{conn: conn} do
      route_with([{10, 10, 7}, {20, 10, 7}, {20, 20, 7}])
      {:ok, view, _html} = live(conn, ~p"/cavebot")

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
      {:ok, _view, html} = live(conn, ~p"/cavebot")

      refute html =~ "var(--color-pk-info)"
      refute html =~ ~s(id="map-lure-legend")
    end

    # A start nobody closed lures the WHOLE loop — which on screen looks like
    # "the hunt stopped fighting", with no error anywhere.
    test "a stretch left open warns, and closing it takes the warning away", %{conn: conn} do
      route_with([{10, 10, 7}, {20, 10, 7}])
      {:ok, view, _html} = live(conn, ~p"/cavebot")

      view |> element("#map-waypoint-0") |> render_click()
      html = view |> element("#waypoint-0-lure_start") |> render_click()
      assert html =~ ~s(id="lure-warning")
      assert html =~ "sem &quot;até aqui&quot;"

      view |> element("#map-waypoint-1") |> render_click()
      html = view |> element("#waypoint-1-lure_end") |> render_click()
      refute html =~ ~s(id="lure-warning")
    end

    test "a job can be taken back", %{conn: conn} do
      route_with([{10, 10, 7}, {20, 10, 7}])
      {:ok, view, _html} = live(conn, ~p"/cavebot")

      view |> element("#map-waypoint-0") |> render_click()
      view |> element("#waypoint-0-lure_start") |> render_click()
      view |> element("#waypoint-0-walk") |> render_click()

      assert [%Route{waypoints: [%{action: :walk}, %{action: :walk}]}] = Store.all()
    end
  end
end
