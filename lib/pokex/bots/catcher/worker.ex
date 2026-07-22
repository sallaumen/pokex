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

  alias Pokex.Bots.Body
  alias Pokex.Bots.Catcher.Logic
  alias Pokex.Perception
  alias Pokex.Perception.{Feed, WorldState}
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
    body = Keyword.get(opts, :body, Body)

    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, body)
      name -> GenServer.start_link(__MODULE__, body, name: name)
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
  def init(body) do
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
       timer: nil,
       attached?: false,
       combat_engaged?: false,
       feed_ref: nil,
       reattach_attempts: 0,
       loots: 0,
       # a shiny was just seen: the NEXT ball ignores capture_enabled
       shiny_pending?: false,
       # last performed actuation as %{text, at} (monotonic ms; nil until the first) — panel-facing
       last_action: nil
     }}
  end

  @impl true
  def handle_call(:run, _from, state) do
    {logic, _} = Logic.start(Logic.new(config()), now())
    state = %{state | logic: logic, loots: 0, combat_engaged?: seed_combat_engaged()}
    state = sync_mode(state)
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
    do: {:noreply, advance(state, current_obs())}

  def handle_info(:wake, state), do: {:noreply, state}

  # kill = accelerator (both shapes: Task 5 drops the payload; tolerate the old one meanwhile).
  # loot_kill runs BEFORE advance: the Space presses must land ahead of any ball this cycle.
  def handle_info({:kill}, %{logic: %Logic{state: :armed}} = state) do
    state = loot_kill(state)
    {:noreply, advance(state, current_obs())}
  end

  def handle_info({:kill, _corpse}, %{logic: %Logic{state: :armed}} = state) do
    state = loot_kill(state)
    {:noreply, advance(state, current_obs())}
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
        state |> maybe_attach_after_disengage() |> advance(current_obs())
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
    cond do
      Perception.mini_game_playing?() -> state
      Settings.get(:player_mode) == "parado" -> do_advance(state, obs)
      true -> state
    end
  end

  # A fight is on: everything reaching here is contaminated by the live enemy sprite
  # (tile-locked, stands still — indistinguishable from a corpse). No admissions, no throws,
  # no confirms until combat disengages (see the {:combat,...} handler above).
  defp do_advance(%{combat_engaged?: true} = state, _obs), do: state

  # Capture disabled (loot-only operation): the ball pipeline never steps — no admissions,
  # no throws, no confirms. The feed is also detached (see should_be_attached?/1); this
  # gate only catches stragglers (a late event right after the toggle flip).
  defp do_advance(state, obs) do
    if capture_allowed?(state), do: run_step(state, obs), else: state
  end

  defp run_step(state, obs) do
    {logic, actions} = Logic.step(state.logic, obs, now())

    performs = Enum.filter(actions, &match?({:capture_sequence, _}, &1))
    if performs != [], do: Body.perform(performs, :high, state.body)

    state =
      if performs != [] do
        # a ball that flew because a SHINY was seen closes that log entry
        if state.shiny_pending?, do: Pokex.Pokedex.ShinyLog.resolve_last("bola")

        %{
          state
          | last_action: %{text: "bola arremessada", at: now()},
            shiny_pending?: false
        }
      else
        state
      end

    for {:log, text} <- actions do
      Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:catcher_log, :macro, "captura: #{text}"})
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

  defp current_obs do
    case WorldState.get(:corpses, Settings.get(:catcher_world_max_age_ms), now()) do
      {:ok, obs} -> obs
      _stale_or_missing -> nil
    end
  end

  # parado + running → attached; movimento or halted → detached. Never attaches mid-fight (see
  # should_be_attached?/1) — a mid-fight attach would warm the baseline up on the live enemy
  # sprite and mask the melee tile forever.
  defp sync_mode(state) do
    if should_be_attached?(state), do: attach(state), else: cancel_timer(detach(state))
  end

  defp armed_parado?(state),
    do: Settings.get(:player_mode) == "parado" and match?(%Logic{state: :armed}, state.logic)

  defp should_be_attached?(state),
    do: armed_parado?(state) and not state.combat_engaged? and capture_allowed?(state)

  defp maybe_attach_after_disengage(state) do
    if should_be_attached?(state) and not state.attached?, do: attach(state), else: state
  end

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
        |> Map.put(:loots, state.loots),
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
      Perception.mini_game_playing?() -> "mini-game em jogo"
      state.combat_engaged? -> "esperando fim da luta"
      true -> nil
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
