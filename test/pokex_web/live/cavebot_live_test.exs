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

  defp crowd_fact do
    %{
      read?: true,
      at: System.monotonic_time(:millisecond),
      took_ms: 27,
      me: {906, 720},
      box: {0, 0, 1812, 1440},
      pet: %{point: {906, 1022}, dx: 0, dy: 2, tiles: 2, hp_pct: 100},
      hostiles: [
        %{point: {1057, 1022}, dx: 1, dy: 2, from_me: 2, from_pet: 1, hp_pct: 100, skull?: true}
      ],
      listed: 1
    }
  end

  # UMA TELA SÓ, no notebook que fica ao lado do jogo (12/09). O mapa era 505px
  # de altura e o cerco morava DUAS TELAS abaixo da dobra — a página inteira
  # media 2129px num viewport de 900. Os dois desenhos passam a dividir a coluna
  # da esquerda, e o mapa é um selo.
  describe "the cockpit holds both drawings" do
    test "the eye lives in the cockpit, beside the fight, not below the fold", %{conn: conn} do
      WorldState.put(:crowd, crowd_fact(), System.monotonic_time(:millisecond))

      {:ok, view, _html} = live(conn, ~p"/cavebot")

      assert view |> element("#cavebot-cockpit") |> render() =~ ~s(id="siege-card")
    end

    test "the map is a stamp, not the column", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot")

      assert view |> element("#cavebot-map") |> render() =~ "max-w-[9rem]"
    end

    # A gaveta morava FORA do bloco de uma tela: fechada, uma linha de 35px
    # fazia a página inteira rolar.
    test "the instruments drawer rides the safety row", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot")

      assert view |> element("#cavebot-safety-row") |> render() =~ ~s(id="cavebot-instruments")
    end
  end

  describe "the siege card" do
    test "opens on the fact already on the blackboard", %{conn: conn} do
      WorldState.put(:crowd, crowd_fact(), System.monotonic_time(:millisecond))

      {:ok, _view, html} = live(conn, ~p"/cavebot")

      assert html =~ ~s(id="siege-card")
      assert html =~ ~s(data-from-me="2")
      refute html =~ "onde eles estão"
    end

    test "without a reading it says so", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/cavebot")
      assert html =~ "sem olho — nenhuma leitura ainda"
    end

    test "every reading the eye broadcasts redraws it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot")

      send(view.pid, {:crowd, crowd_fact()})

      assert render(view) =~ ~s(data-dx="1")
    end
  end

  test "marking a waypoint records the current position on the active route", %{conn: conn} do
    put_pos({10, 20, 7})

    {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

    view
    |> form("#new-route-form", %{"name" => "cavena", "dungeon" => "cavena-dg"})
    |> render_submit()

    html = view |> element("#mark-waypoint") |> render_click()

    assert [%Route{name: "cavena", dungeon: "cavena-dg", waypoints: waypoints}] = Store.all()

    assert [%{x: 10, y: 20, z: 7, stops: [], at: %DateTime{}}] = waypoints
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
             %{x: 10, y: 20, z: 7, stops: [], at: %DateTime{}},
             %{x: 20, y: 20, z: 7, stops: [], at: %DateTime{}}
           ] = waypoints

    view |> element("#toggle-recording") |> render_click()
    assert render(view) =~ "gravação parada"
  end

  # "eu geralmente clico com o botão do meio do mouse em um ponto da minha
  # tela" (Lucas, 2026-08-11) — the marker he makes with his own hand. Where
  # the pokémon waits is the hunt's own answer now (two tiles toward the pile),
  # so the click's point is not kept.
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

    test "a click while recording marks the spot", %{conn: conn} do
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
      assert [%Route{waypoints: [_only_one]}] = Store.all()

      # now HE clicks
      clicks!(8, {1240, 655})
      send(view.pid, :watch_middle)
      html = render(view)

      assert [%Route{waypoints: [_wp]}] = Store.all()
      assert html =~ "canto marcado no clique do meio"
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

      assert [%Route{waypoints: [_only_one]}] = Store.all()
    end

    # A ROTA APAGADA DEBAIXO DA GRAVAÇÃO. Armar exige uma rota ativa, e nada
    # garante que ela continue lá — apagar zera o `active_route`, e o
    # `Store.all/0` degrada um `routes.json` ilegível para lista vazia. A partir
    # daí `mark_kill_click_here/1` e `apply_hands/2` liam `.waypoints` de um nil
    # e derrubavam a página a cada 120ms, levando a gravação junto.
    test "the route deleted mid-recording does not take the page with it", %{conn: conn} do
      put_pos({10, 20, 7})
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      view |> form("#new-route-form", %{"name" => "mob", "dungeon" => ""}) |> render_submit()
      view |> element("#toggle-recording") |> render_click()

      send(view.pid, {:world, :minimap, %{pos: {10, 20, 7}}})
      render(view)

      render_click(view, "delete_route", %{})
      assert Store.all() == []

      # o clique do meio E as teclas, os dois caminhos que liam a rota
      clicks!(9, {1240, 655})
      presses!([%{code: 18, shift?: true, at: 1_000}])
      send(view.pid, :watch_middle)

      assert render(view) =~ "Gravar"
      assert Process.alive?(view.pid)
    end
  end

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
      Pokex.SettingsStash.stash!(cavebot_record_dwell_ms: 500)

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

      # …and it stays a MEASUREMENT: a long stop no longer promotes the corner
      # to anything, because the route stopped deciding when the hunt fights.
      refute Map.has_key?(List.last(waypoints), :action)
    end

    test "walking on keeps every dwell short and marks nothing", %{conn: conn} do
      Pokex.SettingsStash.stash!(cavebot_record_dwell_ms: 500)

      put_pos({10, 20, 7})
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")
      recording!(view)

      reading!(view, {10, 20, 7})
      reading!(view, {20, 20, 7})
      reading!(view, {30, 20, 7})

      assert [%Route{waypoints: waypoints}] = Store.all()
      refute Enum.any?(waypoints, &Map.has_key?(&1, :action))
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
      assert quadro.own_row_seen? == :by_name
      # a linha dele tem o marcador; a do Magneton não
      assert vision =~ "hero-user-circle"
      assert vision =~ "text-pk-ok"
    end

    # UM PLACAR, NÃO DOIS. O cartão "inimigos" contava as LINHAS cruas e a lista,
    # três dedos acima, mostrava a conta do cérebro: na tela de 12/09 eram seis
    # contra cinco, e a diferença era o pokémon DELE contado como inimigo — o
    # erro que custou a caçada de 27/08, agora impresso num cartão.
    test "the enemy tile and the list say the same number", %{conn: conn} do
      rows = [
        %{row: 0, name: "Steelix", hp_pct: 0.7, shiny?: false},
        %{row: 1, name: "Magneton", hp_pct: 1.0, shiny?: false},
        %{row: 2, name: "Magneton", hp_pct: 1.0, shiny?: false}
      ]

      see_world(100, 100, rows)

      picture =
        Pokex.Bots.Engine.Situation.build(
          %{
            battle: %{enemies: [0, 1, 2], enemies_detail: rows},
            own_name: "Steelix",
            own_out?: true,
            own_hp: 70
          },
          %{engage_from: 3},
          System.monotonic_time(:millisecond)
        )

      WorldState.put(:situation, picture, System.monotonic_time(:millisecond))
      on_exit(fn -> WorldState.forget(:situation) end)

      {:ok, view, _html} = live(conn, ~p"/cavebot")

      tile = view |> element("#tile-enemies") |> render()
      [_full, shown] = Regex.run(~r/class="pk-num[^"]*">\s*([^<\s]+)\s*</, tile)

      assert picture.enemies == 2
      assert shown == "2"
    end

    # "It still shows up as '?'" (2026-09-11). His row carries HIS pokémon's name:
    # with a trailing "?" while the brain only deduced the row from the health,
    # bare once the row's own drawing is the one it learned.
    test "his row prints his pokemon's name instead of a question mark", %{conn: conn} do
      detail = [
        %{row: 0, name: nil, word: 7, hp_pct: 0.3, shiny?: false},
        %{row: 1, name: nil, word: 9, hp_pct: 0.9, shiny?: false}
      ]

      see_world(100, 90, detail)
      now = System.monotonic_time(:millisecond)
      on_exit(fn -> WorldState.forget(:situation) end)

      build = fn prev ->
        Pokex.Bots.Engine.Situation.build(
          %{
            battle: %{enemies: [0, 1], enemies_detail: detail},
            own_name: "Venusaur",
            own_out?: true,
            own_hp: 90,
            prev: prev
          },
          %{engage_from: 3},
          now
        )
      end

      WorldState.put(:situation, build.(nil), now)
      {:ok, view, _html} = live(conn, ~p"/cavebot")
      assert view |> element("#cavebot-vision") |> render() =~ "Venusaur ?"

      learned = Enum.reduce(1..6, nil, fn _tick, prev -> build.(prev) end)
      WorldState.put(:situation, learned, now)
      {:ok, view, _html} = live(conn, ~p"/cavebot")
      vision = view |> element("#cavebot-vision") |> render()

      assert learned.own_row_seen? == :by_name
      assert vision =~ "Venusaur"
      refute vision =~ "Venusaur ?"
    end

    # TROCAR O POKÉMON SEM SAIR DA CAÇADA. "É geralmente o único motivo pelo
    # qual eu vou lá na parte de time no meu dia a dia" (12/09). A escrita é a
    # MESMA do /time — `Team.set_active/1`, que persiste e anuncia —, nunca uma
    # segunda regra que possa discordar dela.
    test "the pokemon on the field is switched from the hunt screen", %{conn: conn} do
      File.write!(
        Pokex.Pokedex.Team.file(),
        JSON.encode!(%{"members" => ["Shiny Venusaur", "Torterra"], "active" => "Shiny Venusaur"})
      )

      see_world(100, 100, [])

      {:ok, view, _html} = live(conn, ~p"/cavebot")
      card = view |> element("#cavebot-loadout") |> render()

      assert card =~ "Shiny Venusaur"
      assert card =~ "Torterra"

      view |> form("#cavebot-active-form", %{"active" => "Torterra"}) |> render_change()

      assert Pokex.Pokedex.Team.active() == "Torterra"
      assert view |> element("#cavebot-loadout") |> render() =~ "Torterra"
    end

    # A caixa não pode pular de altura a cada bicho que entra ou sai: o que ele
    # estava lendo embaixo dela some do lugar. Ela não crescia com a mobada,
    # mas SUMIA com a tela limpa — e some e volta a noite inteira. Medido em
    # 12/09: 76px de pulo na coluna, e o feed indo de 9 linhas pra 14 e
    # voltando. A caixa é a mesma vazia ou cheia.
    test "the list box keeps its height with a pile, with one, and with none", %{conn: conn} do
      caixa = fn rows ->
        see_world(100, 100, rows)
        {:ok, view, _html} = live(conn, ~p"/cavebot")
        view |> element("#cavebot-battle-rows") |> render()
      end

      pilha = for row <- 0..7, do: %{row: row, name: "Golem", hp_pct: 1.0, shiny?: false}

      for rows <- [pilha, Enum.take(pilha, 1), []] do
        assert caixa.(rows) =~ "h-[2.125rem]"
      end
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

    # A página nasce com `hunt: nil` e só recebe um snapshot quando ALGUMA
    # caçada roda. Sem caçada é exatamente a hora de escolher o modo da rota, e
    # era a única hora em que os botões vinham desabilitados, com um aviso
    # mandando parar a caçada que não estava rodando.
    test "with no hunt running at all the mode buttons are usable", %{conn: conn} do
      {:ok, a} = Route.append(Route.new("teste"), {10, 10, 5})
      :ok = Store.add(%{a | enabled?: true})

      {:ok, view, html} = live(conn, ~p"/cavebot?modo=editar")

      refute html =~ "pare a caçada pra trocar"

      html = view |> element("#route-mode-auto_combo") |> render_click()

      refute html =~ "pare a caçada antes de trocar o modo de combate"
      assert Enum.find(Store.all(), &(&1.name == "teste")).mode == :auto_combo
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
    test "typing the tile moves the waypoint and keeps its stops", %{conn: conn} do
      route_with([{10, 10, 7}, {20, 10, 7}])
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      view |> element("#map-waypoint-1") |> render_click()
      view |> element("#waypoint-1-wait") |> render_click()

      html =
        view
        |> form("#waypoint-place-1", %{"x" => "21", "y" => "11", "z" => "6"})
        |> render_submit()

      assert [%Route{waypoints: [_first, %{x: 21, y: 11, z: 6, stops: [:wait]}]}] = Store.all()
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

    # Mesmo buraco do outro lado: o formulário lia `active_route.waypoints`
    # ANTES do `with_route/2`, que é quem sabe responder a um nil. Enviado no
    # instante em que a rota deixa de existir, derrubava a página inteira.
    test "the form submitted after the route is gone does not take the page with it",
         %{conn: conn} do
      route_with([{10, 10, 7}])
      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")

      view |> element("#map-waypoint-0") |> render_click()
      render_click(view, "delete_route", %{})
      assert Store.all() == []

      render_submit(view, "move_waypoint_to", %{"index" => "0", "x" => "21", "y" => "11"})

      assert Process.alive?(view.pid)
      assert render(view) =~ "apagada"
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
      assert card =~ "ninguém em campo"
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
      send(view.pid, {:game, %{counters: %{rescues: 7, heals: 3}}})
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

  describe "the safety card" do
    setup do
      Pokex.SettingsStash.stash!(
        rescue_enabled: false,
        heal_skill_enabled: true,
        status_cure_enabled: false
      )

      :ok
    end

    test "shows each net by its state, in words", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot")

      assert view |> element("#safety-rescue") |> render() =~ "resgate desligado"
      assert view |> element("#safety-heal") |> render() =~ "cura armada"
      assert view |> element("#safety-cure") |> render() =~ "limpeza de status desligada"
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
      assert has_element?(view, "#cavebot-area-reach")
      refute html =~ ~s(<details id="cavebot-instruments" open)

      {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")
      refute has_element?(view, "#cavebot-instruments")
    end
  end

  # O TETO DO FEED CONTAVA O QUE ELE NÃO VÊ. O interruptor de debug nasce
  # desligado e o cérebro fala várias linhas de diagnóstico por frase dita —
  # então quarenta linhas de buffer viravam três ou quatro na tela ("ainda está
  # aparecendo só umas 3 ou 4 mensagens", 12/09). Medido na tela renderizada:
  # 70 linhas recebidas, 28 delas ditas, 16 sobrevivendo.
  describe "the feed's ceiling" do
    test "a burst of debug never pushes out what he reads", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot")

      # INTERCALADAS, como na noite dele: cada frase dita vem no meio de um punhado
      # de diagnósticos. Em bloco, o teto antigo passava — o que ele via era o
      # fim da fila, e ali as ditas ainda estavam.
      for i <- 1..12 do
        for d <- 1..4, do: send(view.pid, {:engine_log, :debug, "quadro: tique #{i}.#{d} nada"})
        send(view.pid, {:game_log, :macro, "🚑 revive #{i} despachado"})
      end

      feed = view |> element("#cavebot-log") |> render()

      for i <- 1..12, do: assert(feed =~ "revive #{i} despachado")
      refute feed =~ "sem novidade"
    end
  end

  # "Capturar shinies… e ver isso na tela": the shiny's story reaches the feed,
  # the Catcher's scan chatter does not, and the capture tile says "shiny"
  # while the aim is on.
  describe "the shiny story on the Central" do
    test "the aim and the ball lines get through, the scans do not", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot")

      send(
        view.pid,
        {:combat_log, :macro, "✨ Electrode shiny na tela — mancha de 80px da cor dele"}
      )

      send(
        view.pid,
        {:catcher_log, :macro, "captura: 🌟 corpo do Electrode shiny em 116,116 — bola"}
      )

      send(view.pid, {:catcher_log, :macro, "captura: 🌟 bola em 116,116"})

      # a bola da VARREDURA, a mesma linha sem a estrela: a caça comum do
      # Catcher não é assunto desta tela
      send(view.pid, {:catcher_log, :macro, "captura: bola 2 em 402,377"})

      send(
        view.pid,
        {:catcher_log, :macro, "captura: 🔎 varri 12 janelas (300×300) · acervo vazio"}
      )

      html = render(view)
      assert html =~ "Electrode shiny na tela"
      assert html =~ "corpo do Electrode shiny"
      assert html =~ "bola em 116,116"
      refute html =~ "bola 2 em 402,377"
      refute html =~ "varri 12 janelas"
    end

    test "the capture tile says shiny while the trail has one", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot")
      tile = fn -> view |> element("#tile-capture") |> render() end
      catcher = fn extra -> Map.merge(%{counters: %{captures: 0}}, extra) end

      # the bar still standing: followed, nothing on the ground yet
      send(view.pid, {:catcher, catcher.(%{hunted?: true, anchors: 0, pending_corpses: 0})})
      assert tile.() =~ "shiny"
      assert tile.() =~ "seguindo a barra do shiny"

      # it fell: the anchor is the body, and the road holds for it
      send(view.pid, {:catcher, catcher.(%{hunted?: false, anchors: 1, pending_corpses: 0})})
      assert tile.() =~ "corpo no chão"

      send(view.pid, {:catcher, catcher.(%{hunted?: false, anchors: 1, pending_corpses: 1})})
      assert tile.() =~ "bola no ar"

      send(view.pid, {:catcher, catcher.(%{hunted?: false, anchors: 0, pending_corpses: 0})})
      assert tile.() =~ "corpos na fila"
    end
  end

  # O CAMINHO DO SHINY, na tela onde ele passa a noite: um passo por vez, com a
  # porta ao lado, e a guarda a um clique daqui.
  describe "the shiny seal" do
    setup do
      :persistent_term.erase({Pokex.Vision.ColorRules, :cache})
      # a casa de teste é compartilhada pelo arquivo: uma regra ensinada por um
      # teste vizinho faria este começar já com metade do caminho andado
      clear = fn ->
        :persistent_term.erase({Pokex.Vision.ColorRules, :cache})
        Enum.each(Pokex.Vision.ColorRules.list(), &Pokex.Vision.ColorRules.delete(&1["slug"]))
      end

      clear.()
      on_exit(clear)
      Pokex.SettingsStash.stash!(shiny_guard_enabled: false, shiny_sparkle: false)
      :ok
    end

    defp teach_and_prove do
      {:ok, %{"slug" => slug}} =
        Pokex.Vision.ColorRules.add(%{
          "name" => "Electrode shiny",
          "colors" => [%{"rgb" => [40, 160, 60], "tol_h" => 12, "tol_sv" => 30}],
          "min_px" => 50
        })

      :ok = Pokex.Vision.ColorRules.mark_proven(slug, 3)
    end

    test "with nothing taught it says how many steps and where to go", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/cavebot")

      assert html =~ ~s(id="cavebot-shiny")
      assert view |> element("#cavebot-shiny") |> render() =~ "shiny: 1 passo"
      assert view |> element("#cavebot-shiny-list") |> render() =~ "nenhuma cor de shiny ensinada"
      assert view |> element("#cavebot-shiny-list") |> render() =~ "/calibration"
    end

    test "the last step is one click from here, and the seal turns green", %{conn: conn} do
      teach_and_prove()

      {:ok, view, _html} = live(conn, ~p"/cavebot")

      assert view |> element("#cavebot-shiny-list") |> render() =~
               "caçador de shiny está desligado"

      view |> element("#shiny-arm") |> render_click()

      assert Pokex.Settings.get(:shiny_guard_enabled)
      assert view |> element("#cavebot-shiny") |> render() =~ "shiny armado: Electrode shiny"

      # o passo bloqueante sai; o CONSELHO da bola fica, que é o que ele ainda
      # ganha lendo (a bola padrão sai do mesmo jeito)
      lista = view |> element("#cavebot-shiny-list") |> render()
      refute lista =~ "caçador de shiny está desligado"
      assert lista =~ "bola padrão"
    end
  end

  # O CARD COMO FONTE DE VALIDAÇÃO (09/09): "pra eu ver a interseção e nós
  # juntos podermos usar aquilo como uma fonte visual de validação do
  # funcionamento do reconhecimento de imagens".
  describe "the siege card as proof" do
    defp crowd_with(hostiles, pet \\ nil) do
      %{
        read?: true,
        at: System.monotonic_time(:millisecond),
        took_ms: 27,
        me: {906, 720},
        box: {0, 0, 1812, 1440},
        pet: pet,
        hostiles: hostiles,
        listed: length(hostiles)
      }
    end

    defp hostile(point, dx, dy, extra \\ %{}) do
      Map.merge(
        %{
          point: point,
          dx: dx,
          dy: dy,
          from_me: max(abs(dx), abs(dy)),
          from_pet: nil,
          hp_pct: 100,
          skull?: false
        },
        extra
      )
    end

    test "the shiny gets its own colour and says how far past the trigger it is", %{conn: conn} do
      :persistent_term.erase({Pokex.Vision.ColorRules, :cache})

      {:ok, %{"slug" => slug}} =
        Pokex.Vision.ColorRules.add(%{
          "name" => "Charizard preto",
          "colors" => [%{"dark" => 30, "spread" => 12, "rgb" => [17, 16, 16]}],
          "min_px" => 3_000
        })

      :ok = Pokex.Vision.ColorRules.mark_proven(slug, 900)
      now = System.monotonic_time(:millisecond)

      WorldState.put(:crowd, crowd_with([hostile({1057, 1022}, 1, 2)]), now)

      WorldState.put(
        :special,
        %{especial?: true, vistos: [%{name: "Charizard preto", px: 12_000, point: {1057, 1022}}]},
        now
      )

      {:ok, view, _html} = live(conn, ~p"/cavebot")
      card = view |> element("#siege-card") |> render()

      assert card =~ ~s(data-special="1"), "o quadrado do shiny se declara"
      assert card =~ "pk-shiny", "…e tem cor própria"
      # 12.000px contra um gatilho de 3.000 = 400%
      assert card =~ "≈400%", "…e diz o quanto passou do gatilho, marcado como CONFIANÇA"
      assert card =~ "Charizard preto"

      :persistent_term.erase({Pokex.Vision.ColorRules, :cache})
    end

    test "the pet square says which of the three paths found it", %{conn: conn} do
      pet = %{
        point: {906, 1022},
        dx: 0,
        dy: 2,
        tiles: 2,
        hp_pct: 96,
        by: :sprite,
        score: 0.87
      }

      WorldState.put(:crowd, crowd_with([], pet), System.monotonic_time(:millisecond))

      {:ok, view, _html} = live(conn, ~p"/cavebot")
      card = view |> element("#siege-card") |> render()

      assert card =~ "≈87%",
             "a nota da sprite ensinada vai no quadrado, com o ≈ que a separa da vida"

      refute card =~ ">87<", "número puro é VIDA — a semelhança nunca pode se passar por ela"
      assert card =~ "achado pela sprite ensinada"
    end

    test "a pet found by health says so, because that is the weak path", %{conn: conn} do
      pet = %{point: {906, 1022}, dx: 0, dy: 2, tiles: 2, hp_pct: 96, by: :hp, score: nil}
      WorldState.put(:crowd, crowd_with([], pet), System.monotonic_time(:millisecond))

      {:ok, view, _html} = live(conn, ~p"/cavebot")
      card = view |> element("#siege-card") |> render()

      assert card =~ "vida"
      assert card =~ "nem sprite nem caixa"
    end

    test "the mirror is off until he asks, and then it says so", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot")

      assert view |> element("#siege-mirror") |> render() =~ "desligado"
      view |> element("#siege-mirror") |> render_click()
      assert view |> element("#siege-mirror") |> render() =~ "ligado"
    end

    # UM LAÇO SÓ. O tique se reagendava com um timer sem dono: desligar e
    # religar dentro dos dois segundos deixava o antigo vivo e passavam a
    # existir dois laços, cada um tirando uma foto da tela inteira.
    test "toggling the mirror off and on keeps a single loop", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot")

      view |> element("#siege-mirror") |> render_click()
      antes = :sys.get_state(view.pid).socket.assigns.mirror_timer

      view |> element("#siege-mirror") |> render_click()
      assert :sys.get_state(view.pid).socket.assigns.mirror_timer == nil
      assert Process.read_timer(antes) == false

      view |> element("#siege-mirror") |> render_click()
      depois = :sys.get_state(view.pid).socket.assigns.mirror_timer
      assert is_reference(depois)
      assert depois != antes
    end

    # O ESPELHO SAI COM ELE. `patch` pros Editores não desmonta a página, e a
    # foto seguia sendo tirada e empurrada pro navegador atrás de uma tela que
    # não a desenha.
    test "leaving the watching mode turns the mirror off", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot")

      view |> element("#siege-mirror") |> render_click()
      assert view |> element("#siege-mirror") |> render() =~ "ligado"

      assert view |> render_patch(~p"/cavebot?modo=editar")
      assert view |> render_patch(~p"/cavebot")
      assert view |> element("#siege-mirror") |> render() =~ "desligado"
    end
  end
end
