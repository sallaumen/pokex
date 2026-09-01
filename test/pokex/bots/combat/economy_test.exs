defmodule Pokex.Bots.Combat.EconomyTest do
  @moduledoc """
  A rota barata: Tab, a tecla mais barata, um respiro, e a área só se ainda
  precisar.
  """
  use ExUnit.Case, async: true

  alias Pokex.Bots.Combat.{Loadout, Plan}

  defp loadout do
    %Loadout{
      name: "Dugtrio",
      aoe: ["3", "4"],
      single: ["7"],
      buffs: ["2"],
      shield: ["5"],
      crowd: ["1"]
    }
  end

  defp ctx(overrides \\ %{}) do
    Map.merge(%{enemies: 1, ready_keys: nil, config: %{}}, overrides)
  end

  test "a abertura é a tecla barata primeiro, a área atrás" do
    assert Plan.Economy.opening(loadout(), ctx()) == ["7", "3", "4"]
  end

  # "Ainda é necessário" sem inventar memória: se a barata está em cooldown, ela
  # já saiu e não resolveu.
  test "a rotação gasta a barata enquanto ela existe" do
    assert Plan.Economy.sustained(loadout(), ctx(%{ready_keys: ["7", "3", "4"]})) == ["7"]
  end

  test "com a barata fria, aí sim a área" do
    assert Plan.Economy.sustained(loadout(), ctx(%{ready_keys: ["3", "4"]})) == ["3", "4"]
  end

  # Cega aperta: segurar dano por causa de uma barra ilegível é o pior lado de
  # errar, e é a mesma regra que o modo comum já segue.
  test "sem leitura da barra, a barata sai às cegas" do
    assert Plan.Economy.sustained(loadout(), ctx(%{ready_keys: nil})) == ["7"]
  end

  # "Evitar comportamentos sofisticados ou consumo desnecessário": as auras
  # custam cooldown e este modo existe pra gastar pouco. Quem quiser aura no
  # relógio tem o /timers.
  test "nenhuma aura entra na rotação" do
    keys = Plan.Economy.sustained(loadout(), ctx(%{enemies: 4, ready_keys: ["2", "5", "7"]}))

    refute "2" in keys
    refute "5" in keys
  end

  test "o alvo único é do modo, não do ajuste global" do
    assert Plan.Economy.single(loadout(), ctx(%{config: %{single_target: false}})) == ["7"]
  end

  # `spent?` mede contra as duas, porque o modo gasta as duas.
  test "a barra gasta conta área e alvo único" do
    assert Plan.Economy.damage_keys(loadout(), ctx()) == ["3", "4", "7"]
  end

  test "o controle continua sendo do resgate" do
    assert Plan.Economy.crowd(loadout(), ctx()) == ["1"]
  end

  test "Tab volta a ser a primeira metade do fluxo" do
    assert Plan.Economy.tab?(ctx())
  end

  test "sem pokémon em campo não há o que apertar" do
    assert Plan.Economy.opening(nil, ctx()) == []
    assert Plan.Economy.sustained(nil, ctx()) == []
    assert Plan.Economy.damage_keys(nil, ctx()) == []
  end
end
