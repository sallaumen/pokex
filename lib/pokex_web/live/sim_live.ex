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
  alias Pokex.Sim.DamageLevel
  alias Pokex.Sim.Setup
  alias Pokex.Sim.Verdict
  alias Pokex.Sim.World

  @directions %{
    "ArrowRight" => "right",
    "ArrowLeft" => "left",
    "ArrowUp" => "up",
    "ArrowDown" => "down"
  }

  # OS TRÊS GRAUS DE APROXIMAÇÃO, em tiles de meia-largura a partir do
  # personagem. `:perto` é o enquadramento do jogo (Tibia mostra 15x11 em volta
  # do personagem, e um pouco mais largo mantém na tela o que está prestes a
  # entrar); `:medio` é o que faltava — longe o bastante pra ver a próxima
  # esquina chegando, perto o bastante pra contar bicho; `:rota` desenha a volta
  # inteira e responde "onde estou na lap".
  @zoom_spans %{perto: 11, medio: 26}
  @zooms [:rota, :medio, :perto]

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
       bench_verdict: [],
       bench_all: nil,
       # O SELO DE CADA CENÁRIO já rodado nesta sessão: id => :ok |
       # :falhou | :sem_promessa. É o que faz a gaveta de cenários virar
       # um painel — sem ele, saber como cada um foi exige abrir treze.
       seals: %{},
       score: nil,
       measured_note: nil,
       setup: saved,
       setup_open?: false,
       zoom: :rota,
       calib: Calibrate.report(Date.utc_today()),
       night: Tally.of_day(Date.utc_today()),
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

  # UM CLIQUE VALE NA HORA. O formulário só salva no botão Salvar, e um nível
  # que não muda nada até ele achar outro botão não é "selecionar clicando".
  # Grava direto, sem passar pelo formulário: os outros campos podem estar
  # sendo digitados e um clique que não é sobre eles não pode sobrescrevê-los.
  def handle_event("dmg_one", %{"key" => key, "level" => level}, socket),
    do: write_damage(socket, [key], level)

  # O COOLDOWN DE UMA TECLA, em segundos. Campo vazio é "não sei" e volta pro
  # chute global — apagar tem que ser possível, senão um número digitado por
  # engano fica pra sempre.
  def handle_event("set_cooldown", %{"key" => key, "segundos" => segundos}, socket) do
    saved = Map.get(socket.assigns.setup, :skill_cooldowns, %{})

    cooldowns =
      case cooldown_ms(segundos) do
        nil -> Map.delete(saved, key)
        ms -> Map.put(saved, key, ms)
      end

    knobs =
      socket.assigns.setup
      |> Map.put(:skill_cooldowns, cooldowns)

    Setup.write(knobs)

    {:noreply,
     socket |> assign(setup: knobs, bench: nil, bench_verdict: [], seals: %{}) |> reload_world()}
  end

  # A BARRA INTEIRA de uma vez. Ele tem dez teclas, e "facilita pra mim" não
  # combina com dez cliques pra montar um experimento que ele vai repetir por
  # vida de monstro.
  def handle_event("dmg_all", %{"level" => level}, socket),
    do: write_damage(socket, damaging_keys(socket.assigns.world), level)

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

  def handle_event("toggle-setup", _params, socket),
    do: {:noreply, assign(socket, setup_open?: not socket.assigns.setup_open?)}

  # Saved to disk, not just to the socket: "calibrar" only means anything if he
  # does it once. A number he has to retype after every restart is a number he
  # will stop trusting and then stop setting.
  def handle_event("save-setup", params, socket) do
    knobs = parse_setup(params)
    Setup.write(knobs)

    socket |> assign(setup: knobs, bench: nil, bench_verdict: [], seals: %{}) |> reload_world()
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
    |> assign(
      setup: knobs,
      bench: nil,
      bench_verdict: [],
      seals: %{},
      bench_all: nil,
      score: nil,
      measured_note: measured
    )
    |> reload_world()
  end

  def handle_event("reset-setup", _params, socket) do
    Setup.clear()

    socket |> assign(setup: %{}, bench: nil, bench_verdict: [], seals: %{}) |> reload_world()
  end

  def handle_event("zoom", %{"level" => level}, socket) do
    case Enum.find(@zooms, &(Atom.to_string(&1) == level)) do
      nil -> {:noreply, socket}
      zoom -> {:noreply, assign(socket, zoom: zoom)}
    end
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
    do: {:noreply, assign(load_scenario(socket, id), bench: nil, bench_verdict: [])}

  # Runs the scenario through the PURE engine core — no process, no clock, one
  # minute of hunting in a few milliseconds — and answers with a verdict instead
  # of an impression.
  def handle_event("bench", _params, socket) do
    case socket.assigns.scenario do
      nil ->
        {:noreply, socket}

      scenario ->
        report = Bench.run(scenario, routes: socket.assigns.routes, knobs: extra_knobs(socket))

        {:noreply,
         assign(socket,
           bench: report,
           # …e a PROMESSA cobrada junto. Um relatório sem o veredito devolve
           # seis números e deixa pra ele lembrar qual era a pergunta daquele
           # cenário; com treze deles isso é trabalho de arqueólogo.
           bench_verdict: Verdict.judge(report, scenario.espera),
           seals: Map.put(socket.assigns.seals, scenario.id, seal_of(report, scenario))
         )}
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
        report =
          Bench.run(scenario,
            routes: socket.assigns.routes,
            config: config,
            knobs: extra_knobs(socket)
          )

        %{
          id: scenario.id,
          name: scenario.name,
          icon: scenario.icon,
          outcome: report.outcome,
          verdict: Verdict.judge(report, scenario.espera),
          seal: seal_of(report, scenario)
        }
      end)

    {:noreply,
     assign(socket,
       bench_all: %{rows: rows, config: config},
       # OS SELOS DA BIBLIOTECA INTEIRA de uma vez — é o que transforma a
       # gaveta de cenários num painel que se lê de relance.
       seals: Map.new(rows, &{&1.id, &1.seal})
     )}
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
        # A MESA DELE VAI JUNTO, como já vai no "Rodar todos" logo acima. Sem
        # isto o placar jogava fora a tabela de calibração inteira — e a
        # própria tela invalida o placar quando ela muda, ou seja, ela já sabia
        # que o placar depende dela.
        knobs = extra_knobs(socket)

        %{card: without} = Score.hunt(scenario, minutes: minutes, config: config, knobs: knobs)

        %{card: with_tuning} =
          Score.hunt(scenario, minutes: minutes, config: tuned, knobs: knobs)

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
  defp write_damage(socket, keys, level) do
    saved = Map.get(socket.assigns.setup, :skill_damage, %{})

    case damage_for(level) do
      :unknown ->
        {:noreply, socket}

      # `:padrao` tira o nível e devolve o chute em %. Só das teclas que ESTÃO
      # num dos quatro: uma faixa que ele digitou à mão sobrevive, pelo mesmo
      # motivo que ela sobrevive tecla a tecla — apagar em silêncio o que ele
      # mediu seria pior do que oferecer um botão a menos.
      nil ->
        keep = Enum.reject(keys, &match?({:custom, _}, DamageLevel.of(saved[&1])))
        save_damage(socket, Map.drop(saved, keep))

      band ->
        save_damage(socket, Enum.reduce(keys, saved, &Map.put(&2, &1, band)))
    end
  end

  defp cooldown_ms(segundos) do
    case Float.parse(String.trim(segundos)) do
      {s, _rest} when s >= 1 and s <= 600 -> round(s * 1_000)
      _vazio_ou_fora_de_faixa -> nil
    end
  end

  # O QUE APARECE NO CAMPO: a mesa primeiro (é o experimento), depois o que ele
  # gravou no /time pra este pokémon. Vazio quer dizer "cai no chute global",
  # e o placeholder mostra qual é esse chute.
  defp cooldown_seconds(setup, world, key) do
    ms =
      Map.get(Map.get(setup, :skill_cooldowns, %{}), key) ||
        (world && get_in(world.keys, [key, :cooldown_ms]))

    if ms, do: seconds_label(ms), else: ""
  end

  defp cooldown_placeholder(world),
    do: if(world, do: seconds_label(world.knobs.skill_cooldown_ms), else: "s")

  defp seconds_label(ms) do
    segundos = ms / 1_000
    if segundos == trunc(segundos), do: "#{trunc(segundos)}", else: "#{segundos}"
  end

  defp damage_for(level) do
    DamageLevel.band(String.to_existing_atom(level))
  rescue
    ArgumentError -> :unknown
  end

  # O combo vive no socket, não no `setup` lido do disco — `toggle-kill-key` só
  # mexe no socket. Sem costurá-lo de volta, gravar a mesa por qualquer outro
  # caminho apaga o que ele acabou de marcar, e ele só descobre no F5 seguinte.
  # É o que `save-setup` já fazia, e o que faltava aqui.
  defp save_damage(socket, damage) do
    knobs =
      socket.assigns.setup
      |> Map.put(:skill_damage, damage)

    Setup.write(knobs)
    socket |> assign(setup: knobs, bench: nil, bench_verdict: [], seals: %{}) |> reload_world()
  end

  defp extra_knobs(socket), do: socket.assigns.setup

  defp kind_label(:aoe), do: "área"
  defp kind_label(:single), do: "alvo"
  defp kind_label(:buffs), do: "aura dano"
  defp kind_label(:shield), do: "aura defesa"
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

  defp level_of(setup, key), do: setup |> tuned_band(key) |> DamageLevel.of()

  defp custom_label({:custom, {lo, hi}}), do: "#{lo}~#{hi} (seu)"
  defp custom_label(_level), do: ""

  # Só é mistura quando ele JÁ escolheu algum nível: uma barra inteira em padrão
  # é o comportamento de sempre, e avisar sobre ela seria ruído.
  defp mixed_units?(setup, world) do
    DamageLevel.mixed?(Map.get(setup, :skill_damage, %{}), damaging_keys(world))
  end

  defp damaging_keys(nil), do: []
  defp damaging_keys(world), do: Enum.filter(bar_order(world), &damages?(world, &1))

  # O que as teclas em padrão tiram desta vida — o número que torna o aviso
  # concreto em vez de uma advertência genérica.
  #
  # Sai de `World.damage_band/2`, que é EXATAMENTE de onde vem a coluna "agora"
  # da mesma linha. A primeira versão usava `aoe_damage_pct` para qualquer
  # tecla, e errava em duas das três fontes: uma tecla de alvo único tira
  # `single_damage_pct` (22, não 34), e uma tecla no `kill_combo` tira
  # `mob_hp / length(combo)`. A tabela dizia 94~126 e o aviso logo abaixo dizia
  # 170 — a tela se contradizendo sobre o mesmo número.
  defp pct_hit(nil, _setup), do: "—"

  defp pct_hit(world, setup) do
    saved = Map.get(setup, :skill_damage, %{})

    world
    |> damaging_keys()
    |> Enum.reject(&Map.has_key?(saved, &1))
    |> Enum.map(&World.damage_band(world, &1))
    |> Enum.filter(&match?({_lo, _hi}, &1))
    |> case do
      [] ->
        "—"

      bands ->
        "#{bands |> Enum.map(&elem(&1, 0)) |> Enum.min()} a #{bands |> Enum.map(&elem(&1, 1)) |> Enum.max()} de HP"
    end
  end

  defp tuned_band(setup, key), do: Map.get(setup, :skill_damage, %{})[key]

  # A blank box means "use the default", NOT zero: zero milliseconds per tile
  # is a character that teleports, and that is never what an empty field means.
  defp parse_setup(params) do
    numbers =
      for key <- Setup.tunable(),
          {:ok, n} <- [as_int(params[Atom.to_string(key)])],
          into: %{},
          do: {key, n}

    # O dano é dos CLIQUES, não deste formulário: ele passa por aqui intacto.
    numbers
    |> unpin_at_zero()
    |> Map.put(:skill_damage, Map.get(Setup.read(), :skill_damage, %{}))
  end

  # `nest_size` PINA a pilha: um número liga o pino, `nil` devolve o sorteio ao
  # cenário. Mas a caixa só sabe escrever números, e "0" no formulário quer dizer
  # "não pina" — não "todo ninho tem zero bicho", que é um mundo vazio.
  defp unpin_at_zero(%{nest_size: 0} = knobs), do: Map.delete(knobs, :nest_size)
  defp unpin_at_zero(knobs), do: knobs

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
    stranded: "no chão, sem estoque — parei",
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
  defp night_readouts(night) do
    [
      %{
        label: "mortos/min",
        value: night.kills_per_min,
        tone: "text-pk-text",
        note: "#{night.kills} no total"
      },
      %{
        label: "revives/min",
        value: night.revives_per_min,
        tone: "text-pk-text",
        note: "#{night.revives} prensas"
      },
      %{
        label: "limpezas/min",
        value: night.cures_per_min,
        tone: "text-pk-text",
        note: "#{night.cures} Status Potion"
      },
      %{
        label: "no chão",
        value: "#{night.down_pct}%",
        tone: if(night.down_pct > 10, do: "text-pk-danger", else: "text-pk-text"),
        note: "sem pokémon em campo"
      },
      %{
        label: "sem cooldown",
        value: "#{night.stalled_pct}%",
        tone: "text-pk-text",
        note: "com bicho na tela"
      },
      %{
        label: "leituras",
        value: map_size(night.piles),
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

  defp ending_class(:died), do: "font-semibold text-pk-danger"
  defp ending_class(:clean), do: "text-pk-ok"
  defp ending_class(_still_going), do: "text-pk-warn"

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

  # Os nomes agora podem ser worker OU aba: uma página aberta noutra janela
  # continua fotografando a tela real por cima das chaves que o simulador
  # publica, e "pare a frota" sozinho manda ele consertar a coisa errada.
  defp refusal_text(names) do
    "não dá pra armar com #{Enum.map_join(names, ", ", &to_string/1)} — " <>
      "pare a frota e feche as abas que estão olhando a tela"
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
  defp view_of(%{zoom: zoom, world: %{} = world}, _points) when is_map_key(@zoom_spans, zoom) do
    {x, y, _z} = world.pos
    span = @zoom_spans[zoom]

    {x - span, y - div(span * 3, 4), span * 2, div(span * 3, 2)}
  end

  defp view_of(assigns, points), do: bounds(points ++ character_point(assigns.world))

  # O RACK, respondido pelo mundo e não por conta na tela: `World.cooling/2` é a
  # mesma função que a decisão usa pra saber o que está pronto.
  defp ready?(world, key), do: elem(World.cooling(world, key), 0) == 0

  defp recuperado_pct(world, key) do
    {_falta, fracao} = World.cooling(world, key)
    round(fracao * 100)
  end

  # Segundo com uma casa até 10s, inteiro depois: o olho lê a contagem final
  # tique a tique e não precisa de precisão nenhuma num cooldown de 45.
  defp missing_text(world, key) do
    {falta, _fracao} = World.cooling(world, key)

    if falta < 10_000,
      do: "#{Float.round(falta / 1_000, 1)}s",
      else: "#{div(falta + 999, 1_000)}s"
  end

  defp ready_count(world), do: Enum.count(bar_order(world), &ready?(world, &1))

  # A JANELA EM QUE O REVIVE AINDA É NOTÍCIA. Meio segundo é o tempo de ele
  # perceber a barra inteira voltando; mais que isso vira enfeite aceso.
  @revive_flash_ms 900
  defp revive_flash?(%{revived_at: at, clock: clock}) when is_integer(at),
    do: clock - at <= @revive_flash_ms

  defp revive_flash?(_never_revived), do: false

  defp tone_badge(:good), do: "bg-pk-ok-dim text-pk-ok"
  defp tone_badge(:paused), do: "bg-pk-raised text-pk-info"
  defp tone_badge(:bad), do: "bg-pk-danger-dim text-pk-danger"
  defp tone_badge(:idle), do: "bg-pk-raised text-pk-text-3"

  defp zoom_label(:rota), do: "rota"
  defp zoom_label(:medio), do: "médio"
  defp zoom_label(:perto), do: "perto"

  defp zoom_hint(:rota), do: "a volta inteira — onde estou na lap"
  defp zoom_hint(:medio), do: "meio caminho: dá pra ver a próxima esquina chegando"
  defp zoom_hint(:perto), do: "o enquadramento do jogo — dá pra contar bicho"

  defp bounds(points) do
    xs = Enum.map(points, &elem(&1, 0))
    ys = Enum.map(points, &elem(&1, 1))
    pad = 8

    {Enum.min(xs, fn -> 0 end) - pad, Enum.min(ys, fn -> 0 end) - pad,
     Enum.max(xs, fn -> 1 end) - Enum.min(xs, fn -> 0 end) + pad * 2,
     Enum.max(ys, fn -> 1 end) - Enum.min(ys, fn -> 0 end) + pad * 2}
  end

  # Só o andar que está sendo olhado: uma parede de outro piso desenhada aqui
  # seria uma parede que não existe pra quem está andando.
  defp visible_blocked(nil, _z), do: []

  defp visible_blocked(world, z),
    do: world.blocked |> Enum.filter(fn {_x, _y, tz} -> tz == z end) |> Enum.sort()

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
    do: "#{orders.why} · rota #{orders.route}, fogo #{orders.fire}"

  defp tone_class(:good), do: "border-pk-ok-line bg-pk-ok-dim text-pk-text"
  defp tone_class(:paused), do: "border-pk-line-strong bg-pk-surface text-pk-text"
  defp tone_class(:bad), do: "border-pk-danger-line bg-pk-danger-dim text-pk-text"
  defp tone_class(:idle), do: "border-pk-line bg-pk-surface text-pk-text-2"

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

  defp band_class(:green), do: "text-pk-ok"
  defp band_class(:yellow), do: "text-pk-warn"
  defp band_class(:red), do: "text-pk-danger"
  defp band_class(_unknown), do: "text-pk-text-2"

  # OS KNOBS QUE O MUNDO APERTOU: `{nome, o que ele pediu, o que vale, por quê}`.
  # Lista vazia quando a mesa dele já é coerente, que é o caso normal.
  @porques %{
    aggro_tiles: "um bicho não nota de mais longe do que a corda deixa ele vir",
    nest_radius:
      "um bicho que nasce fora do alcance de acordar nunca participa da caçada — " <>
        "e ainda ocupa a vaga dele no canto, que para de repor"
  }

  defp apertados(setup) do
    valendo = World.coherent_knobs(setup)

    for {knob, efetivo} <- valendo,
        pedido = Map.get(setup, knob),
        is_integer(pedido),
        pedido != efetivo,
        do: {knob, pedido, efetivo, Map.fetch!(@porques, knob)}
  end

  # --- O LABORATÓRIO ----------------------------------------------------------
  #
  # O selo de um cenário depois de uma corrida. Três respostas, e a terceira
  # importa tanto quanto as outras: um cenário sem promessa não "passou" nem
  # "falhou", ele é de OBSERVAR — e dar-lhe um ✅ diria que uma corrida foi
  # aprovada quando ninguém perguntou nada a ela.
  defp seal_of(report, scenario), do: report |> Verdict.judge(scenario.espera) |> Verdict.seal()

  defp seal_icon(:ok), do: "✅"
  defp seal_icon(:falhou), do: "❌"
  defp seal_icon(:sem_promessa), do: "👁"
  defp seal_icon(_nao_rodou), do: "·"

  defp seal_title(:ok), do: "cumpriu tudo que prometeu"
  defp seal_title(:falhou), do: "quebrou uma promessa — abre o cenário pra ver qual"
  defp seal_title(:sem_promessa), do: "cenário de observar: leia a linha do tempo"
  defp seal_title(_nao_rodou), do: "ainda não rodou nesta sessão"

  # A cor do CARTÃO é a do aperto (o que esperar), nunca a do selo (o que
  # aconteceu): um cenário quebrado de propósito é vermelho antes e depois de
  # rodar, e pintá-lo de verde ao passar diria que a falha foi consertada.
  defp severity_class(:ok), do: "border-pk-ok-line bg-pk-ok-dim"
  defp severity_class(:warn), do: "border-pk-warn-line bg-pk-warn-dim"
  defp severity_class(:danger), do: "border-pk-danger-line bg-pk-danger-dim"

  defp severity_text(:ok), do: "text-pk-ok"
  defp severity_text(:warn), do: "text-pk-warn"
  defp severity_text(:danger), do: "text-pk-danger"

  # Os cenários na ordem da tela, agrupados — e um grupo só aparece com gente
  # dentro, senão um grupo novo e vazio vira um título órfão.
  defp lab_groups(scenarios) do
    by_group = Enum.group_by(scenarios, & &1.group)

    for group <- Scenario.group_order(),
        items = Map.get(by_group, group, []),
        items != [],
        do: {group, items}
  end

  # A DUREZA que este cenário fixa, em teclas. É a linha que avisa que a mesa
  # dele NÃO está mandando aqui — sem ela, ele grava uma faixa de dano, roda o
  # Couraçado e não entende por que nada mudou.
  defp dureza(%{knobs: knobs}) do
    case Map.get(knobs, :presses_to_kill) do
      n when is_integer(n) and n > 0 -> n
      _livre -> nil
    end
  end

  defp dureza(_sem_cenario), do: nil

  @impl true
  def render(assigns) do
    z = floor_of(assigns.world)
    points = legs(assigns.world, z)

    assigns =
      assign(assigns,
        z: z,
        points: points,
        # atributo de módulo não existe dentro do ~H: quem desenha os três graus
        # é a lista, e ela precisa chegar como assign
        zooms: @zooms,
        view_box: view_of(assigns, points),
        blocked: visible_blocked(assigns.world, z),
        mobs: visible_mobs(assigns.world, z),
        truth: truth_rows(assigns.world),
        perceived: perceived_rows(fact(:battle)),
        pokemon_fact: fact(:pokemon),
        hunt_fact: fact(:hunt)
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_page={:sim}
      max_width="max-w-[1600px]"
      {Layouts.header(assigns)}
    >
      <div
        id="sim-board"
        phx-window-keydown="keydown"
        phx-window-keyup="keyup"
        class="space-y-3"
      >
        <%!-- A BARRA DE COMANDO. Uma linha, altura fixa, três grupos separados
              por fio: o que carregar, o que rodar, o que medir. Antes eram doze
              botões de cores diferentes embrulhando em três linhas — cada um
              gritando o mesmo tanto. --%>
        <div class="flex flex-wrap items-center gap-x-2 gap-y-2 rounded-lg border border-pk-line bg-pk-surface px-2 py-2">
          <form id="sim-rota" phx-change="pick-route" class="flex items-center">
            <select
              name="route"
              aria-label="Rota"
              class="h-8 min-h-0 rounded-lg border border-pk-line-strong bg-pk-raised px-2 text-pk-meta text-pk-text focus:border-pk-ok/60 focus:outline-none"
            >
              <option :for={route <- @routes} value={route.name} selected={route.name == @route_name}>
                {route.name} ({length(route.waypoints)} esquinas)
              </option>
            </select>
          </form>

          <form id="sim-cenario" phx-change="pick-scenario" class="flex items-center">
            <select
              name="scenario"
              aria-label="Cenário"
              class="h-8 min-h-0 rounded-lg border border-pk-line-strong bg-pk-raised px-2 text-pk-meta text-pk-text focus:border-pk-ok/60 focus:outline-none"
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

          <span class="h-6 w-px bg-pk-line"></span>

          <button
            :if={!@armed?}
            phx-click="arm"
            class="flex h-8 items-center gap-1.5 rounded-lg bg-pk-ok px-3 text-pk-meta font-bold text-pk-bg transition hover:brightness-110 active:scale-[0.99]"
          >
            <.icon name="hero-bolt-solid" class="size-4" /> Armar
          </button>

          <button
            :if={@armed?}
            phx-click="disarm"
            class="flex h-8 items-center gap-1.5 rounded-lg border border-pk-danger-line bg-pk-danger-dim px-3 text-pk-meta font-bold text-pk-danger transition hover:bg-pk-danger/15"
          >
            <.icon name="hero-power" class="size-4" /> Desarmar
          </button>

          <button
            :if={@armed? and !@playing?}
            phx-click="play"
            class="flex h-8 items-center gap-1.5 rounded-lg border border-pk-ok-line bg-pk-ok-dim px-3 text-pk-meta font-bold text-pk-ok transition hover:bg-pk-ok/20"
          >
            <.icon name="hero-play-solid" class="size-4" /> Rodar
          </button>

          <button
            :if={@armed? and @playing?}
            phx-click="pause"
            class="flex h-8 items-center gap-1.5 rounded-lg border border-pk-line-strong px-3 text-pk-meta font-semibold text-pk-text-2 transition hover:bg-pk-raised hover:text-white"
          >
            <.icon name="hero-pause-solid" class="size-4" /> Pausar
          </button>

          <button
            :if={@armed?}
            phx-click="toggle-auto"
            class={[
              "flex h-8 items-center gap-1.5 rounded-lg border px-3 text-pk-meta font-semibold transition",
              if(@auto?,
                do: "border-pk-ok-line bg-pk-ok-dim text-pk-ok hover:bg-pk-ok/20",
                else: "border-pk-line-strong text-pk-text-2 hover:bg-pk-raised hover:text-white"
              )
            ]}
          >
            <.icon name="hero-cpu-chip" class="size-4" />
            {if @auto?, do: "O cérebro joga", else: "Você joga"}
          </button>

          <span class="h-6 w-px bg-pk-line"></span>

          <button
            :if={@scenario}
            phx-click="bench"
            class="flex h-8 items-center gap-1.5 rounded-lg border border-pk-line-strong px-3 text-pk-meta font-semibold text-pk-text-2 transition hover:bg-pk-raised hover:text-white"
          >
            <.icon name="hero-forward" class="size-4" /> 1 min
          </button>

          <button
            phx-click="bench_all"
            class="flex h-8 items-center gap-1.5 rounded-lg border border-pk-line-strong px-3 text-pk-meta font-semibold text-pk-text-2 transition hover:bg-pk-raised hover:text-white"
          >
            <.icon name="hero-table-cells" class="size-4" /> Todos
          </button>

          <button
            phx-click="score"
            class="flex h-8 items-center gap-1.5 rounded-lg border border-pk-line-strong px-3 text-pk-meta font-semibold text-pk-text-2 transition hover:bg-pk-raised hover:text-white"
          >
            <.icon name="hero-calculator" class="size-4" /> Placar
          </button>

          <button
            phx-click="reload"
            title="Recomeçar do zero"
            aria-label="Recomeçar"
            class="grid size-8 place-items-center rounded-lg border border-pk-line-strong text-pk-text-2 transition hover:border-pk-ok/60 hover:bg-pk-raised hover:text-white"
          >
            <.icon name="hero-arrow-path" class="size-4" />
          </button>

          <p :if={@armed?} class="ml-auto text-pk-meta text-pk-text-3">
            setas andam · <span class="font-mono text-pk-text-2">1–9</span> disparam
          </p>
        </div>

        <%!-- O ESTADO, COM GEOMETRIA FIXA. Antes a caixa crescia e encolhia com
              o tamanho da frase — "isso atrapalha bastante a visibilidade"
              (27/08) —, e a frase muda a cada tique. Agora a altura é cravada,
              o título tem largura própria e a explicação é uma linha só que
              corta no fim. O que muda é o texto, nunca o layout. --%>
        <div class={[
          "flex h-14 items-center gap-3 overflow-hidden rounded-lg border px-3",
          tone_class(status(assigns).tone)
        ]}>
          <%!-- ÍCONE LITERAL, não calculado: o gerador do Tailwind lê o
                template, e um nome montado em runtime (`tone_icon/1`) nunca
                entra no CSS — o quadrado saía vazio. --%>
          <span class={[
            "grid size-8 shrink-0 place-items-center rounded-lg",
            tone_badge(status(assigns).tone)
          ]}>
            <.icon :if={status(assigns).tone == :good} name="hero-signal" class="size-4" />
            <.icon :if={status(assigns).tone == :paused} name="hero-pause" class="size-4" />
            <.icon
              :if={status(assigns).tone == :bad}
              name="hero-exclamation-triangle"
              class="size-4"
            />
            <.icon :if={status(assigns).tone == :idle} name="hero-minus-small" class="size-4" />
          </span>
          <div class="min-w-0">
            <p class="truncate text-pk-body font-bold">{status(assigns).title}</p>
            <p class="truncate text-pk-meta opacity-80">{status(assigns).hint}</p>
          </div>
          <p class="pk-num ml-auto hidden shrink-0 font-mono text-pk-meta tabular-nums opacity-70 sm:block">
            {(@world && @world.clock) || 0}ms
          </p>
        </div>

        <%!-- O RACK DAS TECLAS. Estava aqui "O combo que mata", que era uma
              pergunta de calibragem — e ele pediu o contrário: ver o que a barra
              está fazendo AGORA. Cada tecla mostra o que faz, quanto falta pra
              voltar e uma barra que drena; quando o revive cai, o rack inteiro
              acende por um instante e a etiqueta diz por quê.
              Ver `Pokex.Sim.World.cooling/2`. --%>
        <div
          :if={@world && @world.keys != %{}}
          id="sim-rack"
          class={[
            "rounded-lg border bg-pk-surface p-2 transition-colors duration-500",
            if(revive_flash?(@world),
              do:
                "border-pk-ok shadow-[0_0_0_1px_var(--color-pk-ok),0_8px_24px_rgba(55,208,125,0.18)]",
              else: "border-pk-line"
            )
          ]}
        >
          <div class="mb-1.5 flex items-center gap-2">
            <h2 class="text-pk-meta font-semibold uppercase tracking-[0.12em] text-pk-text-3">
              A barra, agora
            </h2>
            <span
              :if={revive_flash?(@world)}
              class="flex items-center gap-1 rounded-full border border-pk-ok-line bg-pk-ok-dim px-2 py-0.5 text-pk-meta font-bold uppercase tracking-[0.12em] text-pk-ok"
            >
              <.icon name="hero-arrow-path-rounded-square" class="size-3.5" /> revive — barra zerada
            </span>
            <span class="pk-num ml-auto font-mono text-pk-meta text-pk-text-3">
              {ready_count(@world)}/{length(bar_order(@world))} prontas
            </span>
          </div>

          <ol class="grid grid-cols-[repeat(auto-fit,minmax(96px,1fr))] gap-1.5">
            <li
              :for={chave <- bar_order(@world)}
              class={[
                "relative overflow-hidden rounded border px-2 py-1.5",
                if(ready?(@world, chave),
                  do: "border-pk-ok-line bg-pk-ok-dim",
                  else: "border-pk-line bg-pk-sunken"
                )
              ]}
            >
              <%!-- O TRILHO QUE ENCHE. Fica ATRÁS do texto, não do lado: a
                    célula inteira é o medidor, então dá pra ler a barra de longe
                    sem procurar onde está o número. --%>
              <span
                class="absolute inset-y-0 left-0 bg-pk-ok/10 transition-[width] duration-200 ease-linear"
                style={"width: #{recuperado_pct(@world, chave)}%"}
                aria-hidden="true"
              ></span>
              <span class="relative flex items-baseline gap-1.5">
                <span class={[
                  "pk-num font-mono text-pk-title font-bold",
                  if(ready?(@world, chave), do: "text-pk-ok", else: "text-pk-text-3")
                ]}>
                  {chave}
                </span>
                <span class="truncate text-pk-meta text-pk-text-2">
                  {kind_label(@world.keys[chave].kind)}
                </span>
              </span>
              <span class="relative mt-0.5 block">
                <span
                  :if={ready?(@world, chave)}
                  class="text-pk-meta font-bold uppercase tracking-[0.12em] text-pk-ok"
                >
                  pronta
                </span>
                <span
                  :if={!ready?(@world, chave)}
                  class="pk-num font-mono text-pk-body font-bold tabular-nums text-pk-warn"
                >
                  {missing_text(@world, chave)}
                </span>
              </span>
            </li>
          </ol>
        </div>

        <div
          :if={@world}
          class="rounded-lg border border-pk-line bg-pk-surface px-3 py-2"
        >
          <div class="flex items-center gap-3">
            <button
              phx-click="toggle-setup"
              class="text-pk-body font-semibold text-pk-text hover:text-white"
            >
              {if @setup_open?, do: "▾", else: "▸"} Mesa de calibragem
            </button>
            <span class="text-pk-meta text-pk-text-3">
              os números que eu chutei — troque pelos do seu jogo
            </span>
            <span :if={@setup != %{}} class="text-pk-meta text-pk-ok">
              salva em ~/.pokex/sim_setup.json
            </span>
          </div>

          <form :if={@setup_open?} id="sim-mesa" phx-submit="save-setup" class="mt-3 space-y-3">
            <div :for={{titulo, campos} <- setup_groups()}>
              <p class="mb-1 text-pk-meta font-semibold text-pk-text-2">{titulo}</p>
              <div class="flex flex-wrap gap-2">
                <label :for={{chave, rotulo} <- campos} class="text-pk-meta text-pk-text-3">
                  {rotulo}
                  <input
                    type="number"
                    min="0"
                    name={chave}
                    value={knob_value(assigns, chave)}
                    class="ml-1 w-20 h-7 rounded border border-pk-line-strong bg-pk-raised px-1.5 text-pk-meta text-pk-text focus:border-pk-ok/60 focus:outline-none"
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
              <div class="mt-1 flex flex-wrap items-center gap-1 text-pk-meta">
                <span class="text-pk-text-3">a barra toda:</span>
                <button
                  :for={nivel <- DamageLevel.all()}
                  type="button"
                  phx-click="dmg_all"
                  phx-value-level={nivel}
                  title={DamageLevel.note(nivel)}
                  class="rounded border border-pk-line-strong px-1.5 py-0.5 text-pk-text-2 hover:bg-pk-raised"
                >
                  {DamageLevel.label(nivel)}
                </button>
              </div>

              <table class="w-full text-left text-pk-meta">
                <thead class="text-pk-text-3">
                  <tr>
                    <th class="py-0.5 pr-2 font-semibold">tecla</th>
                    <th class="py-0.5 pr-2 font-semibold">o que faz</th>
                    <th class="py-0.5 pr-2 font-semibold">quanto tira</th>
                    <th class="py-0.5 pr-2 font-semibold">agora</th>
                    <th class="py-0.5 font-semibold">volta em</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={chave <- bar_order(@world)} class="border-t border-pk-line">
                    <td class="pk-num py-0.5 pr-2 font-mono font-bold text-pk-text">{chave}</td>
                    <td class="py-0.5 pr-2 text-pk-text-2">{job_label(@world, chave)}</td>
                    <td class="py-0.5 pr-2">
                      <div :if={damages?(@world, chave)} class="flex flex-wrap gap-1">
                        <button
                          :for={nivel <- DamageLevel.all()}
                          type="button"
                          phx-click="dmg_one"
                          phx-value-key={chave}
                          phx-value-level={nivel}
                          title={DamageLevel.note(nivel)}
                          class={[
                            "rounded border px-1.5 py-0.5",
                            if(level_of(@setup, chave) == nivel,
                              do: "border-pk-ok bg-pk-ok/10 text-pk-ok",
                              else: "border-pk-line-strong text-pk-text-3 hover:bg-pk-raised"
                            )
                          ]}
                        >
                          {DamageLevel.label(nivel)}
                        </button>
                        <%!-- Uma faixa que ele digitou à mão antes dos níveis
                              existirem não é nenhum dos quatro. Ela aparece como
                              número, e continua valendo até ele clicar. --%>
                        <span
                          :if={match?({:custom, _}, level_of(@setup, chave))}
                          class="rounded border border-pk-warn px-1.5 py-0.5 text-pk-warn"
                        >
                          {custom_label(level_of(@setup, chave))}
                        </span>
                      </div>
                    </td>
                    <td class="pk-num py-0.5 pr-2 font-mono text-pk-text-3">
                      {band_label(@world, chave)}
                    </td>
                    <%!-- O COOLDOWN DESTA TECLA. O mundo tinha um número só pra
                          barra inteira (45s), e uma barra com tudo igual não tem
                          ordem preferida — nenhuma regra sobre gastar a barra
                          podia ser medida aqui. O que ele grava no /time é a
                          verdade; isto é a mesa do experimento, e vence. --%>
                    <td class="py-0.5">
                      <form phx-change="set_cooldown" phx-value-key={chave}>
                        <input type="hidden" name="key" value={chave} />
                        <input
                          type="number"
                          name="segundos"
                          inputmode="decimal"
                          min="1"
                          max="600"
                          step="0.5"
                          value={cooldown_seconds(@setup, @world, chave)}
                          placeholder={cooldown_placeholder(@world)}
                          aria-label={"Cooldown da tecla " <> chave}
                          class="h-8 w-14 rounded border border-pk-line-strong bg-pk-bg px-1 text-right font-mono text-pk-body text-pk-text focus:border-pk-ok focus:outline-none"
                        />
                      </form>
                    </td>
                  </tr>
                </tbody>
              </table>
              <p class="mt-1 text-pk-meta text-pk-text-3">
                os níveis são HP de verdade · o monstro tem {@world && @world.knobs.mob_hp} de vida,
                na MESMA unidade
              </p>

              <%!-- A ARMADILHA que estragaria o experimento em silêncio: uma
                    tecla em "padrão" tira uma PORCENTAGEM da vida, então ela
                    cresce junto com o monstro. Com 500 de vida, 34% é 170 — mais
                    do que o dobro do "muito dano". --%>
              <p
                :if={mixed_units?(@setup, @world)}
                class="mt-1 flex items-start gap-1.5 text-pk-meta text-pk-warn"
              >
                <.icon name="hero-exclamation-triangle" class="mt-px size-3.5 shrink-0" />
                <span>
                  tem tecla em <b>padrão</b>
                  no meio: ela tira uma % da vida, então CRESCE junto com o monstro. Com {@world &&
                    @world.knobs.mob_hp} de vida elas tiram {pct_hit(@world, @setup)},
                  e a medida deixa de ser a que você configurou.
                </span>
              </p>

              <%!-- O NÚMERO APERTADO EM SILÊNCIO. Duas coerências do mundo
                    corrigem o que ele digita — um bicho não nota de mais longe
                    do que a corda deixa vir, e um ninho não é mais largo que a
                    percepção — e corrigir calado é a mesma armadilha que elas
                    existem pra fechar: ele mediria um mapa que não é o da tela.
                    Medido em 28/08: raio 10 contra aggro 8 derrubava a caçada de
                    24,6 para 4,1 mortos/min numa hora. --%>
              <p
                :for={{knob, pedido, valendo, porque} <- apertados(@setup)}
                class="mt-1 flex items-start gap-1.5 text-pk-meta text-pk-warn"
              >
                <.icon name="hero-exclamation-triangle" class="mt-px size-3.5 shrink-0" />
                <span>
                  <b>{knob}</b> está em {pedido}, mas o mundo usa <b>{valendo}</b>: {porque}
                </span>
              </p>
            </div>

            <div class="flex items-center gap-2">
              <button
                type="submit"
                class="h-8 rounded-lg bg-pk-ok px-3 text-pk-meta font-bold text-pk-bg transition hover:brightness-110"
              >
                Salvar e recomeçar
              </button>
              <button
                type="button"
                phx-click="reset-setup"
                class="h-8 rounded-lg border border-pk-line-strong px-3 text-pk-meta font-semibold text-pk-text-2 transition hover:bg-pk-raised hover:text-white"
              >
                Voltar aos meus chutes
              </button>
              <span class="text-pk-body text-pk-text-3">
                a vida do monstro e o dano estão na MESMA unidade
              </span>
            </div>
          </form>
        </div>

        <p
          :if={@refusal}
          class="rounded-lg border border-pk-warn-line bg-pk-warn-dim px-3 py-2 text-pk-body text-pk-warn"
        >
          {@refusal}
        </p>

        <%!-- O LABORATÓRIO. A gaveta de cenários era um <select> com optgroup:
              treze nomes parecidos, sem dizer qual é o difícil, e sem lembrar
              como cada um foi da última vez. Aqui cada um tem SÍMBOLO (a
              identidade), COR (o aperto — o que esperar) e SELO (o que
              aconteceu), e "Todos" preenche a coluna dos selos de uma vez.
              O emoji é a única coisa que distingue treze coisas num sistema de
              quatro cores; a cor segue sendo do design system. --%>
        <section id="laboratorio" class="rounded-lg border border-pk-line bg-pk-surface p-3">
          <div class="mb-2 flex flex-wrap items-baseline gap-x-3 gap-y-1">
            <h2 class="text-pk-title font-bold text-pk-text">O laboratório</h2>
            <span class="text-pk-meta text-pk-text-3">
              {length(@scenarios)} cenários · clique pra carregar · “Todos” roda a biblioteca
              inteira e preenche os selos
            </span>
          </div>

          <div class="space-y-3">
            <div :for={{group, items} <- lab_groups(@scenarios)}>
              <h3 class="mb-1.5 text-pk-meta font-semibold uppercase tracking-[0.12em] text-pk-text-3">
                {Scenario.group_label(group)}
              </h3>

              <div class="grid gap-2 [grid-template-columns:repeat(auto-fill,minmax(190px,1fr))]">
                <button
                  :for={item <- items}
                  phx-click="pick-scenario"
                  phx-value-scenario={item.id}
                  title={Scenario.aperto_note(item.aperto)}
                  class={[
                    "flex items-start gap-2 rounded-lg border px-2.5 py-2 text-left transition hover:brightness-125",
                    severity_class(Scenario.aperto_tone(item.aperto)),
                    @scenario && @scenario.id == item.id && "ring-1 ring-pk-ok"
                  ]}
                >
                  <span class="text-pk-title leading-none">{item.icon}</span>

                  <span class="min-w-0 flex-1">
                    <span class="block truncate text-pk-body font-semibold text-pk-text">
                      {item.name}
                    </span>
                    <span class={[
                      "block text-pk-meta",
                      severity_text(Scenario.aperto_tone(item.aperto))
                    ]}>
                      {Scenario.aperto_label(item.aperto)}
                      <span :if={dureza(item)} class="text-pk-text-3">
                        · morre em {dureza(item)} {if dureza(item) == 1, do: "tecla", else: "teclas"}
                      </span>
                    </span>
                  </span>

                  <span
                    class="shrink-0 text-pk-body leading-none"
                    title={seal_title(@seals[item.id])}
                  >
                    {seal_icon(@seals[item.id])}
                  </span>
                </button>
              </div>
            </div>
          </div>

          <p class="mt-2 text-pk-meta text-pk-text-3">
            ✅ cumpriu o que prometeu · ❌ quebrou uma promessa · 👁 cenário de observar (leia a
            linha do tempo) · · ainda não rodou
          </p>
        </section>

        <div
          :if={@scenario}
          class="rounded-lg border border-pk-line-strong bg-pk-sunken px-3 py-2 text-pk-body text-pk-text"
        >
          <div class="flex flex-wrap items-baseline gap-x-2">
            <span class="text-pk-title leading-none">{@scenario.icon}</span>
            <span class="font-semibold">{@scenario.name}</span>
            <span class="text-pk-text-3">· {Scenario.group_label(@scenario.group)}</span>
            <span class={severity_text(Scenario.aperto_tone(@scenario.aperto))}>
              · {Scenario.aperto_label(@scenario.aperto)}
            </span>
          </div>

          <p class="mt-1 whitespace-pre-line text-pk-text-2">{@scenario.why}</p>

          <p :if={@scenario.espera != []} class="mt-1.5 text-pk-meta text-pk-text-3">
            <span class="font-semibold uppercase tracking-[0.12em]">promete</span>
            {Enum.map_join(@scenario.espera, " · ", &Verdict.label/1)}
          </p>

          <%!-- A mesa dele não manda num cenário que fixa a dureza, e calar
                sobre isso o deixaria configurando dano sem efeito. --%>
          <p :if={dureza(@scenario)} class="mt-1.5 text-pk-meta text-pk-warn">
            este cenário fixa a dureza em {dureza(@scenario)} teclas por monstro — as faixas de dano
            da tua mesa não valem aqui
          </p>
        </div>

        <p
          :if={failures(@world) != []}
          class="rounded-lg border border-pk-danger-line bg-pk-danger-dim px-3 py-2 text-pk-body font-semibold text-pk-danger"
        >
          quebrado de propósito agora: {Enum.join(failures(@world), " · ")}
        </p>

        <p
          :if={@world && @world.unsimulated_stairs != []}
          class="rounded-lg border border-pk-warn-line bg-pk-warn-dim px-3 py-2 text-pk-body text-pk-warn"
        >
          Esta rota tem {length(@world.unsimulated_stairs)} passagem(ns) entre andares que não dá
          pra simular: o par de esquinas gravado está sujo, e chutar onde fica o degrau seria pior
          que não atravessar.
        </p>

        <div class="grid gap-3 lg:grid-cols-[minmax(0,3fr)_minmax(300px,1fr)]">
          <div class="rounded-lg border border-pk-line bg-pk-surface p-3">
            <div class="mb-2 flex flex-wrap items-center gap-x-3 gap-y-1.5">
              <h2 class="text-pk-title font-bold text-pk-text">O mundo</h2>
              <p class="pk-num font-mono text-pk-meta text-pk-text-3">
                andar {@z || "?"} · {length(@mobs)} no chão
              </p>

              <%!-- TRÊS GRAUS, um controle segmentado: a distância de leitura é
                    uma escolha contínua do olho dele, não um liga-desliga. --%>
              <div
                :if={@world}
                role="group"
                aria-label="Aproximação"
                class="ml-auto flex items-center gap-px rounded-lg border border-pk-line-strong p-0.5"
              >
                <button
                  :for={nivel <- @zooms}
                  phx-click="zoom"
                  phx-value-level={nivel}
                  title={zoom_hint(nivel)}
                  aria-pressed={to_string(@zoom == nivel)}
                  class={[
                    "rounded px-2 py-0.5 text-pk-meta font-semibold transition",
                    if(@zoom == nivel,
                      do: "bg-pk-ok-dim text-pk-ok",
                      else: "text-pk-text-3 hover:bg-pk-raised hover:text-white"
                    )
                  ]}
                >
                  {zoom_label(nivel)}
                </button>
              </div>
            </div>
            <div class="relative">
              <%!-- O VAZIO DIZ O QUE FALTA. Desarmado o mapa é uma grade em
                    branco do tamanho da tela, e uma grade em branco parece
                    defeito. --%>
              <div
                :if={!@world}
                class="pointer-events-none absolute inset-0 z-10 grid place-items-center"
              >
                <p class="rounded-lg border border-pk-line-strong bg-pk-surface/90 px-3 py-2 text-pk-body text-pk-text-2 backdrop-blur">
                  sem mundo ainda — <span class="font-semibold text-pk-ok">Armar</span>
                  acorda o cérebro e desenha a rota
                </p>
              </div>
              <svg
                viewBox={view_box(@view_box)}
                class="h-[30rem] w-full rounded border border-pk-line bg-pk-bg lg:h-[38rem] 2xl:h-[46rem]"
              >
                <%!-- O CHÃO. Um quadriculado sutil atrás de tudo dá a única coisa
                    que o mapa não tinha: escala. Sem ele, dois monstros a três
                    tiles e a nove desenham a mesma distância no olho. --%>
                <defs>
                  <pattern id="chao" width="1" height="1" patternUnits="userSpaceOnUse">
                    <rect width="1" height="1" fill="var(--color-pk-bg)" />
                    <path
                      d="M 1 0 L 0 0 0 1"
                      fill="none"
                      stroke="var(--color-pk-line)"
                      stroke-width="0.04"
                    />
                  </pattern>
                </defs>
                <rect
                  x={elem(@view_box, 0)}
                  y={elem(@view_box, 1)}
                  width={elem(@view_box, 2)}
                  height={elem(@view_box, 3)}
                  fill="url(#chao)"
                />

                <%!-- PAREDE E PEDRA, o que ele não atravessa. Desenhadas ANTES da
                    rota de propósito: quando uma pedra cai em cima de um canto,
                    é isso que a linha do circuito passando por cima mostra — e é
                    exatamente o tropeço que ele quer ver o bot resolver. --%>
                <rect
                  :for={{x, y, _z} <- @blocked}
                  x={x - 0.5}
                  y={y - 0.5}
                  width="1"
                  height="1"
                  fill="var(--color-pk-raised)"
                  stroke="var(--color-pk-line-strong)"
                  stroke-width="0.06"
                  rx="0.12"
                />

                <polyline
                  points={Enum.map_join(@points, " ", fn {x, y, _n} -> "#{x},#{y}" end)}
                  fill="none"
                  stroke="var(--color-pk-line-strong)"
                  stroke-width="0.25"
                />
                <circle
                  :for={{x, y, nest} <- @points}
                  cx={x}
                  cy={y}
                  r={if nest, do: 0.55, else: 0.28}
                  fill={if nest, do: "var(--color-pk-warn)", else: "var(--color-pk-line-strong)"}
                />
                <%= if @world do %>
                  <rect
                    x={elem(@world.pos, 0) - div(@world.knobs.screen_w, 2) - 0.5}
                    y={elem(@world.pos, 1) - div(@world.knobs.screen_h, 2) - 0.5}
                    width={@world.knobs.screen_w}
                    height={@world.knobs.screen_h}
                    fill="var(--color-pk-info)"
                    fill-opacity="0.06"
                    stroke="var(--color-pk-info)"
                    stroke-opacity="0.4"
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
                      if World.asleep?(mob, @world),
                        do: "var(--color-pk-info)",
                        else: "var(--color-pk-bg)"
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
                    stroke="var(--color-pk-ok)"
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
                    stroke="var(--color-pk-ok)"
                    stroke-width="0.1"
                    stroke-dasharray="0.5 0.4"
                    opacity="0.6"
                  />
                  <rect
                    x={elem(@world.own.pos, 0) - 0.5}
                    y={elem(@world.own.pos, 1) - 0.5}
                    width="1"
                    height="1"
                    fill={
                      if @world.own.out?, do: "var(--color-pk-ok)", else: "var(--color-pk-text-3)"
                    }
                    stroke="var(--color-pk-bg)"
                    stroke-width="0.12"
                  />
                  <rect
                    x={elem(@world.pos, 0) - 0.5}
                    y={elem(@world.pos, 1) - 0.5}
                    width="1"
                    height="1"
                    fill="var(--color-pk-info)"
                    stroke="var(--color-pk-text)"
                    stroke-width="0.18"
                  />
                <% end %>
              </svg>
            </div>

            <ul class="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-pk-meta text-pk-text-2">
              <li class="flex items-center gap-1.5">
                <span class="inline-block size-3 bg-pk-info ring-1 ring-pk-text"></span> você
              </li>
              <li class="flex items-center gap-1.5">
                <span class="inline-block size-3 bg-pk-ok"></span> seu pokémon (cinza = caiu)
              </li>
              <li class="flex items-center gap-1.5">
                <span class="inline-block size-3 border border-dashed border-pk-ok"></span>
                alcance da área — sai DELE
              </li>
              <li class="flex items-center gap-1.5">
                <span class="inline-block size-3 bg-pk-danger"></span> monstro
              </li>
              <li class="flex items-center gap-1.5">
                <span class="inline-block size-3 rounded-full bg-pk-warn"></span> esquina onde nascem
              </li>
              <li class="flex items-center gap-1.5">
                <span class="inline-block size-3 rounded-full bg-pk-line-strong"></span> esquina comum
              </li>
              <li class="flex items-center gap-1.5">
                <span class="inline-block size-3 border border-pk-info/60"></span>
                a tela do jogo — o bot só sabe o que cabe aqui
              </li>
            </ul>
            <p class="mt-1 text-pk-meta leading-snug text-pk-text-3">
              Cada bicho é um quadrado de UM tile, com o pé no centro exato — é assim que a engine
              do jogo trata criatura. E o alcance é quadrado, não redondo: a distância aqui é
              Chebyshev (a grade tem diagonal), então 3 tiles na diagonal são 3, não 4,24.
            </p>
          </div>

          <div class="space-y-4">
            <div class="rounded-lg border border-pk-line bg-pk-surface p-3">
              <h2 class="mb-2 text-pk-title font-bold text-pk-text">O cérebro</h2>
              <%= if @orders do %>
                <p class={"text-pk-title font-semibold #{band_class(@orders.band)}"}>
                  {@orders.phase} · {@orders.band}
                </p>
                <p class="mt-1 text-pk-body text-pk-text-2">{@orders.why}</p>
                <dl class="mt-3 grid grid-cols-2 gap-x-3 gap-y-1 text-pk-meta text-pk-text-2">
                  <div>rota: <span class="text-pk-text">{@orders.route}</span></div>
                  <div>fogo: <span class="text-pk-text">{@orders.fire}</span></div>
                  <div>revive: <span class="text-pk-text">{@orders.revive}</span></div>
                </dl>
              <% else %>
                <p class="text-pk-body text-pk-text-3">
                  A engine não publicou ordem ainda. Arme a simulação para acordá-la.
                </p>
              <% end %>
              <p class="mt-3 border-t border-pk-line pt-2 text-pk-meta text-pk-text-3">
                caçada: {(@hunt_fact && @hunt_fact.state) || "sem fato :hunt"}
                <span class="ml-2">
                  cérebro: {if @orders, do: "decidindo", else: "calado"}
                </span>
              </p>
            </div>

            <div class="rounded-lg border border-pk-line bg-pk-surface p-3">
              <h2 class="mb-1 text-pk-title font-bold text-pk-text">Vida</h2>
              <p class="text-pk-body text-pk-text-2">
                <span class="text-pk-ok">pokémon</span>
                {(@world && @world.own.hp_pct) || "—"}% <span class="text-pk-text-3">·</span>
                lido: {(@pokemon_fact && (@pokemon_fact.hp_pct || "não leu")) || "—"}
                <span :if={@pokemon_fact && @pokemon_fact.fainted?} class="text-pk-danger">
                  · caiu
                </span>
              </p>
              <p class="mt-1 text-pk-body text-pk-text-2">
                <span class="text-pk-info">você</span>
                {(@world && @world.player.hp_pct) || "—"}%
                <span :if={@world && @world.own.out?} class="ml-1 text-pk-meta text-pk-text-3">
                  — intocável enquanto ele está em campo
                </span>
                <span :if={@world && not @world.own.out?} class="ml-1 text-pk-meta text-pk-danger">
                  — ele caiu, agora é você que apanha
                </span>
              </p>
              <p class="mt-2 border-t border-pk-line pt-2 text-pk-meta text-pk-text-3">
                a engine não tem fato de vida do personagem: o mundo sabe que você
                está morrendo e o bot não enxerga.
              </p>
            </div>
          </div>
        </div>

        <div class="grid gap-4 md:grid-cols-2">
          <div class="rounded-lg border border-pk-line bg-pk-surface p-3">
            <h2 class="mb-2 text-pk-title font-bold text-pk-text">
              Antes da caçada <span class="font-normal text-pk-text-3">— o que grava dado</span>
            </h2>
            <ul class="space-y-1 text-pk-body">
              <li class={if @measuring?, do: "text-pk-ok", else: "text-pk-warn"}>
                <span class="font-medium">medir caminhada:</span>
                {if @measuring?,
                  do: "ligado — a noite vai medir tiles/s",
                  else:
                    "DESLIGADO — sem ele ninguém mede tiles/s. Ligue cavebot_measure_walk em /config"}
              </li>
              <li class="text-pk-text-2">
                O cérebro grava sozinho: cada mudança de decisão vira uma linha tipada em
                ~/.pokex/events/. É de lá que sai o tamanho real das pilhas.
              </li>
            </ul>
          </div>

          <div class="rounded-lg border border-pk-line bg-pk-surface p-3">
            <h2 class="mb-2 text-pk-title font-bold text-pk-text">
              O que a noite disse <span class="font-normal text-pk-text-3">— hoje</span>
            </h2>
            <dl class="space-y-1 text-pk-body text-pk-text-2">
              <div>
                ms por tile: <span class="text-pk-text">{measured_text(@calib.walk)}</span>
              </div>
              <div>
                pilha ao abrir:
                <span class="text-pk-text">{measured_text(@calib.pile && @calib.pile.engaged)}</span>
              </div>
              <div>
                parou de chegar em:
                <span class="text-pk-text">{measured_text(@calib.pile && @calib.pile.settled_ms)}</span>
              </div>
              <div :if={@calib.pile} class="text-pk-text-3">
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
          :if={@night}
          id="placar-da-noite"
          class="space-y-2 rounded-lg border border-pk-line bg-pk-surface p-3"
        >
          <header class="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
            <h2 class="text-pk-title font-bold text-pk-text">O placar da noite</h2>
            <p class="pk-num font-mono text-pk-meta text-pk-text-3">
              {@night.minutes} min de rastro
            </p>
          </header>

          <dl class="grid grid-cols-2 gap-px overflow-hidden rounded border border-pk-line bg-pk-line sm:grid-cols-3 lg:grid-cols-5">
            <div :for={cell <- night_readouts(@night)} class="bg-pk-sunken px-3 py-2">
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
            :if={@night.by_phase != []}
            class="space-y-1 rounded border border-pk-line bg-pk-sunken p-2"
          >
            <h3 class="text-pk-meta font-semibold uppercase tracking-[0.12em] text-pk-text-3">
              Onde foi o minuto, no jogo
            </h3>
            <dl class="flex flex-wrap gap-x-4 gap-y-1">
              <div :for={slice <- @night.by_phase} class="flex items-baseline gap-1">
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
            :if={@night.keys != %{}}
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
                <tr :for={{gap, t} <- Enum.sort(@night.keys)} class="border-t border-pk-line">
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
            :if={@night.piles != %{}}
            class="space-y-1 rounded border border-pk-line bg-pk-sunken p-2"
          >
            <h3 class="text-pk-meta font-semibold uppercase tracking-[0.12em] text-pk-text-3">
              As pilhas que ele encontrou
            </h3>
            <dl class="flex flex-wrap gap-x-4 gap-y-1">
              <div
                :for={{quantos, vezes} <- Enum.sort(@night.piles)}
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

        <div :if={@bench} class="rounded-lg border border-pk-line bg-pk-surface p-3">
          <h2 class="mb-2 text-pk-title font-bold text-pk-text">
            Veredito
            <span class="font-normal text-pk-text-3">— um minuto simulado, sem processo</span>
          </h2>

          <%!-- A PROMESSA COBRADA, antes dos números: seis contadores não dizem
                se a corrida foi boa, e lembrar qual era a pergunta de cada um
                dos treze cenários é trabalho que a tela pode fazer. --%>
          <ul :if={@bench_verdict != []} class="mb-3 space-y-1">
            <li :for={item <- @bench_verdict} class="flex items-baseline gap-2 text-pk-body">
              <span class="w-4 shrink-0 leading-none">
                {if item.cumpriu?, do: "✅", else: "❌"}
              </span>
              <span class={[
                "font-semibold",
                if(item.cumpriu?, do: "text-pk-text-2", else: "text-pk-danger")
              ]}>
                {item.label}
              </span>
              <span class="text-pk-text-3">— {item.porque}</span>
            </li>
          </ul>

          <p
            :if={@bench_verdict == [] and @scenario}
            class="mb-3 text-pk-body text-pk-text-3"
          >
            👁 cenário de observar — este não promete um resultado, ele mostra uma decisão. A
            resposta está na linha do tempo abaixo.
          </p>

          <dl class="mb-3 flex flex-wrap gap-x-5 gap-y-1 text-pk-body text-pk-text-2">
            <div>mortos: <span class="font-semibold">{@bench.outcome.killed}</span></div>
            <div>sumidos no leash: <span class="font-semibold">{@bench.outcome.vanished}</span></div>
            <div>de pé: <span class="font-semibold">{@bench.outcome.left_alive}</span></div>
            <div>vida no fim: <span class="font-semibold">{@bench.outcome.hp_at_end}%</span></div>
            <div>
              revive: <span class="font-semibold">{revive_text(@bench.outcome.revived_at)}</span>
            </div>
            <div>caiu: <span class="font-semibold">{revive_text(@bench.outcome.died_at)}</span></div>
          </dl>
          <ol class="max-h-56 space-y-1 overflow-y-auto text-pk-meta">
            <li :for={line <- @bench.timeline} class="flex gap-2 text-pk-text-2">
              <span class="w-14 shrink-0 tabular-nums text-pk-text-3">{line.at}ms</span>
              <span class={"w-24 shrink-0 font-medium #{band_class(line.band)}"}>{line.phase}</span>
              <span class="text-pk-text-2">{line.why}</span>
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

        <div :if={@bench_all} class="rounded-lg border border-pk-line bg-pk-surface p-3">
          <h2 class="mb-1 text-pk-title font-bold text-pk-text">
            Todos os cenários
            <span class="font-normal text-pk-text-3">
              — um minuto cada, com os botões que o bot está usando agora
            </span>
          </h2>
          <p class="mb-2 font-mono text-pk-meta text-pk-text-3">
            engaja a partir de {@bench_all.config.engage_from} · {if @bench_all.config.gather_piles,
              do: "juntando pilha",
              else: "sem juntar pilha"} · assenta em {@bench_all.config.pile_settle_ms}ms · teto {@bench_all.config.size_ceiling_ms}ms
          </p>
          <div class="overflow-x-auto">
            <table class="w-full text-left text-pk-meta">
              <thead class="text-pk-meta uppercase tracking-[0.12em] text-pk-text-3">
                <tr>
                  <th class="py-1 pr-2 font-medium">selo</th>
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
                <tr :for={row <- @bench_all.rows} class="border-t border-pk-line">
                  <td class="py-1 pr-2 leading-none" title={seal_title(row.seal)}>
                    {seal_icon(row.seal)}
                  </td>
                  <td class="py-1 pr-3 text-pk-text">
                    <span class="mr-1">{row.icon}</span>{row.name}
                    <span
                      :if={row.seal == :falhou}
                      class="block text-pk-meta text-pk-danger"
                    >{row.verdict
                    |> Enum.reject(& &1.cumpriu?)
                    |> Enum.map_join(" · ", &"#{&1.label}: #{&1.porque}")}</span>
                  </td>
                  <td class={"py-1 pr-3 #{ending_class(row.outcome.ended)}"}>
                    {ending_text(row.outcome.ended)}
                  </td>
                  <td class="py-1 pr-3 text-right tabular-nums text-pk-text-2">
                    {row.outcome.killed}
                  </td>
                  <td class={"py-1 pr-3 text-right tabular-nums #{if row.outcome.vanished > 0, do: "text-pk-warn", else: "text-pk-text-3"}"}>
                    {row.outcome.vanished}
                  </td>
                  <td class="py-1 pr-3 text-right tabular-nums text-pk-text-2">
                    {row.outcome.left_alive}
                  </td>
                  <td class="py-1 pr-3 text-right tabular-nums text-pk-text-2">
                    {row.outcome.hp_at_end}%
                  </td>
                  <td class="py-1 font-mono text-pk-body text-pk-text-2">
                    {Enum.join(row.outcome.phases, " › ")}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <div class="grid gap-4 md:grid-cols-2">
          <div class="rounded-lg border border-pk-line bg-pk-surface p-3">
            <h2 class="mb-2 text-pk-title font-bold text-pk-text">
              O que existe <span class="font-normal text-pk-text-3">— verdade do mundo</span>
            </h2>
            <p :if={@truth == []} class="text-pk-body text-pk-text-3">nada no chão</p>
            <ul class="space-y-1 text-pk-body">
              <li :for={row <- @truth} class="flex justify-between gap-2 text-pk-text-2">
                <span>
                  {row.name}
                  <span :if={row.asleep?} class="text-pk-info">· dormindo</span>
                </span>
                <span class="text-pk-text-3">
                  {row.hp_pct}% · leash {row.leash}
                </span>
              </li>
            </ul>
          </div>

          <div class="rounded-lg border border-pk-line bg-pk-surface p-3">
            <h2 class="mb-2 text-pk-title font-bold text-pk-text">
              O que o bot leu <span class="font-normal text-pk-text-3">— fato :battle</span>
            </h2>
            <p :if={@perceived == :unread} class="text-pk-body text-pk-warn">
              não estou lendo a lista de batalha
            </p>
            <p :if={@perceived == []} class="text-pk-body text-pk-text-3">lista vazia</p>
            <ul :if={is_list(@perceived)} class="space-y-1 text-pk-body">
              <li :for={row <- @perceived} class="flex justify-between gap-2 text-pk-text-2">
                <span>linha {row.row} · {row.name || "?"}</span>
                <span class="text-pk-text-3">{round((row.hp_pct || 0) * 100)}%</span>
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

  # A VIDA DO BICHO EM TRÊS DEGRAUS, na paleta do console: inteiro é ameaça,
  # meio é aviso, quase morto some pro fundo. Não é o verde — verde aqui é o que
  # é DELE.
  defp mob_fill(hp) when hp > 66, do: "var(--color-pk-danger)"
  defp mob_fill(hp) when hp > 33, do: "var(--color-pk-warn)"
  defp mob_fill(_low), do: "var(--color-pk-warn-line)"
end
