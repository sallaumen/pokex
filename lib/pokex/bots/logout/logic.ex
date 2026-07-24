defmodule Pokex.Bots.Logout.Logic do
  @moduledoc """
  A decisão do logout, sem nada em volta: sem processo, sem relógio, sem tela.
  Recebe o resultado de cada tecla e cada leitura da tela e devolve a próxima
  ação. Isso é o que permite testar o protocolo inteiro sem o jogo aberto.

  A regra que dá o tom: **toda ambiguidade resolve para "não deslogou"**. Uma
  leitura ilegível não confirma nada, e um logout que não confirmou termina em
  FALHA — que grita. Um "deslogado" falso é exatamente o prejuízo silencioso
  que essa feature existe para matar: o Lucas vai dormir achando que saiu, e a
  estamina queima a noite toda.

  Só uma leitura `:gone` DUAS VEZES SEGUIDAS confirma. Um glifo lido errado
  sozinho não consegue forjar um logout.

  ## A testemunha

  `:gone` sozinho não prova nada. A barra de baixo também devolve `nil` nos três
  campos quando as sub-regiões não estão calibradas, ou quando o atlas de glifos
  não conhece algum dígito — o "9" que faltava até 2026-07-23 é um caso real e
  vivido. Nesse mundo a HUD já estava "ausente" ANTES de qualquer tecla, e
  confirmar por ela seria inventar um logout.

  Por isso a medida é DIFERENCIAL: o worker lê a barra antes de agir e passa a
  leitura como `baseline`. Só quando ela era `:present` — a HUD estava legível,
  temos testemunha — um `:gone` posterior significa alguma coisa. Sem testemunha
  o logout termina em falha (`:sem_testemunha`), que grita: as teclas foram
  enviadas do mesmo jeito, só não dá para AFIRMAR que funcionaram.
  """

  # Quantas leituras uma tentativa ganha antes de apertar as teclas de novo.
  # É um limite interno para o laço terminar, não uma escolha que o Lucas
  # queira fazer — por isso é atributo, não ajuste.
  @reads_per_attempt 4

  defstruct state: :idle,
            reason: nil,
            attempt: 0,
            reads: 0,
            confirms: 0,
            config: %{},
            error: nil,
            # a HUD estava legível ANTES de apertar? sem isso, um :gone não é
            # prova de nada — ver "A testemunha" no moduledoc
            witness?: false

  @type reading :: :gone | :present | :unreadable
  @type action :: :press | :verify | {:finish, :out} | {:finish, {:failed, term()}}
  @type t :: %__MODULE__{}

  @doc "Quantas leituras cabem numa tentativa."
  @spec reads_per_attempt() :: pos_integer()
  def reads_per_attempt, do: @reads_per_attempt

  @doc """
  Começa um logout. A primeira ação é sempre apertar as teclas.

  `baseline` é a leitura da barra ANTES de agir. Só `:present` dá testemunha —
  qualquer outra coisa e nenhum `:gone` posterior poderá confirmar. Sem valor
  padrão de propósito: quem chama tem que decidir, e um padrão otimista aqui
  seria exatamente o bug que essa testemunha existe para impedir.
  """
  @spec start(String.t(), %{attempts: pos_integer()}, reading()) :: {t(), action()}
  def start(reason, config, baseline) do
    logic = %__MODULE__{
      state: :pressing,
      reason: reason,
      attempt: 1,
      config: config,
      witness?: baseline == :present
    }

    {logic, :press}
  end

  @doc """
  O resultado da sequência de teclas. Uma falha de foco entra por aqui também:
  do ponto de vista da decisão, "não trouxe o jogo para a frente" e "a tecla não
  saiu" são o mesmo fato — a tecla não aconteceu.
  """
  @spec after_press(t(), :ok | {:error, term()}) :: {t(), action()}
  def after_press(%__MODULE__{} = logic, :ok),
    do: {%{logic | state: :verifying, reads: 0, confirms: 0}, :verify}

  def after_press(%__MODULE__{} = logic, {:error, reason}), do: retry(logic, reason)

  @doc "Uma leitura da tela."
  @spec after_read(t(), reading()) :: {t(), action()}
  def after_read(%__MODULE__{} = logic, reading) do
    case {reading, logic.witness?} do
      {:gone, true} -> confirma(logic)
      {:gone, false} -> nao_confirma(logic, :sem_testemunha)
      {:present, _} -> nao_confirma(logic, :ainda_logado)
      {:unreadable, _} -> nao_confirma(logic, :ilegivel)
    end
  end

  defp confirma(logic) do
    logic = %{logic | reads: logic.reads + 1, confirms: logic.confirms + 1}

    cond do
      logic.confirms >= 2 -> {%{logic | state: :out}, {:finish, :out}}
      logic.reads >= @reads_per_attempt -> retry(logic, :nao_confirmou)
      true -> {logic, :verify}
    end
  end

  defp nao_confirma(logic, motivo) do
    logic = %{logic | reads: logic.reads + 1, confirms: 0}

    if logic.reads >= @reads_per_attempt,
      do: retry(logic, motivo),
      else: {logic, :verify}
  end

  defp retry(logic, motivo) do
    if logic.attempt < Map.fetch!(logic.config, :attempts) do
      {%{logic | state: :pressing, attempt: logic.attempt + 1, reads: 0, confirms: 0}, :press}
    else
      {%{logic | state: :failed, error: motivo}, {:finish, {:failed, motivo}}}
    end
  end
end
