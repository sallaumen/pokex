defmodule Pokex.Bots.Combat.PlanTest do
  @moduledoc """
  A mão que a caçada aperta, agora com um dono só.

  O que estes testes cobram é o CONTRATO — não as regras, que continuam sendo
  as do `Combat.Strategy` e já têm arquivo próprio: um plano responde as sete
  perguntas, aceita os dois vocabulários de knob (o cérebro chama
  `single_target`, o combate chama `combat_single_target`) e nunca levanta
  exceção sem pokémon em campo.
  """
  use ExUnit.Case, async: true

  alias Pokex.Bots.Combat.{Loadout, Plan}
  alias Pokex.Bots.Combat.Plan.Standard

  defp loadout do
    %Loadout{
      name: "Vespiquen",
      aoe: ["3", "4"],
      single: ["7"],
      buffs: ["2"],
      shield: ["5"],
      heal: ["6"],
      crowd: ["1"]
    }
  end

  defp ctx(overrides \\ %{}) do
    Map.merge(%{enemies: 1, ready_keys: nil, config: %{}}, overrides)
  end

  test "for/1 answers a plan for every mode, and for none" do
    assert Plan.for(:auto_combo) == Standard
    assert Plan.for(:economy) == Standard
    assert Plan.for(nil) == Standard
  end

  test "opening/2 leads with the area keys" do
    assert Standard.opening(loadout(), ctx()) == ["3", "4"]
  end

  test "opening/2 puts the ready auras in front, shield first" do
    ctx = ctx(%{enemies: 2, ready_keys: ["2", "5"], config: %{shield_from: 2}})

    assert Standard.opening(loadout(), ctx) == ["5", "2", "3", "4"]
  end

  # O piso do escudo tem dois nomes — o do cérebro e o do ajuste — e o plano
  # responde igual pros dois. Uma regra, um número: se a abertura e a rotação
  # discordarem sobre quando ele fica indestrutível, uma das duas está mentindo.
  test "opening/2 reads the shield floor under either name" do
    pelo_cerebro = ctx(%{enemies: 2, ready_keys: ["5"], config: %{shield_from: 2}})
    pelo_combate = ctx(%{enemies: 2, ready_keys: ["5"], config: %{combat_shield_from_enemies: 2}})

    assert Standard.opening(loadout(), pelo_cerebro) ==
             Standard.opening(loadout(), pelo_combate)
  end

  test "sustained/2 filters by the bar, opening/2 does not" do
    ctx = ctx(%{ready_keys: ["4"]})

    assert Standard.sustained(loadout(), ctx) == ["4"]
    assert Standard.opening(loadout(), ctx) == ["3", "4"]
  end

  test "sustained/2 goes blind when the bar cannot be read" do
    assert Standard.sustained(loadout(), ctx(%{ready_keys: nil})) == ["3", "4"]
  end

  test "small/2 is one damage key, never the shield or the aura" do
    ctx = ctx(%{enemies: 5, ready_keys: ["2", "5"], config: %{shield_from: 2}})

    assert Standard.small(loadout(), ctx) == ["3"]
  end

  test "single/2 is empty until he says the single-target keys hurt" do
    assert Standard.single(loadout(), ctx()) == []
    assert Standard.single(loadout(), ctx(%{config: %{single_target: true}})) == ["7"]
    assert Standard.single(loadout(), ctx(%{config: %{combat_single_target: true}})) == ["7"]
  end

  test "crowd/2 is the control key the brain may spend" do
    assert Standard.crowd(loadout(), ctx()) == ["1"]
  end

  # `spent?` mede contra esta lista. Uma tecla que o jogo ignora aqui dentro
  # nunca esfria, e aí a barra nunca conta como gasta.
  test "damage_keys/2 is the area, plus the single-target keys only when they hurt" do
    assert Standard.damage_keys(loadout(), ctx()) == ["3", "4"]

    assert Standard.damage_keys(loadout(), ctx(%{config: %{single_target: true}})) == [
             "3",
             "4",
             "7"
           ]
  end

  test "tab?/1 is off unless the knob says otherwise" do
    refute Standard.tab?(ctx())
    assert Standard.tab?(ctx(%{config: %{combat_tab_target: true}}))
  end

  test "every question answers empty with no pokémon on the field" do
    assert Standard.opening(nil, ctx()) == []
    assert Standard.sustained(nil, ctx()) == []
    assert Standard.small(nil, ctx()) == []
    assert Standard.single(nil, ctx()) == []
    assert Standard.crowd(nil, ctx()) == []
    assert Standard.damage_keys(nil, ctx()) == []
  end

  # Contagem desconhecida é o caso da foto ilegível: o escudo não sai (não dá
  # pra dizer que há dois em cima) e a rotação trata como um.
  test "an unknown count never arms the shield" do
    ctx = ctx(%{enemies: nil, ready_keys: ["5"], config: %{shield_from: 2}})

    assert Standard.opening(loadout(), ctx) == ["3", "4"]
  end
end
