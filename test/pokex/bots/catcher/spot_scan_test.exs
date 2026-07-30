defmodule Pokex.Bots.Catcher.SpotScanTest do
  # async: false — o acervo mora no home global (:home_dir) e os knobs são
  # Settings globais (stash restaura).
  use ExUnit.Case, async: false

  alias Pokex.Bots.Catcher.{CorpseLibrary, SpotScan}
  alias Pokex.{Calibration, SettingsStash}

  @moduletag :tmp_dir

  # tiles de 40px, raio 1, caixa de 24 — geometria pequena e exata pros testes
  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

    SettingsStash.stash!(
      tile_px: 40,
      corpse_scan_radius_tiles: 1,
      corpse_sprite_box_px: 24,
      corpse_match_min_similarity: 0.72
    )

    :ok
  end

  defp calib(overrides \\ []) do
    struct!(
      %Calibration{
        scale: 1.0,
        screen_w: 1000,
        screen_h: 700,
        water_point: {1, 1},
        glow_region: {0, 0, 8, 8},
        battle_region: {900, 0, 80, 400},
        arena_region: {100, 200, 200, 200},
        neutral_point: {500, 500},
        player_point: {200, 300}
      },
      overrides
    )
  end

  @red {230, 40, 40}
  @ground {100, 90, 60}

  # Captura injetada: pinta o CHÃO em toda a região pedida e um quadrado
  # vermelho de 24px centrado em cada ponto de TELA listado — o fake responde
  # relativo à região que o SpotScan pedir, como a captura real faria.
  defp capture_with_corpses_at(screen_points) do
    fn {rx, ry, rw, rh}, _filename ->
      frame =
        Pokex.FrameFixtures.of(rw, rh, fn x, y ->
          on_corpse? =
            Enum.any?(screen_points, fn {cx, cy} ->
              abs(x + rx - cx) <= 12 and abs(y + ry - cy) <= 12
            end)

          if on_corpse?, do: @red, else: @ground
        end)

      {:ok, frame}
    end
  end

  defp teach_red!(name \\ "Corsola") do
    solid = Pokex.FrameFixtures.of(24, 24, fn _x, _y -> @red end)
    {:ok, _n} = CorpseLibrary.add(name, solid)
    :ok
  end

  test "acha o corpo ensinado no tile vizinho: ponto certo, nome e score" do
    teach_red!("Corsola")

    # corpo no vizinho LESTE do personagem {200,300} → {240,300}
    obs = SpotScan.scan(calib(), capture_with_corpses_at([{240, 300}]))

    assert %{scanning?: true, corpses: [{240, 300}]} = obs
    assert %{name: "Corsola", score: score} = obs.known[{240, 300}]
    assert score >= 0.72
    assert is_integer(obs.captured_at)
  end

  test "chão puro (nenhum corpo conhecido) = observação VAZIA, não nil" do
    teach_red!()

    obs = SpotScan.scan(calib(), capture_with_corpses_at([]))

    assert %{scanning?: true, corpses: [], known: known} = obs
    assert known == %{}
  end

  test "acervo vazio = nenhum alvo mesmo com o corpo na tela" do
    obs = SpotScan.scan(calib(), capture_with_corpses_at([{240, 300}]))
    assert obs.corpses == []
  end

  test "o tile do PRÓPRIO âncora fica de fora (sprite vivo casaria por paleta)" do
    teach_red!()

    # "corpo" pintado exatamente onde o personagem está: nunca vira alvo
    obs = SpotScan.scan(calib(), capture_with_corpses_at([{200, 300}]))
    assert obs.corpses == []
  end

  test "o ponto estratégico do pokémon também é escaneado" do
    teach_red!()
    c = calib(pokemon_spot_point: {160, 240})

    # corpo no vizinho NORTE do pokémon → {160, 200}... fora da arena (y < 200
    # + meia caixa); usa o vizinho LESTE {200, 240}, dentro dela
    obs = SpotScan.scan(c, capture_with_corpses_at([{200, 240}]))

    assert {200, 240} in obs.corpses
  end

  test "a região capturada nunca sai da ARENA (a quarentena do broker rejeitaria)" do
    teach_red!()
    {ax, ay, aw, ah} = calib().arena_region
    test_pid = self()

    capture = fn {rx, ry, rw, rh} = region, _filename ->
      send(test_pid, {:region, region})
      assert rx >= ax and ry >= ay and rx + rw <= ax + aw and ry + rh <= ay + ah

      {:ok, Pokex.FrameFixtures.of(rw, rh, fn _x, _y -> @ground end)}
    end

    # âncora colado no canto da arena: os vizinhos de fora são recortados
    obs = SpotScan.scan(calib(player_point: {110, 210}), capture)

    assert %{corpses: []} = obs
    assert_received {:region, _region}
  end

  test "sem calibração de arena, o scan é nil (passo cego, nunca crash)" do
    assert SpotScan.scan(calib(arena_region: nil), capture_with_corpses_at([])) == nil
  end
end
