defmodule PokexWeb.AppHeaderTest do
  @moduledoc """
  The header must be the same on EVERY page. A test per page misses drift;
  sweeping every route for the same markers is what catches it.
  """
  use PokexWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias PokexWeb.Layouts

  @routes [
    {"/", :panel},
    {"/calibration", :calibration},
    {"/diagnostics", :diagnostics},
    {"/fishing-lab", :fishing_lab},
    {"/mini-game", :mini_game},
    {"/world", :world},
    {"/cavebot", :cavebot},
    {"/pokedex", :pokedex},
    {"/time", :team}
  ]

  @nav_ids ~w(
    app-nav-panel app-nav-config app-nav-calibration app-nav-diagnostics
    app-nav-fishing-lab app-nav-mini-game app-nav-world app-nav-cavebot
    app-nav-timers app-nav-pokedex app-nav-team
  )

  test "every page mounts the same header", %{conn: conn} do
    for {path, _page} <- @routes do
      {:ok, view, html} = live(conn, path)

      assert has_element?(view, "#app-header"), "#{path} is missing the standard header"
      assert html =~ "Pokex", "#{path} does not show the app name at the top"
      assert has_element?(view, "#character-picker"), "#{path} is missing the active character"
      assert has_element?(view, "#app-bot-state"), "#{path} does not say if the bot is running"

      assert has_element?(view, "#app-alarm-toggle"),
             "#{path} is missing the alarm sound control"

      assert has_element?(view, "#app-navigation-toggle"),
             "#{path} is missing the navigation"

      for id <- @nav_ids do
        assert has_element?(view, "##{id}"), "#{path}: #{id} missing from the menu"
      end
    end
  end

  test "the menu comes grouped, with Painel and the ⚙️ above the groups", %{conn: conn} do
    # the structure first: a destination landing in two groups (or in none) is
    # exactly the kind of mistake that survives a read of the markup
    grouped = Enum.flat_map(Layouts.nav_groups(), fn {_title, entries} -> entries end)
    keys = Enum.map(grouped, fn {key, _label, _icon} -> key end)
    titles = Enum.map(Layouts.nav_groups(), fn {title, _entries} -> title end)
    top_keys = Enum.map(Layouts.nav_top(), fn {key, _label, _icon} -> key end)
    labels = Enum.map(Layouts.nav_items(), fn {_key, label, _icon} -> label end)

    assert titles == ["Pokémon", "No jogo", "Máquina"]
    assert top_keys == [:panel, :config]
    assert keys == Enum.uniq(keys), "a destination shows up in more than one group"
    refute Enum.any?(top_keys, &(&1 in keys)), "an ungrouped destination is also inside a group"
    assert Layouts.nav_items() == Layouts.nav_top() ++ grouped
    assert length(Layouts.nav_items()) == length(@nav_ids)

    # a group header repeating a destination's label reads as a duplicate when
    # the item is right under it, and misleads when the item is somewhere else
    for title <- titles do
      refute title in labels, "the group #{title} has the same name as a menu item"
    end

    for {path, _page} <- @routes, title <- titles do
      {:ok, _view, html} = live(conn, path)
      assert html =~ title, "#{path}: the menu does not show the group #{title}"
    end
  end

  test "nothing in the header freezes its own subtree from the patcher", %{conn: conn} do
    for {path, _page} <- @routes do
      {:ok, view, _html} = live(conn, path)

      # `phx-update="ignore"` makes morphdom skip the element's WHOLE subtree
      # (phoenix_live_view 1.2.5, dom_patch.ts: an ignored element returns
      # false from onBeforeElUpdated and only data-* is merged), so whatever
      # rendered at mount is frozen for the life of that mount. On the menu it
      # was there to protect the <details> open state — which app.js already
      # mirrors globally for EVERY <details>, which is why the alarm menu and
      # the character popover right beside it never needed it.
      #
      # Today `current_page` is a literal per LiveView, so nothing is visibly
      # wrong. The day a header control becomes conditional, an ignored menu
      # would stop following it without a single error to show for it.
      for id <- ~w(app-navigation app-alarm-menu character-manager) do
        refute has_element?(view, ~s(##{id}[phx-update="ignore"])),
               "#{path}: ##{id} is ignored by the patcher — its content cannot follow the page"
      end
    end
  end

  test "the menu marks the page you are on", %{conn: conn} do
    for {path, page} <- @routes do
      {:ok, view, _html} = live(conn, path)
      id = "app-nav-" <> String.replace(to_string(page), "_", "-")

      assert has_element?(view, "##{id}[aria-current=page]"),
             "#{path} does not mark itself as the current page in the menu"
    end
  end

  test "no page offers theme switching", %{conn: conn} do
    for {path, _page} <- @routes do
      {:ok, _view, html} = live(conn, path)

      refute html =~ "data-phx-theme", "#{path} still has the theme button"
      refute html =~ "phx:set-theme", "#{path} still triggers theme switching"
      refute html =~ ~s(data-theme="light"), "#{path} can still go light"
    end
  end

  test "the dark theme is pinned on the document, without a script", %{conn: conn} do
    html = conn |> get("/") |> html_response(200)

    assert html =~ ~s(lang="pt-br")
    assert html =~ ~s(data-theme="dark")
    refute html =~ "phx:theme"
  end

  test "the running/stopped pill follows the workers outside the panel", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/pokedex")
    assert view |> element("#app-bot-state") |> render() =~ "Parado"

    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      "fishing",
      {:fishing, %{state: :fishing, counters: %{}, error: nil}}
    )

    assert render(view) =~ "Ativo"
  end

  # the header follows the same fleet snapshot as the panel, with the same rule:
  # walking lights it up, stopped-with-reason never does
  test "a walking hunt shows Ativo in the header; a blocked one shows Parado", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/pokedex")
    assert view |> element("#app-bot-state") |> render() =~ "Parado"

    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      "cavebot",
      {:cavebot, %{state: :walking, wp_index: 2, wp_total: 9, counters: %{}}}
    )

    assert eventually_renders(view, "Ativo")

    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      "cavebot",
      {:cavebot, %{state: :blocked, wp_index: 2, wp_total: 9, counters: %{}}}
    )

    assert eventually_renders(view, "Parado")
  end

  defp eventually_renders(view, text, tries \\ 50) do
    cond do
      view |> element("#app-bot-state") |> render() =~ text -> true
      tries == 0 -> false
      true -> Process.sleep(10) && eventually_renders(view, text, tries - 1)
    end
  end

  # 2026-07-30: {:fishing_log, _, _} rides the same topic as snapshots and hit
  # LiveViews with no clause for it — a FunctionClauseError took the page down;
  # the header hook that subscribed now swallows what the page did not ask for
  test "worker noise (logs/alarms) does not crash any page", %{conn: conn} do
    noise = [
      {"fishing", {:fishing_log, :debug, "delay 532ms → kill corner — parado"}},
      {"fishing", {:fishing_log, "legado de 2 elementos"}},
      {"combat", {:combat_log, :macro, "combate: alvo na lista; Tab"}},
      {"combat", {:rule_alarm, "🎣 3 arremessos sem NENHUMA bolha"}},
      {"cavebot", {:cavebot_log, :macro, "caçada: passo"}},
      {"cavebot", {:cavebot_alarm, "algo estranho"}}
    ]

    for {path, _page} <- @routes do
      {:ok, view, _html} = live(conn, path)

      for {topic, msg} <- noise do
        Phoenix.PubSub.broadcast(Pokex.PubSub, topic, msg)
      end

      Phoenix.PubSub.broadcast(
        Pokex.PubSub,
        "fishing",
        {:fishing, %{state: :fishing, counters: %{}, error: nil}}
      )

      assert eventually_renders(view, "Ativo"), "#{path} died under worker noise"

      Phoenix.PubSub.broadcast(
        Pokex.PubSub,
        "fishing",
        {:fishing, %{state: :idle, counters: %{}, error: nil}}
      )
    end
  end

  @tag :tmp_dir
  # Settings is a global cache: leaving :active_character set makes a later
  # Settings.put rewrite the test-home file with this character, and Team.file()
  # then points at chars/<slug>/team.json in future runs — reset before releasing
  # home_dir
  test "switching characters works outside the panel", %{conn: conn, tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)

    on_exit(fn ->
      Pokex.Characters.set_active("")
      Application.delete_env(:pokex, :home_dir)
    end)

    {:ok, slug} = Pokex.Characters.create("Header Teste")

    {:ok, view, _html} = live(conn, "/world")

    view
    |> form("#character-picker-form", %{"character" => slug})
    |> render_change()

    assert Pokex.Characters.active() == slug
  end

  test "the lost-focus badge appears on any page", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/diagnostics")
    refute has_element?(view, "#focus-pause-badge")

    Phoenix.PubSub.broadcast(Pokex.PubSub, "focus", {:focus, %{focused?: false}})
    assert has_element?(view, "#focus-pause-badge")

    Phoenix.PubSub.broadcast(Pokex.PubSub, "focus", {:focus, %{focused?: true}})
    refute has_element?(view, "#focus-pause-badge")
  end

  test "the Pokédex shows Pokex at the top and syncs the wiki from the page body", %{conn: conn} do
    {:ok, view, html} = live(conn, "/pokedex")

    assert has_element?(view, "#pokedex-tools #sync-form")
    refute has_element?(view, "#app-header #sync-form")

    assert html =~ "Pokex"
    assert has_element?(view, "#app-page-label")
  end

  describe "alarm sound (header)" do
    # the general sound toggle lives in the HEADER (visible on any page) plus
    # per-sector switches; it replaces the panel-only button and works on any route
    test "the general sound toggles on any page — the same global setting", %{
      conn: conn
    } do
      sound = Pokex.Settings.get(:alarm_sound)
      on_exit(fn -> Pokex.Settings.put(:alarm_sound, sound) end)
      Pokex.Settings.put(:alarm_sound, true)

      {:ok, view, _html} = live(conn, "/pokedex")
      assert has_element?(view, "#app-alarm-sound-toggle", "ligado")

      view |> element("#app-alarm-sound-toggle") |> render_click()

      assert has_element?(view, "#app-alarm-sound-toggle", "mudo")
      refute Pokex.Settings.get(:alarm_sound)

      view |> element("#app-alarm-sound-toggle") |> render_click()
      assert has_element?(view, "#app-alarm-sound-toggle", "ligado")
      assert Pokex.Settings.get(:alarm_sound)
    end

    test "a sector toggles alone, touching neither the general sound nor other sectors", %{
      conn: conn
    } do
      muted = Pokex.Settings.get(:alarm_muted_categories)
      on_exit(fn -> Pokex.Settings.put(:alarm_muted_categories, muted) end)
      Pokex.Settings.put(:alarm_muted_categories, [])

      {:ok, view, _html} = live(conn, "/world")

      view
      |> element("#app-alarm-category-stock input")
      |> render_click(%{"category" => "stock"})

      assert Pokex.Settings.get(:alarm_muted_categories) == ["stock"]
      refute has_element?(view, "#app-alarm-category-stock input[checked]")
      assert has_element?(view, "#app-alarm-category-shiny input[checked]")
      assert Pokex.Settings.get(:alarm_sound)

      view
      |> element("#app-alarm-category-stock input")
      |> render_click(%{"category" => "stock"})

      assert Pokex.Settings.get(:alarm_muted_categories) == []
      assert has_element?(view, "#app-alarm-category-stock input[checked]")
    end

    test "an unknown category is never persisted — the Settings boundary still holds",
         %{conn: conn} do
      muted = Pokex.Settings.get(:alarm_muted_categories)
      on_exit(fn -> Pokex.Settings.put(:alarm_muted_categories, muted) end)
      Pokex.Settings.put(:alarm_muted_categories, [])

      {:ok, view, _html} = live(conn, "/")

      render_click(view, "toggle_alarm_category", %{"category" => "invente-se"})

      assert Pokex.Settings.get(:alarm_muted_categories) == []
    end
  end

  describe "a calibração é de outra tela" do
    # THE field bug (Lucas, 2026-08-10): back from the MacBook to the two
    # monitors — "o tamanho da minha tela era diferente da última calibragem,
    # nada me foi avisado". The warning existed, inside /calibration only, so
    # opening the app and going straight to the panel said nothing while every
    # coordinate the bot aimed at belonged to the other screen.
    #
    # The display comes from the broker's lock-free copy: this key is the
    # contract between `Pokex.Bots.Capture`'s writer and its reader.
    @display_key {Pokex.Bots.Capture, :display_points}

    setup %{tmp_dir: tmp} do
      Application.put_env(:pokex, :home_dir, tmp)

      on_exit(fn ->
        Application.delete_env(:pokex, :home_dir)
        :persistent_term.erase(@display_key)
      end)

      :ok
    end

    defp calibrated_on(w, h) do
      Pokex.Calibration.save(%Pokex.Calibration{
        scale: 1.0,
        screen_w: w,
        screen_h: h,
        neutral_point: {10, 10}
      })
    end

    @tag :tmp_dir
    test "every page says so, and offers the way out", %{conn: conn} do
      calibrated_on(3440, 1440)
      :persistent_term.put(@display_key, {:ok, {1512, 982}})

      for {path, page} <- @routes do
        {:ok, view, html} = live(conn, path)

        assert has_element?(view, "#screen-mismatch-strip"),
               "#{path} does not warn that the calibration is from another screen"

        assert html =~ "3440×1440", "#{path} does not say which screen it was marked on"
        assert html =~ "1512×982", "#{path} does not say which screen this is"

        # on the calibration page the fix is already on screen — a "Resolver"
        # pointing at the page you are already on is noise
        if page == :calibration,
          do: refute(has_element?(view, "#screen-mismatch-fix")),
          else: assert(has_element?(view, "#screen-mismatch-fix"))
      end
    end

    @tag :tmp_dir
    test "same screen, no strip — and no proof is silence, not an alarm", %{conn: conn} do
      calibrated_on(1512, 982)
      :persistent_term.put(@display_key, {:ok, {1512, 982}})

      {:ok, view, _html} = live(conn, "/")
      refute has_element?(view, "#screen-mismatch-strip")

      # a wedged backend has no opinion about the screen
      :persistent_term.put(@display_key, :unknown)
      {:ok, view, _html} = live(conn, "/")
      refute has_element?(view, "#screen-mismatch-strip")
    end
  end
end
