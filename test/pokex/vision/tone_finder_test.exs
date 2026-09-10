defmodule Pokex.Vision.ToneFinderTest do
  use ExUnit.Case, async: true

  alias Pokex.Vision.{ColorMark, Frame, ToneFinder}

  # A CENA DELE, de 10/09: o Venusaur SHINY (roxo, flor marrom) e dois Venusaur
  # COMUNS (azul, flor rosa) na mesma foto, recortados da calibracao que ele
  # tentou e nao conseguiu. Ele clicou tres vezes e nenhuma das tres cores
  # circulava o bicho: "tentei por TUDO e nao fui capaz de marcar cores onde
  # fizesse circular o shiny venusaur e nao os outros".
  @cena "test/fixtures/crowd/venusaur_shiny_e_comuns.png"

  # o corpo do shiny e o do comum de baixo, em pixels deste recorte
  @shiny {220, 105}
  @comum {200, 260}
  @chao {500, 300}

  # os tres tons que o conta-gotas antigo lhe deu naquela sessao
  @tons_dele [{83, 38, 98}, {129, 117, 142}, {126, 108, 145}]

  defp cena do
    {:ok, frame} = Frame.from_file(@cena)
    frame
  end

  describe "his own scene" do
    test "one click on the shiny finds a tone the common ones do not have" do
      assert {:ok, achado} = ToneFinder.find(cena(), @shiny, box_px: 150)

      assert achado.on_target >= 90,
             "o tom tem que casar o bicho de verdade, nao um punhado de pixels"

      assert achado.elsewhere <= 8, "…e quase nada fora dele"

      assert achado.biggest_elsewhere == 0,
             "nenhuma MANCHA fora do bicho: e isso que faz o vigia nao apitar com o comum"

      assert achado.blob >= 90, "a mancha tem que sobreviver a peneira de celulas do vigia"
      assert achado.min_px >= 50, "o gatilho sai da mancha medida, e nao de um palpite"
    end

    # A PROVA QUE ELE PEDIU, lado a lado. Nao adianta o tom novo ser bom se o
    # antigo tambem fosse: aqui os tres tons que a ferramenta lhe entregou sao
    # medidos na MESMA foto, com a MESMA peneira.
    test "the tones the old eyedropper gave him never circle any creature" do
      frame = cena()

      for tom <- @tons_dele, tol <- [0, 1] do
        maior = maior_px(varre(frame, tom, tol))

        assert maior <= 50,
               "#{inspect(tom)} folga #{tol}: maior mancha #{maior}px — " <>
                 "esse tom nunca circulou bicho nenhum"
      end

      {:ok, achado} = ToneFinder.find(frame, @shiny, box_px: 150)

      assert maior_px(varre(frame, achado.rgb, achado.tol)) >= 150,
             "e o tom medido acha UMA mancha grande onde os dele nao achavam nenhuma"
    end

    # A ARMADILHA EM QUE ELE ESTAVA. Com um tom que nao e o da sprite, apertar a
    # folga nao acha nada e afrouxa-la acha o cenario inteiro — nao existe numero
    # certo pra girar, e girar numeros era tudo o que a ferramenta oferecia.
    test "loosening his tone does not find the creature, it finds everything" do
      frame = cena()
      apertado = varre(frame, {126, 108, 145}, 1)
      frouxo = varre(frame, {126, 108, 145}, 2)

      assert maior_px(apertado) <= 50, "apertado, o tom dele mal toca o bicho"
      assert length(frouxo.manchas) >= 3, "frouxo, ele acende em varios lugares de uma vez"
    end

    # …E NAO E SO "acha alguma coisa": tem que ser o BICHO CERTO. O gatilho
    # sugerido, aplicado a foto inteira, so pode sobrar uma mancha, e ela tem
    # que estar em cima do shiny — nao do comum dois tiles abaixo.
    test "at the suggested trigger only the shiny survives, and it is the shiny" do
      frame = cena()
      {:ok, achado} = ToneFinder.find(frame, @shiny, box_px: 150)

      %{manchas: manchas} = varre(frame, achado.rgb, achado.tol)
      acima = Enum.filter(manchas, &(&1.px >= achado.min_px))

      assert [uma] = acima
      {l, t, r, b} = uma.box
      assert dentro?({div(l + r, 2), div(t + b, 2)}, @shiny, 90)
    end

    # O COMUM NAO TEM TOM PROPRIO, e essa e a diferenca inteira: existe outro
    # igual a ele na mesma foto, entao toda cor dele vaza pro vizinho. A
    # ferramenta tem que RECUSAR, nao entregar um tom qualquer — e e por isso
    # que o mesmo clique no shiny responde.
    test "a click on a common Venusaur is refused: its twin is on the screen" do
      assert {:ok, _do_shiny} = ToneFinder.find(cena(), @shiny, box_px: 150)
      assert {:error, :nothing_separates} = ToneFinder.find(cena(), @comum, box_px: 150)
    end

    # O CHAO NAO TEM TOM PROPRIO: ele esta em toda parte, entao tudo o que casa
    # dentro do quadrado casa muito mais fora. A ferramenta tem que dizer isso
    # em vez de entregar um tom qualquer.
    test "a click on the ground finds nothing that separates" do
      assert {:error, motivo} = ToneFinder.find(cena(), @chao, box_px: 150)
      assert motivo in [:nothing_separates, :too_thin]
    end
  end

  describe "the mechanics, on frames with no surprises" do
    test "a colour that lives only inside the square is the answer" do
      frame = pintado(200, 200, {30, 30, 30}, [{{80, 80, 40, 40}, {88, 45, 103}}])

      assert {:ok, %{rgb: {88, 45, 103}, tol: 0, elsewhere: 0}} =
               ToneFinder.find(frame, {100, 100}, box_px: 100)
    end

    test "a colour that is also all over the picture is refused" do
      frame = pintado(200, 200, {88, 45, 103}, [])

      assert {:error, :nothing_separates} = ToneFinder.find(frame, {100, 100}, box_px: 100)
    end

    # UMA COR PRECISA SE REPETIR. O tom que ele pegou existia UMA vez na tela
    # inteira: era mistura de borda, nao a cor da sprite. Num quadrado em que
    # NENHUMA cor se repete nao ha tom nenhum a ensinar, e a ferramenta diz isso.
    test "where no colour repeats there is no tone at all" do
      assert {:error, :nothing_repeats} =
               ToneFinder.find(degrade(200, 200), {100, 100}, box_px: 100)
    end

    # …e um punhado de pixels tambem nao vira tom: quem tem repeticao ali e o
    # fundo, e o fundo vaza pra foto inteira.
    test "a handful of pixels does not win over the background" do
      frame = pintado(200, 200, {30, 30, 30}, [{{100, 100, 2, 2}, {88, 45, 103}}])

      assert {:error, :nothing_separates} = ToneFinder.find(frame, {100, 100}, box_px: 100)
    end

    # O GATILHO SAI DA MANCHA, com folga: o bicho vira de lado e mostra menos
    # cor, e um gatilho colado na medida perderia o proprio bicho no quadro
    # seguinte.
    test "the trigger is below the blob it measured" do
      frame = pintado(200, 200, {30, 30, 30}, [{{80, 80, 40, 40}, {88, 45, 103}}])

      assert {:ok, achado} = ToneFinder.find(frame, {100, 100}, box_px: 100)
      assert achado.min_px < achado.blob
      assert achado.min_px >= 20
    end
  end

  defp maior_px(%{manchas: [%{px: px} | _resto]}), do: px
  defp maior_px(%{manchas: []}), do: 0

  # um quadro em que cada pixel tem a sua propria cor
  defp degrade(w, h) do
    rgba =
      for y <- 0..(h - 1), x <- 0..(w - 1), into: <<>> do
        <<rem(x, 256), rem(y, 256), rem(x * 7 + y * 3, 256), 255>>
      end

    %Frame{width: w, height: h, rgba: rgba, scale: 1.0}
  end

  defp varre(frame, rgb, tol),
    do: ColorMark.scan(frame, ColorMark.compile([%{rgb: rgb, tol: tol}]), min_cell_px: 6)

  defp dentro?({x, y}, {cx, cy}, raio), do: abs(x - cx) <= raio and abs(y - cy) <= raio

  defp pintado(w, h, bg, patches) do
    rgba =
      for y <- 0..(h - 1), x <- 0..(w - 1), into: <<>> do
        {r, g, b} = cor_em(x, y, bg, patches)
        <<r, g, b, 255>>
      end

    %Frame{width: w, height: h, rgba: rgba, scale: 1.0}
  end

  defp cor_em(x, y, bg, patches) do
    Enum.find_value(patches, bg, fn {{px, py, pw, ph}, cor} ->
      if x >= px and x < px + pw and y >= py and y < py + ph, do: cor
    end)
  end
end
