defmodule Pokex.Bots.ShinyGuard do
  @moduledoc """
  The anti-shiny protocol's TRIGGER (Lucas's request): watches the `:arena`
  feed for the shiny verdict `Interpret.arena` computes from the wiki-sprite
  color signatures, debounces it over `shiny_streak_needed` consecutive
  frames, and acts per `shiny_action`:

    * `"fugir"` — the emergency-escape protocol (latch, click-walk to the
      calibrated staircase, full stop, alarm) via the injected `escape_fun`;
    * `"alarme"` — his "lutar se quiser": keep fighting, broadcast a
      `{:rule_alarm, _}` so the panel screams (F7 pipeline) and he decides.

  Always-on app child like the Guardian — a shiny is dangerous during MANUAL
  play too. It manages its own arena-feed attachment from the
  `shiny_guard_enabled` setting on a slow poll (the demand-driven feed only
  captures while someone is attached), rebuilds the color signatures on every
  (re)attach so edits to `shiny_watch_names` apply on the next enable, and
  holds a refractory window after firing so one sighting can't machine-gun
  escapes or alarms. It never touches the Body itself — the escape path owns
  its own gates, the alarm is just PubSub — so no panic fan-out is needed.

  Like the Guardian's session rules, the env flag `:shiny_guard_active` turns
  the app-global instance off in the test env (a test flipping the global
  setting must not start real arena captures); test instances opt in with
  `active: true`.
  """

  use GenServer
  require Logger

  alias Pokex.Perception
  alias Pokex.Perception.Feed
  alias Pokex.Pokedex.ShinySignatures
  alias Pokex.Settings

  @combat_topic "combat"
  # the panel's live meter subscribes here for throttled per-name readings
  @reading_topic "shiny"
  @poll_ms 1_000
  @refractory_ms 60_000
  @reading_throttle_ms 700

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    state = %{
      escape_fun: Keyword.get(opts, :escape_fun, &Pokex.Bots.BotSupervisor.emergency_escape/1),
      active?: Keyword.get(opts, :active, Application.get_env(:pokex, :shiny_guard_active, true)),
      attached?: false,
      feed_ref: nil,
      streak: 0,
      last_fired_at: nil,
      last_reading_at: nil
    }

    case name do
      nil -> GenServer.start_link(__MODULE__, state)
      name -> GenServer.start_link(__MODULE__, state, name: name)
    end
  end

  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(state) do
    schedule_poll()
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       enabled?: state.active? and Settings.get(:shiny_guard_enabled),
       attached?: state.attached?,
       streak: state.streak,
       signatures: Enum.map(ShinySignatures.signatures(), & &1.name)
     }, state}
  end

  @impl true
  def handle_info(:poll, state) do
    state = sync_attachment(state)
    schedule_poll()
    {:noreply, state}
  end

  def handle_info({:world, :arena, obs}, state) do
    state = broadcast_reading(state, Map.get(obs, :shiny_scores, []))
    {:noreply, advance(state, Map.get(obs, :shiny))}
  end

  def handle_info({:world, _key, _obs}, state), do: {:noreply, state}

  # The :arena feed died — mark detached; the next poll re-attaches (a fresh
  # feed starts with nobody attached, same liveness pattern as the catcher's).
  def handle_info({:DOWN, ref, :process, _obj, _reason}, %{feed_ref: ref} = state),
    do: {:noreply, %{state | attached?: false, feed_ref: nil, streak: 0}}

  def handle_info(_msg, state), do: {:noreply, state}

  # -- attachment lifecycle ----------------------------------------------------

  defp sync_attachment(%{active?: false} = state), do: state

  defp sync_attachment(state) do
    enabled? = Settings.get(:shiny_guard_enabled)

    cond do
      enabled? and not state.attached? ->
        {:ok, built} = ShinySignatures.rebuild()

        if built == [] do
          Logger.warning(
            "ShinyGuard: nenhuma assinatura construída (sprites/base ausentes?) — vigiando nada"
          )
        end

        Perception.attach(:arena)
        ref = Process.monitor(Feed.name(:arena))
        %{state | attached?: true, feed_ref: ref, streak: 0}

      not enabled? and state.attached? ->
        safe_detach()
        demonitor(state.feed_ref)
        %{state | attached?: false, feed_ref: nil, streak: 0}

      true ->
        state
    end
  end

  defp safe_detach do
    Perception.detach(:arena)
  catch
    _kind, _reason -> :ok
  end

  defp demonitor(nil), do: :ok
  defp demonitor(ref), do: Process.demonitor(ref, [:flush])

  # -- detection ---------------------------------------------------------------

  defp advance(state, nil), do: %{state | streak: 0}

  defp advance(state, %{name: name, px: px}) do
    streak = state.streak + 1

    if streak >= Settings.get(:shiny_streak_needed) and cooled_down?(state) do
      fire(state, name, px)
    else
      %{state | streak: streak}
    end
  end

  defp cooled_down?(%{last_fired_at: nil}), do: true

  defp cooled_down?(%{last_fired_at: at}),
    do: System.monotonic_time(:millisecond) - at > @refractory_ms

  # Feed the panel's live meter — throttled so the arena's ~300ms cadence
  # doesn't re-render the panel several times a second.
  defp broadcast_reading(state, []), do: state

  defp broadcast_reading(state, scores) do
    now = System.monotonic_time(:millisecond)

    if state.last_reading_at == nil or now - state.last_reading_at > @reading_throttle_ms do
      Phoenix.PubSub.broadcast(
        Pokex.PubSub,
        @reading_topic,
        {:shiny_reading, %{scores: Map.new(scores), min_px: Settings.get(:shiny_min_px)}}
      )

      %{state | last_reading_at: now}
    else
      state
    end
  end

  defp fire(state, name, px) do
    reason = "✨ SHINY na área: #{name} (#{px}px)"

    case Settings.get(:shiny_action) do
      "fugir" ->
        Logger.warning("ShinyGuard: #{reason} — fugindo pela escada")
        state.escape_fun.(reason)

      _alarme_ou_lutar ->
        Logger.warning("ShinyGuard: #{reason} — modo lutar, só alarmando")
        Phoenix.PubSub.broadcast(Pokex.PubSub, @combat_topic, {:rule_alarm, reason <> " — LUTA!"})
    end

    %{state | streak: 0, last_fired_at: System.monotonic_time(:millisecond)}
  end

  defp schedule_poll, do: Process.send_after(self(), :poll, @poll_ms)
end
