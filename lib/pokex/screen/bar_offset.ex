defmodule Pokex.Screen.BarOffset do
  @moduledoc """
  Onde está o CORPO, dado o ponto que o olho PUBLICA de uma criatura.

  Tudo que este bot sabe sobre onde um bicho está vem da barra de vida dele. O
  `point` de um hostil (`Pokex.Bots.CrowdScan`) não é a barra crua: `place/4`
  soma UM TILE à marca antes de publicar, porque "o corpo fica um tile abaixo da
  barra" (`Pokex.Vision.CreatureMarks`). Pra decidir tile isso some no
  arredondamento de `offset/3`. Pra APONTAR O MOUSE não some, e é o único lugar
  onde importa.

  ## Medido no quadro dele (14/09, caixa-preta `20260914T025428Z-shiny`)

  A régua é o próprio personagem, que é o único ponto marcado à mão e portanto o
  único que não se discute:

      player_point (1695, 686) ....... no corpo dele, altura da cintura
      a linha do NOME dele ........... y 617, na cabeça  → 69 px acima

  E os Golem colados nele, uma casa abaixo:

      marca crua da barra ............ y 767
      corpo do Golem ................. y ~836   → 69 px abaixo da barra
      ponto PUBLICADO (marca + tile) . y 918    → 82 px ABAIXO do corpo

  Ou seja: a barra flutua **69 px** sobre o corpo, não os 151 que o `+ tile`
  assume. O tile a mais joga o ponto 82 px abaixo do bicho — meia casa — e é por
  isso que a bola caía no chão entre duas fileiras.

  **Correção de rota (14/09):** a primeira versão desta tabela trazia
  `{-25, 70}` e empurrava a bola 70 px pra BAIXO, dobrando o erro em vez de
  desfazê-lo. Os `-70` de então saíram de comparar o ponto publicado com
  `me + {dx, dy} * tile` — o que mede a sobra do ARREDONDAMENTO, não a distância
  da barra ao corpo — e os `+25`, de `player_point` estar marcado 25 px à
  esquerda da coluna da grade. "Ele jogou pra baixo, tem que ser mais pra cima"
  (Lucas, 14/09).

  ## Por que uma tabela por tela, e não uma conta

  Não escala com o tile: no ultrawide a barra flutua 69 px sobre um tile de 151
  (0,46 casa) e no notebook a proporção é outra. São duas geometrias do cliente,
  não uma proporção — do mesmo jeito que `Pokex.Screen.Tile` é tabela e não
  fórmula.

  Tela não medida devolve `:unknown`, e quem pergunta continua mirando no ponto
  publicado como sempre mirou: um palpite aqui erraria a bola de um jeito novo, e
  o que não foi medido não entra.
  """

  @measured %{
    # o ultrawide dele: 151 (o tile somado) menos 69 (a barra sobre o corpo)
    {3440, 1440} => {0, -82}
  }

  @doc """
  O vetor que leva do ponto PUBLICADO ao CORPO, nesta tela: `{dx, dy}` em pontos
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
  O ponto publicado levado até o corpo, na tela salva na calibração.

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
