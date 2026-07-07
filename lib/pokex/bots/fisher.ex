defmodule Pokex.Bots.Fisher do
  @moduledoc """
  Driver GenServer around the pure Logic: gathers observations, executes
  actions through the Rig, schedules ticks, broadcasts snapshots on PubSub.
  """
  use GenServer
  require Logger

  alias Pokex.Bots.Fisher.{Config, Logic, Sensors}
  alias Pokex.{Calibration, Preflight, Rig, Settings}

  @topic "fisher"

  def topic, do: @topic

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def start_bot(server \\ __MODULE__), do: GenServer.call(server, :start_bot)
  def start_combat(server \\ __MODULE__), do: GenServer.call(server, :start_combat)
  def stop_bot(server \\ __MODULE__), do: GenServer.call(server, :stop_bot)
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(_opts), do: {:ok, %{logic: nil, calib: nil, timer: nil}}

  @impl true
  def handle_call(:start_bot, _from, state), do: begin(state, &Logic.start/2)
  def handle_call(:start_combat, _from, state), do: begin(state, &Logic.start_combat/2)

  def handle_call(:stop_bot, _from, %{logic: nil} = state), do: {:reply, :ok, state}

  def handle_call(:stop_bot, _from, state) do
    {logic, _actions} = Logic.stop(state.logic)
    broadcast(logic)
    {:reply, :ok, %{cancel_timer(state) | logic: logic}}
  end

  def handle_call(:status, _from, state), do: {:reply, snapshot(state.logic), state}

  # Shared preflight → load → build → start; differs only by the Logic starter.
  defp begin(state, start_fun) do
    with :ok <- Preflight.run(),
         {:ok, calib} <- Calibration.load() do
      config = Config.build(calib, Settings.all())
      {logic, actions} = start_fun.(Logic.new(config), now())
      execute_all(actions, {0, config.humanize_max_ms})
      broadcast(logic)
      {:reply, :ok, %{state | logic: logic, calib: calib} |> reschedule(0)}
    else
      {:error, messages} when is_list(messages) -> {:reply, {:error, messages}, state}
      {:error, other} -> {:reply, {:error, ["calibração ilegível: #{inspect(other)}"]}, state}
    end
  end

  @impl true
  def handle_info(:tick, %{logic: nil} = state), do: {:noreply, state}

  def handle_info(:tick, %{logic: %Logic{state: s}} = state) when s in [:idle, :error],
    do: {:noreply, state}

  def handle_info(:tick, state) do
    previous = state.logic

    # In a post-action pause there's nothing to SENSE — no screen capture. But the
    # panic corner must stay live: a screencapture-free cursor read still runs so
    # mouse-to-corner stops the bot during the long waits (settle, assess, capture)
    # — exactly when the user is most likely to grab the mouse.
    if Logic.waiting?(previous, now()) do
      wait_tick(state, previous)
    else
      run_tick(state, previous)
    end
  end

  defp wait_tick(state, previous) do
    case Rig.impl().cursor_position() do
      {:ok, cursor} ->
        if Logic.in_kill_corner?(cursor) do
          {logic, _} = Logic.stop(previous)
          broadcast(logic)
          Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:fisher_log, "kill corner — parado"})
          {:noreply, cancel_timer(%{state | logic: logic})}
        else
          {:noreply, reschedule(state, Logic.tick_interval(previous))}
        end

      _ ->
        {:noreply, reschedule(state, Logic.tick_interval(previous))}
    end
  end

  defp run_tick(state, previous) do
    settings = Settings.all()

    {logic, actions, obs} =
      case Sensors.impl().observe(Logic.needs(previous), state.calib, settings) do
        {:ok, observations} ->
          {stepped, actions} = Logic.step(previous, threshold_glow(observations, settings), now())

          logic =
            case execute_all(actions, humanize_max_for(previous)) do
              :ok -> stepped
              {:error, reason} -> elem(Logic.io_failed(stepped, inspect(reason), now()), 0)
            end

          {logic, actions, observations}

        {:error, reason} ->
          {elem(Logic.io_failed(previous, inspect(reason), now()), 0), [], %{}}
      end

    broadcast_activity(previous, obs, actions)
    maybe_log_wait(previous, logic)
    if logic.state != previous.state or logic.counters != previous.counters, do: broadcast(logic)

    state = %{state | logic: logic}

    if logic.state in [:idle, :error] do
      {:noreply, cancel_timer(state)}
    else
      {:noreply, reschedule(state, Logic.tick_interval(logic))}
    end
  end

  # Anti-bot delay windows {min, max} ms per state. The CAST gets a 0..max jitter
  # so casts aren't on a fixed cadence; the HOOK gets a min..max wait before the
  # pull (the bubbles flash until we pull, so a human 0.5-1s reaction is safe and
  # non-robotic); every other state uses the global humanize (0), leaving combat's
  # own timing untouched.
  defp humanize_max_for(%Logic{state: :casting, config: c}), do: {0, c.cast_delay_max_ms}

  defp humanize_max_for(%Logic{state: :watching, config: c}),
    do: {c.hook_delay_min_ms, c.hook_delay_max_ms}

  defp humanize_max_for(%Logic{config: c}), do: {0, c.humanize_max_ms}

  defp execute_all(actions, window) do
    Enum.reduce_while(actions, :ok, fn action, :ok ->
      humanize(action, window)

      case execute(action) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # A random min..max ms pause before a real input, so the cadence looks human
  # instead of a metronome. When it actually delays (cast jitter or hook wait), it
  # announces the pause + duration in the feed so the anti-bot wait is visible.
  defp humanize({:log, _}, _window), do: :ok

  defp humanize(action, {lo, hi}) when hi > 0 do
    lo = lo |> max(0) |> min(hi)
    delay = lo + :rand.uniform(hi - lo + 1) - 1

    if delay > 0 do
      Phoenix.PubSub.broadcast(
        Pokex.PubSub,
        @topic,
        {:fisher_log, "⏳ delay anti-bot #{delay}ms → #{describe_action(action)}"}
      )
    end

    Process.sleep(delay)
  end

  defp humanize(_action, _window), do: :ok

  defp execute({:press, key}), do: Rig.impl().press(key)
  defp execute({:click, button, point}), do: Rig.impl().click(button, point)
  defp execute({:move, point}), do: Rig.impl().move(point)
  defp execute({:capture_sequence, point}), do: Rig.impl().capture_sequence(point)

  defp execute({:log, message}) do
    Logger.info("fisher: #{message}")
    :ok
  end

  # The glow sensor returns the RAW cyan count (for the live feed); Logic still
  # decides on a boolean, so apply the bite threshold here before stepping. A Fake
  # sensor may hand back a boolean directly — pass those straight through.
  defp threshold_glow(%{glow: count} = obs, settings) when is_integer(count),
    do: %{obs | glow: count > (settings[:glow_threshold] || 500)}

  defp threshold_glow(obs, _settings), do: obs

  defp broadcast(logic),
    do: Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:fisher, snapshot(logic)})

  # A live, human-readable trace of what the bot is doing and WHERE it clicks —
  # so a click landing on the map (walking) instead of the Battle tab is obvious.
  defp broadcast_activity(logic, obs, actions) do
    case describe_activity(logic, obs, actions) do
      nil -> :ok
      text -> Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:fisher_log, text})
    end
  end

  # When a state transition arms a meaningful pause, surface it in the feed with
  # its REASON and duration — so lag/failed-input scenarios are visible: the user
  # sees WHY and HOW LONG the bot is waiting, not just a silent stall.
  defp maybe_log_wait(%Logic{state: s}, %Logic{state: s}), do: :ok

  defp maybe_log_wait(_previous, %Logic{waiting_until: until, state: state})
       when is_integer(until) do
    ms = max(until - now(), 0)
    reason = fishing_wait_reason(state)

    if reason && ms >= 100 do
      Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:fisher_log, "⏳ #{reason} (#{ms}ms)"})
    end

    :ok
  end

  defp maybe_log_wait(_previous, _logic), do: :ok

  defp fishing_wait_reason(:watching), do: "assentando a água pós-arremesso"
  defp fishing_wait_reason(:assessing), do: "esperando o peixe teleportar"
  defp fishing_wait_reason(_), do: nil

  defp describe_activity(logic, obs, actions) do
    acts = actions |> Enum.map(&describe_action/1) |> Enum.reject(&is_nil/1) |> Enum.join(" · ")

    case {state_desc(logic, obs), acts} do
      {nil, ""} -> nil
      {nil, a} -> a
      {s, ""} -> s
      {s, a} -> "#{s} → #{a}"
    end
  end

  defp state_desc(
         %Logic{state: :fighting, targeted?: false, pending_verify?: true, select_idx: i} = logic,
         obs
       ),
       do:
         "luta: linha #{i} travou? #{Enum.at(Map.get(obs, :battle_lock, []), i, 0)}px (limiar #{logic.config.target_locked_min_pixels})"

  defp state_desc(%Logic{state: :fighting, targeted?: false, select_idx: i}, _obs),
    do: "luta: mirando linha #{i}"

  defp state_desc(%Logic{state: :fighting, targeted?: true, locked_row: row} = logic, obs),
    do:
      "luta: atacando linha #{row} — #{Enum.at(Map.get(obs, :battle_lock, []), row, 0)}px (mín #{logic.config.target_locked_min_pixels})"

  defp state_desc(%Logic{state: :walking_to_loot, walk_plan: plan}, _obs),
    do: "andando até o loot (#{length(plan)} passos restantes)"

  defp state_desc(%Logic{state: :looting}, _obs), do: "coletando loot (espaço)"

  defp state_desc(%Logic{state: :walking_back, walk_plan: plan}, _obs),
    do: "voltando ao ponto de pesca (#{length(plan)} passos restantes)"

  defp state_desc(%Logic{state: :capturing}, _obs), do: "capturando"

  # Live fishing telemetry: the raw cyan bubble count every watch tick, so the
  # bite (800+) vs resting pulse (≤305) is visible in the feed while it waits.
  defp state_desc(%Logic{state: :watching, settled?: settled, dead_streak: dead} = logic, obs) do
    case Map.get(obs, :glow) do
      n when is_integer(n) ->
        "vigiando: bolhas #{n}px (limiar #{Settings.get(:glow_threshold)}) — assentado? #{settled} — #{dead}/#{logic.config.watch_dead_streak_needed} sem bolha"

      _ ->
        "vigiando"
    end
  end

  defp state_desc(_, _obs), do: nil

  defp describe_action({:press, key}), do: "tecla #{key}"
  defp describe_action({:click, :left, {x, y}}), do: "clique esq (#{x},#{y})"
  defp describe_action({:click, :right, {x, y}}), do: "clique dir (#{x},#{y})"
  defp describe_action({:move, {x, y}}), do: "mover mouse (#{x},#{y})"
  defp describe_action({:capture_sequence, {x, y}}), do: "pokébola (#{x},#{y})"
  defp describe_action({:log, msg}), do: msg

  defp snapshot(nil), do: %{state: :idle, counters: %Logic{}.counters, error: nil}
  defp snapshot(logic), do: %{state: logic.state, counters: logic.counters, error: logic.error}

  defp now, do: System.monotonic_time(:millisecond)

  defp reschedule(state, delay_ms) do
    state = cancel_timer(state)
    %{state | timer: Process.send_after(self(), :tick, delay_ms)}
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | timer: nil}
  end
end
