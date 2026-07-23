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
  lida) segura o passo — nunca anda às cegas; e um `{:block, _}` da Logic
  (mudança de andar, stuck esgotado) é o freio de mão completo — latch de
  pânico, frota inteira parada, alarme no tópico, e o worker fica em
  `:blocked` até um humano religar.

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
      combat_state: :idle
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

  @spec status(GenServer.server()) :: %{state: atom, wp_index: non_neg_integer, route: term}
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

        state =
          %{cancel_timer(state) | logic: Logic.new(route, config())}
          |> attach()
          |> schedule_tick()

        broadcast_status(state)
        {:reply, :ok, state}
    end
  end

  def handle_call(:halt, _from, %{logic: nil} = state), do: {:reply, :ok, state}

  def handle_call(:halt, _from, state) do
    Combat.Worker.halt(state.combat)
    state = %{detach(cancel_timer(state)) | logic: nil, reattach_attempts: 0}
    broadcast_status(state)
    {:reply, :ok, state}
  end

  def handle_call(:status, _from, state), do: {:reply, snapshot(state), state}

  # Um tick perdido depois do halt (ou antes do run) é inócuo.
  @impl true
  def handle_info(:tick, %{logic: nil} = state), do: {:noreply, state}

  def handle_info(:tick, state) do
    now = now()
    before = state.logic.state
    {logic, action} = Logic.step(state.logic, world(state, now), now)
    state = translate(%{state | logic: logic}, action)
    if state.logic.state != before, do: broadcast_status(state)
    {:noreply, schedule_tick(state)}
  end

  # O snapshot do combate, guardado do jeito do Combos.Runner: a Logic recebe
  # o último estado ouvido como world.combat_state.
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

  defp world(state, now) do
    %{pos: position(now), enemies: enemy_count(now), combat_state: state.combat_state}
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
  def translate(state, :none), do: state

  def translate(state, {:walk, dx, dy}), do: minimap_step(state, dx, dy)
  def translate(state, {:nudge, dx, dy}), do: minimap_step(state, dx, dy)

  def translate(state, :run_combat) do
    Combat.Worker.run(state.combat)
    state
  end

  def translate(state, :halt_combat) do
    Combat.Worker.halt(state.combat)
    state
  end

  # O freio de mão completo, na ordem do emergency_escape: latch PRIMEIRO
  # (nada pode auto-retomar por cima de um bloqueio — mudou de andar, retomar
  # a caçada seria andar num mapa errado), depois o combate que este worker
  # dirige, depois a frota inteira, depois o alarme. A Logic já está em
  # :blocked (terminal), então nenhum tick futuro é agendado e os feeds são
  # soltos — capturar para ninguém só pesa o broker.
  def translate(state, {:block, reason}) do
    Logger.warning("Cavebot: BLOQUEADO (#{inspect(reason)}) — parando a frota")
    Pokex.Bots.InputGate.set_panic_latch(true)
    Combat.Worker.halt(state.combat)
    Pokex.Bots.BotSupervisor.stop_all()
    broadcast({:cavebot_alarm, reason})
    state = detach(cancel_timer(state))
    broadcast_status(state)
    state
  end

  # Falha de passo (ex.: {:error, :no_layout} sem HUD localizado) não derruba
  # nada: o próximo tick relê o mundo e tenta de novo.
  defp minimap_step(state, dx, dy) do
    case state.body.minimap_step(dx, dy, []) do
      {:ok, _point} -> :ok
      error -> Logger.debug("Cavebot: passo (#{dx},#{dy}) falhou: #{inspect(error)}")
    end

    state
  end

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
    %{state | attached?: true, feed_ref: ref, reattach_attempts: 0}
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
    %{state | attached?: true, feed_ref: ref, reattach_attempts: 0}
  catch
    :exit, _reason -> schedule_reattach(state)
  end

  defp schedule_reattach(%{reattach_attempts: attempts} = state) when attempts >= 20, do: state

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

  defp snapshot(%{logic: nil}), do: %{state: :idle, wp_index: 0, route: nil}

  defp snapshot(%{logic: logic}),
    do: %{state: logic.state, wp_index: logic.wp_index, route: logic.route.name}

  defp broadcast_status(state), do: broadcast({:cavebot, snapshot(state)})

  defp broadcast(message), do: Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, message)

  defp now, do: System.monotonic_time(:millisecond)
end
