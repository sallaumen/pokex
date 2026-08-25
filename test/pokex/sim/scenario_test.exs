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
end
