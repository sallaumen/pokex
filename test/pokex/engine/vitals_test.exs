defmodule Pokex.Engine.VitalsTest do
  @moduledoc """
  The sampling rule, which is the only thing standing between the four
  measurements and a stream that cannot answer them.

  Blur the transitions and `revive_settle_ms` — a number around 1200ms — is
  measured to the nearest second. Write every tick and a night is a hundred
  thousand identical lines. The rule has to do both, and this is where it is
  argued.
  """
  use ExUnit.Case, async: true

  alias Pokex.Engine.Vitals

  defp picture(overrides) do
    Map.merge(
      %{
        enemies: 3,
        own_hp: 90,
        own_out?: true,
        spent?: false,
        ready_keys: ["3", "4", "1"]
      },
      overrides
    )
  end

  defp orders(overrides) do
    Map.merge(%{phase: :engaged, revive: :hold}, overrides)
  end

  defp reading(picture_overrides \\ %{}, orders_overrides \\ %{}) do
    Vitals.reading(picture(picture_overrides), orders(orders_overrides), ~w(3 4))
  end

  describe "a leitura" do
    test "conta só as teclas de DANO prontas, não a barra inteira" do
      # a barra tem 3 prontas, mas só duas delas machucam
      assert reading().ready == 2
      assert reading().keys == 2
    end

    test "barra ilegível é nil, nunca zero — não saber não é estar sem cooldown" do
      assert reading(%{ready_keys: nil}).ready == nil
    end

    test "carrega o que as quatro medições precisam" do
      r = reading(%{own_hp: 55, enemies: 4}, %{revive: :now})

      assert r.hp == 55
      assert r.enemies == 4
      assert r.out == true
      assert r.revive == :now
      assert r.phase == :engaged
    end
  end

  describe "quando escrever" do
    test "a primeira leitura de uma corrida sempre" do
      assert Vitals.due?(nil, reading(), 1_000, 1_000)
    end

    test "nada mudou e o batimento não venceu: não escreve" do
      last = Map.put(reading(), :at, 1_000)

      refute Vitals.due?(last, reading(), 1_500, 1_000)
    end

    test "nada mudou mas o batimento venceu: escreve" do
      last = Map.put(reading(), :at, 1_000)

      assert Vitals.due?(last, reading(), 2_000, 1_000)
    end

    # Os quatro campos cuja TRANSIÇÃO é a medição.
    test "cada campo vigiado força uma linha na hora" do
      last = Map.put(reading(), :at, 1_000)

      mudancas = [
        {"o pokémon saiu de campo", reading(%{own_out?: false})},
        {"a lista encolheu", reading(%{enemies: 2})},
        {"a barra secou", reading(%{spent?: true})},
        {"o revive foi ordenado", reading(%{}, %{revive: :now})}
      ]

      for {o_que, agora} <- mudancas do
        assert Vitals.due?(last, agora, 1_100, 5_000), "#{o_que} tinha que virar linha na hora"
      end
    end

    # A vida cai o tempo todo; se ela forçasse linha, o batimento não existiria.
    test "a vida caindo NÃO força linha — pra isso existe o batimento" do
      last = Map.put(reading(), :at, 1_000)

      refute Vitals.due?(last, reading(%{own_hp: 40}), 1_100, 1_000)
    end
  end
end
