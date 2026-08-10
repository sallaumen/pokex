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

  Switching character also passes through here: the header listens on
  `Pokex.Characters.topic/0` and asks the page to reload itself via
  `PokexWeb.CharacterAware` — including a tab parked on another page, which
  used to keep showing the previous character's data indefinitely.
  """
  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, put_flash: 3]

  alias Pokex.Bots.AlarmCategories
  alias Pokex.Bots.BotSupervisor
  alias Pokex.Bots.Capture
  alias Pokex.Bots.Focus
  alias Pokex.Calibration
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
      Phoenix.PubSub.subscribe(Pokex.PubSub, Characters.topic())

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
        alarm_muted_categories: Settings.get(:alarm_muted_categories),
        screen_check: screen_check()
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

  # `screen_check` is a SHARED assign on purpose: this hook seeds it for every
  # page, and the calibration page overwrites it with the reading from the
  # screenshot it just took. One name, so a mismatch fixed there clears the
  # strip on the click instead of on the next page load.
  #
  # Reads the display from the broker's lock-free copy, never with a call: this
  # runs on EVERY mount, and the broker is busy for seconds at a time while the
  # bot works. No proof (:unknown) shows nothing — a strip that cries wolf on a
  # missing reading would be worse than the silence it replaces.
  defp screen_check do
    case Calibration.load() do
      {:ok, calib} -> Calibration.screen_check(calib, Capture.display_points_cached())
      _no_calibration -> :unknown
    end
  catch
    _kind, _reason -> :unknown
  end

  defp info({:focus, %{focused?: focused?}}, socket),
    do: {:halt, assign(socket, focused?: focused?)}

  # ALWAYS `:halt`: no page handles `{:character, _}` in its own
  # `handle_info/2` — whoever owns character data implements
  # `PokexWeb.CharacterAware` and is called from here. Letting it through would
  # raise FunctionClauseError on every page that does not know the message.
  #
  # The flash is skipped when the socket already carries this slug: that is the
  # echo of a switch THIS tab just made through an event, which flashed its own
  # (more precise) message. What is left is the case worth announcing — the
  # active character changed from somewhere else.
  defp info({:character, slug}, socket) do
    echo? = socket.assigns.active_character == slug
    socket = apply_character(socket, slug)
    {:halt, if(echo?, do: socket, else: flash_switch(socket, slug))}
  end

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
    {:halt, socket |> apply_character(slug) |> flash_switch(slug)}
  end

  defp event("create_character", %{"name" => name}, socket) do
    case Characters.create(name) do
      {:ok, slug} ->
        :ok = Characters.set_active(slug)
        {:halt, socket |> apply_character(slug) |> flash_switch(slug)}

      {:error, reason} ->
        {:halt, put_flash(socket, :error, create_error(name, reason))}
    end
  end

  # Renaming and deleting existed in `Pokex.Characters` from the start with no
  # way to reach them: a character created with a typo was permanent as far as
  # the app was concerned. Both live in the header's character popover, next to
  # the picker they affect.
  defp event("rename_character", %{"slug" => slug, "name" => name}, socket) do
    case Characters.rename(slug, name) do
      {:ok, new_slug} ->
        socket = apply_character(socket, Characters.active())
        {:halt, put_flash(socket, :info, "Agora chama #{display_name(socket, new_slug)}")}

      {:error, reason} ->
        {:halt, put_flash(socket, :error, create_error(name, reason))}
    end
  end

  defp event("delete_character", %{"slug" => slug}, socket) do
    name = display_name(socket, slug)
    :ok = Characters.delete(slug)

    socket = apply_character(socket, Characters.active())
    {:halt, put_flash(socket, :info, "#{name} apagado")}
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

  # Applied on BOTH paths (the switch made here and the announcement arriving
  # over PubSub) on purpose: the switch must not depend on the broadcast coming
  # back, and the broadcast is what makes a parked tab follow a switch made
  # somewhere else. Re-applying is harmless — everything here re-reads its source.
  defp apply_character(socket, slug) do
    socket
    |> assign(characters: Characters.list(), active_character: slug)
    |> reload_page()
  end

  defp reload_page(socket) do
    view = socket.view

    if Code.ensure_loaded?(view) and function_exported?(view, :on_character_change, 1) do
      view.on_character_change(socket)
    else
      socket
    end
  end

  defp flash_switch(socket, ""),
    do: put_flash(socket, :info, "Sem personagem — de volta ao time compartilhado")

  defp flash_switch(socket, slug),
    do: put_flash(socket, :info, "Agora você é #{display_name(socket, slug)}")

  defp display_name(socket, slug) do
    Enum.find_value(socket.assigns.characters, slug, &(&1.slug == slug && &1.name))
  end

  defp create_error(name, :invalid_name),
    do: "\"#{name}\" não vira um nome — usa letras ou números"

  defp create_error(name, :already_exists), do: "já existe um personagem chamado #{name}"
  defp create_error(_name, :not_found), do: "esse personagem não existe mais"

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
