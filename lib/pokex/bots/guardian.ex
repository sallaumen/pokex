defmodule Pokex.Bots.Guardian do
  @moduledoc """
  The single owner of the panic corner. Polls `Body.cursor/1` on a timer
  (bypasses the input queue — safe to poll live) and, the instant the cursor
  sits in `Pokex.Bots.Corner`'s top-left kill corner, halts EVERYTHING at
  once via `on_panic` and broadcasts `{:panic, "kill corner"}` on both the
  "fishing" and "combat" PubSub topics.

  ALSO the watchdog for the session STOP CONDITIONS (hunt goals) and the
  ANTI-STAGNATION rule: the same poll checks the `:session` fact against
  `stop_after_minutes` / `stop_after_kills`, and against
  `stagnation_minutes` of silence, whose action is an `{:rule_alarm, _}`
  broadcast (re-armed per window), the same full stop, or a LOGOUT. A hit
  halts the fleet through the SAME latch + on_panic path as the corner — a
  reached goal is a standing order to stay stopped until the human presses
  Iniciar — but broadcasts `{:session_stop, reason}` instead of
  `{:panic, _}`, so the panel reports a met goal, not an emergency. Being
  external to every worker, the stop can never deadlock on a worker halting
  itself; and since `on_panic` (stop_all) forgets the `:session` fact, a
  fired condition cannot re-fire.

  ## What counts as a sign of life

  Kill + WON MINI-GAME. **Not** a hook: a hook is the rod pull, and with the
  mini-game stuck the rod hooks all night catching no fish — the counter
  climbs, the clock resets, and the rule sleeps while stamina burns (exactly
  how a whole night on the main account was lost). Hooks count again only
  while the mini-game watcher is stopped (mini-game played by hand), otherwise
  the rule would fire mid-fishing that was going fine. The three counters ride
  the snapshots combat, fishing and mini-game already publish; this process
  subscribes to all three.

  Logging out is the action that actually saves stamina: stopping the bot
  saves nothing, the character stays online. `Pokex.Bots.Logout` (injectable
  via `:logout_fun`) sets the latch and halts the fleet on its own — neither
  is duplicated here.

  `on_panic` is injected (not a hard dependency on the bot supervisor) so
  this module doesn't need to know about `BotSupervisor` — callers pass e.g.
  `&BotSupervisor.stop_all/0`.

  Design note: `on_panic` fires on EVERY poll tick that finds the cursor in
  the corner, not just on the first entry. A human parked in the corner
  wants the bot to stay stopped, and re-invoking a stop is harmless as long
  as `on_panic` is idempotent (stopping already-stopped workers is a no-op)
  — which is simpler and safer than tracking "fresh entry" edge state that
  could itself have a bug that lets a second panic slip through unhandled.

  The poll loop must never crash on a bad cursor read: an `{:error, _}`
  reply (or any other unexpected shape) just reschedules the next poll.

  The poll loop itself is gated by `:guardian_auto_poll` (false in test): it
  reads the cursor through the shared Rig, which in the suite is the same
  `Rig.Fake` other tests assert on. Test Guardians opt in with `auto_poll: true`.

  Bound on the panic guarantee: panic is delivered promptly but is bounded
  by whatever `Body` action is currently in flight — a worker blocked
  mid-action is halted once that action returns (actions are short: one
  osascript/cliclick).
  """
  use GenServer
  require Logger

  alias Pokex.Bots.Body
  alias Pokex.Bots.BotSupervisor
  alias Pokex.Bots.Corner
  alias Pokex.Bots.InputGate
  alias Pokex.Bots.Logout
  alias Pokex.Bots.MiniGame.Worker
  alias Pokex.Perception.WorldState
  alias Pokex.Settings

  @fishing_topic "fishing"
  @combat_topic "combat"

  # same practically-forever max age the :calibration/:session stamps use
  @session_max_age_ms 4_000_000_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    on_panic = Keyword.fetch!(opts, :on_panic)
    body = Keyword.get(opts, :body, Body)
    poll_ms = Keyword.get(opts, :poll_ms, 100)

    # Same pattern as :player_support_auto_monitor: the env flag turns the
    # session rules OFF for the app-global instance in the test env, so a test
    # planting a :session fact + global limits never wakes the real Guardian
    # (its real stop_all would race the test's own scoped Guardian — measured
    # flaky). Test Guardians opt back in via the option.
    session_rules? =
      Keyword.get(
        opts,
        :session_rules,
        Application.get_env(:pokex, :guardian_session_rules, true)
      )

    # Same contract as :focus_auto_monitor and :sweep_auto_tick: an app-global
    # loop that reaches the Rig is OFF in the suite. This one reads the cursor
    # through the SHARED Rig.Fake every 100ms, so every test that asserts
    # "nothing reached the Rig" was racing it — six files carried an
    # `Enum.reject({:cursor_position})` workaround and the one that didn't was
    # the ~1-in-3 flake. Test Guardians opt back in with `auto_poll: true`.
    auto_poll? =
      Keyword.get(
        opts,
        :auto_poll,
        Application.get_env(:pokex, :guardian_auto_poll, true)
      )

    state = %{
      on_panic: on_panic,
      body: body,
      poll_ms: poll_ms,
      auto_poll?: auto_poll?,
      session_rules?: session_rules?,
      logout_fun: Keyword.get(opts, :logout_fun, &Logout.request/1),
      # COMMAND corner (top-right): injectable deps so tests never start the
      # real fleet nor read real calibration
      command_toggle: Keyword.get(opts, :command_toggle, &__MODULE__.default_command_toggle/0),
      screen_w_fun: Keyword.get(opts, :screen_w_fun, &__MODULE__.default_screen_w/0),
      # when the cursor ENTERED the command corner (nil = outside) and whether
      # this visit's command already fired — LEAVING the corner re-arms
      command_since: nil,
      command_fired?: false,
      fights: 0,
      hooked: 0,
      clears: 0,
      # is the mini-game watcher running? Until heard from, assume NOT — the
      # safe default, since its absence is what makes hooks count as signs of
      # life again.
      mini_game_running?: false,
      # last time a REAL sign of life was SEEN (monotonic ms; nil = none
      # yet this run) — the anti-stagnation rule measures silence from here
      last_activity_at: nil
    }

    case name do
      nil -> GenServer.start_link(__MODULE__, state)
      name -> GenServer.start_link(__MODULE__, state, name: name)
    end
  end

  @impl true
  def init(state) do
    # kills (stop condition + stagnation) and hooked fish (stagnation) ride
    # the snapshots the workers already broadcast
    Phoenix.PubSub.subscribe(Pokex.PubSub, @combat_topic)
    Phoenix.PubSub.subscribe(Pokex.PubSub, @fishing_topic)
    # the REAL fish (won mini-game) and whether the watcher is up
    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    if state.auto_poll?, do: schedule_poll(state.poll_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    state =
      case Body.cursor(state.body) do
        {:ok, point} ->
          in_corner? = Corner.in_kill_corner?(point)
          # The gate closes the moment the cursor enters the corner, so it ALSO suppresses the
          # always-on PlayerSupport's revive/potion — not just the Start/Stop workers on_panic
          # halts. It reopens when the cursor leaves, so manual-play protection comes right back.
          InputGate.set_corner_ok(not in_corner?)
          if in_corner?, do: panic(state)

          check_command_corner(state, point)

        _error ->
          state
      end

    state = check_session_limits(state)
    schedule_poll(state.poll_ms)
    {:noreply, state}
  end

  def handle_info({:combat, snapshot}, state),
    do: {:noreply, track_counter(state, :fights, get_in(snapshot, [:counters, :fights]))}

  # A HOOK is the rod pull, not the fish. With the mini-game watcher running,
  # the real fish is `clears`: a stuck mini-game hooks all night catching
  # nothing — exactly how a night of stamina was lost. With the watcher off
  # (mini-game played by hand) the hook is again the best signal we have;
  # without that fallback the rule would log out mid-fishing that was fine.
  def handle_info({:fishing, snapshot}, state) do
    hooked = get_in(snapshot, [:counters, :hooked])

    if state.mini_game_running?,
      do: {:noreply, store_counter(state, :hooked, hooked)},
      else: {:noreply, track_counter(state, :hooked, hooked)}
  end

  def handle_info({:mini_game, snapshot}, state) do
    state = %{state | mini_game_running?: Map.get(snapshot, :state) != :off}
    {:noreply, track_counter(state, :clears, get_in(snapshot, [:counters, :clears]))}
  end

  # the subscribed topics also carry {:*_log, ...} / {:panic, ...} chatter — not ours
  def handle_info(_msg, state), do: {:noreply, state}

  # A counter INCREASE is activity; a decrease is the run-start reset (workers
  # zero their counters on run) — store it silently so the next real kill/hook
  # still reads as an increase.
  defp track_counter(state, key, value) do
    cond do
      not is_integer(value) ->
        state

      value > Map.fetch!(state, key) ->
        state
        |> Map.put(key, value)
        |> Map.put(:last_activity_at, System.monotonic_time(:millisecond))

      true ->
        Map.put(state, key, value)
    end
  end

  # Stores the counter WITHOUT marking activity. Exists so turning the
  # mini-game watcher off mid-session doesn't pass the accumulated hook jump
  # off as a sign of life that never happened.
  defp store_counter(state, key, value) when is_integer(value), do: Map.put(state, key, value)
  defp store_counter(state, _key, _value), do: state

  defp panic(state) do
    # LATCH FIRST, halt second: the latch is what forbids every auto-resume path (the Focus
    # poller's refocus resume) from restarting workers over this human order — set it before
    # anything else so no resume can slip in between. Only Iniciar bot clears it.
    InputGate.set_panic_latch(true)
    stop_fleet(state)
    Phoenix.PubSub.broadcast(Pokex.PubSub, @fishing_topic, {:panic, "kill corner"})
    Phoenix.PubSub.broadcast(Pokex.PubSub, @combat_topic, {:panic, "kill corner"})
  end

  # This process is the LAST thing standing, so stopping the fleet must never be
  # able to take it down with it. On 2026-08-11 a worker parked on a capture did
  # not answer its `:halt` inside the default 5s, the call exited, and this
  # Guardian died mid-panic: everything below the slow worker stayed running and
  # nobody was watching the corner any more. `BotSupervisor.safe_halt/1` bounds
  # that wait now — this is the belt under it, so whatever `on_panic` grows into
  # (or is injected as) can never again cost the corner.
  defp stop_fleet(state) do
    state.on_panic.()
  catch
    kind, reason ->
      Logger.error(
        "Guardian: a parada do pânico falhou (#{inspect({kind, reason})}) — " <>
          "a trava está armada e o canto segue vigiado"
      )
  end

  # The COMMAND corner (top-right): holding the mouse there for
  # command_corner_dwell_ms toggles the last used mode — from INSIDE the game.
  # Exists because clicking Iniciar in the browser STEALS the game's focus and
  # the (correctly fail-closed) gate swallowed the fleet's first steps — the
  # real 2026-07-29 regression. Moving the mouse changes no focus.
  #
  # Three anti-accident layers: the DWELL (passing through doesn't fire), the
  # RE-ARM (must LEAVE the corner before another command) and the corner
  # OPPOSITE to panic (never confused — panic stays instant and sovereign).
  defp check_command_corner(state, point) do
    enabled? = Settings.get(:command_corner) == true
    screen_w = state.screen_w_fun.()

    cond do
      not enabled? or screen_w == nil ->
        %{state | command_since: nil, command_fired?: false}

      # The mouse belongs to the MACHINE, not to a VM: every live Pokex polls the same cursor
      # and each obeys the same dwell on its own. That is precisely how a second server, opened
      # only to review the UI, started fishing on 2026-08-12 with nobody clicking Iniciar. The
      # human giving this order is talking to whichever VM commands the Mac; the observers stay
      # quiet rather than announcing a toggle they would only be refused for.
      # (The PANIC corner, deliberately, is not filtered: "stop" is safe from anyone.)
      not InputGate.owner_ok?() ->
        %{state | command_since: nil, command_fired?: false}

      not Corner.in_command_corner?(point, screen_w) ->
        %{state | command_since: nil, command_fired?: false}

      state.command_fired? ->
        state

      state.command_since == nil ->
        %{state | command_since: System.monotonic_time(:millisecond)}

      System.monotonic_time(:millisecond) - state.command_since >=
          Settings.get(:command_corner_dwell_ms) ->
        state.command_toggle.()
        %{state | command_fired?: true}

      true ->
        state
    end
  end

  @doc false
  # Starts if everything is stopped; stops if anything runs. The start goes in
  # a Task because preflight captures take seconds and the panic-corner poll
  # must NEVER go deaf waiting — the Logout lesson.
  def default_command_toggle do
    status = BotSupervisor.status()

    if BotSupervisor.any_active?([
         status.fishing,
         status.combat,
         status.cavebot,
         status.mini_game
       ]) do
      Phoenix.PubSub.broadcast(
        Pokex.PubSub,
        @combat_topic,
        {:rule_alarm, :command, "🕹️ canto de comando: parando o bot"}
      )

      BotSupervisor.stop_all("canto de comando")
    else
      Phoenix.PubSub.broadcast(
        Pokex.PubSub,
        @combat_topic,
        {:rule_alarm, :command, "🕹️ canto de comando: ligando o modo #{Pokex.Modes.current()}"}
      )

      # The Task stays — the corner poll must never block on preflight captures.
      # A REFUSED start is announced by BotSupervisor itself, so throwing this
      # return away can no longer make the fleet fail in silence.
      {:ok, _pid} = Task.start(fn -> BotSupervisor.start_all() end)
      :ok
    end
  end

  @doc false
  # Screen width comes from the calibration (the panic corner needs none —
  # {0,0} is universal; the opposite corner isn't). No calibration → corner off.
  def default_screen_w do
    case Pokex.Calibration.load() do
      {:ok, calib} -> Map.get(calib, :screen_w)
      _no_calibration -> nil
    end
  end

  # No running session (no fact) = nothing to measure; 0 = condition off.
  # A fired stop halts the fleet, which forgets :session — self-disarming.
  defp check_session_limits(%{session_rules?: false} = state), do: state

  defp check_session_limits(state) do
    now = System.monotonic_time(:millisecond)

    case WorldState.get(:session, @session_max_age_ms, now) do
      {:ok, %{started_at: started_at}} ->
        check_goals(state, started_at, now)

      _no_session ->
        state
    end
  end

  # A met goal ENDS the session. "stop" locks everything as usual; "logout"
  # ends the account session, which is what actually saves stamina — a stopped
  # bot saves nothing, the character stays online burning. Logout sets the
  # latch and halts the fleet on its own; neither is duplicated here.
  defp session_end(state, reason) do
    case Settings.get(:stop_after_action) do
      "logout" ->
        Logger.info("Guardian: #{reason} — deslogando")
        state.logout_fun.(reason)

      _parar ->
        session_stop(state, reason)
    end
  end

  # The anti-stagnation rule: silence (no kill, no won mini-game) measured from
  # the LATER of session start / last activity / last ring — so the alarm
  # action re-rings only after ANOTHER full silent window (its own cooldown),
  # and a fresh session never inherits old silence.
  # A goal that fires ends the session; otherwise stagnation gets its turn.
  defp check_goals(state, started_at, now) do
    minutes = Settings.get(:stop_after_minutes)
    kills = Settings.get(:stop_after_kills)

    cond do
      time_is_up?(minutes, started_at, now) ->
        session_end(state, "tempo de caçada atingido (#{minutes}min)")
        state

      kills_reached?(kills, state.fights) ->
        session_end(state, "meta de kills atingida (#{state.fights}/#{kills})")
        state

      true ->
        check_stagnation(state, started_at, now)
    end
  end

  defp time_is_up?(minutes, started_at, now),
    do: is_integer(minutes) and minutes > 0 and now - started_at >= minutes * 60_000

  defp kills_reached?(kills, fights), do: is_integer(kills) and kills > 0 and fights >= kills

  defp check_stagnation(state, started_at, now) do
    minutes = Settings.get(:stagnation_minutes)
    baseline = max(state.last_activity_at || started_at, started_at)

    if is_integer(minutes) and minutes > 0 and now - baseline >= minutes * 60_000 do
      reason = "estagnação: sem kills nem peixes há #{minutes}min"

      case Settings.get(:stagnation_action) do
        "stop" ->
          session_stop(state, reason)
          state

        "logout" ->
          Logger.info("Guardian: #{reason} — deslogando")
          state.logout_fun.(reason)
          state

        _alarm ->
          Logger.info("Guardian: #{reason}")
          Phoenix.PubSub.broadcast(Pokex.PubSub, @combat_topic, {:rule_alarm, :session, reason})
          %{state | last_activity_at: now}
      end
    else
      state
    end
  end

  defp session_stop(state, reason) do
    Logger.info("Guardian: parada por condição — #{reason}")
    # same order as panic: latch first, halt second — nothing may auto-resume
    # a finished hunt; only Iniciar clears it.
    InputGate.set_panic_latch(true)
    state.on_panic.()
    Phoenix.PubSub.broadcast(Pokex.PubSub, @combat_topic, {:session_stop, reason})
  end

  defp schedule_poll(poll_ms), do: Process.send_after(self(), :poll, poll_ms)
end
