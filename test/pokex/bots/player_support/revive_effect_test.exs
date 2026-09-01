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

  test "revive pago que cura fecha a sonda em paz" do
    judge = ReviveEffect.paid(ReviveEffect.new(), 40, 0)
    {judge, :quiet} = ReviveEffect.tick(judge, 100, 5_000)
    assert ReviveEffect.streak(judge) == 0
  end

  test "curou de verdade mesmo sem chegar a 90 — o salto basta" do
    judge = ReviveEffect.paid(ReviveEffect.new(), 30, 0)
    {judge, :quiet} = ReviveEffect.tick(judge, 60, 5_000)
    assert ReviveEffect.streak(judge) == 0
  end

  test "três pagos sem cura = grito; o quarto fica quieto na janela refratária" do
    {judge, :quiet} = paga_e_falha(ReviveEffect.new(), 50, 0)
    {judge, :quiet} = paga_e_falha(judge, 40, 10_000)
    {judge, :scream} = paga_e_falha(judge, 30, 20_000)
    {judge, :quiet} = paga_e_falha(judge, 20, 30_000)
    assert ReviveEffect.streak(judge) == 4
  end

  test "depois da janela refratária o grito volta" do
    {judge, :quiet} = paga_e_falha(ReviveEffect.new(), 50, 0)
    {judge, :quiet} = paga_e_falha(judge, 40, 10_000)
    {judge, :scream} = paga_e_falha(judge, 30, 20_000)
    {_judge, :scream} = paga_e_falha(judge, 20, 200_000)
  end

  test "uma cura no meio zera a série — bag reposta não herda as quebras" do
    {judge, :quiet} = paga_e_falha(ReviveEffect.new(), 50, 0)
    {judge, :quiet} = paga_e_falha(judge, 40, 10_000)
    {judge, :quiet} = ReviveEffect.tick(judge, 95, 20_000)
    assert ReviveEffect.streak(judge) == 0
    {_judge, :quiet} = paga_e_falha(judge, 40, 30_000)
  end

  test "revive de reset em pokémon cheio não abre sonda — não há cura pra medir" do
    judge = ReviveEffect.paid(ReviveEffect.new(), 95, 0)
    {judge, :quiet} = ReviveEffect.tick(judge, 94, 6_000)
    assert ReviveEffect.streak(judge) == 0
  end

  test "o caído que precisa de insistência conta strike direto" do
    judge = ReviveEffect.new()
    {judge, :quiet} = ReviveEffect.fallen_again(judge, 0)
    {judge, :quiet} = ReviveEffect.fallen_again(judge, 3_000)
    {judge, :scream} = ReviveEffect.fallen_again(judge, 6_000)
    assert ReviveEffect.streak(judge) == 3
  end

  test "sonda vencida com a barra ilegível por 10s também é quebra" do
    judge = ReviveEffect.paid(ReviveEffect.new(), 40, 0)
    {judge, :quiet} = ReviveEffect.tick(judge, nil, 5_000)
    assert ReviveEffect.streak(judge) == 0, "cego cedo demais não condena"
    {judge, :quiet} = ReviveEffect.tick(judge, nil, 11_000)
    assert ReviveEffect.streak(judge) == 1
  end

  test "a sonda não fecha antes da hora — o settle do revive leva uns 4s" do
    judge = ReviveEffect.paid(ReviveEffect.new(), 40, 0)
    {judge, :quiet} = ReviveEffect.tick(judge, 38, 2_000)
    assert ReviveEffect.streak(judge) == 0
  end
end
