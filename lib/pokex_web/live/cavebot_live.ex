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
  alias Pokex.Bots.AreaProbe
  alias Pokex.Bots.Combat
  alias Pokex.Bots.ReviveLedger
  alias Pokex.Bots.SkillClock
  alias Pokex.Bots.SkillMeter
  alias Pokex.Bots.SkillRack
  alias Pokex.Bots.CrowdScan
  alias Pokex.Bots.Combat.Loadout
  alias Pokex.Calibration
  alias Pokex.Perception
  alias Pokex.Pokedex.SkillProfile
  alias Pokex.Settings
  alias Pokex.Sim.Fence
  alias Pokex.World
  alias PokexWeb.CavebotMap
  alias PokexWeb.PanelForms
  alias PokexWeb.PositionReadout

  # Eight lines hid the story of a whole fight ("mais linhas", 2026-08-14):
  # the card shows the first eight and scrolls for the rest, so the page reads
  # like a page and the history is still there when a stop needs explaining.
  @log_lines 40

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
      # the support speaks on "game": revives, deaths and refusals belong in the
      # hunt's own feed, not only in the panel's
      Phoenix.PubSub.subscribe(Pokex.PubSub, Pokex.Bots.PlayerSupport.Worker.topic())
      # the engine counts what is on the screen — the number the ruler of three
      # will be measured against, and which nothing recorded until now
      Phoenix.PubSub.subscribe(Pokex.PubSub, Pokex.Bots.Engine.Worker.topic())
      # the minimap feed only captures while someone is attached — the
      # recording page IS that someone, exactly while it is open.
      #
      # The battle feed is deliberately NOT attached: during a hunt the workers
      # already run it and this page reads the fact for free, while OUTSIDE a
      # hunt attaching it would capture for nothing and read the browser's own
      # pixels — which is exactly how this tile announced a SHINY that did not
      # exist the first time it was drawn (2026-08-10).
      Perception.attach(:minimap)

      # A HEARTBEAT, because every other assign on this page arrives by
      # broadcast — and the states worth warning about are exactly the ones
      # where NO broadcast comes. With the simulator's fence up the real feeds
      # are switched off by design, so the page rendered once at mount and then
      # sat there showing a coordinate from an hour earlier while he walked a
      # whole route that recorded nothing (2026-08-26). A page that can only
      # learn it is blind from the thing that went blind cannot warn about it.
      # Um segundo, não dois: a fileira da barra conta o cooldown pra trás em
      # segundos inteiros, e um pulso de dois faz o número pular de dois em
      # dois. É a mesma batida que já mantinha os avisos de cegueira vivos.
      :timer.send_interval(1_000, :health)
    end

    routes = Store.all()

    {:ok,
     socket
     |> PokexWeb.HeaderState.relay_workers()
     |> assign(
       page_title: "Cavebot",
       # Which half of the page he is on. Watching is the default because that
       # is what the page is for most of the night; editing is one click away
       # and says so in the URL, so a reload lands where he left it.
       mode: :watch,
       routes: routes,
       active_route: default_active(routes),
       pos: World.snapshot().pos,
       # what the RUNNING fight holds; nil until it says so, and then the page
       # falls back to the configuration and labels it as such
       combat: nil,
       # what the ENGINE sees and what it would order. Seeded from the facts so
       # a page opened mid-hunt is not blank until the next tick.
       situation: engine_fact(:situation),
       orders: engine_fact(:orders),
       gather_piles: Settings.get(:engine_gather_piles),
       reset_revive: Settings.get(:engine_reset_revive),
       minimap_gap?: minimap_gap?(),
       recording?: false,
       # What the last look at the SCREEN found, and nothing until he asks: the
       # scan costs a capture, so it never runs on the poll (see the button).
       crowd: nil,
       # The simulator's fence points the eyes at a world that is not the game.
       # Free to read (`:persistent_term`), and re-read on the heartbeat.
       sim_armed?: Fence.armed?(),
       # A calibração do raio da área: o modo, e o que os disparos já disseram.
       area_probe?: Settings.get(:area_probe_enabled) == true,
       area: AreaProbe.summary(),
       # Quanto cada tecla tira, e quanto demora — a calibração de checagem.
       meter?: Settings.get(:skill_meter_enabled) == true,
       meter: SkillMeter.summary(),
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
       log: seed_log(),
       show_debug: false,
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
       park_default: {Settings.get(:cavebot_park_tiles_x), Settings.get(:cavebot_park_tiles_y)},
       safety: safety_snapshot()
     )}
  end

  # The mode rides in the URL and nowhere else: `patch` swaps the half of the
  # page being drawn without remounting, so the feed, the selected corner and
  # a recording in progress all survive the switch. Anything that is not
  # "editar" is watching — a typed query string must not blank the page.
  @impl true
  def handle_params(params, _uri, socket) do
    mode = if params["modo"] == "editar", do: :edit, else: :watch
    {:noreply, assign(socket, mode: mode)}
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

  # The heartbeat: the two facts this page cannot learn from a broadcast —
  # whether the eyes are switched off, and how old the last position is.
  def handle_info(:health, socket),
    do:
      {:noreply,
       assign(socket,
         sim_armed?: Fence.armed?(),
         world: World.snapshot()
       )}

  def handle_info({:cavebot, snapshot}, socket), do: {:noreply, assign(socket, hunt: snapshot)}

  def handle_info({:combat, snapshot}, socket), do: {:noreply, assign(socket, combat: snapshot)}

  def handle_info({:engine, situation, orders}, socket),
    do: {:noreply, assign(socket, situation: situation, orders: orders)}

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
  def handle_info({:cavebot_log, level, text}, socket),
    do: {:noreply, log_line(socket, level, text)}

  def handle_info({:game_log, level, text}, socket), do: {:noreply, log_line(socket, level, text)}

  def handle_info({:engine_log, level, text}, socket),
    do: {:noreply, log_line(socket, level, text)}

  def handle_info({:rule_alarm, text}, socket), do: {:noreply, log_line(socket, :alarm, text)}

  def handle_info({:rule_alarm, _category, text}, socket),
    do: {:noreply, log_line(socket, :alarm, text)}

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

    filed = Recording.lesson_index(socket.assigns.active_route, index)

    socket
    |> write_timings(index, timings)
    |> flush_combo()
    |> then(
      &if reading.fight_ms,
        do: assign(&1, notice: fight_note(reading, index, filed), notice_kind: :ok),
        else: &1
    )
  end

  # Called when he moves on, when the fight closes, and when he stops
  # recording: a combo he pressed and never closed with shift+3 is still what
  # he pressed.
  defp flush_combo(%{assigns: %{pending_combo: []}} = socket),
    do: assign(socket, pending_index: nil)

  defp flush_combo(%{assigns: %{pending_index: index, pending_combo: combo}} = socket) do
    route = socket.assigns.active_route
    existing = Enum.at(route.waypoints, Recording.lesson_index(route, index))[:combo] || []

    socket
    |> write_timings(index, combo: existing ++ combo)
    |> assign(pending_combo: [], pending_index: nil)
  end

  defp write_timings(socket, _index, []), do: socket

  # The lesson goes to THIS fight's kill spot, not to the tile he was standing
  # on when the shift+3 closed it: he kills, takes a step, and only then closes
  # — four of the eight fights of Meganium 1 landed one waypoint past the "até
  # aqui", where the hunt does not read. (Recording.lesson_index/3.)
  defp write_timings(socket, index, timings) when is_integer(index) and index >= 0 do
    route = socket.assigns.active_route
    updated = Route.set_timing(route, Recording.lesson_index(route, index), timings)
    :ok = Store.add(updated)
    reload_routes(socket, updated.name)
  end

  defp write_timings(socket, _index, _timings), do: socket

  # "aqui" only when it really was here: the lesson may have been filed on the
  # kill spot one or two tiles back (`Recording.lesson_index/3`), and a notice
  # that says "aqui" about another waypoint is one he cannot check.
  defp fight_note(%{fight_ms: ms, combo: combo}, index, filed) do
    base = "⚔️ luta de #{round(ms / 1000)}s medida #{fight_place(index, filed)}"
    if combo == [], do: base, else: base <> " — skills #{Enum.join(combo, ", ")}"
  end

  # the waypoint numbers he reads on the page are 1-based
  defp fight_place(index, index), do: "aqui"
  defp fight_place(_index, filed), do: "e anotada no waypoint #{filed + 1}"

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

      # THE ONE REFUSAL THAT MATTERS HERE. Recording lays waypoints from minimap
      # broadcasts, and the fence switches the real feeds off — so arming this
      # with the simulator up gives him a route that records NOTHING while
      # looking exactly like one that is recording. He walked a whole route that
      # way (2026-08-26). Refusing costs a click; not refusing costs the walk.
      Fence.armed?() ->
        {:noreply,
         assign(socket,
           notice:
             "o simulador está armado — os olhos estão no mundo falso e a gravação não " <>
               "receberia nenhuma posição. Desarme no /sim e grave de novo.",
           notice_kind: :warn
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

  # What the hunt DOES at a waypoint once the fighting there stops: reset the
  # cooldowns on a revive, or simply stand still. A second axis, not more jobs
  # — the waypoint worth reviving at is usually the one already marked "até
  # aqui".
  #
  # A stop nobody knows leaves before anything is named, same reason as the
  # skill chips below: `stop_label/1` has one clause per stop and no catch-all,
  # so naming a nil in the notice would kill this LiveView over a forged click
  # that could not have changed the route anyway.
  def handle_event("toggle_waypoint_stop", %{"index" => index, "stop" => stop}, socket) do
    toggle_stop(socket, String.to_integer(index), decode_stop(stop))
  end

  # The skill HE wants at this corner, said by category — the aura in the
  # middle of the gathering is the case he asked for. Third axis, beside the
  # job and the stops: the corner of the aura is usually the corner already
  # marked "até aqui".
  #
  # A category nobody knows leaves before anything is named. It can only come
  # from a forged event — the chips emit whitelisted values and nothing else —
  # but `SkillProfile.label/1` has one clause per category and no catch-all, so
  # naming a nil in the notice would kill this LiveView over a click that could
  # not have changed the route anyway.
  def handle_event("toggle_waypoint_skill", %{"index" => index, "skill" => raw}, socket) do
    toggle_skill(socket, index, decode_skill(raw))
  end

  # The whole route's ruler: the number he dials down until he finds the limit
  # where the pile still closes. An empty field hands the command back to
  # /config.
  def handle_event("set_route_gather_wait", %{"gather_wait_ms" => raw}, socket) do
    ms = parse_ms(raw)

    with_route(socket, fn route ->
      {Route.set_gather_wait(route, ms), gather_wait_note("a rota", ms)}
    end)
  end

  def handle_event("set_waypoint_gather_wait", %{"index" => index} = params, socket) do
    index = String.to_integer(index)
    ms = parse_ms(params["gather_wait_ms"])
    socket = remember_hand_mark(socket, index)

    with_route(socket, fn route ->
      {Route.set_gather_wait(route, index, ms), gather_wait_note("o waypoint #{index + 1}", ms)}
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

  # The pre-sleep checklist, on the hunt's own page. Same settings the panel
  # flips — Settings is the one truth — and arming re-runs the idempotent
  # support monitor exactly like the panel does, so a net turned on here is a
  # net that is actually watching.
  # ONE look at the screen, because he pressed the button. Deliberately not on
  # the poll: a capture is ~0.28s serialized through the broker, and a page left
  # open would spend that every second for a number nobody is reading.
  # O MODO de calibração. Custa uma foto por disparo de área, então é coisa de
  # ligar por uma caçada e desligar — nunca um padrão.
  def handle_event("toggle_skill_meter", _params, socket) do
    on? = not socket.assigns.meter?
    Settings.put(:skill_meter_enabled, on?)
    {:noreply, assign(socket, meter?: on?, meter: SkillMeter.summary())}
  end

  def handle_event("clear_skill_meter", _params, socket) do
    SkillMeter.clear()
    {:noreply, assign(socket, meter: %{})}
  end

  def handle_event("refresh_skill_meter", _params, socket) do
    {:noreply, assign(socket, meter: SkillMeter.summary())}
  end

  def handle_event("toggle_area_probe", _params, socket) do
    on? = not socket.assigns.area_probe?
    Settings.put(:area_probe_enabled, on?)
    {:noreply, assign(socket, area_probe?: on?, area: AreaProbe.summary())}
  end

  def handle_event("clear_area_probe", _params, socket) do
    AreaProbe.clear()
    {:noreply, assign(socket, area: nil)}
  end

  def handle_event("refresh_area_probe", _params, socket) do
    {:noreply, assign(socket, area: AreaProbe.summary())}
  end

  def handle_event("crowd_scan", _params, socket) do
    reading = CrowdScan.look(listed: enemy_count(socket.assigns.world), evidence: true)
    {:noreply, assign(socket, crowd: reading)}
  end

  def handle_event("toggle_debug", _params, socket),
    do: {:noreply, assign(socket, show_debug: not socket.assigns.show_debug)}

  # Copied through the CLIENT, because the log he needs to paste is the log he
  # is LOOKING at — and a server-side clipboard does not exist.
  def handle_event("copy_log", _params, socket) do
    {:noreply,
     socket
     |> push_event("copy-to-clipboard", %{
       text: log_as_text(socket.assigns.log, socket.assigns.show_debug)
     })
     |> assign(notice: "feed copiado — pode colar no relato", notice_kind: :ok)}
  end

  # R3b lives beside the pile switch because it is the same kind of decision:
  # a rule about HOW the hunt spends its round, with no other screen to live on.
  def handle_event("toggle_reset_revive", _params, socket) do
    value = not Settings.get(:engine_reset_revive)
    Settings.put(:engine_reset_revive, value)

    {:noreply,
     assign(socket,
       reset_revive: value,
       notice: reset_revive_notice(value),
       notice_kind: if(value, do: :warn, else: :ok)
     )}
  end

  # Mobar é escolha, não natureza da caçada: contra bicho fraco que aparece de
  # um em um, esperar a pilha juntar só perde luta.
  def handle_event("toggle_gather_piles", _params, socket) do
    value = not Settings.get(:engine_gather_piles)
    Settings.put(:engine_gather_piles, value)

    {:noreply,
     assign(socket,
       gather_piles: value,
       notice: gather_notice(value),
       notice_kind: if(value, do: :ok, else: :warn)
     )}
  end

  def handle_event("toggle_safety", %{"key" => key}, socket) do
    case safety_key(key) do
      nil ->
        {:noreply, socket}

      setting ->
        value = not Settings.get(setting)
        Settings.put(setting, value)
        if value, do: arm_support()

        {:noreply,
         assign(socket,
           safety: safety_snapshot(),
           notice: safety_notice(setting, value),
           notice_kind: if(value, do: :ok, else: :warn)
         )}
    end
  end

  def handle_event("comeback_cfg", %{"retries" => retries, "wait_s" => wait_s}, socket) do
    with {:ok, retries} <- PanelForms.parse_int(retries, 0..50),
         {:ok, seconds} <- PanelForms.parse_int(wait_s, 1..600) do
      Settings.put(:cavebot_block_retries, retries)
      Settings.put(:cavebot_block_retry_ms, seconds * 1000)

      {:noreply,
       assign(socket,
         safety: safety_snapshot(),
         notice: comeback_notice(retries, seconds),
         notice_kind: :ok
       )}
    else
      :error ->
        {:noreply,
         assign(socket,
           notice: "tentativas de 0 a 50, espera de 1 a 600 segundos",
           notice_kind: :warn
         )}
    end
  end

  def handle_event("hp_guard", %{"abort" => abort, "resume" => resume}, socket) do
    with {:ok, abort} <- PanelForms.parse_int(abort, 0..100),
         {:ok, resume} <- PanelForms.parse_int(resume, 1..100) do
      Settings.put(:cavebot_hp_abort_pct, abort)
      Settings.put(:cavebot_hp_resume_pct, resume)

      {:noreply,
       assign(socket,
         safety: safety_snapshot(),
         notice: hp_guard_notice(abort, resume),
         notice_kind: :ok
       )}
    else
      :error ->
        {:noreply,
         assign(socket,
           notice: "porcentagens entre 0 e 100 — abandono 0 desliga a guarda",
           notice_kind: :warn
         )}
    end
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
        updated = %{route | waypoints: waypoints}
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

  # -- onde eles estão --------------------------------------------------------

  defp crowd_headline(%{seen: 0, radius: r}),
    do: "nenhum nome legível dentro de #{r} tiles"

  defp crowd_headline(%{seen: seen, spots: [%{tiles: near} | _]}) do
    "#{seen} #{if seen == 1, do: "monstro localizado", else: "monstros localizados"} — o mais perto a #{near} #{if near == 1, do: "tile", else: "tiles"}"
  end

  # The histogram he can check against his own screen: how many at each ring.
  defp crowd_spread(%{spots: []}), do: "—"

  defp crowd_spread(%{spots: spots}) do
    spots
    |> Enum.frequencies_by(& &1.tiles)
    |> Enum.sort()
    |> Enum.map_join("  ", fn {tiles, n} -> "#{tiles}t×#{n}" end)
  end

  # What the battle list counted that the screen could not place. Only a gap
  # when there IS a list to compare against.
  defp crowd_gap(%{listed: listed, seen: seen}) when is_integer(listed), do: max(listed - seen, 0)
  defp crowd_gap(_no_list), do: 0

  # An area skill leaves the POKÉMON. When its green name is covered the reading
  # falls back to the character, and the difference is two tiles on his screen —
  # so it is said out loud instead of quietly changing what the number means.
  defp area_headline(%{p50: p50, casts: casts}) do
    "alcance medido: ~#{Float.round(p50, 1)} tiles em #{casts} #{if casts == 1, do: "disparo", else: "disparos"}"
  end

  # The whole shape, because the median alone cannot show contamination.
  defp area_spread(%{p50: p50, p75: p75, top: top, hits: hits, discarded: dropped}) do
    "mediana #{Float.round(p50, 1)}t · p75 #{Float.round(p75, 1)}t · topo #{Float.round(top, 1)}t · #{hits} números de dano" <>
      if dropped > 0, do: " · #{dropped} descartado(s) por não achar o nome verde", else: ""
  end

  # "o 8 nunca foi ensinado" / "o 6 e o 8 nunca foram ensinados" — o número de
  # dígitos que falta muda a frase, e a frase é o que ele vai ler correndo.
  defp gap_words([digito]), do: "o #{digito} nunca foi ensinado"

  defp gap_words(digitos) do
    {inicio, [ultimo]} = Enum.split(digitos, -1)
    "o " <> Enum.join(inicio, ", o ") <> " e o " <> ultimo <> " nunca foram ensinados"
  end

  defp crowd_anchor(:pokemon), do: "medido do seu pokémon"
  defp crowd_anchor(:character), do: "medido do personagem (não achei o nome verde)"

  defp crowd_reason(:not_calibrated), do: "o /calibrar nunca rodou nesta tela"
  defp crowd_reason(:no_player_point), do: "a calibração não marcou onde o personagem fica"
  defp crowd_reason(reason), do: to_string(reason)

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
  # domain's (`Route.stop/0`); only these words are Portuguese. Whitelisted and
  # never `String.to_atom/1` — the value comes from the DOM, and a stop nobody
  # knows answers nil, which `Route.set_stop/4` leaves the route untouched for.
  defp decode_stop(value), do: Enum.find(Route.stops(), &(Atom.to_string(&1) == value))

  # Whitelist, never String.to_atom/1: the value comes from the DOM. A category
  # nobody knows answers nil, and the handler above drops the event rather than
  # trying to name it.
  defp decode_skill(value), do: Enum.find(Route.skills(), &(Atom.to_string(&1) == value))

  # The nil clause is the whole reason these are functions and not a `case`: a
  # stop or a category nobody knows leaves HERE, before anything tries to name
  # it.
  defp toggle_stop(socket, _index, nil), do: {:noreply, socket}

  defp toggle_stop(socket, index, stop) do
    socket = remember_hand_mark(socket, index)

    with_route(socket, fn route ->
      on? = stop not in Route.stops_at(route.waypoints, index)

      {Route.set_stop(route, index, stop, on?),
       "waypoint #{index + 1}: #{stop_label(stop)} #{if on?, do: "ligado", else: "desligado"}"}
    end)
  end

  defp toggle_skill(socket, _index, nil), do: {:noreply, socket}

  defp toggle_skill(socket, index, skill) do
    index = String.to_integer(index)
    socket = remember_hand_mark(socket, index)

    with_route(socket, fn route ->
      on? = skill not in Route.skills_at(route.waypoints, index)

      {Route.set_skill(route, index, skill, on?),
       "waypoint #{index + 1}: #{SkillProfile.label(skill)} #{if on?, do: "ligada", else: "desligada"}"}
    end)
  end

  # Every category paired with whether THIS waypoint carries it, read once per
  # row. Each chip asking on its own walked the waypoint list twice over, for
  # ten walks per row to answer one question about one place.
  defp waypoint_skill_chips(wp) do
    carried = List.wrap(wp[:skills])
    Enum.map(Route.skills(), &{&1, &1 in carried})
  end

  # What this corner tells the pokémon to fire, as icons: the READ-ONLY half of
  # the chips, so a 67-corner route reads at a glance instead of carrying 335
  # buttons. Answered as a list of nothing or one, the same trick
  # `selected_pair/2` uses, so a corner with no skill renders no badge at all.
  defp skill_badge(wp) do
    case List.wrap(wp[:skills]) do
      [] ->
        []

      skills ->
        [
          {Enum.map_join(skills, " ", &SkillProfile.icon/1),
           Enum.map_join(skills, ", ", &SkillProfile.label/1)}
        ]
    end
  end

  # An empty field is "I have no ruler here", which is not zero ("wait for
  # nothing here"). Typed garbage becomes nil too, never a crash.
  defp parse_ms(raw) when is_binary(raw) do
    case Integer.parse(String.trim(raw)) do
      {ms, ""} when ms >= 0 -> ms
      _empty_or_junk -> nil
    end
  end

  defp parse_ms(_absent), do: nil

  defp gather_wait_note(what, nil), do: "#{what} voltou a usar o respiro do /config"
  defp gather_wait_note(what, ms), do: "#{what} espera #{ms}ms o bolo fechar"

  # What his hands measured, offered as a starting point — and only when it is
  # plausible. The two settings that used to bound the Logic live here now: 12s
  # measured at a kill spot is not him waiting for the pile, it is the recorder
  # having timed something else.
  #
  # Answered as a list of nothing or one so the row asks once: `:if` plus the
  # text ran the whole check twice on every kill spot.
  defp gather_suggestion(%{gather_ms: ms}) when is_integer(ms) do
    if ms >= Settings.get(:cavebot_gather_wait_min_ms) and
         ms <= Settings.get(:cavebot_gather_wait_max_ms),
       do: [ms],
       else: []
  end

  defp gather_suggestion(_no_measurement), do: []

  defp stop_label(:cooldown_revive), do: "resetar cooldown"
  defp stop_label(:wait), do: "esperar"

  defp stop_icon(:cooldown_revive), do: "⚡"
  defp stop_icon(:wait), do: "⏱"

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
  # A BARRA, tecla por tecla, no estado em que ela está AGORA. `ready_skills`
  # responde `nil` quando a leitura não existe ou envelheceu — e não saber é
  # diferente de estar em cooldown, então tem cara própria.
  # A FILEIRA DA BARRA, com as duas testemunhas. Ver `Pokex.Bots.SkillRack`: a
  # página não decide nada aqui, e o `state` de cada peça é o mesmo que o
  # combate vai obedecer.
  defp skill_rack(combat), do: SkillRack.build(fighting_as(combat), Perception.ready_skills())

  defp tile_class(%{state: :ready, job: "controle" <> _}),
    do: "border-pk-warn-line bg-pk-warn/10"

  defp tile_class(%{state: :ready}), do: "border-pk-ok-line bg-pk-ok-dim"
  defp tile_class(%{muted?: true}), do: "border-pk-danger-line bg-pk-danger-dim"
  defp tile_class(%{disagree?: true}), do: "border-pk-danger-line bg-pk-danger-dim"
  defp tile_class(_cooling), do: "border-pk-line bg-pk-sunken"

  defp tile_key_class(%{state: :ready, job: "controle" <> _}), do: "text-pk-warn"
  defp tile_key_class(%{state: :ready}), do: "text-pk-ok"
  defp tile_key_class(%{muted?: true}), do: "text-pk-danger"
  defp tile_key_class(%{disagree?: true}), do: "text-pk-danger"
  defp tile_key_class(_cooling), do: "text-pk-text-3"

  # O NÚMERO QUE ELE PEDIU. Segundos inteiros abaixo de um minuto, porque é a
  # unidade em que o jogo escreve o cooldown na própria tecla; um traço quando
  # ninguém sabe quanto falta, que é uma resposta e não um erro.
  defp countdown(%{left_ms: 0}), do: "—"
  defp countdown(%{left_ms: ms}) when ms < 60_000, do: "#{max(div(ms + 999, 1_000), 1)}s"
  defp countdown(%{left_ms: ms}), do: "#{div(ms, 60_000)}min"

  defp tile_title(tile) do
    "#{tile.key}: #{tile.job} · tela: #{witness_text(tile.screen)} · " <>
      "relógio: #{witness_text(tile.clock)}"
  end

  # A etiqueta do quadrado é curta porque o quadrado é pequeno; a frase inteira
  # continua no `title`.
  defp job_short("controle" <> _), do: "controle"
  defp job_short("alvo único" <> _), do: "único"
  defp job_short("sem trabalho"), do: "—"
  defp job_short(job), do: job

  defp witness_text(:ready), do: "pronta"
  defp witness_text(:cooling), do: "em cooldown"
  defp witness_text(:unknown), do: "não sabe"

  # Quantas teclas da barra ainda não têm o tempo escrito no /time. Sem ele não
  # há contagem regressiva pra mostrar, e o relógio cai no assumido de 45s.
  defp unwritten(tiles), do: Enum.count(tiles, &(&1.written_ms == nil))

  # As teclas em conflito, juntas — e o motivo dito UMA vez. Dentro do
  # quadradinho a frase virava "tela diz em …", que ocupa a peça e não informa.
  defp enemy_pct(pct) when is_number(pct), do: round(pct * 100)
  defp enemy_pct(_unknown), do: 0

  # QUAL LINHA É A DELE — pela decisão do CÉREBRO, nunca por uma segunda regra
  # na tela. `Situation.named` é a lista JÁ sem a linha própria (descontada por
  # nome, por vida ou por posição), então a que sobra é a dele. Sem quadro, a
  # tela não afirma nada.
  defp mine?(_row, nil), do: false

  defp mine?(row, %{named: named}) when is_list(named),
    do: row[:row] not in Enum.map(named, & &1[:row])

  defp mine?(_row, _no_reading), do: false

  # Quantos INIMIGOS, que não é quantas linhas: a linha dele não conta.
  defp enemies_seen(_world, %{enemies: n}) when is_integer(n), do: n
  defp enemies_seen(world, _no_reading), do: length(world.enemies)

  # A vida do bicho conta a história ao contrário da dele: cheia é ruim (falta
  # matar), quase vazia é o alvo prestes a cair. O trilho é neutro e o
  # COMPRIMENTO é a informação — verde e vermelho aqui competiriam com as
  # barras de cima, onde as cores significam perigo.
  defp enemy_fill(row, situation) do
    cond do
      mine?(row, situation) -> "bg-pk-ok"
      is_number(row[:hp_pct]) and row[:hp_pct] <= 0.35 -> "bg-pk-warn"
      is_number(row[:hp_pct]) -> "bg-pk-text-3"
      true -> "bg-pk-line-strong"
    end
  end

  defp active_name(combat) do
    case fighting_as(combat) do
      %{name: name} -> name
      _none -> nil
    end
  end

  defp conflicted(tiles),
    do: tiles |> Enum.filter(&(&1.muted? or &1.disagree?)) |> Enum.map(& &1.key)

  # A causa mais forte primeiro: uma tecla CALADA é o jogo tendo ignorado o
  # aperto, e isso já explica a discordância que vem junto.
  defp conflict_reason(tiles) do
    if Enum.any?(tiles, & &1.muted?) do
      "o jogo não reagiu ao aperto. A barra está oferecendo tecla que não sai — " <>
        "recalibre a barra com TUDO pronto, fora de combate"
    else
      "a leitura da barra e o relógio das teclas discordam — a rotação obedece o relógio"
    end
  end

  # O caderninho: só existe com o estoque digitado (`revive_stock` > 0).
  defp revive_ledger do
    case ReviveLedger.remaining() do
      nil ->
        nil

      left ->
        reserve = Settings.get(:engine_revive_reserve)

        cond do
          left <= 0 ->
            "revives: acabaram pela conta (#{ReviveLedger.spent()} gastos) — repõe e digita o estoque novo no /config"

          left <= reserve ->
            "revives: só #{left} na conta — guardando pra emergência (#{ReviveLedger.spent()} gastos)"

          true ->
            "revives: ~#{left} no bolso · #{ReviveLedger.spent()} gastos desde a última contagem"
        end
    end
  end

  defp ledger_tone do
    case ReviveLedger.remaining() do
      nil ->
        "text-pk-text-3"

      left when left <= 0 ->
        "text-pk-danger font-bold"

      left ->
        if left <= Settings.get(:engine_revive_reserve),
          do: "text-pk-warn",
          else: "text-pk-text-3"
    end
  end

  defp burst_line do
    "rajada: #{burst_size()} tecla(s) a cada #{burst_gap_ms()}ms"
  end

  defp burst_size, do: max(Settings.get(:combat_skill_burst_size) || 1, 1)
  defp burst_gap_ms, do: Settings.get(:combat_skill_gap_ms) || 0
  defp default_burst_gap_ms, do: Map.fetch!(Settings.defaults(), :combat_skill_gap_ms)
  defp burst_cost_ms, do: burst_size() * burst_gap_ms()

  # "Devagar" não é uma opinião: é o intervalo estar acima do padrão o bastante
  # pra uma rajada custar mais de meio segundo.
  defp slow_burst?, do: burst_gap_ms() > default_burst_gap_ms() and burst_cost_ms() >= 500

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
          single: loadout.single,
          heal: loadout.heal,
          shield: loadout.shield,
          cooldowns: loadout.cooldowns
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
    case Route.floor_change(waypoints, arriving_leg(waypoints, index)) do
      nil -> nil
      floor -> "⇅ andar #{floor}"
    end
  end

  # The convention of this list, and the reason for every `index - 1` in it: a
  # waypoint's badges describe the leg that ARRIVES at it, never the one that
  # leaves it. `climb_label/2` and `leg_tiles/2` are the other two witnesses.
  # Mixing the two directions puts one row's badges on two different legs, which
  # reads as a straight lie — "⇅ andar 6" beside "a marcação não está limpa"
  # when it is the descent AFTER that row that is crooked. Do not simplify the
  # shift away.
  defp arriving_leg(waypoints, index), do: Integer.mod(index - 1, max(length(waypoints), 1))

  # A floor change is either a staircase the route describes exactly — one key,
  # two tiles, the step in the middle — or a corner with extra walking folded
  # into it, which costs the hunt the ring search. Saying which is which is the
  # difference between "it is slow at the stairs" and a corner he can fix.
  #
  # Nothing is offered on a crooked one, and nothing can be: the step is the
  # midpoint of two tiles exactly two apart, so it exists only once the pair is
  # already clean. On a folded corner the staircase's real position is not in
  # the recording at all — he is the one who knows it, by walking there.
  #
  # `{tone, short, full}`: this row already carries eight things on one line, so
  # the badge shows the verdict and the sentence that acts on it travels in
  # `title`/`sr-only` — the same split the skill badge beside it uses.
  defp stair_label(waypoints, index) do
    leg = arriving_leg(waypoints, index)

    case {Route.floor_change(waypoints, leg), Route.stair_leg(waypoints, leg)} do
      {nil, _no_stair} ->
        nil

      {_floor, {:stair, _sx, _sy}} ->
        {x, y} = Route.stair_step(waypoints, leg)
        step = "🪜 escada: o degrau é #{x}, #{y}"
        {:ok, step, step}

      {_floor, nil} ->
        crooked = "🪜 troca de andar, mas a marcação não está limpa"

        {:warn, crooked,
         crooked <>
           " — o passo da escada é 1 tecla que anda 2 tiles: marque o canto logo" <>
           " ANTES e o logo DEPOIS"}
    end
  end

  defp stair_tone(:ok), do: "border-pk-ok-line bg-pk-ok-dim text-pk-ok"
  defp stair_tone(:warn), do: "border-pk-warn-line bg-pk-warn-dim text-pk-warn"

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
  defp map_floor(%Route{} = route, _no_pos), do: route |> Route.floors() |> List.first()
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

  # The engine's facts, straight off the blackboard. Stale reads as absent: a
  # page that shows a decision nobody is making any more is worse than one that
  # shows none.
  defp engine_fact(key) do
    case Pokex.Perception.WorldState.get(key, 3_000, System.monotonic_time(:millisecond)) do
      {:ok, obs} -> obs
      _stale_or_missing -> nil
    end
  end

  defp default_active(routes), do: Enum.find(routes, & &1.enabled?)

  # The coordinate and the read health come from `PositionReadout`: the SAME
  # words here, on the panel and on /world. Three pages showing the position
  # in three different phrasings was the recipe for trusting none of them.
  defp pos_text(pos), do: PositionReadout.coords(pos)
  defp read_health(reads, misses), do: PositionReadout.read_health(reads, misses)

  # "aguardando a primeira leitura" was TRUE and useless: the feed only
  # broadcasts when the observation CHANGES, so this counter cannot tell
  # "reading fine, standing still" apart from "not reading at all". With the
  # fence up it is the second one, always — say that instead.
  defp read_note(true, _reads, _misses), do: "os olhos estão desligados pelo simulador"
  defp read_note(_free, reads, misses), do: read_health(reads, misses)

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

  # WHERE the running hunt is on this route — `nil` when it is stopped, or when
  # the route on screen is not the one being walked (he edits one route while
  # another is armed, and a green mark on the wrong list is worse than none).
  defp heading_to(%{state: state}, _route) when state in [:idle, nil], do: nil

  defp heading_to(%{route: name, wp_index: index}, %Route{name: name}), do: index
  defp heading_to(_no_hunt_or_other_route, _route), do: nil

  # Read through Access, never by dot: this page also renders PARTIAL snapshots
  # (a fleet fallback, an older broadcast, a test), and a missing key must not
  # take the whole page down over a progress counter.
  # Corners walked and, when they happened at all, the incidents: a night with
  # zero aborts and zero comebacks says so by staying short.
  defp hunt_tally(%{counters: %{} = c}) do
    [
      {Map.get(c, :aborts, 0), "mobada(s) largada(s)"},
      {Map.get(c, :comebacks, 0), "volta(s)"},
      {Map.get(c, :blocks, 0), "parada(s)"}
    ]
    |> Enum.filter(fn {n, _} -> n > 0 end)
    |> case do
      [] -> nil
      some -> Enum.map_join(some, " · ", fn {n, label} -> "#{n} #{label}" end)
    end
  end

  defp hunt_tally(_no_counters), do: nil

  defp hunt_progress(%{state: state} = hunt) when state not in [:idle, nil] do
    with index when is_integer(index) <- hunt[:wp_index],
         total when is_integer(total) and total > 0 <- hunt[:wp_total] do
      "waypoint #{index + 1}/#{total}"
    else
      _incomplete -> nil
    end
  end

  defp hunt_progress(_stopped_or_absent), do: nil

  # The feed starts with what the JOURNAL already knows: closing the tab (or a
  # crash, or a reload at 4am) no longer erases the night. Only the sources the
  # hunt cares about, newest first, in this page's own shape.
  defp seed_log do
    [sources: ~w(cavebot game combat engine), limit: @log_lines, min_severity: :macro]
    |> Pokex.Journal.recent()
    |> Enum.map(&%{level: &1.severity, text: &1.text, at: DateTime.to_time(&1.at)})
  catch
    :exit, _journal_down -> []
  end

  # REPETIÇÃO CONSECUTIVA VIRA CONTADOR. Metade das linhas da noite dele eram
  # a mesma frase duas vezes seguidas no mesmo segundo — 6 de 14 linhas na tela
  # que ele mandou em 28/08. Colapsar não ESCONDE: o `×2` fica visível, que é o
  # que permite descobrir de onde vem a repetição em vez de olhar por cima dela.
  defp log_line(socket, level, text) do
    assign(socket, log: fold(socket.assigns.log, level, text))
  end

  defp fold([%{text: same, level: level} = head | rest], level, same),
    do: [%{head | times: head.times + 1, at: Time.utc_now()} | rest]

  defp fold(log, level, text),
    do: Enum.take([%{level: level, text: text, at: Time.utc_now(), times: 1} | log], @log_lines)

  defp visible_log(log, true), do: log
  defp visible_log(log, _hide), do: Enum.reject(log, &(&1.level == :debug))

  # As quatro vozes do feed. O prefixo já vinha no texto; aqui ele vira coluna,
  # e o que sobra da frase começa sempre no mesmo x.
  @sources [
    {"caçada: ", "caçada", "text-pk-info"},
    {"quadro: ", "cérebro", "text-pk-ok"},
    {"combate: ", "luta", "text-pk-warn"}
  ]

  defp source_label(text) do
    Enum.find_value(@sources, "suporte", fn {prefix, label, _tone} ->
      String.starts_with?(text, prefix) && label
    end)
  end

  defp source_tone(text) do
    Enum.find_value(@sources, "text-pk-text-3", fn {prefix, _label, tone} ->
      String.starts_with?(text, prefix) && tone
    end)
  end

  defp strip_source(text) do
    Enum.find_value(@sources, text, fn {prefix, _label, _tone} ->
      String.starts_with?(text, prefix) && String.replace_prefix(text, prefix, "")
    end)
  end

  defp log_tone(%{level: :alarm}), do: "text-pk-warn"
  defp log_tone(%{level: :macro}), do: "text-pk-text"
  defp log_tone(_debug), do: "text-pk-text-3"

  defp log_as_text(log, show_debug) do
    log
    |> visible_log(show_debug)
    |> Enum.reverse()
    |> Enum.map_join("\n", &"#{Calendar.strftime(&1.at, "%H:%M:%S")} #{&1.text}")
  end

  defp safety_snapshot do
    %{
      rescue?: Settings.get(:rescue_enabled),
      heal?: Settings.get(:heal_skill_enabled),
      potion?: Settings.get(:potion_enabled),
      abort_pct: Settings.get(:cavebot_hp_abort_pct),
      resume_pct: Settings.get(:cavebot_hp_resume_pct),
      block_retries: Settings.get(:cavebot_block_retries),
      block_retry_ms: Settings.get(:cavebot_block_retry_ms)
    }
  end

  # The whitelist IS the parser: client strings never become atoms.
  # Warn, not ok, when it is turned ON: it spends presses on a game mechanic
  # nobody has watched yet, and the strip is the only place that says so.
  defp reset_revive_notice(true),
    do:
      "o revive passa a sair no meio da luta pra zerar cooldown — meça antes em /sim se " <>
        "tirar o pokémon de campo e trazer de volta zera mesmo as skills dele"

  defp reset_revive_notice(false),
    do: "o revive volta a ser só resgate (vermelho e fim de rodada)"

  defp gather_notice(true), do: "juntando pilha antes de bater"

  defp gather_notice(false),
    do:
      "sem juntar pilha: bate assim que #{Settings.get(:engine_engage_from)} inimigo(s) aparecer(em)"

  defp safety_key("rescue"), do: :rescue_enabled
  defp safety_key("heal"), do: :heal_skill_enabled
  defp safety_key("potion"), do: :potion_enabled
  defp safety_key(_unknown), do: nil

  defp safety_notice(:rescue_enabled, true),
    do: "resgate armado — o suporte revive se a vida despencar"

  defp safety_notice(:rescue_enabled, false), do: "resgate desligado — ninguém revive o pokémon"
  defp safety_notice(:heal_skill_enabled, true), do: "cura armada"
  defp safety_notice(:heal_skill_enabled, false), do: "cura desligada"
  defp safety_notice(:potion_enabled, true), do: "poção armada"
  defp safety_notice(:potion_enabled, false), do: "poção desligada"

  defp hp_guard_notice(0, _resume), do: "guarda de HP desligada — a mobada nunca é abandonada"

  defp hp_guard_notice(abort, resume),
    do: "abandona a mobada abaixo de #{abort}% e volta em #{resume}% — vale da próxima caçada"

  defp comeback_notice(0, _seconds),
    do: "volta automática desligada — um tropeço local encerra a caçada"

  defp comeback_notice(retries, seconds),
    do: "tropeçou: espera #{seconds}s e tenta voltar, até #{retries}x"

  # Same semantics as the panel's arm_support/0: turning a net ON re-runs the
  # idempotent monitor, the natural re-enable after a panic halted it. Gated by
  # the same env flag so tests never tick the app-global worker.
  defp arm_support do
    if Application.get_env(:pokex, :player_support_auto_monitor, true),
      do: Pokex.Bots.PlayerSupport.Worker.run()

    :ok
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def render(assigns) do
    # A FILEIRA, montada UMA vez. Ela lê o relógio (ETS) e o fato da barra, e o
    # template pergunta por ela em oito lugares — pedir oito vezes é oito
    # leituras que podem discordar entre si dentro do mesmo desenho.
    assigns = assign(assigns, :rack, skill_rack(assigns.combat))

    ~H"""
    <%!-- The widest page in the app, deliberately: this one holds a MAP of a
          55-tile route beside a list of 45 corners, and on the default
          `max-w-3xl` the drawing got 350px — six pixels per tile — while an
          ultrawide screen sat empty around it. Same rule as the dashboard:
          narrow where a phone would need it, wide where there is room. --%>
    <%!-- A LARGURA LIGA COM O LAYOUT, no mesmo degrau. As onze regras desta
         página ligam em `lg` (1024px): o cockpit vira duas colunas, o bloco
         ganha uma tela de altura, o feed passa a rolar por dentro. A largura
         que acomoda isso liberava só em `xl` (1280) — então entre 1024 e 1279
         a página montava DUAS COLUNAS DENTRO DE 560px e o conteúdo se
         atropelava.

         Ele achou isso com o navegador em 90% de zoom (2026-08-28), e zoom é
         exatamente o que alguém que lê de óculos usa. Uma faixa de 256px de
         largura onde a página nasce quebrada não é caso raro: é uma janela
         não-maximizada num monitor grande. --%>
    <Layouts.app
      flash={@flash}
      current_page={:cavebot}
      max_width="max-w-[560px] lg:max-w-[1600px]"
      {Layouts.header(assigns)}
    >
      <%!-- TWO MODES, one page. Watching a hunt and editing a route want the
           same screen and disagree about everything else: watching wants the
           map, the bar and the feed and nothing that can be clicked by
           accident; editing wants the map beside forty-five rows of corners.
           Stacked, they were five strips and a workbench that did not fit a
           notebook — "eu quero ver sempre o mapa inteiro aberto na minha tela"
           (Lucas, 2026-08-28).

           Both modes are bounded by the VIEWPORT: this block is exactly one
           screen tall, and whatever scrolls, scrolls inside itself. The
           `min-h-0` is what lets a flex or grid child shrink below its content
           and scroll at all. --%>
      <div class="flex flex-col gap-2 lg:h-[calc(100dvh-4.5rem)]">
        <header class="flex flex-wrap items-center justify-between gap-x-3 gap-y-1">
          <div>
            <%!-- The subtitle explained the page to someone reading it for the
             first time, and cost a line of a laptop screen on every one of
             the thousand times after that (2026-08-14). --%>
            <h1 class="text-pk-body font-bold uppercase tracking-[0.14em] text-pk-text">
              Central da caçada
            </h1>
          </div>
          <p class="font-mono text-pk-meta text-pk-text-3">
            <span :if={hunt_progress(@hunt)} class="font-bold text-pk-ok">
              {hunt_progress(@hunt)} ·
            </span>
            <%!-- the night in five numbers, where he already looks for the
             route's size — incidents included, because "o que ocorreu"
             needs them (2026-08-15) --%>
            <span :if={hunt_tally(@hunt)} id="cavebot-tally" class="text-pk-text-2">
              {hunt_tally(@hunt)} ·
            </span>
            {length(@routes)} rota(s) · {(@active_route && length(@active_route.waypoints)) || 0} waypoints · {route_tiles(
              @active_route
            )} tiles
          </p>
          <.mode_tabs mode={@mode} />
        </header>

        <.hunt_alerts
          minimap_gap?={@minimap_gap?}
          hunt={@hunt}
          sim_armed?={@sim_armed?}
          world={@world}
          routes={@routes}
          active_route={@active_route}
          notice={@notice}
          notice_kind={@notice_kind}
        />

        <%!-- ASSISTIR: the map takes the left half whole, and everything that
             changes on its own — who is fighting, the cooldown squares, the
             world tiles, the feed — stacks down the right. Nothing here is a
             route editor: the only page that scrolls is the feed, inside its
             own box. --%>
        <div
          :if={@mode == :watch}
          id="cavebot-cockpit"
          class="grid gap-2 lg:min-h-0 lg:flex-1 lg:grid-cols-[minmax(0,0.85fr)_minmax(0,1.15fr)]"
        >
          <.route_map_card
            active_route={@active_route}
            pos={@pos}
            selected={@selected}
            hunt={@hunt}
            recording?={@recording?}
            fill?
          />

          <div class="flex flex-col gap-2 lg:min-h-0">
            <%!-- WHO the fight is fighting as. He classifies each pokémon's keys on
            /time and the hunt page said nothing about it: "sinto falta dele
            falar ali qual pokémon que eu tô usando (…) pra eu saber que os
            combos que ele tá me mostrando ali na caçada são de acordo com
            aquele meu pokémon" (2026-08-12).

            LIVE when the fight is running (that is the proof it is being
            obeyed), the CONFIGURATION otherwise, and it says which. --%>
            <section
              id="cavebot-loadout"
              class="rounded-lg border border-pk-line bg-pk-surface px-3 py-1.5"
            >
              <div class="flex flex-wrap items-center gap-x-3 gap-y-0.5">
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

              <p
                :if={fighting_as(@combat)}
                class="mt-0.5 flex flex-wrap gap-x-3 font-mono text-pk-meta"
              >
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

              <%!-- A BARRA, AGORA. Ele desconfiava que a rotação não estava usando
              algumas skills e não tinha como olhar; virou uma fileira de
              etiquetas com um `title`, que é uma resposta que só existe
              quando o mouse pergunta. Em 27/08 o jogo escreveu 12, 32 e 32
              em cima de três teclas enquanto a leitura dizia "prontas", e a
              luta gastou dezenove segundos nelas — nada em tela nenhuma
              dizia isso.

              Então cada tecla é um QUADRADO, com quanto falta em contagem
              regressiva, e as duas testemunhas ficam à vista quando
              discordam: "importante irmos dando mais esses detalhes (…) pra
              eu ir ajudando a debugar problemas de leitura do jogo"
              (27/08). Ver `Pokex.Bots.SkillRack`. --%>
              <div :if={fighting_as(@combat)} id="cavebot-rack" class="mt-1.5">
                <div class="mb-1 flex flex-wrap items-center gap-x-2 gap-y-0.5">
                  <span class="font-mono text-pk-meta uppercase tracking-[0.12em] text-pk-text-3">
                    a barra agora
                  </span>
                  <span class="pk-num font-mono text-pk-meta text-pk-text-2">
                    {SkillRack.ready_count(@rack)}/{length(@rack)} prontas
                  </span>
                  <span
                    :if={Perception.ready_skills() == nil}
                    class="flex items-center gap-1 rounded border border-pk-warn-line bg-pk-warn-dim px-1.5 py-0.5 text-pk-meta font-bold text-pk-warn"
                    title="a barra do jogo não está sendo lida — quem responde é só o relógio das teclas"
                  >
                    <.icon name="hero-eye-slash" class="size-3" /> barra não lida
                  </span>
                  <span
                    :if={Enum.any?(@rack, & &1.disagree?)}
                    class="flex items-center gap-1 rounded border border-pk-danger-line bg-pk-danger-dim px-1.5 py-0.5 text-pk-meta font-bold text-pk-danger"
                    title="a leitura da barra e o relógio das teclas não estão contando a mesma coisa — recalibre a barra com TUDO pronto, fora de combate"
                  >
                    <.icon name="hero-exclamation-triangle" class="size-3" /> tela × relógio
                  </span>
                  <span class="ml-auto text-pk-meta text-pk-text-2">{burst_line()}</span>
                </div>

                <%!-- 84px: com 78 o motivo da discordância cabia como "tela diz
                em …" — ruído com cara de informação — e com 96 os nove
                quadrados comiam a coluna ("tão grande demais", 28/08). O
                motivo saiu da peça (vira uma linha embaixo do rack), então a
                peça só precisa do que se lê de longe: a tecla, o trabalho e o
                tempo. --%>
                <ol class="grid grid-cols-[repeat(auto-fill,minmax(84px,1fr))] gap-1">
                  <li
                    :for={tile <- @rack}
                    class={[
                      "relative overflow-hidden rounded-lg border px-2 py-1.5",
                      tile_class(tile)
                    ]}
                    title={tile_title(tile)}
                  >
                    <%!-- O TRILHO QUE ENCHE fica ATRÁS do texto: o quadrado inteiro
                    é o medidor, então dá pra ler a barra de longe sem
                    procurar onde está o número. --%>
                    <span
                      :if={SkillRack.recovered_pct(tile)}
                      class="absolute inset-y-0 left-0 bg-pk-ok/10 transition-[width] duration-1000 ease-linear"
                      style={"width: #{SkillRack.recovered_pct(tile)}%"}
                      aria-hidden="true"
                    ></span>

                    <span class="relative flex items-baseline justify-between gap-1">
                      <span class={["pk-num font-mono text-pk-body font-bold", tile_key_class(tile)]}>
                        {tile.key}
                      </span>
                      <span class="truncate text-pk-meta text-pk-text-3">{job_short(tile.job)}</span>
                    </span>

                    <%!-- O ESTADO EM UMA PALAVRA, sempre no mesmo lugar: os nove
                    quadrados se leem numa varredura só quando a linha de baixo
                    é sempre a mesma pergunta. O traço sozinho ("—") não era
                    resposta: dizia "esfriando, e ninguém escreveu quanto". --%>
                    <span class="relative mt-0.5 flex items-baseline gap-1">
                      <span
                        :if={tile.state == :ready}
                        class="text-pk-meta font-bold uppercase tracking-[0.1em] text-pk-ok"
                      >
                        pronta
                      </span>
                      <span
                        :if={tile.state == :cooling and tile.left_ms > 0}
                        class="pk-num font-mono text-pk-body font-bold tabular-nums text-pk-warn"
                      >
                        {countdown(tile)}
                      </span>
                      <span
                        :if={tile.state == :cooling and tile.left_ms == 0}
                        class="text-pk-meta uppercase tracking-[0.1em] text-pk-text-3"
                      >
                        esfriando
                      </span>
                      <.icon
                        :if={tile.muted? or tile.disagree?}
                        name="hero-exclamation-triangle"
                        class="ml-auto size-3 shrink-0 text-pk-danger"
                      />
                    </span>
                  </li>
                </ol>

                <%!-- O MOTIVO, UMA VEZ, embaixo do rack — e não truncado dentro de
                cada peça. Junta as teclas em conflito numa frase que diz o que
                FAZER: a peça mostra o alerta, esta linha explica. --%>
                <p
                  :if={conflicted(@rack) != []}
                  id="cavebot-rack-conflict"
                  class="mt-1.5 flex items-start gap-1.5 rounded-lg border border-pk-danger-line bg-pk-danger-dim px-2 py-1.5 text-pk-meta text-pk-danger"
                >
                  <.icon name="hero-exclamation-triangle" class="mt-px size-3.5 shrink-0" />
                  <span>
                    <b class="font-bold">{Enum.join(conflicted(@rack), ", ")}</b>
                    — {conflict_reason(@rack)}
                  </span>
                </p>

                <p :if={@rack == []} class="text-pk-meta text-pk-text-3">
                  sem barra classificada
                </p>

                <p
                  :if={unwritten(@rack) > 0}
                  class="mt-1 flex items-start gap-1.5 text-pk-meta text-pk-text-3"
                >
                  <.icon name="hero-clock" class="mt-px size-3.5 shrink-0" />
                  <span>
                    {unwritten(@rack)} tecla(s) sem o tempo escrito — sem ele não há
                    contagem, e o relógio chuta {div(SkillClock.assumed_ms(), 1_000)}s.
                    <.link navigate={~p"/time"} class="underline">escrever no /time</.link>
                  </span>
                </p>
              </div>

              <%!-- A RAJADA CUSTA O QUE O INTERVALO MANDA. Um `gap` alto não parece
              nada num arquivo de ajustes e é o teto de dano da caçada
              inteira. --%>
              <p :if={slow_burst?()} class="mt-1 flex items-start gap-1.5 text-pk-meta text-pk-warn">
                <.icon name="hero-exclamation-triangle" class="mt-px size-3.5 shrink-0" />
                <span>
                  o intervalo entre teclas está em <b>{burst_gap_ms()}ms</b>
                  (o padrão é {default_burst_gap_ms()}ms) — cada rajada custa {burst_cost_ms()}ms, e é isso que limita o dano da caçada
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

              <%!-- O CADERNINHO DO ESTOQUE. 189 revives saíram em menos de 2h na
              noite de 27→28/08, o estoque acabou e ninguém viu. Digitar o
              estoque no /config é o botão de repor (a conta zera quando o
              número muda). --%>
              <p
                :if={revive_ledger()}
                id="cavebot-revive-ledger"
                class={["mt-1 flex items-center gap-1.5 font-mono text-pk-meta", ledger_tone()]}
              >
                <.icon name="hero-heart" class="size-3.5 shrink-0" />
                <span>{revive_ledger()}</span>
              </p>
            </section>

            <%!-- O QUE ELE ESTÁ VENDO, em barras. Ele pediu pra poder JOGAR pela
            Central — e disse por que isso vale mais do que conforto: "já
            aconteceu antes onde o problema não era no algoritmo da engine e
            sim na detecção correta de dados pelas imagens" (28/08). Uma tela
            que mostra a DECISÃO só permite discutir a regra; uma que mostra a
            LEITURA permite ele dizer "isso aí na tela não é o que eu estou
            vendo no jogo", que é o defeito mais caro de achar.

            CUSTO ZERO de captura: os três números já são fatos publicados (a
            Pokebar e a barra vermelha pelo suporte, a lista de batalha pelo
            feed do combate). Isto só desenha o que já estava sendo lido. --%>
            <section
              id="cavebot-vision"
              class="rounded-lg border border-pk-line bg-pk-sunken px-2.5 py-2"
            >
              <div class="grid gap-2 sm:grid-cols-2">
                <.hp_bar
                  label="você"
                  pct={@world.me.player_hp}
                  note={if is_nil(@world.me.player_hp), do: "marque na calibração"}
                />
                <.hp_bar label={active_name(@combat) || "pokémon"} pct={@world.me.hp_pct} />
              </div>

              <%!-- A LISTA DE BATALHA COMO ELE A VÊ. É aqui que um erro de leitura
              aparece antes de virar decisão errada — a linha do próprio
              pokémon contada como inimigo custou uma caçada inteira em 27/08.

              ALTURA FIXA: uma lista que cresce e encolhe com a mobada empurra
              tudo embaixo dela a cada tique, e o que ele estava lendo pula
              ("está com um tamanho flexível, aumentando e diminuindo",
              28/08). Duas colunas de peças pequenas, três fileiras
              reservadas, e o que passar rola dentro da própria caixa. --%>
              <div class="mt-2 border-t border-pk-line pt-1.5">
                <p class="flex items-baseline gap-1.5 font-mono text-pk-meta">
                  <span class="uppercase tracking-[0.1em] text-pk-text-3">na tela</span>
                  <span class="pk-num font-bold text-pk-text-2">
                    {enemies_seen(@world, @situation)}
                  </span>
                  <span :if={@world.enemies == []} class="text-pk-text-3">— nada na lista</span>
                  <span :if={@world.shiny?} class="ml-auto font-bold text-pk-warn">✨ shiny</span>
                </p>

                <ul
                  :if={@world.enemies != []}
                  id="cavebot-battle-rows"
                  class="mt-1 grid h-[4.5rem] grid-cols-2 content-start gap-x-2 gap-y-1 overflow-y-auto pr-1"
                >
                  <li
                    :for={row <- @world.enemies}
                    class={[
                      "flex min-w-0 items-center gap-1.5 rounded px-1 py-0.5",
                      if(mine?(row, @situation), do: "bg-pk-ok-dim", else: "bg-pk-raised")
                    ]}
                  >
                    <%!-- QUEM É O DELE, dito na peça. O cérebro já decidiu qual
                    linha descontar; a tela repete a decisão dele em vez de
                    aplicar uma segunda regra. --%>
                    <.icon
                      :if={mine?(row, @situation)}
                      name="hero-user-circle"
                      class="size-3 shrink-0 text-pk-ok"
                    />
                    <span class={[
                      "min-w-0 flex-1 truncate font-mono text-pk-meta",
                      if(mine?(row, @situation), do: "text-pk-ok", else: "text-pk-text-2")
                    ]}>
                      {row[:name] || "?"}
                    </span>
                    <span class="h-1 w-8 shrink-0 overflow-hidden rounded-full bg-pk-line">
                      <span
                        class={["block h-full rounded-full", enemy_fill(row, @situation)]}
                        style={"width: #{enemy_pct(row[:hp_pct])}%"}
                      ></span>
                    </span>
                    <span class="pk-num w-6 shrink-0 text-right font-mono text-pk-meta tabular-nums text-pk-text-3">
                      {if row[:hp_pct], do: enemy_pct(row[:hp_pct]), else: "?"}
                    </span>
                  </li>
                </ul>
              </div>
            </section>

            <%!-- THE WORLD, as the bot sees it. Everything here already existed as
            facts; what was missing was a place to read them together while
            the hunt runs. --%>
            <section id="cavebot-world" class="grid grid-cols-2 gap-1.5 sm:grid-cols-3">
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
                note={read_note(@sim_armed?, @reads, @misses)}
                tone={
                  cond do
                    @sim_armed? -> :warn
                    @misses > @reads -> :warn
                    true -> :neutral
                  end
                }
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

            <%!-- The feed used to live in this tab's assigns: a reload erased
             the night, and overnight is exactly when things go wrong. It
             is seeded from the Journal now (which persists :macro and
             :alarm to ~/.pokex/journal), and the debug switch is the one
             the panel already has — "logs mais claros (…) talvez com botão
             de debug também que nem tem no painel" (Lucas, 2026-08-15). --%>
            <section
              id="cavebot-log"
              phx-hook="CopyToClipboard"
              class="flex flex-col rounded-lg border border-pk-line bg-pk-surface p-3 lg:min-h-0 lg:flex-1"
            >
              <div class="flex flex-wrap items-center justify-between gap-2">
                <h2 class="font-mono text-pk-meta font-bold uppercase tracking-[0.12em] text-pk-text-3">
                  O que ela fez
                </h2>
                <div class="flex items-center gap-2 font-mono text-pk-meta text-pk-text-3">
                  <label
                    class="flex cursor-pointer items-center gap-1"
                    title="Mostra também as linhas de diagnóstico"
                  >
                    <input
                      id="cavebot-log-debug"
                      type="checkbox"
                      checked={@show_debug}
                      phx-click="toggle_debug"
                      aria-label="Mostrar linhas de debug no feed da caçada"
                      class="toggle toggle-xs toggle-success"
                    /> debug
                  </label>
                  <button
                    id="cavebot-log-copy"
                    type="button"
                    phx-click="copy_log"
                    title="Copia o feed inteiro pra colar num relato"
                    class="cursor-pointer rounded border border-pk-line-strong px-1.5 font-semibold transition hover:border-pk-ok/60 hover:text-pk-text"
                  >
                    copiar
                  </button>
                </div>
              </div>

              <p :if={visible_log(@log, @show_debug) == []} class="mt-2 text-pk-meta text-pk-text-3">
                nada ainda — as linhas aparecem assim que a caçada (ou o suporte) falar
              </p>

              <ol
                id="cavebot-log-lines"
                class="relative mt-2 max-h-44 space-y-0.5 overflow-y-auto pr-1 lg:max-h-none lg:min-h-0 lg:flex-1"
              >
                <li
                  :for={line <- visible_log(@log, @show_debug)}
                  class={["flex items-baseline gap-2 font-mono text-pk-meta", log_tone(line)]}
                >
                  <span class="pk-num shrink-0 tabular-nums text-pk-text-3">
                    {Calendar.strftime(line.at, "%H:%M:%S")}
                  </span>
                  <%!-- A ORIGEM VIRA ETIQUETA, em coluna de largura fixa. Ela
                  vinha como prefixo do texto ("caçada: ", "quadro: ",
                  "combate: "), o que empurrava cada frase pra um começo
                  diferente — e uma coluna que não alinha é uma coluna que não
                  se varre: "tá bem confuso de ler e acompanhar enquanto ele
                  joga" (28/08). --%>
                  <span class={[
                    "w-14 shrink-0 text-right uppercase tracking-[0.08em]",
                    source_tone(line.text)
                  ]}>
                    {source_label(line.text)}
                  </span>
                  <span class="min-w-0">{strip_source(line.text)}</span>
                  <span
                    :if={line.times > 1}
                    class="pk-num ml-auto shrink-0 rounded bg-pk-raised px-1 font-bold tabular-nums text-pk-text-3"
                    title="a mesma linha, repetida"
                  >
                    ×{line.times}
                  </span>
                </li>
              </ol>
            </section>
          </div>
        </div>

        <%!-- EDITAR: the drawing stays put at the top of the left column while
             the corner being edited scrolls under it, because those two are
             the ends of one act — "tenho que ficar scrollando pra cima e pra
             baixo pra saber o que estou editando" (2026-08-11). The list of
             corners keeps its own column and its own scroll. --%>
        <div
          :if={@mode == :edit}
          id="cavebot-workbench"
          class="grid gap-2 lg:min-h-0 lg:flex-1 lg:grid-cols-[minmax(0,1fr)_minmax(0,1.1fr)]"
        >
          <div class="flex flex-col gap-2 lg:min-h-0">
            <.route_map_card
              active_route={@active_route}
              pos={@pos}
              selected={@selected}
              hunt={@hunt}
              recording?={@recording?}
            />

            <div class="space-y-2 lg:min-h-0 lg:flex-1 lg:overflow-y-auto lg:pr-1">
              <section
                id="cavebot-recorder"
                class="rounded-lg border border-pk-line bg-pk-surface p-3"
              >
                <h2 class="font-mono text-pk-meta font-bold uppercase tracking-[0.12em] text-pk-text-3">
                  Gravar
                </h2>
                <div class="mt-2 flex flex-wrap items-center gap-1.5">
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
                class="rounded-lg border border-pk-warn-line bg-pk-surface p-3"
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

                  <span class="mx-1 h-5 w-px bg-pk-warn-line"></span>

                  <%!-- The third axis: what the pokémon FIRES here, said by
                  category. It lives beside the job and the stops for the
                  reason they do — the corner of the aura is usually the
                  corner already marked "até aqui" — and on the SELECTED
                  waypoint only: five chips on each of his 67 corners is
                  335 buttons for the handful of corners that carry one.
                  A lit chip is an order; the key comes from whichever
                  pokémon is in the field at the time. --%>
                  <button
                    :for={{skill, on?} <- waypoint_skill_chips(wp)}
                    id={"waypoint-skill-#{index}-#{skill}"}
                    phx-click="toggle_waypoint_skill"
                    phx-value-index={index}
                    phx-value-skill={skill}
                    aria-pressed={to_string(on?)}
                    aria-label={"Waypoint #{index + 1}: #{SkillProfile.label(skill)}"}
                    title={SkillProfile.moment(skill)}
                    class={[
                      "flex h-8 cursor-pointer items-center gap-1 rounded-lg border px-2 font-mono text-pk-meta transition",
                      if(on?,
                        do: "border-pk-ok bg-pk-ok-dim text-pk-ok",
                        else:
                          "border-pk-line-strong text-pk-text-2 hover:border-pk-ok/60 hover:text-pk-text"
                      )
                    ]}
                  >
                    {SkillProfile.icon(skill)} {SkillProfile.label(skill)}
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

              <details
                :if={@active_route}
                id="route-photos"
                class="rounded-lg border border-pk-line bg-pk-surface px-3 py-2"
              >
                <%!-- Reference material, not hunt material: it earns a click, not
               256px of the screen he watches the route on (2026-08-15). --%>
                <summary class="cursor-pointer list-none font-mono text-pk-meta font-bold uppercase tracking-[0.12em] text-pk-text-3 hover:text-pk-text [&::-webkit-details-marker]:hidden">
                  Como é o lugar ▸
                </summary>
                <div class="mt-3 flex flex-wrap gap-3">
                  <.route_photo kind={:start} url={Photos.url(@active_route.name, :start)} />
                  <.route_photo kind={:finish} url={Photos.url(@active_route.name, :finish)} />
                </div>
              </details>
            </div>
          </div>

          <div class="space-y-2 lg:min-h-0 lg:overflow-y-auto lg:pr-1">
            <section id="cavebot-routes" class="rounded-lg border border-pk-line bg-pk-surface p-3">
              <h2 class="font-mono text-pk-meta font-bold uppercase tracking-[0.12em] text-pk-text-3">
                Rotas
              </h2>

              <form
                :if={@routes != []}
                id="route-select-form"
                phx-change="select_route"
                class="mt-2 flex flex-wrap items-center gap-1.5"
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
                class="mt-2 flex flex-wrap items-center gap-1.5"
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
              class="rounded-lg border border-pk-line bg-pk-surface p-3"
            >
              <div class="flex flex-wrap items-baseline justify-between gap-2">
                <h2 class="font-mono text-pk-meta font-bold uppercase tracking-[0.12em] text-pk-text-3">
                  Waypoints
                </h2>
                <div class="flex items-center gap-3">
                  <.form
                    id="route-gather-wait"
                    for={%{}}
                    phx-submit="set_route_gather_wait"
                    class="flex items-center gap-1"
                  >
                    <label
                      for="route-gather-wait-input"
                      class="font-mono text-pk-meta text-pk-text-3"
                    >
                      respiro da rota
                    </label>
                    <input
                      type="number"
                      id="route-gather-wait-input"
                      name="gather_wait_ms"
                      value={@active_route.gather_wait_ms}
                      min="0"
                      step="100"
                      placeholder={Settings.get(:cavebot_gather_wait_ms)}
                      class="pk-num w-24 rounded border border-pk-line-strong bg-pk-sunken px-1.5 py-0.5 text-pk-meta text-pk-text focus:border-pk-ok focus:outline-none"
                    />
                    <span class="font-mono text-pk-meta text-pk-text-3">ms</span>
                    <button
                      id="route-gather-wait-save"
                      class="cursor-pointer rounded border border-pk-line-strong px-1.5 py-0.5 font-mono text-pk-meta font-bold text-pk-text-2 transition hover:border-pk-ok/60 hover:text-white"
                    >
                      guardar
                    </button>
                  </.form>
                  <%!-- A REAL button: as a bare text link he never found it —
                    "não consegui encontrar esse botão" (2026-08-14). --%>
                  <button
                    :if={@active_route.waypoints != []}
                    id="tidy-marks"
                    phx-click="tidy_marks"
                    aria-label="Otimizar a rota: juntar marcas repetidas e fechar as mobadas"
                    title="junta os cliques de uma luta só e garante uma mobada pra cada matança"
                    class="flex h-8 cursor-pointer items-center gap-1.5 rounded-lg border border-pk-line-strong px-2.5 font-mono text-pk-meta font-semibold text-pk-text transition hover:border-pk-info/60 hover:text-pk-info"
                  >
                    <.icon name="hero-sparkles" class="size-3.5" /> otimizar rota
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

              <.route_doctor
                route={@active_route}
                tolerance={Settings.get(:cavebot_arrival_tolerance_tiles)}
              />

              <%!-- A 45-corner route made the page 45 rows tall on a laptop —
               "as coisas da rota ainda estão muito grandes" (2026-08-14).
               The list scrolls inside its own box now, so the map, the
               editor and the list stay on ONE screen. --%>
              <ol
                :if={@active_route.waypoints != []}
                id="waypoint-list"
                phx-hook="FollowHunt"
                data-heading-to={heading_to(@hunt, @active_route)}
                class="relative mt-2 max-h-[46vh] space-y-1 overflow-y-auto pr-1"
              >
                <li
                  :for={{wp, index} <- Enum.with_index(@active_route.waypoints)}
                  id={"waypoint-#{index}"}
                  class={[
                    "rounded-lg border px-2.5 py-1.5 transition",
                    cond do
                      @selected == index -> "border-pk-warn bg-pk-warn-dim"
                      heading_to(@hunt, @active_route) == index -> "border-pk-ok bg-pk-ok-dim"
                      true -> "border-pk-line bg-pk-sunken hover:border-pk-line-strong"
                    end
                  ]}
                >
                  <div
                    class="flex cursor-pointer items-center gap-2"
                    phx-click="select_waypoint"
                    phx-value-index={index}
                  >
                    <%!-- the hunt's place on the list, as a glyph and not only
                     a colour: the selection is already a colour --%>
                    <span
                      :if={heading_to(@hunt, @active_route) == index}
                      class="font-mono text-pk-meta text-pk-ok"
                      title="a caçada está indo pra cá"
                    >
                      ▶
                    </span>
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
                      <%!-- What the pokémon fires here, READ-ONLY: the chips
                        that change it live in the editor above, on the
                        selected waypoint. The badge only shows up where
                        there is something to say. --%>
                      <span
                        :for={{icons, labels} <- skill_badge(wp)}
                        id={"waypoint-skills-#{index}"}
                        title={labels}
                        class="ml-1 rounded border border-pk-line-strong px-1.5 py-0.5 text-pk-meta text-pk-text-2"
                      >
                        {icons}
                      </span>
                      <span
                        :if={climb_label(@active_route.waypoints, index)}
                        class="ml-1 rounded border border-pk-line-strong px-1.5 py-0.5 text-pk-meta text-pk-text-2"
                      >
                        {climb_label(@active_route.waypoints, index)}
                      </span>
                      <%!-- Same leg as the climb badge above it, by the list's
                        convention: whether THAT floor change is a staircase
                        the route describes exactly, and where its step is.
                        The full sentence rides in `title` for the mouse and
                        in `sr-only` for everyone else. --%>
                      <span
                        :for={
                          {tone, short, full} <-
                            List.wrap(stair_label(@active_route.waypoints, index))
                        }
                        id={"waypoint-stair-#{index}"}
                        title={full}
                        class={[
                          "ml-1 rounded border px-1.5 py-0.5 text-pk-meta",
                          stair_tone(tone)
                        ]}
                      >
                        <span aria-hidden="true">{short}</span>
                        <span class="sr-only">{full}</span>
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

                  <%!-- The huddle only makes sense where the pile closes.
                    Typed and SUBMITTED: the number is one he dials down
                    again and again, so it needs somewhere to click that
                    says the typing landed, the same way the park form
                    does. --%>
                  <.form
                    :if={wp.action == :lure_end}
                    id={"waypoint-gather-wait-#{index}"}
                    for={%{}}
                    phx-submit="set_waypoint_gather_wait"
                    class="mt-1 flex flex-wrap items-center gap-1 pl-7"
                  >
                    <input type="hidden" name="index" value={index} />
                    <label
                      for={"gather-wait-input-#{index}"}
                      class="font-mono text-pk-meta text-pk-text-3"
                    >
                      respiro
                    </label>
                    <input
                      type="number"
                      id={"gather-wait-input-#{index}"}
                      name="gather_wait_ms"
                      value={wp[:gather_wait_ms]}
                      min="0"
                      step="100"
                      placeholder={
                        @active_route.gather_wait_ms || Settings.get(:cavebot_gather_wait_ms)
                      }
                      class="pk-num w-20 rounded border border-pk-line-strong bg-pk-sunken px-1 py-0.5 text-pk-meta text-pk-text focus:border-pk-ok focus:outline-none"
                    />
                    <span class="font-mono text-pk-meta text-pk-text-3">ms</span>
                    <button
                      id={"waypoint-gather-wait-save-#{index}"}
                      class="cursor-pointer rounded border border-pk-line-strong px-1.5 py-0.5 font-mono text-pk-meta font-bold text-pk-text-2 transition hover:border-pk-ok/60 hover:text-white"
                    >
                      guardar
                    </button>
                    <%!-- What his hands measured, with somewhere to click that
                      adopts it: reading a number and retyping it is the
                      same work twice. `type="button"` because this sits
                      INSIDE the form — a click here is the adoption, not a
                      submit of whatever is in the field. It is the same
                      command the field sends, so it is the same event. --%>
                    <span
                      :for={ms <- gather_suggestion(wp)}
                      class="font-mono text-pk-meta text-pk-text-3"
                    >
                      (suas mãos esperaram {ms}ms aqui)
                      <button
                        type="button"
                        id={"waypoint-gather-wait-adopt-#{index}"}
                        phx-click="set_waypoint_gather_wait"
                        phx-value-index={index}
                        phx-value-gather_wait_ms={ms}
                        class="ml-1 cursor-pointer rounded border border-pk-line-strong px-1.5 py-0.5 font-mono text-pk-meta font-bold text-pk-text-2 transition hover:border-pk-ok/60 hover:text-white"
                      >
                        usar {ms}ms
                      </button>
                    </span>
                  </.form>
                </li>
              </ol>
            </section>
          </div>
        </div>

        <div :if={@mode == :watch} class="lg:shrink-0">
          <%!-- The pre-sleep checklist: whether TONIGHT's hunt survives without
            him. The three switches are the support worker's (same settings
            the panel flips); the guard is the cavebot's own. Shown HERE
            because this is the page he checks before letting it run the
            madrugada — "não podemos morrer" (2026-08-14). --%>
          <%!-- ONE ROW. This card was 360px tall with 60% of its width empty —
            two stacked forms, each with a paragraph under it, on the screen
            he needs for the route ("altos espaços vazios", 2026-08-15). The
            paragraphs became titles: they explain a knob he tunes twice a
            month, and they were costing a third of the fold every day. --%>
          <section
            id="cavebot-safety"
            class="flex flex-wrap items-center gap-x-3 gap-y-1.5 rounded-lg border border-pk-line bg-pk-surface px-3 py-1.5"
          >
            <h2 class="flex shrink-0 items-center gap-1.5 font-mono text-pk-meta font-bold uppercase tracking-[0.12em] text-pk-text-3">
              <.icon name="hero-shield-check" class="size-3.5" /> Segurança
            </h2>
            <span class="h-5 w-px shrink-0 bg-pk-line" aria-hidden="true"></span>

            <div class="flex flex-wrap items-center gap-1.5">
              <.safety_toggle
                id="safety-rescue"
                key="rescue"
                armed?={@safety.rescue?}
                icon="hero-lifebuoy"
                on="resgate armado"
                off="resgate desligado"
              />
              <.safety_toggle
                id="safety-heal"
                key="heal"
                armed?={@safety.heal?}
                icon="hero-heart"
                on="cura armada"
                off="cura desligada"
              />
              <.safety_toggle
                id="safety-potion"
                key="potion"
                armed?={@safety.potion?}
                icon="hero-beaker"
                on="poção armada"
                off="poção desligada"
              />
            </div>

            <span class="h-5 w-px shrink-0 bg-pk-line" aria-hidden="true"></span>

            <form
              id="hp-guard-form"
              phx-submit="hp_guard"
              title="Abaixo do limite: solta o combo no que juntou, desiste do mob, e só volta a andar com ele recuperado. 0 desliga a guarda. Vale a partir da próxima caçada."
              class="flex items-center gap-1.5 font-mono text-pk-meta text-pk-text-2"
            >
              <.icon name="hero-heart" class="size-3.5 shrink-0 text-pk-text-3" />
              <span>larga o mob &lt;</span>
              <input
                type="number"
                name="abort"
                value={@safety.abort_pct}
                min="0"
                max="100"
                inputmode="numeric"
                aria-label="Abandonar a mobada abaixo desta porcentagem de vida"
                class="pk-num h-8 w-14 rounded border border-pk-line-strong bg-pk-sunken px-1.5 text-center text-pk-body text-pk-text focus:border-pk-ok focus:outline-none"
              />
              <span>% · volta em</span>
              <input
                type="number"
                name="resume"
                value={@safety.resume_pct}
                min="1"
                max="100"
                inputmode="numeric"
                aria-label="Retomar a rota nesta porcentagem de vida"
                class="pk-num h-8 w-14 rounded border border-pk-line-strong bg-pk-sunken px-1.5 text-center text-pk-body text-pk-text focus:border-pk-ok focus:outline-none"
              />
              <span>%</span>
              <button
                aria-label="Salvar os limites da guarda de HP"
                class="h-8 cursor-pointer rounded border border-pk-line-strong px-2.5 font-semibold text-pk-text transition hover:border-pk-ok/60 hover:bg-pk-raised hover:text-white"
              >
                salvar
              </button>
            </form>

            <span class="h-5 w-px shrink-0 bg-pk-line" aria-hidden="true"></span>

            <form
              id="comeback-form"
              phx-submit="comeback_cfg"
              title="Só pra tropeço local — mudar de andar ou o combate recusar continua parando de vez. Chegar num waypoint devolve as tentativas. 0 desliga a volta automática."
              class="flex items-center gap-1.5 font-mono text-pk-meta text-pk-text-2"
            >
              <.icon name="hero-arrow-path" class="size-3.5 shrink-0 text-pk-text-3" />
              <span>tropeço:</span>
              <input
                type="number"
                name="retries"
                value={@safety.block_retries}
                min="0"
                max="50"
                inputmode="numeric"
                aria-label="Quantas vezes a caçada tenta voltar sozinha"
                class="pk-num h-8 w-12 rounded border border-pk-line-strong bg-pk-sunken px-1.5 text-center text-pk-body text-pk-text focus:border-pk-ok focus:outline-none"
              />
              <span>× a cada</span>
              <input
                type="number"
                name="wait_s"
                value={div(@safety.block_retry_ms, 1000)}
                min="1"
                max="600"
                inputmode="numeric"
                aria-label="Quantos segundos ela espera antes de tentar voltar"
                class="pk-num h-8 w-14 rounded border border-pk-line-strong bg-pk-sunken px-1.5 text-center text-pk-body text-pk-text focus:border-pk-ok focus:outline-none"
              />
              <span>s</span>
              <button
                aria-label="Salvar as tentativas de volta da caçada"
                class="h-8 cursor-pointer rounded border border-pk-line-strong px-2.5 font-semibold text-pk-text transition hover:border-pk-ok/60 hover:text-white"
              >
                salvar
              </button>
            </form>

            <span
              :if={is_nil(@world.me.hp_pct)}
              id="safety-no-reading"
              class="ml-auto font-mono text-pk-meta text-pk-warn"
            >
              sem leitura de vida — a guarda e o resgate não enxergam o pokémon
            </span>
          </section>
        </div>
      </div>

      <%!-- BELOW THE FOLD, and deliberately: the reading of the engine and the
           three instruments are what he opens when he is deciding a rule, not
           what he watches while the hunt runs. They cost nothing closed and
           they were costing a third of the screen open. --%>
      <div :if={@mode == :watch} class="mt-3 space-y-3">
        <%!-- …and what the engine MAKES of all that. The tiles above are facts;
            this line is the reading of them, which until now only existed
            inside a process. It says what WOULD happen — nobody obeys it
            yet — and the feed below carries the same sentence beside what
            the bot actually did. --%>
        <.engine_brain
          situation={@situation}
          orders={@orders}
          gather_piles={@gather_piles}
          reset_revive={@reset_revive}
        />

        <details id="cavebot-instruments" class="rounded-lg border border-pk-line bg-pk-surface">
          <summary class="cursor-pointer list-none px-3 py-2 font-mono text-pk-meta font-bold uppercase tracking-[0.12em] text-pk-text-3">
            Instrumentos ▸
          </summary>
          <div class="space-y-3 px-3 pb-3">
            <%!-- ONDE ELES ESTÃO. A lista de batalha sempre soube QUANTOS existem;
            o que faltava era a distância — "não adianta a gente otimizar ele
            ter mais cooldowns pra usar com Revives se ele não espera os
            pokémons estarem próximos" (2026-08-26).

            Isto é LEITURA: não manda em nada, e está aqui pra ele julgar se
            merece virar regra. --%>
            <section id="cavebot-crowd" class="rounded-pk border border-pk-line bg-pk-surface p-3">
              <div class="flex flex-wrap items-center gap-2">
                <h3 class="text-pk-sm font-semibold text-pk-text-1">onde eles estão</h3>
                <button
                  type="button"
                  phx-click="crowd_scan"
                  class="rounded border border-pk-line px-2 py-0.5 text-pk-meta text-pk-text-2 hover:bg-pk-surface-2"
                >
                  olhar agora
                </button>
                <span class="text-pk-meta text-pk-text-3">
                  custa uma foto da tela (~0,3s) — só quando você pede
                </span>
              </div>

              <p :if={@crowd == nil} class="mt-2 text-pk-meta text-pk-text-3">
                ninguém olhou ainda
              </p>

              <p :if={@crowd && !@crowd.read?} class="mt-2 text-pk-meta text-pk-warn">
                não deu pra olhar: {crowd_reason(@crowd.reason)}
              </p>

              <div :if={@crowd && @crowd.read?} class="mt-2">
                <p class="text-pk-sm text-pk-text-1">{crowd_headline(@crowd)}</p>
                <p class="mt-0.5 font-mono text-pk-meta text-pk-text-3">
                  {crowd_spread(@crowd)} · {crowd_anchor(@crowd.anchor)}
                </p>

                <%!-- A PROVA. Um número não diz se errou o detector, a âncora ou a
                régua — três bugs diferentes, um "2" indistinguível. Aqui dá
                pra ver: caixa azul é hostil, verde é o pokémon dele, e a cruz
                rosa é o ponto de onde a distância foi medida. --%>
                <img
                  :if={@crowd.evidence}
                  src={@crowd.evidence}
                  alt="o que a leitura enxergou"
                  class="mt-2 w-full max-w-2xl rounded border border-pk-line"
                />
                <p :if={@crowd.evidence} class="mt-1 text-pk-meta text-pk-text-3">
                  caixa azul = hostil · verde = seu pokémon · cruz rosa = de onde mediu
                </p>
              </div>

              <%!-- QUANTO A ÁREA ALCANÇA. O simulador resolve todo disparo de área
              com `aoe_radius: 4`, debaixo de um comentário que diz que o
              número foi inventado — e é ele que faz TODOS os knobs de
              posicionamento darem chapado na bancada. O outro número
              inventado daquele arquivo era um cooldown de 8s; o vídeo dele
              mediu 45s. --%>
              <div class="mt-3 border-t border-pk-line pt-3">
                <div class="flex flex-wrap items-center gap-2">
                  <h4 class="text-pk-sm font-semibold text-pk-text-1">o alcance da área</h4>
                  <button
                    type="button"
                    phx-click="toggle_area_probe"
                    class={[
                      "rounded border px-2 py-0.5 text-pk-meta",
                      if(@area_probe?,
                        do: "border-pk-ok text-pk-ok",
                        else: "border-pk-line text-pk-text-2 hover:bg-pk-surface-2"
                      )
                    ]}
                  >
                    {if @area_probe?, do: "medindo — clique pra parar", else: "medir durante a caçada"}
                  </button>
                  <button
                    :if={@area}
                    type="button"
                    phx-click="refresh_area_probe"
                    class="rounded border border-pk-line px-2 py-0.5 text-pk-meta text-pk-text-2 hover:bg-pk-surface-2"
                  >
                    atualizar
                  </button>
                  <button
                    :if={@area}
                    type="button"
                    phx-click="clear_area_probe"
                    class="rounded border border-pk-line px-2 py-0.5 text-pk-meta text-pk-text-3 hover:bg-pk-surface-2"
                  >
                    zerar
                  </button>
                </div>

                <p :if={@area_probe?} class="mt-1 text-pk-meta text-pk-text-3">
                  custa uma foto a cada disparo de área — ligue por uma caçada, não deixe ligado
                </p>

                <p :if={@area == nil} class="mt-2 text-pk-meta text-pk-text-3">
                  nenhum disparo medido ainda
                </p>

                <div :if={@area} class="mt-2">
                  <p class="text-pk-sm text-pk-text-1">{area_headline(@area)}</p>
                  <p class="mt-0.5 font-mono text-pk-meta text-pk-text-3">{area_spread(@area)}</p>
                  <%!-- O confundidor, escrito onde ele lê o número: número de dano
                  não diz QUEM causou. Nos quadros do vídeo dele os disparos de
                  outros jogadores apareciam como um segundo grupo, de 7 a 17
                  tiles — só inflam, nunca encolhem. --%>
                  <p class="mt-1 flex items-start gap-1.5 text-pk-meta text-pk-warn">
                    <.icon name="hero-users" class="mt-px size-3.5 shrink-0" />
                    <span>
                      o dano de outro jogador na tela conta junto e só ESTICA o alcance — se o topo
                      estiver muito acima da mediana, é isso
                    </span>
                  </p>
                </div>
              </div>

              <%!-- QUANTO CADA TECLA TIRA, e quanto demora. Ideia dele inteira:
              "ele e um inimigo de vida cheia, o sistema usa uma skill e
              calcula a diferença e salva essa diferença associada a essa
              skill... se ele se identificar aqui com a skill 4 sozinha, ele já
              mata, não precisa ficar usando 4, 5, 6 sempre". --%>
              <div class="mt-3 border-t border-pk-line pt-3">
                <div class="flex flex-wrap items-center gap-2">
                  <h4 class="text-pk-sm font-semibold text-pk-text-1">o que cada tecla tira</h4>
                  <button
                    type="button"
                    phx-click="toggle_skill_meter"
                    class={[
                      "rounded border px-2 py-0.5 text-pk-meta",
                      if(@meter?,
                        do: "border-pk-ok text-pk-ok",
                        else: "border-pk-line text-pk-text-2 hover:bg-pk-surface-2"
                      )
                    ]}
                  >
                    {if @meter?, do: "medindo — clique pra parar", else: "medir durante a caçada"}
                  </button>
                  <button
                    :if={@meter != %{}}
                    type="button"
                    phx-click="refresh_skill_meter"
                    class="rounded border border-pk-line px-2 py-0.5 text-pk-meta text-pk-text-2 hover:bg-pk-surface-2"
                  >
                    atualizar
                  </button>
                  <button
                    :if={@meter != %{}}
                    type="button"
                    phx-click="clear_skill_meter"
                    class="rounded border border-pk-line px-2 py-0.5 text-pk-meta text-pk-text-3 hover:bg-pk-surface-2"
                  >
                    zerar
                  </button>
                </div>

                <p :if={@meter?} class="mt-1 text-pk-meta text-pk-text-3">
                  só mede apertos de UMA tecla — uma rajada de três tira uma queda só e ninguém
                  sabe de quem foi
                </p>

                <p :if={@meter == %{}} class="mt-2 text-pk-meta text-pk-text-3">
                  nenhuma tecla medida ainda
                </p>

                <table :if={@meter != %{}} class="mt-2 w-full font-mono text-pk-meta">
                  <thead class="text-pk-text-3">
                    <tr>
                      <th class="text-left font-normal">tecla</th>
                      <th class="text-right font-normal">tira</th>
                      <th class="text-right font-normal">demora</th>
                      <th class="text-right font-normal">pra matar</th>
                      <th class="text-right font-normal">amostras</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={{key, m} <- Enum.sort_by(@meter, &elem(&1, 0))} class="text-pk-text-2">
                      <td class="text-left">{key}</td>
                      <td class="text-right">{m.took_pct}%</td>
                      <td class="text-right">{m.delay_ms}ms</td>
                      <td class="text-right">{m.to_kill || "—"}×</td>
                      <td class={["text-right", if(m.shots < 5, do: "text-pk-warn")]}>{m.shots}</td>
                    </tr>
                  </tbody>
                </table>

                <%!-- As duas coisas que o número NÃO sabe, onde ele lê o número. --%>
                <p :if={@meter != %{}} class="mt-1 flex items-start gap-1.5 text-pk-meta text-pk-warn">
                  <.icon name="hero-exclamation-triangle" class="mt-px size-3.5 shrink-0" />
                  <span>
                    é MEDIANA: o dano de outro jogador na mesma linha entra na conta. E poucas
                    amostras (em amarelo) não merecem a mesma fé que muitas.
                  </span>
                </p>

                <%!-- O ponto cego, escrito onde ele lê o número: efeito de skill
                pinta por cima do nome, então some quem está DENTRO da área.
                Erra sempre pra menos. --%>
                <p
                  :if={crowd_gap(@crowd) > 0}
                  class="mt-1 flex items-start gap-1.5 text-pk-meta text-pk-warn"
                >
                  <.icon name="hero-eye-slash" class="mt-px size-3.5 shrink-0" />
                  <span>
                    a lista tem {@crowd.listed} e eu localizei {@crowd.seen} — {crowd_gap(@crowd)} sem nome legível (efeito na tela cobre o nome, ou está fora do alcance da vista)
                  </span>
                </p>
              </div>
            </section>
          </div>
        </details>
      </div>
    </Layouts.app>
    """
  end

  # THE TWO MODES, as one control. A link and not a button: the mode belongs in
  # the URL so a reload — and the tab he leaves open all night — comes back
  # where he left it.
  attr :mode, :atom, required: true

  defp mode_tabs(assigns) do
    ~H"""
    <nav
      id="cavebot-modes"
      class="flex items-center gap-1 rounded-lg border border-pk-line bg-pk-sunken p-0.5"
    >
      <.link
        :for={
          {mode, label, icon} <- [
            {:watch, "assistir", "hero-eye"},
            {:edit, "editar", "hero-pencil-square"}
          ]
        }
        id={"cavebot-mode-#{mode}"}
        patch={if mode == :watch, do: ~p"/cavebot", else: ~p"/cavebot?modo=editar"}
        aria-current={if @mode == mode, do: "page"}
        class={[
          "flex cursor-pointer items-center gap-1.5 rounded px-2.5 py-1 font-mono text-pk-meta font-bold uppercase tracking-[0.12em] transition",
          if(@mode == mode,
            do: "bg-pk-ok-dim text-pk-ok",
            else: "text-pk-text-3 hover:bg-pk-raised hover:text-pk-text"
          )
        ]}
      >
        <.icon name={icon} class="size-3.5" /> {label}
      </.link>
    </nav>
    """
  end

  # EVERYTHING THAT MAKES A READING WRONG, in one place and above both modes.
  # These are conditional by nature: when one is up it pushes the rest of the
  # page down, which is the correct price for the loudest fact on the screen.
  attr :minimap_gap?, :boolean, required: true
  attr :hunt, :map, required: true
  attr :sim_armed?, :boolean, required: true
  attr :world, :map, required: true
  attr :routes, :list, required: true
  attr :active_route, :any, required: true
  attr :notice, :any, required: true
  attr :notice_kind, :atom, required: true

  defp hunt_alerts(assigns) do
    ~H"""
    <%!-- OS OLHOS ESTÃO DESLIGADOS. A cerca do simulador aponta os feeds pro
          mundo falso de propósito — e o resultado, nesta página, é que NADA
          chega: ela renderiza uma vez e congela. Foi assim que ele andou uma
          rota inteira achando que gravava, olhando pra uma coordenada de uma
          hora antes (26/08). O aviso vem antes de tudo porque enquanto ele
          estiver de pé, todo o resto da página é ficção. --%>
    <section
      :if={@sim_armed?}
      id="cavebot-sim-armed"
      class="rounded-pk border border-pk-danger bg-pk-danger/10 p-3"
    >
      <p class="flex items-start gap-2 text-pk-sm font-semibold text-pk-danger">
        <.icon name="hero-eye-slash" class="mt-px size-4 shrink-0" />
        <span>
          o simulador está armado — os olhos do bot estão apontados pro mundo falso
        </span>
      </p>
      <p class="mt-1 text-pk-meta text-pk-text-2">
        nada nesta página está sendo lido do jogo: a posição, os inimigos e a vida são do
        momento em que você abriu. Gravar rota não grava nada.
        <.link navigate={~p"/sim"} class="underline">Desarme no simulador</.link>
        pra voltar a enxergar.
      </p>
    </section>

    <section
      :if={@minimap_gap?}
      id="cavebot-minimap-gap"
      class="rounded-lg border border-pk-warn-line bg-pk-warn-dim p-3"
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

    <%!-- A STOPPED hunt is this page's loudest fact, and it lived in a
          tile's small print: "parou POR QUÊ" needs no hunting of its own.
          Three states, three tones — and the middle one only exists because
          a hunt that is about to fix itself must not read like one asking
          to be rescued (`comeback?`). --%>
    <section
      :if={@hunt && @hunt.state == :blocked && !@hunt[:comeback?]}
      id="cavebot-blocked"
      class="rounded-lg border border-pk-danger-line bg-pk-danger-dim p-3"
    >
      <p class="flex items-center gap-2 text-pk-body font-bold text-pk-danger">
        <.icon name="hero-hand-raised" class="size-4" /> A caçada parou e não volta sozinha
      </p>
      <p class="mt-1 text-pk-body text-pk-text-2">
        {@hunt.hold_reason || "bloqueada sem motivo escrito"} — resolva e solte a caçada de
        novo no painel.
      </p>
    </section>

    <section
      :if={@hunt && @hunt.state == :blocked && @hunt[:comeback?]}
      id="cavebot-comeback"
      class="rounded-lg border border-pk-warn-line bg-pk-warn-dim p-3"
    >
      <p class="flex items-center gap-2 text-pk-body font-bold text-pk-warn">
        <.icon name="hero-arrow-path" class="size-4" /> A caçada tropeçou — e vai tentar de novo
      </p>
      <p class="mt-1 text-pk-body text-pk-text-2">
        {@hunt.hold_reason || "parada sem motivo escrito"}. Ela reentra pelo canto mais perto;
        se as tentativas acabarem, aí sim precisa de você.
      </p>
    </section>

    <section
      :if={@hunt && @hunt.state != :blocked && @hunt.hold_reason}
      id="cavebot-held"
      class="rounded-lg border border-pk-warn-line bg-pk-warn-dim p-3"
    >
      <p class="flex items-center gap-2 text-pk-body font-bold text-pk-warn">
        <.icon name="hero-pause-circle" class="size-4" /> A caçada está esperando
      </p>
      <p class="mt-1 text-pk-body text-pk-text-2">{@hunt.hold_reason}</p>
    </section>

    <%!-- UM DÍGITO QUE O ATLAS NÃO TEM não vira "não sei ler": vira OUTRO
          dígito. A regra da margem do casador compara o que está no atlas
          com o que está no atlas, e não tem como perceber que o certo nunca
          esteve na disputa.

          Em 27/08 o jogo dele mostrava `1088, 1409, 5` e o painel `1066,
          1409` — e a rota gravada saltava pro outro lado do mapa. Só
          aparece pela fonte que ESTA faixa usa: o atlas tem buraco em cinco
          alturas, e quatro delas ele nunca lê. --%>
    <section
      :if={@world.coord_gap}
      id="cavebot-glifos"
      class="rounded-pk border border-pk-danger bg-pk-danger/10 p-3"
    >
      <p class="flex items-start gap-2 text-pk-sm font-semibold text-pk-danger">
        <.icon name="hero-hashtag" class="mt-px size-4 shrink-0" />
        <span>
          a fonte da sua coordenada não tem
          <span class="font-mono">{Enum.join(@world.coord_gap.faltam, " ")}</span>
          no atlas — o número pode vir ERRADO, não vazio
        </span>
      </p>
      <p class="mt-1 text-pk-meta text-pk-text-2">
        a faixa que o bot lê é desenhada com {@world.coord_gap.px}px de altura, e nessa altura {gap_words(
          @world.coord_gap.faltam
        )} nunca foi ensinado. Um dígito que falta casa com o
        mais parecido que existe, e casa com folga — o certo não entra na disputa. Ensine na <.link
          navigate={~p"/calibration"}
          class="underline"
        >calibração</.link>, digitando a
        coordenada que está na tela.
      </p>
    </section>

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
    """
  end

  # THE DRAWING, and only the drawing. It is the one thing on this page that
  # must never be scrolled to, so it is a card of its own in both modes, and
  # `fill?` says which way it is measured.
  #
  # Watching, the card takes the left column whole and the square is measured by
  # its HEIGHT — that is the whole trick. `.route_map` is `aspect-square w-full`,
  # so a width cap is the only lever it offers, and any cap written in `dvh` is
  # a guess about how much of the screen the strips above happen to be using
  # today. Measured at 1440×800: with the "minimapa não calibrado" banner up the
  # drawing lands at 490px, and with it gone it grows to 567px on its own, both
  # times with the safety strip still on screen. A guessed cap gets exactly one
  # of those two right.
  #
  # Editing, the card shares the column with the corner's controls and the map
  # is deliberately the smaller half, so there the width cap is right.
  attr :active_route, :any, required: true
  attr :pos, :any, required: true
  attr :selected, :any, required: true
  attr :hunt, :any, required: true
  attr :recording?, :boolean, required: true
  attr :fill?, :boolean, default: false

  defp route_map_card(assigns) do
    ~H"""
    <section
      id="cavebot-map"
      class={[
        "flex flex-col rounded-lg border border-pk-line bg-pk-surface p-3",
        if(@fill?, do: "lg:min-h-0 lg:flex-1", else: "lg:shrink-0")
      ]}
    >
      <div class="flex flex-wrap items-center justify-between gap-2">
        <h2 class="font-mono text-pk-meta font-bold uppercase tracking-[0.12em] text-pk-text-3">
          {if @active_route, do: "Mapa de #{@active_route.name}", else: "Mapa"}
        </h2>
        <span
          :if={@active_route && @active_route.waypoints != []}
          class="font-mono text-pk-meta text-pk-text-2"
        >
          {floors_label(@active_route)}
        </span>
      </div>

      <div class={[
        "mt-2",
        if(@fill?,
          do: "grid min-h-0 flex-1 place-items-center",
          else: "mx-auto w-full max-w-[min(100%,40dvh)]"
        )
      ]}>
        <div class={@fill? && "aspect-square h-full max-w-full"}>
          <.route_map
            floor={map_floor(@active_route, @pos)}
            waypoints={(@active_route && @active_route.waypoints) || []}
            pos={@pos}
            selected={@selected}
            heading_to={heading_to(@hunt, @active_route)}
            recording?={@recording?}
          />
        </div>
      </div>
    </section>
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
