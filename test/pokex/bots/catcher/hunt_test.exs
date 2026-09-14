defmodule Pokex.Bots.Catcher.HuntTest do
  @moduledoc """
  A cerca da tela na hora da bola, medida na tela DELE (3440x1440), a única
  em que `Screen.BarOffset` tem número.
  """
  use ExUnit.Case, async: false

  alias Pokex.Bots.Catcher.Hunt
  alias Pokex.Calibration

  # A CALIBRAÇÃO É UM ARQUIVO SÓ, compartilhado pela suíte inteira: salvar a
  # tela DELE e ir embora faz `BarOffset` acordar em testes que contam com a
  # tela não medida (o `ball_test` afirma o ponto sem desvio). Devolve o que
  # estava aqui.
  setup do
    antes = Calibration.load()
    arquivo = Pokex.Home.calibration_file()

    on_exit(fn ->
      case antes do
        {:ok, calib} -> Calibration.save(calib)
        _nenhuma -> File.rm_rf!(arquivo)
      end
    end)

    Calibration.save(%Calibration{scale: 1.0, screen_w: 3440, screen_h: 1440, tile_px: 151})
    :ok
  end

  # A MIRA TAMBÉM TEM QUE CABER NA TELA.
  #
  # A mira desce 110 px na tela dele. Um bicho nos 110 px de cima passava com a
  # BARRA dentro e virava alvo `(2324, -97)`: o sistema gruda o cursor na borda,
  # a bola é usada no nada, e o corpo volta pra fila pra tentar de novo — 99
  # recusas no mesmo alvo em 14/09, com a fila inteira parada atrás dele.
  test "a point whose aim falls off the top of the screen is not a target" do
    refute Hunt.aimable?({2324, 13})
  end

  test "the same point lower down, with its aim inside, is a target" do
    assert Hunt.aimable?({2324, 700})
  end

  test "a point already off the screen was never a target" do
    refute Hunt.aimable?({-1, 700})
    refute Hunt.aimable?({2324, 1_500})
  end
end
