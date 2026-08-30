defmodule Pokex.Bots.Combat.Worker do
  @moduledoc """
  Event-driven driver around the pure Tab-targeting Combat.Logic. Consumes battle
  observations from the perception blackboard ("world" PubSub + WorldState), presses Tab
  and skill bursts through the DIRECT keyboard path (never the Body, never the mouse — the
  select-click died with the click-targeting flow), and broadcasts snapshots/kills exactly
  like before. The Guardian owns the panic corner; this worker reads no cursor.

  A fallback timer wakes the logic for its time-based deadlines (tab confirm window, fight
  timeout, hunt hold) even when the battle picture isn't changing — Logic.next_wake says
  when.
  """
  use GenServer
  require Logger

  alias Pokex.Bots.AreaProbe
  alias Pokex.Bots.Catcher.Worker
  alias Pokex.Bots.Combat.{Loadout, Logic, Strategy}
  alias Pokex.Bots.Perf
  alias Pokex.Bots.ReviveLedger
  alias Pokex.Bots.SkillClock
  alias Pokex.Bots.SkillMeter
  alias Pokex.Bots.SkillReceipt
  alias Pokex.Bots.SkillSuspect
  alias Pokex.Perception
  alias Pokex.Perception.{Feed, WorldState}
  alias Pokex.Pokedex.Team
  alias Pokex.{Preflight, Settings}

  @topic "combat"
  @catch_topic "fishing:caught"

  @config_keys [
    :tab_confirm_ms,
    :tab_confirm_frames,
    :tab_max_attempts,
    :hunt_cooldown_ms,
    :scenery_hunts_needed,
    :scenery_ttl_ms,
    :no_damage_ms,
    :after_kill_hold_ms,
    :attack_mode_key,
    :defense_mode_key,
    :hunt_probe_window_ms,
    :skill_burst_every_ms,
    :fight_timeout_ms,
    :target_lost_streak,
    :skill_keys,
    :combat_skill_burst_size,
    :combat_aoe_from_enemies,
    :combat_shield_from_enemies,
    :combat_single_target,
    :combat_tab_target,
    :max_consecutive_failures
  ]

  def topic, do: @topic
  def catch_topic, do: @catch_topic

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, :ok)
      name -> GenServer.start_link(__MODULE__, :ok, name: name)
    end
  end

  @doc """
  Starts the fight. EXPLICIT timeout, because this one is not cheap: the
  `handle_call` runs `Preflight.run/1` inline, and that reaches
  `Capture.display_points/1` — a `GenServer.call(..., :infinity)` on the broker
  that serializes every capture in the app (2-4s each when they contend). The
  hunt calls this from inside its own tick, so the default 5s was a silent exit
  waiting to happen.
  """
  def run(server \\ __MODULE__, timeout \\ 5_000), do: GenServer.call(server, :run, timeout)
  def halt(server \\ __MODULE__), do: GenServer.call(server, :halt)
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(:ok) do
    Phoenix.PubSub.subscribe(Pokex.PubSub, @catch_topic)
    Phoenix.PubSub.subscribe(Pokex.PubSub, Perception.topic())
    # Re-classifying a skill on /time has to reach the fight without a restart,
    # and re-reading the team file every burst is the disk-hammering the
    # recording audit killed. So: cached, invalidated by the change itself.
    Phoenix.PubSub.subscribe(Pokex.PubSub, Team.topic())

    {:ok,
     %{
       logic: nil,
       timer: nil,
       # what the keys of the pokémon he chose DO — nil until :run, and nil
       # forever if he chose none (the fight then presses the configured list)
       loadout: nil,
       # the same loadout in the shape a page reads, computed WHEN IT CHANGES —
       # snapshots go out on every step, and recomputing an order per broadcast
       # is work inside the hot path for a value that only moves when he edits
       loadout_view: nil,
       feed_ref: nil,
       reattach_attempts: 0,
       held?: false,
       # os controles que a ÚLTIMA ordem do cérebro trazia na abertura: o press
       # do controle é disparado na BORDA em que ele aparece (ver
       # `press_engine_crowd/2`), e sem memória a mesma ordem repetida a cada
       # tique viraria um press por tique
       engine_crowd: [],
       # the ONE in-flight key burst (nil when none): a new burst is SKIPPED while the previous
       # is still landing, instead of piling concurrent osascripts onto System Events
       burst_pid: nil,
       # last dispatched burst as %{text, at} (monotonic ms; nil until the first) — panel-facing
       last_action: nil,
       # false only while a RETRY is being dispatched: its own miss must not
       # start another one
       retry_ok?: true,
       # who keeps missing while never being seen on cooldown (SkillSuspect),
       # and who has already been named for it
       suspects: SkillSuspect.new(),
       accused: []
     }}
  end

  @impl true
  def handle_call(:run, _from, state) do
    case Preflight.run() do
      :ok ->
        config = Settings.all() |> Map.take(@config_keys)
        {logic, _actions} = Logic.start(Logic.new(config), now())
        Perception.attach(:battle)
        # The skill-bar feed powers the cooldown-aware rotation. Its loss is GRACEFUL
        # (stale fact → nil → blind rotation), so unlike :battle it gets no monitor and no
        # reattach loop — combat still fights, just blind, exactly as before the feed.
        Perception.attach(:skill_bar)
        # …e a MÃO DELE entra na jogada: enquanto a caçada roda, os apertos que
        # ele mesmo dá (skill ou F4) são vigiados e carimbados como nossos.
        # Mesma graça do skill_bar: um vigia indisponível não muda a luta.
        Pokex.Bots.HandWatch.attach()
        # A double :run (two Start presses) must not leak the previous feed monitor.
        demonitor_feed(state.feed_ref)
        ref = Process.monitor(Feed.name(:battle))

        state =
          %{
            state
            | logic: logic,
              feed_ref: ref,
              reattach_attempts: 0,
              held?: false,
              last_action: nil
          }
          |> put_loadout(Loadout.current())

        log_loadout(state.loadout)

        broadcast(logic, state)
        # step immediately against whatever the world already knows
        {:reply, :ok, advance(state, current_obs())}

      # List.wrap keeps this total without a second clause the type system can
      # prove unreachable.
      {:error, messages} ->
        {:reply, {:error, List.wrap(messages)}, state}
    end
  end

  def handle_call(:halt, _from, %{logic: nil} = state), do: {:reply, :ok, state}

  def handle_call(:halt, _from, state) do
    {logic, _} = Logic.stop(state.logic)
    safe_detach(:battle)
    safe_detach(:skill_bar)
    Pokex.Bots.HandWatch.detach()
    demonitor_feed(state.feed_ref)
    state = %{state | logic: logic, feed_ref: nil, reattach_attempts: 0, held?: false}
    broadcast(logic, state)
    {:reply, :ok, cancel_timer(state)}
  end

  def handle_call(:status, _from, state), do: {:reply, snapshot(state.logic, state), state}

  @impl true
  def handle_info({:world, :battle, obs}, %{logic: %Logic{}} = state),
    do: {:noreply, advance(state, obs)}

  def handle_info({:world, _key, _obs}, state), do: {:noreply, state}

  def handle_info(:wake, %{logic: %Logic{}} = state),
    do: {:noreply, advance(state, current_obs())}

  def handle_info(:wake, state), do: {:noreply, state}

  def handle_info({:fish_caught}, %{logic: %Logic{}} = state) do
    {:noreply, advance(%{state | logic: Logic.rescan(state.logic, now())}, current_obs())}
  end

  def handle_info({:fish_caught}, state), do: {:noreply, state}

  # He re-classified a skill, or chose another pokémon. Re-read now, while the
  # fight is running: the whole point of moving the key order onto the profile
  # is that correcting it is a page edit, not a restart. Only the LOADOUT is
  # refreshed — never the logic, which would drop a fight in progress.
  def handle_info({:team_changed}, state) do
    loadout = Loadout.current()

    if loadout != state.loadout, do: log_loadout(loadout)

    {:noreply, put_loadout(state, loadout)}
  end

  # A key burst failed on its async task (see `dispatch/1`/`tap_keys/2`). Ignore it while
  # halted/errored — same invariant as the world/wake paths above — so a stale failure from
  # a task that outlived a `halt` can't silently reactivate the machine.
  # A skill that did not go off is STILL READY, so pressing it again is exactly
  # right — once. The retry itself is never confirmed (retry_ok?: false), or a
  # bar that cannot be read would keep the two of them pressing forever.
  def handle_info({:skill_bar_seen, ready, watched}, state) do
    {:noreply, %{state | suspects: SkillSuspect.observe(state.suspects, ready, watched)}}
  end

  def handle_info({:skills_missed, keys}, %{logic: %Logic{}} = state) do
    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      @topic,
      {:combat_log, :macro, "combate: 🔁 #{Enum.join(keys, ", ")} não saiu — apertando de novo"}
    )

    state = %{state | suspects: SkillSuspect.missed(state.suspects, keys)} |> accuse()
    state = dispatch(%{state | retry_ok?: false}, Enum.map(keys, &{:press, &1}))

    # …e AGORA a tela cala sobre elas. A retentativa fica: uma tecla comida pelo
    # foco da janela sai na segunda. O que não pode continuar é a rotação
    # oferecer, cinco segundos depois, a mesma tecla que o jogo acabou de
    # ignorar — foi o que ele viu em 27/08, com o jogo escrevendo o cooldown em
    # cima dela.
    #
    # SÓ COM O PORTÃO ABERTO: com o `InputGate` fechado o aperto foi ENGOLIDO
    # antes de chegar no jogo — o `missed` não prova nada sobre a barra, e
    # calar uma tecla boa por 45s porque a janela perdeu o foco era metade dos
    # "cooldowns errados" que ele viu em 28/08.
    if Pokex.Bots.InputGate.allowed?() do
      Enum.each(keys, &SkillClock.denied/1)
      mute_log(keys, cooldowns(state.loadout))
    end

    {:noreply, state}
  end

  def handle_info({:skills_missed, _keys}, state), do: {:noreply, state}

  def handle_info({:key_burst_failed, _reason}, %{logic: %Logic{state: s}} = state)
      when s in [:idle, :error],
      do: {:noreply, state}

  def handle_info({:key_burst_failed, reason}, %{logic: %Logic{}} = state) do
    {logic, actions} = Logic.io_failed(state.logic, inspect(reason), now())
    {:noreply, apply_step(state, logic, actions)}
  end

  def handle_info({:key_burst_failed, _reason}, state), do: {:noreply, state}

  # O F4 aterrissou no meio da rajada e a cauda parou no ar. Não é falha de
  # IO: as teclas seguradas cairiam na janela cega (medido em 30/08 — quase
  # sempre numa tela já vazia). A próxima decisão relê o mundo, e a largada
  # dela continua com o `blackout?/1` no comando.
  def handle_info({:burst_yielded, sent, held}, state) do
    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      @topic,
      {:combat_log, :macro,
       "combate: ✂️ o F4 aterrissou no meio da rajada — saiu #{shown(sent)}, segurei #{shown(held)}"}
    )

    {:noreply, state}
  end

  # The :battle feed died (its consumers map — and this worker's registration — dies with
  # it; a restarted feed starts with nobody attached). Idle/errored: nothing to blind, do
  # not schedule a reattach. Otherwise, combat would silently wedge forever the moment the
  # feed comes back — retry-attach on a short timer instead.
  def handle_info(
        {:DOWN, ref, :process, _obj, _reason},
        %{feed_ref: ref, logic: %Logic{state: s}} = state
      )
      when s in [:idle, :error],
      do: {:noreply, %{state | feed_ref: nil}}

  def handle_info({:DOWN, ref, :process, _obj, _reason}, %{feed_ref: ref} = state) do
    Process.send_after(self(), :reattach_battle, 250)
    {:noreply, %{state | feed_ref: nil}}
  end

  def handle_info({:DOWN, _ref, :process, _obj, _reason}, state), do: {:noreply, state}

  def handle_info(:reattach_battle, %{logic: %Logic{state: s}} = state)
      when s in [:idle, :error],
      do: {:noreply, state}

  # Already reattached (an earlier retry landed and re-monitored) — nothing to do.
  def handle_info(:reattach_battle, %{feed_ref: ref} = state) when not is_nil(ref),
    do: {:noreply, state}

  def handle_info(:reattach_battle, %{logic: %Logic{}} = state),
    do: {:noreply, reattach_battle(state)}

  def handle_info(:reattach_battle, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  # -- the step pipeline -------------------------------------------------------

  defp advance(%{logic: %Logic{state: s}} = state, _obs) when s in [:idle, :error],
    do: cancel_timer(state)

  defp advance(state, obs) do
    cond do
      Perception.mini_game_playing?() -> hold(state)
      state.held? -> state |> resume_from_hold() |> step(current_obs())
      true -> step(state, obs)
    end
  end

  defp step(state, obs) do
    {posture, combo, orders} = posture()

    state =
      state
      |> press_engine_crowd(combo)
      |> open_with_combo(state.logic.posture, posture, combo, orders)

    logic =
      state.logic
      |> Logic.set_posture(posture)
      |> Logic.set_loadout(state.loadout)

    {logic, actions} = Logic.step(logic, with_ready_skills(obs, state.loadout), now())
    apply_step(state, logic, actions)
  end

  # The hunt's opening move, fired on the EDGE where the fire is released —
  # once, not once per frame. It is what HE left at this kill spot: the keys he
  # ORDERED there, then the opening (his recorded combo, or the strategy's area
  # keys). It exists because killing one at a time throws away the gathering
  # ("quando você fica tentando matar de um em um, ele é extremamente mais
  # lento" — 2026-08-11).
  # BEFORE the step, not after: the Logic's own Tab would be dispatched first
  # and this would be dropped by the one-burst-in-flight rule. The combo IS
  # the opening move — area damage needs no target, and Tab comes on the next
  # frame anyway.
  defp open_with_combo(state, :hold_fire, :free_fight, recorded, orders) do
    {source, keys} = opening_keys(state.loadout, recorded)

    # The order HE left on the kill spot goes FIRST: the Body runs the list in
    # order, and an aura that lands after the area damage did nothing at all.
    # Deduped by key — pressing the same one twice only burns its cooldown.
    # These are already keys: resolving a category is the hunt's job, never
    # ours (it is the one that knows which pokémon is out).
    case orders ++ Enum.reject(keys, &(&1 in orders)) do
      [] ->
        state

      all ->
        Phoenix.PubSub.broadcast(
          Pokex.PubSub,
          @topic,
          {:combat_log, :macro,
           "combate: 💥 abrindo #{open_source(source, orders)}: #{Enum.join(all, ", ")}"}
        )

        dispatch(state, Enum.map(all, &{:press, &1}))
    end
  end

  defp open_with_combo(state, _was, _now, _combo, _orders), do: state

  defp open_source(source, []), do: source
  defp open_source(source, _orders), do: "com a ordem da rota + #{source}"

  # "Quando termina o período de mobar, ele vai começar sempre usando as skills
  # em área" (2026-08-11). When the pokémon's keys are classified that is a rule
  # the machine can KEEP — area, then single-target, control never.
  #
  # A MÃO DO CÉREBRO VENCE. A abertura da engine é o MESMO `Strategy.opening`,
  # composto com o que este módulo não tem: a leitura da barra (aura/escudo
  # prontos de verdade) e o tamanho da pilha (a mão pequena do bicho bobo).
  # Recompor aqui era jogar essa informação fora — a auditoria de 28/08 achou o
  # cérebro carimbando um stun que ninguém apertava porque a lista dele morria
  # exatamente nesta função. O controle NÃO sai daqui: ele tem via própria, na
  # borda em que aparece (`press_engine_crowd/2`), porque o momento dele é o da
  # ordem, não o da liberação do fogo.
  #
  # The recorded combo stays as the fallback, and it is a worse one on purpose:
  # it presses whatever his hands pressed at that waypoint, which stops being
  # true the moment he swaps pokémon, and can spend a control skill that was
  # supposed to survive for the revive.
  defp opening_keys(loadout, {:engine, keys}) do
    {"com a mão do cérebro", Enum.reject(keys, &(&1 in crowd_keys(loadout)))}
  end

  defp opening_keys(loadout, recorded) do
    if Loadout.attacks?(loadout),
      do:
        {"em área com #{loadout.name}",
         Strategy.opening(loadout, aura_ready?: aura_ready?(loadout))},
      else: {"com o combo da caçada", recorded -- crowd_keys(loadout)}
  end

  defp crowd_keys(nil), do: []
  defp crowd_keys(loadout), do: loadout.crowd

  # R10, DE VERDADE. `stun_now?`/`stun_before_reset?` põem o controle na frente
  # da abertura e carimbam `:stunned` — e até 28/08 ninguém apertava: a
  # recomposição local descartava a lista, o moduledoc do Strategy diz "control
  # never", e a janela dos 5s abria sobre um stun que não aconteceu. O único
  # stun real era o que o resgate refazia por conta própria, 800ms antes do F4.
  #
  # O press é na BORDA em que o controle entra na ordem: o cérebro repete a
  # mesma ordem a cada tique de 200ms, e stun é UMA tecla, não uma cadência. A
  # borda de saída limpa a memória; ordem sem mão do cérebro idem.
  defp press_engine_crowd(state, {:engine, keys}) do
    crowd = Enum.filter(keys, &(&1 in crowd_keys(state.loadout)))

    case crowd -- state.engine_crowd do
      [] ->
        %{state | engine_crowd: crowd}

      fresh ->
        # Só LATCHA quando a tecla saiu: `try_dispatch` pula rajada com outra
        # em voo, e uma borda consumida num pulo era um stun perdido em
        # silêncio. Pulado, a memória fica como estava — e se a ordem seguinte
        # já não trouxer o controle (a janela abre no tique seguinte), o
        # resgate re-faz o stun por conta própria, como sempre fez.
        case try_dispatch(state, Enum.map(fresh, &{:press, &1})) do
          {state, :skipped} ->
            state

          {state, _sent_or_nothing} ->
            Phoenix.PubSub.broadcast(
              Pokex.PubSub,
              @topic,
              {:combat_log, :macro, "combate: 💤 controle do cérebro: #{Enum.join(fresh, ", ")}"}
            )

            %{state | engine_crowd: crowd}
        end
    end
  end

  defp press_engine_crowd(state, _no_engine_hand), do: %{state | engine_crowd: []}

  # What the hunt is asking of us, read as a FACT with an age — the same
  # contract as every other reading on the blackboard. Stale, missing or
  # unreadable all mean `:free_fight`: the posture may only ever stop combat
  # while something is actively saying so, so a dead or stopped cavebot can
  # never leave the bot standing pacifist in the middle of a crowd.
  #
  # THE ENGINE OUTRANKS THE POSTURE when it is speaking. Its answer is the same
  # question decided with more than the leg of the route — the count on screen,
  # whether the pile stopped arriving, and the health band. But only while it is
  # FRESH: the moment its fact ages out, this falls back to the posture, which
  # falls back to free fire. Two fallbacks deep, and the floor is today's bot.
  #
  # The route's ordered categories keep riding the posture either way: the
  # engine decides WHETHER to open and WITH WHAT, never what he wrote on a
  # corner.
  defp posture do
    fact = posture_fact()

    case engine_fire() do
      nil ->
        fact

      {fire, opening} ->
        {fire, tag_engine(opening_or(opening, elem(fact, 1)), opening), elem(fact, 2)}
    end
  end

  # A mão que veio DO CÉREBRO carrega a marca: `opening_keys/2` a obedece
  # inteira, enquanto o combo gravado num canto continua sendo só o fallback de
  # quem não tem loadout. Sem a marca as duas listas eram indistinguíveis — e a
  # do cérebro morria na recomposição local.
  defp tag_engine(keys, []), do: keys
  defp tag_engine(keys, _engine_opening), do: {:engine, keys}

  defp posture_fact do
    case WorldState.get(:posture, Settings.get(:posture_max_age_ms), now()) do
      {:ok, %{posture: :hold_fire} = fact} -> {:hold_fire, combo_of(fact), orders_of(fact)}
      {:ok, fact} -> {:free_fight, combo_of(fact), orders_of(fact)}
      _stale_or_missing -> {:free_fight, [], []}
    end
  end

  defp engine_fire do
    case WorldState.get(:orders, Settings.get(:engine_orders_max_age_ms), now()) do
      {:ok, %{fire: :hold} = orders} -> {:hold_fire, Map.get(orders, :opening) || []}
      {:ok, %{fire: :free} = orders} -> {:free_fight, Map.get(orders, :opening) || []}
      _stale_or_missing -> nil
    end
  end

  # An engine with no keys to name (no pokémon chosen, or one unclassified) must
  # not silently erase the combo he recorded at this kill spot.
  defp opening_or([], recorded), do: recorded
  defp opening_or(opening, _recorded), do: opening

  defp combo_of(fact), do: Map.get(fact, :combo) || []

  # A fact published by a hunt that predates the field simply has no orders.
  # Map.get, not a pattern: a missing key must read as "none", never crash.
  defp orders_of(fact), do: Map.get(fact, :orders) || []

  defp log_loadout(loadout) do
    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      @topic,
      {:combat_log, :macro, "combate: lutando como #{Loadout.describe(loadout)}"}
    )
  end

  # The freshest skill-bar reading rides along on every observation the logic sees, so the
  # burst it decides fires only READY skills. nil obs stays nil (a timer wake without a
  # frame must not become a fake observation), and a missing/stale/unreadable fact merges
  # as nil → Logic blind-rotates (fail-open; see Logic.press_next_skill).
  defp with_ready_skills(nil, _loadout), do: nil

  defp with_ready_skills(obs, loadout) do
    obs
    |> Map.put(:ready_skills, ready_skills(loadout))
    |> Map.put(:own_out?, own_pokemon_out?())
  end

  # AS DUAS FONTES, cruzadas: a tela sabe de coisas que ninguém escreveu e o
  # relógio sabe da tecla que saiu agora e a foto ainda não mostrou. Com a barra
  # ilegível o relógio responde sozinho, e é aí que ele paga: antes disso, uma
  # leitura ruim mandava o combate rodar a barra às cegas.
  defp ready_skills(loadout),
    do: SkillClock.ready(Perception.ready_skills(), Loadout.keys(loadout), cooldowns(loadout))

  defp cooldowns(%Loadout{cooldowns: cooldowns}), do: cooldowns
  defp cooldowns(_no_loadout), do: %{}

  # Reading his pokémon's HP bar IS the proof it is out of its ball — the same
  # bar PlayerSupport potions and revives from. With it out, a battle list of
  # exactly ONE row is almost certainly that pokémon, and the slow three-hunt
  # scenery dance is the wrong tool (Lucas, 2026-08-10: "está muito lento!!!").
  defp own_pokemon_out?,
    do: match?({:ok, %{hp_pct: pct}} when is_integer(pct), Perception.pokemon())

  # Frozen while the mini-game plays: no steps, no bursts. Combat is
  # event-driven and a static battle would never deliver the resume edge, so
  # poll :wake while held (every :wake funnels back through advance/2).
  # The freeze EDGE broadcasts once so the panel shows WHY combat stopped.
  @held_poll_ms 250
  defp hold(state) do
    if not state.held?, do: broadcast(state.logic, %{state | held?: true})
    state = cancel_timer(state)
    %{state | held?: true, timer: Process.send_after(self(), :wake, @held_poll_ms)}
  end

  # The fight state frozen many seconds ago is garbage — restart the machine,
  # exactly what the old external halt+run pair produced.
  defp resume_from_hold(state) do
    config = Settings.all() |> Map.take(@config_keys)
    {logic, _actions} = Logic.start(Logic.new(config), now())
    state = %{state | logic: logic, held?: false}
    broadcast(logic, state)
    state
  end

  defp apply_step(state, logic, actions) do
    previous = state.logic
    previous_action = state.last_action

    # A skipped burst is not a performed one: the Logic has to hear about it, or the
    # stance it latched while deciding would be believed on a key that never went out.
    {state, outcome} = try_dispatch(state, actions)
    logic = if outcome == :skipped, do: Logic.dropped(logic, actions), else: logic

    broadcast_activity(previous, logic, actions)

    # KILL first, snapshot second: the Catcher loots on {:kill} (Space presses) and throws the
    # ball on the disengage snapshot's advance — the ball consumes the corpse WITH its loot, so
    # this producer-side order IS the loot-before-ball guarantee (same sender → same receiver
    # preserves it).
    if logic.counters.fights > previous.counters.fights do
      broadcast_kill()
      # …e o mesmo instante, TIPADO. Sem isto uma noite de verdade não tem
      # numerador: o simulador conta mortos porque é dono do mundo, e aqui o
      # único lugar que sabe que um alvo caiu é este contador.
      Pokex.Engine.Events.record(:kill, %{n: logic.counters.fights})
    end

    if logic.state != previous.state or logic.counters != previous.counters or
         state.last_action != previous_action,
       do: broadcast(logic, state)

    schedule_wake(%{state | logic: logic})
  end

  # Tab + skills are keys → the direct fire-and-forget path (a key must never wait behind a
  # mouse sequence holding the Body). Logs are broadcast, not typed.
  #
  # AT MOST ONE burst in flight: a burst takes ~1.2s on the osascript path (taps × gaps) while
  # the logic re-decides every ~300ms — spawning every decision stacked 3-4 concurrent key
  # scripts onto System Events (one OS queue), lagging EVERY key in the app seconds behind its
  # mouse move. Skipping is correct, not lossy FOR THE KEYS: the next decision re-reads the
  # world and fires a FRESHER burst than the one skipped. It IS lossy for what the Logic
  # latched while deciding, which is why the outcome travels back to it (Logic.dropped/2).
  defp dispatch(state, actions), do: state |> try_dispatch(actions) |> elem(0)

  defp try_dispatch(state, actions) do
    keys =
      Enum.flat_map(actions, fn
        {:tab} -> [Settings.get(:tab_key)]
        {:press, key} -> [key]
        {:log, _} -> []
      end)

    cond do
      keys == [] ->
        {state, :nothing}

      state.burst_pid != nil and Process.alive?(state.burst_pid) ->
        Perf.count("combat.burst_skipped")
        {state, :skipped}

      blackout?(keys) ->
        Perf.count("combat.revive_blackout")
        {state, :skipped}

      true ->
        parent = self()
        confirm? = Settings.get(:combat_confirm_skills) and state.retry_ok?

        # Is this burst worth measuring the AREA with? Only a cast that actually
        # contained an area key can say how far an area key reaches.
        area? = AreaProbe.on?() and area_key?(state.loadout, keys)

        {%{
           state
           | burst_pid: spawn(fn -> tap_keys(keys, parent, confirm?, area?) end),
             last_action: %{text: "teclas #{Enum.join(keys, "+")}", at: now()},
             retry_ok?: true
         }, :sent}
    end
  end

  # O POKÉMON NÃO ESTÁ EM CAMPO. O revive TIRA o pokémon e devolve — "esperando
  # Nms o bolo dormir, aí sim tiro o pokémon" — e enquanto ele está fora
  # nenhuma skill dele sai, com a barra mostrando tudo pronto do mesmo jeito
  # (o revive zerou os cooldowns de verdade).
  #
  # A noite de 29/08 mediu o buraco, e ele é grande: das teclas que a barra dava
  # como prontas e o jogo ignorou, 91% saíram no primeiro segundo depois de um
  # revive e 54% no segundo — contra ~20% de base no resto da caçada. Com 242
  # revives em 82 minutos, o bot passou a run inteira apertando dentro da
  # janela cega, e cada aperto ali custava três vezes: a tecla, os 500ms do
  # intervalo, e um `missed` que ainda comprava uma retentativa em cima.
  #
  # O Tab passa: mirar não é conjurar, e ele não tem cooldown pra gastar. O
  # resgate também não passa por aqui (ele fala direto com o `Body`), então
  # nada nesta trava atrasa um stun ou o próprio revive.
  # …contada do F4 QUE SAIU (`ReviveLedger.landed/0`), nunca do despacho do
  # combo: o despacho antecede o F4 pelo settle inteiro (1,5-2s), e uma janela
  # contada dele cobria o settle — quando o pokémon está em campo DE PROPÓSITO,
  # tanqueando e podendo bater — e descobria o 1º-2º segundo pós-F4, que é a
  # janela real. Medido em 30/08: 320 das 441 teclas engolidas da noite caíram
  # no primeiro segundo depois do F4, com a janela "ligada".
  defp blackout?(keys) do
    janela = Settings.get(:rescue_blackout_ms)

    janela > 0 and keys != [Settings.get(:tab_key)] and
      ReviveLedger.landed_within?(janela)
  end

  # Só com UMA tecla — uma rajada de três tira uma queda só e ninguém sabe de
  # quem foi, que é exatamente o modo que ele descreveu ("ele e um inimigo de
  # vida cheia, usa uma skill e calcula a diferença").
  defp measure_damage([only]) do
    if SkillMeter.on?(), do: spawn(fn -> SkillMeter.file(only) end)
    :ok
  end

  defp measure_damage(_rajada), do: :ok

  # A aura de dano só lidera a rajada quando está PRONTA — "usar a aura 2 quando
  # disponível" (26/08). A barra é lida do fato, sem captura nova, e uma leitura
  # velha responde "não", que é o lado barato de errar.
  defp aura_ready?(loadout), do: Loadout.aura_ready?(loadout, ready_skills(loadout))

  # `:ok` porque ela vive dentro do `with` da rajada: o carimbo é um passo da
  # sequência, não um efeito colateral pendurado nela.
  defp stamp_clock(keys, started_at, gap_ms) do
    keys
    |> Enum.with_index()
    |> Enum.each(fn {key, idx} -> SkillClock.pressed(key, started_at + idx * gap_ms) end)
  end

  defp area_key?(%Loadout{aoe: aoe}, keys), do: Enum.any?(keys, &(&1 in aoe))
  defp area_key?(_no_loadout, _keys), do: false

  defp tap_keys(keys, parent, confirm?, area?) do
    before = if confirm?, do: Perception.ready_skills()
    started_at = now()

    opts = [
      tap_count: Settings.get(:combat_skill_tap_count) |> positive_int(1),
      gap_ms: Settings.get(:combat_skill_gap_ms) |> non_neg_int(0),
      jitter_ms: Settings.get(:combat_skill_jitter_ms) |> non_neg_int(0)
    ]

    with :ok <- Perception.mini_game_gate(),
         # O RELÓGIO DAS TECLAS, CARIMBADO ANTES DA RAJADA SAIR.
         #
         # A rajada não passa pelo `Body` (ela vai direto no rig pra sair
         # inteira, sem ceder o corpo no meio), então o carimbo do portão não a
         # vê — e ela é a maior parte do que o bot aperta. Cada tecla leva o
         # instante em que ela VAI sair, não o do pedido: uma rajada de seis
         # com 500ms de intervalo leva dois segundos e meio pra terminar.
         #
         # E o carimbo vem ANTES da prensa por causa de quem lê o relógio no
         # meio dela. `press_many` só volta quando a ÚLTIMA tecla saiu, e o
         # `HandWatch` drena o teclado a cada 150ms: com o carimbo escrito
         # depois, ele via as teclas do próprio bot saindo, não achava carimbo
         # nenhum (o da volta anterior tinha 45s) e concluía "foi a mão dele" —
         # carimbando cooldown em cima de cooldown. Medido na noite dele de
         # 29/08: 7.703 linhas de "🖐️ tecla N da tua mão", na ordem exata da
         # rajada (3, 4, 5, 6, 7), e a barra inteira aparecendo em espera assim
         # que a caçada começava.
         #
         # O preço de carimbar cedo é conhecido e se conserta sozinho: se a
         # rajada falhar depois disto, sobram carimbos de teclas que não
         # saíram — e o `SkillTruth` os solta em ~1s, assim que a tela mostrar
         # a tecla pronta. O preço de carimbar tarde não se conserta: quem lê
         # no meio da rajada lê um relógio que ainda não existe.
         :ok <- stamp_clock(keys, started_at, opts[:gap_ms] || 0),
         {:sent, sent} <-
           keys
           |> Pokex.Rig.impl().press_many(opts ++ [halt?: tail_fence(keys)])
           |> burst_result(keys, parent),
         :ok <- Perception.mini_game_gate() do
      # The clock of the receipt is the LAST key, never the first. A burst of n
      # keys takes (n-1) x gap_ms to leave the hand (3,3s with his 500) while
      # the bar is published every `feed_skill_bar_ms`, so judging against the
      # REQUEST accepted a frame captured mid-burst — one where the tail had not
      # been pressed yet and was therefore still ready. Every such key came back
      # `missed` by construction, and each one bought a retry burst on top.
      at = now()

      # The receipt FIRST: it is the timing-critical half of a burst, and
      # nothing measured is worth delaying it by even a cast. Only for what
      # actually LEFT: reading a receipt for a key the fence held would call
      # it `missed` and buy a retry for a press that never happened.
      receipt = if sent == [], do: :ok, else: ask_for_receipt(sent, before, at, parent)

      # One typed line per BURST — the other half of "quantas teclas matam um
      # bicho". The vitals stream says when the list shrank; this says what was
      # spent to make it shrink, and the two together are the only way the
      # simulator's `mob_hp` vs damage ratio stops being a number I made up.
      # `elapsed_ms` is how long the keys took to LEAVE, and it is the number the
      # gap sweep is read against: the burst is also combat's only dispatch slot
      # (`burst_pid`), so every millisecond here is a decision not taken.
      if sent != [] do
        Pokex.Engine.Events.record(:press, %{
          keys: sent,
          n: length(sent) * opts[:tap_count],
          elapsed_ms: at - started_at
        })
      end

      # CALIBRATION MODE, and only then: one look at where the damage landed.
      # Spawned like the receipt and for the same reason — this process must die
      # now so the next decision is not skipped as "a burst still in flight".
      if area? and sent == keys, do: spawn(&AreaProbe.file/0)

      # E o OUTRO modo de checagem: quanto esta tecla tirou.
      measure_damage(sent)

      receipt
    else
      {:blocked, :mini_game_active} -> :ok
      {:error, reason} -> send(parent, {:key_burst_failed, reason})
    end
  catch
    kind, reason -> Logger.debug("combat key burst crashed: #{inspect({kind, reason})}")
  end

  # A cerca da cauda (ver `Pokex.Rig.Mac.walk_burst/3`): a MESMA janela que
  # barra a LARGADA de uma rajada depois do F4 (`blackout?/1`) patrulha as
  # teclas que ainda não saíram de uma rajada JÁ em voo. Uma rajada leva
  # (n-1) × gap pra sair da mão, e o revive corre num processo próprio: na
  # noite de 30/08 (4h17), 325 rajadas foram atravessadas por um F4 no meio e
  # 237 teclas aterrissaram DEPOIS dele — dentro da janela cega que o próprio
  # revive abre, quase sempre com a tela já vazia. Rajada só de Tab fica sem
  # cerca pelo mesmo motivo que fura o blackout: mirar não conjura nada.
  #
  # Os carimbos das teclas seguradas se consertam sozinhos como os de uma
  # rajada que falhou: o `SkillTruth` os solta em ~1s quando a tela mostra a
  # tecla pronta.
  defp tail_fence(keys) do
    janela = Settings.get(:rescue_blackout_ms)

    if is_integer(janela) and janela > 0 and keys != [Settings.get(:tab_key)] do
      fn -> ReviveLedger.landed_within?(janela) end
    end
  end

  defp burst_result(:ok, keys, _parent), do: {:sent, keys}

  defp burst_result({:halted, pressed}, keys, parent) do
    sent = Enum.uniq(pressed)
    Perf.count("combat.burst_yielded")
    send(parent, {:burst_yielded, sent, keys -- sent})
    {:sent, sent}
  end

  defp burst_result(error, _keys, _parent), do: error

  # The receipt is read in its OWN process: this one has to die now so the next
  # decision is not skipped as "a burst still in flight" — confirming must cost
  # accuracy, never damage.
  defp ask_for_receipt(_keys, nil, _at, _parent), do: :ok

  defp ask_for_receipt(keys, before, at, parent) do
    spawn(fn -> confirm_burst(keys, before, at, parent) end)
    :ok
  end

  # Did the keys actually go off? The cooldown is the receipt: a skill that
  # fired is no longer ready (Pokex.Bots.SkillReceipt). Tab is left out — it
  # has no cooldown to spend, so it has no receipt to read.
  #
  # "A gente tem que sempre estar garantindo que a skill que a gente validou
  # foi usada mesmo" (Lucas, 2026-08-11): hunting is not fishing, and a skill
  # that silently never left is damage he is not doing while a pile eats him.
  defp confirm_burst(keys, before, at, parent) do
    skills = keys -- [Settings.get(:tab_key)]
    later = Perception.ready_skills_after(at, Settings.get(:combat_confirm_ms))

    # Separate message, on purpose: the detector must never be able to change
    # whether a missed key gets pressed again. Diagnosis is a bonus; the retry
    # is the service.
    send(parent, {:skill_bar_seen, later, skills})

    check = SkillReceipt.check(before, later, skills)

    # …e o recibo vira NÚMERO, não só um aviso. Quanto tempo entre duas teclas o
    # jogo aceita é uma pergunta sobre o JOGO, e ele já responde: uma tecla que
    # saiu deixa de estar pronta. Sem isto, "35ms derruba tecla?" só podia ser
    # discutido — com isto, uma noite responde (Lucas, 26/08: "esse gap não pode
    # ser tão rápido").
    Pokex.Engine.Events.record(:receipt, %{
      keys: skills,
      fired: Map.get(check, :fired, []),
      missed: Map.get(check, :missed, []),
      unknown: Map.get(check, :unknown, []),
      gap_ms: Settings.get(:combat_skill_gap_ms),
      taps: Settings.get(:combat_skill_tap_count)
    })

    case SkillReceipt.verdict(check) do
      {:missed, missed} -> send(parent, {:skills_missed, missed})
      _confirmed_or_unknown -> :ok
    end
  catch
    kind, reason -> Logger.debug("combat receipt crashed: #{inspect({kind, reason})}")
  end

  defp mute_log([], _cooldowns), do: :ok

  defp mute_log(keys, cooldowns) do
    held =
      Enum.map_join(keys, ", ", fn key ->
        "#{key} (#{div(SkillClock.deaf_ms(key, cooldowns), 1_000)}s)"
      end)

    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      @topic,
      {:combat_log, :macro,
       "combate: 🔇 a barra diz que #{held} está pronta e o jogo não reage — " <>
         "segurando ela até o relógio devolver. Recalibre a barra com TUDO pronto."}
    )
  end

  # Said ONCE per key: a slot whose reference is inverted misses forever, and a
  # line repeated on every miss would bury itself.
  defp accuse(state) do
    state.suspects
    |> SkillSuspect.suspects()
    |> Enum.reject(&(&1 in state.accused))
    |> Enum.reduce(state, fn key, acc ->
      Phoenix.PubSub.broadcast(
        Pokex.PubSub,
        @topic,
        {:combat_log, :macro,
         "combate: ⚠️ " <> SkillSuspect.explain(key, acc.suspects[key].missed)}
      )

      %{acc | accused: [key | acc.accused]}
    end)
  end

  # The freshest battle picture, or nil (stale/missing → Logic acts time-only, fail-safe).
  # The stale counter matters: on a static battle list the poll is combat's ONLY driver (no
  # content change → no broadcast), so a stretch of stale polls means combat is flying blind —
  # exactly the "killed the first, never Tabbed the next" wedge. Watch combat.poll_stale in the
  # perf dump next to the capture queue times.
  defp current_obs do
    case WorldState.get(:battle, Settings.get(:combat_world_max_age_ms), now()) do
      {:ok, obs} ->
        obs

      _stale_or_missing ->
        Perf.count("combat.poll_stale")
        nil
    end
  end

  # The feed's consumers map (and this worker's monitor of it) dies with the feed process —
  # a restart starts fresh with nobody attached. Reattach on a short retry loop until the
  # feed is back up (or logic goes idle/error, or we've retried enough that it's clearly not
  # coming back). try/catch: `Perception.attach/1` exits if the feed isn't registered yet.
  defp reattach_battle(%{reattach_attempts: attempts} = state) when attempts >= 20, do: state

  defp reattach_battle(state) do
    Perception.attach(:battle)
    ref = Process.monitor(Feed.name(:battle))
    %{state | feed_ref: ref, reattach_attempts: 0}
  catch
    :exit, _ ->
      Process.send_after(self(), :reattach_battle, 250)
      %{state | reattach_attempts: state.reattach_attempts + 1}
  end

  defp demonitor_feed(nil), do: :ok
  defp demonitor_feed(ref), do: Process.demonitor(ref, [:flush])

  # A dead/restarting feed must never crash the halt path (the Guardian panic fan-out runs
  # through it).
  defp safe_detach(key) do
    Perception.detach(key)
  catch
    :exit, _ -> :ok
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

  # -- broadcasts ---------------------------------------------------------------

  defp shown([]), do: "nenhuma"
  defp shown(keys), do: Enum.join(keys, "+")

  defp broadcast(logic, state),
    do: Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:combat, snapshot(logic, state)})

  defp broadcast_kill,
    do:
      Phoenix.PubSub.broadcast(
        Pokex.PubSub,
        Worker.kill_topic(),
        {:kill}
      )

  # :macro (surfaced to Lucas) for the moments that matter: the step just landed a fight,
  # counters moved (a kill/loot/capture/failure), or the log itself flags a timeout. Anything
  # else — routine hunting/tabbing chatter — stays at :debug. (Previously ANY log after the
  # first kill of the run stayed :macro forever, which drowned the useful signal in noise.)
  defp broadcast_activity(previous, logic, actions) do
    texts = for {:log, msg} <- actions, do: msg

    if texts != [] do
      became_fighting? = logic.state == :fighting and previous.state != :fighting
      counters_changed? = logic.counters != previous.counters
      mentions_timeout? = Enum.any?(texts, &String.contains?(&1, "timeout"))

      level =
        if became_fighting? or counters_changed? or mentions_timeout?, do: :macro, else: :debug

      Enum.each(texts, fn text ->
        Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:combat_log, level, "combate: #{text}"})
      end)
    end
  end

  defp snapshot(nil, state),
    do: %{
      state: :idle,
      counters: %Logic{}.counters,
      error: nil,
      locked_row: nil,
      scenery: 0,
      hold_reason: nil,
      last_action: state.last_action,
      loadout: state.loadout_view
    }

  # `scenery` is how many battle rows this worker has GIVEN UP on — the rows it
  # tabbed at and never locked (his own pokémon in the list, an unreachable mob
  # behind a wall). It was private knowledge that only shaped Tab; the HUNT
  # needs it too, or it yields the road to a row nobody will ever fight.
  defp snapshot(logic, state),
    do: %{
      state: logic.state,
      counters: logic.counters,
      error: logic.error,
      locked_row: logic.locked_row,
      scenery: logic.scenery_rows || 0,
      hold_reason: hold_reason(logic, state),
      last_action: state.last_action,
      loadout: state.loadout_view
    }

  # WHO the running fight thinks it is fighting as, and what that decides. The
  # profile lives on /time and the pages that show it were showing the CONFIG —
  # "não vejo na prática se realmente isso tá impactando" (Lucas, 2026-08-12).
  # This is the fight's own answer, so a page can show what is happening instead
  # of what was configured.
  defp put_loadout(state, loadout),
    do: %{state | loadout: loadout, loadout_view: loadout_view(loadout)}

  defp loadout_view(nil), do: nil

  defp loadout_view(loadout),
    do: %{
      name: loadout.name,
      opening: Strategy.opening(loadout),
      reserved: Strategy.reserved(loadout),
      buffs: loadout.buffs,
      heal: loadout.heal,
      # As duas que faltavam pra uma página desenhar a BARRA em vez da rotação:
      # as de alvo único existem na barra dele mesmo fora da rotação, e sem os
      # cooldowns escritos não há contagem regressiva pra mostrar.
      single: loadout.single,
      # `reserved` junta controle E escudo (é a lista de EXCLUSÃO da rotação),
      # e uma tela de diagnóstico que chama o escudo de controle mente sobre a
      # coisa exata que ela existe pra mostrar.
      shield: loadout.shield,
      cooldowns: loadout.cooldowns
    }

  # Why combat is quiet, in the ONE slot the panel already reads. A silent
  # combat with a full battle list is the most alarming thing this bot can
  # show; holding fire on purpose must never look like that.
  defp hold_reason(_logic, %{held?: true}), do: "mini-game em jogo"
  defp hold_reason(%Logic{posture: :hold_fire}, _state), do: "segurando o fogo (trecho de mob)"
  defp hold_reason(_logic, _state), do: nil

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, default), do: default

  defp non_neg_int(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_neg_int(_value, default), do: default

  defp now, do: System.monotonic_time(:millisecond)
end
