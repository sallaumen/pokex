defmodule PokexWeb.DiagnosticsLiveTest do
  use PokexWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  setup do
    {:ok, _} = Pokex.Rig.Fake.start_link()
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
    calls = Enum.reject(Pokex.Rig.Fake.calls(), &match?({:cursor_position}, &1))
    assert calls == [{:press, "shift+v"}]
  end

  test "click goes straight through", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/diagnostics")

    view
    |> form("#click-form", %{"x" => "812", "y" => "402", "button" => "left"})
    |> render_submit()

    assert {:click, :left, {812, 402}} in Pokex.Rig.Fake.calls()
  end

  test "capture renders the image tag", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/diagnostics")

    html =
      view
      |> form("#capture-form", %{"x" => "0", "y" => "0", "w" => "100", "h" => "80"})
      |> render_submit()

    assert html =~ "/captures/diag.png"
    assert {:capture, {0, 0, 100, 80}, "diag.png"} in Pokex.Rig.Fake.calls()
  end

  test "invalid coordinate shows an error instead of crashing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/diagnostics")

    html =
      view
      |> form("#click-form", %{"x" => "abc", "y" => "400", "button" => "left"})
      |> render_submit()

    assert html =~ "inválid"
    refute Enum.any?(Pokex.Rig.Fake.calls(), &match?({:click, _, _}, &1))
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
        arena_region: {200, 100, 400, 400},
        neutral_point: {420, 350},
        glow_baselines: [baseline],
        suggested_glow_threshold: 15.0
      })

      %{bright: bright, calm: baseline}
    end

    @tag :tmp_dir
    test "glow panel counts the cyan bubble pixels", %{conn: conn, bright: bright} do
      # a region full of bright-cyan pixels → over the bubble threshold → a bite
      Agent.update(Pokex.Rig.Fake, fn state ->
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

      Agent.update(Pokex.Rig.Fake, fn state ->
        %{state | script: %{capture: [{:ok, strip}]}}
      end)

      {:ok, view, _} = live(conn, ~p"/diagnostics")
      view |> element("button", "Pokébola presente?") |> render_click()
      assert render(view) =~ "pokébola: true"
    end
  end
end
