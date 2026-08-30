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
    assert groups == [:blind, :chefe, :hands, :health, :hunt, :mundo, :ruler]
  end

  # A ORDEM DA TELA tem que conhecer todo grupo que existe: um grupo fora dela
  # some da página em silêncio, que é a pior forma de um cenário deixar de
  # existir — ele continua no código, passando nos testes, e ninguém o roda.
  test "a ordem da tela cobre todos os grupos, sem sobra" do
    grupos = Scenario.all() |> Enum.map(& &1.group) |> Enum.uniq()

    assert Enum.sort(Scenario.group_order()) == Enum.sort(grupos)
  end

  describe "o símbolo, a cor e a promessa" do
    test "todo cenário tem símbolo e um aperto conhecido" do
      for scenario <- Scenario.all() do
        assert is_binary(scenario.icon) and scenario.icon != "", "#{scenario.id} sem símbolo"

        assert scenario.aperto in [:rotina, :aperto, :quebrado],
               "#{scenario.id}: aperto #{inspect(scenario.aperto)} não é um dos três"

        assert Scenario.aperto_tone(scenario.aperto) in [:ok, :warn, :danger]
        assert Scenario.aperto_note(scenario.aperto) != ""
      end
    end

    test "todo símbolo é único — dois cenários com o mesmo ícone não se distinguem" do
      icones = Enum.map(Scenario.all(), & &1.icon)

      assert icones == Enum.uniq(icones)
    end

    test "toda promessa declarada existe no catálogo do Verdict" do
      for scenario <- Scenario.all(), promessa <- scenario.espera do
        assert promessa in Pokex.Sim.Verdict.all(),
               "#{scenario.id} promete #{inspect(promessa)}, que ninguém sabe cobrar"
      end
    end

    # Uma caçada inteira sem promessa nenhuma seria um cenário que roda e não
    # responde nada. Os experimentos de uma pilha são o caso oposto de
    # propósito: sem renascimento, 90% da corrida é estrada vazia, e uma
    # promessa de resultado mediria o vazio.
    test "toda caçada promete alguma coisa" do
      for scenario <- Scenario.all(), scenario.group in [:hunt, :mundo] do
        assert scenario.espera != [], "#{scenario.id} é uma caçada e não promete nada"
      end
    end
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

  describe "o chão, quando ele não é liso" do
    # "uns pontos de obstáculo no caminho pra ele tropeçar e vermos com ele lida"
    # (26/08). Um circuito de chão liso responde sobre a régua e sobre o dano;
    # não responde nada sobre andar, que é onde a caçada de verdade trava.
    test "chão liso não bloqueia nada — é o que todo cenário sempre foi" do
      assert Scenario.blocked(Scenario.get("formigueiro")) |> Enum.empty?()
    end

    test "o anel tem parede por fora, por dentro, e pedras no corredor" do
      blocked = Scenario.blocked(Scenario.get("lotavanon"))

      raios =
        Enum.map(blocked, fn {x, y, _z} ->
          round(:math.sqrt((x - 1000) ** 2 + (y - 1000) ** 2))
        end)

      assert 14 in raios, "parede externa"
      assert 6 in raios, "parede interna"
      assert 11 in raios, "pedra dentro do corredor que ele anda"
    end

    test "NENHUMA pedra em cima de um canto — isso seria uma armadilha, não um teste" do
      # Um canto inalcançável não faz o bot tropeçar: faz ele nunca avançar, e o
      # cenário passa a medir um travamento em vez de um desvio.
      cenario = Scenario.get("lotavanon")
      %{waypoints: pts} = Scenario.route(cenario, [])
      cantos = MapSet.new(pts, &{&1.x, &1.y, &1.z})

      assert MapSet.intersection(cantos, Scenario.blocked(cenario)) |> Enum.empty?()
    end

    test "as pedras são FIXAS: duas sementes têm que medir o mesmo mapa" do
      assert Scenario.blocked(Scenario.get("lotavanon")) ==
               Scenario.blocked(%{Scenario.get("lotavanon") | seed: 99})
    end
  end
end
