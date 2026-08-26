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
  alias Pokex.Sim.Score
  alias Pokex.Engine.Tally
  alias Pokex.Sim.Calibrate
  alias Pokex.Sim.Scenario
  alias Pokex.Sim.Setup
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
    saved = Setup.read()

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
       bench_all: nil,
       score: nil,
       measured_note: nil,
       setup: saved,
       kill_combo: Map.get(saved, :kill_combo, []),
       setup_open?: false,
       close_up?: false,
       calib: Calibrate.report(Date.utc_today()),
       noite: Tally.of_day(Date.utc_today()),
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

    socket |> assign(kill_combo: combo, bench: nil, bench_all: nil, score: nil) |> reload_world()
  end

  def handle_event("toggle-setup", _params, socket),
    do: {:noreply, assign(socket, setup_open?: not socket.assigns.setup_open?)}

  # Saved to disk, not just to the socket: "calibrar" only means anything if he
  # does it once. A number he has to retype after every restart is a number he
  # will stop trusting and then stop setting.
  def handle_event("save-setup", params, socket) do
    knobs = Map.put(parse_setup(params), :kill_combo, socket.assigns.kill_combo)
    Setup.write(knobs)

    socket |> assign(setup: knobs, bench: nil) |> reload_world()
  end

  # MEDIR → USAR, em um clique. Sem isto, `Calibrate.knobs/1` era um número
  # bonito numa tela que ninguém podia gastar: ele lia "a mordida tira 2%/s por
  # bicho" e continuava simulando com o meu chute. Só o que a noite REALMENTE
  # mediu entra; o resto do painel fica como está.
  def handle_event("use-measured", _params, socket) do
    measured = Calibrate.knobs(socket.assigns.calib.date)
    knobs = Map.merge(socket.assigns.setup, measured)
    Setup.write(knobs)

    socket
    |> assign(setup: knobs, bench: nil, bench_all: nil, score: nil, measured_note: measured)
    |> reload_world()
  end

  def handle_event("reset-setup", _params, socket) do
    Setup.clear()

    socket |> assign(setup: %{}, kill_combo: [], bench: nil) |> reload_world()
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

  # Every scenario at once, with the knobs the bot is running RIGHT NOW —
  # "validar vários cenários, ver como ele se comporta" (Lucas, 2026-08-25).
  # One at a time answers "did this one work"; all of them side by side answers
  # the question he actually asks, which is what a knob COSTS: the same nine
  # rows under `engine_engage_from: 1` and under 3 are two different hunts.
  def handle_event("bench_all", _params, socket) do
    config = Bench.config_in_force()

    rows =
      Enum.map(Scenario.all(), fn scenario ->
        %{outcome: outcome} = Bench.run(scenario, routes: socket.assigns.routes, config: config)
        %{id: scenario.id, name: scenario.name, outcome: outcome}
      end)

    {:noreply, assign(socket, bench_all: %{rows: rows, config: config})}
  end

  # THE SCOREBOARD. Every scenario walked for five simulated minutes, twice —
  # once with the brain as it is and once with R3b on — because the question he
  # asks is never "did this run go well", it is "is this brain better than that
  # one", and that is a question only two runs of the same world can answer.
  #
  # 177ms for the whole thing (18 runs of five minutes), so it is a click and
  # not a job.
  def handle_event("score", _params, socket) do
    config = Bench.config_in_force()
    minutes = 5

    tuned = Map.merge(config, Bench.tuning())

    rows =
      Enum.map(Scenario.all(), fn scenario ->
        %{card: without} = Score.hunt(scenario, minutes: minutes, config: config)
        %{card: with_tuning} = Score.hunt(scenario, minutes: minutes, config: tuned)

        %{scenario: scenario, without: without, with: with_tuning}
      end)

    {:noreply,
     assign(socket,
       score: %{
         rows: rows,
         minutes: minutes,
         config: config,
         tuning: Bench.tuning(),
         totals: %{without: totals(rows, :without), with: totals(rows, :with)}
       }
     )}
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

  # Lives out here, not between the handle_event clauses that call it: a defp
  # in the middle of a clause group is the warning this project treats as an
  # error, and it only shows up under --warnings-as-errors.
  defp reload_world(socket) do
    if socket.assigns.scenario,
      do: {:noreply, load_scenario(socket, socket.assigns.scenario.id)},
      else: {:noreply, load_route(socket)}
  end

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
  defp extra_knobs(socket) do
    socket.assigns.setup
    |> Map.drop([:kill_combo])
    |> Map.put(:kill_combo, socket.assigns.kill_combo)
  end

  defp kind_label(:aoe), do: "área"
  defp kind_label(:single), do: "alvo"
  defp kind_label(:buffs), do: "buff"
  defp kind_label(:heal), do: "cura"
  defp kind_label(:crowd), do: "controle"
  defp kind_label(other), do: to_string(other)

  # Grouped the way he listed them, not the way the struct happens to order
  # them: the monster, the damage, the speeds, the window, the world.
  @setup_groups [
    {"O monstro",
     [
       {:mob_hp, "vida"},
       {:aggro_tiles, "enxerga a (tiles)"},
       {:leash_tiles, "leash (tiles)"},
       {:mob_ms_per_tile, "ms por tile"},
       {:bite_dmg, "mordida"},
       {:bite_every_ms, "morde a cada (ms)"}
     ]},
    {"O dano",
     [
       {:damage_spread_pct, "variação ±%"},
       {:aoe_damage_pct, "área: % da vida"},
       {:single_damage_pct, "alvo: % da vida"},
       {:aoe_radius, "raio da área"}
     ]},
    {"As velocidades — ms por tile, menor é mais rápido",
     [
       {:ms_per_tile, "você"},
       {:pet_ms_per_tile, "seu pokémon"},
       {:pet_follow_tiles, "ele fica atrás (tiles)"}
     ]},
    {"A tela do jogo — o que a engine pode saber",
     [{:screen_w, "largura"}, {:screen_h, "altura"}]},
    {"O preço do F4 — o que decide se vale apertar por cooldown",
     [
       {:revive_settle_ms, "fica na bola (ms)"},
       {:revive_cooldown_ms, "piso entre dois (ms)"}
     ]},
    {"O mundo", [{:stray_chance_pct, "perdido por esquina %"}]},
    # A DENSIDADE, o guindaste que ele pediu: "a meta é ver quanto inimigo a
    # gente consegue surrar ao mesmo tempo... sem limites pra chegar no máximo".
    # `pilha fixa` sai por último no grupo porque é o que muda TODO cenário de
    # uma vez, e o rótulo diz isso.
    {"A densidade — quanto bicho ao mesmo tempo",
     [
       {:nest_radius, "ninho: espalha (tiles)"},
       {:respawn_ms, "renasce a cada (ms)"},
       {:nest_size, "pilha fixa (força TODO cenário; 0 = deixa o cenário decidir)"}
     ]}
  ]

  defp setup_groups, do: @setup_groups

  # The EFFECTIVE value, never a blank box: he must never have to wonder which
  # number is actually running.
  defp knob_value(assigns, key) do
    Map.get(assigns.setup, key) || (assigns.world && Map.get(assigns.world.knobs, key))
  end

  defp band_label(nil, _key), do: "—"

  defp band_label(world, key) do
    case World.damage_band(world, key) do
      :no_damage -> "não machuca"
      {lo, hi} when lo == hi -> "#{lo}"
      {lo, hi} -> "#{lo}–#{hi}"
    end
  end

  # A ordem da BARRA, não a do alfabeto: `Enum.sort` sobre strings põe o "0"
  # antes do "1" e o "10" entre o "1" e o "2". A barra dele começa no 1.
  defp bar_order(nil), do: []

  defp bar_order(world) do
    world.keys
    |> Map.keys()
    |> Enum.sort_by(fn key ->
      case Integer.parse(key) do
        # o zero é a última tecla da fileira, não a primeira
        {0, ""} -> 100
        {n, ""} -> n
        :error -> 999
      end
    end)
  end

  @jobs %{aoe: "área", single: "alvo único", crowd: "controle", buffs: "buff", heal: "cura"}

  defp job_label(nil, _key), do: "—"

  defp job_label(world, key) do
    case world.keys[key] do
      %{kind: kind} -> Map.get(@jobs, kind, to_string(kind))
      _no_key -> "—"
    end
  end

  # Buff, cura e controle não têm dano pra calibrar, e pedir um número deles é
  # pedir que ele invente um.
  defp damages?(world, key), do: World.damage_band(world, key) != :no_damage

  defp bar_owner(nil), do: "sem pokémon"

  defp bar_owner(_world), do: "a barra do #{Pokex.Sim.Loadout.current().name}"

  defp tuned(setup, key) do
    case Map.get(setup, :skill_damage, %{})[key] do
      {lo, hi} -> {lo, hi}
      _untuned -> {nil, nil}
    end
  end

  # A blank box means "use the default", NOT zero: zero milliseconds per tile
  # is a character that teleports, and that is never what an empty field means.
  defp parse_setup(params) do
    numbers =
      for key <- Setup.tunable(),
          {:ok, n} <- [as_int(params[Atom.to_string(key)])],
          into: %{},
          do: {key, n}

    numbers
    |> unpin_at_zero()
    |> Map.put(:skill_damage, parse_damage(params))
  end

  # `nest_size` PINA a pilha: um número liga o pino, `nil` devolve o sorteio ao
  # cenário. Mas a caixa só sabe escrever números, e "0" no formulário quer dizer
  # "não pina" — não "todo ninho tem zero bicho", que é um mundo vazio.
  defp unpin_at_zero(%{nest_size: 0} = knobs), do: Map.delete(knobs, :nest_size)
  defp unpin_at_zero(knobs), do: knobs

  defp parse_damage(params) do
    for key <- ~w(1 2 3 4 5 6 7 8 9),
        {:ok, lo} <- [as_int(params["dmg_min_" <> key])],
        {:ok, hi} <- [as_int(params["dmg_max_" <> key])],
        into: %{},
        do: {key, {min(lo, hi), max(lo, hi)}}
  end

  defp as_int(text) when is_binary(text) do
    case Integer.parse(String.trim(text)) do
      {n, _rest} when n >= 0 -> {:ok, n}
      _not_a_number -> :blank
    end
  end

  defp as_int(_absent), do: :blank

  defp failures(nil), do: []
  defp failures(world), do: Enum.map(world.failures, &failure_label/1)

  # The session, not the average of the averages: nine runs of five minutes are
  # 45 minutes of hunting, and a rate over the whole of it is the number a night
  # would actually produce.
  defp totals(rows, key) do
    cards = Enum.map(rows, &Map.fetch!(&1, key))
    minutes = Enum.sum(Enum.map(cards, & &1.minutes))
    ms = Enum.sum(Enum.map(cards, & &1.ms))

    %{
      minutes: minutes,
      kills: Enum.sum(Enum.map(cards, & &1.kills)),
      deaths: Enum.sum(Enum.map(cards, & &1.deaths)),
      vanished: Enum.sum(Enum.map(cards, & &1.vanished)),
      kills_per_min: rate(Enum.sum(Enum.map(cards, & &1.kills)), minutes),
      deaths_per_min: rate(Enum.sum(Enum.map(cards, & &1.deaths)), minutes),
      vanished_per_min: rate(Enum.sum(Enum.map(cards, & &1.vanished)), minutes),
      revives_per_min: rate(Enum.sum(Enum.map(cards, & &1.revives.accepted)), minutes),
      stalled_pct: share(cards, :ms_stalled_of, ms),
      down_pct: share(cards, :ms_down_of, ms),
      revives: %{
        accepted: Enum.sum(Enum.map(cards, & &1.revives.accepted)),
        proactive: Enum.sum(Enum.map(cards, & &1.revives.proactive)),
        rescue: Enum.sum(Enum.map(cards, & &1.revives.rescue)),
        refused: Enum.sum(Enum.map(cards, & &1.revives.refused))
      },
      pile_ms: median(Enum.reject(Enum.map(cards, & &1.pile_ms.median), &is_nil/1)),
      # A session with no falls is not the same as a safe session, and the two
      # numbers that tell them apart are the lowest the bar ever got and what
      # HE paid — he is only ever bitten while nothing of his is on the field.
      min_hp: Enum.min(Enum.map(cards, &(&1.min_hp || 100))),
      player_hp: Enum.min(Enum.map(cards, & &1.player_hp))
    }
  end

  defp rate(count, minutes) when minutes > 0, do: Float.round(count / minutes, 2)
  defp rate(_count, _minutes), do: 0.0

  # The percentages come back as percentages, so weighting them by each run's
  # length and dividing by the total is the only way to add them without lying.
  defp share(cards, :ms_stalled_of, total_ms),
    do: weighted(cards, & &1.stalled_pct, total_ms)

  defp share(cards, :ms_down_of, total_ms), do: weighted(cards, & &1.down_pct, total_ms)

  defp weighted(_cards, _get, 0), do: 0.0

  defp weighted(cards, get, total_ms) do
    cards
    |> Enum.map(fn card -> get.(card) * card.ms end)
    |> Enum.sum()
    |> Kernel./(total_ms)
    |> Float.round(1)
  end

  defp median([]), do: nil

  defp median(values) do
    sorted = Enum.sort(values)
    middle = div(length(sorted), 2)

    if rem(length(sorted), 2) == 1,
      do: Enum.at(sorted, middle),
      else: div(Enum.at(sorted, middle - 1) + Enum.at(sorted, middle), 2)
  end

  # A delta the eye can read without arithmetic: the sign is the label, so the
  # colour never has to carry the meaning on its own.
  defp delta_pct(before, aft) when before > 0, do: round((aft - before) * 100 / before)
  defp delta_pct(_before, aft) when aft > 0, do: 100
  defp delta_pct(_before, _aft), do: 0

  defp delta_text(pct) when pct > 0, do: "+#{pct}%"
  defp delta_text(pct), do: "#{pct}%"

  defp delta_class(pct) when pct > 0, do: "font-bold text-pk-text"
  defp delta_class(pct) when pct < 0, do: "font-bold text-pk-danger"
  defp delta_class(_zero), do: "text-pk-text-3"

  # The phases of every scenario added up by TIME, which is the only way to add
  # percentages of runs of different lengths without lying. Anything under one
  # percent of the session is noise on a strip this small.
  defp phase_shares(rows) do
    cards = Enum.map(rows, & &1.without)
    total = cards |> Enum.map(& &1.ms) |> Enum.sum() |> max(1)

    cards
    |> Enum.flat_map(& &1.by_phase)
    |> Enum.reduce(%{}, fn %{phase: phase, ms: ms}, acc ->
      Map.update(acc, phase, ms, &(&1 + ms))
    end)
    |> Enum.map(fn {phase, ms} -> %{phase: phase, pct: Float.round(ms * 100 / total, 1)} end)
    |> Enum.reject(&(&1.pct < 1.0))
    |> Enum.sort_by(& &1.pct, :desc)
  end

  @phase_labels %{
    travelling: "andando",
    gathering: "mobando",
    sizing: "contando",
    engaged: "lutando",
    skipping: "deixando pra trás",
    closing: "fechando a rodada",
    emergency: "vermelho",
    recovering: "esperando o revive",
    unaided: "ferido, sem revive",
    downed: "no chão",
    handless: "sem teclas",
    blind: "cego",
    idle: "parado",
    guarding: "só protegendo"
  }

  defp phase_label(phase), do: Map.get(@phase_labels, phase, to_string(phase))

  # He is only ever bitten while nothing of his is on the field, so this number
  # is the price of every second down, in one figure. Silent when he paid none.
  defp his_bill(%{player_hp: 100}), do: ""
  defp his_bill(%{player_hp: hp}), do: " · você caiu a #{hp}%"

  # Cinco mostradores, na ordem em que ele os lê: o que rendeu, o que custou, e
  # os dois números que dizem por quê.
  defp noite_readouts(noite) do
    [
      %{
        label: "mortos/min",
        value: noite.kills_per_min,
        tone: "text-pk-text",
        note: "#{noite.kills} no total"
      },
      %{
        label: "revives/min",
        value: noite.revives_per_min,
        tone: "text-pk-text",
        note: "#{noite.revives} prensas"
      },
      %{
        label: "no chão",
        value: "#{noite.down_pct}%",
        tone: if(noite.down_pct > 10, do: "text-pk-danger", else: "text-pk-text"),
        note: "sem pokémon em campo"
      },
      %{
        label: "sem cooldown",
        value: "#{noite.stalled_pct}%",
        tone: "text-pk-text",
        note: "com bicho na tela"
      },
      %{
        label: "leituras",
        value: map_size(noite.piles),
        tone: "text-pk-text-2",
        note: "tamanhos de pilha distintos"
      }
    ]
  end

  defp ms_text(nil), do: "—"
  defp ms_text(ms), do: "#{Float.round(ms / 1000, 1)}s"

  # Six readouts, in the order he would read them: what it produced, what it
  # cost, and the two numbers that say WHY. Deliberately not six big-number
  # cards — one dense strip of hairline-separated cells, which is what this
  # panel is made of everywhere else.
  defp score_readouts(%{without: without, with: with_reset}) do
    [
      %{
        label: "mortos/min",
        value: without.kills_per_min,
        tone: "text-pk-text",
        note: "com R3b: #{with_reset.kills_per_min}"
      },
      %{
        label: "quedas/min",
        value: without.deaths_per_min,
        tone: if(without.deaths > 0, do: "text-pk-danger", else: "text-pk-text"),
        note: "com R3b: #{with_reset.deaths_per_min}"
      },
      %{
        label: "sem cooldown",
        value: "#{without.stalled_pct}%",
        tone: "text-pk-text",
        note: "do tempo, com bicho na tela"
      },
      %{
        label: "no chão",
        value: "#{without.down_pct}%",
        tone: if(without.down_pct > 10, do: "text-pk-danger", else: "text-pk-text"),
        note: "sem pokémon em campo · vida mínima #{without.min_hp}%#{his_bill(without)}"
      },
      %{
        label: "pilha (mediana)",
        value: ms_text(without.pile_ms),
        tone: "text-pk-text",
        note: "do primeiro bicho à lista vazia"
      },
      %{
        label: "revives",
        value: without.revives.accepted,
        tone: if(without.revives.refused > 0, do: "text-pk-warn", else: "text-pk-text"),
        note: revive_note(without.revives)
      }
    ]
  end

  defp revive_note(%{refused: refused} = revives) when refused > 0,
    do: "#{revives.proactive} proativos · #{refused} recusados"

  defp revive_note(revives), do: "#{revives.proactive} proativos · #{revives.rescue} resgates"

  # A run that ended with the pokemon down is not the same news as one that
  # ended with the ground clean, and a table where both read "clean" is a table
  # nobody looks twice at.
  defp ending_text(:died), do: "caiu"
  defp ending_text(:clean), do: "limpo"
  defp ending_text(:timeout), do: "ficou gente"

  defp ending_class(:died), do: "font-semibold text-rose-400"
  defp ending_class(:clean), do: "text-emerald-400"
  defp ending_class(_still_going), do: "text-amber-400"

  defp failure_label(:blind), do: "tela ilegível"
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
      %{
        name: mob.name,
        hp_pct: World.hp_pct(mob),
        pos: mob.pos,
        leash: leash_left(mob, world),
        asleep?: World.asleep?(mob, world)
      }
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

  # The battle fact comes off the SHARED blackboard, and not every producer
  # fills the detail: the real interpreter does, a hand-made observation does
  # not. Rendering the rows it DOES carry beats taking the page down — the row
  # numbers are the part this panel is comparing against the truth anyway.
  defp perceived_rows(%{enemies: rows}) when is_list(rows),
    do: Enum.map(rows, &%{row: &1, name: nil, hp_pct: nil})

  defp perceived_rows(_unknown_shape), do: :unread

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
        running_status(assigns)
    end
  end

  defp running_status(assigns) do
    cond do
      # ENTREGUE E MUDO. Uma simulação que roda com o cérebro no comando e não
      # faz nada não pode parecer igual a uma que está caçando: ele rodou uma
      # assim e teve que adivinhar ("ele não usou nenhuma skill nem andou",
      # 25/08). Sem ordens, o cérebro não está rodando; sem teclas, não há luta
      # possível — e as duas coisas agora estão escritas.
      assigns.auto? and is_nil(assigns.orders) ->
        %{
          tone: :bad,
          title: "Rodando — mas o cérebro não está mandando nada",
          hint:
            "nenhuma ordem chegou. A engine não está de pé: Desarmar e Armar de novo " <>
              "religa ela junto com a cerca."
        }

      assigns.auto? and assigns.orders.phase == :handless ->
        %{
          tone: :bad,
          title: "Rodando — mas sem teclas pra lutar",
          hint:
            "#{assigns.orders.why}. Escolha um pokémon no /time e classifique cada slot " <>
              "da barra dele — sem isso a luta não tem o que apertar."
        }

      true ->
        %{
          tone: :good,
          title:
            if(assigns.auto?, do: "Rodando — o cérebro está jogando", else: "Rodando — você joga"),
          hint:
            "#{length(assigns.mobs)} monstro(s) no chão · sua vida #{assigns.world.own.hp_pct}% · " <>
              if(assigns.auto?,
                do: brain_hint(assigns.orders),
                else: "setas andam, 1–9 disparam — ou clique em “Deixar o cérebro jogar”"
              )
        }
    end
  end

  # O que ele está mandando AGORA, na frase dele: um cérebro que decide em
  # silêncio é indistinguível de um cérebro parado.
  defp brain_hint(nil), do: "ele anda a rota, atira e revive sozinho"

  defp brain_hint(orders),
    do: "🧠 #{orders.why} (rota #{orders.route}, fogo #{orders.fire})"

  defp tone_class(:good), do: "border-emerald-800/70 bg-emerald-950/30 text-emerald-100"
  defp tone_class(:paused), do: "border-sky-900/70 bg-sky-950/30 text-sky-100"
  defp tone_class(:bad), do: "border-rose-900/70 bg-rose-950/40 text-rose-100"
  defp tone_class(:idle), do: "border-zinc-800 bg-zinc-900/60 text-zinc-300"

  defp measured_text(nil), do: "a noite não mediu"

  defp measured_text(%{n: n, median: median, min: min, max: max}) do
    "mediana #{round(median)} · de #{round(min)} a #{round(max)} · #{n} amostras"
  end

  # Uma leitura por medição, com o n do lado: número sem amostra é boato, e uma
  # noite que não mediu diz que não mediu em vez de mostrar um padrão.
  defp measurements(calib) do
    [
      %{
        label: "a mordida",
        value: bite_value(calib.bite),
        tone: measured_tone(calib.bite),
        note: "quanto a vida cai por segundo, por bicho na tela"
      },
      %{
        label: "o custo de um bicho",
        value: kill_value(calib.kill),
        tone: measured_tone(calib.kill),
        note: "teclas e segundos por monstro morto em luta aberta"
      },
      %{
        label: "o preço do F4",
        value: settle_value(calib.revive_settle),
        tone: measured_tone(calib.revive_settle),
        note: "quanto tempo o pokémon fica na bola"
      },
      %{
        label: "F4 zera cooldown?",
        value: reset_value(calib.revive_reset),
        tone: reset_tone(calib.revive_reset),
        note: "a premissa da R3b — e um fato do jogo, não do código"
      }
    ]
  end

  defp measured_tone(nil), do: "text-pk-text-3"
  defp measured_tone(_measured), do: "text-pk-text"

  defp bite_value(nil), do: "a noite não mediu"

  defp bite_value(bite),
    do: "#{Float.round(bite.median, 2)}%/s por bicho · #{bite.n} janelas"

  defp kill_value(nil), do: "a noite não mediu"

  defp kill_value(kill),
    do: "#{kill.presses_per_kill} teclas · #{ms_text(kill.ms_per_kill)} · #{kill.n} mortes"

  defp settle_value(nil), do: "a noite não mediu"
  defp settle_value(settle), do: "#{round(settle.median)}ms · #{settle.n} revives"

  defp reset_value(nil), do: "a noite não mediu"
  defp reset_value(%{resets: r, kept: 0, n: n}) when r > 0, do: "SIM, zerou · #{n} revives"
  defp reset_value(%{resets: 0, kept: k}), do: "NÃO zerou · #{k} revives"

  defp reset_value(%{resets: r, kept: k}),
    do: "misturado: #{r} zeraram, #{k} não"

  defp reset_tone(nil), do: "text-pk-text-3"
  defp reset_tone(%{resets: r, kept: 0}) when r > 0, do: "text-pk-ok"
  defp reset_tone(%{resets: 0}), do: "text-pk-danger"
  defp reset_tone(_mixed), do: "text-pk-warn"

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
          <form id="sim-rota" phx-change="pick-route" class="flex items-center gap-2">
            <select
              name="route"
              class="rounded-lg border border-zinc-700 bg-zinc-950 px-3 py-1.5 text-sm text-zinc-100"
            >
              <option :for={route <- @routes} value={route.name} selected={route.name == @route_name}>
                {route.name} ({length(route.waypoints)} esquinas)
              </option>
            </select>
          </form>

          <form id="sim-cenario" phx-change="pick-scenario" class="flex items-center gap-2">
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
            phx-click="bench_all"
            class="rounded-lg border border-violet-700 px-3 py-1.5 text-sm font-medium text-violet-200 hover:bg-violet-900/40"
          >
            <.icon name="hero-table-cells" class="mr-1 h-4 w-4" /> Rodar TODOS
          </button>

          <button
            phx-click="score"
            class="rounded-lg border border-pk-ok-line bg-pk-ok-dim px-3 py-1.5 text-pk-body font-semibold text-pk-ok hover:bg-pk-ok/20"
          >
            <.icon name="hero-calculator" class="mr-1 h-4 w-4" /> Placar (5 min por cenário)
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
              nenhuma marcada — a área usa o meu chute: {@world.knobs.aoe_damage_pct}% da vida do bicho
            </span>
            <span :if={@kill_combo != []} class="ml-auto text-xs text-emerald-300">
              {length(@kill_combo)} teclas · {div(100 + length(@kill_combo) - 1, length(@kill_combo))}% por golpe
            </span>
          </div>
        </div>

        <div
          :if={@world}
          class="rounded-xl border border-zinc-800 bg-zinc-900/60 px-3 py-2"
        >
          <div class="flex items-center gap-3">
            <button
              phx-click="toggle-setup"
              class="text-sm font-medium text-zinc-200 hover:text-white"
            >
              {if @setup_open?, do: "▾", else: "▸"} Mesa de calibragem
            </button>
            <span class="text-xs text-zinc-500">
              os números que eu chutei — troque pelos do seu jogo
            </span>
            <span :if={@setup != %{}} class="text-xs text-emerald-300">
              salva em ~/.pokex/sim_setup.json
            </span>
          </div>

          <form :if={@setup_open?} id="sim-mesa" phx-submit="save-setup" class="mt-3 space-y-3">
            <div :for={{titulo, campos} <- setup_groups()}>
              <p class="mb-1 text-xs font-medium text-zinc-400">{titulo}</p>
              <div class="flex flex-wrap gap-2">
                <label :for={{chave, rotulo} <- campos} class="text-[11px] text-zinc-500">
                  {rotulo}
                  <input
                    type="number"
                    min="0"
                    name={chave}
                    value={knob_value(assigns, chave)}
                    class="ml-1 w-20 rounded border border-zinc-700 bg-zinc-950 px-1.5 py-0.5 text-xs text-zinc-200"
                  />
                </label>
              </div>
            </div>

            <%!-- A barra DELE, na ordem dele, com o trabalho de cada tecla
                  escrito. Antes era uma grade de "0..9 min max" sem dizer qual
                  tecla fazia o quê — e pedia dano de uma tecla de buff. --%>
            <div>
              <p class="mb-1 text-pk-meta font-semibold text-pk-text-2">
                Dano por skill — {bar_owner(@world)}
              </p>
              <table class="w-full text-left text-pk-meta">
                <thead class="text-pk-text-3">
                  <tr>
                    <th class="py-0.5 pr-2 font-semibold">tecla</th>
                    <th class="py-0.5 pr-2 font-semibold">o que faz</th>
                    <th class="py-0.5 pr-2 font-semibold">mín</th>
                    <th class="py-0.5 pr-2 font-semibold">máx</th>
                    <th class="py-0.5 font-semibold">agora</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={chave <- bar_order(@world)} class="border-t border-pk-line">
                    <td class="pk-num py-0.5 pr-2 font-mono font-bold text-pk-text">{chave}</td>
                    <td class="py-0.5 pr-2 text-pk-text-2">{job_label(@world, chave)}</td>
                    <td class="py-0.5 pr-2">
                      <input
                        :if={damages?(@world, chave)}
                        type="number"
                        min="0"
                        name={"dmg_min_" <> chave}
                        value={elem(tuned(@setup, chave), 0)}
                        placeholder="—"
                        class="w-16 rounded border border-pk-line-strong bg-pk-bg px-1 py-0.5 text-pk-meta text-pk-text"
                      />
                    </td>
                    <td class="py-0.5 pr-2">
                      <input
                        :if={damages?(@world, chave)}
                        type="number"
                        min="0"
                        name={"dmg_max_" <> chave}
                        value={elem(tuned(@setup, chave), 1)}
                        placeholder="—"
                        class="w-16 rounded border border-pk-line-strong bg-pk-bg px-1 py-0.5 text-pk-meta text-pk-text"
                      />
                    </td>
                    <td class="pk-num py-0.5 font-mono text-pk-text-3">
                      {band_label(@world, chave)}
                    </td>
                  </tr>
                </tbody>
              </table>
              <p class="mt-1 text-pk-meta text-pk-text-3">
                em branco usa o combo ou o meu chute · a vida do monstro e o dano estão na MESMA
                unidade ({@world && @world.knobs.mob_hp} de vida)
              </p>
            </div>

            <div class="flex items-center gap-2">
              <button
                type="submit"
                class="rounded-lg bg-emerald-600 px-3 py-1 text-xs font-medium text-white hover:bg-emerald-500"
              >
                Salvar e recomeçar
              </button>
              <button
                type="button"
                phx-click="reset-setup"
                class="rounded-lg border border-zinc-700 px-3 py-1 text-xs text-zinc-300 hover:bg-zinc-800"
              >
                Voltar aos meus chutes
              </button>
              <span class="text-[11px] text-zinc-600">
                a vida do monstro e o dano estão na MESMA unidade
              </span>
            </div>
          </form>
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
                <%!-- DORMINDO tem contorno próprio, não cor própria: a cor já
                      carrega a vida, e o sono é o que decide se aquele bicho vai
                      morder no instante em que o campo esvaziar. --%>
                <rect
                  :for={mob <- @mobs}
                  x={elem(mob.pos, 0) - 0.5}
                  y={elem(mob.pos, 1) - 0.5}
                  width="1"
                  height="1"
                  fill={mob_fill(World.hp_pct(mob))}
                  fill-opacity={if World.asleep?(mob, @world), do: "0.45", else: "1"}
                  stroke={
                    if World.asleep?(mob, @world), do: "rgb(125 211 252)", else: "rgb(24 24 27)"
                  }
                  stroke-width={if World.asleep?(mob, @world), do: "0.18", else: "0.08"}
                  stroke-dasharray={if World.asleep?(mob, @world), do: "0.25 0.2", else: nil}
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

        <%!-- AS QUATRO. O placar comparava dois cérebros com exatidão e não
              sabia dizer um número absoluto, porque o dano por baixo dele era
              chutado. Estas quatro leituras saem da mesma noite que ele caça,
              e o botão as gasta. --%>
        <%!-- O PLACAR DA NOITE: as mesmas perguntas do placar simulado, feitas
              ao rastro que o bot deixou. O que se compara entre os dois não são
              as taxas — as de lá saem de um mundo inventado — é a FORMA: se a
              caçada real gasta o minuto onde a simulada gasta, o simulador está
              dizendo a verdade sobre a caçada. --%>
        <section
          :if={@noite}
          id="placar-da-noite"
          class="space-y-2 rounded-lg border border-pk-line bg-pk-surface p-3"
        >
          <header class="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
            <h2 class="text-pk-title font-bold text-pk-text">O placar da noite</h2>
            <p class="pk-num font-mono text-pk-meta text-pk-text-3">
              {@noite.minutes} min de rastro
            </p>
          </header>

          <dl class="grid grid-cols-2 gap-px overflow-hidden rounded border border-pk-line bg-pk-line sm:grid-cols-3 lg:grid-cols-5">
            <div :for={cell <- noite_readouts(@noite)} class="bg-pk-sunken px-3 py-2">
              <dt class="text-pk-meta font-semibold uppercase tracking-[0.12em] text-pk-text-3">
                {cell.label}
              </dt>
              <dd class={["pk-num mt-1 font-mono text-pk-title font-bold", cell.tone]}>
                {cell.value}
              </dd>
              <dd class="text-pk-meta text-pk-text-2">{cell.note}</dd>
            </div>
          </dl>

          <div
            :if={@noite.by_phase != []}
            class="space-y-1 rounded border border-pk-line bg-pk-sunken p-2"
          >
            <h3 class="text-pk-meta font-semibold uppercase tracking-[0.12em] text-pk-text-3">
              Onde foi o minuto, no jogo
            </h3>
            <dl class="flex flex-wrap gap-x-4 gap-y-1">
              <div :for={slice <- @noite.by_phase} class="flex items-baseline gap-1">
                <dt class="text-pk-body text-pk-text-2">{phase_label(slice.phase)}</dt>
                <dd class="pk-num font-mono text-pk-body font-bold text-pk-text">{slice.pct}%</dd>
              </div>
            </dl>
          </div>

          <%!-- O INTERVALO ENTRE TECLAS, RESPONDIDO PELO JOGO. Quanto ele
                aceita não é uma discussão: uma tecla que saiu deixa de estar
                pronta, e o recibo lê isso. Duas noites com intervalos
                diferentes decidem sozinhas. --%>
          <div
            :if={@noite.keys != %{}}
            class="space-y-1 rounded border border-pk-line bg-pk-sunken p-2"
          >
            <h3 class="text-pk-meta font-semibold uppercase tracking-[0.12em] text-pk-text-3">
              As teclas que realmente saíram
            </h3>
            <table class="w-full text-left text-pk-body">
              <thead>
                <tr class="text-pk-meta uppercase tracking-[0.12em] text-pk-text-3">
                  <th class="py-1 pr-3 font-semibold">intervalo</th>
                  <th class="py-1 pr-3 text-right font-semibold">rajadas</th>
                  <th class="py-1 pr-3 text-right font-semibold">saíram</th>
                  <th class="py-1 pr-3 text-right font-semibold">falharam</th>
                  <th class="py-1 text-right font-semibold">taxa</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={{gap, t} <- Enum.sort(@noite.keys)} class="border-t border-pk-line">
                  <td class="pk-num py-1 pr-3 font-mono text-pk-text">{gap}ms</td>
                  <td class="pk-num py-1 pr-3 text-right font-mono text-pk-text-2">{t.rajadas}</td>
                  <td class="pk-num py-1 pr-3 text-right font-mono text-pk-text">{t.sairam}</td>
                  <td class={[
                    "pk-num py-1 pr-3 text-right font-mono",
                    if(t.falharam > 0, do: "text-pk-warn", else: "text-pk-text-2")
                  ]}>
                    {t.falharam}
                  </td>
                  <td class="pk-num py-1 text-right font-mono font-bold text-pk-text">
                    {if t.taxa, do: "#{t.taxa}%", else: "—"}
                  </td>
                </tr>
              </tbody>
            </table>
            <p class="text-pk-meta text-pk-text-2">
              o que já estava esfriando quando a rajada saiu fica fora da conta — sobre
              essa tecla o recibo não tem o que dizer
            </p>
          </div>

          <%!-- A RÉGUA DELE DISCUTIDA COM O QUE O JOGO ENTREGA, em vez de com o
                que eu imagino: quantas vezes a lista de batalha teve 1, 2, 3… --%>
          <div
            :if={@noite.piles != %{}}
            class="space-y-1 rounded border border-pk-line bg-pk-sunken p-2"
          >
            <h3 class="text-pk-meta font-semibold uppercase tracking-[0.12em] text-pk-text-3">
              As pilhas que ele encontrou
            </h3>
            <dl class="flex flex-wrap gap-x-4 gap-y-1">
              <div
                :for={{quantos, vezes} <- Enum.sort(@noite.piles)}
                class="flex items-baseline gap-1"
              >
                <dt class="text-pk-body text-pk-text-2">{quantos} na lista</dt>
                <dd class="pk-num font-mono text-pk-body font-bold text-pk-text">{vezes}</dd>
              </div>
            </dl>
          </div>
        </section>

        <section
          id="quatro-medicoes"
          class="space-y-2 rounded-lg border border-pk-line bg-pk-surface p-3"
        >
          <header class="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
            <h2 class="text-pk-title font-bold text-pk-text">As quatro medições do jogo</h2>
            <p class="pk-num font-mono text-pk-meta text-pk-text-3">
              {@calib.vitals} leituras hoje
            </p>
          </header>

          <dl class="grid grid-cols-1 gap-px overflow-hidden rounded border border-pk-line bg-pk-line sm:grid-cols-2">
            <div :for={m <- measurements(@calib)} class="bg-pk-sunken px-3 py-2">
              <dt class="text-pk-meta font-semibold uppercase tracking-[0.12em] text-pk-text-3">
                {m.label}
              </dt>
              <dd class={["pk-num mt-0.5 font-mono text-pk-body font-bold", m.tone]}>{m.value}</dd>
              <dd class="text-pk-meta text-pk-text-2">{m.note}</dd>
            </div>
          </dl>

          <div class="flex flex-wrap items-center gap-2">
            <button
              phx-click="use-measured"
              disabled={Calibrate.knobs(@calib.date) == %{}}
              class="rounded-lg border border-pk-ok-line bg-pk-ok-dim px-2.5 py-1 text-pk-meta font-bold text-pk-ok hover:bg-pk-ok/20 disabled:cursor-not-allowed disabled:border-pk-line-strong disabled:bg-transparent disabled:text-pk-text-3"
            >
              Usar o que a noite mediu
            </button>
            <p :if={@measured_note} class="pk-num font-mono text-pk-meta text-pk-ok">
              {map_size(@measured_note)} botão(ões) trocado(s): {@measured_note
              |> Map.keys()
              |> Enum.join(", ")}
            </p>
            <p :if={is_nil(@measured_note)} class="text-pk-meta text-pk-text-2">
              troca só o que a noite mediu — o resto do painel fica como está
            </p>
          </div>

          <%!-- O placar conta segundos. Se o F4 gasta item, a conta de verdade
                tem uma segunda moeda, e ela não está em lugar nenhum do
                simulador — então pelo menos está dita. --%>
          <p class="flex items-start gap-1.5 text-pk-meta leading-relaxed text-pk-text-2">
            <.icon name="hero-exclamation-triangle" class="mt-px size-3.5 shrink-0 text-pk-warn" />
            <span>
              <b class="text-pk-text">O que o placar não cobra:</b>
              se o F4 gasta um item de revive, cada revive proativo tem preço em
              INVENTÁRIO, não só nos segundos fora de campo. O simulador conta segundos;
              a conta dos itens é o número de <b class="text-pk-text">revives aceitos</b>
              no placar.
            </span>
          </p>

          <p class="border-t border-pk-line pt-2 text-pk-meta leading-relaxed text-pk-text-2">
            <b class="text-pk-text">Como medir:</b>
            cace com o cavebot rodando — os três primeiros saem sozinhos. Pro quarto, com a <b class="text-pk-text">barra gasta e bicho na tela</b>, aperte <code class="font-mono">F4</code>: ele recolhe, usa o revive e devolve o pokémon
            pro campo de uma vez só. O bot lê o antes e o depois e diz se as skills voltaram
            prontas. Ele mede o que ACONTECEU, então trocar de pokémon no
            <code class="font-mono">Ctrl+1..6</code>
            também responde — mas aí quem volta é
            outro bicho, o que é outra decisão.
          </p>
        </section>

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

        <%!-- O PLACAR. Painel de instrumento, não dashboard: fio de 1px entre
              células, número mono tabular, rótulo em caixa alta. O que ele
              pergunta nunca é "essa corrida foi boa", é "esse cérebro é melhor
              que aquele" — então tudo aqui é medido duas vezes. --%>
        <section
          :if={@score}
          id="placar"
          class="space-y-3 rounded-lg border border-pk-line bg-pk-surface p-3"
        >
          <header class="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
            <h2 class="text-pk-title font-bold text-pk-text">Placar da caçada</h2>
            <p class="pk-num font-mono text-pk-meta text-pk-text-3">
              {length(@score.rows)} cenários · {@score.minutes} min cada · engaja a partir de {@score.config.engage_from} · piso do reset {@score.config.reset_revive_cooldown_ms}ms
            </p>
          </header>

          <dl class="grid grid-cols-2 gap-px overflow-hidden rounded border border-pk-line bg-pk-line sm:grid-cols-3 lg:grid-cols-6">
            <div :for={cell <- score_readouts(@score.totals)} class="bg-pk-sunken px-3 py-2">
              <dt class="text-pk-meta font-semibold uppercase tracking-[0.12em] text-pk-text-3">
                {cell.label}
              </dt>
              <dd class={["pk-num mt-1 font-mono text-pk-title font-bold", cell.tone]}>
                {cell.value}
              </dd>
              <dd class="text-pk-meta text-pk-text-2">{cell.note}</dd>
            </div>
          </dl>

          <%!-- ONDE FOI O MINUTO. Uma taxa por minuto diz que a caçada está
                lenta; isto diz qual fase comeu o tempo, que é a única versão do
                número da qual dá pra escolher um botão. --%>
          <div class="space-y-1 rounded border border-pk-line bg-pk-sunken p-2">
            <h3 class="text-pk-meta font-semibold uppercase tracking-[0.12em] text-pk-text-3">
              Onde foi o minuto
            </h3>

            <dl class="flex flex-wrap gap-x-4 gap-y-1">
              <div :for={slice <- phase_shares(@score.rows)} class="flex items-baseline gap-1">
                <dt class="text-pk-body text-pk-text-2">{phase_label(slice.phase)}</dt>
                <dd class="pk-num font-mono text-pk-body font-bold text-pk-text">
                  {slice.pct}%
                </dd>
              </div>
            </dl>
          </div>

          <%!-- O CÉREBRO CONTRA O CÉREBRO: o mesmo mundo, a mesma semente, e só
                as três chaves que o banco achou que pagam o próprio preço. --%>
          <div class="space-y-2 rounded border border-pk-line bg-pk-sunken p-2">
            <div class="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
              <h3 class="text-pk-meta font-semibold uppercase tracking-[0.12em] text-pk-text-3">
                Hoje → com o F4 proativo (R3b)
              </h3>
              <p class="text-pk-meta text-pk-text-2">
                mesmo mundo, mesma semente — só a regra muda
              </p>
            </div>

            <p class="text-pk-body text-pk-text-2">
              <span class="pk-num font-mono font-bold text-pk-text">
                {@score.totals.without.kills} → {@score.totals.with.kills} monstros
              </span>
              <span class={[
                "pk-num ml-1 font-mono",
                delta_class(delta_pct(@score.totals.without.kills, @score.totals.with.kills))
              ]}>
                {delta_text(delta_pct(@score.totals.without.kills, @score.totals.with.kills))}
              </span>
              · quedas
              <span class="pk-num font-mono font-bold text-pk-text">
                {@score.totals.without.deaths} → {@score.totals.with.deaths}
              </span>
              · pilhas abandonadas
              <span class="pk-num font-mono font-bold text-pk-text">
                {@score.totals.without.vanished} → {@score.totals.with.vanished}
              </span>
              · revives
              <span class="pk-num font-mono font-bold text-pk-text">
                {@score.totals.without.revives_per_min} → {@score.totals.with.revives_per_min}/min
              </span>
              · sua vida no fim
              <span class="pk-num font-mono font-bold text-pk-text">
                {@score.totals.without.player_hp}% → {@score.totals.with.player_hp}%
              </span>
            </p>

            <p class="flex items-start gap-1.5 text-pk-meta text-pk-text-2">
              <.icon name="hero-information-circle" class="mt-px size-3.5 shrink-0 text-pk-info" />
              <span>
                O preço de um revive é o <b class="text-pk-text">campo vazio</b>: pelo
                settle não há nada seu lá fora e cada mordida passa a ser sua. Uma pilha
                DORMINDO não cobra esse preço — é por isso que o resgate aperta o controle
                guardado primeiro, espera o sono cair, e só então recolhe. A coluna da
                direita roda com
                <span :for={{key, value} <- @score.tuning}>
                  <code class="font-mono">{key}</code>
                  <span class="pk-num font-mono text-pk-text">{inspect(value)}</span> ·
                </span>
                e é a mesma caçada sem esse prefixo. Ele só sai se o pokémon em campo tiver
                uma skill de <b class="text-pk-text">controle</b>
                marcada no /time — sem ela
                não há o que apertar, e o revive volta a esvaziar o campo com a pilha
                acordada.
              </span>
            </p>
          </div>

          <div class="overflow-x-auto">
            <table class="w-full text-left text-pk-body">
              <thead>
                <tr class="text-pk-meta uppercase tracking-[0.12em] text-pk-text-3">
                  <th class="py-1 pr-3 font-semibold">cenário</th>
                  <th class="py-1 pr-3 text-right font-semibold">mortos/min · Δ R3b</th>
                  <th class="py-1 pr-3 text-right font-semibold">quedas/min</th>
                  <th class="py-1 pr-3 text-right font-semibold">sumiram/min</th>
                  <th class="py-1 pr-3 text-right font-semibold">sem cooldown · com R3b</th>
                  <th class="py-1 pr-3 text-right font-semibold">no chão</th>
                  <th class="py-1 pr-3 text-right font-semibold">pilha</th>
                  <th class="py-1 text-right font-semibold">revives</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @score.rows} class="border-t border-pk-line align-baseline">
                  <td class="py-1 pr-3 text-pk-text">{row.scenario.name}</td>
                  <td class="pk-num py-1 pr-3 text-right font-mono text-pk-text">
                    {row.without.kills_per_min}
                    <span class={["ml-1", delta_class(delta_pct(row.without.kills, row.with.kills))]}>
                      {delta_text(delta_pct(row.without.kills, row.with.kills))}
                    </span>
                  </td>
                  <td class={[
                    "pk-num py-1 pr-3 text-right font-mono",
                    if(row.without.deaths > 0, do: "font-bold text-pk-danger", else: "text-pk-text-2")
                  ]}>
                    {row.without.deaths_per_min}
                  </td>
                  <td class={[
                    "pk-num py-1 pr-3 text-right font-mono",
                    if(row.without.vanished > 0, do: "text-pk-warn", else: "text-pk-text-2")
                  ]}>
                    {row.without.vanished_per_min}
                  </td>
                  <td class="pk-num py-1 pr-3 text-right font-mono text-pk-text-2">
                    {row.without.stalled_pct}% → {row.with.stalled_pct}%
                  </td>
                  <td class={[
                    "pk-num py-1 pr-3 text-right font-mono",
                    if(row.without.down_pct > 20,
                      do: "font-bold text-pk-danger",
                      else: "text-pk-text-2"
                    )
                  ]}>
                    {row.without.down_pct}%
                  </td>
                  <td class="pk-num py-1 pr-3 text-right font-mono text-pk-text-2">
                    {ms_text(row.without.pile_ms.median)}
                  </td>
                  <td class="pk-num py-1 text-right font-mono text-pk-text-2">
                    {row.without.revives.accepted}
                    <span :if={row.without.revives.refused > 0} class="text-pk-warn">
                      +{row.without.revives.refused} recusados
                    </span>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <p class="border-t border-pk-line pt-2 text-pk-meta leading-relaxed text-pk-text-2">
            <b class="text-pk-text">O que estes números valem:</b>
            a aritmética é exata, o mundo por baixo dela é chutado. Vida de monstro,
            dano por skill, cooldown, mordida e o tempo que o F4 deixa o pokémon na bola
            nunca foram medidos no jogo. <b class="text-pk-text">Comparação vale</b>
            — mesmo mundo, mesma semente, a diferença é do cérebro.
            <b class="text-pk-text">Número absoluto não vale</b>
            — "5 monstros por minuto" é uma propriedade dos meus chutes, não do Ratata. <br />
            <b class="text-pk-text">O que NÃO é chute</b>
            são os pisos: o tempo entre dois resgates é o
            <code class="font-mono">rescue_cooldown_ms</code>
            que você configurou ({div(@score.config.rescue_cooldown_ms, 1000)}s), e é ele
            que decide quantos revives a noite comporta. Enquanto ele não passa, o revive
            não é uma opção — e nenhuma banda pode segurar a rota esperando por um.
          </p>
        </section>

        <div :if={@bench_all} class="rounded-xl border border-violet-900/60 bg-violet-950/20 p-3">
          <h2 class="mb-1 text-sm font-semibold text-violet-100">
            Todos os cenários
            <span class="font-normal text-violet-300/70">
              — um minuto cada, com os botões que o bot está usando agora
            </span>
          </h2>
          <p class="mb-2 font-mono text-xs text-violet-300/70">
            engaja a partir de {@bench_all.config.engage_from} · {if @bench_all.config.gather_piles,
              do: "juntando pilha",
              else: "sem juntar pilha"} · assenta em {@bench_all.config.pile_settle_ms}ms · teto {@bench_all.config.size_ceiling_ms}ms
          </p>
          <div class="overflow-x-auto">
            <table class="w-full text-left text-xs">
              <thead class="text-violet-300/70">
                <tr>
                  <th class="py-1 pr-3 font-medium">cenário</th>
                  <th class="py-1 pr-3 font-medium">fim</th>
                  <th class="py-1 pr-3 text-right font-medium">mortos</th>
                  <th class="py-1 pr-3 text-right font-medium">sumiram</th>
                  <th class="py-1 pr-3 text-right font-medium">de pé</th>
                  <th class="py-1 pr-3 text-right font-medium">vida</th>
                  <th class="py-1 font-medium">fases</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @bench_all.rows} class="border-t border-violet-900/40">
                  <td class="py-1 pr-3 text-violet-100">{row.name}</td>
                  <td class={"py-1 pr-3 #{ending_class(row.outcome.ended)}"}>
                    {ending_text(row.outcome.ended)}
                  </td>
                  <td class="py-1 pr-3 text-right tabular-nums text-zinc-300">
                    {row.outcome.killed}
                  </td>
                  <td class={"py-1 pr-3 text-right tabular-nums #{if row.outcome.vanished > 0, do: "text-amber-400", else: "text-zinc-500"}"}>
                    {row.outcome.vanished}
                  </td>
                  <td class="py-1 pr-3 text-right tabular-nums text-zinc-300">
                    {row.outcome.left_alive}
                  </td>
                  <td class="py-1 pr-3 text-right tabular-nums text-zinc-300">
                    {row.outcome.hp_at_end}%
                  </td>
                  <td class="py-1 font-mono text-[11px] text-zinc-400">
                    {Enum.join(row.outcome.phases, " › ")}
                  </td>
                </tr>
              </tbody>
            </table>
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
                <span>
                  {row.name}
                  <span :if={row.asleep?} class="text-sky-300">· dormindo</span>
                </span>
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
