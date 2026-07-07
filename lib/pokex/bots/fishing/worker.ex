defmodule Pokex.Bots.Fishing.Worker do
  @moduledoc """
  Driver GenServer around the pure Fishing.Logic: senses the glow, steps the
  state machine, and submits every resulting action list to the shared Body at
  `:normal` priority (fishing yields to combat). Broadcasts snapshots on
  PubSub. Does NOT own/duplicate panic-corner polling itself (a later
  Guardian will centralize that) — but the kill corner is still honored every
  active tick via `Fishing.Logic.step/3`. Does NOT touch combat.

  Paces its own inputs with an anti-bot humanize delay (a random cast-jitter
  before a CAST, a random hook-delay in WATCHING) applied here, BEFORE
  Body.perform — the Body itself never humanizes.
  """
  use GenServer
  require Logger

  alias Pokex.Bots.Fishing.Logic
  alias Pokex.Bots.Fisher.{Config, Sensors}
  alias Pokex.Bots.Body
  alias Pokex.{Calibration, Preflight, Settings}

  @topic "fishing"

  def topic, do: @topic

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    body = Keyword.get(opts, :body, Body)

    case name do
      nil -> GenServer.start_link(__MODULE__, body)
      name -> GenServer.start_link(__MODULE__, body, name: name)
    end
  end

  def run(server \\ __MODULE__), do: GenServer.call(server, :run)
  def halt(server \\ __MODULE__), do: GenServer.call(server, :halt)
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(body), do: {:ok, %{logic: nil, calib: nil, body: body, timer: nil}}

  @impl true
  def handle_call(:run, _from, state) do
    with :ok <- Preflight.run(),
         {:ok, calib} <- Calibration.load() do
      config = Config.build(calib, Settings.all())
      {logic, actions} = Logic.start(Logic.new(config), now())
      submit(state.body, actions, humanize_max_for(logic))
      broadcast(logic)
      {:reply, :ok, %{state | logic: logic, calib: calib} |> reschedule(0)}
    else
      {:error, messages} when is_list(messages) -> {:reply, {:error, messages}, state}
      {:error, other} -> {:reply, {:error, ["calibração ilegível: #{inspect(other)}"]}, state}
    end
  end

  def handle_call(:halt, _from, %{logic: nil} = state), do: {:reply, :ok, state}

  def handle_call(:halt, _from, state) do
    {logic, _actions} = Logic.stop(state.logic)
    broadcast(logic)
    {:reply, :ok, %{cancel_timer(state) | logic: logic}}
  end

  def handle_call(:status, _from, state), do: {:reply, snapshot(state.logic), state}

  @impl true
  def handle_info(:tick, %{logic: nil} = state), do: {:noreply, state}

  def handle_info(:tick, %{logic: %Logic{state: s}} = state) when s in [:idle, :error],
    do: {:noreply, state}

  def handle_info(:tick, state) do
    previous = state.logic

    # In a post-action pause there's nothing to sense — skip the capture (so
    # the kill corner isn't polled THIS tick either; Fishing.Logic.step/3 is
    # what checks it, on every active tick once sensing resumes) and just
    # wait out the pause.
    if Logic.waiting?(previous, now()) do
      {:noreply, reschedule(state, Logic.tick_interval(previous))}
    else
      run_tick(state, previous)
    end
  end

  defp run_tick(state, previous) do
    settings = Settings.all()

    {logic, actions, obs} =
      case Sensors.impl().observe(Logic.needs(previous), state.calib, settings) do
        {:ok, observations} ->
          obs = threshold_glow(observations, settings)
          {stepped, actions} = Logic.step(previous, obs, now())

          logic =
            case submit(state.body, actions, humanize_max_for(previous)) do
              :ok -> stepped
              {:error, reason} -> elem(Logic.io_failed(stepped, inspect(reason), now()), 0)
            end

          {logic, actions, obs}

        {:error, reason} ->
          {elem(Logic.io_failed(previous, inspect(reason), now()), 0), [], %{}}
      end

    broadcast_activity(previous, obs, actions)
    if logic.state != previous.state or logic.counters != previous.counters, do: broadcast(logic)

    state = %{state | logic: logic}

    if logic.state in [:idle, :error] do
      {:noreply, cancel_timer(state)}
    else
      {:noreply, reschedule(state, Logic.tick_interval(logic))}
    end
  end

  # Anti-bot delay windows {min, max} ms per state. The CAST gets a 0..max
  # jitter so casts aren't on a fixed cadence; the HOOK gets a min..max wait
  # before the pull (the bubbles flash until we pull, so a human 0.5-1s
  # reaction is safe and non-robotic); every other state uses the global
  # humanize (0).
  defp humanize_max_for(%Logic{state: :casting, config: c}), do: {0, c.cast_delay_max_ms}

  defp humanize_max_for(%Logic{state: :watching, config: c}),
    do: {c.hook_delay_min_ms, c.hook_delay_max_ms}

  defp humanize_max_for(%Logic{config: c}), do: {0, c.humanize_max_ms}

  # Every action list is one atomic Body.perform at :normal — fishing yields
  # to combat. The humanize delay is paced here, BEFORE the submit, so the
  # Body itself never sleeps (combat, running in its own process, is
  # unaffected).
  defp submit([], _body, _window), do: :ok

  defp submit(body, actions, window) do
    humanize(actions, window)
    Body.perform(actions, :normal, body)
  end

  # A random min..max ms pause before a real input, so the cadence looks human
  # instead of a metronome. When it actually delays (cast jitter or hook
  # wait), it announces the pause + duration in the feed so the anti-bot wait
  # is visible.
  defp humanize(actions, {lo, hi}) when hi > 0 do
    lo = lo |> max(0) |> min(hi)
    delay = lo + :rand.uniform(hi - lo + 1) - 1

    if delay > 0 do
      Phoenix.PubSub.broadcast(
        Pokex.PubSub,
        @topic,
        {:fishing_log, "⏳ delay anti-bot #{delay}ms → #{describe_actions(actions)}"}
      )

      Process.sleep(delay)
    end
  end

  defp humanize(_actions, _window), do: :ok

  defp describe_actions(actions),
    do: actions |> Enum.map(&describe_action/1) |> Enum.reject(&is_nil/1) |> Enum.join(" · ")

  # The glow sensor returns the RAW cyan count (for the live feed); Logic decides
  # on booleans, so apply the thresholds here before stepping: `glow` = a BITE
  # (raw over glow_threshold), `line?` = the line is PRESENT in the water (raw at
  # or above line_present_min_px, i.e. a resting line pulsing between bites vs
  # near-empty water). A Fake sensor may hand back a boolean directly — pass those
  # straight through (no line? key → treated as absent by the Logic).
  defp threshold_glow(%{glow: count} = obs, settings) when is_integer(count) do
    obs
    |> Map.put(:glow, count > (settings[:glow_threshold] || 500))
    |> Map.put(:line?, count >= (settings[:line_present_min_px] || 100))
  end

  defp threshold_glow(obs, _settings), do: obs

  defp broadcast(logic),
    do: Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:fishing, snapshot(logic)})

  defp broadcast_activity(logic, obs, actions) do
    case describe_activity(logic, obs, actions) do
      nil -> :ok
      text -> Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:fishing_log, text})
    end
  end

  defp describe_activity(logic, obs, actions) do
    acts = describe_actions(actions)

    case {state_desc(logic, obs), acts} do
      {nil, ""} -> nil
      {nil, a} -> a
      {s, ""} -> s
      {s, a} -> "#{s} → #{a}"
    end
  end

  defp state_desc(%Logic{state: :focusing}, _obs), do: "pesca: focando (clique neutro)"
  defp state_desc(%Logic{state: :equipping}, _obs), do: "pesca: equipando a vara"
  defp state_desc(%Logic{state: :casting}, _obs), do: "pesca: lançando a linha"

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
