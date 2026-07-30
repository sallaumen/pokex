defmodule Pokex.Bots.Cavebot.Worker do
  @moduledoc """
  Driver da `Cavebot.Logic` pura, no estilo constante: um tick curto lê o
  mundo (posição do fato `:minimap`, contagem de inimigos do fato `:battle`,
  o último estado do combate ouvido no tópico "combat"), chama `Logic.step/3`
  e traduz UMA ação por vez.

  É um PEER dos outros workers, nunca uma mudança neles:

    * atuação SÓ pelo Body — `Body.minimap_step/3` é o único jeito de andar
      (o clique no minimapa; o cliente contorna obstáculos sozinho). O Rig
      nunca é tocado daqui.
    * o Combat.Worker é dirigido exclusivamente por `run/1` e `halt/1` — a
      Logic liga ele no arranque e ele luta sozinho; o cavebot só cede a vez
      enquanto houver inimigo na tela.

  Fail-safe em camadas: posição desconhecida (fato ausente/velho/anchor não
  lida) segura o passo — nunca anda às cegas; e um `{:block, _}` da Logic tem
  DOIS níveis (ver `translate/2`): o perigoso, que é o freio de mão completo da
  frota, e o local, que para só esta caçada.

  Toda parada tem NOME: o resultado de cada passo fica em `last_step` e vira o
  `hold_reason` do snapshot (junto com a cegueira que a Logic marca e com o
  `hold_note` dos motivos que nascem fora do tick). Um cavebot parado sem motivo
  escrito é indistinguível de um cavebot quebrado — foi assim que um clique
  suprimido pelo portão de input derrubou a frota em silêncio.

  Duas saídas para a tela, e elas são diferentes: o SNAPSHOT (`{:cavebot, map}`)
  é o estado atual completo, reemitido quando um FATO muda; os LOGS
  (`{:cavebot_log, level, texto}`) são a narrativa das bordas — rota carregada,
  waypoint alcançado, bloqueio, motivo de espera aparecendo. Nada aqui pode
  falar por tick: a cadência é de 200ms e uma linha por tick é ruído que esconde
  o fato.

  O `body` injetado é um MÓDULO (produção: `Pokex.Bots.Body`; testes: um fake
  com a mesma assinatura), porque `minimap_step/3` é função de módulo — a
  geometria do clique vive no Body, não aqui. O `combat` é um server
  (produção: o `Combat.Worker` nomeado), porque `run/1`/`halt/1` recebem o
  server. `active: false` (testes) prepara tudo no `run` mas NÃO agenda o
  tick automático — o teste manda `:tick` na mão e cada passo é
  determinístico.
  """
  use GenServer
  require Logger

  alias Pokex.Bots.Cavebot.{Logic, Route, Store}
  alias Pokex.Bots.Combat
  alias Pokex.Perception
  alias Pokex.Perception.{Feed, WorldState}
  alias Pokex.Settings

  @topic "cavebot"
  @tick_ms 200
  @no_route_error "nenhuma rota de caçada configurada"
  @max_reattach 20
  @feed_lost "perdi o feed do minimapa e desisti de reconectar"

  # Os bloqueios em que o personagem pode estar em um lugar que a rota não
  # descreve, ou lutando sem ninguém para lutar — ver `translate/2`.
  @dangerous_blocks [:floor_changed, :combat_preflight_failed]

  @config_keys %{
    arrival_tolerance: :cavebot_arrival_tolerance_tiles,
    walk_timeout_ms: :cavebot_walk_timeout_ms,
    stuck_max_retries: :cavebot_stuck_max_retries,
    clear_debounce_ms: :cavebot_clear_debounce_ms,
    fight_timeout_ms: :cavebot_fight_timeout_ms,
    post_kill_dwell_ms: :cavebot_post_kill_dwell_ms
  }

  def topic, do: @topic

  def start_link(opts \\ []) do
    state = %{
      body: Keyword.get(opts, :body, Pokex.Bots.Body),
      combat: Keyword.get(opts, :combat, Combat.Worker),
      active?: Keyword.get(opts, :active, Application.get_env(:pokex, :cavebot_active, true)),
      logic: nil,
      timer: nil,
      attached?: false,
      feed_ref: nil,
      reattach_attempts: 0,
      combat_state: :idle,
      last_step: nil,
      pos: nil,
      pos_at: nil,
      counters: %{waypoints: 0, steps: 0},
      last_action: nil,
      hold_note: nil,
      logged_holds: []
    }

    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, state)
      name -> GenServer.start_link(__MODULE__, state, name: name)
    end
  end

  @spec run(GenServer.server()) :: :ok | {:error, [String.t()]}
  def run(server \\ __MODULE__), do: GenServer.call(server, :run)

  @spec halt(GenServer.server()) :: :ok
  def halt(server \\ __MODULE__), do: GenServer.call(server, :halt)

  @typedoc """
  O que a tela precisa para contar a caçada inteira sem adivinhar: onde ele
  está, para onde vai, quanto falta, o que segurou e o que ele fez por último.
  """
  @type snapshot :: %{
          state: atom,
          route: String.t() | nil,
          wp_index: non_neg_integer,
          wp_total: non_neg_integer,
          wp_target: Route.waypoint() | nil,
          pos: {integer, integer, integer} | nil,
          pos_age_ms: non_neg_integer | nil,
          distance_tiles: %{dx: integer, dy: integer} | nil,
          hold_reason: String.t() | nil,
          last_action: %{text: String.t(), at: integer} | nil,
          counters: %{waypoints: non_neg_integer, steps: non_neg_integer}
        }

  @spec status(GenServer.server()) :: snapshot
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(state) do
    Phoenix.PubSub.subscribe(Pokex.PubSub, Combat.Worker.topic())
    {:ok, state}
  end

  @impl true
  def handle_call(:run, _from, state) do
    case active_route() do
      nil ->
        {:reply, {:error, [@no_route_error]}, state}

      route ->
        Logger.info("Cavebot: rota \"#{route.name}\" (#{length(route.waypoints)} waypoints)")
        log(:macro, "rota \"#{route.name}\": #{length(route.waypoints)} waypoints")

        # O gate de combos por dungeon lê este fato (Combos.Runner). Publicado
        # mesmo com dungeon nil — o Runner trata nil como "só combos globais".
        WorldState.put(:dungeon, %{id: route.dungeon}, now())

        state =
          %{cancel_timer(state) | logic: Logic.new(route, config())}
          |> reset_session()
          |> attach()
          |> schedule_tick()

        broadcast_status(state)
        {:reply, :ok, state}
    end
  end

  def handle_call(:halt, _from, %{logic: nil} = state), do: {:reply, :ok, state}

  def handle_call(:halt, _from, state) do
    Combat.Worker.halt(state.combat)
    WorldState.forget(:dungeon)

    state =
      %{detach(cancel_timer(state)) | logic: nil, reattach_attempts: 0}
      |> end_session()

    broadcast_status(state)
    {:reply, :ok, state}
  end

  def handle_call(:status, _from, state), do: {:reply, snapshot(state), state}

  # Um tick perdido depois do halt (ou antes do run) é inócuo.
  @impl true
  def handle_info(:tick, %{logic: nil} = state), do: {:noreply, state}

  def handle_info(:tick, state) do
    now = now()

    if not Pokex.Bots.InputGate.allowed?() do
      # Portão fechado = nenhum passo sai (o Body recusa), mas os relógios de
      # paciência da Logic continuavam correndo — 3s sem "progresso" viravam
      # :stuck e a caçada morria ANTES de o Lucas alcançar o jogo depois de
      # clicar Iniciar no navegador (a regressão real do fail-closed,
      # 2026-07-29). Congela os relógios: pina cada carimbo de `since` em
      # `now`, registra o motivo visível e espera o portão reabrir.
      frozen = %{
        state.logic
        | since: Map.new(state.logic.since, fn {k, _at} -> {k, now} end)
      }

      state = %{
        state
        | logic: frozen,
          last_step: %{dx: 0, dy: 0, result: {:error, :input_gate_closed}, at: now}
      }

      {:noreply, schedule_tick(state)}
    else
      run_cavebot_tick(state, now)
    end
  end

  def handle_info({:combat, %{state: combat_state}}, state),
    do: {:noreply, %{state | combat_state: combat_state}}

  # O feed do minimapa morreu (o mapa de consumidores morre com ele; um feed
  # reiniciado nasce sem ninguém atachado). Sem reatachar, o fato :minimap
  # envelhece, a posição vira :unknown e o cavebot fica parado PRA SEMPRE —
  # retry curto e limitado, o molde do Catcher.
  def handle_info({:DOWN, ref, :process, _obj, _reason}, %{feed_ref: ref} = state) do
    state = %{state | attached?: false, feed_ref: nil}
    state = if running?(state), do: schedule_reattach(state), else: state
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _obj, _reason}, state), do: {:noreply, state}

  def handle_info(:reattach_minimap, state) do
    if running?(state) and not state.attached? do
      {:noreply, reattach_minimap(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- o mundo observado ---------------------------------------------------------

  # A posição lida fica GUARDADA com a hora da leitura: durante um lapso de
  # cegueira o mundo que a Logic recebe tem `pos: nil` (ela não pode andar num
  # palpite), mas a tela continua mostrando a última coordenada conhecida COM A
  # IDADE dela — "estava em 100,100 há 4s" é diagnóstico, "sem posição" não é.
  defp run_cavebot_tick(state, now) do
    {world, state} = observe(state, now)
    before = broadcast_key(state, now)
    wp_before = state.logic.wp_index

    {logic, action} = Logic.step(state.logic, world, now)

    state =
      %{state | logic: logic}
      |> translate(action)
      |> note_arrival(wp_before, now)
      |> log_hold_edge(now)

    if broadcast_key(state, now) != before, do: broadcast_status(state)
    {:noreply, schedule_tick(state)}
  end

  # O snapshot do combate, guardado do jeito do Combos.Runner: a Logic recebe
  # o último estado ouvido como world.combat_state.
  defp observe(state, now) do
    pos = position(now)
    world = %{pos: pos, enemies: enemy_count(now), combat_state: state.combat_state}

    if pos, do: {world, %{state | pos: pos, pos_at: now}}, else: {world, state}
  end

  defp position(now) do
    case Perception.minimap(now) do
      {:ok, %{pos: pos}} -> pos
      :unknown -> nil
    end
  end

  # Fail-safe 0: fato :battle ausente/velho lê como "tela limpa" — o cavebot
  # continua a rota; se houver inimigo de verdade, o Combat (sempre rodando)
  # briga mesmo assim e o próximo fato fresco corrige a contagem.
  defp enemy_count(now) do
    case WorldState.get(:battle, Settings.get(:combat_world_max_age_ms), now) do
      {:ok, obs} -> length(Map.get(obs, :enemies) || [])
      _stale_or_missing -> 0
    end
  end

  # -- traduzindo as ações da Logic ----------------------------------------------

  # Pública (@doc false) de propósito: cobre o vocabulário COMPLETO de ações
  # da Logic, mas o corte constante ainda não emite :halt_combat (hoje só o
  # {:block, _} desliga o combate — o estilo mobado é quem vai emitir). Como
  # função privada, o compilador prova a cláusula morta e
  # --warnings-as-errors derruba o build; pública, o contrato inteiro fica
  # implementado e testável.
  @doc false
  # `last_step` descreve a tentativa de passo DESTE tick: quando a Logic não pede
  # passo nenhum, não há tentativa — e um erro velho não pode ficar pendurado na
  # tela explicando uma parada que já tem outro motivo.
  def translate(state, :none), do: %{state | last_step: nil}

  def translate(state, {:walk, dx, dy}), do: minimap_step(state, dx, dy)
  def translate(state, {:nudge, dx, dy}), do: minimap_step(state, dx, dy)

  # Ligar o combate PODE falhar no preflight (sem calibração, p.ex.). Se falhar,
  # não dá pra seguir andando cego contra inimigos que ninguém vai matar — a
  # Logic acharia que o combate está de pé. Melhor bloquear pelo mesmo freio, na
  # hora, com um motivo claro, do que degradar via fight_stalled vários segundos
  # depois.
  def translate(state, :run_combat) do
    case Combat.Worker.run(state.combat) do
      :ok ->
        log(:debug, "combate ligado")
        state

      {:error, messages} ->
        Logger.warning("Cavebot: combate recusou o arranque (#{inspect(messages)})")
        translate(state, {:block, :combat_preflight_failed})
    end
  end

  def translate(state, :halt_combat) do
    Combat.Worker.halt(state.combat)
    state
  end

  # BLOQUEIO PERIGOSO × BLOQUEIO LOCAL — a divisão existe porque tratar os dois
  # como emergência foi o que apagou a caçada inteira em silêncio: uma parede
  # (:stuck) derrubava a frota TODA e ainda ligava o latch de pânico, que veta
  # até o auto-resume do Focus — captura e suporte só voltavam com um "Iniciar"
  # humano, por causa de um obstáculo de um tile.
  #
  # PERIGOSO (@dangerous_blocks) é quando o mundo deixou de bater com a rota: o
  # personagem mudou de andar (a rota descreve OUTRO mapa — andar seria andar às
  # cegas em lugar errado) ou o combate recusou o arranque (seguir a rota seria
  # colecionar inimigos que ninguém vai matar). Aí vale o freio de mão completo,
  # na ordem do emergency_escape: latch PRIMEIRO (nada pode auto-retomar por
  # cima), depois o combate que este worker dirige, depois a frota inteira.
  def translate(state, {:block, reason}) when reason in @dangerous_blocks do
    Logger.warning("Cavebot: BLOQUEADO (#{inspect(reason)}) — parando a frota")
    Pokex.Bots.InputGate.set_panic_latch(true)
    Combat.Worker.halt(state.combat)
    Pokex.Bots.BotSupervisor.stop_all("caçada — " <> block_text(reason))
    stop_hunt(state, reason)
  end

  # LOCAL (:stuck, :fight_stalled) é o cavebot que bateu numa parede ou numa luta
  # que não acaba: um problema DELE, não do personagem. Nada aí ameaça a captura
  # nem o suporte, e um bot parado com vida é melhor que uma frota morta — então
  # sem latch (o Focus segue podendo retomar sozinho) e sem `stop_all`. Só esta
  # caçada para: o tick, os feeds e o combate — que em caçada é dirigido daqui, e
  # ficaria brigando sozinho para sempre se sobrevivesse ao dono.
  def translate(state, {:block, reason}) do
    Logger.warning("Cavebot: parei (#{inspect(reason)}) — o resto da frota segue")
    Combat.Worker.halt(state.combat)
    stop_hunt(state, reason)
  end

  # O que os dois níveis têm em comum: alarme, motivo escrito na tela, tick
  # cancelado e feeds soltos (capturar para ninguém só pesa o broker). A Logic
  # vai para :blocked à força porque o bloqueio pode vir dela (mudou de andar) OU
  # do Worker (o combate recusou o arranque) — nos dois o estado reportado tem
  # que ser :blocked, terminal até um humano religar.
  defp stop_hunt(state, reason) do
    broadcast({:cavebot_alarm, reason})
    log(:macro, block_text(reason))

    state =
      %{
        cancel_timer(detach(state))
        | logic: %{state.logic | state: :blocked},
          hold_note: block_text(reason)
      }
      |> mark_logged(:note)

    broadcast_status(state)
    state
  end

  defp block_text(:floor_changed), do: "BLOQUEADO: mudou de andar"
  defp block_text(:combat_preflight_failed), do: "BLOQUEADO: o combate recusou o arranque"
  defp block_text(:stuck), do: "parei: travado, sem sair do lugar"
  defp block_text(:fight_stalled), do: "parei: a luta não termina"
  defp block_text(reason), do: "parei: #{inspect(reason)}"

  # Falha de passo (ex.: {:error, :no_layout} sem HUD localizado) não derruba
  # nada: o próximo tick relê o mundo e tenta de novo. Mas ela FICA REGISTRADA —
  # um passo que não saiu contando como passo dado é exatamente o que matou a
  # frota calada em 2026-07-23 (portão fechado → clique engolido → a Logic
  # acreditou no passo → posição parada → :stuck → pânico). Um Logger.debug não
  # é visibilidade: ninguém está lendo o log quando o bot para.
  defp minimap_step(state, dx, dy) do
    at = now()
    result = step_result(state.body.minimap_step(dx, dy, []))
    text = "passo #{dx},#{dy}"
    stepped = %{state | last_step: %{dx: dx, dy: dy, result: result, at: at}}

    if result == :ok do
      # o passo é o evento mais frequente que existe aqui (5/s): só vira linha
      # quando MUDA — repetir "passo 90,80" tick após tick não conta nada novo.
      if action_text(state) != text,
        do: log(:debug, "#{text} → wp #{stepped.logic.wp_index + 1}/#{wp_total(stepped)}")

      %{stepped | counters: bump(stepped.counters, :steps), last_action: %{text: text, at: at}}
    else
      Logger.debug("Cavebot: passo (#{dx},#{dy}) falhou: #{inspect(result)}")
      stepped
    end
  end

  defp step_result({:ok, _point}), do: :ok
  defp step_result({:error, reason}), do: {:error, reason}
  defp step_result(other), do: {:error, other}

  # -- rota e config -------------------------------------------------------------

  # A primeira rota habilitada E válida: uma rota sem waypoints (ou com andar
  # misto) nunca chega na Logic — `current_wp` de uma lista vazia seria crash.
  defp active_route do
    Enum.find(Store.all(), fn route ->
      route.enabled? and Route.validate(route) == :ok
    end)
  end

  defp config do
    Map.new(@config_keys, fn {key, setting} -> {key, Settings.get(setting)} end)
  end

  # -- feeds ---------------------------------------------------------------------

  # :minimap é o feed DESTE worker (monitorado + reatachado); :battle já é
  # monitorado pelo Combat.Worker enquanto ele roda — aqui só registramos a
  # demanda para o feed não pausar entre as lutas.
  defp attach(state) do
    safe(fn -> Perception.attach(:minimap) end)
    safe(fn -> Perception.attach(:battle) end)
    demonitor_feed(state.feed_ref)
    ref = Process.monitor(Feed.name(:minimap))
    %{state | attached?: true, feed_ref: ref, reattach_attempts: 0, hold_note: nil}
  end

  defp detach(%{attached?: false} = state), do: state

  defp detach(state) do
    safe(fn -> Perception.detach(:minimap) end)
    safe(fn -> Perception.detach(:battle) end)
    demonitor_feed(state.feed_ref)
    %{state | attached?: false, feed_ref: nil}
  end

  defp reattach_minimap(state) do
    Perception.attach(:minimap)
    safe(fn -> Perception.attach(:battle) end)
    demonitor_feed(state.feed_ref)
    ref = Process.monitor(Feed.name(:minimap))
    %{state | attached?: true, feed_ref: ref, reattach_attempts: 0, hold_note: nil}
  catch
    :exit, _reason -> schedule_reattach(state)
  end

  # Desistir depois de 20×250ms era MUDO: o state voltava intocado e o cavebot
  # ficava parado para sempre sem posição e sem ninguém saber por quê. Desistência
  # é um fato — vira motivo na tela e linha no feed, uma vez só.
  defp schedule_reattach(%{reattach_attempts: attempts} = state) when attempts >= @max_reattach do
    unless state.hold_note == @feed_lost do
      Logger.warning("Cavebot: #{@feed_lost}")
      log(:macro, @feed_lost)
    end

    state = mark_logged(%{state | hold_note: @feed_lost}, :note)
    broadcast_status(state)
    state
  end

  defp schedule_reattach(state) do
    Process.send_after(self(), :reattach_minimap, 250)
    %{state | reattach_attempts: state.reattach_attempts + 1}
  end

  defp demonitor_feed(nil), do: :ok
  defp demonitor_feed(ref), do: Process.demonitor(ref, [:flush])

  defp safe(fun) do
    fun.()
  catch
    :exit, _reason -> :ok
  end

  # -- tick ----------------------------------------------------------------------

  # active? false = nunca auto-agendar (testes dirigem com :tick manual);
  # :blocked é terminal — só o humano religa, via run.
  defp schedule_tick(%{active?: false} = state), do: state
  defp schedule_tick(%{logic: nil} = state), do: state
  defp schedule_tick(%{logic: %Logic{state: :blocked}} = state), do: state

  defp schedule_tick(state) do
    state = cancel_timer(state)
    %{state | timer: Process.send_after(self(), :tick, @tick_ms)}
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | timer: nil}
  end

  defp running?(state), do: match?(%Logic{}, state.logic) and state.logic.state != :blocked

  # -- panel-facing ---------------------------------------------------------------

  # A caçada parada é o snapshot vazio COM TODAS AS CHAVES: a tela lê os campos
  # direto, e um mapa que muda de forma entre parado e rodando quebraria o
  # template no pior momento — quando o bot acabou de parar.
  @idle_snapshot %{
    state: :idle,
    route: nil,
    wp_index: 0,
    wp_total: 0,
    wp_target: nil,
    pos: nil,
    pos_age_ms: nil,
    distance_tiles: nil,
    hold_reason: nil,
    last_action: nil,
    counters: %{waypoints: 0, steps: 0}
  }

  @doc """
  A forma COMPLETA do snapshot com tudo zerado — o placeholder que o
  `BotSupervisor` usa quando o worker não responde a tempo.
  """
  @spec idle_snapshot() :: snapshot
  def idle_snapshot, do: @idle_snapshot

  defp snapshot(%{logic: nil} = state), do: %{@idle_snapshot | counters: state.counters}

  defp snapshot(%{logic: logic} = state) do
    now = now()

    %{
      state: logic.state,
      route: logic.route.name,
      wp_index: logic.wp_index,
      wp_total: wp_total(state),
      wp_target: wp_target(state),
      pos: state.pos,
      pos_age_ms: state.pos_at && now - state.pos_at,
      distance_tiles: distance_tiles(state),
      hold_reason: hold_reason(state, now),
      last_action: state.last_action,
      counters: state.counters
    }
  end

  defp wp_total(%{logic: %Logic{route: route}}), do: length(route.waypoints)
  defp wp_total(_state), do: 0

  defp wp_target(%{logic: %Logic{} = logic}), do: Enum.at(logic.route.waypoints, logic.wp_index)
  defp wp_target(_state), do: nil

  # Quanto falta em TILES, com sinal — é a leitura que responde "ele está indo
  # para lá mesmo?" olhando dois snapshots seguidos.
  defp distance_tiles(%{pos: {x, y, _z}} = state) do
    case wp_target(state) do
      %{x: wx, y: wy} -> %{dx: wx - x, dy: wy - y}
      nil -> nil
    end
  end

  defp distance_tiles(_state), do: nil

  # O gatilho do broadcast compara o que muda por FATO, nunca por relógio:
  # `pos_age_ms` e o `at` do last_action andam sozinhos e emitiriam 5 mapas por
  # segundo para sempre — ruído que enterra a mudança de verdade.
  defp broadcast_key(state, now) do
    {logic_state(state), state.logic && state.logic.wp_index, hold_reason(state, now),
     action_text(state)}
  end

  defp logic_state(%{logic: %Logic{state: s}}), do: s
  defp logic_state(_state), do: :idle

  defp action_text(%{last_action: %{text: text}}), do: text
  defp action_text(_state), do: nil

  # "por que não está andando", no molde dos outros workers (fishing,
  # player_support): o motivo de fora do tick primeiro (feed perdido, bloqueio),
  # porque ele é o mais grave; o passo recusado depois, porque é o obstáculo
  # concreto do tick; a cegueira por último, porque explica os ticks em que nem
  # se tenta andar. Todos juntos quando todos valem. nil = nada segurando.
  #
  # Cada motivo vem com um TIPO, e o tipo é o que decide se ele já foi contado no
  # feed: o texto da cegueira muda a cada segundo (o contador anda) sem nenhum
  # fato novo, e comparar texto viraria uma linha de log por segundo.
  defp holds(%{logic: nil}, _now), do: []

  defp holds(state, now) do
    Enum.reject(
      [note_hold(state.hold_note), step_hold(state.last_step), blind_hold(state.logic, now)],
      &is_nil/1
    )
  end

  defp hold_reason(state, now) do
    case holds(state, now) do
      [] -> nil
      reasons -> reasons |> Enum.map_join(" + ", &elem(&1, 1))
    end
  end

  defp note_hold(nil), do: nil
  defp note_hold(text), do: {:note, text}

  defp step_hold(%{result: {:error, reason}}), do: {{:step, reason}, step_hold_text(reason)}
  defp step_hold(_ok_or_no_step), do: nil

  defp step_hold_text(:input_gate_closed), do: "jogo sem foco (ou pânico) — nada é clicado"
  defp step_hold_text(:no_layout), do: "HUD não localizado — não sei onde fica o minimapa"
  defp step_hold_text(reason), do: "o passo no minimapa falhou: #{inspect(reason)}"

  defp blind_hold(logic, now) do
    case Logic.blind_ms(logic, now) do
      nil ->
        nil

      ms ->
        {:blind,
         "não sei onde estou há #{div(ms, 1000)}s — a coordenada do minimapa não está sendo lida"}
    end
  end

  # -- narrativa (o feed do painel) -----------------------------------------------

  # Chegar num waypoint é o único progresso que a caçada tem: a Logic já avançou
  # o índice, então quem chegou é o waypoint ANTERIOR — é o número dele que o
  # humano reconhece na lista da rota.
  defp note_arrival(%{logic: %Logic{wp_index: same}} = state, same, _now), do: state

  defp note_arrival(state, wp_before, now) do
    text = "waypoint #{wp_before + 1}/#{wp_total(state)}"
    log(:macro, text)
    %{state | counters: bump(state.counters, :waypoints), last_action: %{text: text, at: now}}
  end

  # O motivo da espera é informação na BORDA: uma linha quando ele APARECE, e
  # silêncio enquanto continua valendo. Repetir a cada 200ms afogaria o feed
  # exatamente quando ele mais precisa ser lido. Some e volta = borda nova, linha
  # nova — é fato diferente.
  defp log_hold_edge(state, now) do
    holds = holds(state, now)

    for {kind, text} <- holds, kind not in state.logged_holds, do: log(:macro, text)

    %{state | logged_holds: Enum.map(holds, &elem(&1, 0))}
  end

  # Um motivo que já foi anunciado por quem o criou (bloqueio, feed perdido) não
  # pode ser anunciado de novo pela borda no tick seguinte.
  defp mark_logged(state, kind), do: %{state | logged_holds: [kind | state.logged_holds]}

  defp log(level, text), do: broadcast({:cavebot_log, level, "caçada: " <> text})

  defp bump(counters, key), do: Map.update(counters, key, 1, &(&1 + 1))

  # Parar guarda só os CONTADORES: "a caçada fez 12 waypoints e 340 passos" é o
  # resumo que interessa depois do halt. Motivo, última ação e posição são do
  # tick — e um tick que não existe mais não pode continuar explicando a tela.
  defp end_session(state), do: %{reset_session(state) | counters: state.counters}

  # Uma caçada nova não herda nada da anterior: contadores, última ação, motivos
  # e a posição conhecida são todos daquela sessão.
  defp reset_session(state) do
    %{
      state
      | last_step: nil,
        pos: nil,
        pos_at: nil,
        counters: %{waypoints: 0, steps: 0},
        last_action: nil,
        hold_note: nil,
        logged_holds: []
    }
  end

  defp broadcast_status(state), do: broadcast({:cavebot, snapshot(state)})

  defp broadcast(message), do: Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, message)

  defp now, do: System.monotonic_time(:millisecond)
end
