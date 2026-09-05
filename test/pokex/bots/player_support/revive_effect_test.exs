defmodule Pokex.Bots.PlayerSupport.ReviveEffectTest do
  use ExUnit.Case, async: true

  alias Pokex.Bots.PlayerSupport.ReviveEffect

  # A morte de 01/09 às 08:14: bag sem revive, dez pedidos pagos e mudos, o
  # tanque de 55% a 2%. O juiz cobra a única testemunha que não mente: a VIDA.

  defp paga_e_falha(judge, hp, at) do
    judge = ReviveEffect.paid(judge, hp, at)
    # 5s depois a vida não subiu — quebra
    {judge, veredito} = ReviveEffect.tick(judge, hp - 3, at + 5_000)
    {judge, veredito}
  end

  test "a paid revive that heals closes the probe in peace" do
    judge = ReviveEffect.paid(ReviveEffect.new(), 40, 0)
    {judge, :quiet} = ReviveEffect.tick(judge, 100, 5_000)
    assert ReviveEffect.streak(judge) == 0
  end

  test "healed for real even without reaching 90: the jump is enough" do
    judge = ReviveEffect.paid(ReviveEffect.new(), 30, 0)
    {judge, :quiet} = ReviveEffect.tick(judge, 60, 5_000)
    assert ReviveEffect.streak(judge) == 0
  end

  test "three paid without a heal = shout; the fourth stays quiet in the refractory window" do
    {judge, :quiet} = paga_e_falha(ReviveEffect.new(), 50, 0)
    {judge, :quiet} = paga_e_falha(judge, 40, 10_000)
    {judge, :scream} = paga_e_falha(judge, 30, 20_000)
    {judge, :quiet} = paga_e_falha(judge, 20, 30_000)
    assert ReviveEffect.streak(judge) == 4
  end

  test "after the refractory window the shout returns" do
    {judge, :quiet} = paga_e_falha(ReviveEffect.new(), 50, 0)
    {judge, :quiet} = paga_e_falha(judge, 40, 10_000)
    {judge, :scream} = paga_e_falha(judge, 30, 20_000)
    {_judge, :scream} = paga_e_falha(judge, 20, 200_000)
  end

  test "a heal in the middle resets the series: a restocked bag does not inherit the breaks" do
    {judge, :quiet} = paga_e_falha(ReviveEffect.new(), 50, 0)
    {judge, :quiet} = paga_e_falha(judge, 40, 10_000)
    {judge, :quiet} = ReviveEffect.tick(judge, 95, 20_000)
    assert ReviveEffect.streak(judge) == 0
    {_judge, :quiet} = paga_e_falha(judge, 40, 30_000)
  end

  test "a reset revive on a full pokemon opens no probe: there is no heal to measure" do
    judge = ReviveEffect.paid(ReviveEffect.new(), 95, 0)
    {judge, :quiet} = ReviveEffect.tick(judge, 94, 6_000)
    assert ReviveEffect.streak(judge) == 0
  end

  test "the fainted one needing insistence counts a strike directly" do
    judge = ReviveEffect.new()
    {judge, :quiet} = ReviveEffect.fallen_again(judge, 0)
    {judge, :quiet} = ReviveEffect.fallen_again(judge, 3_000)
    {judge, :scream} = ReviveEffect.fallen_again(judge, 6_000)
    assert ReviveEffect.streak(judge) == 3
  end

  test "a probe that expired with the bar unreadable for 10s is a break too" do
    judge = ReviveEffect.paid(ReviveEffect.new(), 40, 0)
    {judge, :quiet} = ReviveEffect.tick(judge, nil, 5_000)
    assert ReviveEffect.streak(judge) == 0, "cego cedo demais não condena"
    {judge, :quiet} = ReviveEffect.tick(judge, nil, 11_000)
    assert ReviveEffect.streak(judge) == 1
  end

  test "the probe does not close early: the revive settle takes about 4s" do
    judge = ReviveEffect.paid(ReviveEffect.new(), 40, 0)
    {judge, :quiet} = ReviveEffect.tick(judge, 38, 2_000)
    assert ReviveEffect.streak(judge) == 0
  end
end
