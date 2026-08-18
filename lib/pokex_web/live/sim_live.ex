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
  alias Pokex.Sim.Bench
  alias Pokex.Sim.Calibrate
  alias Pokex.Sim.Scenario
  alias Pokex.Sim.World

  @directions %{
    "ArrowRight" => "right",
    "ArrowLeft" => "left",
    "ArrowUp" => "up",
    "ArrowDown" => "down"
  }

  # Tibia shows 15x11 tiles around the character. A little wider than that keeps
  # what is about to walk in on screen too.
  @close_up_tiles 11

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
       scenario: Runner.scenario(),
       bench: nil,
       kill_combo: [],
       close_up?: false,
       calib: Calibrate.report(Date.utc_today()),
       measuring?: Pokex.Settings.get(:cavebot_measure_walk),
       auto?: Runner.auto?()
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

  def handle_event("toggle-auto", _params, socket) do
    on? = not socket.assigns.auto?
    if on?, do: wake_engine()
    Runner.auto(on?)
    {:noreply, assign(socket, auto?: on?)}
  end

  def handle_event("play", _params, socket) do
    wake_engine()
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

  # The one damage fact he actually holds. Every toggle rebuilds the world,
  # because a combo declared halfway through a fight would be measuring two
  # different worlds and calling it one.
  def handle_event("toggle-kill-key", %{"key" => key}, socket) do
    combo =
      if key in socket.assigns.kill_combo,
        do: socket.assigns.kill_combo -- [key],
        else: Enum.sort(socket.assigns.kill_combo ++ [key])

    socket = assign(socket, kill_combo: combo, bench: nil)

    if socket.assigns.scenario,
      do: {:noreply, load_scenario(socket, socket.assigns.scenario.id)},
      else: {:noreply, load_route(socket)}
  end

  def handle_event("toggle-close-up", _params, socket),
    do: {:noreply, assign(socket, close_up?: not socket.assigns.close_up?)}

  def handle_event("reload", _params, socket) do
    if socket.assigns.scenario,
      do: {:noreply, load_scenario(socket, socket.assigns.scenario.id)},
      else: {:noreply, load_route(socket)}
  end

  def handle_event("pick-scenario", %{"scenario" => ""}, socket) do
    {:noreply, socket |> assign(scenario: nil) |> load_route()}
  end

  def handle_event("pick-scenario", %{"scenario" => id}, socket),
    do: {:noreply, assign(load_scenario(socket, id), bench: nil)}

  # Runs the scenario through the PURE engine core — no process, no clock, one
  # minute of hunting in a few milliseconds — and answers with a verdict instead
  # of an impression.
  def handle_event("bench", _params, socket) do
    case socket.assigns.scenario do
      nil ->
        {:noreply, socket}

      scenario ->
        {:noreply, assign(socket, bench: Bench.run(scenario, routes: socket.assigns.routes))}
    end
  end

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
        Runner.load(route, knobs: extra_knobs(socket))
        assign(socket, world: Runner.world(), floor: nil)
    end
  end

  # The engine is what publishes `:orders`, and without orders the auto-play has
  # nothing to obey and the screen shows a brain that says nothing. It stops on
  # every code reload in dev, so asking it to run is cheap and idempotent — and
  # far better than a screen that looks broken for a reason nobody can see.
  defp wake_engine do
    Engine.Worker.run()
  catch
    :exit, _not_up -> :ok
  end

  defp load_scenario(socket, id) do
    case Scenario.get(id) do
      nil ->
        socket

      scenario ->
        Runner.load_scenario(Runner, scenario, socket.assigns.routes, extra_knobs(socket))
        assign(socket, scenario: scenario, world: Runner.world(), floor: nil)
    end
  end

  # His combo rides over whatever the route or the scenario asked for: it
  # describes his POKEMON, not the experiment.
  defp extra_knobs(%{assigns: %{kill_combo: []}}), do: %{}
  defp extra_knobs(socket), do: %{kill_combo: socket.assigns.kill_combo}

  defp kind_label(:aoe), do: "área"
  defp kind_label(:single), do: "alvo"
  defp kind_label(:buffs), do: "buff"
  defp kind_label(:heal), do: "cura"
  defp kind_label(:crowd), do: "controle"
  defp kind_label(other), do: to_string(other)

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

  # The whole route at 6px a tile answers "where am I on the lap". It cannot
  # answer "have they closed around the pokemon yet", which is the question he
  # actually asked for — that one is local, and at this zoom a monster is four
  # pixels. The close-up recentres on the character with a fixed span, so a
  # creature becomes a square you can count instead of a speck.
  defp view_of(%{close_up?: true, world: %{} = world}, _points) do
    {x, y, _z} = world.pos
    span = @close_up_tiles

    {x - span, y - div(span * 3, 4), span * 2, div(span * 3, 2)}
  end

  defp view_of(assigns, points), do: bounds(points ++ character_point(assigns.world))

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
      %{name: mob.name, hp_pct: World.hp_pct(mob), pos: mob.pos, leash: leash_left(mob, world)}
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

  # The screen has to answer "what is happening RIGHT NOW" before it answers
  # anything else. A dead pokémon in a paused world used to look exactly like a
  # world that had not started, and the only difference on screen was the shade
  # of one circle — which is not a difference anybody can read.
  defp status(assigns) do
    cond do
      not assigns.armed? ->
        %{
          tone: :idle,
          title: "Simulação desarmada",
          hint: "Clique em “Armar simulação” para acordar o mundo e o cérebro."
        }

      is_nil(assigns.world) ->
        %{
          tone: :idle,
          title: "Nenhum mundo carregado",
          hint: "Escolha uma rota ou um cenário e clique em “Recomeçar”."
        }

      not assigns.world.own.alive? ->
        %{
          tone: :bad,
          title: "Seu pokémon caiu",
          hint:
            "Os monstros bateram até zerar a vida. Clique em “Recomeçar” para levantar tudo " <>
              "de novo — ou aperte 1–9 mais cedo da próxima vez."
        }

      not assigns.playing? ->
        %{
          tone: :paused,
          title: "Pausado",
          hint:
            "Clique em “Rodar”. Depois: “Deixar o cérebro jogar” para assistir a engine caçar, " <>
              "ou jogue você mesmo com as setas e as teclas 1–9."
        }

      true ->
        %{
          tone: :good,
          title:
            if(assigns.auto?, do: "Rodando — o cérebro está jogando", else: "Rodando — você joga"),
          hint:
            "#{length(assigns.mobs)} monstro(s) no chão · sua vida #{assigns.world.own.hp_pct}% · " <>
              if(assigns.auto?,
                do: "ele anda a rota, atira e revive sozinho; o card ao lado diz por quê",
                else: "setas andam, 1–9 disparam — ou clique em “Deixar o cérebro jogar”"
              )
        }
    end
  end

  defp tone_class(:good), do: "border-emerald-800/70 bg-emerald-950/30 text-emerald-100"
  defp tone_class(:paused), do: "border-sky-900/70 bg-sky-950/30 text-sky-100"
  defp tone_class(:bad), do: "border-rose-900/70 bg-rose-950/40 text-rose-100"
  defp tone_class(:idle), do: "border-zinc-800 bg-zinc-900/60 text-zinc-300"

  defp measured_text(nil), do: "a noite não mediu"

  defp measured_text(%{n: n, median: median, min: min, max: max}) do
    "mediana #{round(median)} · de #{round(min)} a #{round(max)} · #{n} amostras"
  end

  defp revive_text(nil), do: "não"
  defp revive_text(at), do: "#{at}ms"

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
        view_box: view_of(assigns, points),
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
            :if={@armed?}
            phx-click="toggle-auto"
            class={
              "rounded-lg px-3 py-1.5 text-sm font-medium text-white " <>
                if(@auto?,
                  do: "bg-amber-600 hover:bg-amber-500",
                  else: "bg-indigo-600 hover:bg-indigo-500")
            }
          >
            {if @auto?, do: "Você joga", else: "Deixar o cérebro jogar"}
          </button>

          <button
            :if={@scenario}
            phx-click="bench"
            class="rounded-lg bg-violet-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-violet-500"
          >
            <.icon name="hero-forward" class="mr-1 h-4 w-4" /> Rodar rápido (1 min)
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

        <div
          :if={@world && @world.keys != %{}}
          class="rounded-xl border border-zinc-800 bg-zinc-900/60 px-3 py-2"
        >
          <div class="flex flex-wrap items-center gap-x-3 gap-y-2">
            <span class="text-sm font-medium text-zinc-200">O combo que mata</span>
            <span class="text-xs text-zinc-500">
              marque as teclas que, juntas, derrubam um monstro
            </span>

            <div class="flex flex-wrap gap-1.5">
              <button
                :for={key <- Enum.sort(Map.keys(@world.keys))}
                phx-click="toggle-kill-key"
                phx-value-key={key}
                class={
                  "rounded-md border px-2 py-1 text-xs font-medium " <>
                    if(key in @kill_combo,
                      do: "border-emerald-500 bg-emerald-600/25 text-emerald-200",
                      else: "border-zinc-700 text-zinc-400 hover:bg-zinc-800")
                }
              >
                {key}
                <span class="ml-1 text-[10px] font-normal opacity-70">
                  {kind_label(@world.keys[key].kind)}
                </span>
              </button>
            </div>

            <span :if={@kill_combo == []} class="ml-auto text-xs text-amber-300">
              nenhuma marcada — o dano é o número que eu chutei ({@world.knobs.aoe_damage}% por área)
            </span>
            <span :if={@kill_combo != []} class="ml-auto text-xs text-emerald-300">
              {length(@kill_combo)} teclas · {div(100 + length(@kill_combo) - 1, length(@kill_combo))}% por golpe
            </span>
          </div>
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

        <div class={"rounded-xl border px-4 py-3 #{tone_class(status(assigns).tone)}"}>
          <p class="text-base font-semibold">{status(assigns).title}</p>
          <p class="mt-0.5 text-sm opacity-90">{status(assigns).hint}</p>
        </div>

        <div class="grid gap-4 lg:grid-cols-[2fr_1fr]">
          <div class="rounded-xl border border-zinc-800 bg-zinc-900/60 p-3">
            <div class="mb-2 flex items-baseline justify-between">
              <h2 class="text-sm font-semibold text-zinc-200">O mundo</h2>
              <div class="flex items-baseline gap-3">
                <span class="text-xs text-zinc-500">
                  andar {@z || "?"} · {length(@mobs)} no chão · relógio {(@world && @world.clock) ||
                    0}ms
                </span>
                <button
                  :if={@world}
                  phx-click="toggle-close-up"
                  class={
                    "rounded-md border px-2 py-0.5 text-[11px] font-medium " <>
                      if(@close_up?,
                        do: "border-sky-500 bg-sky-600/25 text-sky-200",
                        else: "border-zinc-700 text-zinc-400 hover:bg-zinc-800")
                  }
                >
                  {if @close_up?, do: "🔍 perto", else: "🔍 aproximar"}
                </button>
              </div>
            </div>
            <svg viewBox={view_box(@view_box)} class="h-[26rem] w-full">
              <polyline
                points={Enum.map_join(@points, " ", fn {x, y, _n} -> "#{x},#{y}" end)}
                fill="none"
                stroke="rgb(63 63 70)"
                stroke-width="0.25"
              />
              <circle
                :for={{x, y, nest} <- @points}
                cx={x}
                cy={y}
                r={if nest, do: 0.55, else: 0.28}
                fill={if nest, do: "rgb(251 146 60)", else: "rgb(82 82 91)"}
              />
              <%= if @world do %>
                <rect
                  x={elem(@world.pos, 0) - div(@world.knobs.screen_w, 2) - 0.5}
                  y={elem(@world.pos, 1) - div(@world.knobs.screen_h, 2) - 0.5}
                  width={@world.knobs.screen_w}
                  height={@world.knobs.screen_h}
                  fill="rgb(56 189 248 / 0.07)"
                  stroke="rgb(56 189 248 / 0.35)"
                  stroke-width="0.3"
                />
                <rect
                  :for={mob <- @mobs}
                  x={elem(mob.pos, 0) - 0.5}
                  y={elem(mob.pos, 1) - 0.5}
                  width="1"
                  height="1"
                  fill={mob_fill(World.hp_pct(mob))}
                  stroke="rgb(24 24 27)"
                  stroke-width="0.08"
                />
                <line
                  :if={@world.own.out?}
                  x1={elem(@world.pos, 0)}
                  y1={elem(@world.pos, 1)}
                  x2={elem(@world.own.pos, 0)}
                  y2={elem(@world.own.pos, 1)}
                  stroke="rgb(52 211 153)"
                  stroke-width="0.12"
                  stroke-dasharray="0.4 0.3"
                  opacity="0.55"
                />
                <rect
                  :if={@world.own.out?}
                  x={elem(@world.own.pos, 0) - @world.knobs.aoe_radius - 0.5}
                  y={elem(@world.own.pos, 1) - @world.knobs.aoe_radius - 0.5}
                  width={@world.knobs.aoe_radius * 2 + 1}
                  height={@world.knobs.aoe_radius * 2 + 1}
                  fill="none"
                  stroke="rgb(52 211 153)"
                  stroke-width="0.1"
                  stroke-dasharray="0.5 0.4"
                  opacity="0.6"
                />
                <rect
                  x={elem(@world.own.pos, 0) - 0.5}
                  y={elem(@world.own.pos, 1) - 0.5}
                  width="1"
                  height="1"
                  fill={if @world.own.out?, do: "rgb(52 211 153)", else: "rgb(113 113 122)"}
                  stroke="rgb(24 24 27)"
                  stroke-width="0.12"
                />
                <rect
                  x={elem(@world.pos, 0) - 0.5}
                  y={elem(@world.pos, 1) - 0.5}
                  width="1"
                  height="1"
                  fill="rgb(56 189 248)"
                  stroke="white"
                  stroke-width="0.18"
                />
              <% end %>
            </svg>

            <ul class="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-xs text-zinc-400">
              <li class="flex items-center gap-1.5">
                <span class="inline-block h-3 w-3 bg-sky-400 ring-1 ring-white"></span> você
              </li>
              <li class="flex items-center gap-1.5">
                <span class="inline-block h-3 w-3 bg-emerald-400"></span> seu pokémon (cinza = caiu)
              </li>
              <li class="flex items-center gap-1.5">
                <span class="inline-block h-3 w-3 border border-dashed border-emerald-400"></span>
                alcance da área — sai DELE
              </li>
              <li class="flex items-center gap-1.5">
                <span class="inline-block h-3 w-3 bg-rose-500"></span> monstro
              </li>
              <li class="flex items-center gap-1.5">
                <span class="inline-block h-3 w-3 rounded-full bg-orange-400"></span>
                esquina onde nascem
              </li>
              <li class="flex items-center gap-1.5">
                <span class="inline-block h-3 w-3 rounded-full bg-zinc-600"></span> esquina comum
              </li>
              <li class="flex items-center gap-1.5">
                <span class="inline-block h-3 w-3 border border-sky-500/60"></span>
                a tela do jogo — o bot só sabe o que cabe aqui
              </li>
            </ul>
            <p class="mt-1 text-[11px] leading-snug text-zinc-500">
              Cada bicho é um quadrado de UM tile, com o pé no centro exato — é assim que a engine
              do jogo trata criatura. E o alcance é quadrado, não redondo: a distância aqui é
              Chebyshev (a grade tem diagonal), então 3 tiles na diagonal são 3, não 4,24.
            </p>
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
                <span class="ml-2">
                  cérebro: {if @orders, do: "decidindo", else: "calado"}
                </span>
              </p>
            </div>

            <div class="rounded-xl border border-zinc-800 bg-zinc-900/60 p-3">
              <h2 class="mb-1 text-sm font-semibold text-zinc-200">Vida</h2>
              <p class="text-sm text-zinc-300">
                <span class="text-emerald-300">pokémon</span>
                {(@world && @world.own.hp_pct) || "—"}% <span class="text-zinc-600">·</span>
                lido: {(@pokemon_fact && (@pokemon_fact.hp_pct || "não leu")) || "—"}
                <span :if={@pokemon_fact && @pokemon_fact.fainted?} class="text-rose-300">
                  · caiu
                </span>
              </p>
              <p class="mt-1 text-sm text-zinc-300">
                <span class="text-sky-300">você</span>
                {(@world && @world.player.hp_pct) || "—"}%
                <span :if={@world && @world.own.out?} class="ml-1 text-xs text-zinc-500">
                  — intocável enquanto ele está em campo
                </span>
                <span :if={@world && not @world.own.out?} class="ml-1 text-xs text-rose-300">
                  — ele caiu, agora é você que apanha
                </span>
              </p>
              <p class="mt-2 border-t border-zinc-800 pt-2 text-xs text-zinc-500">
                a engine não tem fato de vida do personagem: o mundo sabe que você
                está morrendo e o bot não enxerga.
              </p>
            </div>
          </div>
        </div>

        <div class="grid gap-4 md:grid-cols-2">
          <div class="rounded-xl border border-zinc-800 bg-zinc-900/60 p-3">
            <h2 class="mb-2 text-sm font-semibold text-zinc-200">
              Antes da caçada <span class="font-normal text-zinc-500">— o que grava dado</span>
            </h2>
            <ul class="space-y-1 text-sm">
              <li class={if @measuring?, do: "text-emerald-300", else: "text-amber-300"}>
                <span class="font-medium">medir caminhada:</span>
                {if @measuring?,
                  do: "ligado — a noite vai medir tiles/s",
                  else:
                    "DESLIGADO — sem ele ninguém mede tiles/s. Ligue cavebot_measure_walk em /config"}
              </li>
              <li class="text-zinc-400">
                O cérebro grava sozinho: cada mudança de decisão vira uma linha tipada em
                ~/.pokex/events/. É de lá que sai o tamanho real das pilhas.
              </li>
            </ul>
          </div>

          <div class="rounded-xl border border-zinc-800 bg-zinc-900/60 p-3">
            <h2 class="mb-2 text-sm font-semibold text-zinc-200">
              O que a noite disse <span class="font-normal text-zinc-500">— hoje</span>
            </h2>
            <dl class="space-y-1 text-sm text-zinc-300">
              <div>
                ms por tile: <span class="text-zinc-100">{measured_text(@calib.walk)}</span>
              </div>
              <div>
                pilha ao abrir:
                <span class="text-zinc-100">{measured_text(@calib.pile && @calib.pile.engaged)}</span>
              </div>
              <div>
                parou de chegar em:
                <span class="text-zinc-100">{measured_text(@calib.pile && @calib.pile.settled_ms)}</span>
              </div>
              <div :if={@calib.pile} class="text-zinc-500">
                {@calib.pile.decisions} decisões · {@calib.pile.engagements} aberturas · {@calib.pile.skipped} pilhas puladas
              </div>
            </dl>
          </div>
        </div>

        <div :if={@bench} class="rounded-xl border border-violet-900/60 bg-violet-950/20 p-3">
          <h2 class="mb-2 text-sm font-semibold text-violet-100">
            Veredito
            <span class="font-normal text-violet-300/70">— um minuto simulado, sem processo</span>
          </h2>
          <dl class="mb-3 flex flex-wrap gap-x-5 gap-y-1 text-sm text-violet-100">
            <div>mortos: <span class="font-semibold">{@bench.outcome.killed}</span></div>
            <div>sumidos no leash: <span class="font-semibold">{@bench.outcome.vanished}</span></div>
            <div>de pé: <span class="font-semibold">{@bench.outcome.left_alive}</span></div>
            <div>vida no fim: <span class="font-semibold">{@bench.outcome.hp_at_end}%</span></div>
            <div>
              revive: <span class="font-semibold">{revive_text(@bench.outcome.revived_at)}</span>
            </div>
            <div>caiu: <span class="font-semibold">{revive_text(@bench.outcome.died_at)}</span></div>
          </dl>
          <ol class="max-h-56 space-y-1 overflow-y-auto text-xs">
            <li :for={line <- @bench.timeline} class="flex gap-2 text-zinc-300">
              <span class="w-14 shrink-0 tabular-nums text-zinc-500">{line.at}ms</span>
              <span class={"w-24 shrink-0 font-medium #{band_class(line.band)}"}>{line.phase}</span>
              <span class="text-zinc-400">{line.why}</span>
            </li>
          </ol>
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
