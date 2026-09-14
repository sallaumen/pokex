defmodule Pokex.Screen.BarOffset do
  @moduledoc """
  Onde está o CORPO, dado o ponto que o olho PUBLICA de uma criatura.

  O `point` publicado não é a barra crua: `Pokex.Bots.CrowdScan.place/4` soma UM
  TILE à marca antes de publicar. Pra decidir tile isso some no arredondamento
  de `offset/3`; pra APONTAR O MOUSE não some, e é o único lugar onde importa.

  ## Medido no quadro dele (14/09, caixas-pretas de incidente)

  A régua é o personagem, o único ponto marcado à mão:

      player_point (1695, 686) ....... no corpo dele, altura da cintura
      a linha do NOME dele ........... y 617, na cabeça  → 69 px acima

  E os Golem colados nele, uma casa abaixo:

      marca crua da barra ............ y 767
      o pé do Golem (barra + 69) ..... y ~836
      o CORPO desenhado dele ......... y ~808   → o sprite sobe ~28 px do pé
      ponto PUBLICADO (marca + tile) . y 918    → 110 px ABAIXO do corpo

  Conferido em três cenas independentes: nas três a mira sem correção cai em
  pedra vazia e `-110` cai em cima do bicho. Bate com o quadrado que ELE desenhou
  na tela às 1h da manhã de 14/09, e com o que ele viu na noite seguinte — "a
  primeira vez que funcionou shiny ser capturado em muito tempo".

  ## O que NÃO serve pra decidir isto (14/09, e custou um revert)

  Contar `capturado` sobre bolas lançadas no diário **não responde**, e por três
  motivos que só apareceram depois:

    * uma âncora de brilho FALSO não tem corpo no chão; a bola vai lá, não acha
      nada, e o `Catcher` conclui "sumiu do ponto → capturado". Era sucesso
      contado em chão vazio, e o #659 (filtro do brilho falso) mudou essa taxa
      em 4× no MEIO da janela que eu estava comparando;
    * a faixa `🌟` do log não separa shiny de corpo comum — desde o #658 o
      rastro inteiro entra por ela e o "vizinho" também sai com estrela;
    * seis PRs entraram entre 19:05 e 23:58 de 13/09, e quase toda janela
      comparável tem menos de uma hora.

  Uma mudança de mira só se julga com um A/B de campo que alterne as duas miras
  DENTRO da mesma noite. Até existir esse A/B, a medição de quadro (que é
  verificável, e que ELE confirmou na tela) é a melhor evidência que há.

  ## Histórico, pra ninguém repetir

    * **#657** trazia `{-25, +70}` — empurrava a bola pra BAIXO, dobrando o erro.
      Os `-70` saíram de comparar o publicado com `me + {dx, dy} * tile`, que
      mede a sobra do ARREDONDAMENTO e não a distância barra→corpo; os `+25`, de
      `player_point` estar marcado 25 px à esquerda da coluna da grade.
    * **#665** esvaziou esta tabela com base na conta quebrada acima. Revertido.

  ## Por que uma tabela por tela, e não uma conta

  Não escala com o tile: no ultrawide a barra flutua 69 px sobre um tile de 151
  (0,46 casa) e no notebook a proporção é outra. São duas geometrias do cliente,
  não uma proporção — do mesmo jeito que `Pokex.Screen.Tile` é tabela e não
  fórmula.

  Tela não medida devolve `:unknown`, e quem pergunta continua mirando no ponto
  publicado: um palpite aqui erraria a bola de um jeito novo.
  """

  @measured %{
    # o ultrawide dele: 151 (o tile somado) menos 69 (a barra sobre o pé) mais
    # os 28 que o sprite sobe do pé — a bola quer o CORPO, não a sombra dele
    {3440, 1440} => {0, -110}
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
