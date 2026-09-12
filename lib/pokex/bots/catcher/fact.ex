defmodule Pokex.Bots.Catcher.Fact do
  @moduledoc """
  O que o Catcher tem em mãos, num mapa só.

  A mesma verdade sai por DOIS fios, e é este módulo que os alimenta: o fato
  `:capture` do quadro-negro, que o cérebro lê pra segurar os pés
  (`Engine.Logic.hold_for_capture/2`), e a transmissão `{:catcher, snapshot}`,
  que o Cavebot, o suporte e as telas leem. Cada um respondia a pergunta "o
  capturador está ocupado?" com uma conta própria, de fios diferentes, e as
  contas divergiam.

  São três coisas, e nenhuma delas é uma sessão aberta:

    * `pending` — corpos na fila ou uma bola no ar, das DUAS lentes (a
      varredura do acervo e a âncora do shiny). Segura os pés.
    * `anchors` — corpos que o rastro sabe onde estão, esperando a bola.
      Segura os pés.
    * `hunted?` — a barra de um shiny ainda DE PÉ. Não segura os pés (é hora
      de matar, não de jogar bola), mas licencia a bola com a captura
      desligada e é o que o azulejo da Central mostra.

  E `armed?`: tem alguém aqui pra jogar. Parar pra olhar o chão sem ninguém
  pra jogar é só parar.
  """

  alias Pokex.Bots.Catcher.Logic
  alias Pokex.Bots.Catcher.Trail

  # O pulso do worker: ele reescreve o fato a cada batida pra que `armed?` não
  # envelheça enquanto nada acontece.
  @pulse_ms 1_000

  @type t :: %{
          pending: non_neg_integer,
          anchors: non_neg_integer,
          hunted?: boolean,
          armed?: boolean
        }

  @doc "A batida do coração do worker, em ms."
  @spec pulse_ms() :: pos_integer
  def pulse_ms, do: @pulse_ms

  @doc """
  Quanto o fato pode envelhecer e ainda valer: três pulsos.

  O PRAZO É DO CATCHER. Ele era emprestado de `ShinyGuard.fact_max_age_ms/0`,
  que é a cadência da varredura de COR do vigia — duas coisas sem relação
  nenhuma, e mexer numa mudava em silêncio quanto tempo o cérebro acreditava
  na outra. Quem escreve o fato é este worker, no pulso dele.
  """
  @spec max_age_ms() :: pos_integer
  def max_age_ms, do: @pulse_ms * 3

  @doc "O fato, do rastro e da lógica de agora."
  @spec build(Trail.t(), %Logic{} | nil, boolean, map, integer) :: t
  def build(trail, logic, armed?, ref, now) do
    %{
      pending: (logic && Logic.pending(logic)) || 0,
      anchors: length(Trail.anchors(trail, ref, now)),
      hunted?: Trail.hunted(trail, ref) != nil,
      armed?: armed?
    }
  end

  @doc "Os campos de captura da transmissão, recortados do mesmo fato."
  @spec snapshot_fields(t) :: map
  def snapshot_fields(%{pending: pending, anchors: anchors, hunted?: hunted?}),
    do: %{pending_corpses: pending, anchors: anchors, hunted?: hunted?}
end
