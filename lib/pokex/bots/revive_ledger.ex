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

  @doc """
  Carimba que o F4 de um combo SAIU DO TECLADO agora — o fim do resgate, não o
  despacho dele.

  A diferença é o settle: o combo é stun → espera de 1,5-2s → F4, e o `note/0`
  (que serve o ESTOQUE) é feito no despacho. A janela cega pós-revive
  (`rescue_blackout_ms`) contada do despacho fica DESLOCADA settle inteiro pra
  trás: cobre o settle — quando o pokémon está em campo de propósito, podendo
  bater — e descobre o 1º-2º segundo pós-F4, que é a janela real. A noite de
  30/08 mediu o custo do deslocamento: 441 teclas "prontas" que o jogo ignorou,
  320 delas no primeiro segundo depois do F4 — 46% de falha nas rajadas da
  luta, cada uma comprando retentativa.
  """
  @spec landed() :: :ok
  def landed do
    ensure_table()
    :ets.insert(@table, {:last_landed_at, System.monotonic_time(:millisecond)})
    :ok
  end

  @doc "O F4 de um combo saiu nos últimos `window_ms`? A pergunta da janela cega."
  @spec landed_within?(pos_integer, integer) :: boolean
  def landed_within?(window_ms, now \\ System.monotonic_time(:millisecond)) do
    ensure_table()

    case :ets.lookup(@table, :last_landed_at) do
      [{:last_landed_at, at}] -> now - at <= window_ms
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
  # …e o POUSO também. Um reset que esquece o estoque mas lembra "o F4 acabou de
  # aterrissar" deixa a janela cega armada pra quem vier depois — na suíte, o
  # teste seguinte nascia dentro de um blackout de 2s (CI de 02/09, cinco
  # "skill não saiu" que dependiam da ordem); no jogo, uma troca de personagem
  # herdaria dois segundos de mudo.
  def reset do
    ensure_table()
    :ets.delete(@table, :ledger)
    :ets.delete(@table, :last_note_at)
    :ets.delete(@table, :last_landed_at)
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
