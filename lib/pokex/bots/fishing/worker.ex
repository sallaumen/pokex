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

  alias Pokex.Bots.Body
  alias Pokex.Bots.Fisher.Config
  alias Pokex.Bots.Fisher.Sensors
  alias Pokex.Bots.Fishing.Logic
  alias Pokex.Bots.InputGate
  alias Pokex.Calibration
  alias Pokex.Perception
  alias Pokex.Preflight
  alias Pokex.Settings

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
  def init(body),
    do: {:ok, %{logic: nil, calib: nil, body: body, timer: nil, held?: false, gated?: false}}

  @impl true
  def handle_call(:run, _from, state) do
    with :ok <- Preflight.run(),
         {:ok, calib} <- Calibration.load() do
      config = Config.build(calib, Settings.all())
      {logic, actions} = Logic.start(Logic.new(config), now())
      submit(state.body, actions, humanize_max_for(logic))
      broadcast(logic)
      {:reply, :ok, %{state | logic: logic, calib: calib, held?: false} |> reschedule(0)}
    else
      {:error, messages} when is_list(messages) -> {:reply, {:error, messages}, state}
      {:error, other} -> {:reply, {:error, ["calibração ilegível: #{inspect(other)}"]}, state}
    end
  end

  def handle_call(:halt, _from, %{logic: nil} = state), do: {:reply, :ok, state}

  def handle_call(:halt, _from, state) do
    {logic, _actions} = Logic.stop(state.logic)
    broadcast(logic)
    {:reply, :ok, %{cancel_timer(state) | logic: logic, held?: false}}
  end

  def handle_call(:status, _from, state), do: {:reply, snapshot(state.logic), state}

  @impl true
  def handle_info(:tick, %{logic: nil} = state), do: {:noreply, state}

  def handle_info(:tick, %{logic: %Logic{state: s}} = state) when s in [:idle, :error],
    do: {:noreply, state}

  def handle_info(:tick, state) do
    previous = state.logic

    cond do
      # The mini-game is being played: freeze this cycle (no sensing, no
      # actions) and keep polling the fact. Nobody halts us from outside.
      # The freeze EDGE broadcasts once so the panel shows WHY fishing stopped;
      # the repeated polls stay silent.
      Perception.mini_game_playing?() ->
        if not state.held?, do: broadcast_held(previous)
        {:noreply, reschedule(%{state | held?: true}, Logic.tick_interval(previous))}

      # Resume edge: the fight for the rod is over. The frozen mid-cycle state
      # (a glow watched 30s ago, a cast mid-settle) is garbage — restart the
      # cast cycle fresh, exactly what the old external halt+run pair produced.
      state.held? ->
        {:noreply, resume_from_hold(state)}

      # Input gate closed: every key would be SWALLOWED with :ok and the Logic
      # would believe it — counting a cast that never hit the water (how the
      # cavebot "walked" without walking). Freeze the WHOLE cycle, sensor
      # included, like the mini-game freeze; warn ONCE on the edge and keep
      # polling until it reopens.
      not InputGate.allowed?() ->
        if not state.gated? do
          Phoenix.PubSub.broadcast(
            Pokex.PubSub,
            @topic,
            {:fishing_log, :macro,
             "🚫 portão de entrada fechado (foco/canto) — segurando a vara; nada foi apertado"}
          )
        end

        {:noreply, reschedule(%{state | gated?: true}, Logic.tick_interval(previous))}

      # gate reopened: announce, and this SAME tick goes back to work
      state.gated? ->
        Phoenix.PubSub.broadcast(
          Pokex.PubSub,
          @topic,
          {:fishing_log, :macro, "portão reaberto — a pesca segue"}
        )

        run_tick(%{state | gated?: false}, previous)

      # In a post-action pause there's nothing to sense — skip the capture (so
      # the kill corner isn't polled THIS tick either; Fishing.Logic.step/3 is
      # what checks it, on every active tick once sensing resumes) and just
      # wait out the pause.
      Logic.waiting?(previous, now()) ->
        {:noreply, reschedule(state, Logic.tick_interval(previous))}

      true ->
        run_tick(state, previous)
    end
  end

  defp resume_from_hold(state) do
    config = Config.build(state.calib, Settings.all())
    {logic, actions} = Logic.start(Logic.new(config), now())
    submit(state.body, actions, humanize_max_for(logic))
    broadcast(logic)
    %{state | logic: logic, held?: false} |> reschedule(0)
  end

  # The fishing→support HP gate, fed by the :pokemon blackboard fact PlayerSupport
  # publishes. Computed here (not in Logic) so the panel toggle and threshold apply
  # instantly, without rebuilding the run config. Empty map = gate off or fact
  # unknown (monitor halted / HP not calibrated) — Logic then never holds for it.
  defp pokemon_obs do
    with true <- Settings.get(:require_pokemon_hp),
         {:ok, pokemon} <- Pokex.Perception.pokemon() do
      min_pct = Settings.get(:pokemon_hp_fishing_pct)

      cond do
        pokemon.readable? != true ->
          %{pokemon_ok?: false, pokemon_hold_reason: "sem pokémon ativo"}

        is_integer(pokemon.hp_pct) and pokemon.hp_pct < min_pct ->
          %{pokemon_ok?: false, pokemon_hold_reason: "vida #{pokemon.hp_pct}% < #{min_pct}%"}

        true ->
          %{pokemon_ok?: true}
      end
    else
      _off_or_unknown -> %{}
    end
  end

  defp run_tick(state, previous) do
    settings = Settings.all()

    {logic, actions, raw_obs} =
      case Sensors.impl().observe(Logic.needs(previous), state.calib, settings) do
        {:ok, observations} ->
          observations = Map.merge(observations, pokemon_obs())
          {stepped, actions} = Logic.step(previous, threshold_glow(observations, settings), now())

          logic =
            case submit(state.body, actions, humanize_max_for(previous, actions)) do
              :ok -> stepped
              {:error, reason} -> elem(Logic.io_failed(stepped, inspect(reason), now()), 0)
            end

          # feed gets the RAW observations (integer glow) so "vigiando" can show
          # the live bubble count vs the threshold — the boolean-thresholded obs
          # would hide it.
          {logic, actions, observations}

        {:error, reason} ->
          {elem(Logic.io_failed(previous, inspect(reason), now()), 0), [], %{}}
      end

    # Alarms decided by the Logic (e.g. dry casts) ring the panel siren — the
    # same one the rule guards use.
    for {:alarm, msg} <- actions do
      Phoenix.PubSub.broadcast(Pokex.PubSub, "combat", {:rule_alarm, :fishing, msg})
    end

    # A tick is MACRO when the state or a counter changed (a hook, a recast, an
    # error) OR the hold latched/released — the events worth keeping; every other
    # tick is routine DEBUG chatter (per-frame bubble counts), hidden by default in
    # the panel feed. Elevating the hold transition means the lock never scrolls past
    # unseen the way the old once-only debug log did.
    level =
      if logic.state != previous.state or logic.counters != previous.counters or
           logic.holding? != previous.holding?,
         do: :macro,
         else: :debug

    broadcast_activity(previous, raw_obs, actions, level)
    if level == :macro, do: broadcast(logic)

    # Just hooked a fish → it'll land near the top of the Battle list. Tell combat to
    # search NOW (one-way, fire-and-forget; combat only reacts if it's searching).
    if logic.counters.hooked > previous.counters.hooked do
      Phoenix.PubSub.broadcast(
        Pokex.PubSub,
        Pokex.Bots.Combat.Worker.catch_topic(),
        {:fish_caught}
      )
    end

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
  defp humanize_max_for(logic, actions \\ [])

  defp humanize_max_for(%Logic{state: :watching, config: c}, actions) do
    if cast_sequence?(actions),
      do: {0, c.cast_delay_max_ms},
      else: {c.hook_delay_min_ms, c.hook_delay_max_ms}
  end

  defp humanize_max_for(%Logic{state: :casting, config: c}, _actions),
    do: {0, c.cast_delay_max_ms}

  defp humanize_max_for(%Logic{config: c}, _actions), do: {0, c.humanize_max_ms}

  defp cast_sequence?(actions) do
    Enum.any?(actions, &match?({:move, _point}, &1)) and
      Enum.any?(actions, &match?({:press, _key}, &1))
  end

  # Every action list is one atomic Body.perform at :normal — fishing yields
  # to combat. The humanize delay is paced here, BEFORE the submit, so the
  # Body itself never sleeps (combat, running in its own process, is
  # unaffected).
  # No actions this tick (e.g. watching with no bite) → do NOTHING: no humanize
  # sleep, no Body round-trip. The old arg order (`submit([], _body, _window)`)
  # never matched — `submit/3` is called `(body, actions, window)` — so the hook
  # delay slept EVERY watch tick, sampling the bubbles too slowly to catch the
  # flashing bite. This clause is the fix.
  defp submit(_body, [], _window), do: :ok

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
        {:fishing_log, :debug, "delay #{delay}ms → #{describe_actions(actions)}"}
      )

      Process.sleep(delay)
    end
  end

  defp humanize(_actions, _window), do: :ok

  defp describe_actions(actions),
    do: actions |> Enum.map(&describe_action/1) |> Enum.reject(&is_nil/1) |> Enum.join(" · ")

  # The real glow sensor returns a fishing signal map (focused around the lure).
  # Older fakes/tests may still hand back a raw integer or boolean; keep those
  # shapes working so logic tests stay simple.
  defp threshold_glow(%{glow: %{bubble_count: count} = signal} = obs, settings)
       when is_integer(count) do
    line_present? =
      case Map.fetch(signal, :line_present?) do
        {:ok, present?} ->
          present?

        :error ->
          Map.get(signal, :bubble_count, 0) >= Settings.value(settings, :line_present_min_px)
      end

    obs
    |> Map.put(:glow, count > Settings.value(settings, :glow_threshold))
    |> Map.put(:line?, line_present?)
  end

  defp threshold_glow(%{glow: count} = obs, settings) when is_integer(count) do
    obs
    |> Map.put(:glow, count > Settings.value(settings, :glow_threshold))
    |> Map.put(:line?, count >= Settings.value(settings, :line_present_min_px))
  end

  defp threshold_glow(obs, _settings), do: obs

  defp broadcast(logic),
    do: Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:fishing, snapshot(logic)})

  defp broadcast_held(logic) do
    snapshot = %{snapshot(logic) | hold_reason: "mini-game em jogo"}
    Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:fishing, snapshot})
  end

  defp broadcast_activity(logic, obs, actions, level) do
    case describe_activity(logic, obs, actions) do
      nil -> :ok
      text -> Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:fishing_log, level, text})
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

  defp state_desc(%Logic{state: :focusing}, _obs), do: "pesca: foco"
  defp state_desc(%Logic{state: :equipping}, _obs), do: "pesca: equip"
  defp state_desc(%Logic{state: :casting}, _obs), do: "pesca: cast"

  defp state_desc(%Logic{state: :watching, settled?: settled, dead_streak: dead} = logic, obs) do
    case Map.get(obs, :glow) do
      %{bubble_count: n} = signal ->
        lure = Map.get(signal, :lure_count, 0)
        line? = Map.get(signal, :line_present?, false)

        "pesca: bol #{n}/#{fmt_threshold(Settings.get(:glow_threshold))} isca #{lure} linha #{yes_no(line?)} #{settled_label(settled)} #{dead}/#{logic.config.watch_dead_streak_needed}#{lock_suffix(logic)}"

      n when is_integer(n) ->
        "pesca: bol #{n}/#{fmt_threshold(Settings.get(:glow_threshold))} #{settled_label(settled)} #{dead}/#{logic.config.watch_dead_streak_needed}#{lock_suffix(logic)}"

      _ ->
        "pesca: vigia#{lock_suffix(logic)}"
    end
  end

  defp state_desc(_, _obs), do: nil

  # While a bite is HELD by the cooldown gate the line stays live and the bubbles keep
  # flashing, so without this the watch line just reads "bolhas Npx (acima do limiar)"
  # forever and never says WHY it isn't pulling. Surface the lock on every held tick.
  defp lock_suffix(%Logic{holding?: true}), do: " — 🔒 cd kill"
  defp lock_suffix(_logic), do: ""

  defp settled_label(true), do: "ok"
  defp settled_label(false), do: "settle"

  defp yes_no(true), do: "sim"
  defp yes_no(false), do: "nao"

  defp fmt_threshold(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 0)
  defp fmt_threshold(value), do: to_string(value)

  defp describe_action({:press, key}), do: "key #{key}"
  defp describe_action({:click, :left, {x, y}}), do: "clickE #{x},#{y}"
  defp describe_action({:click, :right, {x, y}}), do: "clickD #{x},#{y}"
  defp describe_action({:move, {x, y}}), do: "move #{x},#{y}"
  defp describe_action({:capture_sequence, {x, y}}), do: "ball #{x},#{y}"
  defp describe_action({:wait, _ms}), do: nil
  defp describe_action({:log, msg}), do: msg
  defp describe_action({:alarm, msg}), do: msg

  defp snapshot(nil),
    do: %{
      state: :idle,
      counters: %Logic{}.counters,
      error: nil,
      hold_reason: nil,
      last_action: nil
    }

  defp snapshot(logic),
    do: %{
      state: logic.state,
      counters: logic.counters,
      error: logic.error,
      hold_reason: logic.hold_reason,
      last_action: logic.last_action
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
