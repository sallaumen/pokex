defmodule Pokex.Bots.Catcher.Worker do
  @moduledoc """
  Driver for the pure Catcher.Logic: consumes `:corpses` observations from the perception
  blackboard, throws confirmed Pokéballs through the Body (`:high`), and follows the player
  mode LIVE — `parado` attaches the feed and acts; `movimento` detaches and idles (Lucas
  captures manually while moving). Combat's kill broadcast is only an accelerator: it forces
  an immediate world re-read; detection never depends on it. A confirmed kill also triggers a
  Space loot (gated by `loot_enabled`) before any ball of that cycle — the corpse consumed by
  a ball takes its loot with it. `capture_enabled` independently gates the entire ball
  pipeline (and the feed attach) so loot-only operation never throws.

  Combat-engagement gate: PXG combat is tile-locked — a FIGHTING sprite stands still,
  indistinguishable from a corpse to the stationary-blob detector — so this worker also
  tracks Combat.Worker's "combat" snapshots. While combat is :tabbing/:fighting, observations
  are held (no admissions/throws/confirms: they would be contaminated by the live enemy) and
  the feed is never (re)attached (a mid-fight attach would warm the baseline up on the enemy
  sprite and mask the melee tile forever). The disengage edge (kill landed or the fight ended)
  immediately re-checks the world so capture stays prompt, and lets a parado+armed+detached
  worker re-attach right away — the ground is back to normal.
  """
  use GenServer
  require Logger

  alias Pokex.Bots.Body
  alias Pokex.Bots.Catcher.{Ball, Logic}
  alias Pokex.Perception
  alias Pokex.Perception.Feed
  alias Pokex.Settings

  @topic "catcher"
  @kill_topic "combat:kill"

  @config_keys [
    :corpse_match_tolerance_px,
    :corpse_max_balls,
    :corpse_ignore_ttl_ms,
    :corpse_confirm_after_ms,
    :feed_corpses_ms
  ]

  def topic, do: @topic
  def kill_topic, do: @kill_topic

  def start_link(opts \\ []) do
    init_arg = %{
      body: Keyword.get(opts, :body, Body),
      # a visão ancorada no kill; injetável nos testes como o Body
      scanner: Keyword.get(opts, :scanner, &Pokex.Bots.Catcher.SpotScan.scan/0)
    }

    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, init_arg)
      name -> GenServer.start_link(__MODULE__, init_arg, name: name)
    end
  end

  def run(server \\ __MODULE__), do: GenServer.call(server, :run)
  def halt(server \\ __MODULE__), do: GenServer.call(server, :halt)
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "The panel pokes this after flipping player_mode / the loot & capture toggles — attach/detach applies live."
  def mode_changed(server \\ __MODULE__), do: GenServer.call(server, :mode_changed)

  @doc "Force a fresh ground warmup (detach + attach): use after moving to a new spot."
  def relearn(server \\ __MODULE__), do: GenServer.call(server, :relearn)

  @impl true
  def init(%{body: body, scanner: scanner}) do
    Phoenix.PubSub.subscribe(Pokex.PubSub, @kill_topic)
    Phoenix.PubSub.subscribe(Pokex.PubSub, Perception.topic())
    Phoenix.PubSub.subscribe(Pokex.PubSub, Pokex.Bots.Combat.Worker.topic())
    # a SHINY sighting overrides capture_enabled for the next ball (Lucas:
    # "O Shiny sempre tem que tentar")
    Phoenix.PubSub.subscribe(Pokex.PubSub, "shiny")

    {:ok,
     %{
       logic: nil,
       body: body,
       scanner: scanner,
       timer: nil,
       attached?: false,
       combat_engaged?: false,
       feed_ref: nil,
       reattach_attempts: 0,
       loots: 0,
       # o portão fechado já foi anunciado nesta rodada? (log por BORDA)
       segurada?: false,
       # R4: quantos de cada corpo foram ENCONTRADOS nesta sessão, e o conjunto
       # visto na varredura anterior (dedup consecutivo)
       contagem: %{},
       vistos: MapSet.new(),
       # o placar da sessão (zerado em cada Iniciar): quantas varreduras
       # aconteceram, quantas acharam alvo, e quantas cegaram
       varreduras: 0,
       com_alvo: 0,
       cegas: 0,
       # a shiny was just seen: the NEXT ball ignores capture_enabled
       shiny_pending?: false,
       # last performed actuation as %{text, at} (monotonic ms; nil until the first) — panel-facing
       last_action: nil
     }}
  end

  @impl true
  def handle_call(:run, _from, state) do
    {logic, _} = Logic.start(Logic.new(config()), now())

    state = %{
      state
      | logic: logic,
        loots: 0,
        varreduras: 0,
        com_alvo: 0,
        cegas: 0,
        contagem: %{},
        vistos: MapSet.new(),
        combat_engaged?: seed_combat_engaged()
    }

    state = sync_mode(state)
    announce_library()
    broadcast(state)
    {:reply, :ok, state}
  end

  def handle_call(:halt, _from, %{logic: nil} = state), do: {:reply, :ok, state}

  def handle_call(:halt, _from, state) do
    {logic, _} = Logic.stop(state.logic)
    state = detach(%{state | logic: logic})
    broadcast(state)
    {:reply, :ok, cancel_timer(%{state | reattach_attempts: 0})}
  end

  def handle_call(:status, _from, state), do: {:reply, snapshot(state), state}

  def handle_call(:mode_changed, _from, %{logic: nil} = state), do: {:reply, :ok, state}

  def handle_call(:mode_changed, _from, state) do
    state = %{state | combat_engaged?: seed_combat_engaged()}
    state = sync_mode(state)
    broadcast(state)
    {:reply, :ok, state}
  end

  def handle_call(:relearn, _from, state) do
    state = state |> reset_logic() |> detach() |> sync_mode()
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:world, :corpses, obs}, %{logic: %Logic{state: :armed}} = state),
    do: {:noreply, advance(state, obs)}

  def handle_info({:world, _key, _obs}, state), do: {:noreply, state}

  def handle_info(:wake, %{logic: %Logic{state: :armed}} = state),
    do: {:noreply, advance(state, scan_obs(state))}

  def handle_info(:wake, state), do: {:noreply, state}

  # kill = accelerator (both shapes: Task 5 drops the payload; tolerate the old one meanwhile).
  # loot_kill runs BEFORE advance: the Space presses must land ahead of any ball this cycle.
  # A visão é ANCORADA AQUI: o kill diz que um corpo acabou de cair num tile
  # vizinho — o SpotScan pergunta ao acervo qual (ver Catcher.SpotScan).
  def handle_info({:kill}, %{logic: %Logic{state: :armed}} = state) do
    state = loot_kill(state)
    {:noreply, advance(state, scan_obs(state))}
  end

  def handle_info({:kill, _corpse}, %{logic: %Logic{state: :armed}} = state) do
    state = loot_kill(state)
    {:noreply, advance(state, scan_obs(state))}
  end

  # Combat-engagement gate: track the live fight so a stationary enemy sprite never gets
  # balled/ignore-poisoned like a corpse. On the engaged→disengaged edge (kill landed or the
  # fight ended) the corpse track is already mature — re-check the world immediately instead
  # of waiting for the next event/poll, and let a parado+armed+detached worker re-attach now
  # (the ground is back to normal, so a fresh warmup here is safe).
  def handle_info({:combat, %{state: combat_state}}, state) do
    engaged? = combat_state in [:tabbing, :fighting]
    disengaged? = state.combat_engaged? and not engaged?
    edge? = engaged? != state.combat_engaged?
    state = %{state | combat_engaged?: engaged?}

    # The engage/disengage EDGE broadcasts so the panel's "esperando fim da luta"
    # reason appears and clears in real time, not only on the next corpse event.
    if edge? and state.logic != nil, do: broadcast(state)

    # combat_engaged? tracks regardless of our own state (so a :run mid-fight starts correctly
    # gated); the disengage ACTION (attach + advance) only applies once there is a real armed
    # logic to drive — nil/halted must never reach Logic.step/3.
    state =
      if disengaged? and match?(%Logic{state: :armed}, state.logic) do
        # o kill pode ter chegado com a luta ainda "engajada" no nosso espelho
        # (ordem dos broadcasts) — a borda do desengate re-escaneia na hora
        advance(state, scan_obs(state))
      else
        state
      end

    {:noreply, state}
  end

  # The :corpses feed died (its consumers map — and this worker's registration — dies with
  # it; a restarted feed starts with nobody attached). Manual/halted: nothing to blind, do not
  # schedule a reattach. Otherwise a silently-detached catcher would stop capturing forever the
  # moment the feed restarts — retry-attach on a short timer instead (mirrors Combat.Worker's
  # battle-feed monitor).
  def handle_info({:DOWN, ref, :process, _obj, _reason}, %{feed_ref: ref} = state) do
    state = %{state | attached?: false, feed_ref: nil}
    state = if armed_parado?(state), do: schedule_reattach(state), else: state
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _obj, _reason}, state), do: {:noreply, state}

  def handle_info(:reattach_corpses, state) do
    cond do
      not armed_parado?(state) or state.attached? ->
        {:noreply, state}

      state.combat_engaged? ->
        # a fight is in progress — attaching now would warm up on the live sprite; retry later
        {:noreply, schedule_reattach(state)}

      true ->
        {:noreply, reattach_corpses(state)}
    end
  end

  # A shiny is on screen: arm the override so the ball flies even with capture
  # off, and make sure the corpse feed is attached to see its body.
  def handle_info({:shiny_seen, _info}, state) do
    state = %{state | shiny_pending?: true}
    {:noreply, if(should_be_attached?(state), do: attach(state), else: state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # capture_enabled OR a pending shiny (never lose a shiny to a toggle).
  defp capture_allowed?(state),
    do:
      Settings.get(:capture_enabled) or
        (state.shiny_pending? and Settings.get(:shiny_always_ball))

  # -- step pipeline -------------------------------------------------------------

  # The mode gate lives HERE, not only in attach/detach: a late in-flight {:world,...} event
  # (or a test-injected one) right after flipping to movimento must never throw a ball.
  # The mini-game gate comes first: no admissions, throws or confirms while it
  # plays. The catcher is event-driven — the next corpse/kill/combat event after
  # the fact clears resumes the flow on its own.
  defp advance(state, obs) do
    state = contar(state, obs)

    cond do
      Perception.mini_game_playing?() -> state
      Settings.get(:player_mode) == "parado" -> do_advance(state, obs)
      true -> state
    end
  end

  # Os números que faltavam pra medir uma mudança em vez de torcer por ela: a
  # sessão inteira em três contadores no card. `com_alvo` sobe quando ALGUM
  # corpo do acervo passou do limiar — a razão varreduras:com_alvo é o
  # termômetro da mira (medido em 2026-07-30: 242 kills → 1 reconhecimento).
  defp contar(state, %{scanning?: true} = obs) do
    achou? = Map.get(obs, :corpses, []) != []

    state
    |> Map.merge(%{
      varreduras: state.varreduras + 1,
      com_alvo: state.com_alvo + if(achou?, do: 1, else: 0)
    })
    |> contar_por_corpo(obs)
  end

  defp contar(state, %{scanning?: false}), do: %{state | cegas: state.cegas + 1}
  defp contar(state, _sem_varredura), do: state

  # "Quantos Kingler eu encontrei nesta sessão?" — o pedido R4 do Lucas.
  #
  # Dedup CONSECUTIVO (a mesma ideia do Journal): a confirmação de uma bola
  # re-escaneia os mesmos tiles, e sem isto um corpo parado ali contaria de novo
  # a cada varredura. Só o que ENTROU desde a varredura anterior soma. Não sai
  # de `counters.captures` de propósito: aquele número mede "o ponto parou de
  # casar", não captura — mentiria pelo mesmo motivo que os logs mentiam.
  defp contar_por_corpo(state, obs) do
    vistos =
      obs
      |> Map.get(:known, %{})
      |> MapSet.new(fn {ponto, %{name: nome}} -> {nome, ponto} end)

    novos = MapSet.difference(vistos, state.vistos)

    contagem =
      Enum.reduce(novos, state.contagem, fn {nome, _ponto}, acc ->
        Map.update(acc, nome, 1, &(&1 + 1))
      end)

    if contagem != state.contagem, do: broadcast_contagem(contagem)

    %{state | vistos: vistos, contagem: contagem}
  end

  defp broadcast_contagem(contagem),
    do: Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:catcher_contagem, contagem})

  # A fight is on: everything reaching here is contaminated by the live enemy sprite
  # (tile-locked, stands still — indistinguishable from a corpse). No admissions, no throws,
  # no confirms until combat disengages (see the {:combat,...} handler above).
  defp do_advance(%{combat_engaged?: true} = state, _obs), do: state

  # Capture disabled (loot-only operation): the ball pipeline never steps — no admissions,
  # no throws, no confirms. The feed is also detached (see should_be_attached?/1); this
  # gate only catches stragglers (a late event right after the toggle flip).
  defp do_advance(state, obs) do
    cond do
      not capture_allowed?(state) ->
        state

      # Perguntar ao PORTÃO antes de decidir — a mesma lição que o cavebot
      # aprendeu (Body.step_minimap): `Rig.Mac.gated/1` devolve `:ok` quando
      # SUPRIME, então agir e depois olhar o retorno faria a Logic contar uma
      # bola que nunca saiu, gastar a fila e abrir janela de confirmação contra
      # um corpo intocado. Pular o passo inteiro deixa o corpo lá pro próximo
      # kill, que é a verdade.
      not gate_aberto?() ->
        segurar(state)

      true ->
        run_step(%{state | segurada?: false}, obs)
    end
  end

  defp gate_aberto? do
    Pokex.Bots.InputGate.allowed?()
  catch
    :exit, _reason -> false
  end

  # Uma linha por BORDA, não por evento: com o navegador em foco o portão fica
  # fechado por minutos, e um alarme por kill viraria sirene.
  defp segurar(%{segurada?: true} = state), do: state

  defp segurar(state) do
    log(:macro, "🔒 bola SEGURADA — o jogo não está em foco (ou o pânico está armado)")
    %{state | segurada?: true}
  end

  defp run_step(state, obs) do
    {logic, actions} = Logic.step(state.logic, obs, now())

    performs = Enum.filter(actions, &match?({:capture_sequence, _}, &1))

    # A Logic fala "arremesse em X"; QUEM SABE COMO é o Catcher.Ball (posicionar,
    # bater, acionar o atalho configurado, segurar o cursor). Cada passo passa
    # pelo portão e pelo gate do mini-game em vez de um primitivo opaco do Rig.
    resultado =
      if performs != [] do
        performs
        |> Enum.flat_map(fn {:capture_sequence, ponto} -> Ball.sequence(ponto) end)
        |> Body.perform(:high, state.body)
      end

    # O retorno era DESCARTADO — um erro real da atuação sumia e o feed escrevia
    # "bola arremessada" do mesmo jeito.
    case resultado do
      {:error, motivo} ->
        log(:macro, "⚠️ a bola não saiu: #{inspect(motivo)}")

      _ok_ou_sem_bola ->
        :ok
    end

    state =
      if performs != [] do
        # a ball that flew because a SHINY was seen closes that log entry
        if state.shiny_pending?, do: Pokex.Pokedex.ShinyLog.resolve_last("bola")

        %{
          state
          | last_action: %{text: "bola arremessada (#{Ball.key()})", at: now()},
            shiny_pending?: false
        }
      else
        state
      end

    for {:log, text} <- actions do
      Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:catcher_log, :macro, "captura: #{text}"})
    end

    # A bola diz QUEM está na mira: o interpretador já reconheceu o corpo pelo
    # acervo (só corpo mapeado vira alvo desde 2026-07-30) e o nome viaja na
    # observação — jogar a informação fora deixava o Lucas validando às cegas.
    for {:capture_sequence, point} <- performs, info = known_at(obs, point), info != nil do
      Phoenix.PubSub.broadcast(
        Pokex.PubSub,
        @topic,
        {:catcher_log, :macro,
         "captura: 🎯 #{info.name} reconhecido (#{trunc(info.score * 100)}%)"}
      )
    end

    # pending_corpses joins the change condition: suporte holds on that number,
    # so its transitions must reach the wire even on an action-less step
    if logic.counters != state.logic.counters or actions != [] or
         Logic.pending(logic) != Logic.pending(state.logic),
       do: broadcast(%{state | logic: logic})

    schedule_wake(%{state | logic: logic})
  end

  # A confirmed kill just dropped a corpse on the ADJACENT melee tile — Space reaches it from
  # standing position. Runs BEFORE the advance so the presses hit the Body ahead of any ball
  # of this cycle (the ball additionally waits on detector confirmation, ≥800ms later — and
  # the ball consumes the corpse WITH its loot, so the order is load-bearing).
  defp loot_kill(state) do
    # Looting works in BOTH modes: Space reaches the corpse on the tile where the
    # kill just happened, wherever he is standing at that instant. Only the BALL
    # needs him still — it is aimed from a ground baseline learned while standing
    # — and that is gated separately in advance/2. The mode check that used to
    # sit here was inherited from the capture design and silently cost him every
    # drop while walking.
    #
    # Space is the MINI-GAME's control key: looting mid-game would drive the
    # capsule (the Body gate also blocks it — this keeps the log honest too).
    if not Perception.mini_game_playing?() and Settings.get(:loot_enabled) do
      presses = max(Settings.get(:loot_presses), 1)
      gap = Settings.get(:loot_press_gap_ms)

      actions =
        [{:press, "space"}]
        |> List.duplicate(presses)
        |> Enum.intersperse([{:wait, gap}])
        |> List.flatten()

      Body.perform(actions, :high, state.body)

      Phoenix.PubSub.broadcast(
        Pokex.PubSub,
        @topic,
        {:catcher_log, :macro, "captura: 🧰 saqueando (espaço ×#{presses})"}
      )

      state = %{
        state
        | loots: state.loots + 1,
          last_action: %{text: "saque (espaço ×#{presses})", at: now()}
      }

      broadcast(state)
      state
    else
      state
    end
  end

  # A observação ancorada no kill. Portões ANTES da captura: escanear com luta
  # engajada casaria o sprite VIVO adjacente (a paleta de um pokémon em pé é a
  # mesma do corpo ensinado dele); movimento/captura-desligada nem olham; o
  # mini-game é dono do momento. nil = um passo que não prova nada (a Logic
  # ignora), nunca uma confirmação falsa.
  defp scan_obs(state) do
    if state.combat_engaged? or Settings.get(:player_mode) != "parado" or
         not capture_allowed?(state) or Perception.mini_game_playing?(),
       do: nil,
       else: state.scanner |> safe_scan() |> narrar()
  end

  # Um scanner que morra (captura falhou, calibração corrompida) vira um passo
  # cego — jamais derruba o worker no meio da frota. Mas a exceção é LOGADA: um
  # rescue silencioso é exatamente como uma varredura que nunca aconteceu vira
  # indistinguível de uma que não achou nada.
  defp safe_scan(scanner) do
    scanner.()
  rescue
    erro ->
      Logger.warning("captura: varredura explodiu — #{Exception.message(erro)}")
      nil
  catch
    :exit, reason ->
      Logger.warning("captura: varredura morreu — #{inspect(reason)}")
      nil
  end

  # Toda varredura vira UMA linha no feed. Antes, os três desfechos possíveis —
  # não varri, varri e não achei, varri e achei — produziam o mesmo silêncio, e
  # o Lucas ficou horas sem saber em qual deles estava (2026-07-30). O score do
  # melhor candidato vai junto mesmo REPROVADO: a distância até o limiar é o
  # diagnóstico da mira.
  defp narrar(nil), do: nil

  defp narrar(%{scanning?: false} = obs) do
    # cegueira é rara e precisa sobreviver ao restart → :macro (vai pro JSONL)
    log(:macro, "🔎 cego: #{motivo_texto(Map.get(obs, :motivo))}")
    obs
  end

  defp narrar(%{janelas: janelas} = obs) do
    # rotina em :debug — vive no feed, não infla o histórico em disco
    log(:debug, "🔎 varri #{janelas} janelas#{quadro_texto(obs)} · " <> melhor_texto(obs))
    obs
  end

  defp narrar(obs), do: obs

  defp quadro_texto(%{regiao: {_x, _y, w, h}}), do: " (#{w}×#{h})"
  defp quadro_texto(_sem_regiao), do: ""

  defp melhor_texto(%{melhor: nil}), do: "acervo vazio"

  defp melhor_texto(%{melhor: %{name: nome, score: score, ponto: {x, y}}, limiar: limiar}) do
    veredicto = if score >= limiar, do: "✓", else: "✗"
    "melhor: #{nome} #{fmt(score)} #{veredicto} em #{x},#{y} (limiar #{fmt(limiar)})"
  end

  defp melhor_texto(_sem_campo), do: "sem leitura"

  defp fmt(n) when is_number(n), do: :erlang.float_to_binary(n / 1, decimals: 2)
  defp fmt(_outro), do: "?"

  defp motivo_texto(:sem_calibracao), do: "sem calibração"
  defp motivo_texto(:sem_ancora), do: "sem personagem nem ponto do pokémon calibrados"
  defp motivo_texto(:sem_arena), do: "sem arena calibrada"

  defp motivo_texto(:fora_da_arena),
    do: "os tiles ao redor do personagem caem FORA da arena calibrada — recalibre a arena"

  defp motivo_texto({:captura_falhou, motivo}), do: "captura falhou (#{inspect(motivo)})"
  defp motivo_texto(outro), do: inspect(outro)

  defp log(level, texto),
    do: Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:catcher_log, level, "captura: #{texto}"})

  # O acervo é a mira — um start com acervo vazio vai passar a sessão inteira
  # sem mirar NADA, e isso merece sirene, não silêncio (era exatamente o tipo
  # de "parece ligado mas não faz nada" que corroía a confiança do Lucas).
  defp announce_library do
    # Antes de falar do acervo: se a bola está desligada, o acervo é irrelevante
    # e o que o Lucas precisa ouvir é OUTRA coisa. Um alarme, não um sussurro —
    # a captura passou horas "ligada" (o bot rodando, o saque saindo) com a
    # chave em false, e nada na tela dizia isso em voz alta.
    if not Settings.get(:capture_enabled) do
      Phoenix.PubSub.broadcast(
        Pokex.PubSub,
        @topic,
        {:rule_alarm, :captura,
         "🔒 captura DESLIGADA (só saque) — ligue o botão Captura no painel; " <>
           "nenhuma Pokébola será arremessada"}
      )
    end

    announce_corpses()
  end

  defp announce_corpses do
    case length(Pokex.Bots.Catcher.CorpseLibrary.list()) do
      0 ->
        Phoenix.PubSub.broadcast(
          Pokex.PubSub,
          @topic,
          {:rule_alarm, :captura,
           "🎯 acervo de corpos VAZIO — a captura não vai mirar nada; fotografe corpos na calibração"}
        )

      n ->
        # "N pokémon ensinados", não "N corpos" — o Lucas leu "acervo com 10
        # corpos" como "10 corpos na tela agora" (2026-07-30)
        Phoenix.PubSub.broadcast(
          Pokex.PubSub,
          @topic,
          {:catcher_log, :macro,
           "captura: 🎯 mira pronta — #{n} pokémon ensinado(s) no acervo da calibração"}
        )
    end
  end

  # A bola voa contra um ponto ADMITIDO em observação anterior; o centro do
  # track pode ter derivado alguns px até aqui — o vizinho mais próximo dentro
  # da tolerância é o mesmo corpo.
  defp known_at(%{known: known}, {px, py}) when is_map(known) and map_size(known) > 0 do
    tolerance = Settings.get(:corpse_match_tolerance_px)

    known
    |> Enum.filter(fn {{x, y}, _info} ->
      abs(x - px) <= tolerance and abs(y - py) <= tolerance
    end)
    |> Enum.min_by(
      fn {{x, y}, _info} -> (x - px) * (x - px) + (y - py) * (y - py) end,
      fn -> nil end
    )
    |> case do
      {_point, info} -> info
      nil -> nil
    end
  end

  defp known_at(_obs, _point), do: nil

  # O feed do detector de chão foi APOSENTADO (2026-07-30): a visão agora é o
  # SpotScan ancorado no kill — a operação real (pesca + combate contínuos)
  # nunca tem a janela quieta que o aquecimento do baseline exigia; o warmup
  # acontecia com luta na tela, mascarava os tiles dos corpos e a captura
  # ficava muda a sessão inteira. O maquinário de attach/reattach abaixo fica
  # inerte (nada nunca anexa); a remoção do Interpret.Corpses/feed é faxina
  # separada.
  defp sync_mode(state) do
    if should_be_attached?(state), do: attach(state), else: cancel_timer(detach(state))
  end

  defp armed_parado?(state),
    do: Settings.get(:player_mode) == "parado" and match?(%Logic{state: :armed}, state.logic)

  defp should_be_attached?(_state), do: false

  defp attach(%{attached?: true} = state), do: state

  defp attach(state) do
    safe(fn -> Perception.attach(:corpses) end)
    demonitor_feed(state.feed_ref)
    ref = Process.monitor(Feed.name(:corpses))
    %{state | attached?: true, feed_ref: ref, reattach_attempts: 0}
  end

  defp detach(%{attached?: false} = state), do: state

  defp detach(state) do
    safe(fn -> Perception.detach(:corpses) end)
    demonitor_feed(state.feed_ref)
    %{state | attached?: false, feed_ref: nil}
  end

  defp demonitor_feed(nil), do: :ok
  defp demonitor_feed(ref), do: Process.demonitor(ref, [:flush])

  defp schedule_reattach(%{reattach_attempts: attempts} = state) when attempts >= 20, do: state

  defp schedule_reattach(state) do
    Process.send_after(self(), :reattach_corpses, 250)
    %{state | reattach_attempts: state.reattach_attempts + 1}
  end

  # The bounded, catch-guarded reattach fired from :reattach_corpses. Unlike attach/1 (used by
  # the normal run/mode_changed/relearn/disengage paths, which must never crash on a feed that
  # isn't registered yet), this one is only reached once we already know the feed just went
  # down — a still-dead feed schedules another bounded retry instead of optimistically marking
  # itself attached.
  defp reattach_corpses(state) do
    Perception.attach(:corpses)
    demonitor_feed(state.feed_ref)
    ref = Process.monitor(Feed.name(:corpses))
    %{state | attached?: true, feed_ref: ref, reattach_attempts: 0}
  catch
    :exit, _ -> schedule_reattach(state)
  end

  defp reset_logic(%{logic: nil} = state), do: state

  # "Reaprender chão": a fresh Logic (not just the old one restarted) so the queue/throw/
  # ignored map from the old spot die with the old ground — a stale pending throw surviving
  # the move would confirm/retry against coordinates that mean nothing at the new spot.
  defp reset_logic(state) do
    {logic, _actions} = Logic.start(Logic.new(config()), now())
    %{state | logic: logic}
  end

  defp safe(fun) do
    fun.()
  catch
    :exit, _reason -> :ok
  end

  defp schedule_wake(state) do
    state = cancel_timer(state)

    case Logic.next_wake(state.logic, now()) do
      nil -> state
      ms -> %{state | timer: Process.send_after(self(), :wake, ms)}
    end
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | timer: nil}
  end

  defp config, do: Settings.all() |> Map.take(@config_keys)

  defp mode_state(nil, _mode), do: :idle
  defp mode_state(_logic, "movimento"), do: :manual

  defp mode_state(%Logic{state: :armed}, _mode) do
    if Settings.get(:capture_enabled), do: :armed, else: :saqueando
  end

  defp mode_state(%Logic{state: s}, _mode), do: s

  defp snapshot(state) do
    mode = Settings.get(:player_mode)

    %{
      state: mode_state(state.logic, mode),
      mode: mode,
      counters:
        ((state.logic && state.logic.counters) || %Logic{}.counters)
        |> Map.put(:loots, state.loots)
        |> Map.put(:varreduras, state.varreduras)
        |> Map.put(:com_alvo, state.com_alvo)
        |> Map.put(:cegas, state.cegas),
      error: state.logic && state.logic.error,
      hold_reason: hold_reason(state),
      last_action: state.last_action,
      pending_corpses: (state.logic && Logic.pending(state.logic)) || 0
    }
  end

  # Computed at broadcast time from live state — the engage/disengage edge above
  # guarantees the fight reason appears/clears promptly; the mini-game one rides
  # on whatever event broadcasts while the game plays (the catcher is passive then).
  defp hold_reason(%{logic: nil}), do: nil

  defp hold_reason(state) do
    cond do
      Perception.mini_game_playing?() ->
        "mini-game em jogo"

      state.combat_engaged? ->
        "esperando fim da luta"

      # O portão que passou o dia inteiro fechado sem dizer o nome (2026-07-30:
      # 1015 kills, 1015 saques, zero varredura — a chave estava false e a única
      # pista era a pílula "só saque"). O motivo agora é o primeiro da lista de
      # espera, não uma sutileza que se lê como estado normal.
      not Settings.get(:capture_enabled) ->
        "captura DESLIGADA — só saque"

      true ->
        nil
    end
  end

  defp broadcast(state),
    do: Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:catcher, snapshot(state)})

  # combat only broadcasts on transitions — a catcher arming MID-FIGHT would otherwise
  # believe the field is clear. Best-effort: an unreachable combat reads as not engaged
  # (fail-open matches the boot default; the next transition broadcast corrects it).
  defp seed_combat_engaged do
    %{state: s} = Pokex.Bots.Combat.Worker.status()
    s in [:tabbing, :fighting]
  catch
    :exit, _reason -> false
  end

  defp now, do: System.monotonic_time(:millisecond)
end
