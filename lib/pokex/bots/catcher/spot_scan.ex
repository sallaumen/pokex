defmodule Pokex.Bots.Catcher.SpotScan do
  @moduledoc """
  A visão da captura ANCORADA NO KILL (2026-07-30).

  O detector de chão (baseline + diff + rastreamento) exigia uma janela QUIETA
  pro aquecimento — e a operação real (pesca fisgando sem parar, combate em
  Tab/luta contínua) não tem janela quieta nunca: o aquecimento acontecia com
  luta na tela, mascarava exatamente os tiles onde os corpos caem, e a captura
  passava a sessão inteira MUDA enquanto o saque (ancorado no kill, sem visão
  nenhuma) funcionava ao lado. Visto ao vivo pelo Lucas: "só vejo ele tentando
  saquear, não reconhecer corpo, e nunca vi jogar a bola".

  O combate do PXG é tile-locked: quando um kill acontece, o corpo só pode
  estar nos tiles VIZINHOS de quem lutou — o personagem e/ou o pokémon no
  ponto estratégico. Então a visão vira pergunta direta: fotografa UMA vez a
  região desses tiles, recorta uma caixa por tile e pergunta ao acervo
  ensinado (`Pokex.Bots.Catcher.CorpseLibrary`): "isso é um corpo que eu
  conheço?". Sem baseline, sem aquecimento, sem rastreamento — o gatilho é o
  kill e a testemunha é o acervo.

  Devolve a MESMA observação que o detector antigo publicava
  (`%{scanning?, corpses, known, captured_at}`), então `Catcher.Logic` — fila,
  uma bola em voo, confirmação contra frames pós-voo, retry, ignore-TTL —
  segue intocado: a confirmação re-escaneia os mesmos tiles (corpo que sumiu =
  capturado; corpo que ficou = retry/ignore).
  """

  alias Pokex.Bots.Capture
  alias Pokex.Bots.Catcher.CorpseLibrary
  alias Pokex.{Calibration, Settings}
  alias Pokex.Vision.Frame

  @doc "Carrega a calibração vigente e escaneia. nil quando não dá pra ver (sem calibração)."
  def scan do
    case Calibration.load() do
      {:ok, calib} -> scan(calib)
      _sem_calibracao -> nil
    end
  end

  @doc """
  Escaneia os tiles vizinhos dos âncoras contra o acervo.

  `capture` é injetável nos testes (mesma seam do resto dos workers); o
  default é o broker serializado. nil quando a captura falha ou não há
  âncora/arena — uma observação nil é um passo que não prova nada, nunca uma
  confirmação falsa.
  """
  def scan(%Calibration{} = calib, capture \\ &Capture.frame/2) do
    points = candidate_points(calib)

    with [_ | _] <- points,
         {:ok, region} <- scan_region(points, calib),
         {:ok, %Frame{} = frame} <- capture.(region, "corpse_scan.png") do
      box = Settings.get(:corpse_sprite_box_px)
      min = Settings.get(:corpse_match_min_similarity)

      known =
        for point <- points,
            crop = tile_crop(frame, calib, region, point, box),
            crop != nil,
            {:ok, info} <- [CorpseLibrary.match(crop, min)],
            into: %{} do
          {point, info}
        end

      %{
        scanning?: true,
        corpses: known |> Map.keys() |> Enum.sort(),
        known: known,
        captured_at: System.monotonic_time(:millisecond)
      }
    else
      _sem_visao -> nil
    end
  end

  # Os tiles onde um corpo PODE ter caído: o anel de vizinhança (raio em
  # tiles) ao redor do personagem e do ponto estratégico do pokémon (quem luta
  # é ele). Os centros ficam de fora — são os tiles OCUPADOS pelos âncoras
  # vivos, e um sprite vivo da mesma espécie casaria com o corpo ensinado por
  # paleta. Tudo em pontos de TELA; tile visto pelos dois âncoras conta uma vez.
  defp candidate_points(calib) do
    tile = Settings.get(:tile_px)
    radius = Settings.get(:corpse_scan_radius_tiles)

    anchors =
      [Calibration.player_point(calib), calib.pokemon_spot_point]
      |> Enum.reject(&is_nil/1)

    for {ax, ay} <- anchors,
        dx <- -radius..radius,
        dy <- -radius..radius,
        not (dx == 0 and dy == 0),
        uniq: true do
      {ax + dx * tile, ay + dy * tile}
    end
  end

  # UMA captura pequena cobrindo todos os tiles candidatos (+ meia caixa de
  # folga), recortada pra dentro da arena — capturar a arena inteira a cada
  # confirmação custaria décimos de segundo de decode por tick; isto custa
  # milissegundos. Recortar pra dentro da arena também garante que a região
  # nunca sai da tela (a quarentena do broker rejeitaria).
  defp scan_region(points, %Calibration{arena_region: {ax, ay, aw, ah}}) do
    half = div(Settings.get(:corpse_sprite_box_px), 2) + 1
    {xs, ys} = {Enum.map(points, &elem(&1, 0)), Enum.map(points, &elem(&1, 1))}

    left = max(Enum.min(xs) - half, ax)
    top = max(Enum.min(ys) - half, ay)
    right = min(Enum.max(xs) + half, ax + aw)
    bottom = min(Enum.max(ys) + half, ay + ah)

    if right > left and bottom > top,
      do: {:ok, {left, top, right - left, bottom - top}},
      else: :fora_da_arena
  end

  defp scan_region(_points, _sem_arena), do: :sem_arena

  # Ponto de TELA → px do frame da REGIÃO capturada (o inverso de
  # frame_to_screen, com a origem da região no lugar da arena). Tile fora do
  # frame não tem recorte — um âncora na borda da arena perde os vizinhos de
  # fora, e é isso mesmo: fora da arena não cai corpo visível.
  defp tile_crop(%Frame{width: w, height: h} = frame, calib, {rx, ry, _rw, _rh}, {sx, sy}, box) do
    fx = round((sx - rx) * calib.scale)
    fy = round((sy - ry) * calib.scale)

    if fx in 0..(w - 1) and fy in 0..(h - 1) do
      half = div(box, 2)
      cx = fx |> max(half) |> min(max(w - half, half))
      cy = fy |> max(half) |> min(max(h - half, half))
      Frame.crop(frame, {cx - half, cy - half, min(box, w), min(box, h)})
    end
  end
end
