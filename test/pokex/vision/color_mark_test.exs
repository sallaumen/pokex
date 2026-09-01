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

  test "uma mancha concentrada vira UMA mancha com centro no lugar certo" do
    # 12×12 px verdes num campo cinza-escuro
    f = frame(64, 64, {40, 40, 40}, [{{20, 24, 12, 12}, @verde}])
    %{px: px, manchas: [m]} = ColorMark.scan(f, specs(@verde))

    assert px == 144
    assert m.px == 144
    {cx, cy} = m.point
    assert_in_delta cx, 26, 6
    assert_in_delta cy, 30, 6
  end

  test "o mesmo total ESPALHADO não vira mancha — célula rala é ruído" do
    salpicos =
      for i <- 0..11 do
        {{rem(i * 17, 60), div(i * 23, 2) |> rem(60), 1, 1}, @verde}
      end

    f = frame(64, 64, {40, 40, 40}, salpicos)
    %{px: px, manchas: manchas} = ColorMark.scan(f, specs(@verde))

    assert px > 0, "os pixels casam"
    assert manchas == [], "mas nenhuma célula junta o bastante pra ser mancha"
  end

  test "o shading do sprite (mais escuro, menos saturado) ainda casa — o matiz segura" do
    sombra = {30, 120, 45}
    f = frame(64, 64, {40, 40, 40}, [{{10, 10, 10, 10}, sombra}])
    %{manchas: [_m]} = ColorMark.scan(f, specs(@verde))
  end

  test "matiz vizinho fora do cone NÃO casa — vermelho comum não é shiny verde" do
    f = frame(64, 64, {40, 40, 40}, [{{10, 10, 10, 10}, @vermelho}])
    assert %{px: 0, manchas: []} = ColorMark.scan(f, specs(@verde))
  end

  test "cinza nunca casa: sem matiz não há cor especial" do
    f = frame(32, 32, {40, 40, 40}, [{{8, 8, 8, 8}, {100, 100, 100}}])
    assert %{px: 0} = ColorMark.scan(f, specs(@verde, tol_sv: 100))
  end

  test "a caixa proibida engole o próprio Torterra — verde DELE não apita" do
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

  test "duas manchas separadas são duas — e vêm da maior pra menor" do
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

    test "clicar no cinza não ensina nada — e diz isso" do
      f = frame(8, 8, {90, 90, 92}, [])
      assert :none = ColorMark.dominant(f, {4, 4})
    end

    test "clicar no quase-preto também não ensina" do
      f = frame(8, 8, {8, 14, 9}, [])
      assert :none = ColorMark.dominant(f, {4, 4})
    end

    test "a mediana devolve um tom que EXISTE na tela, nunca a média de dois" do
      # metade num verde, metade noutro: a média inventaria um terceiro
      f =
        frame(8, 8, {40, 40, 40}, [
          {{2, 2, 5, 3}, {40, 160, 60}},
          {{2, 5, 5, 2}, {50, 180, 70}}
        ])

      assert {:ok, cor} = ColorMark.dominant(f, {4, 4})
      assert cor in [{40, 160, 60}, {50, 180, 70}]
    end

    test "clique na borda do quadro não estoura o frame" do
      f = frame(8, 8, {40, 40, 40}, [{{0, 0, 3, 3}, @verde}])
      assert {:ok, @verde} = ColorMark.dominant(f, {0, 0})
    end
  end
end
