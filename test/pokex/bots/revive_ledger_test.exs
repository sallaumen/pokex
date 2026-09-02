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

  # Um reset que lembra "o F4 acabou de pousar" deixa a janela cega armada pra
  # quem vier depois — a suíte pagou isso em 02/09.
  test "reset/0 forgets the landing too" do
    ReviveLedger.landed()
    assert ReviveLedger.landed_within?(60_000)

    ReviveLedger.reset()
    refute ReviveLedger.landed_within?(60_000)
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

  # A testemunha que o HandWatch consulta: o reset do :rescue_done apaga o
  # carimbo do F4 do bot, e um drain atrasado precisa de OUTRA prova de que
  # aquele F4 já tem dono — a hora do último despacho fica no caderninho.
  test "noted_within? lembra a hora do último despacho, e o reset esquece" do
    refute ReviveLedger.noted_within?(5_000)

    ReviveLedger.note()
    assert ReviveLedger.noted_within?(5_000)

    now = System.monotonic_time(:millisecond)
    refute ReviveLedger.noted_within?(5_000, now + 6_000)

    ReviveLedger.note()
    ReviveLedger.reset()
    refute ReviveLedger.noted_within?(5_000)
  end
end
