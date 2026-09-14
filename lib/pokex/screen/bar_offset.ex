defmodule Pokex.Screen.BarOffset do
  @moduledoc """
  Onde está o CORPO, dado o ponto que o olho PUBLICA de uma criatura.

  **HOJE A TABELA ESTÁ VAZIA, e isso é um resultado, não um esquecimento.**
  Duas correções foram tentadas e as duas PIORARAM a captura no jogo dele. Até
  alguém medir uma terceira **no campo** — não na geometria de um quadro — a bola
  mira no ponto publicado, como sempre mirou.

  ## As três miras, medidas no diário dele pela taxa de captura por bola

      mira                      bolas   capturado na hora
      ------------------------  -----   -----------------
      ponto publicado, cru       1098         36 %
      #657  publicado +70        337          24 %
      #664  publicado -110       111           5 %

  A conta é `capturado` (o corpo sumiu do ponto na janela do arremesso) sobre
  bolas lançadas, nos três trechos separados pelos merges. O melhor regime é o
  que não mexe em nada, e é também o de longe mais bem medido.

  ## Por que as duas tentativas erraram

  O `point` publicado não é a barra crua: `Pokex.Bots.CrowdScan.place/4` soma UM
  TILE à marca antes de publicar. Medindo a geometria de um quadro, o corpo
  DESENHADO de um bicho VIVO fica ~110 px acima desse ponto — foi o que o #664
  corrigiu, e o quadro não mentia.

  **Mas a bola não é jogada num bicho vivo: é jogada num CORPO no chão.** O corpo
  é desenhado deitado, na tile, sem a altura do sprite de pé — e o ponto
  publicado, que a medição de quadro dizia estar "abaixo do bicho", está em cima
  do corpo. Medir o sprite errado foi o erro, nas duas vezes:

    * o #657 comparou o publicado com `me + {dx, dy} * tile`, o que mede a sobra
      do ARREDONDAMENTO, e ainda aplicou o sinal invertido;
    * o #664 mediu o sprite de um bicho DE PÉ e mirou no peito dele.

  ## O que falta pra uma terceira tentativa ser honesta

  Um quadro de `hora-da-bola` com um CORPO de verdade no chão e o ponto publicado
  marcado em cima dele — e depois um A/B de pelo menos algumas centenas de bolas.
  A caixa-preta já grava o quadro (`Pokex.Bots.BlackBox`, tags `hora-da-bola` e
  `depois-da-bola`) com `anunciada`, `corpo` e o cursor de verdade.

  Enquanto isso: tela não medida devolve `:unknown` e quem pergunta mira no ponto
  publicado. O que não foi medido NO CAMPO não entra.
  """

  # VAZIA DE PROPÓSITO — ver o moduledoc. Uma entrada aqui muda a mira de TODA
  # bola; ela só volta com um A/B de campo do lado dela, nunca com a geometria de
  # um quadro sozinha.
  @measured %{}

  @doc """
  O vetor que leva do ponto PUBLICADO ao CORPO, nesta tela: `{dx, dy}` em pontos
  de tela, pra somar. `:unknown` numa tela que ninguém mediu — que hoje são
  todas.
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
