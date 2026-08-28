defmodule Pokex.Sim.ToughnessTest do
  @moduledoc """
  A dureza do monstro medida em TECLAS — o único eixo em que "esse bicho tem
  mais vida" quer dizer alguma coisa.

  A armadilha que este knob existe pra fechar está documentada em
  `Sim.DamageLevel`: com o dano em porcentagem da vida, subir `mob_hp` de 100
  pra 500 não deixa bicho nenhum mais duro — a tecla passa a tirar 170 em vez
  de 34 e tudo morre no mesmo número de tiros. O primeiro teste aqui é essa
  armadilha, escrita, pra ninguém "consertar" o knob de volta pro buraco.
  """
  use ExUnit.Case, async: true

  alias Pokex.Bots.Combat.Loadout
  alias Pokex.Sim.Scenario
  alias Pokex.Sim.World

  defp mundo(knobs) do
    World.new(Scenario.ring(),
      seed: 1,
      knobs: knobs,
      loadout: %Loadout{name: "Teste", aoe: ["3"], single: ["6"], crowd: ["1"]}
    )
  end

  # Quantas teclas, no dano NOMINAL, pra derrubar um monstro inteiro. Pelo meio
  # da faixa e não pela ponta: a variação de ±15% existe pra que "três skills
  # matam" não seja lei da física (o jogo deixa sobrevivente por um fio), então
  # medir pelo pior sorteio mediria a variação, não a dureza.
  defp teclas_pra_matar(world, key) do
    {lo, hi} = World.damage_band(world, key)
    ceil(world.knobs.mob_hp / div(lo + hi, 2))
  end

  test "A ARMADILHA: sem a dureza, subir a vida do monstro não muda nada" do
    magro = mundo(%{mob_hp: 100})
    gordo = mundo(%{mob_hp: 500})

    assert teclas_pra_matar(magro, "3") == teclas_pra_matar(gordo, "3")
  end

  test "com a dureza, a vida do monstro para de importar e as teclas mandam" do
    for hp <- [100, 500] do
      world = mundo(%{mob_hp: hp, presses_to_kill: 8})

      assert teclas_pra_matar(world, "3") == 8
    end
  end

  test "a dureza vale pras duas famílias de dano — área e alvo único" do
    world = mundo(%{presses_to_kill: 4})

    assert teclas_pra_matar(world, "3") == 4
    assert teclas_pra_matar(world, "6") == 4
  end

  # Um cenário chamado "Couraçado" que respeita uma faixa antiga de 60-80 da
  # mesa dele não é um couraçado, é uma mentira com nome bonito.
  test "a dureza do cenário vence as faixas gravadas na mesa" do
    world = mundo(%{presses_to_kill: 8, skill_damage: %{"3" => {60, 80}}})

    assert teclas_pra_matar(world, "3") == 8
  end

  test "sem dureza, a faixa da mesa segue mandando" do
    world = mundo(%{skill_damage: %{"3" => {60, 80}}})

    assert World.damage_band(world, "3") == {60, 80}
  end

  test "dureza inválida cai no mundo de sempre, sem dividir por zero" do
    for invalida <- [0, -3, nil, "oito"] do
      world = mundo(%{presses_to_kill: invalida, mob_hp: 100})

      assert World.presses_to_kill(world) == nil
      assert {lo, _hi} = World.damage_band(world, "3")
      assert lo > 0
    end
  end

  test "a tela consegue perguntar se um cenário está mandando na mesa" do
    assert World.presses_to_kill(mundo(%{presses_to_kill: 5})) == 5
    assert World.presses_to_kill(mundo(%{})) == nil
  end

  test "uma tecla que não faz dano continua sem faixa" do
    world = mundo(%{presses_to_kill: 3})

    assert World.damage_band(world, "1") == :no_damage
  end
end
