defmodule PokexWeb.CalibrationLiveTest do
  use PokexWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Pokex.Calibration

  defp rows(w, h, color), do: List.duplicate(List.duplicate(color, w), h)

  @tag :tmp_dir
  test "full wizard produces a saved calibration", %{conn: conn, tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

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
  end
end
