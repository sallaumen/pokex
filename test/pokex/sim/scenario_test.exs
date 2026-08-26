defmodule Pokex.Sim.ScenarioTest do
  use ExUnit.Case, async: true

  alias Pokex.Sim.Scenario

  test "every scenario has a unique id" do
    ids = Enum.map(Scenario.all(), & &1.id)

    assert ids == Enum.uniq(ids)
  end

  test "every scenario says what to watch for" do
    for scenario <- Scenario.all() do
      assert is_binary(scenario.why) and scenario.why != "", "#{scenario.id} has no why"
      assert is_binary(scenario.name) and scenario.name != ""
    end
  end

  test "the four groups he marked are all covered" do
    groups = Scenario.all() |> Enum.map(& &1.group) |> Enum.uniq() |> Enum.sort()

    assert Enum.sort(Scenario.experiment_groups()) == [:blind, :hands, :health, :ruler]
    assert groups == [:blind, :hands, :health, :hunt, :ruler]
  end

  test "every group has a label for the screen" do
    for scenario <- Scenario.all() do
      refute Scenario.group_label(scenario.group) == to_string(scenario.group)
    end
  end

  test "every script is ordered in time" do
    for scenario <- Scenario.all() do
      times = Enum.map(scenario.script, &elem(&1, 0))
      assert times == Enum.sort(times), "#{scenario.id} has an out-of-order script"
    end
  end

  test "get returns the scenario named by its id" do
    assert Scenario.get("tecla-morta").group == :hands
  end

  test "get returns nil for an id nobody defined" do
    assert Scenario.get("nao-existe") == nil
  end

  test "a scenario without a route plays on the built-in field" do
    assert Scenario.route(Scenario.get("pilha-pequena"), []).name == "campo de testes"
  end

  test "the built-in field carries exactly one nest" do
    nests = Enum.count(Scenario.ring().waypoints, &(&1.gather_ms != nil))

    assert nests == 1
  end

  test "a named route falls back to the field when it is not on this machine" do
    scenario = %{Scenario.get("pilha-pequena") | route: "uma rota que ele apagou"}

    assert Scenario.route(scenario, []).name == "campo de testes"
  end

  test "due returns the actions inside the window" do
    scenario = Scenario.get("tela-ilegivel")

    assert Scenario.due(scenario, 2_900, 3_000) == [{:fail, :blind}]
  end

  test "due fires a beat once and not again on the next tick" do
    scenario = Scenario.get("tela-ilegivel")

    assert Scenario.due(scenario, 2_900, 3_000) == [{:fail, :blind}]
    assert Scenario.due(scenario, 3_000, 3_100) == []
  end

  test "due returns nothing when no beat falls in the window" do
    assert Scenario.due(Scenario.get("tela-ilegivel"), 100, 200) == []
  end

  test "the dead key scenario breaks a key the loadout can actually fire" do
    scenario = Scenario.get("tecla-morta")

    assert [{_at, {:fail, {:dead_key, "3"}}}] = scenario.script
  end

  describe "o anel de Lotavanon" do
    test "é o mapa dele, com os números dele" do
      s = Scenario.get("lotavanon")

      # MEDIDO POR ELE: "os electrodos mal me dão dano, tipo menos de 1% da minha
      # vida por ataque". É o que torna este mapa uma questão de dano em vez de
      # sobrevivência, e é a única razão pra ele existir ao lado do formigueiro.
      assert s.knobs.bite_dmg == 1
      assert s.knobs.player_bite_dmg == 1

      # "direto tem nove pokémon ao redor do meu"
      assert Map.keys(s.knobs.nest_sizes) |> Enum.max() == 9
    end

    test "o circuito é um CÍRCULO, não um polígono de conveniência" do
      %{waypoints: pts} = Scenario.route(Scenario.get("lotavanon"), [])

      assert length(pts) == 12

      # Cada canto à mesma distância do centro (±1 tile de arredondamento): num
      # anel ele nunca volta pelo que já limpou, e o renascimento chega nele em
      # vez de ele voltar buscar.
      raios = Enum.map(pts, fn p -> :math.sqrt((p.x - 1000) ** 2 + (p.y - 1000) ** 2) end)

      assert Enum.max(raios) - Enum.min(raios) <= 1.0
    end

    test "CADA canto é ninho — sem isso o mapa cheio nasce vazio" do
      # `World.population_of/2` só trata um waypoint como ninho quando ele tem
      # `gather_ms` ou `fight_ms`; sem nenhum dos dois sai um dado de passante.
      # A primeira versão deste circuito não tinha nenhum dos dois e o "mapa
      # cheio de bichinho" rendia 1,19 monstro por tiro contra os 3,82 do
      # formigueiro — num mapa que devia render MAIS.
      %{waypoints: pts} = Scenario.route(Scenario.get("lotavanon"), [])

      assert Enum.all?(pts, &(&1.gather_ms || &1.fight_ms))
    end
  end
end
