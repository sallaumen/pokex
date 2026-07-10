defmodule PokexWeb.CalibrationLiveTest do
  use PokexWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Pokex.{Calibration, Settings}

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
  test "full wizard produces a saved calibration", %{conn: conn, tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)
    Settings.put(:skill_keys, ["6", "5", "4", "3", "2", "1"])

    probe = Pokex.PngFixtures.write!(Path.join(tmp, "probe.png"), rows(200, 200, {9, 9, 9, 255}))

    screen =
      Pokex.PngFixtures.write!(Path.join(tmp, "screen.png"), rows(200, 150, {9, 9, 9, 255}))

    glow = Pokex.PngFixtures.write!(Path.join(tmp, "glow.png"), rows(8, 8, {0, 60, 120, 255}))

    {:ok, _} =
      Pokex.Rig.Fake.start_link(%{
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
      render_hook(view, "img_click", %{
        "x" => x,
        "y" => y,
        "cw" => 50.0,
        "ch" => 37.5,
        "nw" => 200.0,
        "nh" => 150.0
      })
    end

    # water → point {50, 30}
    click.(25.0, 15.0)
    assert render(view) =~ "SUPERIOR-ESQUERDO"
    # battle_a → {70, 10}
    click.(35.0, 5.0)
    # battle_b → {90, 40}
    click.(45.0, 20.0)
    # arena_a → {20, 20}
    click.(10.0, 10.0)
    # arena_b → {80, 60}
    click.(40.0, 30.0)
    # neutral → {52, 36}
    click.(26.0, 18.0)

    assert render(view) =~ "7/8"
    # skill_a → {10, 60}
    click.(5.0, 30.0)
    assert render(view) =~ "8/8"
    # skill_b → {58, 70}; count is the explicit value entered before capture.
    click.(29.0, 35.0)

    assert render(view) =~ "linhas de base"
    view |> element("button", "Capturar linhas de base") |> render_click()

    Process.sleep(300)
    assert render(view) =~ "Calibração salva"

    assert {:ok, calib} = Calibration.load()
    assert calib.scale == 2.0
    assert calib.screen_w == 100
    assert calib.screen_h == 75
    assert calib.water_point == {50, 30}
    assert calib.glow_region == {18, -2, 64, 64}
    assert calib.battle_region == {70, 10, 20, 30}
    assert calib.arena_region == {20, 20, 60, 40}
    assert calib.neutral_point == {52, 36}
    assert calib.skill_bar_region == {10, 60, 48, 10}
    assert calib.skill_bar_count == 8
    assert Settings.get(:skill_keys) == ["6", "5", "4", "3", "2", "1", "7", "8"]
    assert length(calib.glow_baselines) == 10
    assert calib.suggested_glow_threshold == 12.0
    assert Enum.all?(calib.glow_baselines, &File.exists?/1)
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
      arena_region: {20, 20, 60, 40},
      skill_bar_region: {10, 60, 50, 10},
      skill_bar_count: 6,
      neutral_point: {52, 36},
      glow_baselines: [],
      suggested_glow_threshold: 15.0
    })

    probe = Pokex.PngFixtures.write!(Path.join(tmp, "probe.png"), rows(200, 200, {9, 9, 9, 255}))

    screen =
      Pokex.PngFixtures.write!(Path.join(tmp, "screen.png"), rows(200, 150, {9, 9, 9, 255}))

    {:ok, _} =
      Pokex.Rig.Fake.start_link(%{
        capture: [{:ok, probe}],
        capture_screen: [{:ok, screen}]
      })

    {:ok, view, _html} = live(conn, ~p"/calibration")
    html = view |> element("button", "Revisar áreas salvas") |> render_click()

    assert html =~ "Áreas que o bot está usando"
    assert html =~ "janela Battle"
    # battle_region left = 70/100 = 70%; arena left = 20/100 = 20%
    assert html =~ "left:70.0%"
    assert html =~ "left:20.0%"
    assert html =~ "skills"

    # the per-row lock bands (red) and the player marker are the new, diagnostic
    # overlays — each battle row gets an L<i> band, and the player point is drawn
    assert html =~ "bandas do lock"
    assert html =~ "L0"
    assert html =~ "L5"
    assert html =~ ~s(title="player")
  end

  @tag :tmp_dir
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
      arena_region: {20, 20, 60, 40},
      neutral_point: {52, 36},
      glow_baselines: [],
      suggested_glow_threshold: 15.0
    })

    probe = Pokex.PngFixtures.write!(Path.join(tmp, "probe.png"), rows(200, 200, {9, 9, 9, 255}))

    screen =
      Pokex.PngFixtures.write!(Path.join(tmp, "screen.png"), rows(200, 150, {9, 9, 9, 255}))

    {:ok, _} =
      Pokex.Rig.Fake.start_link(%{capture: [{:ok, probe}], capture_screen: [{:ok, screen}]})

    {:ok, view, _} = live(conn, ~p"/calibration")

    view
    |> form("#skill-count-form", skill_bar: %{count: "6"})
    |> render_change()

    view |> element("button", "Recalibrar só as skills") |> render_click()
    assert render(view) =~ "7/8"

    click = fn x, y ->
      render_hook(view, "img_click", %{
        "x" => x,
        "y" => y,
        "cw" => 50.0,
        "ch" => 37.5,
        "nw" => 200.0,
        "nh" => 150.0
      })
    end

    # skill_a → {20, 20}
    click.(10.0, 10.0)
    assert render(view) =~ "8/8"
    # skill_b → {80, 60}
    click.(40.0, 30.0)

    assert render(view) =~ "Barra salva com"
    assert {:ok, calib} = Calibration.load()
    assert calib.skill_bar_region == {20, 20, 60, 40}
    assert calib.skill_bar_count == 6
    # the rest of the calibration is untouched
    assert calib.water_point == {50, 30}
    assert calib.battle_region == {70, 10, 20, 30}
  end

  @tag :tmp_dir
  test "standalone Pokémon-HP calibration merges the HP region + photo point", %{
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
      arena_region: {20, 20, 60, 40},
      neutral_point: {52, 36},
      glow_baselines: [],
      suggested_glow_threshold: 15.0
    })

    probe = Pokex.PngFixtures.write!(Path.join(tmp, "probe.png"), rows(200, 200, {9, 9, 9, 255}))

    screen =
      Pokex.PngFixtures.write!(Path.join(tmp, "screen.png"), rows(200, 150, {9, 9, 9, 255}))

    {:ok, _} =
      Pokex.Rig.Fake.start_link(%{capture: [{:ok, probe}], capture_screen: [{:ok, screen}]})

    {:ok, view, _} = live(conn, ~p"/calibration")

    view |> element("button", "Calibrar vida do Pokémon") |> render_click()
    assert render(view) =~ "barra de VIDA"

    click = fn x, y ->
      render_hook(view, "img_click", %{
        "x" => x,
        "y" => y,
        "cw" => 50.0,
        "ch" => 37.5,
        "nw" => 200.0,
        "nh" => 150.0
      })
    end

    # hp_a → {20, 20}
    click.(10.0, 10.0)
    assert render(view) =~ "MESMA barra de vida"
    # hp_b → {80, 60} → region {20, 20, 60, 40}
    click.(40.0, 30.0)
    assert render(view) =~ "FOTO"
    # photo → {40, 50}
    click.(20.0, 25.0)

    assert render(view) =~ "Vida do Pokémon calibrada"
    assert {:ok, calib} = Calibration.load()
    assert calib.pokemon_hp_region == {20, 20, 60, 40}
    assert calib.pokemon_photo_point == {40, 50}
    # the rest of the calibration is untouched
    assert calib.water_point == {50, 30}
    assert calib.battle_region == {70, 10, 20, 30}
  end
end
