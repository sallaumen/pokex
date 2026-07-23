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
  through `Cavebot.Store` (same name = replace), and the floor invariant lives
  in `Route.append/2` — this page only translates its `:floor_mismatch` into
  words.
  """
  use PokexWeb, :live_view

  alias Pokex.Bots.Cavebot.{Route, Store}
  alias Pokex.Perception
  alias Pokex.World

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Pokex.PubSub, Perception.topic())
      # the minimap feed only captures while someone is attached — the
      # recording page IS that someone, exactly while it is open
      Perception.attach(:minimap)
    end

    routes = Store.all()

    {:ok,
     assign(socket,
       page_title: "Cavebot",
       routes: routes,
       active_route: default_active(routes),
       pos: World.snapshot().pos,
       notice: nil,
       notice_kind: :warn
     )}
  end

  # Every minimap publish refreshes the position readout; other facts are
  # irrelevant here and fall through.
  @impl true
  def handle_info({:world, :minimap, _obs}, socket) do
    {:noreply, assign(socket, pos: World.snapshot().pos)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

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
           notice: "ainda não li tua posição — o jogo está em foco no monitor principal?",
           notice_kind: :warn,
           pos: nil
         )}

      {route, pos} ->
        case Route.append(route, pos) do
          {:ok, updated} ->
            :ok = Store.add(updated)

            {:noreply,
             socket
             |> assign(
               notice: "waypoint #{length(updated.waypoints)} marcado (andar #{updated.z})",
               notice_kind: :ok,
               pos: pos
             )
             |> reload_routes(updated.name)}

          {:error, :floor_mismatch} ->
            {:noreply,
             assign(socket,
               notice:
                 "essa posição é de outro andar — a rota \"#{route.name}\" é do andar #{route.z}",
               notice_kind: :warn,
               pos: pos
             )}
        end
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

  defp reload_routes(socket, active_name) do
    routes = Store.all()
    active = Enum.find(routes, &(&1.name == active_name)) || default_active(routes)
    assign(socket, routes: routes, active_route: active)
  end

  defp default_active(routes), do: Enum.find(routes, & &1.enabled?)

  defp pos_text(nil), do: "?"
  defp pos_text({x, y, z}), do: "#{x}, #{y} · andar #{z}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_page={:cavebot}>
      <div class="space-y-4">
        <header>
          <h1 class="text-xl font-bold">Cavebot — rotas</h1>
          <p class="mt-1 text-sm opacity-70">
            Grave a rota andando: escolha (ou crie) uma rota, ande no jogo e
            marque um waypoint em cada canto do caminho. A rota é de um andar
            só — waypoints de outro andar são recusados.
          </p>
        </header>

        <section id="cavebot-recorder" class="rounded-lg border border-pk-line bg-pk-surface p-4">
          <div class="flex flex-wrap items-center justify-between gap-3">
            <div>
              <p class="font-mono text-pk-meta uppercase text-pk-text-3">Posição atual</p>
              <p id="cavebot-pos" class="font-mono text-sm text-pk-text">{pos_text(@pos)}</p>
            </div>
            <button
              id="mark-waypoint"
              phx-click="mark_waypoint"
              aria-label="Marcar waypoint na posição atual"
              class="cursor-pointer rounded-lg border-0 bg-pk-ok px-4 py-2 text-pk-body font-bold text-pk-ok-dim transition hover:brightness-110"
            >
              Marcar waypoint aqui
            </button>
          </div>
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
              class="h-9 rounded border border-pk-line-strong bg-pk-sunken px-2 font-mono text-sm text-pk-text focus:border-pk-ok focus:outline-none"
            >
              <option
                :for={route <- @routes}
                value={route.name}
                selected={@active_route != nil and route.name == @active_route.name}
              >
                {route.name}{if route.dungeon, do: " · #{route.dungeon}"}
              </option>
            </select>
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
              class="h-9 w-44 rounded border border-pk-line-strong bg-pk-sunken px-2 font-mono text-sm text-pk-text focus:border-pk-ok focus:outline-none"
            />
            <input
              name="dungeon"
              placeholder="dungeon (opcional)"
              autocomplete="off"
              aria-label="Dungeon da nova rota"
              class="h-9 w-44 rounded border border-pk-line-strong bg-pk-sunken px-2 font-mono text-sm text-pk-text focus:border-pk-ok focus:outline-none"
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
          <div class="flex items-baseline justify-between gap-2">
            <h2 class="font-mono text-pk-meta font-bold uppercase tracking-[0.12em] text-pk-text-3">
              Waypoints de {@active_route.name}
            </h2>
            <span :if={@active_route.z} class="font-mono text-pk-meta text-pk-text-2">
              andar {@active_route.z}
            </span>
          </div>

          <p :if={@active_route.waypoints == []} class="mt-3 text-pk-body text-pk-text-2">
            nenhum waypoint ainda — ande até o primeiro canto e marque
          </p>

          <ol :if={@active_route.waypoints != []} class="mt-3 space-y-1.5">
            <li
              :for={{wp, index} <- Enum.with_index(@active_route.waypoints)}
              id={"waypoint-#{index}"}
              class="flex items-center gap-3 rounded-lg border border-pk-line bg-pk-sunken px-3 py-2"
            >
              <span class="font-mono text-pk-meta text-pk-text-3">{index + 1}</span>
              <span class="flex-1 font-mono text-sm text-pk-text">{wp.x}, {wp.y}</span>
              <button
                id={"waypoint-delete-#{index}"}
                phx-click="delete_waypoint"
                phx-value-index={index}
                data-confirm={"Apagar o waypoint #{index + 1} (#{wp.x}, #{wp.y})?"}
                aria-label={"Apagar waypoint #{index + 1}"}
                class="cursor-pointer font-mono text-pk-meta text-pk-text-2 transition hover:text-pk-danger"
              >
                apagar
              </button>
            </li>
          </ol>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
