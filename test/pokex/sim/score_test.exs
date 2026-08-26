defmodule Pokex.Sim.ScoreTest do
  @moduledoc """
  The scorecard is the thing two brains are compared with, so the way it counts
  has to be arguable on its own — a rate per minute made of the wrong events is
  worse than no rate at all, because it looks like evidence.
  """
  use ExUnit.Case, async: true

  alias Pokex.Sim.Score
  alias Pokex.Sim.Scenario

  defp card(id, opts \\ []) do
    %{card: card} = Score.run(Scenario.get(id), Keyword.put_new(opts, :duration_ms, 60_000))
    card
  end

  describe "as taxas" do
    test "um minuto simulado é um minuto, e as taxas saem por ele" do
      card = card("pilha-que-fecha")

      assert card.ms >= 60_000
      assert_in_delta card.minutes, 1.0, 0.02
      assert card.kills_per_min == Float.round(card.kills / card.minutes, 2)
    end

    test "cinco minutos de caçada contam cinco minutos, não um" do
      %{card: card} = Score.hunt(Scenario.get("pilha-que-fecha"), minutes: 5)

      assert_in_delta card.minutes, 5.0, 0.02
    end

    # A map that empties once and stays empty makes every rate a rate per fight.
    test "a caçada repovoa o ninho, e por isso mata mais que o cenário parado" do
      %{card: parado} =
        Score.run(Scenario.get("pilha-que-fecha"),
          duration_ms: 300_000,
          config: %{engage_from: 1}
        )

      %{card: cacando} =
        Score.hunt(Scenario.get("pilha-que-fecha"),
          minutes: 5,
          config: %{engage_from: 1, reset_revive: false, crowd_from: 99}
        )

      assert cacando.kills > parado.kills
    end
  end

  describe "o tempo parado — o número por trás do F4" do
    test "conta os ticks com bicho na tela E a barra gasta" do
      card = card("pilha-que-fecha", config: %{engage_from: 1})

      assert card.stalled_pct > 0,
             "uma luta inteira sem nenhum tique sem cooldown é uma luta que não aconteceu"

      assert card.stalled_pct <= card.enemies_pct,
             "não dá pra estar sem cooldown na frente de mais bicho do que se viu"
    end

    test "e o tempo no chão é o pokémon fora de campo, não a vida baixa" do
      card = card("morte", config: %{engage_from: 1})

      assert card.deaths == 1
      assert card.down_pct > 50, "o revive está quebrado neste cenário: ele não volta"
    end
  end

  describe "os revives, julgados em vez de contados" do
    test "uma ordem recusada não vira um revive que aconteceu" do
      card = card("morte", config: %{engage_from: 1})

      assert card.revives.ordered > 0
      assert card.revives.accepted == 0
      assert card.revives.refused == card.revives.ordered
    end

    test "o revive por vida entra como resgate" do
      card = card("vermelho", config: %{engage_from: 1})

      assert card.revives.rescue > 0
      assert card.revives.proactive == 0, "sem a regra R3b, nada é proativo"
    end

    # HIS definition: bar spent, pile still worth fighting.
    test "com a R3b ligada, o mesmo mundo passa a ter revives proativos" do
      # `crowd_from: 99` dos dois lados: a pergunta é sobre a barra vazia, não
      # sobre a pilha grande — a R10 tem o teste dela.
      %{card: sem} =
        Score.hunt(Scenario.get("pilha-que-fecha"),
          minutes: 5,
          config: %{engage_from: 1, reset_revive: false, crowd_from: 99}
        )

      %{card: com} =
        Score.hunt(Scenario.get("pilha-que-fecha"),
          minutes: 5,
          config: %{engage_from: 1, reset_revive: true, crowd_from: 99}
        )

      assert sem.revives.proactive == 0
      assert com.revives.proactive > 0
      assert com.stalled_pct < sem.stalled_pct, "o que ela ataca é o tempo sem cooldown"

      # O QUE A REGRA CUSTA MUDOU DE NATUREZA, duas vezes, e o teste conta as
      # duas porque a segunda só existe por causa da primeira:
      #
      #   1. Com o piso de verdade entre dois revives (`rescue_cooldown_ms`, e
      #      não os 2s que este simulador inventou até 25/08), ela deixou de
      #      COMPRAR revives e passou a REALOCÁ-LOS: cada proativo saía de um
      #      resgate.
      #   2. Com a R7 — andar enquanto a barra recarrega — os RESGATES somem:
      #      o pokémon deixa de chegar no amarelo. Então não há mais o que
      #      realocar, e cada proativo é uma prensa a mais.
      #
      # Ou seja: a R3b ficou mais cara exatamente porque o resto ficou melhor.
      assert sem.revives.rescue == 0, "com a R7 no lugar, esta pilha não precisa de resgate"
      assert com.revives.accepted > sem.revives.accepted, "então cada proativo é um revive novo"
    end
  end

  describe "as pilhas" do
    test "uma pilha é medida do primeiro bicho na lista até a lista vazia" do
      card = card("pilha-que-fecha", config: %{engage_from: 1})

      assert card.piles_cleared > 0
      assert is_integer(card.pile_ms.median)
      assert card.pile_ms.worst >= card.pile_ms.median
    end
  end
end
