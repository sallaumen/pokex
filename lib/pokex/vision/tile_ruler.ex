defmodule Pokex.Vision.TileRuler do
  @moduledoc """
  Pixels casados lidos como TILES — a régua que ele enxerga.

  "Não estou entendendo nem um pouco o que são os pixels" (09/09), e ele tem razão: pixel não
  é unidade de ninguém que joga. O tile é o quadrado do jogo, e a mesma cena rende quatro
  vezes mais pixels numa tela ampliada e um quarto dos pixels no notebook — o número em tiles
  atravessa as duas telas, o número em pixels não.

  Serve também de veredito: um bicho ocupa da ordem de um tile, então um gatilho de catorze
  tiles não é um gatilho alto, é um gatilho que nenhum bicho alcança. Uma regra assim fica
  provada, armada e MUDA.
  """

  alias Pokex.Calibration
  alias Pokex.Vision.ColorRules

  @doc "O tile e a ampliação da tela calibrada agora."
  @spec now() :: {pos_integer, number}
  def now do
    case Calibration.load() do
      {:ok, %Calibration{scale: scale} = calib} when is_number(scale) and scale > 0 ->
        {Calibration.tile_px(calib), scale}

      {:ok, calib} ->
        {Calibration.tile_px(calib), 1.0}

      _uncalibrated ->
        {Calibration.tile_px(), 1.0}
    end
  end

  @doc "Quantos tiles de cor sólida são estes pixels, nesta tela."
  @spec tiles(number) :: float
  def tiles(px) do
    {tile, scale} = now()
    ColorRules.tiles(px, tile, scale)
  end

  @doc "Um gatilho que nenhum bicho alcança, nesta tela."
  @spec unreachable?(number) :: boolean
  def unreachable?(px) do
    {tile, scale} = now()
    ColorRules.unreachable?(px, tile, scale)
  end

  @doc """
  O número pra tela, na régua dele.

  Abaixo de um décimo de tile vai a PALAVRA e não o zero: "quase nada" é a notícia boa (o
  cenário mal casa com o tom) e "0,0 tiles" seria honesto e inútil.
  """
  @spec label(number | nil) :: String.t()
  def label(nil), do: "—"

  def label(px) do
    t = tiles(px)

    cond do
      t < 0.1 -> "quase nada"
      t < 1.0 -> "#{decimal(t)} de um tile"
      true -> "#{decimal(t)} tiles"
    end
  end

  defp decimal(float),
    do: float |> :erlang.float_to_binary(decimals: 1) |> String.replace(".", ",")
end
