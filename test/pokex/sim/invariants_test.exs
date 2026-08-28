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
  alias Pokex.Sim.Verdict

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

  # A APOSTA DELE, virada em teste: "teoricamente mesmo no caos nunca deveríamos
  # morrer, que com o revive e stun em área antes de usar o revive tudo se
  # resolve" (25/08).
  #
  # Ele estava certo, e o que faltava não era regra nenhuma — era o simulador
  # modelar a prensa sem o SONO na frente dela. O preço de um revive é o campo
  # vazio; uma pilha dormindo não cobra esse preço.
  #
  # Duas condições, e as duas são ajuste dele, não código: o prefixo do stun
  # ligado (e um pokémon com controle na barra pra ele apertar) e um piso curto
  # entre dois resgates. Com as duas, vinte e quatro corridas de cinco minutos
  # em cada circuito não perdem o pokémon uma única vez.
  describe "com stun na frente do revive, nada cai" do
    @dele %{rescue_stun_first: true}
    @piso %{revive_cooldown_ms: 2_000}

    for id <- ["cacada", "formigueiro"] do
      @id id

      test "#{id}: nenhuma queda em 24 corridas" do
        base = Scenario.get(@id)

        for seed <- 1..24 do
          cenario = %{base | seed: seed, knobs: Map.merge(base.knobs, @piso)}
          %{outcome: o} = Bench.run(cenario, duration_ms: 300_000, config: @dele)

          refute o.died_at, "#{@id} semente #{seed}: caiu em #{o.died_at}ms"
          assert o.killed > 0
        end
      end
    end
  end

  # A PROMESSA DE CADA CENÁRIO, cobrada — a outra metade de "está funcionando
  # bem", e a que ele lê na tela como ✅ ou ❌.
  #
  # As invariantes acima dizem que nenhuma ordem é ilegal; esta diz que a
  # caçada faz o que o cenário PROMETEU que ela faria. Um cenário sem promessa
  # (os experimentos de uma pilha) é de OBSERVAR e não entra aqui: sem
  # renascimento, quase toda a corrida é estrada vazia, e uma promessa de
  # resultado mediria o vazio.
  describe "cada caçada cumpre o que promete" do
    for scenario <- Enum.filter(Scenario.all(), &(&1.espera != [])) do
      @promissor scenario

      test "#{scenario.id}: #{Enum.join(scenario.espera, ", ")}" do
        quebradas =
          for seed <- 1..4,
              report = Bench.run(%{@promissor | seed: seed}, duration_ms: @minutes_ms),
              veredito <- Verdict.judge(report, @promissor.espera),
              not veredito.cumpriu?,
              do: "semente #{seed} — #{veredito.label}: #{veredito.porque}"

        assert quebradas == [], "#{@promissor.id}:\n  " <> Enum.join(quebradas, "\n  ")
      end
    end
  end
end
