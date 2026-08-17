defmodule PokexWeb.SimLive do
  @moduledoc """
  The simulator: one of his real routes, played out in a world that is not the
  game, with the REAL engine deciding over it.

  The reason this screen exists is the one thing the game can never show him:
  **truth next to perception**. In the PXG window there is no way to compare
  what was on screen with what the bot read, so a bad decision is always two
  suspects at once. Here the two lists sit side by side — when they differ the
  bug is in the eyes, and when they agree and the decision is still wrong the
  bug is in the brain.

  It is playable on purpose. The arrows walk, the number keys fire, and the
  engine's card narrates every decision as it happens: a hypothesis about the
  ruler costs seconds here instead of a night of hunting.
  """
  use PokexWeb, :live_view

  alias Pokex.Bots.Cavebot.Store
  alias Pokex.Bots.Engine
  alias Pokex.Perception.WorldState
  alias Pokex.Sim.Fence
  alias Pokex.Sim.Runner
  alias Pokex.Sim.Scenario

  @directions %{
    "ArrowRight" => "right",
    "ArrowLeft" => "left",
    "ArrowUp" => "up",
    "ArrowDown" => "down"
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Pokex.PubSub, Runner.topic())
      Phoenix.PubSub.subscribe(Pokex.PubSub, Engine.Worker.topic())
    end

    routes = Enum.filter(Store.all(), &(&1.waypoints != []))

    {:ok,
     socket
     |> assign(
       page_title: "Simulador",
       current_page: :sim,
       routes: routes,
       route_name: pick_default(routes),
       world: Runner.world(),
       playing?: Runner.playing?(),
       armed?: Fence.armed?(),
       picture: nil,
       orders: nil,
       refusal: nil,
       floor: nil,
       scenarios: Scenario.all(),
       scenario: Runner.scenario()
     )}
  end

  @impl true
  def handle_event("arm", _params, socket) do
    case Fence.arm() do
      :ok ->
        Engine.Worker.run()
        {:noreply, socket |> assign(armed?: true, refusal: nil) |> load_route()}

      {:error, names} ->
        {:noreply, assign(socket, refusal: refusal_text(names))}
    end
  end

  def handle_event("disarm", _params, socket) do
    Runner.pause()
    Engine.Worker.halt()
    Fence.disarm()

    {:noreply, assign(socket, armed?: false, playing?: false, picture: nil, orders: nil)}
  end

  def handle_event("play", _params, socket) do
    Runner.play()
    {:noreply, assign(socket, playing?: true)}
  end

  def handle_event("pause", _params, socket) do
    Runner.pause()
    {:noreply, assign(socket, playing?: false)}
  end

  def handle_event("pick-route", %{"route" => name}, socket) do
    {:noreply, socket |> assign(route_name: name) |> load_route()}
  end

  def handle_event("reload", _params, socket) do
    if socket.assigns.scenario,
      do: {:noreply, load_scenario(socket, socket.assigns.scenario.id)},
      else: {:noreply, load_route(socket)}
  end

  def handle_event("pick-scenario", %{"scenario" => ""}, socket) do
    {:noreply, socket |> assign(scenario: nil) |> load_route()}
  end

  def handle_event("pick-scenario", %{"scenario" => id}, socket),
    do: {:noreply, load_scenario(socket, id)}

  # The hands, from HIS keyboard instead of from the bot's. The world cannot
  # tell the difference, which is the whole point: the same press that the
  # cavebot would have made walks the same tile.
  def handle_event("keydown", %{"key" => key}, socket) do
    send_key(socket, key, :down)
    {:noreply, socket}
  end

  def handle_event("keyup", %{"key" => key}, socket) do
    send_key(socket, key, :up)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:sim, world}, socket), do: {:noreply, assign(socket, world: world)}

  def handle_info({:engine, picture, orders}, socket),
    do: {:noreply, assign(socket, picture: picture, orders: orders)}

  def handle_info(_ignored, socket), do: {:noreply, socket}

  defp pick_default([]), do: nil
  defp pick_default(routes), do: (Enum.find(routes, &(&1.name =~ "Meganium")) || hd(routes)).name

  defp load_route(%{assigns: %{route_name: nil}} = socket), do: socket

  defp load_route(socket) do
    case Enum.find(socket.assigns.routes, &(&1.name == socket.assigns.route_name)) do
      nil ->
        socket

      route ->
        Runner.load(route, knobs: %{})
        assign(socket, world: Runner.world(), floor: nil)
    end
  end

  defp load_scenario(socket, id) do
    case Scenario.get(id) do
      nil ->
        socket

      scenario ->
        Runner.load_scenario(scenario, socket.assigns.routes)
        assign(socket, scenario: scenario, world: Runner.world(), floor: nil)
    end
  end

  defp failures(nil), do: []
  defp failures(world), do: Enum.map(world.failures, &failure_label/1)

  defp failure_label(:blind), do: "tela ilegível"
  defp failure_label(:mini_game), do: "mini-game na tela"
  defp failure_label({:dead_key, key}), do: "tecla #{key} não sai"
  defp failure_label({:hp, pct}), do: "vida forçada em #{pct}%"
  defp failure_label(other), do: to_string(other)

  defp send_key(%{assigns: %{armed?: false}}, _key, _direction), do: :ok

  defp send_key(_socket, key, direction) do
    case {Map.get(@directions, key), direction} do
      {nil, :down} -> if key in ~w(1 2 3 4 5 6 7 8 9), do: rig_send({:press, key})
      {nil, :up} -> :ok
      {arrow, :down} -> rig_send({:key_down, arrow})
      {arrow, :up} -> rig_send({:key_up, arrow})
    end
  end

  # Goes through the same door the fleet's keys go through, so a key typed here
  # and a key the cavebot presses are indistinguishable to the world.
  defp rig_send(action) do
    case Process.whereis(Runner) do
      nil -> :ok
      pid -> send(pid, {:sim_rig, action})
    end
  end

  defp refusal_text(names) do
    "não dá pra armar com #{Enum.map_join(names, ", ", &to_string/1)} rodando — pare a frota primeiro"
  end

  defp fact(key) do
    case WorldState.get(key, 5_000, System.monotonic_time(:millisecond)) do
      {:ok, obs} -> obs
      _stale_or_missing -> nil
    end
  end

  # The visible floor follows the character: a map drawn with every floor at once
  # is a map of nowhere.
  defp floor_of(%{pos: {_x, _y, z}}), do: z
  defp floor_of(_no_world), do: nil

  defp legs(nil, _z), do: []

  defp legs(world, z) do
    world.route.waypoints
    |> Enum.filter(&(&1.z == z))
    |> Enum.map(&{&1.x, &1.y, nest?(&1)})
  end

  defp nest?(waypoint), do: waypoint[:gather_ms] != nil or waypoint[:fight_ms] != nil

  defp bounds(points) do
    xs = Enum.map(points, &elem(&1, 0))
    ys = Enum.map(points, &elem(&1, 1))
    pad = 8

    {Enum.min(xs, fn -> 0 end) - pad, Enum.min(ys, fn -> 0 end) - pad,
     Enum.max(xs, fn -> 1 end) - Enum.min(xs, fn -> 0 end) + pad * 2,
     Enum.max(ys, fn -> 1 end) - Enum.min(ys, fn -> 0 end) + pad * 2}
  end

  defp visible_mobs(nil, _z), do: []
  defp visible_mobs(world, z), do: Enum.filter(world.mobs, fn m -> elem(m.pos, 2) == z end)

  defp truth_rows(nil), do: []

  defp truth_rows(world) do
    Enum.map(world.mobs, fn mob ->
      %{name: mob.name, hp_pct: mob.hp_pct, pos: mob.pos, leash: leash_left(mob, world)}
    end)
  end

  defp leash_left(mob, world) do
    {sx, sy, _sz} = mob.spawn
    {mx, my, _mz} = mob.pos
    world.knobs.leash_tiles - max(abs(mx - sx), abs(my - sy))
  end

  defp perceived_rows(nil), do: :unread
  defp perceived_rows(%{enemies: nil}), do: :unread
  defp perceived_rows(%{enemies_detail: detail}), do: detail

  defp band_class(:green), do: "text-emerald-300"
  defp band_class(:yellow), do: "text-amber-300"
  defp band_class(:red), do: "text-rose-300"
  defp band_class(_unknown), do: "text-zinc-400"

  @impl true
  def render(assigns) do
    z = floor_of(assigns.world)
    points = legs(assigns.world, z)

    assigns =
      assign(assigns,
        z: z,
        points: points,
        view_box: bounds(points ++ character_point(assigns.world)),
        mobs: visible_mobs(assigns.world, z),
        truth: truth_rows(assigns.world),
        perceived: perceived_rows(fact(:battle)),
        pokemon_fact: fact(:pokemon),
        hunt_fact: fact(:hunt)
      )

    ~H"""
    <Layouts.app flash={@flash} current_page={:sim} {Layouts.header(assigns)}>
      <div
        id="sim-board"
        phx-window-keydown="keydown"
        phx-window-keyup="keyup"
        class="space-y-4"
      >
        <div class="flex flex-wrap items-center gap-3 rounded-xl border border-zinc-800 bg-zinc-900/60 p-3">
          <form phx-change="pick-route" class="flex items-center gap-2">
            <select
              name="route"
              class="rounded-lg border border-zinc-700 bg-zinc-950 px-3 py-1.5 text-sm text-zinc-100"
            >
              <option :for={route <- @routes} value={route.name} selected={route.name == @route_name}>
                {route.name} ({length(route.waypoints)} esquinas)
              </option>
            </select>
          </form>

          <form phx-change="pick-scenario" class="flex items-center gap-2">
            <select
              name="scenario"
              class="rounded-lg border border-zinc-700 bg-zinc-950 px-3 py-1.5 text-sm text-zinc-100"
            >
              <option value="">— cenário livre —</option>
              <optgroup
                :for={{group, items} <- Enum.group_by(@scenarios, & &1.group)}
                label={Scenario.group_label(group)}
              >
                <option
                  :for={item <- items}
                  value={item.id}
                  selected={@scenario && @scenario.id == item.id}
                >
                  {item.name}
                </option>
              </optgroup>
            </select>
          </form>

          <button
            :if={!@armed?}
            phx-click="arm"
            class="rounded-lg bg-emerald-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-emerald-500"
          >
            Armar simulação
          </button>

          <button
            :if={@armed?}
            phx-click="disarm"
            class="rounded-lg bg-rose-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-rose-500"
          >
            Desarmar
          </button>

          <button
            :if={@armed? and !@playing?}
            phx-click="play"
            class="rounded-lg bg-sky-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-sky-500"
          >
            <.icon name="hero-play" class="mr-1 h-4 w-4" /> Rodar
          </button>

          <button
            :if={@armed? and @playing?}
            phx-click="pause"
            class="rounded-lg bg-zinc-700 px-3 py-1.5 text-sm font-medium text-white hover:bg-zinc-600"
          >
            <.icon name="hero-pause" class="mr-1 h-4 w-4" /> Pausar
          </button>

          <button
            phx-click="reload"
            class="rounded-lg border border-zinc-700 px-3 py-1.5 text-sm text-zinc-300 hover:bg-zinc-800"
          >
            Recomeçar
          </button>

          <span :if={@armed?} class="ml-auto text-xs text-zinc-400">
            setas andam · teclas 1–9 disparam skills
          </span>
        </div>

        <p :if={@refusal} class="rounded-lg bg-amber-950/60 px-3 py-2 text-sm text-amber-200">
          {@refusal}
        </p>

        <div
          :if={@scenario}
          class="rounded-xl border border-sky-900/60 bg-sky-950/30 px-3 py-2 text-sm text-sky-100"
        >
          <span class="font-semibold">{@scenario.name}</span>
          <span class="text-sky-300/70">· {Scenario.group_label(@scenario.group)}</span>
          <p class="mt-1 text-sky-200/90">{@scenario.why}</p>
        </div>

        <p
          :if={failures(@world) != []}
          class="rounded-lg bg-rose-950/60 px-3 py-2 text-sm font-medium text-rose-200"
        >
          quebrado de propósito agora: {Enum.join(failures(@world), " · ")}
        </p>

        <p
          :if={@world && @world.unsimulated_stairs != []}
          class="rounded-lg bg-amber-950/60 px-3 py-2 text-sm text-amber-200"
        >
          Esta rota tem {length(@world.unsimulated_stairs)} passagem(ns) entre andares que não dá
          pra simular: o par de esquinas gravado está sujo, e chutar onde fica o degrau seria pior
          que não atravessar.
        </p>

        <div class="grid gap-4 lg:grid-cols-[2fr_1fr]">
          <div class="rounded-xl border border-zinc-800 bg-zinc-900/60 p-3">
            <div class="mb-2 flex items-baseline justify-between">
              <h2 class="text-sm font-semibold text-zinc-200">O mundo</h2>
              <span class="text-xs text-zinc-500">
                andar {@z || "?"} · {length(@mobs)} no chão · relógio {(@world && @world.clock) || 0}ms
              </span>
            </div>
            <svg viewBox={view_box(@view_box)} class="h-[26rem] w-full">
              <polyline
                points={Enum.map_join(@points, " ", fn {x, y, _n} -> "#{x},#{y}" end)}
                fill="none"
                stroke="rgb(63 63 70)"
                stroke-width="0.6"
              />
              <circle
                :for={{x, y, nest} <- @points}
                cx={x}
                cy={y}
                r={if nest, do: 1.6, else: 0.8}
                fill={if nest, do: "rgb(251 146 60)", else: "rgb(82 82 91)"}
              />
              <%= if @world do %>
                <circle
                  cx={elem(@world.pos, 0)}
                  cy={elem(@world.pos, 1)}
                  r={@world.knobs.battle_radius}
                  fill="rgb(56 189 248 / 0.07)"
                  stroke="rgb(56 189 248 / 0.35)"
                  stroke-width="0.3"
                />
                <circle
                  :for={mob <- @mobs}
                  cx={elem(mob.pos, 0)}
                  cy={elem(mob.pos, 1)}
                  r="1.8"
                  fill={mob_fill(mob.hp_pct)}
                />
                <circle
                  cx={elem(@world.pos, 0)}
                  cy={elem(@world.pos, 1)}
                  r="2.4"
                  fill={if @world.own.out?, do: "rgb(52 211 153)", else: "rgb(113 113 122)"}
                  stroke="white"
                  stroke-width="0.5"
                />
              <% end %>
            </svg>
          </div>

          <div class="space-y-4">
            <div class="rounded-xl border border-zinc-800 bg-zinc-900/60 p-3">
              <h2 class="mb-2 text-sm font-semibold text-zinc-200">O cérebro</h2>
              <%= if @orders do %>
                <p class={"text-lg font-semibold #{band_class(@orders.band)}"}>
                  {@orders.phase} · {@orders.band}
                </p>
                <p class="mt-1 text-sm text-zinc-300">{@orders.why}</p>
                <dl class="mt-3 grid grid-cols-2 gap-x-3 gap-y-1 text-xs text-zinc-400">
                  <div>rota: <span class="text-zinc-200">{@orders.route}</span></div>
                  <div>fogo: <span class="text-zinc-200">{@orders.fire}</span></div>
                  <div>revive: <span class="text-zinc-200">{@orders.revive}</span></div>
                  <div>poção: <span class="text-zinc-200">{@orders.potion}</span></div>
                </dl>
              <% else %>
                <p class="text-sm text-zinc-500">
                  A engine não publicou ordem ainda. Arme a simulação para acordá-la.
                </p>
              <% end %>
              <p class="mt-3 border-t border-zinc-800 pt-2 text-xs text-zinc-500">
                caçada: {(@hunt_fact && @hunt_fact.state) || "sem fato :hunt"}
              </p>
            </div>

            <div class="rounded-xl border border-zinc-800 bg-zinc-900/60 p-3">
              <h2 class="mb-1 text-sm font-semibold text-zinc-200">Vida</h2>
              <p class="text-sm text-zinc-300">
                mundo: {(@world && @world.own.hp_pct) || "—"}% <span class="text-zinc-600">·</span>
                lido: {(@pokemon_fact && (@pokemon_fact.hp_pct || "não leu")) || "—"}
                <span :if={@pokemon_fact && @pokemon_fact.fainted?} class="text-rose-300">
                  · caiu
                </span>
              </p>
            </div>
          </div>
        </div>

        <div class="grid gap-4 md:grid-cols-2">
          <div class="rounded-xl border border-zinc-800 bg-zinc-900/60 p-3">
            <h2 class="mb-2 text-sm font-semibold text-zinc-200">
              O que existe <span class="font-normal text-zinc-500">— verdade do mundo</span>
            </h2>
            <p :if={@truth == []} class="text-sm text-zinc-500">nada no chão</p>
            <ul class="space-y-1 text-sm">
              <li :for={row <- @truth} class="flex justify-between gap-2 text-zinc-300">
                <span>{row.name}</span>
                <span class="text-zinc-500">
                  {row.hp_pct}% · leash {row.leash}
                </span>
              </li>
            </ul>
          </div>

          <div class="rounded-xl border border-zinc-800 bg-zinc-900/60 p-3">
            <h2 class="mb-2 text-sm font-semibold text-zinc-200">
              O que o bot leu <span class="font-normal text-zinc-500">— fato :battle</span>
            </h2>
            <p :if={@perceived == :unread} class="text-sm text-amber-300">
              não estou lendo a lista de batalha
            </p>
            <p :if={@perceived == []} class="text-sm text-zinc-500">lista vazia</p>
            <ul :if={is_list(@perceived)} class="space-y-1 text-sm">
              <li :for={row <- @perceived} class="flex justify-between gap-2 text-zinc-300">
                <span>linha {row.row} · {row.name || "?"}</span>
                <span class="text-zinc-500">{round((row.hp_pct || 0) * 100)}%</span>
              </li>
            </ul>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp character_point(nil), do: []
  defp character_point(%{pos: {x, y, _z}}), do: [{x, y, false}]

  defp view_box({x, y, w, h}), do: "#{x} #{y} #{max(w, 1)} #{max(h, 1)}"

  defp mob_fill(hp) when hp > 66, do: "rgb(244 63 94)"
  defp mob_fill(hp) when hp > 33, do: "rgb(251 146 60)"
  defp mob_fill(_low), do: "rgb(161 98 7)"
end
