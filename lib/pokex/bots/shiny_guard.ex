defmodule Pokex.Bots.ShinyGuard do
  @moduledoc """
  The watcher for SPECIAL COLOURS: the SHINY trigger in this client, which is the same creature
  he used to call a boss (a recolour, far more health and attack, and the night's trophy). One
  concept, one path.

  The old detector waited for the golden star the previous client painted in the battle list;
  this one paints no star. What separates the special from the common here is the PALETTE: a
  shiny Electrode is green where the common one is red, and the hue survives any pose, even an
  upside-down rollout. So the watcher scans the square around the character (the same one
  `SpotScan` uses) for the PROVEN rules of `ColorRules`, with `ColorMark` doing the reading.

  NO ACTIONS, by his decision: no alarm, no escape; `shiny_action` and the `escape_fun` died
  with the star. Sighted means RECORDED: a journal line, a trophy in `ShinyLog`,
  `{:shiny_seen, info}` on the "shiny" topic (the Catcher arms the guaranteed ball,
  `shiny_always_ball`), and the panel's live meter. The intelligent reaction is born in phase 2
  of the shiny protocol (docs/shiny/plano-shiny-por-cor.md).

  Confirmation is by CONSECUTIVE SCANS (`special_color_confirm_frames`): a single-frame glimpse
  does not record. The per-rule refractory holds the machine gun. The boxes of the character and
  of the STANDING pokémon are forbidden, because his own Torterra's green is nearly a shiny
  Electrode's; the collection's noise proof is the other half of that defence.

  An always-alive child of the application, like the Guardian, because a shiny matters in manual
  play too. `:shiny_guard_active` disables the global instance in tests; test instances opt in
  with `active: true`.
  """

  use GenServer

  alias Pokex.Bots.Capture
  alias Pokex.Bots.Catcher.SpotScan
  alias Pokex.Calibration
  alias Pokex.Perception.WorldState
  alias Pokex.Pokedex.ShinyLog
  alias Pokex.Settings
  alias Pokex.Vision.{ColorMark, ColorRules, Frame}

  @combat_topic "combat"
  # the panel meter and the Catcher listen here
  @reading_topic "shiny"
  @idle_poll_ms 1_000
  @refractory_ms 60_000
  @reading_throttle_ms 700
  # the window in which a kill right after a sighting IS that shiny dying
  @encounter_window_ms 45_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    state = %{
      active?: Keyword.get(opts, :active, Application.get_env(:pokex, :shiny_guard_active, true)),
      capture: Keyword.get(opts, :capture, &Capture.frame/2),
      # consecutive scans with a blob, per rule: the confirmation
      streaks: %{},
      # last trigger per rule: the refractory
      fired_at: %{},
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
    # combat's kill broadcast closes an open encounter as "killed"
    Phoenix.PubSub.subscribe(Pokex.PubSub, Pokex.Bots.Catcher.Worker.kill_topic())
    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       enabled?: state.active? and Settings.get(:shiny_guard_enabled),
       armed_rules: length(ColorRules.armed()),
       pending?: state.streaks != %{}
     }, state}
  end

  @impl true
  def handle_info(:scan, state) do
    state =
      if state.active? and Settings.get(:shiny_guard_enabled),
        do: look(state),
        else: %{state | streaks: %{}}

    schedule(state)
    {:noreply, state}
  end

  # A kill right after a sighting IS that shiny dying (Lucas: "se eu matei um
  # Shiny"). Outside the window it is an ordinary kill — ignored.
  def handle_info(kill, state) when kill in [{:kill}, {:kill, nil}] do
    if recent_sighting?(state), do: ShinyLog.resolve_last("killed")
    {:noreply, state}
  end

  def handle_info({:kill, _corpse}, state) do
    if recent_sighting?(state), do: ShinyLog.resolve_last("killed")
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- a varredura -------------------------------------------------------------

  defp look(state) do
    case ColorRules.armed() do
      [] ->
        %{state | streaks: %{}}

      rules ->
        case snapshot(state) do
          {:ok, frame, forbidden} -> judge(state, rules, frame, forbidden)
          # Blind is not "no boss": without a frame the fact is NOT rewritten; it ages
          # on its own until the brain stops believing it.
          _blind -> state
        end
    end
  end

  defp snapshot(state) do
    with {:ok, calib} <- Calibration.load(),
         {:ok, {_x, _y, _w, _h} = region} <- SpotScan.region(calib),
         {:ok, %Frame{} = frame} <- state.capture.(region, "special_colors.raw") do
      {:ok, frame, forbidden_boxes(calib, frame, region)}
    end
  end

  # The character and the STANDING pokémon become 3×3-tile forbidden boxes: the own pokémon's
  # green can match a shiny's. Points in SCREEN coordinates; the frame knows its own scale.
  defp forbidden_boxes(calib, %Frame{scale: scale}, {rx, ry, _w, _h}) do
    meia = round(Calibration.tile_px() * 1.5 * scale)

    [calib.player_point, calib.pokemon_spot_point]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn {sx, sy} ->
      fx = round((sx - rx) * scale)
      fy = round((sy - ry) * scale)
      {fx - meia, fy - meia, fx + meia, fy + meia}
    end)
  end

  defp judge(state, rules, frame, forbidden) do
    {state, best, vistos} =
      Enum.reduce(rules, {state, 0, []}, fn rule, {state, best, vistos} ->
        result =
          ColorMark.scan(frame, rule.specs,
            min_cell_px: rule.min_cell_px,
            forbidden: forbidden
          )

        mancha = List.first(result.manchas)
        hit? = mancha != nil and mancha.px >= rule.min_px

        {advance(state, rule, mancha, hit?), max(best, result.px),
         if(hit?, do: [{rule, mancha} | vistos], else: vistos)}
      end)

    publish_special(vistos)
    broadcast_reading(state, best)
  end

  # The FACT is published on EVERY scan, not every announcement. The trophy has a one-minute
  # refractory, but the brain needs PRESENCE: while the boss is on screen `heavy?` must stand,
  # and fall when it leaves. Different questions, different clocks.
  defp publish_special(vistos) do
    WorldState.put(
      :special,
      %{
        especial?: vistos != [],
        vistos: Enum.map(vistos, fn {rule, m} -> %{name: rule.name, px: m.px, point: m.point} end)
      },
      System.monotonic_time(:millisecond)
    )
  end

  defp advance(state, rule, _mancha, false),
    do: %{state | streaks: Map.delete(state.streaks, rule.slug)}

  defp advance(state, rule, mancha, true) do
    streak = Map.get(state.streaks, rule.slug, 0) + 1
    state = %{state | streaks: Map.put(state.streaks, rule.slug, streak)}

    if streak >= Settings.get(:special_color_confirm_frames) and cooled?(state, rule.slug),
      do: fire(state, rule, mancha),
      else: state
  end

  defp cooled?(state, slug) do
    case Map.get(state.fired_at, slug) do
      nil -> true
      at -> System.monotonic_time(:millisecond) - at > @refractory_ms
    end
  end

  # Sighted: record and announce, no action here. The Catcher listens for {:shiny_seen, _} and
  # arms the guaranteed ball.
  defp fire(state, rule, mancha) do
    reason = "✨ #{rule.name} na tela — mancha de #{mancha.px}px da cor dele"

    # the trophy shelf first: the encounter is logged even if a broadcast fails.
    # `star_px` is the field's historical name (the star is gone, the field stayed): it now
    # holds the BLOB's px.
    ShinyLog.record(star_px: mancha.px, action: nil, outcome: "seen", note: rule.name)

    Phoenix.PubSub.broadcast(Pokex.PubSub, @combat_topic, {:combat_log, :macro, reason})

    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      @reading_topic,
      {:shiny_seen, %{px: mancha.px, name: rule.name, point: mancha.point}}
    )

    now = System.monotonic_time(:millisecond)

    %{
      state
      | streaks: Map.delete(state.streaks, rule.slug),
        fired_at: Map.put(state.fired_at, rule.slug, now),
        last_fired_at: now
    }
  end

  defp recent_sighting?(%{last_fired_at: nil}), do: false

  defp recent_sighting?(%{last_fired_at: at}),
    do: System.monotonic_time(:millisecond) - at <= @encounter_window_ms

  # Feed the panel's live meter — throttled so the scan cadence doesn't
  # re-render the panel several times a second.
  defp broadcast_reading(state, px) do
    now = System.monotonic_time(:millisecond)

    if state.last_reading_at == nil or now - state.last_reading_at > @reading_throttle_ms do
      Phoenix.PubSub.broadcast(Pokex.PubSub, @reading_topic, {:shiny_reading, %{px: px}})
      %{state | last_reading_at: now}
    else
      state
    end
  end

  # On, the cadence is the scan's; off (or no rule armed), a slow tick just to re-check the
  # switch.
  defp schedule(state) do
    ms =
      if state.active? and Settings.get(:shiny_guard_enabled) and ColorRules.armed() != [],
        do: Settings.get(:special_color_scan_ms),
        else: @idle_poll_ms

    Process.send_after(self(), :scan, ms)
  end
end
