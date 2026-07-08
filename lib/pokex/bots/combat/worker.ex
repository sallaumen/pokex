defmodule Pokex.Bots.Combat.Worker do
  @moduledoc """
  Driver GenServer around the pure Combat.Logic: senses the battle panel,
  steps the state machine, and submits every resulting action list to the
  shared Body at `:high` priority (combat preempts fishing). Broadcasts
  snapshots on PubSub. Does NOT check the panic corner (the Guardian owns
  that) and does NOT touch fishing.
  """
  use GenServer
  require Logger

  alias Pokex.Bots.Combat.Logic
  alias Pokex.Bots.Fisher.{Config, Sensors}
  alias Pokex.Bots.Body
  alias Pokex.{Calibration, Preflight, Settings}

  @topic "combat"

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

  # A fish being hooked is announced on this topic (fire-and-forget, one-way). When
  # combat is searching, it reacts by restarting the scan at the top NOW — the fresh
  # catch lands near the top of the Battle list.
  @catch_topic "fishing:caught"
  def catch_topic, do: @catch_topic

  @impl true
  def init(body) do
    Phoenix.PubSub.subscribe(Pokex.PubSub, @catch_topic)
    {:ok, %{logic: nil, calib: nil, body: body, timer: nil}}
  end

  @impl true
  def handle_call(:run, _from, state) do
    with :ok <- Preflight.run(),
         {:ok, calib} <- Calibration.load() do
      config = Config.build(calib, Settings.all())
      {logic, actions} = Logic.start(Logic.new(config), now())
      submit(state.body, actions)
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

    # In a post-action pause there's nothing to sense — skip the capture (and
    # the panic corner, which is the Guardian's concern here, not ours) and
    # just wait out the pause.
    if Logic.waiting?(previous, now()) do
      {:noreply, reschedule(state, Logic.tick_interval(previous))}
    else
      run_tick(state, previous)
    end
  end

  # Fishing hooked a fish → if we're searching, restart the scan at the top and look
  # NOW (Logic.rescan is a no-op while fighting/looting, so a live fight is untouched).
  def handle_info({:fish_caught}, %{logic: nil} = state), do: {:noreply, state}

  def handle_info({:fish_caught}, state) do
    logic = Logic.rescan(state.logic, now())

    if logic == state.logic,
      do: {:noreply, state},
      else: {:noreply, reschedule(%{state | logic: logic}, 0)}
  end

  defp run_tick(state, previous) do
    settings = Settings.all()

    {logic, actions, obs} =
      case Sensors.impl().observe(Logic.needs(previous, now()), state.calib, settings) do
        {:ok, observations} ->
          {stepped, actions} = Logic.step(previous, observations, now())

          logic =
            case submit(state.body, actions) do
              :ok -> stepped
              {:error, reason} -> elem(Logic.io_failed(stepped, inspect(reason), now()), 0)
            end

          {logic, actions, observations}

        {:error, reason} ->
          {elem(Logic.io_failed(previous, inspect(reason), now()), 0), [], %{}}
      end

    # MACRO when the state or a counter changed (a lock, a kill, a loot, an
    # error); every other tick — the per-row "linha N travou? Npx" reads — is
    # routine DEBUG chatter, hidden by default in the panel feed.
    level =
      if logic.state != previous.state or logic.counters != previous.counters,
        do: :macro,
        else: :debug

    broadcast_activity(previous, obs, actions, level)
    if level == :macro, do: broadcast(logic)

    # A kill (fights bumped) hands the corpse to the Loot.Worker (one-way, fire-and-forget);
    # combat itself keeps scanning/attacking. last_hostile is the corpse's floating-name point.
    if logic.counters.fights > previous.counters.fights,
      do: broadcast_kill(logic.last_hostile)

    state = %{state | logic: logic}

    if logic.state in [:idle, :error] do
      {:noreply, cancel_timer(state)}
    else
      {:noreply, reschedule(state, Logic.tick_interval(logic))}
    end
  end

  # Split combat's actions by input device (Lucas's rule: keyboard can run in PARALLEL, the
  # mouse can't). SKILL presses fire-and-forget on their own tasks, BYPASSING the Body — so a
  # skill key never waits behind a fishing cast that's holding the shared Body (that "fila" made
  # skills lag whole seconds). Each is tapped a few times because the game drops single taps.
  # MOUSE actions (the select-click + move-off) still go through the Body at :high, serialized
  # against fishing and run atomically. Nothing this tick → skip the Body entirely so an idle
  # combat never churns the :high queue ahead of fishing.
  defp submit(_body, []), do: :ok

  defp submit(body, actions) do
    {skills, rest} = Enum.split_with(actions, &match?({:press, _}, &1))

    Enum.each(skills, fn {:press, key} -> spawn(fn -> tap_skill(key) end) end)

    if rest == [], do: :ok, else: Body.perform(rest, :high, body)
  end

  # Tap the skill key a few times (the game silently drops single presses; the real osascript
  # latency spreads the taps over ~half a second, hitting different game frames). Best-effort:
  # a dropped skill is harmless and the rotation retries it next loop.
  defp tap_skill(key) do
    rig = Pokex.Rig.impl()
    rig.press(key)
    rig.press(key)
    rig.press(key)
  end

  defp broadcast(logic),
    do: Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:combat, snapshot(logic)})

  defp broadcast_kill(corpse),
    do:
      Phoenix.PubSub.broadcast(
        Pokex.PubSub,
        Pokex.Bots.Loot.Worker.kill_topic(),
        {:kill, corpse}
      )

  defp broadcast_activity(logic, obs, actions, level) do
    case describe_activity(logic, obs, actions) do
      nil -> :ok
      text -> Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:combat_log, level, text})
    end
  end

  defp describe_activity(logic, obs, actions) do
    acts = actions |> Enum.map(&describe_action/1) |> Enum.reject(&is_nil/1) |> Enum.join(" · ")

    case {state_desc(logic, obs), acts} do
      {nil, ""} -> nil
      {nil, a} -> a
      {s, ""} -> s
      {s, a} -> "#{s} → #{a}"
    end
  end

  defp state_desc(%Logic{state: :scanning, targeted?: false}, obs) do
    case candidates(obs) do
      [] -> "combate: sem inimigos (parado)"
      rows -> "combate: candidato(s) na(s) linha(s) #{Enum.join(rows, ",")}"
    end
  end

  defp state_desc(%Logic{state: :confirming, locked_row: row} = logic, obs),
    do:
      "combate: confirmando linha #{row} — anel #{ring_px(obs, row)}px (mín #{logic.config.target_locked_min_pixels})"

  defp state_desc(%Logic{state: :fighting, targeted?: true, locked_row: row} = logic, obs),
    do:
      "combate: atacando linha #{row} — anel #{ring_px(obs, row)}px (mín #{logic.config.target_locked_min_pixels})"

  defp state_desc(_, _obs), do: nil

  defp candidates(obs), do: (obs[:battle] || %{})[:enemies] || []
  defp ring_px(obs, row), do: Enum.at((obs[:battle] || %{})[:red] || [], row, 0)

  defp describe_action({:press, key}), do: "tecla #{key}"
  defp describe_action({:click, :left, {x, y}}), do: "clique esq (#{x},#{y})"
  defp describe_action({:click, :right, {x, y}}), do: "clique dir (#{x},#{y})"
  defp describe_action({:move, {x, y}}), do: "mover mouse (#{x},#{y})"
  defp describe_action({:capture_sequence, {x, y}}), do: "pokébola (#{x},#{y})"
  defp describe_action({:log, msg}), do: msg

  defp snapshot(nil),
    do: %{state: :idle, counters: %Logic{}.counters, error: nil, locked_row: nil}

  defp snapshot(logic),
    do: %{
      state: logic.state,
      counters: logic.counters,
      error: logic.error,
      locked_row: logic.locked_row
    }

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
