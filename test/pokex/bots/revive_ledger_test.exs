defmodule Pokex.Bots.ReviveLedgerTest do
  @moduledoc """
  O caderninho do estoque: digitar o estoque É o botão de repor.

  A noite de 27→28/08 mediu por que ele existe: 189 revives despachados em
  menos de duas horas, o estoque acabou às 23:43, e nenhuma regra sabia.
  """
  use ExUnit.Case, async: false

  alias Pokex.Bots.ReviveLedger

  setup do
    Pokex.SettingsStash.stash!(revive_stock: 20)
    ReviveLedger.reset()
    on_exit(&ReviveLedger.reset/0)
    :ok
  end

  test "cada despacho desce a conta, nunca abaixo de zero" do
    assert ReviveLedger.remaining() == 20

    Enum.each(1..3, fn _ -> ReviveLedger.note() end)
    assert ReviveLedger.spent() == 3
    assert ReviveLedger.remaining() == 17

    Enum.each(1..30, fn _ -> ReviveLedger.note() end)
    assert ReviveLedger.remaining() == 0
  end

  test "digitar um estoque novo zera a conta — é o botão de repor" do
    Enum.each(1..8, fn _ -> ReviveLedger.note() end)
    assert ReviveLedger.remaining() == 12

    Pokex.Settings.put(:revive_stock, 50)

    assert ReviveLedger.spent() == 0
    assert ReviveLedger.remaining() == 50
  end

  test "estoque em zero é 'não contei': orçamento desligado, conta nenhuma" do
    Pokex.Settings.put(:revive_stock, 0)

    ReviveLedger.note()
    assert ReviveLedger.remaining() == nil
  end
end
