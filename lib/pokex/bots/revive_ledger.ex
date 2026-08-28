defmodule Pokex.Bots.ReviveLedger do
  @moduledoc """
  O caderninho do estoque de revives: quantos ele disse ter, quantos já saíram.

  O revive é um ITEM, finito, e até 28/08 o bot não tinha noção nenhuma disso.
  A noite de 27→28/08 mediu o preço: 189 revives despachados em menos de duas
  horas (~1,7 por minuto), o estoque acabou às 23:43, e dali em diante cada
  regra que "compra" alguma coisa com um revive — chegar preparado, resetar a
  barra — pagou com dinheiro que não existia.

  O contrato é o mais simples que funciona: **digitar o estoque É o botão de
  repor**. O ajuste `revive_stock` diz quantos ele tem AGORA no momento em que
  digita; o caderninho conta cada despacho desde então, e quando o número do
  ajuste MUDA, a conta zera sozinha (mudou = ele acabou de contar de novo).
  Zero no ajuste é "não contei" — o orçamento inteiro desliga e nada muda de
  comportamento.

  A conta é de DESPACHOS, não de consumo: o bot não lê o inventário, e um
  aperto que o jogo recusou conta como gasto. Erra pro lado seguro — o
  caderninho fica pobre antes do bolso — e o freio do chão (`:stranded`) segue
  sendo a rede pra quando a conta e a realidade divergirem.

  Quem gasta ANOTA (o `PlayerSupport`, único lugar de onde um revive sai);
  quem decide PERGUNTA (`remaining/0` viaja no quadro da situação). Mesmo
  molde ETS do `SkillClock`.
  """

  alias Pokex.Settings

  @table :pokex_revive_ledger

  @doc false
  def table, do: @table

  @doc "Garante a tabela. Idempotente."
  @spec ensure_table() :: :ok
  def ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Anota UM revive despachado, contra o estoque em vigor agora."
  @spec note() :: :ok
  def note do
    ensure_table()
    stock = Settings.get(:revive_stock)
    {_stock, spent} = current(stock)
    :ets.insert(@table, {:ledger, stock, spent + 1})
    :ets.insert(@table, {:last_note_at, System.monotonic_time(:millisecond)})
    :ok
  end

  @doc """
  Saiu um revive nos últimos `window_ms`? É a pergunta do `HandWatch`: o
  `SkillClock.reset/0` do revive do bot apaga o carimbo do F4 dele mesmo, então
  uma sighting de F4 num drain atrasado ficaria SEM DONO — e viraria "mão do
  Lucas", contando o mesmo item duas vezes e re-zerando um relógio que já tem
  carimbos novos da rajada pós-revive. O caderninho sabe a hora do último
  despacho, de qualquer mão, e responde por ele.
  """
  @spec noted_within?(pos_integer, integer) :: boolean
  def noted_within?(window_ms, now \\ System.monotonic_time(:millisecond)) do
    ensure_table()

    case :ets.lookup(@table, :last_note_at) do
      [{:last_note_at, at}] -> now - at <= window_ms
      [] -> false
    end
  end

  @doc "Quantos já saíram desde a última vez que ele digitou o estoque."
  @spec spent() :: non_neg_integer
  def spent do
    ensure_table()
    {_stock, spent} = current(Settings.get(:revive_stock))
    spent
  end

  @doc """
  Quantos ainda restam, ou `nil` com o orçamento desligado (`revive_stock` em
  zero — "não contei"). Nunca negativo: a conta é aproximada e um número
  negativo pareceria medição.
  """
  @spec remaining() :: non_neg_integer | nil
  def remaining do
    case Settings.get(:revive_stock) do
      stock when is_integer(stock) and stock > 0 -> max(stock - spent(), 0)
      _off -> nil
    end
  end

  @doc "Esquece a conta — usado por teste e pela troca de personagem."
  @spec reset() :: :ok
  def reset do
    ensure_table()
    :ets.delete(@table, :ledger)
    :ets.delete(@table, :last_note_at)
    :ok
  end

  # A conta vale para UM valor digitado: se o ajuste mudou desde a última
  # anotação, ele recontou o bolso e a conta velha morre aqui, sem precisar de
  # observador nenhum de settings.
  defp current(stock) do
    case :ets.lookup(@table, :ledger) do
      [{:ledger, ^stock, spent}] -> {stock, spent}
      _outro_estoque_ou_vazio -> {stock, 0}
    end
  end
end
