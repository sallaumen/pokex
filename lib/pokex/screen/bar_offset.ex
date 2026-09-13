defmodule Pokex.Screen.BarOffset do
  @moduledoc """
  Onde está o CORPO, dado o ponto da BARRA.

  Tudo que este bot sabe sobre onde um bicho está vem da barra de vida dele: o
  `point` de um hostil é o centro da barra (`Pokex.Bots.CrowdScan`), e a barra
  flutua acima da cabeça. Pra decidir tile — "a três de você" — isso não importa,
  porque `offset/3` divide por tile e ARREDONDA, e meio tile some no
  arredondamento. Foi por isso que ninguém viu.

  Pra APONTAR O MOUSE importa, e é o único lugar onde importa.

  ## Medido no rastro dele (13/09)

  33 marcas das caixas-pretas de incidente, cada uma comparando o `point` da
  barra com o corpo que o próprio `{dx, dy}` da marca aponta
  (`me + {dx, dy} * tile`):

      vertical    -70 px  ·  16 marcas
                  -69 px  ·  15 marcas
                  outros ·   2 marcas

      horizontal  +25 px  ·  22 marcas
                  outros ·  11 marcas

  Ou seja: a barra fica **70 px acima e 25 px à direita** do corpo. Num tile de
  151 px isso é quase meia casa pra cima — a bola era mirada na fronteira entre
  o tile do corpo e o de cima, e caía num ou noutro conforme o arredondamento do
  jogo. "Mais erra do que acerta hoje em dia" (Lucas, 13/09), com ele jogando as
  bolas na mão pra compensar.

  ## Por que uma tabela por tela, e não uma conta

  Não escala com o tile: no ultrawide a barra flutua 70 px sobre um tile de 151
  (0,46 casa) e no notebook ~36 px sobre um tile de 36 (uma casa inteira). São
  duas geometrias do cliente, não uma proporção — do mesmo jeito que
  `Pokex.Screen.Tile` é tabela e não fórmula.

  Tela não medida devolve `:unknown`, e quem pergunta continua mirando na barra
  como sempre mirou: um palpite aqui erraria a bola de um jeito novo, e o que
  não foi medido não entra.
  """

  @measured %{
    # o ultrawide dele: 31 de 33 marcas em -69/-70 vertical, 22 de 33 em +25
    {3440, 1440} => {-25, 70}
  }

  @doc """
  O vetor que leva do ponto da BARRA ao CORPO, nesta tela: `{dx, dy}` em pontos
  de tela, pra somar. `:unknown` numa tela que ninguém mediu.
  """
  @spec for_screen({term, term}) :: {:ok, {integer, integer}} | :unknown
  def for_screen({w, h}) when is_integer(w) and is_integer(h) do
    case Map.fetch(@measured, {w, h}) do
      {:ok, vector} -> {:ok, vector}
      :error -> :unknown
    end
  end

  def for_screen(_no_screen), do: :unknown

  @doc """
  O ponto da barra levado até o corpo, na tela salva na calibração.

  Sem calibração ou numa tela não medida devolve o ponto como veio — nunca um
  palpite.
  """
  @spec body({integer, integer}) :: {integer, integer}
  def body({x, y} = point) do
    with {:ok, calib} <- Pokex.Calibration.load(),
         {:ok, {dx, dy}} <- for_screen({calib.screen_w, calib.screen_h}) do
      {x + dx, y + dy}
    else
      _sem_medida -> point
    end
  end

  @doc "As telas medidas, pra uma recusa ou um alarme."
  @spec known() :: [{{pos_integer, pos_integer}, {integer, integer}}]
  def known, do: Enum.sort_by(@measured, fn {{w, _h}, _vector} -> -w end)
end
