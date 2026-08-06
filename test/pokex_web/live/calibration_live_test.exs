defmodule PokexWeb.CalibrationLiveTest do
  use PokexWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Pokex.Bots.Catcher.CorpseLibrary
  alias Pokex.Bots.Catcher.SpotScan
  alias Pokex.Calibration
  alias Pokex.Rig.Fake
  alias Pokex.Settings

  setup do
    count = Settings.get(:skill_bar_count)
    order = Settings.get(:skill_keys)

    on_exit(fn ->
      Settings.put(:skill_bar_count, count)
      Settings.put(:skill_keys, order)
    end)

    :ok
  end

  defp rows(w, h, color), do: List.duplicate(List.duplicate(color, w), h)

  @tag :tmp_dir
  # click-to-zoom: every point takes a rough click (magnifies) then a precise click (records)
  test "full wizard produces a saved calibration", %{conn: conn, tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)
    Settings.put(:skill_keys, ["6", "5", "4", "3", "2", "1"])

    probe = Pokex.PngFixtures.write!(Path.join(tmp, "probe.png"), rows(200, 200, {9, 9, 9, 255}))

    screen =
      Pokex.PngFixtures.write!(Path.join(tmp, "screen.png"), rows(200, 150, {9, 9, 9, 255}))

    glow = Pokex.PngFixtures.write!(Path.join(tmp, "glow.png"), rows(8, 8, {0, 60, 120, 255}))

    {:ok, _} =
      Fake.start_link(%{
        capture: [{:ok, probe}, {:ok, glow}],
        capture_screen: [{:ok, screen}]
      })

    {:ok, view, _html} = live(conn, ~p"/calibration")

    view
    |> form("#skill-count-form", skill_bar: %{count: "8"})
    |> render_change()

    view |> element("button", "Capturar tela") |> render_click()
    assert render(view) =~ "PONTO DA ÁGUA"

    click = fn x, y ->
      params = %{"x" => x, "y" => y, "cw" => 50.0, "ch" => 37.5, "nw" => 200.0, "nh" => 150.0}
      render_hook(view, "img_click", params)
      render_hook(view, "img_click", params)
    end

    click.(25.0, 15.0)
    assert render(view) =~ "SUPERIOR-ESQUERDO"
    click.(35.0, 5.0)
    click.(45.0, 20.0)
    click.(26.0, 18.0)

    assert render(view) =~ "Passo 5/10"
    assert render(view) =~ "PERSONAGEM"
    click.(20.0, 16.0)

    assert render(view) =~ "Passo 6/10"
    click.(5.0, 30.0)
    assert render(view) =~ "Passo 7/10"
    click.(29.0, 35.0)

    assert render(view) =~ "Passo 8/10"
    click.(15.0, 20.0)
    click.(45.0, 30.0)
    assert render(view) =~ "Passo 10/10"

    # the last click IS the end — no more "cast the line and wait" step
    click.(20.0, 25.0)

    assert render(view) =~ "Calibração salva"

    assert {:ok, calib} = Calibration.load()
    assert calib.scale == 2.0
    assert calib.screen_w == 100
    assert calib.screen_h == 75
    assert calib.water_point == {50, 30}
    assert calib.glow_region == {18, -2, 64, 64}
    assert calib.battle_region == {70, 10, 20, 30}
    assert calib.neutral_point == {52, 36}
    assert calib.player_point == {40, 32}
    assert calib.skill_bar_region == {10, 60, 48, 10}
    assert calib.skill_bar_count == 8
    assert calib.pokemon_hp_region == {30, 40, 60, 20}
    assert calib.pokemon_photo_point == {40, 50}
    assert length(calib.skill_slot_refs) == 8
    assert Enum.all?(calib.skill_slot_refs, &(&1 == {9, 9, 9}))
    assert Settings.get(:skill_keys) == ["6", "5", "4", "3", "2", "1", "7", "8"]
  end

  @tag :tmp_dir
  test "review draws the saved regions over a fresh screenshot", %{conn: conn, tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

    Calibration.save(%Calibration{
      scale: 2.0,
      screen_w: 100,
      screen_h: 75,
      water_point: {50, 30},
      glow_region: {18, -2, 64, 64},
      battle_region: {70, 10, 20, 30},
      skill_bar_region: {10, 60, 50, 10},
      skill_bar_count: 6,
      neutral_point: {52, 36}
    })

    probe = Pokex.PngFixtures.write!(Path.join(tmp, "probe.png"), rows(200, 200, {9, 9, 9, 255}))

    screen =
      Pokex.PngFixtures.write!(Path.join(tmp, "screen.png"), rows(200, 150, {9, 9, 9, 255}))

    {:ok, _} =
      Fake.start_link(%{
        capture: [{:ok, probe}],
        capture_screen: [{:ok, screen}]
      })

    {:ok, view, _html} = live(conn, ~p"/calibration")
    html = view |> element("button", "Revisar áreas salvas") |> render_click()

    assert html =~ "Áreas que o bot está usando"
    assert html =~ "janela Battle"
    assert html =~ "left:70.0%"
    assert html =~ "vida"
    assert html =~ "skills"

    assert html =~ "bandas do lock"
    assert html =~ "L0"
    assert html =~ "L5"
    assert html =~ ~s(title="player")

    # The CELLS, not just the box: `Vision.skill_slots/2` cuts the rectangle into
    # `count` equal columns and column i IS hotkey i. Drawn as one number per
    # column, a box sitting one cell off the icons becomes impossible to miss —
    # Lucas's bar enclosed the ROD and left skill 9 out, and nothing said so.
    assert html =~ "width:#{100 / 6}%"
    assert html =~ "left:#{5 * 100 / 6}%"

    # Every marked area at READING size. The full-screen preview cannot answer
    # "está no lugar certo?": a 10-point-tall band inside a browser column is a
    # few pixels tall, so one 40 points off looks exactly like a correct one —
    # which is how BOTH of Lucas's bottom-row regions passed inspection.
    assert html =~ ~s(id="read-crops")
    assert html =~ "brilho (isca)"
    assert html =~ "água"
    # the skills band is 10 points tall: magnified to the 64-point reading
    # height it would be 6.4×, capped at 5×, and the crop is positioned by
    # sliding the whole screenshot behind a window of exactly that band
    assert html =~ "background-position:-50.0px -300.0px"
    assert html =~ "background-size:500.0px 375.0px"
  end

  @tag :tmp_dir
  # Marking it again by hand is the same trap twice. A cell is the unit the
  # reader works in, so the whole repair is moving by WHOLE cells.
  test "a skill bar one cell off is repaired by nudging, not by redoing the wizard", %{
    conn: conn,
    tmp_dir: tmp
  } do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

    Calibration.save(%Calibration{
      scale: 1.0,
      screen_w: 100,
      screen_h: 75,
      skill_bar_region: {10, 60, 60, 10},
      skill_bar_count: 6,
      neutral_point: {52, 36}
    })

    probe = Pokex.PngFixtures.write!(Path.join(tmp, "probe.png"), rows(100, 100, {9, 9, 9, 255}))
    screen = Pokex.PngFixtures.write!(Path.join(tmp, "screen.png"), rows(100, 75, {9, 9, 9, 255}))

    {:ok, _} = Fake.start_link(%{capture: [{:ok, probe}], capture_screen: [{:ok, screen}]})

    {:ok, view, _html} = live(conn, ~p"/calibration")
    view |> element("button", "Revisar áreas salvas") |> render_click()

    view |> element(~s(#skill-bar-nudge button[phx-value-cells="1"])) |> render_click()

    {:ok, moved} = Calibration.load()
    # one cell = width / count = 10; nothing else about the bar moves
    assert moved.skill_bar_region == {20, 60, 60, 10}
    assert moved.skill_bar_count == 6

    view |> element(~s(#skill-bar-nudge button[phx-value-cells="-1"])) |> render_click()

    {:ok, back} = Calibration.load()
    assert back.skill_bar_region == {10, 60, 60, 10}
  end

  @tag :tmp_dir
  # the count is editable inside the flow (switching Pokémon changes it — the
  # quick fix must not silently reuse a stale one): the marking header has its own form
  test "standalone skill-bar calibration merges skill_bar_region into the saved calibration", %{
    conn: conn,
    tmp_dir: tmp
  } do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

    Calibration.save(%Calibration{
      scale: 2.0,
      screen_w: 100,
      screen_h: 75,
      water_point: {50, 30},
      glow_region: {18, -2, 64, 64},
      battle_region: {70, 10, 20, 30},
      neutral_point: {52, 36}
    })

    probe = Pokex.PngFixtures.write!(Path.join(tmp, "probe.png"), rows(200, 200, {9, 9, 9, 255}))

    screen =
      Pokex.PngFixtures.write!(Path.join(tmp, "screen.png"), rows(200, 150, {9, 9, 9, 255}))

    {:ok, _} =
      Fake.start_link(%{capture: [{:ok, probe}], capture_screen: [{:ok, screen}]})

    {:ok, view, _} = live(conn, ~p"/calibration")

    view |> element("button", "Só as skills") |> render_click()
    assert render(view) =~ "barra de skills"

    view
    |> form("#skill-count-form-marking", skill_bar: %{count: "6"})
    |> render_change()

    click = fn x, y ->
      params = %{"x" => x, "y" => y, "cw" => 50.0, "ch" => 37.5, "nw" => 200.0, "nh" => 150.0}
      render_hook(view, "img_click", params)
      render_hook(view, "img_click", params)
    end

    click.(10.0, 10.0)
    assert render(view) =~ "última skill"
    click.(40.0, 30.0)

    assert render(view) =~ "Barra salva com"
    assert {:ok, calib} = Calibration.load()
    assert calib.skill_bar_region == {20, 20, 60, 40}
    assert calib.skill_bar_count == 6
    assert Settings.get(:skill_bar_count) == 6
    assert calib.water_point == {50, 30}
    assert calib.battle_region == {70, 10, 20, 30}
  end

  # The screenshot he is looking at is itself the measurement of his screen, so
  # reviewing the areas re-judges the saved calibration against it. On mount the
  # backend answers instead — `:unknown` in tests, which must never accuse.
  describe "a calibration whose screen does not match the picture" do
    defp saved_on(conn, tmp, saved_w, saved_h) do
      Application.put_env(:pokex, :home_dir, tmp)
      on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

      Calibration.save(%Calibration{
        scale: 2.0,
        screen_w: saved_w,
        screen_h: saved_h,
        player_point: {100, 60},
        water_point: {50, 30},
        glow_region: {18, 0, 64, 64},
        battle_region: {70, 10, 20, 30},
        neutral_point: {52, 36}
      })

      # a 302x196 picture measured by a 1x probe: a 302x196-point screen
      probe =
        Pokex.PngFixtures.write!(Path.join(tmp, "probe.png"), rows(100, 100, {9, 9, 9, 255}))

      screen =
        Pokex.PngFixtures.write!(Path.join(tmp, "screen.png"), rows(302, 196, {9, 9, 9, 255}))

      {:ok, _} =
        Fake.start_link(%{capture: [{:ok, probe}], capture_screen: [{:ok, screen}]})

      {:ok, view, html} = live(conn, ~p"/calibration")
      %{view: view, mount_html: html}
    end

    @tag :tmp_dir
    test "another SHAPE of screen is called out, naming both", %{conn: conn, tmp_dir: tmp} do
      %{view: view} = saved_on(conn, tmp, 3440, 1440)

      html = view |> element("button", "Revisar áreas salvas") |> render_click()

      assert html =~ "Esta calibração é de outra tela"
      assert html =~ "3440×1440"
      assert html =~ "302×196"
      refute html =~ "rescale_calibration"
    end

    @tag :tmp_dir
    test "the same screen raises no warning", %{conn: conn, tmp_dir: tmp} do
      %{view: view} = saved_on(conn, tmp, 302, 196)

      html = view |> element("button", "Revisar áreas salvas") |> render_click()

      refute html =~ "de outra tela"
      refute html =~ "régua errada"
    end

    @tag :tmp_dir
    test "an unmeasurable display never accuses", %{conn: conn, tmp_dir: tmp} do
      %{mount_html: html} = saved_on(conn, tmp, 3440, 1440)

      refute html =~ "de outra tela"
      refute html =~ "régua errada"
    end

    # The two-monitor bug: the same picture divided by the union of both
    # displays. Same shape, bigger numbers — repairable without remarking.
    @tag :tmp_dir
    test "the same shape at another size offers the repair, and the repair lands", %{
      conn: conn,
      tmp_dir: tmp
    } do
      %{view: view} = saved_on(conn, tmp, 604, 392)

      html = view |> element("button", "Revisar áreas salvas") |> render_click()
      assert html =~ "régua errada"
      assert html =~ "302×196"

      html = view |> element("button", "Corrigir para 302×196") |> render_click()
      refute html =~ "régua errada"

      assert {:ok, calib} = Calibration.load()
      assert {calib.screen_w, calib.screen_h} == {302, 196}
      assert calib.player_point == {50, 30}
      assert calib.battle_region == {35, 5, 10, 15}
      assert calib.scale == 4.0
    end
  end

  # Two live bugs, one rule. 2026-08-03 (one monitor, 1512x982 at 2x): the SCK
  # served the probe in POINTS while the full screen fell back to the CLI in
  # PIXELS, and the two answers were paired. 2026-08-04 (two monitors): the
  # window server was asked instead, and it answers the UNION of every display
  # (4952x1989) for a 3440x1440 picture — every point saved 1.44x off, the
  # fishing rod on dry rock below the character. The ruler must be the display
  # that was FILMED, measured in the same turn as the picture.
  describe "screenshot scale" do
    defp wizard_on(conn, tmp, probe_px) do
      Application.put_env(:pokex, :home_dir, tmp)
      on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

      # the quick fixes only exist once there is a calibration to fix
      Calibration.save(%Calibration{
        scale: 2.0,
        screen_w: 999,
        screen_h: 999,
        water_point: {50, 30},
        glow_region: {18, 0, 64, 64},
        battle_region: {70, 10, 20, 30},
        neutral_point: {52, 36}
      })

      probe =
        Pokex.PngFixtures.write!(
          Path.join(tmp, "probe.png"),
          rows(probe_px, probe_px, {9, 9, 9, 255})
        )

      screen =
        Pokex.PngFixtures.write!(Path.join(tmp, "screen.png"), rows(302, 196, {9, 9, 9, 255}))

      {:ok, _} = Fake.start_link(%{capture: [{:ok, probe}], capture_screen: [{:ok, screen}]})

      {:ok, view, _} = live(conn, ~p"/calibration")
      view |> element("button", "Só o personagem") |> render_click()

      view
    end

    defp click_middle(view) do
      params = %{
        "x" => 50.0,
        "y" => 25.0,
        "cw" => 100.0,
        "ch" => 65.0,
        "nw" => 302.0,
        "nh" => 196.0
      }

      render_hook(view, "img_click", params)
      render_hook(view, "img_click", params)
    end

    @tag :tmp_dir
    test "a retina display's probe converts the picture into screen points", %{
      conn: conn,
      tmp_dir: tmp
    } do
      conn |> wizard_on(tmp, 200) |> click_middle()

      assert {:ok, calib} = Calibration.load()
      assert calib.scale == 2.0
      assert calib.screen_w == 151
      assert calib.screen_h == 98
      # half of the image, in POINTS — not the 151 the pixel-space maths gave
      assert calib.player_point == {76, 38}
    end

    @tag :tmp_dir
    test "a 1x display leaves the picture already in points", %{conn: conn, tmp_dir: tmp} do
      conn |> wizard_on(tmp, 100) |> click_middle()

      assert {:ok, calib} = Calibration.load()
      assert calib.scale == 1.0
      assert calib.screen_w == 302
      assert calib.screen_h == 196
    end
  end

  @tag :tmp_dir
  # the old transform-origin zoom pinned an edge click in place, pushing the
  # skill bar's corner out of view and leaving the last skills unclickable; the
  # pan must clamp flush to the edge (-250%), and a center click centers the
  # point (fy rounds to 38/75 → -127.33%)
  test "the zoom PANS to center the clicked point — an edge target stays visible", %{
    conn: conn,
    tmp_dir: tmp
  } do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

    Calibration.save(%Calibration{
      scale: 2.0,
      screen_w: 100,
      screen_h: 75,
      water_point: {50, 30},
      glow_region: {18, -2, 64, 64},
      battle_region: {70, 10, 20, 30},
      neutral_point: {52, 36}
    })

    probe = Pokex.PngFixtures.write!(Path.join(tmp, "probe.png"), rows(200, 200, {9, 9, 9, 255}))

    screen =
      Pokex.PngFixtures.write!(Path.join(tmp, "screen.png"), rows(200, 150, {9, 9, 9, 255}))

    {:ok, _} =
      Fake.start_link(%{capture: [{:ok, probe}], capture_screen: [{:ok, screen}]})

    {:ok, view, _} = live(conn, ~p"/calibration")
    view |> element("button", "Só as skills") |> render_click()

    render_hook(view, "img_click", %{
      "x" => 46.0,
      "y" => 34.5,
      "cw" => 50.0,
      "ch" => 37.5,
      "nw" => 200.0,
      "nh" => 150.0
    })

    assert render(view) =~ "translate(-250.0%, -250.0%) scale(3.5)"

    render_hook(view, "cancel_zoom", %{})

    render_hook(view, "img_click", %{
      "x" => 25.0,
      "y" => 18.75,
      "cw" => 50.0,
      "ch" => 37.5,
      "nw" => 200.0,
      "nh" => 150.0
    })

    assert render(view) =~ "translate(-125.0%, -127.33%) scale(3.5)"
  end

  @tag :tmp_dir
  test "standalone player calibration merges player_point into the saved calibration", %{
    conn: conn,
    tmp_dir: tmp
  } do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

    Calibration.save(%Calibration{
      scale: 2.0,
      screen_w: 100,
      screen_h: 75,
      water_point: {50, 30},
      glow_region: {18, -2, 64, 64},
      battle_region: {70, 10, 20, 30},
      neutral_point: {52, 36}
    })

    probe = Pokex.PngFixtures.write!(Path.join(tmp, "probe.png"), rows(200, 200, {9, 9, 9, 255}))

    screen =
      Pokex.PngFixtures.write!(Path.join(tmp, "screen.png"), rows(200, 150, {9, 9, 9, 255}))

    {:ok, _} =
      Fake.start_link(%{capture: [{:ok, probe}], capture_screen: [{:ok, screen}]})

    {:ok, view, _} = live(conn, ~p"/calibration")

    view |> element("button", "Só o personagem") |> render_click()
    assert render(view) =~ "PERSONAGEM"

    click = fn x, y ->
      params = %{"x" => x, "y" => y, "cw" => 50.0, "ch" => 37.5, "nw" => 200.0, "nh" => 150.0}
      render_hook(view, "img_click", params)
      render_hook(view, "img_click", params)
    end

    click.(20.0, 16.0)

    assert render(view) =~ "Personagem marcado"
    assert {:ok, calib} = Calibration.load()
    assert calib.player_point == {40, 32}
    assert calib.water_point == {50, 30}
  end

  @tag :tmp_dir
  # a step missing from marking_step?/1 rendered the instruction over a black
  # page (the 2026-07-20 regression); render_hook alone cannot catch it, so the
  # clickable screenshot is asserted as an element
  test "standalone mini-game strip calibration merges mini_game_region into the saved calibration",
       %{conn: conn, tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

    Calibration.save(%Calibration{
      scale: 2.0,
      screen_w: 100,
      screen_h: 75,
      water_point: {50, 30},
      glow_region: {18, -2, 64, 64},
      battle_region: {70, 10, 20, 30},
      neutral_point: {52, 36}
    })

    probe = Pokex.PngFixtures.write!(Path.join(tmp, "probe.png"), rows(200, 200, {9, 9, 9, 255}))

    screen =
      Pokex.PngFixtures.write!(Path.join(tmp, "screen.png"), rows(200, 150, {9, 9, 9, 255}))

    {:ok, _} =
      Fake.start_link(%{capture: [{:ok, probe}], capture_screen: [{:ok, screen}]})

    {:ok, view, _} = live(conn, ~p"/calibration")

    view |> element("button", "Só o minigame") |> render_click()
    assert render(view) =~ "FAIXA"
    assert has_element?(view, "#calibration-screen")

    click = fn x, y ->
      params = %{"x" => x, "y" => y, "cw" => 50.0, "ch" => 37.5, "nw" => 200.0, "nh" => 150.0}
      render_hook(view, "img_click", params)
      render_hook(view, "img_click", params)
    end

    click.(30.0, 4.0)
    assert render(view) =~ "INFERIOR-DIREITO"
    click.(40.0, 28.0)

    assert render(view) =~ "Faixa do minigame salva"
    assert {:ok, calib} = Calibration.load()
    assert calib.mini_game_region == {60, 8, 20, 48}
    assert calib.water_point == {50, 30}
  end

  @tag :tmp_dir
  test "standalone Pokémon-spot calibration merges pokemon_spot_point into the saved calibration",
       %{conn: conn, tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

    Calibration.save(%Calibration{
      scale: 2.0,
      screen_w: 100,
      screen_h: 75,
      water_point: {50, 30},
      glow_region: {18, -2, 64, 64},
      battle_region: {70, 10, 20, 30},
      neutral_point: {52, 36}
    })

    probe = Pokex.PngFixtures.write!(Path.join(tmp, "probe.png"), rows(200, 200, {9, 9, 9, 255}))

    screen =
      Pokex.PngFixtures.write!(Path.join(tmp, "screen.png"), rows(200, 150, {9, 9, 9, 255}))

    {:ok, _} =
      Fake.start_link(%{capture: [{:ok, probe}], capture_screen: [{:ok, screen}]})

    {:ok, view, _} = live(conn, ~p"/calibration")

    view |> element("button", "Posição do Pokémon") |> render_click()
    assert render(view) =~ "TILE"
    assert has_element?(view, "#calibration-screen")

    click = fn x, y ->
      params = %{"x" => x, "y" => y, "cw" => 50.0, "ch" => 37.5, "nw" => 200.0, "nh" => 150.0}
      render_hook(view, "img_click", params)
      render_hook(view, "img_click", params)
    end

    click.(35.0, 20.0)

    assert render(view) =~ "Posição do Pokémon salva"
    assert {:ok, calib} = Calibration.load()
    assert calib.pokemon_spot_point == {70, 40}
    assert calib.water_point == {50, 30}

    view |> element("button", "Escada de fuga") |> render_click()
    assert render(view) =~ "TILE LIVRE DO CAMINHO"
    assert has_element?(view, "#calibration-screen")

    click.(10.0, 10.0)

    assert render(view) =~ "Tile de fuga salvo"
    assert {:ok, calib} = Calibration.load()
    assert calib.escape_point == {20, 20}
    assert calib.pokemon_spot_point == {70, 40}
  end

  @tag :tmp_dir
  test "profiles: save the current calibration, apply it back after it changes", %{
    conn: conn,
    tmp_dir: tmp
  } do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

    Calibration.save(%Calibration{
      scale: 1.0,
      screen_w: 3440,
      screen_h: 1440,
      water_point: {50, 30},
      glow_region: {18, 2, 64, 64},
      battle_region: {70, 10, 20, 30},
      neutral_point: {52, 36}
    })

    {:ok, _} = Fake.start_link(%{})
    {:ok, view, _} = live(conn, ~p"/calibration")

    view
    |> form("#profile-form", %{"profile_name" => "2 monitores"})
    |> render_submit()

    html = render(view)
    assert html =~ "Perfil &quot;2-monitores&quot; salvo"
    assert html =~ "2-monitores"
    assert html =~ "3440×1440"

    {:ok, calib} = Calibration.load()
    Calibration.save(%{calib | screen_w: 111})

    view |> element("button[phx-value-name='2-monitores']", "Usar") |> render_click()
    assert render(view) =~ "Perfil &quot;2-monitores&quot; aplicado"
    assert {:ok, restored} = Calibration.load()
    assert restored.screen_w == 3440
  end

  describe "mapped corpses" do
    @tag :tmp_dir
    test "the teaching section exists and lists the library", %{conn: conn, tmp_dir: tmp} do
      Application.put_env(:pokex, :home_dir, tmp)
      on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

      {:ok, 1} =
        CorpseLibrary.add("Rattata", %Pokex.Vision.Frame{
          width: 4,
          height: 4,
          rgba: :binary.copy(<<180, 120, 200, 255>>, 16)
        })

      {:ok, view, _html} = live(conn, "/calibration")

      assert has_element?(view, "#corpse-shot-btn")
      assert has_element?(view, "#corpse-list", "Rattata")
      assert render(view) =~ "data:image/bmp;base64,"

      view
      |> element(~s(#corpse-list button[phx-click="corpse_delete"][phx-value-slug="rattata"]))
      |> render_click()

      refute has_element?(view, "#corpse-list")
    end

    @tag :tmp_dir
    test "shooting without a calibration explains instead of crashing", %{
      conn: conn,
      tmp_dir: tmp
    } do
      Application.put_env(:pokex, :home_dir, tmp)
      on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

      {:ok, view, _html} = live(conn, "/calibration")
      render_click(view, "corpse_shot")

      assert render(view) =~ "precisa de calibração"
    end

    @tag :tmp_dir
    # 2026-07-30: the photo used arena_region while the search scanned the big
    # square — a fallen Gyarados was cut off at the photo's bottom edge and
    # could not even be clicked to teach
    test "the teaching photo is the same frame the search scans", %{conn: conn, tmp_dir: tmp} do
      Application.put_env(:pokex, :home_dir, tmp)
      on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

      calib = %Pokex.Calibration{
        scale: 1.0,
        screen_w: 3440,
        screen_h: 1440,
        water_point: {1, 1},
        glow_region: {0, 0, 8, 8},
        battle_region: {3173, 403, 261, 380},
        neutral_point: {500, 500},
        player_point: {1688, 697}
      }

      Pokex.Calibration.save(calib)
      {:ok, expected} = SpotScan.region(calib)

      {:ok, _} = Fake.start_link(%{})
      {:ok, view, _html} = live(conn, "/calibration")
      render_click(view, "corpse_shot")

      assert {:capture, ^expected, "corpse_teach.png"} =
               Enum.find(Fake.calls(), &match?({:capture, _, "corpse_teach.png"}, &1))

      {rx, ry, rw, rh} = expected
      {px, py} = calib.player_point
      assert px > rx and px < rx + rw
      assert py > ry and py < ry + rh
    end

    @tag :tmp_dir
    test "each corpse has a targeting switch and a session counter", %{conn: conn, tmp_dir: tmp} do
      Application.put_env(:pokex, :home_dir, tmp)
      on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

      {:ok, 1} =
        CorpseLibrary.add("Kingler", %Pokex.Vision.Frame{
          width: 4,
          height: 4,
          rgba: :binary.copy(<<180, 120, 200, 255>>, 16)
        })

      {:ok, view, _html} = live(conn, "/calibration")

      assert has_element?(view, "#corpse-toggle-kingler", "na mira")

      view |> element("#corpse-toggle-kingler") |> render_click()
      assert has_element?(view, "#corpse-toggle-kingler", "fora")
      assert has_element?(view, "#corpse-list", "Kingler")

      view |> element("#corpse-toggle-kingler") |> render_click()
      assert has_element?(view, "#corpse-toggle-kingler", "na mira")

      refute render(view) =~ "nesta sessão"
      send(view.pid, {:catcher_count, %{"Kingler" => 3}})
      assert render(view) =~ "3× nesta sessão"
    end

    @tag :tmp_dir
    # the page subscribes to "catcher" only for the count; everything else on
    # that topic (snapshots, logs, alarms) must die without a crash
    test "the rest of the catcher traffic does not crash the page", %{conn: conn, tmp_dir: tmp} do
      Application.put_env(:pokex, :home_dir, tmp)
      on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

      {:ok, view, _html} = live(conn, "/calibration")

      send(view.pid, {:catcher, %{state: :armed, counters: %{}}})
      send(view.pid, {:catcher_log, :macro, "captura: bola em 1,2"})
      send(view.pid, {:rule_alarm, :capture, "sirene"})

      send(view.pid, {:catcher_count, %{"Kingler" => 1}})
      assert render(view) =~ "Calibração"
    end
  end

  describe "position & minimap (5 clicks, the hand rules)" do
    @tag :tmp_dir
    # the calibration "photo" is a real capture: the final verdict must read the
    # true coordinate off it
    test "marks minimap+cross+coordinate, saves, and reads the coordinate off its own photo", %{
      conn: conn,
      tmp_dir: tmp
    } do
      Application.put_env(:pokex, :home_dir, tmp)
      on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

      Calibration.save(%Calibration{
        scale: 1.0,
        screen_w: 3440,
        screen_h: 1440,
        water_point: {50, 30},
        glow_region: {18, 2, 64, 64},
        battle_region: {70, 10, 20, 30},
        neutral_point: {52, 36}
      })

      screen_png = "test/fixtures/screen/ultrawide_3440x1440_full.png"
      frame = Pokex.ScreenFixtures.frame!("ultrawide_3440x1440_full")
      {:ok, fix} = Pokex.Layout.locate(frame)
      {mx, my, mw, mh} = Pokex.Layout.region(:minimap, fix)
      {cx, cy, cw, ch} = Pokex.Layout.region(:minimap_coord, fix)

      probe =
        Pokex.PngFixtures.write!(Path.join(tmp, "probe.png"), rows(100, 100, {9, 9, 9, 255}))

      {:ok, _} =
        Fake.start_link(%{capture: [{:ok, probe}], capture_screen: [{:ok, screen_png}]})

      {:ok, view, _} = live(conn, ~p"/calibration")

      view |> element("button", "Posição & minimapa") |> render_click()
      assert render(view) =~ "MINIMAPA"
      assert has_element?(view, "#calibration-screen")

      click = fn x, y ->
        params = %{
          "x" => x / 1,
          "y" => y / 1,
          "cw" => 3440.0,
          "ch" => 1440.0,
          "nw" => 3440.0,
          "nh" => 1440.0
        }

        render_hook(view, "img_click", params)
        render_hook(view, "img_click", params)
      end

      click.(mx, my)
      assert render(view) =~ "INFERIOR-DIREITO"
      click.(mx + mw, my + mh)
      assert render(view) =~ "CRUZ"
      click.(mx + div(mw, 2), my + div(mh, 2))
      assert render(view) =~ "COORDENADA"
      click.(cx, cy)
      click.(cx + cw, cy + ch)

      html = render(view)
      assert html =~ "salvos"
      assert html =~ "li a coordenada da foto: (337, 46107, 4)"

      assert {:ok, calib} = Calibration.load()
      assert calib.minimap_region == {mx, my, mw, mh}
      assert calib.minimap_player_point == {mx + div(mw, 2), my + div(mh, 2)}
      assert calib.minimap_coord_region == {cx, cy, cw, ch}
      assert calib.water_point == {50, 30}
    end
  end
end
