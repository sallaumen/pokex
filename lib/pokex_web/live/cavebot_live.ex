defmodule PokexWeb.CavebotLive do
  @moduledoc """
  /cavebot — record a hunting route by WALKING it: Lucas walks in the game,
  this page follows his position through the `:minimap` fact and each press of
  "marcar waypoint aqui" appends the current tile to the active route. Editing
  is by deletion (wrong click = apagar + marcar de novo); ordering is the order
  he walked.

  The page is a `:minimap` consumer while it lives — `Perception.attach/1` in
  `mount` is what makes the feed capture at all (feeds are demand-driven), so
  without it the recorded position would be nil or stale. Persistence goes
  through `Cavebot.Store` (same name = replace). A route may climb: waypoints
  carry their own floor, and stairs are recorded like any other pair of
  corners.
  """
  use PokexWeb, :live_view

  import PokexWeb.CavebotComponents

  alias Pokex.Bots.Cavebot.{HandsRead, Photos, Recording, Route, Store, WalkTest, Worker}
  alias Pokex.Bots.Combat
  alias Pokex.Bots.Combat.Loadout
  alias Pokex.Calibration
  alias Pokex.Perception
  alias Pokex.Settings
  alias Pokex.World
  alias PokexWeb.CavebotMap
  alias PokexWeb.PositionReadout

  # Enough to see the last decisions without the page becoming a terminal.
  @log_lines 8

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Pokex.PubSub, Perception.topic())
      # The hunt narrates itself on its own topic — HEARD, never asked: a call
      # to the worker parks behind whatever the Body is doing, and this page
      # must stay alive while the fleet works.
      Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
      # The FIGHT narrates itself too, and this page had no idea who it was
      # fighting as — "não vejo isso visível aqui na Central de caçada e nem
      # vejo na prática se realmente isso tá impactando" (Lucas, 2026-08-12).
      # Heard, never asked, for the same reason as the hunt above.
      Phoenix.PubSub.subscribe(Pokex.PubSub, Combat.Worker.topic())
      # the minimap feed only captures while someone is attached — the
      # recording page IS that someone, exactly while it is open.
      #
      # The battle feed is deliberately NOT attached: during a hunt the workers
      # already run it and this page reads the fact for free, while OUTSIDE a
      # hunt attaching it would capture for nothing and read the browser's own
      # pixels — which is exactly how this tile announced a SHINY that did not
      # exist the first time it was drawn (2026-08-10).
      Perception.attach(:minimap)
    end

    routes = Store.all()

    {:ok,
     socket
     |> PokexWeb.HeaderState.relay_workers()
     |> assign(
       page_title: "Cavebot",
       routes: routes,
       active_route: default_active(routes),
       pos: World.snapshot().pos,
       # what the RUNNING fight holds; nil until it says so, and then the page
       # falls back to the configuration and labels it as such
       combat: nil,
       minimap_gap?: minimap_gap?(),
       recording?: false,
       # Read health: read_coord is all-or-nothing (requires 1.0 confidence),
       # so ONE doubtful glyph drops the whole coordinate to nil. Occasional
       # misses don't hurt recording — but without a counter there is no way
       # to tell reading well apart from barely reading.
       reads: 0,
       misses: 0,
       notice: nil,
       notice_kind: :warn,
       # the hunt's own snapshot (state, hold reason, counters), as broadcast
       hunt: nil,
       world: World.snapshot(),
       selected: nil,
       photo_busy?: false,
       # the hunt's own narration: what it just did, in its own words
       log: [],
       walk_test: nil,
       walk_ref: nil,
       # Recording reads the CLOCK: where he has been standing and since when.
       # A corner marked in passing is a walk; half a minute on one tile is a
       # kill spot (Cavebot.Recording).
       still_pos: nil,
       still_since: nil,
       # his OWN marker: the middle click that parks his pokémon. Watched as a
       # counter, so a click too fast to catch by polling still shows up.
       middle_count: nil,
       middle_timer: nil,
       # …and his KEYS: shift+1 opens a fight, shift+3 closes it, and the
       # skills in between are the combo he really used there
       hands: HandsRead.new(),
       # the combo being pressed RIGHT NOW, held in memory: writing it per
       # drain rewrote the whole routes file eight times a second, mid-fight
       pending_combo: [],
       pending_index: nil,
       # waypoints he marked with his own hands — never overwritten by the
       # inference
       hand_marked: [],
       # WHERE the pokémon is sent: read through the calibration, because a
       # distance from the character is only a screen point once you know
       # where the character is drawn — and how big a tile is.
       calibration: loaded_calibration(),
       tile_px: Calibration.tile_px(),
       park_default: {Settings.get(:cavebot_park_tiles_x), Settings.get(:cavebot_park_tiles_y)}
     )}
  end

  # Every minimap publish refreshes the position readout — and, while RECORDING,
  # is what actually lays the route down.
  #
  # A button pressed per waypoint could never work: to click it Lucas has to
  # bring the browser forward, which takes the game out of focus AND can cover
  # the very minimap the capture reads his position from. So recording happens
  # while he is IN the game: he arms it here, walks the whole route, and comes
  # back. The page keeps receiving positions in the background — captures never
  # depended on focus — and lays the waypoints itself.
  @impl true
  def handle_info({:world, :minimap, _obs}, socket) do
    world = World.snapshot()
    pos = world.pos

    socket =
      if pos == nil,
        do: assign(socket, world: world, pos: nil, misses: socket.assigns.misses + 1),
        else: assign(socket, world: world, pos: pos, reads: socket.assigns.reads + 1)

    if socket.assigns.recording? and socket.assigns.active_route do
      socket = if pos, do: maybe_record(socket, pos), else: socket
      {:noreply, track_dwell(socket, pos)}
    else
      {:noreply, socket}
    end
  end

  # Every other fact (battle above all: how many enemies are on screen) refreshes
  # the world strip without touching the recording.
  def handle_info({:world, _key, _obs}, socket),
    do: {:noreply, assign(socket, world: World.snapshot())}

  def handle_info({:cavebot, snapshot}, socket), do: {:noreply, assign(socket, hunt: snapshot)}

  def handle_info({:combat, snapshot}, socket), do: {:noreply, assign(socket, combat: snapshot)}

  # the fight's log lines ride the same topic and are not this page's business
  def handle_info({:combat_log, _level, _text}, socket), do: {:noreply, socket}

  def handle_info({:walk_test, result}, socket),
    do: {:noreply, assign(socket, walk_test: result, walk_ref: nil)}

  # The task died before answering: say so instead of spinning. A normal exit
  # after the result already landed is not a failure — walk_ref is nil by then.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{assigns: %{walk_ref: ref}} = socket),
    do: {:noreply, assign(socket, walk_test: {:error, {:crashed, reason}}, walk_ref: nil)}

  # The hunt narrates its edges (waypoint reached, block, a hold appearing) —
  # the tail of that is what turns "parou" into "parou POR QUÊ".
  def handle_info({:cavebot_log, level, text}, socket) do
    line = %{level: level, text: text, at: Time.utc_now()}
    {:noreply, assign(socket, log: Enum.take([line | socket.assigns.log], @log_lines))}
  end

  # The marker he asked for: "eu geralmente clico com o botão do meio do mouse
  # em um ponto da minha tela" (2026-08-11). Better than the clock in both
  # directions — it says exactly WHERE, and standing still is invisible to the
  # coordinate reader anyway.
  def handle_info(:watch_middle, %{assigns: %{recording?: true}} = socket) do
    {:noreply,
     socket
     |> read_middle_click()
     |> read_his_keys()
     |> schedule_middle_watch()}
  end

  def handle_info(:watch_middle, socket), do: {:noreply, socket}

  def handle_info(_msg, socket), do: {:noreply, socket}

  @middle_watch_ms 120

  defp schedule_middle_watch(socket) do
    if socket.assigns.middle_timer, do: Process.cancel_timer(socket.assigns.middle_timer)
    assign(socket, middle_timer: Process.send_after(self(), :watch_middle, @middle_watch_ms))
  end

  defp stop_middle_watch(socket) do
    if socket.assigns.middle_timer, do: Process.cancel_timer(socket.assigns.middle_timer)
    disarm_key_watch()
    assign(socket, middle_timer: nil, middle_count: nil)
  end

  # The helper polls the keys HE presses inside its own loop, and it has no way
  # to know the recording ended: without this it would keep reading ten key
  # states every 8ms forever, competing with the game he is playing. An empty
  # watch list is the off switch.
  defp disarm_key_watch do
    Pokex.Rig.impl().key_watch([])
  catch
    :exit, _no_rig -> :ok
  end

  # What his hands did since the last look. Nothing here is a command: it is
  # the recording learning the fight it just watched — how long it took, the
  # skills he used, and the pause he leaves for the pile to close in.
  defp read_his_keys(socket) do
    case Pokex.Rig.impl().key_watch(HandsRead.codes()) do
      {:ok, []} -> socket
      {:ok, events} -> apply_hands(socket, events)
      _unavailable -> socket
    end
  catch
    :exit, _reason -> socket
  end

  defp apply_hands(socket, events) do
    {hands, reading} = HandsRead.read(socket.assigns.hands, events)
    socket = assign(socket, hands: hands)

    # shift+1 is the game's attack mode, and he presses it to LEAVE the
    # gathering: "toda luta é uma parada na rota" (2026-08-11). It may lay the
    # waypoint itself, so the index is read after it.
    socket = if reading.fight_started?, do: mark_fight_here(socket), else: socket
    socket = if reading.gathering_started?, do: mark_gathering_here(socket), else: socket
    index = length(socket.assigns.active_route.waypoints) - 1

    socket
    |> flush_if_moved_on(index)
    |> buffer_combo(index, reading.combo)
    |> settle(index, reading)
  end

  # The combo GROWS across drains — he presses 4, then 1, then 3, and each look
  # sees only its own slice — so it is collected in MEMORY. Writing it per
  # drain meant `Store.add` reading, decoding, encoding and rewriting the whole
  # routes file eight times a second, in the middle of a fight.
  defp buffer_combo(socket, _index, []), do: socket

  defp buffer_combo(socket, index, keys) do
    assign(socket,
      pending_index: index,
      pending_combo: socket.assigns.pending_combo ++ keys
    )
  end

  # He walked on: whatever he was pressing belongs to the waypoint he pressed
  # it at, not to the one he reached afterwards.
  defp flush_if_moved_on(%{assigns: %{pending_index: nil}} = socket, _index), do: socket

  defp flush_if_moved_on(%{assigns: %{pending_index: index}} = socket, index), do: socket

  defp flush_if_moved_on(socket, _index), do: flush_combo(socket)

  # A closed fight (his shift+3) or a measured huddle is a CONCLUSION — that
  # is when the disk hears about it, not every 120ms.
  defp settle(socket, _index, %{fight_ms: nil, gather_ms: nil}), do: socket

  defp settle(socket, index, reading) do
    timings =
      [fight_ms: reading.fight_ms, gather_ms: reading.gather_ms]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    socket
    |> write_timings(index, timings)
    |> flush_combo()
    |> then(
      &if reading.fight_ms,
        do: assign(&1, notice: fight_note(reading), notice_kind: :ok),
        else: &1
    )
  end

  # Called when he moves on, when the fight closes, and when he stops
  # recording: a combo he pressed and never closed with shift+3 is still what
  # he pressed.
  defp flush_combo(%{assigns: %{pending_combo: []}} = socket),
    do: assign(socket, pending_index: nil)

  defp flush_combo(%{assigns: %{pending_index: index, pending_combo: combo}} = socket) do
    existing = Enum.at(socket.assigns.active_route.waypoints, index)[:combo] || []

    socket
    |> write_timings(index, combo: existing ++ combo)
    |> assign(pending_combo: [], pending_index: nil)
  end

  defp write_timings(socket, _index, []), do: socket

  defp write_timings(socket, index, timings) when is_integer(index) and index >= 0 do
    updated = Route.set_timing(socket.assigns.active_route, index, timings)
    :ok = Store.add(updated)
    reload_routes(socket, updated.name)
  end

  defp write_timings(socket, _index, _timings), do: socket

  defp fight_note(%{fight_ms: ms, combo: combo}) do
    base = "⚔️ luta de #{round(ms / 1000)}s medida aqui"
    if combo == [], do: base, else: base <> " — skills #{Enum.join(combo, ", ")}"
  end

  defp read_middle_click(socket) do
    case Pokex.Rig.impl().middle_watch() do
      {:ok, %{count: count, point: point} = watch} ->
        middle_click_edge(socket, count, point, watch[:at])

      # no helper (tests, another OS): the clock keeps working on its own
      _unavailable ->
        socket
    end
  catch
    # the rig is not even running — recording must not die with it
    :exit, _reason -> socket
  end

  # Only the JUMP counts, and the first reading only learns the baseline —
  # a session with clicks already behind it must not mark on the first tick.
  defp middle_click_edge(%{assigns: %{middle_count: nil}} = socket, count, _point, _at),
    do: assign(socket, middle_count: count)

  defp middle_click_edge(%{assigns: %{middle_count: seen}} = socket, count, _point, _at)
       when count <= seen,
       do: socket

  # `at` is the HELPER's clock, the same one the key presses are stamped with —
  # the huddle is the gap between this click and his first skill.
  defp middle_click_edge(socket, count, point, at) do
    hands = if at, do: HandsRead.parked(socket.assigns.hands, at), else: socket.assigns.hands

    socket
    |> assign(middle_count: count, hands: hands)
    |> mark_park_here(point)
  end

  # How long he has been standing on this tile, and what that MEANS.
  #
  # "Aqui ele só marcou ponto rápido, então ele só tá andando, e aqui ele ficou
  # um tempão nesse ponto, então ele tá matando bichos nesse ponto, capturando
  # nesse ponto" (Lucas, 2026-08-11). Standing still is the one thing the
  # recorder can read without any new feed, and it says more than the shape of
  # the walk ever did.
  #
  # Measured from the LAST TIME THE POSITION CHANGED, never from readings that
  # repeat — because standing still is exactly when the readings stop. The
  # client only draws the coordinate while the position CHANGES, so a standing
  # character reads `nil` forever, and the first cut of this (2026-08-11)
  # waited for two equal readings that could never arrive. It measured
  # stillness with the one signal that vanishes during it, and recorded a dwell
  # of nil on all 52 waypoints of his first real route.
  defp track_dwell(socket, pos) do
    now = System.monotonic_time(:millisecond)

    cond do
      # a NEW place: whatever he was doing at the old one is over
      pos != nil and pos != socket.assigns.still_pos ->
        assign(socket, still_pos: pos, still_since: now)

      # same place, or no reading at all (which IS the standing-still symptom)
      socket.assigns.still_since != nil ->
        dwelling(socket, socket.assigns.still_pos, now - socket.assigns.still_since)

      true ->
        socket
    end
  end

  # Crossing the "he stopped here" mark lays a waypoint on the spot (a place he
  # stood is a place that matters, and it is rarely a corner); after that every
  # reading updates its dwell, so the number is right even if the recording is
  # stopped without him ever moving again.
  defp dwelling(socket, nil, _dwell), do: socket

  defp dwelling(socket, pos, dwell) do
    route = socket.assigns.active_route

    cond do
      dwell < Pokex.Settings.get(:cavebot_record_dwell_ms) ->
        socket

      last_waypoint_at?(route, pos) ->
        write_dwell(socket, route, dwell)

      true ->
        socket
        |> record_waypoint(route, pos)
        |> then(&write_dwell(&1, &1.assigns.active_route, dwell))
    end
  end

  defp last_waypoint_at?(%Route{waypoints: waypoints}, {x, y, z}) do
    match?(%{x: ^x, y: ^y, z: ^z}, List.last(waypoints))
  end

  defp write_dwell(socket, %Route{waypoints: waypoints} = route, dwell) do
    index = length(waypoints) - 1
    updated = Route.set_dwell(route, index, dwell)

    {updated, note} =
      if Pokex.Settings.get(:cavebot_smart_recording) do
        Recording.infer_with_note(
          updated,
          index,
          Pokex.Settings.get(:cavebot_record_fight_dwell_ms),
          hand_marked: socket.assigns.hand_marked
        )
      else
        {updated, nil}
      end

    :ok = Store.add(updated)

    socket
    |> then(&if note, do: assign(&1, notice: note, notice_kind: :ok), else: &1)
    |> reload_routes(updated.name)
  end

  # A waypoint per tile would be noise — the client pathfinds between points, so
  # what serves the walker are the CORNERS. Only record once he has walked
  # `cavebot_record_min_tiles` away from the last one.
  defp maybe_record(socket, {x, y, z} = pos) do
    route = socket.assigns.active_route
    min_tiles = Pokex.Settings.get(:cavebot_record_min_tiles)

    far_enough? =
      case List.last(route.waypoints) do
        nil ->
          true

        # A CLIMB is always worth a waypoint, however little the tile moved:
        # the top of a staircase shares x/y with its foot, so the distance
        # rule alone would silently drop the one waypoint that teaches the
        # route the floor exists.
        %{z: lz} when lz != z ->
          true

        %{x: lx, y: ly} ->
          abs(x - lx) >= min_tiles or abs(y - ly) >= min_tiles
      end

    if far_enough?, do: record_waypoint(socket, route, pos), else: socket
  end

  # Climbing is recorded like walking: taking the stairs mid-recording used to
  # STOP it ("mudou de andar — parei a gravação", Lucas, 2026-08-10, on the
  # first two-floor hunt he tried). The waypoint carries its own floor, so the
  # stairs simply become two waypoints — one at each end.
  defp record_waypoint(socket, route, pos) do
    {:ok, updated} = Route.append(route, pos, at: DateTime.utc_now())
    :ok = Store.add(updated)

    socket
    |> assign(notice: recording_notice(updated), notice_kind: :ok)
    |> reload_routes(updated.name)
  end

  defp recording_notice(route) do
    case Route.floors(route) do
      [_one] -> "gravando — #{length(route.waypoints)} waypoints"
      many -> "gravando — #{length(route.waypoints)} waypoints, andares #{Enum.join(many, " e ")}"
    end
  end

  @impl true
  def handle_event("mark_waypoint", _params, socket) do
    case {socket.assigns.active_route, World.snapshot().pos} do
      {nil, _pos} ->
        {:noreply,
         assign(socket,
           notice: "nenhuma rota ativa — crie ou selecione uma primeiro",
           notice_kind: :warn
         )}

      {_route, nil} ->
        {:noreply,
         assign(socket,
           notice:
             "não estou lendo tua posição — o HUD foi localizado? " <>
               "a janela do navegador está cobrindo o minimapa do jogo?",
           notice_kind: :warn,
           pos: nil
         )}

      {_route, {_x, _y, z} = pos} ->
        {:ok, updated} = Route.append(socket.assigns.active_route, pos, at: DateTime.utc_now())
        :ok = Store.add(updated)

        {:noreply,
         socket
         |> assign(
           notice: "waypoint #{length(updated.waypoints)} marcado (andar #{z})",
           notice_kind: :ok,
           pos: pos
         )
         |> reload_routes(updated.name)}
    end
  end

  # Arms/disarms recording. Arming requires an active route — without one there
  # is nowhere to put the waypoints, and recording "into nothing" would be the
  # worst possible silent failure.
  def handle_event("toggle_recording", _params, socket) do
    cond do
      socket.assigns.recording? ->
        n = length((socket.assigns.active_route && socket.assigns.active_route.waypoints) || [])
        photo(socket, :finish)

        {:noreply,
         socket
         |> flush_combo()
         |> stop_middle_watch()
         |> assign(
           recording?: false,
           notice: "gravação parada — #{n} waypoints na rota, e tirei a foto do fim",
           notice_kind: :ok
         )}

      socket.assigns.active_route == nil ->
        {:noreply,
         assign(socket,
           notice: "crie ou selecione uma rota antes de gravar",
           notice_kind: :warn
         )}

      true ->
        photo(socket, :start)

        {:noreply,
         socket
         |> assign(
           recording?: true,
           notice:
             "gravando — volte pro jogo e ande a rota. " <>
               "Clique do meio marca onde o pokémon fica quando tu acaba de mobar.",
           notice_kind: :ok
         )
         |> schedule_middle_watch()}
    end
  end

  # The rehearsal: three tiles toward the next waypoint, and a verdict naming
  # WHICH link broke. Arming a whole hunt to learn that the character does not
  # move is an expensive question with a slow answer.
  def handle_event("walk_test", _params, socket) do
    target =
      List.first((socket.assigns.active_route && socket.assigns.active_route.waypoints) || [])

    page = self()

    # MONITORED, not fire-and-forget: a task that dies must not leave the
    # button spinning "andando…" forever with nothing to click — which is
    # exactly what an UndefinedFunctionError inside it did (2026-08-10).
    {:ok, _pid, ref} =
      spawn_monitor_task(fn -> send(page, {:walk_test, WalkTest.run(target)}) end)

    {:noreply, assign(socket, walk_test: :running, walk_ref: ref)}
  end

  def handle_event("select_waypoint", %{"index" => index}, socket) do
    index = String.to_integer(index)
    selected = if socket.assigns.selected == index, do: nil, else: index
    {:noreply, assign(socket, selected: selected)}
  end

  # A waypoint is not only a place: it can carry a JOB. "Mobar daqui" … "até
  # aqui" brackets the stretch the hunt walks GATHERING mobs — drawn blue on
  # the map, and obeyed by the hunt itself in the next step.
  def handle_event("set_waypoint_action", %{"index" => index, "action" => action}, socket) do
    index = String.to_integer(index)
    socket = remember_hand_mark(socket, index)

    with_route(socket, fn route ->
      action = decode_action(action)
      {Route.set_action(route, index, action), "waypoint #{index + 1}: #{action_label(action)}"}
    end)
  end

  # What the hunt DOES at a waypoint once the fighting there stops: sweep the
  # ground, reset the cooldowns on a revive, or simply stand still. A second
  # axis, not more jobs — the waypoint worth sweeping and reviving at is
  # usually the one already marked "até aqui".
  def handle_event("toggle_waypoint_stop", %{"index" => index, "stop" => stop}, socket) do
    index = String.to_integer(index)
    stop = decode_stop(stop)
    socket = remember_hand_mark(socket, index)

    with_route(socket, fn route ->
      on? = stop not in Route.stops_at(route.waypoints, index)

      {Route.set_stop(route, index, stop, on?),
       "waypoint #{index + 1}: #{stop_label(stop)} #{if on?, do: "ligado", else: "desligado"}"}
    end)
  end

  # The exact tile, typed by hand. A recording is a WALK, and a walk rounds:
  # the staircase he could not take was one tile wide and the recorded corner
  # sat beside it ("tem como eu editar na mao pontos da rota?", 2026-08-11).
  def handle_event("move_waypoint_to", %{"index" => index} = params, socket) do
    index = String.to_integer(index)

    case place_from(params, Enum.at(socket.assigns.active_route.waypoints, index)) do
      nil ->
        {:noreply, assign(socket, notice: "coordenada inválida", notice_kind: :warn)}

      {x, y, z} = place ->
        with_route(socket, fn route ->
          {Route.move_to(route, index, place),
           "waypoint #{index + 1} corrigido: #{x}, #{y} (andar #{z})"}
        end)
    end
  end

  # …or simply: it is where I am standing right now.
  def handle_event("move_waypoint_here", %{"index" => index}, socket) do
    index = String.to_integer(index)

    case World.snapshot().pos do
      nil ->
        {:noreply, assign(socket, notice: "não estou lendo tua posição", notice_kind: :warn)}

      {x, y, z} = pos ->
        with_route(socket, fn route ->
          {Route.move_to(route, index, pos),
           "waypoint #{index + 1} agora é #{x}, #{y} (andar #{z})"}
        end)
    end
  end

  # WHERE the pokémon is sent, as a distance from the character — "talvez até
  # uma distância do meu personagem, algo assim mais fácil de eu poder medir e
  # algo que eu possa configurar ali pela interface" (Lucas, 2026-08-11). The
  # ruler rides along in the same form: it is the unit of the two numbers above
  # it, and a distance in tiles is only as honest as the size of a tile.
  def handle_event("save_park_tiles", %{"index" => index} = params, socket) do
    index = String.to_integer(index)
    save_tile_px(params["tile_px"])

    case park_from(params) do
      nil ->
        {:noreply, assign(socket, notice: "distância inválida", notice_kind: :warn)}

      {dx, dy} = tiles ->
        with_route(socket, fn route ->
          {Route.set_park_tiles(route, index, tiles),
           "waypoint #{index + 1}: pokémon a #{dx}, #{dy} tiles de você"}
        end)
    end
  end

  def handle_event("clear_park_tiles", %{"index" => index}, socket) do
    index = String.to_integer(index)

    with_route(socket, fn route ->
      {Route.set_park_tiles(route, index, nil),
       "waypoint #{index + 1}: sem ponto próprio pro pokémon"}
    end)
  end

  # One kill spot's distance, made the hunt's answer everywhere: the spots he
  # never marked (two of five, 2026-08-11) gather the pile around HIM.
  def handle_event("park_tiles_default", %{"index" => index}, socket) do
    index = String.to_integer(index)
    waypoint = Enum.at(socket.assigns.active_route.waypoints, index)

    case park_tiles(waypoint, socket.assigns.calibration) do
      nil ->
        {:noreply, assign(socket, notice: "esse waypoint não tem ponto", notice_kind: :warn)}

      {dx, dy} ->
        Settings.put(:cavebot_park_tiles_x, dx)
        Settings.put(:cavebot_park_tiles_y, dy)

        {:noreply,
         assign(socket,
           park_default: {dx, dy},
           notice: "padrão da caçada: pokémon a #{dx}, #{dy} tiles de você",
           notice_kind: :ok
         )}
    end
  end

  # Recording lays waypoints in the order walked; a corner in the wrong place
  # used to mean walking the whole route again.
  def handle_event("move_waypoint", %{"index" => index, "dir" => dir}, socket) do
    direction = if dir == "up", do: :up, else: :down

    with_route(socket, fn route ->
      {Route.move(route, String.to_integer(index), direction), nil}
    end)
  end

  # The missing corner in the MIDDLE: stand where it should be and insert.
  def handle_event("insert_waypoint", %{"index" => index}, socket) do
    index = String.to_integer(index)

    case World.snapshot().pos do
      nil ->
        {:noreply, assign(socket, notice: "não estou lendo tua posição", notice_kind: :warn)}

      pos ->
        # the new point opens in the editor: inserting is how a custom point is
        # born, and being born is exactly when it needs its tile corrected
        socket
        |> assign(selected: index)
        |> with_route(&insert_here(&1, index, pos))
    end
  end

  # "de repente a gente não cria um botão para otimizar a rota e garantir que,
  # quando ele começa a mobar, ele realmente sempre termina" (Lucas,
  # 2026-08-11). Two passes: the middle clicks of ONE fight become one kill
  # spot, and then every kill spot gets exactly one gathering leading into it.
  # The walk itself is never touched — only what the corners MEAN.
  def handle_event("tidy_marks", _params, socket) do
    with_route(socket, &Recording.tidy/1)
  end

  def handle_event("clear_route", _params, socket) do
    with_route(socket, fn route ->
      Photos.forget(route.name)
      {Route.clear(route), "rota \"#{route.name}\" esvaziada — pode gravar de novo"}
    end)
  end

  def handle_event("delete_route", _params, socket) do
    case socket.assigns.active_route do
      nil ->
        {:noreply, socket}

      %Route{name: name} ->
        Photos.forget(name)
        :ok = Store.delete(name)

        {:noreply,
         socket
         |> assign(notice: "rota \"#{name}\" apagada", notice_kind: :ok, selected: nil)
         |> reload_routes(nil)}
    end
  end

  # The one-click fix for the warning above: whatever the toggle happens to
  # show, THIS is the route the hunt will walk from now on. With two routes
  # armed the toggle is ambiguous — clicking it on the one he wants would turn
  # it OFF — so the warning carries its own cure.
  def handle_event("arm_route", _params, socket) do
    case socket.assigns.active_route do
      nil ->
        {:noreply, socket}

      %Route{} = route ->
        :ok = Store.set_enabled(route.name, true)

        {:noreply,
         socket
         |> assign(
           notice: "\"#{route.name}\" é a rota armada — as outras foram desligadas",
           notice_kind: :ok
         )
         |> reload_routes(route.name)}
    end
  end

  # Through Store.set_enabled/2, NEVER through a whole-route write: arming is
  # exclusive (one route is what the hunt walks) and that rule lives in the
  # Store, where it cannot be bypassed by a page that forgot about it.
  def handle_event("toggle_route_enabled", _params, socket) do
    case socket.assigns.active_route do
      nil ->
        {:noreply, socket}

      %Route{} = route ->
        :ok = Store.set_enabled(route.name, !route.enabled?)

        notice =
          if route.enabled?,
            do: "\"#{route.name}\" desligada — nenhuma rota armada",
            else: "\"#{route.name}\" é a rota armada — as outras foram desligadas"

        {:noreply,
         socket
         |> assign(notice: notice, notice_kind: :ok)
         |> reload_routes(route.name)}
    end
  end

  def handle_event("retake_photo", %{"kind" => kind}, socket) do
    kind = if kind == "start", do: :start, else: :finish

    case socket.assigns.active_route do
      nil ->
        {:noreply, socket}

      %Route{name: name} ->
        Photos.take(name, kind)

        {:noreply,
         assign(socket,
           notice: "foto do #{if kind == :start, do: "início", else: "fim"} atualizada",
           notice_kind: :ok
         )}
    end
  end

  def handle_event("delete_waypoint", %{"index" => index}, socket) do
    case socket.assigns.active_route do
      nil ->
        {:noreply, socket}

      %Route{} = route ->
        waypoints = List.delete_at(route.waypoints, String.to_integer(index))
        # an emptied route loses its floor too, so the next recording can
        # start on whatever floor Lucas is actually standing on
        updated = %{route | waypoints: waypoints, z: if(waypoints == [], do: nil, else: route.z)}
        :ok = Store.add(updated)
        {:noreply, socket |> assign(notice: nil) |> reload_routes(updated.name)}
    end
  end

  def handle_event("create_route", params, socket) do
    name = params |> Map.get("name", "") |> String.trim()
    dungeon = params |> Map.get("dungeon", "") |> String.trim()
    dungeon = if dungeon == "", do: nil, else: dungeon

    cond do
      name == "" ->
        {:noreply,
         assign(socket, notice: "dá um nome pra rota antes de criar", notice_kind: :warn)}

      Enum.any?(socket.assigns.routes, &(&1.name == name)) ->
        # Store.add replaces by name — creating over an existing route would
        # silently wipe its waypoints, so we just select it instead
        {:noreply,
         socket
         |> assign(notice: "já existe uma rota \"#{name}\" — selecionei ela", notice_kind: :warn)
         |> reload_routes(name)}

      true ->
        :ok = Store.add(Route.new(name, dungeon))
        {:noreply, socket |> assign(notice: nil) |> reload_routes(name)}
    end
  end

  def handle_event("select_route", %{"name" => name}, socket) do
    {:noreply, socket |> assign(notice: nil) |> reload_routes(name)}
  end

  # He marked the spot with his own hand: the waypoint under him becomes the
  # kill spot, and the point he clicked is where the pokémon will be parked
  # when the hunt runs this route.
  # Same shape as the middle click below: the spot is where he STANDS when he
  # says so, so a waypoint is laid first if there is none here yet.
  defp mark_fight_here(socket) do
    socket = waypoint_here(socket)
    route = socket.assigns.active_route
    index = length(route.waypoints) - 1

    if index >= 0 do
      {updated, note} =
        Recording.mark_fight_start(route, index, hand_marked: socket.assigns.hand_marked)

      :ok = Store.add(updated)

      socket
      |> then(&if note, do: assign(&1, notice: note, notice_kind: :ok), else: &1)
      |> reload_routes(updated.name)
    else
      socket
    end
  end

  # …and shift+3 says the other half: from here on he is gathering again. On
  # the spot he just closed it says nothing (see Recording.mark_gathering_start/3).
  defp mark_gathering_here(socket) do
    socket = waypoint_here(socket)
    route = socket.assigns.active_route
    index = length(route.waypoints) - 1

    with true <- index >= 0,
         {updated, note} when is_binary(note) <- Recording.mark_gathering_start(route, index) do
      :ok = Store.add(updated)

      socket
      |> remember_hand_mark(index)
      |> assign(notice: note, notice_kind: :ok)
      |> reload_routes(updated.name)
    else
      _nothing_to_say -> socket
    end
  end

  defp waypoint_here(socket) do
    route = socket.assigns.active_route
    pos = socket.assigns.pos

    if pos && !last_waypoint_at?(route, pos),
      do: record_waypoint(socket, route, pos),
      else: socket
  end

  defp mark_park_here(socket, point) do
    socket = waypoint_here(socket)
    route = socket.assigns.active_route
    index = length(route.waypoints) - 1

    if index >= 0 do
      {updated, note} =
        Recording.mark_park(route, index, point, hand_marked: socket.assigns.hand_marked)

      :ok = Store.add(updated)

      socket
      |> then(&if note, do: assign(&1, notice: note, notice_kind: :ok), else: &1)
      |> reload_routes(updated.name)
    else
      socket
    end
  end

  # The photos are a SIDE EFFECT of recording, never a gate on it: a failed
  # screenshot must not cost a waypoint. The game is brought forward for the
  # shot exactly like the calibration does, then the browser comes back.
  defp photo(%{assigns: %{active_route: %Route{name: name}}}, kind) do
    Task.start(fn -> Photos.take(name, kind) end)
  end

  defp photo(_no_route, _kind), do: :ok

  defp insert_here(route, index, pos) do
    {:ok, updated} = Route.insert_at(route, index, pos, at: DateTime.utc_now())
    {updated, "waypoint inserido na posição #{index + 1}"}
  end

  # A blank or unreadable field keeps what the waypoint already had, so
  # correcting only the x never wipes the floor.
  defp place_from(params, %{x: x, y: y, z: z}) do
    with {:ok, nx} <- coord(params["x"], x),
         {:ok, ny} <- coord(params["y"], y),
         {:ok, nz} <- coord(params["z"], z) do
      {nx, ny, nz}
    else
      _invalid -> nil
    end
  end

  defp place_from(_params, _absent), do: nil

  defp park_from(params) do
    with {:ok, dx} <- coord(params["park_x"], nil),
         {:ok, dy} <- coord(params["park_y"], nil),
         true <- is_integer(dx) and is_integer(dy) do
      {dx, dy}
    else
      _invalid -> nil
    end
  end

  # The ruler is saved only when it is a number AND actually different: a blank
  # field means "leave it alone", never "the tile is zero pixels".
  defp save_tile_px(value) do
    case Integer.parse(to_string(value)) do
      {px, ""} when px > 0 -> Settings.put(:tile_px, px)
      _blank_or_garbage -> :ok
    end
  end

  # What the form shows: the waypoint's own distance, or his recorded click
  # converted into one (a click IS a distance from the character — it was just
  # written down in the window's coordinates).
  defp park_tiles(%{park_tiles: {_dx, _dy} = tiles}, _calib), do: tiles

  defp park_tiles(%{park_point: {_x, _y} = point}, %Calibration{} = calib),
    do: Calibration.tile_offset(calib, point)

  defp park_tiles(_waypoint, _calib), do: nil

  defp park_screen_point(tiles, %Calibration{} = calib), do: Calibration.tile_point(calib, tiles)
  defp park_screen_point(_tiles, _uncalibrated), do: nil

  defp park_fields(waypoint, calib) do
    {dx, dy} = park_tiles(waypoint, calib) || {0, 0}
    [{"park_x", "→", dx}, {"park_y", "↓", dy}]
  end

  # One line that says what will actually happen here, in his words: where the
  # click lands, or which answer is being used when the waypoint has none.
  defp park_hint(waypoint, calib, default) do
    case {park_tiles(waypoint, calib), default} do
      {nil, {0, 0}} ->
        "sem ponto: o bolo se junta em cima de você"

      {nil, {dx, dy}} ->
        "sem ponto próprio — uso o padrão da caçada: #{dx}, #{dy} tiles"

      {tiles, _default} ->
        case park_screen_point(tiles, calib) do
          {x, y} -> "clique do meio em #{x}, #{y} na tela"
          nil -> "falta calibrar onde você aparece na tela"
        end
    end
  end

  defp loaded_calibration do
    case Calibration.load() do
      {:ok, calib} -> calib
      _uncalibrated -> nil
    end
  end

  defp coord(value, fallback) do
    case Integer.parse(to_string(value)) do
      {number, ""} -> {:ok, number}
      _blank_or_garbage -> if value in [nil, ""], do: {:ok, fallback}, else: :error
    end
  end

  # Every edit is the same three steps: take the active route, write it, show
  # what happened.
  defp with_route(socket, edit) do
    case socket.assigns.active_route do
      nil ->
        {:noreply, socket}

      %Route{} = route ->
        {updated, notice} = edit.(route)
        :ok = Store.add(updated)

        {:noreply,
         socket
         |> assign(notice: notice, notice_kind: :ok)
         |> reload_routes(updated.name)}
    end
  end

  defp reload_routes(socket, active_name) do
    routes = Store.all()
    active = Enum.find(routes, &(&1.name == active_name)) || default_active(routes)
    assign(socket, routes: routes, active_route: active)
  end

  # -- what the world strip reads ---------------------------------------------

  defp enemy_count(%{enemies: enemies}), do: length(enemies)
  defp enemy_count(_none), do: 0

  defp hunt_state_text(nil), do: "parada"
  defp hunt_state_text(%{luring?: true}), do: "mobando"
  defp hunt_state_text(%{state: state}), do: state_word(state)

  defp state_word(:walking), do: "andando"
  defp state_word(:fighting), do: "lutando"
  defp state_word(:post_fight), do: "pós-luta"
  defp state_word(:stuck), do: "presa"
  defp state_word(:fight_stalled), do: "luta travada"
  defp state_word(:blocked), do: "bloqueada"
  defp state_word(other), do: to_string(other)

  defp hunt_tone(nil), do: :neutral
  defp hunt_tone(%{state: state}) when state in [:blocked, :stuck], do: :danger
  defp hunt_tone(%{state: :walking}), do: :ok
  defp hunt_tone(_other), do: :warn

  defp route_tiles(nil), do: 0
  defp route_tiles(%Route{waypoints: waypoints}), do: CavebotMap.total_tiles(waypoints)

  # The first waypoint's "previous" is the LAST one: the hunt loops back to it,
  # so that leg is real — but shown like the others it reads as a bug. Only its
  # label differs, and only a loop worth closing (3+ corners) gets one.
  defp leg_tiles(waypoints, 0) when length(waypoints) > 2,
    do: CavebotMap.tiles_between(List.last(waypoints), hd(waypoints))

  defp leg_tiles(_waypoints, 0), do: nil

  defp leg_tiles(waypoints, index) do
    CavebotMap.tiles_between(Enum.at(waypoints, index - 1), Enum.at(waypoints, index))
  end

  defp leg_label(0), do: "· fecha o ciclo:"
  defp leg_label(_index), do: "·"

  # The selected waypoint as a ONE-ELEMENT list, so the detail pane can bind
  # `wp` and `index` with `:for` — HEEx has no way to name a value inline, and
  # an empty list is exactly "nothing selected".
  defp selected_pair(%Route{waypoints: waypoints}, index) when is_integer(index) do
    case Enum.at(waypoints, index) do
      nil -> []
      wp -> [{wp, index}]
    end
  end

  defp selected_pair(_route, _none), do: []

  # A mark he made HIMSELF outranks anything the clock infers: the recorder
  # assists, it does not overrule.
  defp remember_hand_mark(socket, index) do
    update(socket, :hand_marked, &Enum.uniq([index | &1]))
  end

  # What the hunt does at a waypoint once the fighting stops. The atoms are the
  # domain's (`Route.stop/0`); only these words are Portuguese.
  defp decode_stop("cooldown_revive"), do: :cooldown_revive
  defp decode_stop("wait"), do: :wait
  defp decode_stop(_sweep), do: :sweep

  defp stop_label(:sweep), do: "varrer"
  defp stop_label(:cooldown_revive), do: "resetar cooldown"
  defp stop_label(:wait), do: "esperar"

  defp stop_icon(:sweep), do: "🧹"
  defp stop_icon(:cooldown_revive), do: "⚡"
  defp stop_icon(:wait), do: "⏱"

  defp stop_hint(:sweep), do: "depois da luta aqui, varre o chão atrás de corpos antes de andar"

  defp stop_hint(:cooldown_revive),
    do: "guarda e revive o pokémon (Q → Shift+Q na foto → Q): zera todos os cooldowns"

  defp stop_hint(:wait),
    do:
      "fica parado #{div(Pokex.Settings.get(:cavebot_stop_wait_ms), 1000)}s pra recuperar cooldown"

  # What the recording learned from his hands at this waypoint, in one line:
  # where he parked the pokémon, how long he let the pile close in, how long
  # the kill took, and the combo he used (as INTENT — the mashing on cooldown
  # is not a decision).
  # The RUNNING fight's answer when there is one — that is the proof the profile
  # is being obeyed. Falling back to the configuration keeps the page useful
  # with the bot stopped, and the badge beside it says which one he is reading.
  defp fighting_as(%{loadout: %{} = live}), do: live
  defp fighting_as(_no_running_fight), do: configured_loadout()

  defp configured_loadout do
    case Loadout.current() do
      nil ->
        nil

      loadout ->
        %{
          name: loadout.name,
          opening: Combat.Strategy.opening(loadout),
          reserved: Combat.Strategy.reserved(loadout),
          buffs: loadout.buffs,
          heal: loadout.heal
        }
    end
  end

  defp keys_line([]), do: "—"
  defp keys_line(keys), do: Enum.join(keys, " ")

  defp taught_label(wp) do
    [park_part(wp), gather_part(wp), fight_part(wp), combo_part(wp)]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end

  # A distance says something a screen point cannot: "6, -2" is six tiles right
  # and two up, which he can picture. The raw point is still shown when it is
  # all the waypoint has and there is no calibration to read it through.
  defp park_part(%{park_tiles: {dx, dy}}), do: "🖱️ #{dx}, #{dy} tiles"
  defp park_part(%{park_point: {x, y}}), do: "🖱️ #{x}, #{y}"
  defp park_part(_none), do: nil

  defp gather_part(%{gather_ms: ms}) when is_integer(ms), do: "bolo #{seconds(ms)}"
  defp gather_part(_none), do: nil

  defp fight_part(%{fight_ms: ms}) when is_integer(ms), do: "luta #{seconds(ms)}"
  defp fight_part(_none), do: nil

  defp combo_part(%{combo: [_ | _] = combo}),
    do: "💥 " <> Enum.join(Recording.combo_intent(combo), " ")

  defp combo_part(_none), do: nil

  defp seconds(ms), do: "#{Float.round(ms / 1000, 1)}s"

  # Only a stop worth mentioning: every waypoint has SOME dwell, and printing
  # "0s" on each of forty of them is noise, not information.
  defp dwell_label(%{dwell_ms: ms}) when is_integer(ms) and ms >= 1_000,
    do: "⏱ #{round(ms / 1000)}s parado"

  defp dwell_label(_passing_through), do: nil

  # His clock, not the server's: waypoints are stored in UTC (unambiguous on
  # disk) and read in the machine's own time, which is the only one he can
  # compare with his memory of the session. Computed from the OS rather than
  # from a timezone database this project does not carry.
  defp clock_label(%DateTime{} = at) do
    at |> DateTime.add(local_offset_seconds(), :second) |> Calendar.strftime("%H:%M")
  end

  defp local_offset_seconds do
    NaiveDateTime.diff(NaiveDateTime.local_now(), DateTime.to_naive(DateTime.utc_now()))
  end

  # "⇅ andar 6" on the waypoint the hunt ARRIVES at from another floor — the
  # stairs, in the list, where they can be reordered and deleted like anything
  # else.
  defp climb_label(waypoints, index) do
    previous = Integer.mod(index - 1, max(length(waypoints), 1))

    case Route.floor_change(waypoints, previous) do
      nil -> nil
      floor -> "⇅ andar #{floor}"
    end
  end

  # The route the HUNT will walk: the armed one, which is exactly one since
  # arming became exclusive (Store.set_enabled/2).
  defp armed_route(routes), do: Enum.find(routes, & &1.enabled?)

  # …and its name when it is NOT the one on screen — the silence that cost a
  # live run.
  defp armed_elsewhere(routes, active) do
    case armed_route(routes) do
      nil -> nil
      %Route{name: name} -> if active && active.name == name, do: nil, else: name
    end
  end

  # Which floor the drawing is drawn FROM: where the character stands, or the
  # route's own first floor while the position is unknown. Everything on
  # another floor is drawn faded — a flat picture puts the floors on top of
  # each other otherwise, and "achei que tivesse funcionando" is what that
  # costs (Lucas, 2026-08-11).
  defp map_floor(_route, {_x, _y, z}), do: z
  defp map_floor(%Route{z: z}, _no_pos), do: z
  defp map_floor(_no_route, _no_pos), do: nil

  # A route may climb: say how many floors it touches, because "andar 7" on a
  # two-floor hunt is a lie the drawing cannot correct on its own.
  defp floors_label(%Route{} = route) do
    case Route.floors(route) do
      [one] -> "andar #{one}"
      many -> "andares #{Enum.join(many, " e ")}"
    end
  end

  # The jobs a waypoint can carry, in the order the editor offers them. The
  # atoms are the domain's (`Route.action`); only the labels are Portuguese.
  @waypoint_actions [
    {:walk, "andar", "hero-arrow-long-right"},
    {:lure_start, "mobar daqui", "hero-play"},
    {:lure_end, "até aqui", "hero-stop"}
  ]

  defp waypoint_actions, do: @waypoint_actions

  defp decode_action("lure_start"), do: :lure_start
  defp decode_action("lure_end"), do: :lure_end
  defp decode_action(_walk), do: :walk

  defp action_label(action) do
    Enum.find_value(@waypoint_actions, "andar", fn {a, label, _icon} -> a == action && label end)
  end

  # A stretch marked "mobar daqui" and never closed does not fail loudly — it
  # lures the WHOLE loop, which reads as "the hunt stopped fighting". Say it
  # where the marks are made.
  defp lure_warning(%Route{} = route) do
    case Route.lure_issue(route) do
      :start_without_end -> "tem \"mobar daqui\" sem \"até aqui\" — o mob vale a rota inteira"
      nil -> nil
    end
  end

  defp lure_warning(_no_route), do: nil

  defp default_active(routes), do: Enum.find(routes, & &1.enabled?)

  # The coordinate and the read health come from `PositionReadout`: the SAME
  # words here, on the panel and on /world. Three pages showing the position
  # in three different phrasings was the recipe for trusting none of them.
  defp pos_text(pos), do: PositionReadout.coords(pos)
  defp read_health(reads, misses), do: PositionReadout.read_health(reads, misses)

  # The position read needs the minimap rect (the feed's capture) and the
  # coordinate strip. Both resolve hand-mark first, layout as fallback — and a
  # layout from another screen was already dropped at Calibration.load. When
  # this gap is real, the whole page is dead weight: say it, with the way out.
  defp minimap_gap? do
    case Calibration.load() do
      {:ok, calib} ->
        Calibration.minimap_region(calib) == nil or
          Calibration.minimap_coord_region(calib) == nil

      _no_calibration ->
        true
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- The widest page in the app, deliberately: this one holds a MAP of a
          55-tile route beside a list of 45 corners, and on the default
          `max-w-3xl` the drawing got 350px — six pixels per tile — while an
          ultrawide screen sat empty around it. Same rule as the dashboard:
          narrow where a phone would need it, wide where there is room. --%>
    <Layouts.app
      flash={@flash}
      current_page={:cavebot}
      max_width="max-w-[560px] xl:max-w-[1600px]"
      {Layouts.header(assigns)}
    >
      <div class="space-y-4">
        <header class="flex flex-wrap items-end justify-between gap-2">
          <div>
            <h1 class="text-pk-title font-bold text-pk-text">Central da caçada</h1>
            <p class="mt-0.5 text-pk-body text-pk-text-2">
              Grave a rota andando, veja o mundo como o bot vê, e conserte os cantos aqui mesmo.
            </p>
          </div>
          <p class="font-mono text-pk-meta text-pk-text-3">
            {length(@routes)} rota(s) · {(@active_route && length(@active_route.waypoints)) || 0} waypoints · {route_tiles(
              @active_route
            )} tiles
          </p>
        </header>

        <section
          :if={@minimap_gap?}
          id="cavebot-minimap-gap"
          class="rounded-lg border border-pk-warn-line bg-pk-warn-dim p-4"
        >
          <p class="flex items-center gap-2 text-pk-body font-bold text-pk-warn">
            <.icon name="hero-map" class="size-4" /> O minimapa não está calibrado nesta tela
          </p>
          <p class="mt-1 text-pk-body text-pk-text-2">
            Sem ele a posição não pode ser lida — nada de gravar rota nem de andar.
            Refaça o passo <strong>Posição & minimapa</strong>
            na <.link navigate={~p"/calibration"} class="underline">Calibração</.link>
            e volte aqui.
          </p>
        </section>

        <%!-- WHO the fight is fighting as. He classifies each pokémon's keys on
              /time and the hunt page said nothing about it: "sinto falta dele
              falar ali qual pokémon que eu tô usando (…) pra eu saber que os
              combos que ele tá me mostrando ali na caçada são de acordo com
              aquele meu pokémon" (2026-08-12).

              LIVE when the fight is running (that is the proof it is being
              obeyed), the CONFIGURATION otherwise, and it says which. --%>
        <section
          id="cavebot-loadout"
          class="rounded-lg border border-pk-line bg-pk-surface p-3"
        >
          <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
            <span class="font-mono text-pk-meta uppercase tracking-[0.12em] text-pk-text-3">
              lutando como
            </span>

            <span :if={fighting_as(@combat)} class="text-pk-body font-bold">
              {fighting_as(@combat).name}
            </span>
            <.link
              :if={is_nil(fighting_as(@combat))}
              navigate={~p"/time"}
              class="text-pk-body font-bold text-pk-warn hover:underline"
            >
              ninguém escolhido — escolhe no /time
            </.link>

            <span
              :if={@combat && @combat[:loadout]}
              class="rounded bg-pk-ok-dim px-1.5 py-0.5 font-mono text-pk-meta text-pk-ok"
              title="veio da luta que está rodando agora"
            >
              ao vivo
            </span>
            <span
              :if={fighting_as(@combat) && is_nil(@combat && @combat[:loadout])}
              class="rounded bg-pk-raised px-1.5 py-0.5 font-mono text-pk-meta text-pk-text-3"
              title="a luta não está rodando — isto é o que está configurado"
            >
              configurado
            </span>

            <.link navigate={~p"/time"} class="ml-auto text-pk-meta text-pk-info hover:underline">
              mudar no /time
            </.link>
          </div>

          <p :if={fighting_as(@combat)} class="mt-1.5 flex flex-wrap gap-x-3 font-mono text-pk-meta">
            <span class="text-pk-ok">
              💥 abre com {keys_line(fighting_as(@combat).opening)}
            </span>
            <span :if={fighting_as(@combat).buffs != []} class="text-pk-text-2">
              ✨ aura {keys_line(fighting_as(@combat).buffs)}
            </span>
            <span :if={fighting_as(@combat).heal != []} class="text-pk-text-2">
              ❤️ cura {keys_line(fighting_as(@combat).heal)}
            </span>
            <span :if={fighting_as(@combat).reserved != []} class="text-pk-warn">
              🌀 guarda {keys_line(fighting_as(@combat).reserved)} pro revive
            </span>
          </p>

          <p
            :if={fighting_as(@combat) && fighting_as(@combat).opening == []}
            class="mt-1 text-pk-meta text-pk-warn"
          >
            sem skill de área nem de alvo único classificada — a luta cai na lista fixa do
            <.link navigate={~p"/config"} class="underline">/config</.link>
          </p>

          <%!-- The proof he asked for: not what is configured, what the fight
                last actually pressed. --%>
          <p
            :if={@combat && @combat[:last_action]}
            id="cavebot-last-press"
            class="mt-1 font-mono text-pk-meta text-pk-text-3"
          >
            último aperto da luta: {@combat.last_action.text}
          </p>
        </section>

        <%!-- THE WORLD, as the bot sees it. Everything here already existed as
              facts; what was missing was a place to read them together while
              the hunt runs. --%>
        <section id="cavebot-world" class="grid grid-cols-2 gap-2 lg:grid-cols-6">
          <.world_tile
            id="tile-pos"
            icon="hero-map-pin"
            label="posição"
            value={pos_text(@pos)}
            note={PositionReadout.note(@pos, @world.pos_age_ms)}
            tone={if @pos, do: :ok, else: :warn}
          />
          <.world_tile
            id="tile-read"
            icon="hero-eye"
            label="leitura"
            value={"#{@reads}/#{@reads + @misses}"}
            note={read_health(@reads, @misses)}
            tone={if @misses > @reads, do: :warn, else: :neutral}
          />
          <.world_tile
            id="tile-enemies"
            icon="hero-bolt"
            label="inimigos"
            value={to_string(enemy_count(@world))}
            note={if @world.engaged?, do: "travado no alvo", else: "sem alvo travado"}
            tone={if enemy_count(@world) > 0, do: :warn, else: :neutral}
          />
          <.world_tile
            id="tile-hunt"
            icon="hero-flag"
            label="caçada"
            value={hunt_state_text(@hunt)}
            note={(@hunt && @hunt.hold_reason) || "solte a caçada no painel"}
            tone={hunt_tone(@hunt)}
          />
          <.world_tile
            id="tile-capture"
            icon="hero-inbox-arrow-down"
            label="captura"
            value={to_string((@hunt && @hunt[:capture_pending]) || 0)}
            note="corpos na fila"
          />
          <.world_tile
            id="tile-hp"
            icon="hero-heart"
            label="vida"
            value={if @world.me.hp_pct, do: "#{@world.me.hp_pct}%", else: "—"}
            note="do pokémon ativo"
            tone={hp_tone(@world)}
          />
        </section>

        <div class="grid items-start gap-4 lg:grid-cols-[minmax(0,1fr)_minmax(0,1.1fr)]">
          <%!-- LEFT: the drawing, what is selected, and the recorder that feeds
               them. STICKY on wide screens: the map and the waypoint's controls
               are two ends of one act, and putting a 45-row list between them
               made editing a scrolling exercise (2026-08-11). Top offset clears
               the app header. --%>
          <%!-- …and the whole column is capped at the viewport: a sticky block
               TALLER than the screen pins its top and hides its bottom, which
               would put the workbench somewhere no scroll can reach. --%>
          <div class="space-y-4 lg:sticky lg:top-14 lg:max-h-[calc(100dvh-4rem)] lg:overflow-y-auto">
            <section class="rounded-lg border border-pk-line bg-pk-surface p-4">
              <div class="flex flex-wrap items-center justify-between gap-2">
                <h2 class="font-mono text-pk-meta font-bold uppercase tracking-[0.12em] text-pk-text-3">
                  {if @active_route, do: "Mapa de #{@active_route.name}", else: "Mapa"}
                </h2>
                <span
                  :if={@active_route && @active_route.z}
                  class="font-mono text-pk-meta text-pk-text-2"
                >
                  {floors_label(@active_route)}
                </span>
              </div>

              <%!-- The drawing is a SQUARE sized by its width, so capping the
                   width in viewport heights is what keeps it from growing
                   taller than the screen on a wide monitor. --%>
              <div class="mt-3 mx-auto w-full max-w-[min(100%,60vh)]">
                <.route_map
                  floor={map_floor(@active_route, @pos)}
                  waypoints={(@active_route && @active_route.waypoints) || []}
                  pos={@pos}
                  selected={@selected}
                  recording?={@recording?}
                />
              </div>

              <div class="mt-3 flex flex-wrap items-center gap-2">
                <button
                  id="toggle-recording"
                  phx-click="toggle_recording"
                  aria-label={
                    if @recording?, do: "Parar de gravar a rota", else: "Gravar a rota andando"
                  }
                  class={[
                    "flex cursor-pointer items-center gap-2 rounded-lg px-4 py-2 text-pk-body font-bold transition",
                    if(@recording?,
                      do: "border border-pk-danger-line bg-pk-danger-dim text-pk-danger",
                      else: "border-0 bg-pk-ok text-pk-ok-dim hover:brightness-110"
                    )
                  ]}
                >
                  <.icon
                    name={if @recording?, do: "hero-stop-circle", else: "hero-play-circle"}
                    class="size-4"
                  />
                  {if @recording?, do: "Parar de gravar", else: "Gravar andando"}
                </button>
                <button
                  id="walk-test"
                  phx-click="walk_test"
                  disabled={@walk_test == :running}
                  aria-label="Testar se o personagem anda e se a posição é lida"
                  class="flex cursor-pointer items-center gap-1.5 rounded-lg border border-pk-line-strong px-3 py-2 text-pk-body text-pk-text-2 transition hover:border-pk-ok hover:text-pk-text disabled:cursor-not-allowed disabled:opacity-50"
                >
                  <.icon name="hero-beaker" class="size-4" />
                  {if @walk_test == :running, do: "andando…", else: "Testar movimento"}
                </button>
                <button
                  id="mark-waypoint"
                  phx-click="mark_waypoint"
                  aria-label="Marcar um waypoint só, na posição atual"
                  class="cursor-pointer rounded-lg border border-pk-line-strong px-3 py-2 text-pk-body text-pk-text-2 transition hover:border-pk-ok hover:text-pk-text"
                >
                  Marcar um só
                </button>
                <span :if={@recording?} class="font-mono text-pk-meta text-pk-warn">
                  gravando — volte pro jogo e ande
                </span>
              </div>

              <p
                :if={@walk_test not in [nil, :running]}
                id="walk-test-result"
                class={[
                  "mt-3 font-mono text-pk-meta",
                  if(match?({:ok, _}, @walk_test), do: "text-pk-ok", else: "text-pk-warn")
                ]}
              >
                {walk_test_text(@walk_test)}
              </p>

              <%!-- The route being EDITED and the route the hunt WALKS are two
                    different things, and believing they were the same cost a
                    live run: two routes armed, the hunt took the other one and
                    blocked on the first step (2026-08-11). --%>
              <p
                :if={armed_elsewhere(@routes, @active_route)}
                id="armed-elsewhere"
                class="mt-3 flex items-start gap-1.5 rounded-lg border border-pk-warn-line bg-pk-warn-dim px-3 py-2 text-pk-body text-pk-warn"
              >
                <.icon name="hero-exclamation-triangle" class="mt-0.5 size-4 shrink-0" />
                <span class="min-w-0 flex-1">
                  a caçada vai andar "{armed_elsewhere(@routes, @active_route)}", não esta.
                </span>
                <button
                  id="arm-this-route"
                  phx-click="arm_route"
                  aria-label={"Armar a rota #{@active_route.name} para a caçada"}
                  class="shrink-0 cursor-pointer rounded border border-pk-warn px-2 py-0.5 font-mono text-pk-meta font-bold text-pk-warn transition hover:bg-pk-warn hover:text-pk-bg"
                >
                  armar esta
                </button>
              </p>

              <p
                :if={@routes != [] and armed_route(@routes) == nil}
                id="none-armed"
                class="mt-3 flex items-start gap-1.5 rounded-lg border border-pk-warn-line bg-pk-warn-dim px-3 py-2 text-pk-body text-pk-warn"
              >
                <.icon name="hero-exclamation-triangle" class="mt-0.5 size-4 shrink-0" />
                nenhuma rota armada — a caçada não tem o que andar
              </p>

              <p
                :if={@notice}
                id="cavebot-notice"
                class={[
                  "mt-3 font-mono text-pk-meta",
                  if(@notice_kind == :ok, do: "text-pk-ok", else: "text-pk-warn")
                ]}
              >
                {@notice}
              </p>
            </section>

            <%!-- The DETAIL of what is selected, pinned beside the drawing.
                 Editing used to mean scrolling: the map at the top, the
                 waypoint's controls at the bottom of a 45-row list, and no way
                 to see both at once ("tenho que ficar scrollando pra cima e pra
                 baixo pra saber o que estou editando", Lucas, 2026-08-11). The
                 list stays the overview; this is the workbench. --%>
            <section
              :for={{wp, index} <- selected_pair(@active_route, @selected)}
              id="waypoint-detail"
              class="rounded-lg border border-pk-warn-line bg-pk-surface p-4"
            >
              <div class="flex flex-wrap items-baseline justify-between gap-2">
                <h2 class="font-mono text-pk-meta font-bold uppercase tracking-[0.12em] text-pk-warn">
                  editando o waypoint {index + 1}
                </h2>
                <span class="pk-num font-mono text-pk-body text-pk-text">
                  {wp.x}, {wp.y} <span class="text-pk-text-3">· andar {wp.z}</span>
                </span>
                <button
                  id="waypoint-detail-close"
                  phx-click="select_waypoint"
                  phx-value-index={index}
                  aria-label="Fechar o editor deste waypoint"
                  class="cursor-pointer font-mono text-pk-meta text-pk-text-2 transition hover:text-pk-text"
                >
                  fechar
                </button>
              </div>
              <%!-- The job lives on the SELECTED waypoint only: fourteen rows
                     each carrying three more buttons is a wall, and the choice
                     is rare — you mark a mob stretch once and hunt it for
                     weeks. --%>
              <%!-- The exact tile, typed. A recording is a walk, and a walk
                     rounds: the staircase he could not take was one tile
                     wide and the waypoint sat beside it, with no way to say
                     so except walking the whole route again (2026-08-11). --%>
              <form
                id={"waypoint-place-#{index}"}
                phx-submit="move_waypoint_to"
                class="mt-2 flex flex-wrap items-center gap-1.5 border-t border-pk-warn-line pt-2"
              >
                <input type="hidden" name="index" value={index} />
                <span class="mr-1 font-mono text-pk-meta uppercase tracking-[0.1em] text-pk-text-3">
                  lugar
                </span>
                <label
                  :for={{field, value} <- [{"x", wp.x}, {"y", wp.y}, {"z", wp.z}]}
                  class="flex items-center gap-1 font-mono text-pk-meta text-pk-text-3"
                >
                  {field}
                  <input
                    type="number"
                    name={field}
                    value={value}
                    class="pk-num h-8 w-20 rounded border border-pk-line-strong bg-pk-sunken px-1 text-center font-mono text-pk-body text-pk-text focus:border-pk-ok focus:outline-none"
                  />
                </label>
                <button
                  id={"waypoint-place-save-#{index}"}
                  class="h-8 cursor-pointer rounded-lg border border-pk-line-strong px-2.5 font-mono text-pk-meta font-bold text-pk-text-2 transition hover:border-pk-ok/60 hover:text-white"
                >
                  corrigir
                </button>
                <button
                  :if={@pos}
                  type="button"
                  id={"waypoint-place-here-#{index}"}
                  phx-click="move_waypoint_here"
                  phx-value-index={index}
                  title="usar a posição onde eu estou agora"
                  class="h-8 cursor-pointer rounded-lg border border-pk-line-strong px-2.5 font-mono text-pk-meta text-pk-text-2 transition hover:border-pk-ok/60 hover:text-white"
                >
                  é aqui que eu estou
                </button>
              </form>

              <div
                id={"waypoint-job-#{index}"}
                class="mt-2 flex flex-wrap items-center gap-1.5 border-t border-pk-warn-line pt-2"
              >
                <span class="mr-1 font-mono text-pk-meta uppercase tracking-[0.1em] text-pk-text-3">
                  função
                </span>
                <button
                  :for={{action, label, icon} <- waypoint_actions()}
                  id={"waypoint-#{index}-#{action}"}
                  phx-click="set_waypoint_action"
                  phx-value-index={index}
                  phx-value-action={action}
                  aria-pressed={to_string(wp.action == action)}
                  aria-label={"Waypoint #{index + 1}: #{label}"}
                  class={[
                    "flex h-8 cursor-pointer items-center gap-1 rounded-lg border px-2 font-mono text-pk-meta transition",
                    if(wp.action == action,
                      do: "border-pk-info bg-pk-info-dim text-pk-info",
                      else:
                        "border-pk-line-strong text-pk-text-2 hover:border-pk-info/60 hover:text-pk-text"
                    )
                  ]}
                >
                  <.icon name={icon} class="size-3.5" />{label}
                </button>

                <span class="mx-1 h-5 w-px bg-pk-warn-line"></span>

                <button
                  :for={stop <- Route.stops()}
                  id={"waypoint-#{index}-#{stop}"}
                  phx-click="toggle_waypoint_stop"
                  phx-value-index={index}
                  phx-value-stop={stop}
                  aria-pressed={to_string(stop in wp.stops)}
                  aria-label={"Waypoint #{index + 1}: #{stop_label(stop)} depois da luta"}
                  title={stop_hint(stop)}
                  class={[
                    "flex h-8 cursor-pointer items-center gap-1 rounded-lg border px-2 font-mono text-pk-meta transition",
                    if(stop in wp.stops,
                      do: "border-pk-ok bg-pk-ok-dim text-pk-ok",
                      else:
                        "border-pk-line-strong text-pk-text-2 hover:border-pk-ok/60 hover:text-pk-text"
                    )
                  ]}
                >
                  {stop_icon(stop)} {stop_label(stop)}
                </button>
              </div>

              <%!-- WHERE the pokémon waits for the pile. Recorded as a screen
                     point from his own middle click, said here as a DISTANCE
                     from the character: the form he can measure by eye, and
                     the only one that survives the game window moving. The
                     ruler rides in the same form because it is the unit of the
                     two numbers beside it. --%>
              <form
                id={"waypoint-park-#{index}"}
                phx-submit="save_park_tiles"
                class="mt-2 flex flex-wrap items-center gap-1.5 border-t border-pk-warn-line pt-2"
              >
                <input type="hidden" name="index" value={index} />
                <span class="mr-1 font-mono text-pk-meta uppercase tracking-[0.1em] text-pk-text-3">
                  pokémon
                </span>
                <label
                  :for={{field, label, value} <- park_fields(wp, @calibration)}
                  class="flex items-center gap-1 font-mono text-pk-meta text-pk-text-3"
                >
                  {label}
                  <input
                    type="number"
                    name={field}
                    value={value}
                    class="pk-num h-8 w-16 rounded border border-pk-line-strong bg-pk-sunken px-1 text-center font-mono text-pk-body text-pk-text focus:border-pk-ok focus:outline-none"
                  />
                </label>
                <span class="font-mono text-pk-meta text-pk-text-3">tiles de você</span>
                <label
                  class="flex items-center gap-1 font-mono text-pk-meta text-pk-text-3"
                  title="quantos pixels da tela tem um tile — a régua dessa distância"
                >
                  1 tile =
                  <input
                    type="number"
                    name="tile_px"
                    value={@tile_px}
                    class="pk-num h-8 w-16 rounded border border-pk-line-strong bg-pk-sunken px-1 text-center font-mono text-pk-body text-pk-text focus:border-pk-ok focus:outline-none"
                  /> px
                </label>
                <button
                  id={"waypoint-park-save-#{index}"}
                  class="h-8 cursor-pointer rounded-lg border border-pk-line-strong px-2.5 font-mono text-pk-meta font-bold text-pk-text-2 transition hover:border-pk-ok/60 hover:text-white"
                >
                  guardar
                </button>
                <button
                  type="button"
                  id={"waypoint-park-default-#{index}"}
                  phx-click="park_tiles_default"
                  phx-value-index={index}
                  title="usar essa distância em todo canto de matar que não tem a sua"
                  class="h-8 cursor-pointer rounded-lg border border-pk-line-strong px-2.5 font-mono text-pk-meta text-pk-text-2 transition hover:border-pk-ok/60 hover:text-white"
                >
                  virar padrão
                </button>
                <button
                  :if={park_tiles(wp, @calibration)}
                  type="button"
                  id={"waypoint-park-clear-#{index}"}
                  phx-click="clear_park_tiles"
                  phx-value-index={index}
                  class="h-8 cursor-pointer rounded-lg border border-pk-line-strong px-2.5 font-mono text-pk-meta text-pk-text-2 transition hover:border-pk-warn/60 hover:text-white"
                >
                  tirar
                </button>
                <span
                  id={"waypoint-park-hint-#{index}"}
                  class="w-full font-mono text-pk-meta text-pk-text-3"
                >
                  {park_hint(wp, @calibration, @park_default)}
                </span>
              </form>
            </section>

            <section
              :if={@log != []}
              id="cavebot-log"
              class="rounded-lg border border-pk-line bg-pk-surface p-4"
            >
              <h2 class="font-mono text-pk-meta font-bold uppercase tracking-[0.12em] text-pk-text-3">
                O que ela acabou de fazer
              </h2>
              <ol class="mt-2 space-y-0.5">
                <li
                  :for={line <- @log}
                  class="flex gap-2 font-mono text-pk-meta text-pk-text-2"
                >
                  <span class="pk-num shrink-0 text-pk-text-3">
                    {Calendar.strftime(line.at, "%H:%M:%S")}
                  </span>
                  <span class={line.level == :macro && "text-pk-text"}>{line.text}</span>
                </li>
              </ol>
            </section>

            <section
              :if={@active_route}
              id="route-photos"
              class="rounded-lg border border-pk-line bg-pk-surface p-4"
            >
              <h2 class="font-mono text-pk-meta font-bold uppercase tracking-[0.12em] text-pk-text-3">
                Como é o lugar
              </h2>
              <div class="mt-3 flex flex-wrap gap-3">
                <.route_photo kind={:start} url={Photos.url(@active_route.name, :start)} />
                <.route_photo kind={:finish} url={Photos.url(@active_route.name, :finish)} />
              </div>
            </section>
          </div>

          <%!-- RIGHT: the routes and the waypoint editor --%>
          <div class="space-y-4">
            <section id="cavebot-routes" class="rounded-lg border border-pk-line bg-pk-surface p-4">
              <h2 class="font-mono text-pk-meta font-bold uppercase tracking-[0.12em] text-pk-text-3">
                Rotas
              </h2>

              <form
                :if={@routes != []}
                id="route-select-form"
                phx-change="select_route"
                class="mt-3 flex flex-wrap items-center gap-2"
              >
                <label for="route-select" class="font-mono text-pk-meta text-pk-text-2">
                  rota ativa
                </label>
                <select
                  id="route-select"
                  name="name"
                  aria-label="Selecionar rota ativa"
                  class="h-9 rounded border border-pk-line-strong bg-pk-sunken px-2 font-mono text-pk-body text-pk-text focus:border-pk-ok focus:outline-none"
                >
                  <option
                    :for={route <- @routes}
                    value={route.name}
                    selected={@active_route != nil and route.name == @active_route.name}
                  >
                    {route.name}{if route.dungeon, do: " · #{route.dungeon}"}
                  </option>
                </select>
                <button
                  :if={@active_route}
                  id="toggle-route-enabled"
                  type="button"
                  phx-click="toggle_route_enabled"
                  aria-label={
                    if @active_route.enabled?, do: "Desligar esta rota", else: "Ligar esta rota"
                  }
                  class={[
                    "h-9 cursor-pointer rounded-lg border px-3 font-mono text-pk-meta transition",
                    if(@active_route.enabled?,
                      do: "border-pk-ok-line bg-pk-ok-dim text-pk-ok",
                      else: "border-pk-line-strong text-pk-text-3 hover:text-pk-text"
                    )
                  ]}
                >
                  {if @active_route.enabled?, do: "ligada", else: "desligada"}
                </button>
              </form>

              <p :if={@routes == []} class="mt-3 text-pk-body text-pk-text-2">
                nenhuma rota ainda — crie a primeira e saia andando
              </p>

              <form
                id="new-route-form"
                phx-submit="create_route"
                class="mt-3 flex flex-wrap items-center gap-2"
              >
                <input
                  name="name"
                  placeholder="nome da rota"
                  autocomplete="off"
                  aria-label="Nome da nova rota"
                  class="h-9 w-40 rounded border border-pk-line-strong bg-pk-sunken px-2 font-mono text-pk-body text-pk-text focus:border-pk-ok focus:outline-none"
                />
                <input
                  name="dungeon"
                  placeholder="dungeon (opcional)"
                  autocomplete="off"
                  aria-label="Dungeon da nova rota"
                  class="h-9 w-40 rounded border border-pk-line-strong bg-pk-sunken px-2 font-mono text-pk-body text-pk-text focus:border-pk-ok focus:outline-none"
                />
                <button
                  aria-label="Criar rota"
                  class="h-9 cursor-pointer rounded-lg border border-pk-line-strong px-3 text-pk-body font-semibold text-pk-text transition hover:border-pk-ok/60 hover:text-white"
                >
                  Criar rota
                </button>
              </form>
            </section>

            <section
              :if={@active_route}
              id="cavebot-waypoints"
              class="rounded-lg border border-pk-line bg-pk-surface p-4"
            >
              <div class="flex flex-wrap items-baseline justify-between gap-2">
                <h2 class="font-mono text-pk-meta font-bold uppercase tracking-[0.12em] text-pk-text-3">
                  Waypoints
                </h2>
                <div class="flex items-center gap-3">
                  <button
                    :if={@active_route.waypoints != []}
                    id="tidy-marks"
                    phx-click="tidy_marks"
                    aria-label="Otimizar a rota: juntar marcas repetidas e fechar as mobadas"
                    title="junta os cliques de uma luta só e garante uma mobada pra cada matança"
                    class="cursor-pointer font-mono text-pk-meta text-pk-text-2 transition hover:text-pk-info"
                  >
                    otimizar rota
                  </button>
                  <button
                    :if={@active_route.waypoints != []}
                    id="clear-route"
                    phx-click="clear_route"
                    data-confirm={"Apagar TODOS os #{length(@active_route.waypoints)} waypoints de \"#{@active_route.name}\"?"}
                    aria-label="Limpar todos os waypoints desta rota"
                    class="cursor-pointer font-mono text-pk-meta text-pk-text-2 transition hover:text-pk-warn"
                  >
                    limpar
                  </button>
                  <button
                    id="delete-route"
                    phx-click="delete_route"
                    data-confirm={"Apagar a rota \"#{@active_route.name}\" inteira, com fotos?"}
                    aria-label="Apagar esta rota"
                    class="cursor-pointer font-mono text-pk-meta text-pk-text-2 transition hover:text-pk-danger"
                  >
                    apagar rota
                  </button>
                </div>
              </div>

              <p :if={@active_route.waypoints == []} class="mt-3 text-pk-body text-pk-text-2">
                nenhum waypoint ainda — ande até o primeiro canto e marque
              </p>

              <p
                :if={lure_warning(@active_route)}
                id="lure-warning"
                class="mt-3 flex items-start gap-1.5 rounded-lg border border-pk-warn-line bg-pk-warn-dim px-3 py-2 text-pk-body text-pk-warn"
              >
                <.icon name="hero-exclamation-triangle" class="mt-0.5 size-4 shrink-0" />
                {lure_warning(@active_route)}
              </p>

              <ol :if={@active_route.waypoints != []} class="mt-3 space-y-1.5">
                <li
                  :for={{wp, index} <- Enum.with_index(@active_route.waypoints)}
                  id={"waypoint-#{index}"}
                  class={[
                    "rounded-lg border px-3 py-2 transition",
                    if(@selected == index,
                      do: "border-pk-warn bg-pk-warn-dim",
                      else: "border-pk-line bg-pk-sunken hover:border-pk-line-strong"
                    )
                  ]}
                >
                  <div
                    class="flex cursor-pointer items-center gap-2"
                    phx-click="select_waypoint"
                    phx-value-index={index}
                  >
                    <span class="pk-num w-5 font-mono text-pk-meta text-pk-text-3">{index + 1}</span>
                    <span class="pk-num flex-1 font-mono text-pk-body text-pk-text">
                      {wp.x}, {wp.y}
                      <span
                        :if={wp.action != :walk}
                        class="ml-1 rounded border border-pk-info-line bg-pk-info-dim px-1.5 py-0.5 text-pk-meta text-pk-info"
                      >
                        {action_label(wp.action)}
                      </span>
                      <%!-- The floor is written only where it CHANGES: on a
                            one-floor route it would be noise on every line, and
                            on a route with stairs it is the whole story. --%>
                      <span
                        :for={stop <- wp.stops}
                        class="ml-1 rounded border border-pk-ok-line bg-pk-ok-dim px-1.5 py-0.5 text-pk-meta text-pk-ok"
                      >
                        {stop_icon(stop)} {stop_label(stop)}
                      </span>
                      <span
                        :if={climb_label(@active_route.waypoints, index)}
                        class="ml-1 rounded border border-pk-line-strong px-1.5 py-0.5 text-pk-meta text-pk-text-2"
                      >
                        {climb_label(@active_route.waypoints, index)}
                      </span>
                      <span :if={leg_tiles(@active_route.waypoints, index)} class="text-pk-text-3">
                        {leg_label(index)} {leg_tiles(@active_route.waypoints, index)} tiles
                      </span>
                      <%!-- What he was DOING here, in the only unit that says
                            it: a corner passed through vs half a minute
                            standing on one tile. --%>
                      <span :if={dwell_label(wp)} class="ml-1 text-pk-warn">
                        {dwell_label(wp)}
                      </span>
                      <span :if={wp.at} class="ml-1 text-pk-text-3">{clock_label(wp.at)}</span>
                    </span>
                    <button
                      id={"waypoint-up-#{index}"}
                      phx-click="move_waypoint"
                      phx-value-index={index}
                      phx-value-dir="up"
                      disabled={index == 0}
                      aria-label={"Mover waypoint #{index + 1} para cima"}
                      class="grid size-7 cursor-pointer place-items-center rounded text-pk-text-2 transition hover:bg-pk-raised hover:text-pk-text disabled:cursor-not-allowed disabled:opacity-30"
                    >
                      <.icon name="hero-arrow-up" class="size-3.5" />
                    </button>
                    <button
                      id={"waypoint-down-#{index}"}
                      phx-click="move_waypoint"
                      phx-value-index={index}
                      phx-value-dir="down"
                      disabled={index == length(@active_route.waypoints) - 1}
                      aria-label={"Mover waypoint #{index + 1} para baixo"}
                      class="grid size-7 cursor-pointer place-items-center rounded text-pk-text-2 transition hover:bg-pk-raised hover:text-pk-text disabled:cursor-not-allowed disabled:opacity-30"
                    >
                      <.icon name="hero-arrow-down" class="size-3.5" />
                    </button>
                    <button
                      id={"waypoint-insert-#{index}"}
                      phx-click="insert_waypoint"
                      phx-value-index={index}
                      aria-label={"Inserir a posição atual antes do waypoint #{index + 1}"}
                      title="inserir a posição atual aqui"
                      class="grid size-7 cursor-pointer place-items-center rounded text-pk-text-2 transition hover:bg-pk-raised hover:text-pk-ok"
                    >
                      <.icon name="hero-plus" class="size-3.5" />
                    </button>
                    <button
                      id={"waypoint-delete-#{index}"}
                      phx-click="delete_waypoint"
                      phx-value-index={index}
                      data-confirm={"Apagar o waypoint #{index + 1} (#{wp.x}, #{wp.y})?"}
                      aria-label={"Apagar waypoint #{index + 1}"}
                      class="grid size-7 cursor-pointer place-items-center rounded text-pk-text-2 transition hover:bg-pk-raised hover:text-pk-danger"
                    >
                      <.icon name="hero-trash" class="size-3.5" />
                    </button>
                  </div>

                  <%!-- What HE did here, learned from his own hands. Only
                        where there is something to say: forty lines of "—"
                        would bury the four that matter. --%>
                  <p
                    :if={taught_label(wp)}
                    id={"waypoint-taught-#{index}"}
                    class="mt-1 pl-7 font-mono text-pk-meta text-pk-text-3"
                  >
                    {taught_label(wp)}
                    <%!-- The keys are here; what they MEAN lives on the team
                          page. Without a way across, the two screens describe
                          the same combo and never mention each other. --%>
                    <.link
                      :if={wp[:combo] not in [nil, []]}
                      navigate={~p"/time"}
                      class="text-pk-info hover:underline"
                    >
                      o que cada tecla faz
                    </.link>
                  </p>
                </li>
              </ol>
            </section>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # Each verdict names the link that broke — that is the whole point of the
  # rehearsal, and the difference between "não anda" and a diagnosis.
  defp walk_test_text({:ok, %{from: from, to: to, tiles: tiles, presses: presses}}) do
    "andou #{tiles} tile(s): #{coord(from)} → #{coord(to)} com #{Enum.join(presses, ", ")} ✓"
  end

  defp walk_test_text({:error, :no_position}),
    do: "não testei: a coordenada não está sendo lida — sem ela eu andaria às cegas"

  defp walk_test_text({:error, :did_not_move}),
    do:
      "apertei as setas e o personagem NÃO saiu do lugar — as teclas não estão chegando no " <>
        "jogo (janela em foco? o jogo está atrás do navegador?)"

  defp walk_test_text({:error, {:refused, reason}}),
    do: "o corpo recusou o passo: #{inspect(reason)} (gate de segurança fechado)"

  defp walk_test_text({:error, {:crashed, reason}}),
    do: "o teste morreu no meio: #{inspect(reason)} — me manda esse erro"

  defp walk_test_text(other), do: "resultado inesperado: #{inspect(other)}"

  # Task.start gives no monitor and Task.async wants a supervisor: this page
  # only needs "run it, and tell me if it dies".
  defp spawn_monitor_task(fun) do
    {pid, ref} = :erlang.spawn_monitor(fun)
    {:ok, pid, ref}
  end

  defp coord({x, y, _z}), do: "#{x}, #{y}"

  defp hp_tone(%{me: %{hp_pct: pct}}) when is_integer(pct) and pct < 40, do: :warn
  defp hp_tone(_world), do: :neutral
end
