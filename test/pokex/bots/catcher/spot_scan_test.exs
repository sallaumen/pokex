defmodule Pokex.Bots.Catcher.SpotScanTest do
  # async: false — o acervo mora no home global (:home_dir) e os knobs são
  # Settings globais (stash restaura).
  use ExUnit.Case, async: false

  alias Pokex.Bots.Catcher.{CorpseLibrary, SpotScan}
  alias Pokex.{Calibration, SettingsStash}

  @moduletag :tmp_dir

  # Geometria pequena e exata: tile 40, caixa 24, passo grosso 20, refino 4.
  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

    SettingsStash.stash!(
      tile_px: 40,
      corpse_scan_radius_tiles: 2,
      corpse_sprite_box_px: 24,
      corpse_scan_step_px: 20,
      corpse_scan_refine_px: 4,
      corpse_scan_refine_peaks: 4,
      corpse_match_min_similarity: 0.72,
      corpse_match_tolerance_px: 32
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
        player_point: {500, 400}
      },
      overrides
    )
  end

  @red {230, 40, 40}
  @ground {100, 90, 60}

  # Captura injetada: chão em toda a região pedida, e um quadrado vermelho de
  # 24px centrado em cada ponto de TELA listado.
  defp capture_with_corpses_at(screen_points) do
    fn {rx, ry, rw, rh}, _filename ->
      frame =
        Pokex.FrameFixtures.of(rw, rh, fn x, y ->
          dentro? =
            Enum.any?(screen_points, fn {cx, cy} ->
              abs(x + rx - cx) <= 12 and abs(y + ry - cy) <= 12
            end)

          if dentro?, do: @red, else: @ground
        end)

      {:ok, frame}
    end
  end

  defp teach_red!(name \\ "Corsola") do
    solid = Pokex.FrameFixtures.of(24, 24, fn _x, _y -> @red end)
    {:ok, _n} = CorpseLibrary.add(name, solid)
    :ok
  end

  describe "o quadradão dinâmico (R1)" do
    test "a região é centrada no personagem e IGNORA a arena calibrada" do
      teach_red!()
      test_pid = self()

      capture = fn {_rx, _ry, rw, rh} = region, _f ->
        send(test_pid, {:region, region})
        {:ok, Pokex.FrameFixtures.of(rw, rh, fn _x, _y -> @ground end)}
      end

      # a arena {100,200,200,200} termina em y=400 e NÃO contém o personagem em
      # y=600 — o caso real do Lucas (arena até 642, personagem em 697)
      SpotScan.scan(calib(player_point: {500, 600}, arena_region: {100, 200, 200, 200}), capture)

      assert_received {:region, {rx, ry, rw, rh}}
      # 2 tiles de raio, tile 40 → lado (2*2+1)*40 = 200, centrado em (500,600)
      assert {rx, ry, rw, rh} == {400, 500, 200, 200}
    end

    test "funciona SEM arena nenhuma calibrada" do
      teach_red!()

      obs =
        SpotScan.scan(
          calib(arena_region: nil, player_point: {500, 400}),
          capture_with_corpses_at([{540, 400}])
        )

      assert obs.scanning?
      assert obs.corpses != []
    end

    test "sem personagem marcado, o centro é o da TELA (não o da arena)" do
      teach_red!()
      test_pid = self()

      capture = fn region, _f ->
        send(test_pid, {:region, region})
        {:ok, Pokex.FrameFixtures.of(elem(region, 2), elem(region, 3), fn _x, _y -> @ground end)}
      end

      SpotScan.scan(calib(player_point: nil), capture)

      # centro da tela 1000x700 = (500,350); lado 200 → canto (400,250)
      assert_received {:region, {400, 250, 200, 200}}
    end

    test "a região nunca sai da TELA (a quarentena do broker rejeitaria)" do
      teach_red!()
      test_pid = self()

      capture = fn {rx, ry, rw, rh} = region, _f ->
        send(test_pid, {:region, region})
        assert rx >= 0 and ry >= 0 and rx + rw <= 1000 and ry + rh <= 700
        {:ok, Pokex.FrameFixtures.of(rw, rh, fn _x, _y -> @ground end)}
      end

      SpotScan.scan(calib(player_point: {20, 20}), capture)
      assert_received {:region, _}
    end

    test "o quadrado ABRAÇA o ponto do pokémon quando ele cai fora" do
      teach_red!()
      test_pid = self()

      capture = fn {_rx, _ry, rw, rh} = region, _f ->
        send(test_pid, {:region, region})
        {:ok, Pokex.FrameFixtures.of(rw, rh, fn _x, _y -> @ground end)}
      end

      # pokémon 300px acima do personagem: fora do quadrado de lado 200
      SpotScan.scan(calib(player_point: {500, 500}, pokemon_spot_point: {500, 200}), capture)

      assert_received {:region, {_rx, ry, _rw, rh}}
      assert ry <= 160, "o topo tem que subir pra abraçar o pokémon (com folga de 1 tile)"
      assert ry + rh >= 600
    end
  end

  describe "a varredura densa (mata o desalinhamento de grade)" do
    test "acha o corpo mesmo FORA de qualquer grade de tile" do
      teach_red!("Kingler")

      # 537,417: deslocado de propósito de qualquer múltiplo de tile a partir do
      # personagem (500,400) — na treliça antiga, esta caixa cairia no chão e o
      # score seria ~0,39, exatamente o que o Lucas mediu com Kingler no chão.
      obs = SpotScan.scan(calib(), capture_with_corpses_at([{537, 417}]))

      assert [ponto] = obs.corpses
      assert %{name: "Kingler", score: score} = obs.known[ponto]
      assert score > 0.9, "a janela vencedora deve enquadrar quase igual ao ensino"
    end

    test "a mira é o CENTRO do corpo, não a borda nem o centro do tile (R2)" do
      teach_red!()

      obs = SpotScan.scan(calib(), capture_with_corpses_at([{537, 417}]))

      assert [{x, y}] = obs.corpses
      # o corpo desenhado tem centro em (537,417); a janela vencedora deve
      # centrar praticamente em cima dele (tolerância do passo de refino)
      assert abs(x - 537) <= 6, "mira fora do centro em x: #{x}"
      assert abs(y - 417) <= 6, "mira fora do centro em y: #{y}"
    end

    test "dois corpos viram DOIS alvos — e um corpo só vira um" do
      teach_red!()

      obs = SpotScan.scan(calib(), capture_with_corpses_at([{450, 350}, {560, 460}]))

      assert length(obs.corpses) == 2, "esperava 2 alvos, veio #{inspect(obs.corpses)}"
    end

    test "chão puro não vira alvo, e o melhor reprovado ainda tem nome e score" do
      teach_red!("Corsola")

      obs = SpotScan.scan(calib(), capture_with_corpses_at([]))

      assert obs.corpses == []
      assert %{name: "Corsola", score: score} = obs.melhor
      assert score < obs.limiar
    end

    test "acervo vazio: nenhum alvo, melhor nil, e nada explode" do
      obs = SpotScan.scan(calib(), capture_with_corpses_at([{537, 417}]))

      assert obs.corpses == []
      assert obs.melhor == nil
      assert obs.janelas == 0
    end
  end

  describe "os âncoras vivos não viram alvo" do
    test "o tile do personagem é zona proibida (sprite vivo casaria por paleta)" do
      teach_red!()

      # "corpo" pintado exatamente em cima do personagem
      obs = SpotScan.scan(calib(), capture_with_corpses_at([{500, 400}]))

      assert obs.corpses == []
    end

    test "o tile do pokémon também" do
      teach_red!()
      c = calib(pokemon_spot_point: {560, 400})

      obs = SpotScan.scan(c, capture_with_corpses_at([{560, 400}]))

      assert obs.corpses == []
    end
  end

  describe "diagnóstico (fatia 1, preservado)" do
    test "cegueira tem NOME e nunca confirma bola em voo" do
      obs = SpotScan.scan(calib(screen_w: nil, screen_h: nil, player_point: nil), nil)

      assert %{scanning?: false, motivo: :sem_ancora, corpses: []} = obs
    end

    test "a observação conta as janelas pontuadas" do
      teach_red!()

      obs = SpotScan.scan(calib(), capture_with_corpses_at([]))

      assert obs.janelas > 0
      assert obs.limiar == 0.72
      assert {_x, _y, _w, _h} = obs.regiao
    end
  end
end
