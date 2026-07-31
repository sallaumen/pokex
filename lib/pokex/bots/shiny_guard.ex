defmodule Pokex.Bots.ShinyGuard do
  @moduledoc """
  The anti-shiny protocol's TRIGGER. Watches the `:battle` feed for the game's
  OWN shiny marker — the gold ★ the battle list paints before a shiny's name
  (Lucas, 2026-07-21: "descobri um jeito muito mais fácil, pela estrelinha
  amarela"). That beats guessing the sprite recolor: it is explicit, it works
  for ANY shiny (not only the configured names), and it rides the region
  combat already captures every ~120ms.

  Debounce is a TIME window, not a message count: the feed dedupes identical
  observations, so a calm list with a shiny broadcasts ONCE — the guard arms a
  `shiny_confirm_ms` timer on the sighting and fires only if no clean frame
  refutes it in the window (a one-frame glitch is refuted ~120ms later by the
  next capture). It LOGS the encounter (Pokex.Pokedex.ShinyLog — the trophy
  shelf) and acts per `shiny_action`:

    * `"fugir"` — the emergency-escape protocol (latch, click-walk to the
      calibrated staircase, full stop, alarm) via the injected `escape_fun`;
    * `"alarme"` — his "lutar se quiser": keep fighting, broadcast a
      `{:rule_alarm, _}` so the panel screams (F7 pipeline) and he decides.

  Always-on app child like the Guardian — a shiny is dangerous during MANUAL
  play too. It manages its own battle-feed attachment from the
  `shiny_guard_enabled` setting on a slow poll (the demand-driven feed only
  captures while someone is attached) and holds a refractory window after
  firing so one sighting can't machine-gun escapes or alarms. It never
  touches the Body itself — the escape path owns its own gates, the alarm is
  just PubSub — so no panic fan-out is needed.

  Like the Guardian's session rules, the env flag `:shiny_guard_active` turns
  the app-global instance off in the test env (a test flipping the global
  setting must not start real arena captures); test instances opt in with
  `active: true`.
  """

  use GenServer
  require Logger

  alias Pokex.Bots.InputGate
  alias Pokex.Perception
  alias Pokex.Perception.Feed
  alias Pokex.Pokedex.ShinyLog
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
      # a sighting awaiting its confirm window; ref ties the timer to THIS pending
      pending_ref: nil,
      pending_px: 0,
      # NAMES read from the starred rows — the alarm says who it is
      pending_nomes: [],
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
    # Feeds deliver observations by PubSub on the world topic — attach only
    # creates demand. Without THIS subscribe the guard is attached but deaf
    # (the bug behind the silent Kingler sighting of 2026-07-21).
    Phoenix.PubSub.subscribe(Pokex.PubSub, Perception.topic())
    # combat's kill broadcast closes an open encounter as "morto"
    Phoenix.PubSub.subscribe(Pokex.PubSub, Pokex.Bots.Catcher.Worker.kill_topic())
    schedule_poll()
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       enabled?: state.active? and Settings.get(:shiny_guard_enabled),
       attached?: state.attached?,
       pending?: state.pending_ref != nil,
       star_min_columns: Settings.get(:shiny_star_min_columns)
     }, state}
  end

  @impl true
  def handle_info(:poll, state) do
    state = sync_attachment(state)
    schedule_poll()
    {:noreply, state}
  end

  def handle_info({:world, :battle, obs}, state) do
    # the world topic carries battle obs whenever ANYONE (combat included)
    # attaches the feed — a disabled guard must stay inert
    if state.active? and Settings.get(:shiny_guard_enabled) do
      px = Map.get(obs, :shiny_star_run, 0)
      state = broadcast_reading(state, px)
      seen? = Map.get(obs, :shiny_rows, []) != []
      {:noreply, advance(state, seen?, px, nomes_shiny(obs))}
    else
      {:noreply, %{state | pending_ref: nil}}
    end
  end

  # The confirm window closed. Still pending (no clean frame refuted it) →
  # a real shiny is on the list.
  def handle_info({:confirm_shiny, ref}, %{pending_ref: ref} = state),
    do: {:noreply, fire(%{state | pending_ref: nil}, state.pending_px)}

  def handle_info({:confirm_shiny, _stale}, state), do: {:noreply, state}

  def handle_info({:world, _key, _obs}, state), do: {:noreply, state}

  # A kill right after a sighting IS that shiny dying (Lucas: "se eu matei um
  # Shiny"). Outside the window it is an ordinary kill — ignored.
  def handle_info(kill, state) when kill in [{:kill}, {:kill, nil}] do
    if recent_sighting?(state), do: ShinyLog.resolve_last("morto")
    {:noreply, state}
  end

  def handle_info({:kill, _corpse}, state) do
    if recent_sighting?(state), do: ShinyLog.resolve_last("morto")
    {:noreply, state}
  end

  # The :battle feed died — mark detached; the next poll re-attaches (a fresh
  # feed starts with nobody attached, same liveness pattern as the catcher's).
  def handle_info({:DOWN, ref, :process, _obj, _reason}, %{feed_ref: ref} = state),
    do: {:noreply, %{state | attached?: false, feed_ref: nil, pending_ref: nil}}

  def handle_info(_msg, state), do: {:noreply, state}

  defp sync_attachment(%{active?: false} = state), do: state

  defp sync_attachment(state) do
    enabled? = Settings.get(:shiny_guard_enabled)

    cond do
      enabled? and not state.attached? ->
        Perception.attach(:battle)
        ref = Process.monitor(Feed.name(:battle))
        %{state | attached?: true, feed_ref: ref, pending_ref: nil}

      not enabled? and state.attached? ->
        safe_detach()
        demonitor(state.feed_ref)
        %{state | attached?: false, feed_ref: nil, pending_ref: nil}

      true ->
        state
    end
  end

  defp safe_detach do
    Perception.detach(:battle)
  catch
    _kind, _reason -> :ok
  end

  defp demonitor(nil), do: :ok
  defp demonitor(ref), do: Process.demonitor(ref, [:flush])

  # a clean frame refutes any pending sighting
  defp advance(state, false, _px, _nomes), do: %{state | pending_ref: nil}

  defp advance(%{pending_ref: nil} = state, true, px, nomes) do
    if cooled_down?(state) do
      ref = make_ref()
      Process.send_after(self(), {:confirm_shiny, ref}, Settings.get(:shiny_confirm_ms))
      %{state | pending_ref: ref, pending_px: px, pending_nomes: nomes}
    else
      state
    end
  end

  # already pending: keep the freshest px (and names) for the log
  defp advance(state, true, px, nomes), do: %{state | pending_px: px, pending_nomes: nomes}

  # WHO the shiny is: the interpreter already reads each row's name
  # (enemies_detail + shiny?) — the alarm used to say only "estrela 40px",
  # forcing a run to the screen to know whether to drop everything.
  defp nomes_shiny(obs) do
    obs
    |> Map.get(:enemies_detail, [])
    |> Enum.filter(&(Map.get(&1, :shiny?) == true))
    |> Enum.map(&Map.get(&1, :name))
    |> Enum.reject(&is_nil/1)
  end

  # the encounter is "open" for a while after the sighting — long enough for a
  # fight to end, short enough not to claim an unrelated kill
  @encounter_window_ms 45_000

  defp recent_sighting?(%{last_fired_at: nil}), do: false

  defp recent_sighting?(%{last_fired_at: at}),
    do: System.monotonic_time(:millisecond) - at <= @encounter_window_ms

  defp cooled_down?(%{last_fired_at: nil}), do: true

  defp cooled_down?(%{last_fired_at: at}),
    do: System.monotonic_time(:millisecond) - at > @refractory_ms

  # Feed the panel's live meter — throttled so the arena's ~300ms cadence
  # doesn't re-render the panel several times a second.
  defp broadcast_reading(state, px) do
    now = System.monotonic_time(:millisecond)

    if state.last_reading_at == nil or now - state.last_reading_at > @reading_throttle_ms do
      Phoenix.PubSub.broadcast(
        Pokex.PubSub,
        @reading_topic,
        {:shiny_reading, %{star_run: px, min_px: Settings.get(:shiny_star_min_columns)}}
      )

      %{state | last_reading_at: now}
    else
      state
    end
  end

  defp fire(state, px) do
    action = Settings.get(:shiny_action)
    quem = if state.pending_nomes == [], do: "", else: " #{Enum.join(state.pending_nomes, ", ")}"
    reason = "✨ SHINY#{quem} na lista de batalha (estrela #{px}px)"

    # the trophy shelf first: the encounter is logged even if the action fails.
    # star_px, not star_run: record/1 reads attrs[:star_px] — the wrong key
    # left EVERY log trophy without the star measurement since forever.
    ShinyLog.record(
      star_px: px,
      action: action,
      outcome: "visto",
      note: if(quem == "", do: nil, else: String.trim(quem))
    )

    case action do
      "fugir" ->
        # The latch is a standing stop order (panic corner, logout, met goal).
        # With it set the guard does NOT act — but keeps shouting: when playing
        # by hand from the corner, a shiny sighting must still be announced;
        # what must not happen is the bot dragging the character to the stairs
        # mid-play. Without this, a sighted shiny moved the character with
        # everything "stopped", because this guard is an app child stop_all/0
        # never reaches — it presses no key, but the escape it calls fronts the
        # game ON PURPOSE and walks to the stairs.
        if InputGate.panic_latched?() do
          Logger.warning("ShinyGuard: #{reason} — parada em vigor, NÃO foge; só avisa")

          Phoenix.PubSub.broadcast(
            Pokex.PubSub,
            @combat_topic,
            {:rule_alarm, :shiny, reason <> " — bot parado, decida você"}
          )
        else
          Logger.warning("ShinyGuard: #{reason} — fugindo pela escada")
          state.escape_fun.(reason)
          ShinyLog.resolve_last("fugiu")
        end

      _alarme_ou_lutar ->
        Logger.warning("ShinyGuard: #{reason} — modo lutar, só alarmando")

        Phoenix.PubSub.broadcast(
          Pokex.PubSub,
          @combat_topic,
          {:rule_alarm, :shiny, reason <> " — LUTA!"}
        )
    end

    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      @reading_topic,
      {:shiny_seen, %{px: px, action: action}}
    )

    %{state | pending_ref: nil, last_fired_at: System.monotonic_time(:millisecond)}
  end

  defp schedule_poll, do: Process.send_after(self(), :poll, @poll_ms)
end
