defmodule PokexWeb.HeaderState do
  @moduledoc """
  Keeps the app header alive on EVERY page.

  The header is the same on every page (brand, focus warning, active
  character, running/stopped, navigation), so its state cannot live inside a
  single LiveView: it is mounted once here, for the whole `live_session`.

  Message ownership is split on purpose. The Panel already subscribes to the
  worker topics because it needs the whole snapshot (cards and error alarm);
  subscribing again here would deliver every message to it TWICE. On the
  panel this hook only rides along on what the panel already receives and
  passes the message on (`:cont`); on the other pages it subscribes and stops
  the message here (`:halt`) — a page with no clause for `{:fishing, _}`
  would raise FunctionClauseError in `handle_info/2`.
  """
  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]

  alias Pokex.Bots.AlarmCategories
  alias Pokex.Bots.BotSupervisor
  alias Pokex.Bots.Focus
  alias Pokex.Characters
  alias Pokex.Settings

  @focus_topic "focus"
  # The fleet the pill represents: the three workers whose state means "the
  # bot is working". The cavebot walks its route with combat OFF between
  # fights, so without it in this list the header swore "Parado" while the
  # bot was hunting.
  @worker_topics ["fishing", "combat", "cavebot"]

  def on_mount(:default, _params, _session, socket) do
    owns_workers? = socket.view != PokexWeb.PanelLive

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Pokex.PubSub, @focus_topic)

      if owns_workers?,
        do: Enum.each(@worker_topics, &Phoenix.PubSub.subscribe(Pokex.PubSub, &1))
    end

    socket =
      socket
      |> assign(
        header_owns_workers?: owns_workers?,
        focused?: focused?(),
        characters: Characters.list(),
        active_character: Characters.active(),
        alarm_sound: Settings.get(:alarm_sound),
        alarm_muted_categories: Settings.get(:alarm_muted_categories)
      )
      |> sync_workers(BotSupervisor.status())
      |> attach_hook(:header_state, :handle_info, &info/2)
      |> attach_hook(:header_events, :handle_event, &event/3)

    {:cont, socket}
  end

  @doc """
  Realigns the running/stopped pill with a freshly read `BotSupervisor.status()`.

  The panel changes worker state by direct action (Start/Stop) and reassigns
  the status immediately; without this the header would only find out on the
  next broadcast — clicking "Iniciar" would read "Parado" for a tick.
  """
  def sync_workers(socket, status) do
    socket
    |> assign(:header_states, %{
      fishing: status.fishing.state,
      combat: status.combat.state,
      cavebot: status.cavebot.state
    })
    |> assign_bot_active()
  end

  defp info({:focus, %{focused?: focused?}}, socket),
    do: {:halt, assign(socket, focused?: focused?)}

  defp info({:fishing, %{state: state}}, socket), do: worker_state(socket, :fishing, state)
  defp info({:combat, %{state: state}}, socket), do: worker_state(socket, :combat, state)
  defp info({:cavebot, %{state: state}}, socket), do: worker_state(socket, :cavebot, state)

  # The REST of the traffic on the topics THIS hook subscribed to — logs and
  # alarms riding along with the snapshots ({:fishing_log, _, _},
  # {:rule_alarm, _}...) — dies here on non-panel pages: the page didn't ask
  # for those messages and has no clause for them (with the bot fishing and
  # the calibration page open, every log was a FunctionClauseError taking the
  # LiveView down — 2026-07-30). On the panel (:cont) everything flows on to
  # its handlers, which subscribed on their own.
  @worker_noise [:fishing_log, :combat_log, :cavebot_log, :cavebot_alarm, :rule_alarm]

  defp info(msg, socket)
       when is_tuple(msg) and tuple_size(msg) >= 1 and elem(msg, 0) in @worker_noise,
       do: {if(socket.assigns.header_owns_workers?, do: :halt, else: :cont), socket}

  defp info(_msg, socket), do: {:cont, socket}

  defp worker_state(socket, key, state) do
    socket =
      socket
      |> assign(:header_states, Map.put(socket.assigns.header_states, key, state))
      |> assign_bot_active()

    {if(socket.assigns.header_owns_workers?, do: :halt, else: :cont), socket}
  end

  defp event("set_character", %{"character" => slug}, socket) do
    :ok = Characters.set_active(slug)
    {:halt, assign(socket, active_character: slug)}
  end

  defp event("create_character", %{"name" => name}, socket) do
    case Characters.create(name) do
      {:ok, slug} ->
        :ok = Characters.set_active(slug)
        {:halt, assign(socket, characters: Characters.list(), active_character: slug)}

      {:error, _reason} ->
        {:halt, socket}
    end
  end

  # Master sound: silences EVERYTHING at once without touching the individual
  # sectors — re-enabling it restores the per-sector state exactly as it was.
  defp event("toggle_alarm_sound", _params, socket) do
    next = not Settings.get(:alarm_sound)
    Settings.put(:alarm_sound, next)
    {:halt, assign(socket, alarm_sound: next)}
  end

  # Per-SECTOR mute (2026-07-30): "command corner"/"session" tend to be the
  # noisy ones; Shiny is the one he always wants on. `from_string/1` rejects
  # anything that is not a known sector — a click never writes garbage to
  # disk (same boundary as Settings.put/3).
  defp event("toggle_alarm_category", %{"category" => category_text}, socket) do
    if AlarmCategories.from_string(category_text) do
      current = Settings.get(:alarm_muted_categories)

      next =
        if category_text in current,
          do: List.delete(current, category_text),
          else: [category_text | current]

      Settings.put(:alarm_muted_categories, next)
      {:halt, assign(socket, alarm_muted_categories: next)}
    else
      {:halt, socket}
    end
  end

  defp event(_event, _params, socket), do: {:cont, socket}

  # The Catcher is left out on purpose: in "movimento" mode it always reports
  # :manual — a display choice, not a running signal. Same rule as the panel.
  # What counts as RUNNING has one ruler, BotSupervisor.active?/1 — the
  # hunt's stop states (:blocked/:stuck/:fight_stalled) do NOT light it up.
  defp assign_bot_active(socket) do
    assign(
      socket,
      :bot_active?,
      BotSupervisor.any_active?(Map.values(socket.assigns.header_states))
    )
  end

  # The focus poller may not have published anything yet at mount; ask
  # directly (fail toward "focused" so the pause warning never shows idly).
  defp focused? do
    Focus.status().focused?
  catch
    _kind, _reason -> true
  end
end
