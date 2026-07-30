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

  alias Pokex.Bots.Combat.Logic
  alias Pokex.Perception
  alias Pokex.Perception.{Feed, WorldState}
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
    :hunt_probe_window_ms,
    :skill_burst_every_ms,
    :fight_timeout_ms,
    :target_lost_streak,
    :skill_keys,
    :combat_skill_burst_size,
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

  def run(server \\ __MODULE__), do: GenServer.call(server, :run)
  def halt(server \\ __MODULE__), do: GenServer.call(server, :halt)
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(:ok) do
    Phoenix.PubSub.subscribe(Pokex.PubSub, @catch_topic)
    Phoenix.PubSub.subscribe(Pokex.PubSub, Perception.topic())

    {:ok,
     %{
       logic: nil,
       timer: nil,
       feed_ref: nil,
       reattach_attempts: 0,
       held?: false,
       # the ONE in-flight key burst (nil when none): a new burst is SKIPPED while the previous
       # is still landing, instead of piling concurrent osascripts onto System Events
       burst_pid: nil,
       # last dispatched burst as %{text, at} (monotonic ms; nil until the first) — panel-facing
       last_action: nil
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
        # A double :run (two Start presses) must not leak the previous feed monitor.
        demonitor_feed(state.feed_ref)
        ref = Process.monitor(Feed.name(:battle))

        state = %{
          state
          | logic: logic,
            feed_ref: ref,
            reattach_attempts: 0,
            held?: false,
            last_action: nil
        }

        broadcast(logic, state)
        # step immediately against whatever the world already knows
        {:reply, :ok, advance(state, current_obs())}

      {:error, messages} when is_list(messages) ->
        {:reply, {:error, messages}, state}

      {:error, other} ->
        {:reply, {:error, [inspect(other)]}, state}
    end
  end

  def handle_call(:halt, _from, %{logic: nil} = state), do: {:reply, :ok, state}

  def handle_call(:halt, _from, state) do
    {logic, _} = Logic.stop(state.logic)
    safe_detach(:battle)
    safe_detach(:skill_bar)
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

  # A key burst failed on its async task (see `dispatch/1`/`tap_keys/2`). Ignore it while
  # halted/errored — same invariant as the world/wake paths above — so a stale failure from
  # a task that outlived a `halt` can't silently reactivate the machine.
  def handle_info({:key_burst_failed, _reason}, %{logic: %Logic{state: s}} = state)
      when s in [:idle, :error],
      do: {:noreply, state}

  def handle_info({:key_burst_failed, reason}, %{logic: %Logic{}} = state) do
    {logic, actions} = Logic.io_failed(state.logic, inspect(reason), now())
    {:noreply, apply_step(state, logic, actions)}
  end

  def handle_info({:key_burst_failed, _reason}, state), do: {:noreply, state}

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
    {logic, actions} = Logic.step(state.logic, with_ready_skills(obs), now())
    apply_step(state, logic, actions)
  end

  # The freshest skill-bar reading rides along on every observation the logic sees, so the
  # burst it decides fires only READY skills. nil obs stays nil (a timer wake without a
  # frame must not become a fake observation), and a missing/stale/unreadable fact merges
  # as nil → Logic blind-rotates (fail-open; see Logic.press_next_skill).
  defp with_ready_skills(nil), do: nil
  defp with_ready_skills(obs), do: Map.put(obs, :ready_skills, Perception.ready_skills())

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

    state = dispatch(state, actions)
    broadcast_activity(previous, logic, actions)

    # KILL first, snapshot second: the Catcher loots on {:kill} (Space presses) and throws the
    # ball on the disengage snapshot's advance — the ball consumes the corpse WITH its loot, so
    # this producer-side order IS the loot-before-ball guarantee (same sender → same receiver
    # preserves it).
    if logic.counters.fights > previous.counters.fights,
      do: broadcast_kill()

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
  # mouse move. Skipping is correct, not lossy: the next decision re-reads the world and fires
  # a FRESHER burst than the one skipped.
  defp dispatch(state, actions) do
    keys =
      Enum.flat_map(actions, fn
        {:tab} -> [Settings.get(:tab_key)]
        {:press, key} -> [key]
        {:log, _} -> []
      end)

    cond do
      keys == [] ->
        state

      state.burst_pid != nil and Process.alive?(state.burst_pid) ->
        Pokex.Bots.Perf.count("combat.burst_skipped")
        state

      true ->
        parent = self()

        %{
          state
          | burst_pid: spawn(fn -> tap_keys(keys, parent) end),
            last_action: %{text: "teclas #{Enum.join(keys, "+")}", at: now()}
        }
    end
  end

  defp tap_keys(keys, parent) do
    opts = [
      tap_count: Settings.get(:combat_skill_tap_count) |> positive_int(1),
      gap_ms: Settings.get(:combat_skill_gap_ms) |> non_neg_int(0),
      jitter_ms: Settings.get(:combat_skill_jitter_ms) |> non_neg_int(0)
    ]

    with :ok <- Perception.mini_game_gate(),
         :ok <- Pokex.Rig.impl().press_many(keys, opts),
         :ok <- Perception.mini_game_gate() do
      :ok
    else
      {:blocked, :mini_game_active} -> :ok
      {:error, reason} -> send(parent, {:key_burst_failed, reason})
    end
  catch
    kind, reason -> Logger.debug("combat key burst crashed: #{inspect({kind, reason})}")
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
        Pokex.Bots.Perf.count("combat.poll_stale")
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

  defp broadcast(logic, state),
    do: Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:combat, snapshot(logic, state)})

  defp broadcast_kill,
    do:
      Phoenix.PubSub.broadcast(
        Pokex.PubSub,
        Pokex.Bots.Catcher.Worker.kill_topic(),
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
      hold_reason: nil,
      last_action: state.last_action
    }

  defp snapshot(logic, state),
    do: %{
      state: logic.state,
      counters: logic.counters,
      error: logic.error,
      locked_row: logic.locked_row,
      hold_reason: if(state.held?, do: "mini-game em jogo"),
      last_action: state.last_action
    }

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, default), do: default

  defp non_neg_int(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_neg_int(_value, default), do: default

  defp now, do: System.monotonic_time(:millisecond)
end
