defmodule Pokex.Bots.Session do
  @moduledoc """
  A GERAÇÃO da sessão: um contador de ordens, e nada mais.

  Frente 1 do plano de consolidação, na menor forma que resolve a ambiguidade
  comprovada. O problema: o `Focus` guardava um booleano `resume?` — "tinha bot
  rodando quando o foco caiu". Um booleano não tem identidade: entre a perda e
  a volta do foco, QUALQUER outra ordem (Parar no painel, pânico, logout, freio
  do cavebot) deveria matar essa retomada pendente, e só o pânico matava
  (via latch). Um Stop manual entre a perda e a volta do foco era esquecido, e
  o refoco religava a frota por cima da ordem do humano.

  O contrato: **toda ordem incrementa a geração**. Quem quer retomar mais tarde
  guarda a geração da SUA pausa e só age se `generation/0` ainda for aquela —
  qualquer ordem no meio invalida a retomada, sem precisar saber qual foi.

  Ordens (`order/2`) são: `:start` e `:stop` (os funis do `BotSupervisor` — todo
  Iniciar/Parar/pânico/logout/freio passa por lá) e `:hold` (a pausa do Focus,
  que é retomável por definição — mas ainda invalida qualquer retomada mais
  antiga que a dela).

  Por que um processo próprio e minúsculo, em vez de uma chave no InputGate: o
  InputGate é o piso de segurança da ATUAÇÃO (veto físico de input); a geração
  é ordenação de INTENÇÃO. Misturar os dois foi descartado de propósito. E o
  plano (Frente 1) quer um dono da sessão para crescer — fase global, holds com
  dono, motivo da parada; este módulo é a semente dele, não um scheduler.

  Reinício deste processo zera o contador — e isso falha pro lado SEGURO: uma
  retomada guardada antes do reinício compara `gen != 0` (ordens reais deixam a
  geração em ≥ 1) e é descartada. Pior caso: o Lucas aperta Iniciar de novo.
  """
  use GenServer

  @typedoc "Uma ordem registrada: quem mandou o quê, em qual geração."
  @type order :: %{
          kind: :start | :stop | :hold,
          reason: String.t() | nil,
          generation: pos_integer(),
          at: integer()
        }

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    state = %{generation: 0, last_order: nil}

    case name do
      nil -> GenServer.start_link(__MODULE__, state)
      name -> GenServer.start_link(__MODULE__, state, name: name)
    end
  end

  @doc """
  Registra uma ordem e devolve a geração NOVA — atomicamente. Quem precisa
  comparar depois (o Focus) guarda exatamente o valor devolvido pela própria
  ordem; ler o contador num segundo passo abriria a janela em que outra ordem
  se intromete e a retomada compararia contra a geração errada.
  """
  @spec order(:start | :stop | :hold, String.t() | nil, GenServer.server()) :: pos_integer()
  def order(kind, reason \\ nil, server \\ __MODULE__) when kind in [:start, :stop, :hold],
    do: GenServer.call(server, {:order, kind, reason})

  @doc "A geração atual. Retomada pendente só vale se ainda for a da sua pausa."
  @spec generation(GenServer.server()) :: non_neg_integer()
  def generation(server \\ __MODULE__), do: GenServer.call(server, :generation)

  @doc "A última ordem registrada (nil antes da primeira) — para painel e diagnóstico."
  @spec last_order(GenServer.server()) :: order() | nil
  def last_order(server \\ __MODULE__), do: GenServer.call(server, :last_order)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:order, kind, reason}, _from, state) do
    generation = state.generation + 1

    order = %{
      kind: kind,
      reason: reason,
      generation: generation,
      at: System.monotonic_time(:millisecond)
    }

    {:reply, generation, %{state | generation: generation, last_order: order}}
  end

  def handle_call(:generation, _from, state), do: {:reply, state.generation, state}
  def handle_call(:last_order, _from, state), do: {:reply, state.last_order, state}
end
