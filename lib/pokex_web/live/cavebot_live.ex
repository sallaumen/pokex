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

  alias Pokex.Bots.Cavebot.{Photos, Route, Store, WalkTest, Worker}
  alias Pokex.Calibration
  alias Pokex.Perception
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
       walk_ref: nil
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

    if socket.assigns.recording? and pos != nil and socket.assigns.active_route,
      do: {:noreply, maybe_record(socket, pos)},
      else: {:noreply, socket}
  end

  # Every other fact (battle above all: how many enemies are on screen) refreshes
  # the world strip without touching the recording.
  def handle_info({:world, _key, _obs}, socket),
    do: {:noreply, assign(socket, world: World.snapshot())}

  def handle_info({:cavebot, snapshot}, socket), do: {:noreply, assign(socket, hunt: snapshot)}

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

  def handle_info(_msg, socket), do: {:noreply, socket}

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
    {:ok, updated} = Route.append(route, pos)
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
        {:ok, updated} = Route.append(socket.assigns.active_route, pos)
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
         assign(socket,
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
         assign(socket,
           recording?: true,
           notice: "gravando — volte pro jogo e ande a rota; eu marco sozinho",
           notice_kind: :ok
         )}
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

    with_route(socket, fn route ->
      on? = stop not in Route.stops_at(route.waypoints, index)

      {Route.set_stop(route, index, stop, on?),
       "waypoint #{index + 1}: #{stop_label(stop)} #{if on?, do: "ligado", else: "desligado"}"}
    end)
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
    case World.snapshot().pos do
      nil ->
        {:noreply, assign(socket, notice: "não estou lendo tua posição", notice_kind: :warn)}

      pos ->
        with_route(socket, &insert_here(&1, String.to_integer(index), pos))
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

  # The photos are a SIDE EFFECT of recording, never a gate on it: a failed
  # screenshot must not cost a waypoint. The game is brought forward for the
  # shot exactly like the calibration does, then the browser comes back.
  defp photo(%{assigns: %{active_route: %Route{name: name}}}, kind) do
    Task.start(fn -> Photos.take(name, kind) end)
  end

  defp photo(_no_route, _kind), do: :ok

  defp insert_here(route, index, pos) do
    {:ok, updated} = Route.insert_at(route, index, pos)
    {updated, "waypoint inserido na posição #{index + 1}"}
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
      :end_without_start -> "tem \"até aqui\" sem \"mobar daqui\" — essa marca não faz nada"
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
    <Layouts.app flash={@flash} current_page={:cavebot} {Layouts.header(assigns)}>
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

        <div class="grid gap-4 lg:grid-cols-[minmax(0,1fr)_minmax(0,1.1fr)]">
          <%!-- LEFT: the drawing + the recorder that feeds it --%>
          <div class="space-y-4">
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

              <div class="mt-3">
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

                  <%!-- The job lives on the SELECTED waypoint only: fourteen rows
                       each carrying three more buttons is a wall, and the choice
                       is rare — you mark a mob stretch once and hunt it for
                       weeks. --%>
                  <div
                    :if={@selected == index}
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
