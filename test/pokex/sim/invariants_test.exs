defmodule Pokex.Sim.InvariantsTest do
  @moduledoc """
  "Valide com mais exatidão que realmente está funcionando bem e que ele está
  sendo consistente" (Lucas, 2026-08-25).

  Uma taxa por minuto não responde isso. Ela é uma média, e uma média esconde
  exatamente o que ele viu: uma corrida em que tudo deu errado. O que responde é
  uma PROPRIEDADE — algo que tem que valer em todo tique de toda corrida — e
  cada uma das quatro aqui é um bug que este projeto já entregou uma vez.

  A malha é a biblioteca inteira de cenários contra oito sementes, e cada
  corrida são três minutos de caçada simulada.
  """
  use ExUnit.Case, async: true

  alias Pokex.Sim.Bench
  alias Pokex.Sim.Scenario

  @seeds 1..8
  @minutes_ms 180_000

  describe "em todo cenário, em toda semente" do
    for scenario <- Scenario.all() do
      @scenario scenario

      test "#{scenario.id}: nenhuma ordem quebra uma invariante" do
        broken =
          for seed <- @seeds, reduce: %{} do
            acc ->
              %{metrics: m} = Bench.run(%{@scenario | seed: seed}, duration_ms: @minutes_ms)
              Map.merge(acc, m.violations, fn _key, a, b -> a + b end)
          end

        assert broken == %{}, "#{@scenario.id}: #{inspect(broken)}"
      end
    end
  end

  # A OUTRA metade de "está funcionando bem": não basta não fazer nada errado,
  # tem que fazer alguma coisa. Uma caçada que anda em círculos sem matar nada
  # não quebra invariante nenhuma.
  describe "e a caçada acontece" do
    test "os dois circuitos de caçada matam em todas as sementes" do
      for id <- ["cacada", "formigueiro"], seed <- @seeds do
        %{outcome: o} = Bench.run(%{Scenario.get(id) | seed: seed}, duration_ms: @minutes_ms)

        assert o.killed > 0, "#{id} semente #{seed}: três minutos sem matar nada"
      end
    end

    test "e nenhuma delas passa a corrida inteira parada" do
      for id <- ["cacada", "formigueiro"], seed <- @seeds do
        %{metrics: m} = Bench.run(%{Scenario.get(id) | seed: seed}, duration_ms: @minutes_ms)

        andando =
          m.by_phase
          |> Map.take([:travelling, :gathering, :skipping, :unaided, :downed])
          |> Map.values()
          |> Enum.sum()

        assert andando > 0, "#{id} semente #{seed}: a corrida inteira sem sair do lugar"
      end
    end
  end
end
