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
  # Every mark goes through ONE door so the screen stamp cannot be forgotten:
  # a step that merged straight into the loaded calibration saved the point with
  # the PREVIOUS monitor's dimensions (2026-08-03 — one point marked on the
  # notebook wrote a file claiming to be the 3440 ultrawide), and since the
  # per-monitor snapshots that stamp also decides which monitor it is filed under.
  test "a quick-fix mark stamps THIS screen and files under THIS monitor", %{
    conn: conn,
    tmp_dir: tmp
  } do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

    # a calibration that belongs to the ultrawide is what is loaded
    Calibration.save(%Calibration{scale: 1.0, screen_w: 3440, screen_h: 1440})

    probe = Pokex.PngFixtures.write!(Path.join(tmp, "probe.png"), rows(200, 200, {9, 9, 9, 255}))

    screen =
      Pokex.PngFixtures.write!(Path.join(tmp, "screen.png"), rows(200, 150, {9, 9, 9, 255}))

    {:ok, _} = Fake.start_link(%{capture: [{:ok, probe}], capture_screen: [{:ok, screen}]})

    {:ok, view, _html} = live(conn, ~p"/calibration")
    view |> element(~s(button[phx-click="calibrate_player"])) |> render_click()

    params = %{"x" => 20.0, "y" => 16.0, "cw" => 50.0, "ch" => 37.5, "nw" => 200.0, "nh" => 150.0}
    render_hook(view, "img_click", params)
    render_hook(view, "img_click", params)

    assert {:ok, saved} = Calibration.load()
    assert saved.player_point == {40, 32}
    # the mark did NOT inherit the ultrawide's dimensions
    assert saved.screen_w == 100
    assert saved.screen_h == 75
    # and this monitor now remembers it
    assert {:ok, %Calibration{player_point: {40, 32}}} = Calibration.last_for_screen({100, 75})
  end

  @tag :tmp_dir
  # "Se eu troquei de monitor... me dá uma opção de usar a última calibração
  # daquele monitor" (Lucas, 2026-08-07). The banner stops saying only "redo
  # everything": when this monitor was calibrated before, its last calibration
  # is one click away — marks and numbers, no arithmetic.
  test "the other-screen banner offers this monitor's last calibration back", %{
    conn: conn,
    tmp_dir: tmp
  } do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

    # this monitor (100×75) was calibrated once; then an ultrawide calibration
    # became active
    Calibration.save(%Calibration{scale: 1.0, screen_w: 100, screen_h: 75, water_point: {50, 30}})
    Calibration.save(%Calibration{scale: 1.0, screen_w: 3440, screen_h: 1440})

    probe = Pokex.PngFixtures.write!(Path.join(tmp, "probe.png"), rows(100, 100, {9, 9, 9, 255}))
    screen = Pokex.PngFixtures.write!(Path.join(tmp, "screen.png"), rows(100, 75, {9, 9, 9, 255}))
    {:ok, _} = Fake.start_link(%{capture: [{:ok, probe}], capture_screen: [{:ok, screen}]})

    {:ok, view, _html} = live(conn, ~p"/calibration")
    view |> element("button", "Revisar áreas salvas") |> render_click()

    assert has_element?(view, "#screen-mismatch-strip")
    html = view |> element("#restore-last-for-screen") |> render_click()

    assert html =~ "Última calibração desta tela restaurada"
    assert {:ok, %Calibration{screen_w: 100, water_point: {50, 30}}} = Calibration.load()
  end

  @tag :tmp_dir
  # A day was lost to "cliquei no meio e gravou torto" and the pipeline turned
  # out CORRECT — but nothing on screen could show it. Two guarantees now: every
  # click leaves its raw numbers and computed point in sight, and every draft
  # mark paints its marker immediately (the minimap steps used to be blind —
  # exactly where the distrust was born).
  test "marking leaves an X-ray: the click trace and the freshly drawn mark", %{
    conn: conn,
    tmp_dir: tmp
  } do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

    probe = Pokex.PngFixtures.write!(Path.join(tmp, "probe.png"), rows(200, 200, {9, 9, 9, 255}))

    screen =
      Pokex.PngFixtures.write!(Path.join(tmp, "screen.png"), rows(200, 150, {9, 9, 9, 255}))

    {:ok, _} = Fake.start_link(%{capture: [{:ok, probe}], capture_screen: [{:ok, screen}]})

    Calibration.save(%Calibration{scale: 2.0, screen_w: 100, screen_h: 75})

    {:ok, view, _html} = live(conn, ~p"/calibration")
    view |> element(~s(button[phx-click="calibrate_minimap"])) |> render_click()

    click = fn x, y ->
      params = %{"x" => x, "y" => y, "cw" => 50.0, "ch" => 37.5, "nw" => 200.0, "nh" => 150.0}
      render_hook(view, "img_click", params)
      render_hook(view, "img_click", params)
    end

    # both minimap corners: the next step (cross) must already SHOW the region
    click.(10.0, 10.0)
    html = click.(40.0, 30.0)

    # the trace: the recorded click with its raw numbers and its computed point
    assert html =~ ~s(id="click-trace")
    assert html =~ "✔ clique (40.0, 30.0)"
    assert html =~ "(80, 60)"

    # and the region overlay is painted the moment it is recorded
    assert html =~ "overlay-label"
  end

  @tag :tmp_dir
  # The "minimapa" label of an already-marked region rides INSIDE the container
  # the zoom scales 3.5x: 10px type becomes 35px sitting exactly over the next
  # target (the label hangs above the region's top edge — where the coord band
  # lives), and the span STOLE the click, which never reached ImgClick. While
  # zoomed the overlays go quiet — hairline outlines only, no labels, no fills
  # — and the whole layer never intercepts a click.
  test "overlays go quiet under zoom and never steal the click", %{conn: conn, tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

    screen =
      Pokex.PngFixtures.write!(Path.join(tmp, "screen.png"), rows(200, 150, {9, 9, 9, 255}))

    {:ok, _} = Fake.start_link(%{capture_screen: [{:ok, screen}]})
    Calibration.save(%Calibration{scale: 2.0, screen_w: 100, screen_h: 75})

    {:ok, view, _html} = live(conn, ~p"/calibration")
    view |> element(~s(button[phx-click="calibrate_minimap"])) |> render_click()

    click = fn x, y ->
      params = %{"x" => x, "y" => y, "cw" => 50.0, "ch" => 37.5, "nw" => 200.0, "nh" => 150.0}
      render_hook(view, "img_click", params)
      render_hook(view, "img_click", params)
    end

    # both minimap corners: the draft now carries minimap_region, no zoom active
    click.(10.0, 10.0)
    html = click.(40.0, 30.0)

    assert html =~ ~s(id="mark-overlays")
    assert html =~ "pointer-events-none"
    assert html =~ "overlay-label"

    # rough click of the NEXT step (the cross) turns the zoom on: labels gone
    html =
      render_hook(view, "img_click", %{
        "x" => 25.0,
        "y" => 15.0,
        "cw" => 50.0,
        "ch" => 37.5,
        "nw" => 200.0,
        "nh" => 150.0
      })

    assert html =~ "scale(3.5)"
    refute html =~ "overlay-label"

    # cancelling the zoom brings the teaching labels back
    html = render_hook(view, "cancel_zoom", %{})
    assert html =~ "overlay-label"
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
  # Every wizard mark is now repairable alone: the window moved -> re-mark just
  # that window, without the other nine steps.
  test "the água/battle/neutro/vida quick fixes save just their marks", %{
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
      battle_region: {70, 10, 20, 30},
      neutral_point: {52, 36},
      skill_bar_region: {10, 60, 50, 10},
      skill_bar_count: 6
    })

    probe = Pokex.PngFixtures.write!(Path.join(tmp, "probe.png"), rows(200, 200, {9, 9, 9, 255}))

    screen =
      Pokex.PngFixtures.write!(Path.join(tmp, "screen.png"), rows(200, 150, {9, 9, 9, 255}))

    {:ok, _} = Fake.start_link(%{capture: [{:ok, probe}], capture_screen: [{:ok, screen}]})

    {:ok, view, _html} = live(conn, ~p"/calibration")

    click = fn x, y ->
      params = %{"x" => x, "y" => y, "cw" => 50.0, "ch" => 37.5, "nw" => 200.0, "nh" => 150.0}
      render_hook(view, "img_click", params)
      render_hook(view, "img_click", params)
    end

    # água: one click; the glow box follows the point
    view |> element("button", "Só a água") |> render_click()
    click.(10.0, 10.0)
    assert {:ok, %{water_point: {20, 20}, glow_region: glow}} = Calibration.load()
    assert {_gx, _gy, gw, gw} = glow

    # battle: two corners
    view |> element("button", "Só a Battle") |> render_click()
    click.(30.0, 5.0)
    click.(45.0, 25.0)
    assert {:ok, %{battle_region: {60, 10, 30, 40}}} = Calibration.load()

    # neutro: one click
    view |> element("button", "Só o ponto neutro") |> render_click()
    click.(26.0, 18.0)
    assert {:ok, %{neutral_point: {52, 36}}} = Calibration.load()

    # vida: two corners + the photo point
    view |> element("button", "Só a vida") |> render_click()
    click.(5.0, 5.0)
    click.(15.0, 8.0)
    click.(18.0, 6.0)

    assert {:ok, saved} = Calibration.load()
    assert saved.pokemon_hp_region == {10, 10, 20, 6}
    assert saved.pokemon_photo_point == {36, 12}
    # nothing else was touched by any of the four flows
    assert saved.skill_bar_region == {10, 60, 50, 10}
  end

  @tag :tmp_dir
  # "ajustando um pouco pro lado, pra cima, pra baixo" (Lucas, 2026-08-07): the
  # crop shows the mark is a hair off — the repair is arrows on the crop, not a
  # wizard. Every click SAVES; the crop redraws from the same screenshot.
  test "the review nudge pads move points and resize regions, saving each click", %{
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
      battle_region: {70, 10, 20, 30},
      neutral_point: {52, 36}
    })

    probe = Pokex.PngFixtures.write!(Path.join(tmp, "probe.png"), rows(200, 200, {9, 9, 9, 255}))

    screen =
      Pokex.PngFixtures.write!(Path.join(tmp, "screen.png"), rows(200, 150, {9, 9, 9, 255}))

    {:ok, _} = Fake.start_link(%{capture: [{:ok, probe}], capture_screen: [{:ok, screen}]})

    {:ok, view, _html} = live(conn, ~p"/calibration")
    view |> element("button", "Revisar áreas salvas") |> render_click()

    # open the pad for the water point and nudge right (default step: 5pt)
    view |> element("#adjust-water_point") |> render_click()

    view
    |> element(~s(#adjust-pad-water_point button[phx-value-dx="1"][phx-value-dy="0"]))
    |> render_click()

    assert {:ok, %{water_point: {55, 30}}} = Calibration.load()

    # step down to 1pt and nudge up
    view |> element(~s(#adjust-pad-water_point button[phx-value-step="1"])) |> render_click()

    view
    |> element(~s(#adjust-pad-water_point button[phx-value-dy="-1"][phx-value-dx="0"]))
    |> render_click()

    assert {:ok, %{water_point: {55, 29}}} = Calibration.load()

    # regions also GROW: +altura on the battle window (step is back at 1)
    view |> element("#adjust-battle_region") |> render_click()
    view |> element(~s(#adjust-pad-battle_region button[phx-value-dh="1"])) |> render_click()

    assert {:ok, %{battle_region: {70, 10, 20, 31}}} = Calibration.load()
  end

  @tag :tmp_dir
  test "nudging the skill bar RE-SAMPLES the per-slot ready references", %{
    conn: conn,
    tmp_dir: tmp
  } do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

    Calibration.save(%Calibration{
      scale: 2.0,
      screen_w: 100,
      screen_h: 75,
      skill_bar_region: {10, 60, 50, 10},
      skill_bar_count: 5,
      neutral_point: {52, 36}
    })

    probe = Pokex.PngFixtures.write!(Path.join(tmp, "probe.png"), rows(200, 200, {9, 9, 9, 255}))

    screen =
      Pokex.PngFixtures.write!(Path.join(tmp, "screen.png"), rows(200, 150, {30, 90, 40, 255}))

    {:ok, _} = Fake.start_link(%{capture: [{:ok, probe}], capture_screen: [{:ok, screen}]})

    {:ok, view, _html} = live(conn, ~p"/calibration")
    view |> element("button", "Revisar áreas salvas") |> render_click()

    view |> element("#adjust-skill_bar_region") |> render_click()

    view
    |> element(~s(#adjust-pad-skill_bar_region button[phx-value-dx="1"][phx-value-dy="0"]))
    |> render_click()

    assert {:ok, moved} = Calibration.load()
    assert moved.skill_bar_region == {15, 60, 50, 10}
    # refs re-sampled from the review screenshot: one per slot, from the green field
    assert length(moved.skill_slot_refs) == 5
    assert Enum.all?(moved.skill_slot_refs, &match?({_r, _g, _b}, &1))
  end

  @tag :tmp_dir
  # The minimap trio was invisible in the review — the areas the CAVEBOT lives
  # on. Now they crop like everything else, and the coordinate strip carries a
  # LIVE reading: green "li: x, y, z" is the proof the mark is right; on this
  # blank fixture it must say it could not read.
  test "minimap areas crop in the review and the coordinate probe answers live", %{
    conn: conn,
    tmp_dir: tmp
  } do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

    Calibration.save(%Calibration{
      scale: 2.0,
      screen_w: 100,
      screen_h: 75,
      minimap_region: {60, 5, 30, 30},
      minimap_coord_region: {62, 28, 26, 6},
      minimap_player_point: {75, 20},
      escape_point: {40, 40},
      neutral_point: {52, 36}
    })

    probe = Pokex.PngFixtures.write!(Path.join(tmp, "probe.png"), rows(200, 200, {9, 9, 9, 255}))

    screen =
      Pokex.PngFixtures.write!(Path.join(tmp, "screen.png"), rows(200, 150, {9, 9, 9, 255}))

    {:ok, _} = Fake.start_link(%{capture: [{:ok, probe}], capture_screen: [{:ok, screen}]})

    {:ok, view, _html} = live(conn, ~p"/calibration")
    html = view |> element("button", "Revisar áreas salvas") |> render_click()

    assert html =~ "minimapa"
    assert html =~ "cruz do personagem"
    assert html =~ "escada de fuga"
    assert html =~ "ponto neutro"
    assert html =~ ~s(id="coord-probe")
    assert html =~ "não li"
  end

  @tag :tmp_dir
  # The real 2026-08-10 calibration carried a cross at {3171, 3} — the macOS
  # menu bar — while the map sat at y=52. The resolver refuses the stray mark
  # (walks would drift north-west forever), and the review must SAY so instead
  # of silently rendering the healthy center fallback.
  test "a cross marked outside the map raises a red flag in the review", %{
    conn: conn,
    tmp_dir: tmp
  } do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

    Calibration.save(%Calibration{
      scale: 2.0,
      screen_w: 100,
      screen_h: 75,
      minimap_region: {60, 25, 30, 30},
      minimap_player_point: {61, 2}
    })

    screen =
      Pokex.PngFixtures.write!(Path.join(tmp, "screen.png"), rows(200, 150, {9, 9, 9, 255}))

    {:ok, _} = Fake.start_link(%{capture_screen: [{:ok, screen}]})

    {:ok, view, _html} = live(conn, ~p"/calibration")
    html = view |> element("button", "Revisar áreas salvas") |> render_click()

    assert html =~ ~s(id="stray-cross")
    assert html =~ "cruz fora do mapa"
  end

  @tag :tmp_dir
  # A calibration can be perfect and the bot still blind: every threshold and
  # box SIZE was measured on the ultrawide. The ruler is a skill slot, and
  # applying is his click — a derivation that rewrote settings silently is how
  # he would stop trusting the numbers exactly when he needs them.
  test "the screen ruler proposes the rescaled numbers and applies them on a click", %{
    conn: conn,
    tmp_dir: tmp
  } do
    Application.put_env(:pokex, :home_dir, tmp)
    # applying rescales EVERY screen-dependent key, so every one of them has to
    # come back — restoring only the two the test asserts on would leave the
    # rest scaled for the whole suite
    %{linear: linear, area: area} = Pokex.ScreenScale.keys()
    before = Map.new(linear ++ area, &{&1, Settings.get(&1)})

    on_exit(fn ->
      Application.delete_env(:pokex, :home_dir)
      Enum.each(before, fn {key, value} -> Settings.put(key, value) end)
    end)

    Calibration.save(%Calibration{
      scale: 1.0,
      screen_w: 100,
      screen_h: 75,
      # 325 points over 9 slots = 36.1 per slot against the reference's 47.8
      skill_bar_region: {10, 60, 325, 10},
      skill_bar_count: 9,
      neutral_point: {52, 36}
    })

    probe = Pokex.PngFixtures.write!(Path.join(tmp, "probe.png"), rows(100, 100, {9, 9, 9, 255}))
    screen = Pokex.PngFixtures.write!(Path.join(tmp, "screen.png"), rows(100, 75, {9, 9, 9, 255}))
    {:ok, _} = Fake.start_link(%{capture: [{:ok, probe}], capture_screen: [{:ok, screen}]})

    {:ok, view, _html} = live(conn, ~p"/calibration")

    # Opening the review is enough: the measurement is arithmetic over the
    # calibration, and a check behind a button is a check nobody makes.
    html = view |> element("button", "Revisar áreas salvas") |> render_click()

    assert html =~ "0.76× a de referência"
    assert has_element?(view, "#numbers-alert")

    html = view |> element("#tool-ruler") |> render_click()
    assert html =~ "tile_px"
    # a length scales with the ruler (88 × 0.756); a pixel count with its
    # square (1100 × 0.756²) — well under the value a linear scaling would give,
    # which is the difference between a bite registering and never registering
    assert html =~ "→ 67"
    assert html =~ "→ 628"

    view |> element("#apply-screen-scale") |> render_click()

    assert Settings.get(:tile_px) == 67
    assert Settings.get(:glow_threshold) == 628
    assert render(view) =~ "ajuste(s) aplicado(s)"
    # nothing left to fix, so the alert is gone instead of merely emptied
    refute has_element?(view, "#numbers-alert")
  end

  @tag :tmp_dir
  # THE FIELD BUG (2026-08-10): back on the ultrawide after a trip to the
  # MacBook, recalibrated and everything, the bot kept fishing with the
  # MacBook's thresholds — glow_threshold 496 where the bite was MEASURED at
  # 1100. The panel had nothing to say, because "the ruler matches the
  # reference" was being read as "the numbers are right". It is the opposite:
  # on the reference screen, a value that differs from the seed is another
  # screen's, and this is the only place that can hand the measured one back.
  test "on the reference screen, another screen's numbers are offered back", %{
    conn: conn,
    tmp_dir: tmp
  } do
    Application.put_env(:pokex, :home_dir, tmp)
    %{linear: linear, area: area} = Pokex.ScreenScale.keys()
    before = Map.new(linear ++ area, &{&1, Settings.get(&1)})

    on_exit(fn ->
      Application.delete_env(:pokex, :home_dir)
      Enum.each(before, fn {key, value} -> Settings.put(key, value) end)
    end)

    # what he came home with
    Settings.put(:glow_threshold, 496)
    Settings.put(:tile_px, 59)

    Calibration.save(%Calibration{
      scale: 1.0,
      screen_w: 100,
      screen_h: 75,
      # his ultrawide profile: 430 points over 9 slots = the reference itself
      skill_bar_region: {10, 60, 430, 10},
      skill_bar_count: 9,
      neutral_point: {52, 36}
    })

    probe = Pokex.PngFixtures.write!(Path.join(tmp, "probe.png"), rows(100, 100, {9, 9, 9, 255}))
    screen = Pokex.PngFixtures.write!(Path.join(tmp, "screen.png"), rows(100, 75, {9, 9, 9, 255}))
    {:ok, _} = Fake.start_link(%{capture: [{:ok, probe}], capture_screen: [{:ok, screen}]})

    {:ok, view, _html} = live(conn, ~p"/calibration")

    html = view |> element("button", "Revisar áreas salvas") |> render_click()

    assert html =~ "números são de outra tela"
    assert html =~ "esta é a tela em que eles foram medidos"

    html = view |> element("#tool-ruler") |> render_click()
    # the SEEDS themselves, not seed × 0.98
    assert html =~ "→ 1100"
    assert html =~ "→ 88"

    view |> element("#apply-screen-scale") |> render_click()

    assert Settings.get(:glow_threshold) == 1100
    assert Settings.get(:tile_px) == 88
  end

  @tag :tmp_dir
  # `battle_row_height` was measured on the ultrawide and, like every other
  # pixel-denominated number, does not survive a change of screen: on the small
  # screen the same list holds ~10 rows and the bot drew 6 fat bands over 3
  # (Lucas, 2026-08-06). The knob lives NEXT to the bands so it can be tuned by
  # eye — it was read everywhere and editable nowhere.
  test "the battle list ruler is editable where the bands are drawn", %{conn: conn, tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    height = Settings.get(:battle_row_height)
    rows = Settings.get(:battle_max_rows)

    on_exit(fn ->
      Application.delete_env(:pokex, :home_dir)
      Settings.put(:battle_row_height, height)
      Settings.put(:battle_max_rows, rows)
    end)

    Calibration.save(%Calibration{
      scale: 1.0,
      screen_w: 100,
      screen_h: 75,
      battle_region: {70, 10, 20, 30},
      neutral_point: {52, 36}
    })

    probe = Pokex.PngFixtures.write!(Path.join(tmp, "probe.png"), rows(100, 100, {9, 9, 9, 255}))
    screen = Pokex.PngFixtures.write!(Path.join(tmp, "screen.png"), rows(100, 75, {9, 9, 9, 255}))
    {:ok, _} = Fake.start_link(%{capture: [{:ok, probe}], capture_screen: [{:ok, screen}]})

    {:ok, view, _html} = live(conn, ~p"/calibration")
    view |> element("button", "Revisar áreas salvas") |> render_click()
    # one tool open at a time — three panels side by side was the pile
    view |> element("#tool-battle") |> render_click()

    html =
      view
      |> form("#battle-rows-form", %{"battle_row_height" => "36", "battle_max_rows" => "10"})
      |> render_change()

    assert Settings.get(:battle_row_height) == 36
    assert Settings.get(:battle_max_rows) == 10
    # the ladder redraws from the new numbers, right there
    assert html =~ "L9"

    # An all-grey screenshot has no HP bars: it must say WHY instead of writing
    # a number it could not measure.
    view |> element("#battle-rows button", "Medir") |> render_click()
    assert render(view) =~ "pelo menos DOIS pokémon vivos"
    assert Settings.get(:battle_row_height) == 36
  end

  @tag :tmp_dir
  # "ta ruim de usar, confuso" (Lucas, 2026-08-10). Six coloured boxes stacked
  # at the same weight: with everything shouting, the one that mattered could
  # not. The panel now opens on the QUESTION (what does the bot read?) and
  # keeps the tools folded until asked for.
  test "the review opens on the crops, with the tools folded away", %{conn: conn, tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

    Calibration.save(%Calibration{
      scale: 1.0,
      screen_w: 100,
      screen_h: 75,
      battle_region: {70, 10, 20, 30},
      skill_bar_region: {10, 60, 60, 10},
      skill_bar_count: 6,
      neutral_point: {52, 36}
    })

    probe = Pokex.PngFixtures.write!(Path.join(tmp, "probe.png"), rows(100, 100, {9, 9, 9, 255}))
    screen = Pokex.PngFixtures.write!(Path.join(tmp, "screen.png"), rows(100, 75, {9, 9, 9, 255}))
    {:ok, _} = Fake.start_link(%{capture: [{:ok, probe}], capture_screen: [{:ok, screen}]})

    {:ok, view, _html} = live(conn, ~p"/calibration")
    view |> element("button", "Revisar áreas salvas") |> render_click()

    # the answer he came for is on screen with no clicks
    assert has_element?(view, "#read-crops")

    for tool <- ~w(#skill-bar-nudge #battle-rows #screen-scale) do
      refute has_element?(view, tool), "#{tool} is open before anyone asked for it"
    end

    # one at a time: opening a second one puts the first away
    view |> element("#tool-skills") |> render_click()
    assert has_element?(view, "#skill-bar-nudge")

    view |> element("#tool-battle") |> render_click()
    assert has_element?(view, "#battle-rows")
    refute has_element?(view, "#skill-bar-nudge")

    # and clicking the open one closes it
    view |> element("#tool-battle") |> render_click()
    refute has_element?(view, "#battle-rows")
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
    view |> element("#tool-skills") |> render_click()

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

      assert html =~ "A calibração é de outra tela"
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
  # "tu pode fazer essa config ser sempre sugerida como padrão... quando for pra
  # calibrar ele ter essa sugestão, mostrando como ficaria na tela?" (Lucas,
  # 2026-08-10). A sugestão é DESENHADA na foto antes de qualquer clique e cabe
  # num botão — dois cantos viram zero.
  test "the mini-game step draws the suggested strip and takes it in one click", %{
    conn: conn,
    tmp_dir: tmp
  } do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

    Calibration.save(%Calibration{
      scale: 1.0,
      screen_w: 200,
      screen_h: 150,
      player_point: {100, 60},
      neutral_point: {52, 36}
    })

    probe = Pokex.PngFixtures.write!(Path.join(tmp, "probe.png"), rows(200, 200, {9, 9, 9, 255}))

    screen =
      Pokex.PngFixtures.write!(Path.join(tmp, "screen.png"), rows(200, 150, {9, 9, 9, 255}))

    {:ok, _} = Fake.start_link(%{capture: [{:ok, probe}], capture_screen: [{:ok, screen}]})

    {:ok, view, _} = live(conn, ~p"/calibration")

    html = view |> element("button", "Só o minigame") |> render_click()

    # from the character: centre 12 to his right, 24 wide, 16 above him, 474 down
    suggestion = {100, 44, 24, 474}
    assert has_element?(view, "#mini-game-suggestion")
    assert html =~ inspect(suggestion)
    # drawn on the photo, not just described
    assert has_element?(view, "#calibration-screen")
    assert html =~ "mini-game-region"

    view |> element("#use-suggested-mini-game") |> render_click()

    assert {:ok, calib} = Calibration.load()
    assert calib.mini_game_region == suggestion
    assert render(view) =~ "Faixa do minigame salva"
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

  describe "position & minimap (3 clicks + band search, the hand rules)" do
    @tag :tmp_dir
    # the calibration "photo" is a real capture: after the 3 clicks the band is
    # FOUND by hovering (through the Body) and reading — and the saved band must
    # re-read on the save verdict
    test "marks minimap+cross, the search finds the band, saving reads it back", %{
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
      cross = {mx + div(mw, 2), my + div(mh, 2)}
      click.(elem(cross, 0), elem(cross, 1))

      # the cross was the last click: the band search hovers (through the Body)
      # and reads the coordinate off the fresh shot — living proof on screen
      html = render(view)
      assert html =~ ~s(id="coord-band-found")
      assert html =~ "li: (337, 46107, 4)"
      assert {:hover, ^cross} = Enum.find(Fake.calls(), &match?({:hover, _}, &1))

      html = view |> element("button", "Salvar assim") |> render_click()
      assert html =~ "salvos"
      assert html =~ "li a coordenada da foto: (337, 46107, 4)"

      assert {:ok, calib} = Calibration.load()
      assert calib.minimap_region == {mx, my, mw, mh}
      assert calib.minimap_player_point == cross
      assert calib.water_point == {50, 30}

      # the found band agrees with where the layout knows the strip lives
      {bx, by, bw, bh} = calib.minimap_coord_region
      assert by >= cy - 6 and by + bh <= cy + ch + 6
      assert bx >= cx - 6 and bx <= cx + 12
      assert bw >= div(cw, 2)
    end

    @tag :tmp_dir
    # the hand still rules: "Marcar na mão" falls back to the 2-click band —
    # and the screenshot being marked is by then the HOVER shot, the first
    # picture that actually CONTAINS the numbers
    test "the manual fallback still marks the band by hand", %{conn: conn, tmp_dir: tmp} do
      Application.put_env(:pokex, :home_dir, tmp)
      on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

      Calibration.save(%Calibration{scale: 1.0, screen_w: 3440, screen_h: 1440})

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
      click.(mx + mw, my + mh)
      click.(mx + div(mw, 2), my + div(mh, 2))

      view |> element("button", "Marcar na mão") |> render_click()
      assert render(view) =~ "COORDENADA"

      click.(cx, cy)
      html = click.(cx + cw, cy + ch)

      assert html =~ "salvos"
      assert html =~ "li a coordenada da foto: (337, 46107, 4)"
      assert {:ok, calib} = Calibration.load()
      assert calib.minimap_coord_region == {cx, cy, cw, ch}
      assert calib.minimap_region == {mx, my, mw, mh}
    end
  end
end
