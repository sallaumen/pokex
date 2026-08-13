defmodule PokexWeb.DiagnosticsLiveTest do
  use PokexWeb.ConnCase, async: false

  alias Pokex.Rig.Fake
  import Phoenix.LiveViewTest

  setup do
    {:ok, _} = Fake.start_link()
    :ok
  end

  test "press is delayed then executed through the rig", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/diagnostics")

    view |> element("button[phx-value-combo='shift+v']") |> render_click()
    assert render(view) =~ "em 2s"

    send(view.pid, {:delayed_press, "shift+v"})
    assert render(view) =~ "press shift+v → :ok"

    # Filter out {:cursor_position} — the app-wide Guardian polls the panic
    # corner on its own timer against this same shared Rig.Fake, and its
    # reads may land in this window. What this test actually asserts is that
    # OUR delayed press ran.
    calls = Enum.reject(Fake.calls(), &match?({:cursor_position}, &1))
    assert calls == [{:press, "shift+v"}]
  end

  # The measurement itself, end to end: the two rounds are drained APART (the
  # plain key rides the native path alone, then rides osascript alongside the
  # shifted ones), so a silent shift cannot hide behind a working "1".
  describe "measuring whether the stance keys leave this machine" do
    # The Fake replays SCRIPTED LISTS; a bare tuple silently falls through to
    # its default of "saw nothing", which is the reading this whole card exists
    # to distinguish from a real silence.
    defp watcher_sees(events) do
      Agent.stop(Fake)
      {:ok, _} = Fake.start_link(%{key_watch: [{:ok, events}]})
    end

    defp seen(code, shift?), do: %{code: code, shift?: shift?, at: 0}

    # Scoped to the card: the prose around it talks ABOUT the verdicts, and a
    # test matching the explanation instead of the reading proves nothing.
    defp verdicts(view), do: view |> element("#key-probe") |> render()

    # The read comes back from a Task that lets the keys land first, so the
    # test hands the round its reading directly rather than waiting out a
    # wall-clock settle it would then have to guess the length of.
    defp reading(view, stage, combos, next \\ nil) do
      send(view.pid, {:probe_read, stage, combos, next})
      verdicts(view)
    end

    test "arming a round drains the watcher and fires the burst", %{conn: conn} do
      watcher_sees([])
      {:ok, view, _html} = live(conn, ~p"/diagnostics")

      view |> element("button[phx-click='probe_keys']") |> render_click()
      assert render(view) =~ "Medindo em"

      send(view.pid, :probe_native)
      assert render(view) =~ "disparando 1"
      assert {:key_watch, [18]} in Fake.calls()

      # the osascript round arms BOTH digits, because both ride that road
      send(view.pid, :probe_osa)
      assert render(view) =~ "disparando 1, shift+1, shift+3"
      assert {:key_watch, [18, 20]} in Fake.calls()
    end

    test "a shift that never left is named, not hidden by the plain key", %{conn: conn} do
      # code 18 is "1" and it arrived; nothing ever arrived for shift+1 / shift+3
      watcher_sees([seen(18, false)])
      {:ok, view, _html} = live(conn, ~p"/diagnostics")

      view |> element("button[phx-click='probe_keys']") |> render_click()
      html = reading(view, :osa, ["1", "shift+1", "shift+3"])

      assert html =~ "saiu inteira"
      assert html =~ "não saiu"
    end

    # The expensive one to miss: the game would read a bare "1" and fire the
    # skill bound to it instead of switching stance.
    test "a shift that got stripped on the way reads as NAKED, not as success", %{conn: conn} do
      watcher_sees([seen(18, false), seen(20, false)])
      {:ok, view, _html} = live(conn, ~p"/diagnostics")

      view |> element("button[phx-click='probe_keys']") |> render_click()
      html = reading(view, :osa, ["1", "shift+1", "shift+3"])

      assert html =~ "saiu SEM o shift"
      refute html =~ "não saiu"
    end

    test "a watcher that cannot answer says so instead of blaming the keys", %{conn: conn} do
      Agent.stop(Fake)
      {:ok, _} = Fake.start_link(%{key_watch: [{:error, :untrusted}]})
      {:ok, view, _html} = live(conn, ~p"/diagnostics")

      view |> element("button[phx-click='probe_keys']") |> render_click()
      html = reading(view, :native, ["1"])

      assert html =~ "A leitura falhou"
      refute html =~ "não saiu"
    end

    # The first round must hand the baton to the second on its own — a probe
    # that measured only the native path would say nothing about the shift.
    test "the native round chains into the osascript one", %{conn: conn} do
      watcher_sees([])
      {:ok, view, _html} = live(conn, ~p"/diagnostics")

      view |> element("button[phx-click='probe_keys']") |> render_click()
      reading(view, :native, ["1"], :probe_osa)

      assert render(view) =~ "disparando 1, shift+1, shift+3"
    end
  end

  test "click goes straight through", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/diagnostics")

    view
    |> form("#click-form", %{"x" => "812", "y" => "402", "button" => "left"})
    |> render_submit()

    assert {:click, :left, {812, 402}} in Fake.calls()
  end

  test "capture renders the image tag", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/diagnostics")

    html =
      view
      |> form("#capture-form", %{"x" => "0", "y" => "0", "w" => "100", "h" => "80"})
      |> render_submit()

    assert html =~ "/captures/diag.png"
    assert {:capture, {0, 0, 100, 80}, "diag.png"} in Fake.calls()
  end

  test "invalid coordinate shows an error instead of crashing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/diagnostics")

    html =
      view
      |> form("#click-form", %{"x" => "abc", "y" => "400", "button" => "left"})
      |> render_submit()

    assert html =~ "inválid"
    refute Enum.any?(Fake.calls(), &match?({:click, _, _}, &1))
  end

  describe "vision panels (calibrated)" do
    defp rows(w, h, color), do: List.duplicate(List.duplicate(color, w), h)

    setup %{tmp_dir: tmp} do
      Application.put_env(:pokex, :home_dir, tmp)
      on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

      # Pin the bite threshold below the bright-cyan fixture so "mordida? true"
      # is deterministic. Settings is a shared named GenServer, so without this the
      # test silently rode on whatever glow_threshold an earlier test file left
      # behind — passing or failing purely on run order. Restore the default after.
      Pokex.Settings.put(:glow_threshold, 15.0)

      on_exit(fn ->
        Pokex.Settings.put(:glow_threshold, Pokex.Settings.defaults().glow_threshold)
      end)

      baseline =
        Pokex.PngFixtures.write!(Path.join(tmp, "base.png"), rows(8, 8, {0, 60, 120, 255}))

      bright =
        Pokex.PngFixtures.write!(
          Path.join(tmp, "bright.png"),
          for y <- 0..31 do
            for x <- 0..31 do
              if x in 12..19 and y in 12..19,
                do: {210, 55, 30, 255},
                else: {40, 180, 220, 255}
            end
          end
        )

      Pokex.Calibration.save(%Pokex.Calibration{
        scale: 2.0,
        screen_w: 1000,
        screen_h: 700,
        water_point: {400, 300},
        glow_region: {368, 268, 64, 64},
        battle_region: {700, 100, 260, 200},
        neutral_point: {420, 350}
      })

      %{bright: bright, calm: baseline}
    end

    @tag :tmp_dir
    test "glow panel counts the cyan bubble pixels", %{conn: conn, bright: bright} do
      # a region full of bright-cyan pixels → over the bubble threshold → a bite
      Agent.update(Fake, fn state ->
        %{state | script: %{capture: [{:ok, bright}]}}
      end)

      {:ok, view, _} = live(conn, ~p"/diagnostics")
      view |> element("button", "Bolhas (ciano)") |> render_click()
      assert render(view) =~ "mordida? true"
    end

    @tag :tmp_dir
    test "wild panel reads battle strip", %{conn: conn, tmp_dir: tmp} do
      strip_rows =
        for y <- 0..99 do
          for x <- 0..29 do
            if x in 10..17 and y in 20..23, do: {230, 40, 40, 255}, else: {30, 30, 30, 255}
          end
        end

      strip = Pokex.PngFixtures.write!(Path.join(tmp, "strip.png"), strip_rows)

      Agent.update(Fake, fn state ->
        %{state | script: %{capture: [{:ok, strip}]}}
      end)

      {:ok, view, _} = live(conn, ~p"/diagnostics")
      view |> element("button", "Pokébola presente?") |> render_click()
      assert render(view) =~ "pokébola: true"
    end
  end
end
