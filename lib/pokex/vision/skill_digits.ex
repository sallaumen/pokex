defmodule Pokex.Vision.SkillDigits do
  @moduledoc """
  A contagem que o JOGO escreve em cima da tecla em cooldown — lida como o que
  ela é: a resposta definitiva sobre prontidão.

  A leitura por referência de cor compara o slot com uma foto tirada na
  calibração, e ela falhou nas DUAS direções em dois dias seguidos: refs
  tirados com a skill carregando liam pronta como fria (27/08 de manhã), e
  refs corretos liam fria como pronta (noite de 27→28/08 — o Poké Alliance só
  escurece PARTE do ícone, e a distância do estado frio cai dentro do teto).
  Naquela noite foram 2.372 linhas de "não saiu": todo recibo mentia, o mute
  calava tecla boa, e o stun do resgate nunca confirmava.

  Enquanto isso o jogo escrevia `32`, `33`, `43`, `44` em cima das teclas — em
  branco com contorno preto, no topo do slot. Uma tecla esfriando SEMPRE tem
  esse número; uma pronta nunca tem. Este módulo procura exatamente isso.

  ## O que separa um dígito da arte do ícone (medido na captura real de 27/08)

    * **Miolo branco**: `min(r,g,b) >= 180` e saturação <= 40.
    * **Tamanho de glifo**: 2-10 px de largura, 5-11 de altura (por ponto de
      escala) — a explosão branca do ícone do slot 8 mede 15×20 e cai fora.
    * **Contorno preto**: >= 70% dos pixels do aglomerado encostam num vizinho
      quase-preto (`max(r,g,b) <= 60`). Os dígitos mediram 100%; a arte branca
      do slot 8, 8%.
    * **Zona**: a contagem vive na METADE DE CIMA do slot. O rótulo da tecla
      (1-9) usa a mesma fonte, mas mora embaixo — medido: contagem em y 8-15,
      rótulo em y 20-28 num frame de 38.

  Só a PRESENÇA decide o estado. O valor (quantos segundos) ficaria bom no
  painel, mas um `6` lido como `9` vira um relógio errado com cara de medido —
  e o atlas de glifos ainda não conhece esta fonte. Presença não erra pra esse
  lado: ou tem um aglomerado com cara de dígito ou não tem.
  """

  alias Pokex.Vision.Frame

  @white_floor 180
  @white_max_sat 40
  @dark_ceiling 60
  @min_cluster_px 8
  @min_outline_ratio 0.7

  @doc """
  Os índices (0-based) dos slots que estão CONTANDO — cooldown escrito pelo
  próprio jogo. `count` é o número de slots calibrado da barra.
  """
  @spec counting(Frame.t(), pos_integer) :: MapSet.t(non_neg_integer)
  def counting(%Frame{} = frame, count) when is_integer(count) and count > 0 do
    scale = max(frame.scale, 0.5)
    slot_w = max(div(frame.width, count), 1)

    frame
    |> clusters()
    |> Enum.filter(&countdown_digit?(&1, frame, scale))
    |> Enum.map(fn %{min_x: x} -> min(div(x, slot_w), count - 1) end)
    |> MapSet.new()
  end

  @doc """
  Os índices (0-based) dos slots em que há um GLIFO da fonte do jogo — o
  rótulo da tecla (1-9, 0) que fica embaixo de todo slot, ou a contagem em
  cima. É a assinatura de "isto É a barra": o jogo desenha o rótulo sempre,
  com a skill pronta ou fria, e nada mais na tela põe um dígito branco com
  contorno preto em cada um de nove retângulos iguais lado a lado.

  Medido em 02/09 nas cinco barras reais que existem (as três fixtures de
  agosto, a de 11:52 e o recorte justo do Venusaur de 18:37): 9 de 9 slots em
  todas. Nos seis não-barras (painel claro, mundo, lista de batalha, chat):
  no máximo 1.
  """
  @spec labelled_slots(Frame.t(), pos_integer) :: MapSet.t(non_neg_integer)
  def labelled_slots(%Frame{} = frame, count) when is_integer(count) and count > 0 do
    scale = max(frame.scale, 0.5)
    slot_w = max(div(frame.width, count), 1)

    frame
    |> clusters()
    |> Enum.filter(&label_glyph?(&1, frame, scale))
    |> Enum.map(fn %{min_x: x} -> min(div(x, slot_w), count - 1) end)
    |> MapSet.new()
  end

  # --- aglomerados de branco --------------------------------------------------

  defp clusters(frame) do
    whites =
      for y <- 0..(frame.height - 1),
          x <- 0..(frame.width - 1),
          white?(Frame.at(frame, x, y)),
          into: MapSet.new(),
          do: {x, y}

    collect(whites, [])
  end

  defp collect(whites, acc) do
    case Enum.at(whites, 0) do
      nil ->
        acc

      seed ->
        {cluster, rest} = flood(MapSet.new([seed]), MapSet.delete(whites, seed), [seed])
        collect(rest, [summarize(cluster) | acc])
    end
  end

  defp flood(cluster, whites, [] = _frontier), do: {cluster, whites}

  defp flood(cluster, whites, frontier) do
    neighbours =
      for {x, y} <- frontier,
          {nx, ny} <- [{x + 1, y}, {x - 1, y}, {x, y + 1}, {x, y - 1}],
          MapSet.member?(whites, {nx, ny}),
          uniq: true,
          do: {nx, ny}

    flood(
      Enum.into(neighbours, cluster),
      Enum.reduce(neighbours, whites, &MapSet.delete(&2, &1)),
      neighbours
    )
  end

  defp summarize(cluster) do
    {xs, ys} = {Enum.map(cluster, &elem(&1, 0)), Enum.map(cluster, &elem(&1, 1))}

    %{
      pixels: cluster,
      size: MapSet.size(cluster),
      min_x: Enum.min(xs),
      width: Enum.max(xs) - Enum.min(xs) + 1,
      min_y: Enum.min(ys),
      max_y: Enum.max(ys)
    }
  end

  # --- o teste de dígito ------------------------------------------------------

  defp countdown_digit?(cluster, frame, scale),
    do: upper_half?(cluster, frame) and label_glyph?(cluster, frame, scale)

  # Um glifo da fonte do jogo, em qualquer altura do slot: tamanho de dígito e
  # contorno preto. A contagem e o rótulo da tecla são a MESMA fonte.
  defp label_glyph?(cluster, frame, scale) do
    height = cluster.max_y - cluster.min_y + 1

    cluster.size >= round(@min_cluster_px * scale * scale) and
      cluster.width in round(2 * scale)..round(10 * scale) and
      height in round(5 * scale)..round(11 * scale) and
      outlined?(cluster, frame)
  end

  # O centro do aglomerado acima da metade do frame: é o que separa a contagem
  # do rótulo da tecla, que usa a MESMA fonte na metade de baixo.
  defp upper_half?(cluster, frame),
    do: (cluster.min_y + cluster.max_y) / 2 < frame.height / 2

  defp outlined?(cluster, frame) do
    dark =
      Enum.count(cluster.pixels, fn {x, y} ->
        Enum.any?(neighbours8(x, y), fn {nx, ny} ->
          nx >= 0 and ny >= 0 and nx < frame.width and ny < frame.height and
            dark?(Frame.at(frame, nx, ny))
        end)
      end)

    dark / cluster.size >= @min_outline_ratio
  end

  defp neighbours8(x, y),
    do: for(dx <- -1..1, dy <- -1..1, {dx, dy} != {0, 0}, do: {x + dx, y + dy})

  defp white?({r, g, b}),
    do:
      min(r, min(g, b)) >= @white_floor and
        max(r, max(g, b)) - min(r, min(g, b)) <= @white_max_sat

  defp dark?({r, g, b}), do: max(r, max(g, b)) <= @dark_ceiling
end
