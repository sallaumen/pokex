defmodule Pokex.Bots.Catcher.SpotScan do
  @moduledoc """
  A visão da captura: ancorada no KILL, VARRIDA densamente ao redor do
  personagem.

  ## Por que é ancorada no kill (2026-07-30)

  O detector de chão (baseline + diff + rastreamento) exigia uma janela QUIETA
  pro aquecimento — e a operação real (pesca fisgando sem parar, combate em
  Tab/luta contínua) não tem janela quieta nunca: o aquecimento acontecia com
  luta na tela, mascarava exatamente os tiles onde os corpos caem, e a captura
  passava a sessão inteira MUDA enquanto o saque (ancorado no kill, sem visão
  nenhuma) funcionava ao lado.

  ## Por que a busca é DENSA, e não numa grade de tiles (2026-07-30, medido)

  A primeira versão mirava numa treliça sintética: `âncora ± N × tile_px`. Três
  defeitos a mataram no campo, todos medidos nos arquivos do Lucas:

    1. **A arena decapitava o anel.** A região era recortada contra
       `arena_region`, e a arena dele (y 217..642) não contém o personagem
       (y 697): a fileira dele e a sul nunca eram olhadas. Log ao vivo:
       `olhei 11/16 tiles (5 fora do quadro)`.
    2. **Duas treliças fora de fase.** Os pontos vinham de `player_point` E
       `pokemon_spot_point`, marcados em passos diferentes do wizard. A
       diferença entre eles, em módulo de tile, era (28, 26) — nem 0 nem 88.
       Acertar a fase de um desalinhava o outro, e é o pokémon quem mata.
    3. **Ensinar e buscar enquadravam diferente.** A calibração recorta a caixa
       em torno do CLIQUE do Lucas (em cima do bicho); a busca recortava em
       torno do CENTRO GEOMÉTRICO do tile. Medido nas duas amostras de Cloyster
       dele: no enquadramento ensinado o score é 1,000; nas grades, 0,56..0,87.
       Com Kingler no chão ao vivo, o melhor foi **0,39** — caixa de chão puro.

  A varredura densa mata os três de uma vez: desliza a caixa do tamanho do
  ensino por TODA a região (passo grosso + refino ao redor dos picos) e fica com
  o máximo. Não existe mais "fase de grade" pra errar, e o enquadramento
  vencedor é, por construção, o mais parecido com o que foi ensinado.

  ## E a mira sai de graça

  O ponto arremessado é o CENTRO DA JANELA VENCEDORA — não o centro de um tile.
  Como o ensino centra no clique do Lucas em cima do corpo, a bola herda
  automaticamente a mira que ele escolheu ao fotografar. (O commit 2f21811 já
  tinha atacado isso com constantes `capture_aim_up_px`/`left_px`, apagadas
  depois numa faxina; a janela vencedora é a mesma correção sem chute.)

  ## O quadradão

  A região é um quadrado de `(2r+1)` tiles centrado no personagem, clampado na
  TELA — nunca mais na arena. `corpse_scan_radius_tiles` manda no raio. Se o
  ponto do pokémon estiver calibrado e cair fora, o quadrado cresce só o
  suficiente pra abraçá-lo: quem luta é ele, e o corpo cai do lado dele.

  Devolve a MESMA forma de observação que a `Catcher.Logic` já consome
  (`%{scanning?, corpses, known, captured_at}`) mais o diagnóstico da fatia 1
  (`janelas`, `melhor`, `motivo`), então fila/bola-em-voo/confirmação/retry
  seguem intocados.
  """

  alias Pokex.Bots.Capture
  alias Pokex.Bots.Catcher.CorpseLibrary
  alias Pokex.{Calibration, Settings}
  alias Pokex.Vision.Frame

  @doc "Carrega a calibração vigente e varre. Observação cega quando não dá pra ver."
  def scan do
    case Calibration.load() do
      {:ok, calib} -> scan(calib)
      _sem_calibracao -> cego(:sem_calibracao)
    end
  end

  @doc """
  Varre o quadradão ao redor do personagem contra o acervo ensinado.

  SEMPRE devolve uma observação — nunca `nil`. Uma varredura que não achou nada
  e uma que não ACONTECEU eram o mesmo silêncio, e foi esse silêncio que fez o
  Lucas passar o dia sem saber se o problema era mira, acervo ou portão. A
  observação carrega o diagnóstico: `janelas` (quantas posições foram
  pontuadas), `melhor` (o melhor par `%{name, score, ponto}` mesmo REPROVADO),
  `regiao`, `limiar` e, quando cegou, `motivo`.

  Observação cega sai com `scanning?: false`: a `Catcher.Logic` trata isso como
  passo que não prova nada, então falha de visão nunca confirma bola em voo.

  `capture` é injetável nos testes (mesma seam do resto dos workers).
  """
  def scan(%Calibration{} = calib, capture \\ &Capture.frame/2) do
    with {:ok, centro} <- centro(calib),
         {:ok, region} <- scan_region(centro, calib),
         {:ok, %Frame{} = frame} <- capture.(region, "corpse_scan.png") do
      varrer(frame, calib, region, centro)
    else
      {:erro, motivo} -> cego(motivo)
      {:error, motivo} -> cego({:captura_falhou, motivo})
      outro -> cego({:captura_falhou, outro})
    end
  end

  @doc """
  A região que a busca varre — a MESMA que a calibração precisa fotografar pra
  ensinar um corpo.

  Existe porque ensinar e buscar precisam enxergar o mesmo pedaço de tela. A
  foto do ensino usava `arena_region` enquanto a busca já usava o quadradão:
  um corpo caído perto do personagem (fora da arena) simplesmente não cabia na
  foto, e o Lucas não conseguia clicar nele pra ensinar — visto ao vivo com um
  Gyarados cortado na borda de baixo (2026-07-30).

  `{:ok, {x, y, w, h}}` ou `{:erro, motivo}`.
  """
  def regiao(%Calibration{} = calib) do
    with {:ok, centro} <- centro(calib), do: scan_region(centro, calib)
  end

  # O centro da busca. O ponto marcado à mão manda; sem ele, o CENTRO DA TELA —
  # que na tela do Lucas cai a menos de meia casa do personagem real (medido:
  # (1720,720) contra (1688,697)). O fallback antigo era o centro da ARENA, que
  # na calibração dele fica 268px acima do personagem. Isto é o que permite
  # capturar SEM arena calibrada, como ele pediu.
  defp centro(%Calibration{player_point: {_x, _y} = ponto}), do: {:ok, ponto}

  defp centro(%Calibration{screen_w: w, screen_h: h}) when is_integer(w) and is_integer(h),
    do: {:ok, {div(w, 2), div(h, 2)}}

  defp centro(_sem_nada), do: {:erro, :sem_ancora}

  # O quadradão: (2r+1) tiles centrado no personagem, esticado pra abraçar o
  # ponto do pokémon se ele cair fora, e clampado na TELA — nunca na arena (era
  # a arena que decapitava o anel). Clampar na tela também garante que a região
  # nunca sai do display, que é o que a quarentena do broker rejeitaria.
  defp scan_region({cx, cy}, %Calibration{screen_w: sw, screen_h: sh} = calib)
       when is_integer(sw) and is_integer(sh) do
    tile = max(Settings.get(:tile_px), 1)
    raio = max(Settings.get(:corpse_scan_radius_tiles), 1)
    meia = div((2 * raio + 1) * tile, 2)

    {left, top, right, bottom} =
      {cx - meia, cy - meia, cx + meia, cy + meia}
      |> abracar(calib.pokemon_spot_point, tile)

    left = max(left, 0)
    top = max(top, 0)
    right = min(right, sw)
    bottom = min(bottom, sh)

    box = Settings.get(:corpse_sprite_box_px)

    if right - left >= box and bottom - top >= box,
      do: {:ok, {left, top, right - left, bottom - top}},
      else: {:erro, :quadro_pequeno_demais}
  end

  defp scan_region(_centro, _sem_tela), do: {:erro, :sem_tela}

  defp abracar(caixa, nil, _tile), do: caixa

  defp abracar({left, top, right, bottom}, {px, py}, tile) do
    {min(left, px - tile), min(top, py - tile), max(right, px + tile), max(bottom, py + tile)}
  end

  # A varredura: desliza a caixa do tamanho do ensino pela região inteira num
  # passo grosso, refina ao redor dos melhores picos, e fica com os máximos
  # locais que passam do limiar. Duas fases porque a fase fina sozinha custaria
  # ~40× mais janelas pelo mesmo resultado.
  defp varrer(%Frame{} = frame, calib, region, centro) do
    box = Settings.get(:corpse_sprite_box_px)
    min_sim = Settings.get(:corpse_match_min_similarity)
    passo = max(Settings.get(:corpse_scan_step_px), 1)
    refino = max(Settings.get(:corpse_scan_refine_px), 1)

    proibidos = zonas_proibidas(calib, region, box)

    grosso = pontuar(frame, janelas(frame, box, passo), box, proibidos)

    finas =
      grosso
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.take(Settings.get(:corpse_scan_refine_peaks))
      |> Enum.flat_map(&janelas_ao_redor(&1, frame, box, passo, refino))
      |> Enum.uniq()

    todas = grosso ++ pontuar(frame, finas, box, proibidos)

    alvos = picos(todas, min_sim, Settings.get(:corpse_match_tolerance_px))

    known =
      Map.new(alvos, fn %{x: x, y: y, name: nome, score: score} ->
        {centro_na_tela(x, y, box, calib, region), %{name: nome, score: score}}
      end)

    %{
      scanning?: true,
      corpses: known |> Map.keys() |> Enum.sort(),
      known: known,
      captured_at: System.monotonic_time(:millisecond),
      janelas: length(todas),
      regiao: region,
      centro: centro,
      limiar: min_sim,
      melhor: melhor(todas, box, calib, region)
    }
  end

  # Todas as posições da caixa dentro do frame, no passo dado.
  defp janelas(%Frame{width: w, height: h}, box, passo) do
    for y <- 0..max(h - box, 0)//passo, x <- 0..max(w - box, 0)//passo, do: {x, y}
  end

  # Ao redor de um pico grosso, o refino cobre ±passo em incrementos finos — é
  # onde os ~0,05 de score por 7px de deslocamento são recuperados.
  defp janelas_ao_redor(%{x: x, y: y}, %Frame{width: w, height: h}, box, passo, refino) do
    for dy <- -passo..passo//refino,
        dx <- -passo..passo//refino,
        nx = x + dx,
        ny = y + dy,
        nx >= 0 and ny >= 0 and nx + box <= w and ny + box <= h,
        do: {nx, ny}
  end

  defp pontuar(frame, posicoes, box, proibidos) do
    for {x, y} <- posicoes,
        not proibida?(x, y, box, proibidos),
        info = CorpseLibrary.best_in(frame, {x, y, box, box}),
        info != nil,
        do: %{x: x, y: y, name: info.name, score: info.score}
  end

  # Os tiles OCUPADOS pelos âncoras vivos: um sprite em pé da mesma espécie
  # casaria com o corpo ensinado por paleta, e a bola voaria no próprio pokémon
  # do Lucas. Guardamos o CENTRO de cada âncora em px do frame; qualquer janela
  # cujo centro caia a menos de meio tile dele é descartada.
  defp zonas_proibidas(calib, region, _box) do
    [calib.player_point, calib.pokemon_spot_point]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn {sx, sy} -> na_moldura(sx, sy, calib, region) end)
  end

  defp proibida?(x, y, box, proibidos) do
    meia_caixa = div(box, 2)
    limite = div(max(Settings.get(:tile_px), 1), 2)
    cx = x + meia_caixa
    cy = y + meia_caixa

    Enum.any?(proibidos, fn {px, py} -> abs(cx - px) < limite and abs(cy - py) < limite end)
  end

  # Máximos locais acima do limiar, com supressão de vizinhos: a varredura densa
  # produz um platô de janelas boas em cima do MESMO corpo, e sem isto cada
  # corpo viraria dezenas de alvos na fila.
  defp picos(candidatos, min_sim, tolerancia) do
    candidatos
    |> Enum.filter(&(&1.score >= min_sim))
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.reduce([], fn cand, aceitos ->
      if Enum.any?(aceitos, &perto?(&1, cand, tolerancia)),
        do: aceitos,
        else: [cand | aceitos]
    end)
    |> Enum.reverse()
  end

  defp perto?(%{x: ax, y: ay}, %{x: bx, y: by}, tolerancia),
    do: abs(ax - bx) <= tolerancia and abs(ay - by) <= tolerancia

  defp melhor([], _box, _calib, _region), do: nil

  defp melhor(candidatos, box, calib, region) do
    %{x: x, y: y, name: nome, score: score} = Enum.max_by(candidatos, & &1.score)
    %{name: nome, score: score, ponto: centro_na_tela(x, y, box, calib, region)}
  end

  # Canto da janela (px do frame) → CENTRO dela em ponto de tela. É a mira: o
  # ensino centra no clique do Lucas em cima do corpo, então o centro da janela
  # vencedora é o ponto que ele mesmo escolheu.
  defp centro_na_tela(x, y, box, %Calibration{scale: scale}, {rx, ry, _w, _h}) do
    meia = div(box, 2)
    {rx + round((x + meia) / scale), ry + round((y + meia) / scale)}
  end

  # Ponto de TELA → px do frame da região capturada (o inverso de
  # frame_to_screen, com a origem da região no lugar da arena).
  defp na_moldura(sx, sy, %Calibration{scale: scale}, {rx, ry, _w, _h}),
    do: {round((sx - rx) * scale), round((sy - ry) * scale)}

  defp cego(motivo) do
    %{
      scanning?: false,
      corpses: [],
      known: %{},
      captured_at: System.monotonic_time(:millisecond),
      janelas: 0,
      regiao: nil,
      centro: nil,
      limiar: nil,
      melhor: nil,
      motivo: motivo
    }
  end
end
