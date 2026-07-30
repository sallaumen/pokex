defmodule Pokex.Perception.InterpretMinimapTest do
  @moduledoc """
  A posição do personagem, do jeito que o CAVEBOT a recebe (2026-07-30).

  O interpretador deixou de falar direto com o layout: as regiões vêm da
  `Calibration` (a MÃO manda, layout é fallback) e o piso de tinta da faixa
  virou o setting `minimap_coord_ink`. O default é 120 — o comportamento
  provado: MEDIMOS que os dígitos têm núcleo 240+ mas o anti-alias espalha por
  160-239, e o atlas foi ensinado com as formas do piso 120; subir o piso
  emagrece as formas e cega o atlas (165 falhou as quatro capturas reais). O
  knob existe pra afinar ao vivo COM a tela de ensinar glifos à mão.
  """
  use ExUnit.Case, async: true

  alias Pokex.{Calibration, Layout, ScreenFixtures}
  alias Pokex.Perception.Interpret.Minimap
  alias Pokex.Vision.Frame

  @coords %{
    "ultrawide_3440x1440_full" => {337, 46_107, 4},
    "ultrawide_3440x1440_outro_mapa" => {2782, 30_571, 5},
    "ultrawide_3440x1440_terceiro" => {2777, 30_560, 5},
    "ultrawide_3440x1440_time" => {2597, 30_640, 6}
  }

  defp located(name) do
    frame = ScreenFixtures.frame!(name)
    {:ok, fix} = Layout.locate(frame)
    panel = Frame.crop(frame, Layout.region(:minimap, fix))
    {fix, panel}
  end

  test "o piso default lê as QUATRO capturas reais via layout-fallback" do
    for {name, expected} <- @coords do
      {fix, panel} = located(name)
      calib = %Calibration{scale: 1.0, layout: fix}

      assert {%{pos: ^expected}, _state} = Minimap.interpret(panel, calib, %{}, nil),
             "não li a coordenada de #{name}"
    end
  end

  test "regiões marcadas À MÃO leem sem layout nenhum — o caminho do drift" do
    {fix, panel} = located("ultrawide_3440x1440_time")

    # o que o Lucas marcaria na calibração: exatamente onde as regiões estão
    calib = %Calibration{
      scale: 1.0,
      layout: nil,
      minimap_region: Layout.region(:minimap, fix),
      minimap_coord_region: Layout.region(:minimap_coord, fix)
    }

    assert {%{pos: {2597, 30_640, 6}}, _state} = Minimap.interpret(panel, calib, %{}, nil)
  end

  test "a marcação manual VENCE um layout presente" do
    {fix, panel} = located("ultrawide_3440x1440_time")

    # layout presente mas com a marcação manual apontando pras mesmas regiões:
    # o resultado tem que vir do caminho manual (idêntico, e é isso que prova
    # que ele existe — um layout DESLOCADO com manual certo leria errado no
    # caminho antigo)
    calib = %Calibration{
      scale: 1.0,
      layout: fix,
      minimap_region: Layout.region(:minimap, fix),
      minimap_coord_region: Layout.region(:minimap_coord, fix)
    }

    assert {%{pos: {2597, 30_640, 6}}, _state} = Minimap.interpret(panel, calib, %{}, nil)
  end

  test "o knob minimap_coord_ink chega no leitor — um piso impossível cega" do
    {fix, panel} = located("ultrawide_3440x1440_full")
    calib = %Calibration{scale: 1.0, layout: fix}

    assert {%{pos: nil}, _state} =
             Minimap.interpret(panel, calib, %{minimap_coord_ink: 255}, nil)
  end

  test "sem região nenhuma (nem mão, nem layout) → pos nil, nunca crash" do
    {_fix, panel} = located("ultrawide_3440x1440_full")
    calib = %Calibration{scale: 1.0, layout: nil}

    assert {%{pos: nil}, _state} = Minimap.interpret(panel, calib, %{}, nil)
    assert {%{pos: nil}, _state} = Minimap.interpret(panel, nil, %{}, nil)
  end

  describe "resolvedores da Calibration" do
    test "mão vence layout; layout é fallback; nada = nil" do
      {fix, _panel} = located("ultrawide_3440x1440_full")

      manual = %Calibration{
        scale: 1.0,
        layout: fix,
        minimap_region: {10, 20, 300, 400},
        minimap_coord_region: {12, 22, 160, 30},
        minimap_player_point: {160, 220}
      }

      assert Calibration.minimap_region(manual) == {10, 20, 300, 400}
      assert Calibration.minimap_coord_region(manual) == {12, 22, 160, 30}
      assert Calibration.minimap_map_region(manual) == {10, 20, 300, 400}
      assert Calibration.minimap_player_point(manual) == {160, 220}

      fallback = %Calibration{scale: 1.0, layout: fix}
      assert Calibration.minimap_region(fallback) == Layout.region(:minimap, fix)
      assert Calibration.minimap_map_region(fallback) == Layout.region(:minimap_map, fix)
      # sem cruz marcada: o centro do retângulo do mapa, como o passo sempre assumiu
      {mx, my, mw, mh} = Layout.region(:minimap_map, fix)
      assert Calibration.minimap_player_point(fallback) == {mx + div(mw, 2), my + div(mh, 2)}

      blind = %Calibration{scale: 1.0, layout: nil}
      assert Calibration.minimap_region(blind) == nil
      assert Calibration.minimap_player_point(blind) == nil
    end

    @tag :tmp_dir
    test "os três campos novos fazem round-trip no arquivo", %{tmp_dir: tmp} do
      path = Path.join(tmp, "calibration.json")

      calib = %Calibration{
        scale: 1.0,
        screen_w: 3440,
        screen_h: 1440,
        water_point: {1, 2},
        glow_region: {0, 0, 4, 4},
        battle_region: {0, 0, 4, 4},
        arena_region: {0, 0, 4, 4},
        neutral_point: {3, 4},
        minimap_region: {3150, 100, 290, 458},
        minimap_player_point: {3295, 329},
        minimap_coord_region: {3171, 106, 160, 30}
      }

      Calibration.save(calib, path)
      {:ok, loaded} = Calibration.load(path)

      assert loaded.minimap_region == {3150, 100, 290, 458}
      assert loaded.minimap_player_point == {3295, 329}
      assert loaded.minimap_coord_region == {3171, 106, 160, 30}
    end
  end
end
