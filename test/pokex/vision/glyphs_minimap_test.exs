defmodule Pokex.Vision.GlyphsMinimapTest do
  @moduledoc """
  A coordenada do minimapa é o alicerce do cavebot, e ela vinha piscando: às
  vezes lia, às vezes virava "?" no painel. A tela "Ensinar glifos" mostrava
  cinco glifos desconhecidos, e um deles era `(2676, 30414, 5)` INTEIRA, como um
  único retângulo — ensinar aquilo seria inútil, porque cada posição nova viraria
  um "glifo" diferente.

  Eram DUAS causas, ambas medidas nas capturas reais:

  1. O atlas nunca aprendeu o "9" da fonte da coordenada. Nenhuma das três
     coordenadas rotuladas tinha um 9, e `read_coord/3` exige confiança 1.0 —
     então TODA posição com um 9 lia nil. `ultrawide_3440x1440_time` é a captura
     que prova isso: ela mostra `(2597, 30640, 6)`.

  2. O minimapa é desenhado em tons de cinza (saturação 0 na faixa da
     coordenada), então o teste de cor não filtra nada ali, e 9-10% dos pixels do
     mapa — o chão andável, medido em 140..159 — passam do piso de tinta 120. A
     faixa `minimap_coord` tem 30px de altura para 20px de texto, então suas
     linhas de margem são mapa puro: basta o Lucas andar para o chão iluminado
     entrar na faixa, e aí NENHUMA coluna fica vazia. Como a segmentação separava
     glifos por coluna vazia, a coordenada inteira virava um glifo só.
  """
  use ExUnit.Case, async: true

  alias Pokex.{Layout, ScreenFixtures}
  alias Pokex.Vision.{Frame, Glyphs}

  # "(2777, 30560, 5)" — 16 caracteres, dos quais 2 são espaços que não desenham
  # tinta nenhuma: 14 glifos. Era ISSO que virava 1.
  @coord_glyphs 14
  @captures [
    "ultrawide_3440x1440_full",
    "ultrawide_3440x1440_outro_mapa",
    "ultrawide_3440x1440_terceiro",
    "ultrawide_3440x1440_time"
  ]

  describe "o 9 que faltava no atlas" do
    test "lê a coordenada da captura que tem um 9 — a que falhava" do
      frame = ScreenFixtures.frame!("ultrawide_3440x1440_time")
      {:ok, fix} = Layout.locate(frame)

      assert Glyphs.read_coord(frame, fix.regions.minimap_coord) == {2597, 30640, 6}
    end

    test "nenhuma das quatro capturas reais deixa um glifo desconhecido na coordenada" do
      for name <- @captures do
        frame = ScreenFixtures.frame!(name)
        {:ok, fix} = Layout.locate(frame)

        assert %{confidence: 1.0} = Glyphs.read_line(frame, fix.regions.minimap_coord),
               "coordenada ilegível em #{name}"

        assert Glyphs.unknown_in(frame, fix.regions.minimap_coord) == [],
               "sobrou glifo desconhecido na coordenada de #{name}"
      end
    end
  end

  describe "mapa claro atrás da coordenada" do
    # O jogo desenha a coordenada num ponto FIXO e rola o mapa por baixo dela.
    # Este cenário é montado com pixels reais desta mesma captura: um pedaço do
    # chão iluminado do próprio minimapa (medido em 140..159, neutro) é levado
    # para as linhas de margem ACIMA do texto — exatamente o que o Lucas vê
    # depois de andar alguns passos para o norte. Nada é sintetizado.
    setup do
      frame = ScreenFixtures.frame!("ultrawide_3440x1440_terceiro")
      {:ok, fix} = Layout.locate(frame)
      {px, py, pw, ph} = fix.regions.minimap
      {cx, cy, cw, _ch} = fix.regions.minimap_coord

      panel = Frame.crop(frame, {px, py, pw, ph})
      # o retalho de chão iluminado mais denso deste minimapa fora da faixa da
      # coordenada — medido, não escolhido no olho
      lit = Frame.crop(frame, {3260, 192, cw, 4})

      %{
        panel: paste(panel, lit, {cx - px, cy - py}),
        band: {cx - px, cy - py, cw, 30},
        clean: panel
      }
    end

    test "o pedaço transplantado é mesmo chão iluminado — tinta pelo critério atual", ctx do
      %{panel: panel, band: {bx, by, bw, _}} = ctx

      inked =
        Enum.count(bx..(bx + bw - 1), fn i ->
          Enum.any?(by..(by + 3), fn j ->
            {r, g, b} = Frame.at(panel, i, j)
            lo = min(r, min(g, b))
            max(r, max(g, b)) - lo <= 60 and lo >= 120
          end)
        end)

      # sem isto o cenário não reproduziria nada: o chão do mapa TEM que passar
      # pelo piso de tinta em boa parte das colunas da faixa
      assert inked > div(bw, 2),
             "só #{inked} de #{bw} colunas receberam tinta do mapa — o cenário não reproduz a falha"
    end

    test "a coordenada continua se separando em caracteres, não num blob", ctx do
      glyphs = Glyphs.segment(ctx.panel, ctx.band)

      assert length(glyphs) == @coord_glyphs,
             "a segmentação soldou os caracteres: #{length(glyphs)} glifos"

      assert Enum.all?(glyphs, &(&1.x1 - &1.x0 + 1 <= 14)),
             "algum glifo saiu largo demais para ser um caractere: " <>
               inspect(Enum.map(glyphs, &(&1.x1 - &1.x0 + 1)))
    end

    test "e continua lendo a mesma posição que lê com o mapa escuro", ctx do
      assert Glyphs.read_coord(ctx.clean, ctx.band) == {2777, 30560, 5}
      assert Glyphs.read_coord(ctx.panel, ctx.band) == {2777, 30560, 5}
    end

    test "a tela de ensinar glifos não oferece o blob para o Lucas aprender", ctx do
      assert Glyphs.unknown_in(ctx.panel, ctx.band) == []
    end
  end

  describe "regras de fundo" do
    test "uma migalha solta entre dois dígitos não solda os dois" do
      frame = ScreenFixtures.frame!("ultrawide_3440x1440_terceiro")
      {:ok, fix} = Layout.locate(frame)
      {px, py, pw, ph} = fix.regions.minimap
      {cx, cy, cw, _} = fix.regions.minimap_coord
      panel = Frame.crop(frame, {px, py, pw, ph})
      band = {cx - px, cy - py, cw, 30}

      [_open, first, second | _] = Glyphs.segment(panel, band)
      gap = div(first.x1 + second.x0, 2)

      # um pixel branco no vão entre dois dígitos — do tamanho das migalhas que
      # apareciam na tela de ensinar (2-3 px)
      speckled = poke(panel, [{gap, 12}, {gap, 13}])

      assert length(Glyphs.segment(speckled, band)) == length(Glyphs.segment(panel, band))
    end

    test "o pingo de um glifo NÃO é jogado fora com o fundo" do
      # O "i" de Sceptile: o pingo é um blob separado do tronco, fora da faixa
      # das outras letras. Descartá-lo mudaria um glifo que o atlas conhece.
      frame = ScreenFixtures.frame!("ultrawide_3440x1440_outro_mapa")

      assert %{text: "Sceptile", confidence: 1.0} =
               Glyphs.read_line(frame, {3223, 547, 132, 21})
    end
  end

  defp paste(%Frame{} = frame, %Frame{} = patch, {x, y}) do
    rgba =
      for j <- 0..(patch.height - 1)//1, reduce: frame.rgba do
        acc ->
          line = binary_part(patch.rgba, j * patch.width * 4, patch.width * 4)
          at = ((y + j) * frame.width + x) * 4
          size = byte_size(line)
          <<head::binary-size(at), _old::binary-size(size), tail::binary>> = acc
          <<head::binary, line::binary, tail::binary>>
      end

    %Frame{frame | rgba: rgba}
  end

  defp poke(%Frame{} = frame, points) do
    rgba =
      Enum.reduce(points, frame.rgba, fn {x, y}, acc ->
        at = (y * frame.width + x) * 4
        <<head::binary-size(at), _old::binary-size(4), tail::binary>> = acc
        <<head::binary, 255, 255, 255, 255, tail::binary>>
      end)

    %Frame{frame | rgba: rgba}
  end
end
