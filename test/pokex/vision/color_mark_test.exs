defmodule Pokex.Vision.ColorMarkTest do
  use ExUnit.Case, async: true

  alias Pokex.Vision.{ColorMark, Frame}

  # O verde do Electrode shiny da print de 01/09 — e o vermelho do comum.
  @verde {40, 160, 60}
  @vermelho {200, 40, 40}

  defp frame(w, h, bg, patches) do
    pixels =
      for y <- 0..(h - 1), x <- 0..(w - 1), into: <<>> do
        {r, g, b} = cor_em(x, y, bg, patches)
        <<r, g, b, 255>>
      end

    %Frame{width: w, height: h, rgba: pixels}
  end

  defp cor_em(x, y, bg, patches) do
    Enum.find_value(patches, bg, fn {{px, py, pw, ph}, cor} ->
      if x >= px and x < px + pw and y >= py and y < py + ph, do: cor
    end)
  end

  defp specs(cor, opts \\ []),
    do:
      ColorMark.compile([
        %{rgb: cor, tol_h: Keyword.get(opts, :tol_h, 12), tol_sv: Keyword.get(opts, :tol_sv, 30)}
      ])

  test "a concentrated blob becomes ONE blob with its centre in the right place" do
    # 12×12 px verdes num campo cinza-escuro
    f = frame(64, 64, {40, 40, 40}, [{{20, 24, 12, 12}, @verde}])
    %{px: px, manchas: [m]} = ColorMark.scan(f, specs(@verde))

    assert px == 144
    assert m.px == 144
    {cx, cy} = m.point
    assert_in_delta cx, 26, 6
    assert_in_delta cy, 30, 6
  end

  test "the same total SPREAD OUT is no blob: a sparse cell is noise" do
    salpicos =
      for i <- 0..11 do
        {{rem(i * 17, 60), div(i * 23, 2) |> rem(60), 1, 1}, @verde}
      end

    f = frame(64, 64, {40, 40, 40}, salpicos)
    %{px: px, manchas: manchas} = ColorMark.scan(f, specs(@verde))

    assert px > 0, "os pixels casam"
    assert manchas == [], "mas nenhuma célula junta o bastante pra ser mancha"
  end

  test "the sprite's shading (darker, less saturated) still matches: the hue holds" do
    sombra = {30, 120, 45}
    f = frame(64, 64, {40, 40, 40}, [{{10, 10, 10, 10}, sombra}])
    %{manchas: [_m]} = ColorMark.scan(f, specs(@verde))
  end

  test "a neighbouring hue outside the cone does NOT match: plain red is not shiny green" do
    f = frame(64, 64, {40, 40, 40}, [{{10, 10, 10, 10}, @vermelho}])
    assert %{px: 0, manchas: []} = ColorMark.scan(f, specs(@verde))
  end

  test "grey never matches: without hue there is no special colour" do
    f = frame(32, 32, {40, 40, 40}, [{{8, 8, 8, 8}, {100, 100, 100}}])
    assert %{px: 0} = ColorMark.scan(f, specs(@verde, tol_sv: 100))
  end

  test "the forbidden box swallows the own Torterra: HIS green does not beep" do
    f = frame(64, 64, {40, 40, 40}, [{{20, 20, 16, 16}, @verde}])

    assert %{px: 0, manchas: []} =
             ColorMark.scan(f, specs(@verde), forbidden: [{16, 16, 40, 40}])
  end

  test "regra de dois tons casa qualquer um deles" do
    amarelo = {220, 200, 40}

    two =
      ColorMark.compile([
        %{rgb: @verde, tol_h: 12, tol_sv: 30},
        %{rgb: amarelo, tol_h: 12, tol_sv: 30}
      ])

    f = frame(64, 64, {40, 40, 40}, [{{4, 4, 8, 8}, @verde}, {{40, 40, 8, 8}, amarelo}])
    %{manchas: manchas} = ColorMark.scan(f, two)
    assert length(manchas) == 2
  end

  test "two separate blobs are two, and come from largest to smallest" do
    f = frame(96, 48, {40, 40, 40}, [{{4, 4, 12, 12}, @verde}, {{70, 30, 6, 6}, @verde}])
    %{manchas: [maior, menor]} = ColorMark.scan(f, specs(@verde))
    assert maior.px == 144
    # 36 casados, mas a célula rala da borda (4px < min_cell_px) fica de fora —
    # o preço do anti-ruído, pago na borda da mancha
    assert menor.px == 32
  end

  # O CONTA-GOTAS: o clique dele vira um TOM, não um pixel.
  describe "dominant/3 — o conta-gotas do ensino" do
    test "o patch inteiro vota: o tom dominante vence o anti-aliasing da borda" do
      # 5×5 quase todo verde, com dois pixels de borrão azulado na quina
      f =
        frame(8, 8, {40, 40, 40}, [
          {{2, 2, 5, 5}, @verde},
          {{2, 2, 2, 1}, {60, 90, 200}}
        ])

      assert {:ok, {r, g, b}} = ColorMark.dominant(f, {4, 4})
      assert {r, g, b} == @verde
    end

    # A CRISTA DO SHINY FERALIGATR: uns poucos pixels azul-escuros num corpo
    # ciano. A votação do patch dava o corpo; o clique em cima da crista tem
    # que devolver a crista — é ela que separa o shiny do comum.
    test "o pixel clicado manda: o detalhe escuro vence o corpo em volta" do
      corpo = {70, 190, 230}
      crista = {20, 40, 110}

      # a crista vem primeiro: `cor_em/4` pinta o primeiro retalho que casar
      f =
        frame(12, 12, {200, 180, 120}, [
          {{5, 5, 2, 2}, crista},
          {{1, 1, 10, 10}, corpo}
        ])

      assert {:ok, ^crista} = ColorMark.dominant(f, {5, 5})
      assert {:ok, ^corpo} = ColorMark.dominant(f, {2, 2})
    end

    # O DEFEITO QUE CUSTOU AS REGRAS DELE (09/09): ele clicou no corpo PRETO do
    # Charizard dentro de uma caverna de lava e a ferramenta guardou o vermelho
    # da lava — um pixel alaranjado na borda da silhueta ganhava do corpo
    # inteiro, porque o voto do quadradinho só era pulado quando NENHUM dos 25
    # tinha matiz. Cada tom assim casava 3% da tela dele.
    test "a black click surrounded by lava still teaches BLACK" do
      f =
        frame(8, 8, {17, 16, 16}, [
          # a borda acesa do bicho, encostando no ponto clicado
          {{5, 3, 3, 3}, {200, 90, 20}}
        ])

      assert {:dark, {r, g, b}} = ColorMark.dominant(f, {4, 4})
      assert max(r, max(g, b)) <= 30, "o tom ensinado tem que ser o do corpo, não o da lava"
    end

    # …e o clique que cai numa borda sem cor continua sendo a votação de sempre.
    test "clicando no cinza entre duas cores, o patch inteiro vota" do
      f =
        frame(12, 12, {90, 90, 92}, [
          {{0, 0, 12, 5}, @verde},
          {{0, 7, 12, 5}, {60, 90, 200}}
        ])

      assert {:ok, {r, g, b}} = ColorMark.dominant(f, {6, 6})
      assert {r, g, b} in [@verde, {60, 90, 200}]
    end

    test "clicking on grey teaches nothing, and says so" do
      f = frame(8, 8, {90, 90, 92}, [])
      assert :none = ColorMark.dominant(f, {4, 4})
    end

    # ISTO MUDOU EM 09/09, e a razão é dele: "justamente é um dos poucos Shinies
    # Pretos do jogo". Preto não tem matiz pra ensinar, e recusar era recusar o
    # bicho inteiro — agora o clique vira uma BANDA ESCURA.
    test "clicking on near-black teaches a dark band" do
      f = frame(8, 8, {17, 16, 16}, [])
      assert {:dark, {r, g, b}} = ColorMark.dominant(f, {4, 4})
      assert max(r, max(g, b)) <= 30
    end

    # …e cinza claro continua não ensinando nada: uma banda que pega pedra pega
    # o mapa inteiro.
    test "clicking on bright grey still teaches nothing" do
      f = frame(8, 8, {130, 130, 132}, [])
      assert :none = ColorMark.dominant(f, {4, 4})
    end

    test "a dark band matches the black body and not the lit ground" do
      [spec] = ColorMark.compile([%{dark: 30, spread: 12}])

      f =
        frame(16, 16, {120, 90, 60}, [
          {{2, 2, 8, 8}, {17, 16, 16}}
        ])

      assert %{px: px, manchas: [%{px: blob, box: {l, t, r, b}}]} =
               ColorMark.scan(f, [spec], cell_px: 4, min_cell_px: 4)

      assert px == 64
      assert blob == 64
      assert {l, t, r, b} == {0, 0, 11, 11}
    end

    test "the median returns a tone that EXISTS on screen, never the average of two" do
      # metade num verde, metade noutro: a média inventaria um terceiro
      f =
        frame(8, 8, {40, 40, 40}, [
          {{2, 2, 5, 3}, {40, 160, 60}},
          {{2, 5, 5, 2}, {50, 180, 70}}
        ])

      assert {:ok, cor} = ColorMark.dominant(f, {4, 4})
      assert cor in [{40, 160, 60}, {50, 180, 70}]
    end

    test "a click on the frame's edge does not overflow the frame" do
      f = frame(8, 8, {40, 40, 40}, [{{0, 0, 3, 3}, @verde}])
      assert {:ok, @verde} = ColorMark.dominant(f, {0, 0})
    end
  end

  # UMA COR QUE ESTA NA TELA. A mediana por canal ordena os tres canais separados
  # e junta os tres meios: da um RGB que pode nao existir em pixel nenhum. Medido
  # na foto dele de 10/09, o tom ensinado aparecia ZERO vezes nos 3,7 milhoes de
  # pixels — e com casamento exato isso e uma regra que nunca casa nada.
  describe "the eyedropper only ever teaches a colour that is on screen" do
    test "a patch whose channel medians cross gives a real pixel, not an invented one" do
      # tres tons reais; a mediana por canal deles seria (150,150,150), que nao
      # existe em nenhum dos tres
      pixels = [{110, 150, 190}, {150, 190, 110}, {190, 110, 150}]

      frame = %Frame{
        width: 3,
        height: 1,
        rgba: for({r, g, b} <- pixels, into: <<>>, do: <<r, g, b, 255>>)
      }

      assert {:ok, tom} = ColorMark.dominant(frame, {1, 0}, 1)
      assert tom in pixels, "ensinou #{inspect(tom)}, que nao esta na foto"
    end

    test "the repeated colour of the patch wins, because that is the sprite" do
      corpo = {90, 40, 120}
      borda = {12, 10, 14}
      pixels = [corpo, corpo, corpo, borda, borda]

      frame = %Frame{
        width: 5,
        height: 1,
        rgba: for({r, g, b} <- pixels, into: <<>>, do: <<r, g, b, 255>>)
      }

      assert {:ok, ^corpo} = ColorMark.dominant(frame, {2, 0}, 2)
    end
  end

  # A PROVA NOS PIXELS DELE: o quadro que ele fotografou em 09/09 tentando
  # ensinar o shiny preto, recortado longe do HUD. O corpo mede (17,16,16) e o
  # chão é lava; a banda escura tem que separar os dois com folga.
  describe "o shiny preto no quadro real" do
    @fixture "test/fixtures/shiny/preto_na_lava.png"

    test "a banda escura acha o bicho e deixa a lava de fora" do
      {:ok, frame} = Frame.from_file(@fixture)
      [spec] = ColorMark.compile([%{dark: 30, spread: 12}])

      %{manchas: manchas} = ColorMark.scan(frame, [spec], min_cell_px: 6)

      assert [maior | resto] = manchas
      # o bicho ocupa o meio do recorte
      {cx, cy} = maior.point
      assert cx in 180..300, "a maior mancha tem que ser o bicho, não a borda"
      assert cy in 130..280

      segunda = resto |> Enum.map(& &1.px) |> Enum.max(fn -> 0 end)

      assert maior.px >= 3 * max(segunda, 1),
             "margem medida em 09/09: 4x com teto 30 (bicho #{maior.px}px, chão #{segunda}px)"
    end

    # …e o teto é a régua: afrouxá-lo faz o chão subir mais depressa que o
    # bicho, que é por que a prova do chão existe e por que o padrão é apertado.
    test "afrouxar o teto de luz encolhe a margem" do
      {:ok, frame} = Frame.from_file(@fixture)

      margem = fn teto ->
        [spec] = ColorMark.compile([%{dark: teto, spread: 12}])
        %{manchas: [maior | resto]} = ColorMark.scan(frame, [spec], min_cell_px: 6)
        chao = resto |> Enum.map(& &1.px) |> Enum.max(fn -> 0 end)
        maior.px / max(chao, 1)
      end

      assert margem.(30) > margem.(60)
    end

    # A FAMILIA CERTA PRA ARTE DE PALETA FIXA. O jogo nao tem variacao de luz e
    # as sprites sao fixas, entao a cor de um bicho e EXATA e se repete quadro a
    # quadro. O cone de matiz e cego justamente ao eixo que separa o shiny do
    # comum: escalar um RGB por um fator preserva matiz e saturacao EXATAMENTE,
    # de modo que o cone aceita a mesma arte em qualquer brilho.
    test "the hue cone accepts the same art brighter; the rgb box does not" do
      # o corpo do shiny preto dele mede (17,16,16)
      corpo = {17, 16, 16}
      # a mesma arte 60% mais clara: outro bicho, mesmo matiz e mesma saturacao
      mais_claro = {27, 26, 26}

      cone = ColorMark.compile([%{rgb: corpo, tol_h: 12, tol_sv: 30}])
      caixa = ColorMark.compile([%{rgb: corpo, tol: 1}])

      assert casou?(cone, mais_claro), "o cone aceita a arte mais clara — e o defeito"
      refute casou?(caixa, mais_claro), "a caixa recusa: o brilho e o sinal"
      assert casou?(caixa, corpo), "…e continua achando o tom ensinado"
    end

    test "on his real frame the box lights up scenery the cone floods" do
      {:ok, frame} = Frame.from_file(@fixture)
      lava = {130, 111, 105}

      cone =
        ColorMark.scan(frame, ColorMark.compile([%{rgb: lava, tol_h: 12, tol_sv: 30}]),
          min_cell_px: 6
        )

      caixa = ColorMark.scan(frame, ColorMark.compile([%{rgb: lava, tol: 2}]), min_cell_px: 6)

      assert cone.px > 10_000, "o cone acende o chao da caverna inteiro (#{cone.px}px)"
      assert caixa.px < cone.px / 50, "a caixa quase nao acende (#{caixa.px}px)"
    end
  end

  defp casou?(specs, {r, g, b}) do
    frame = %Frame{width: 8, height: 8, rgba: :binary.copy(<<r, g, b, 255>>, 64)}
    ColorMark.scan(frame, specs, min_cell_px: 1).px > 0
  end
end
