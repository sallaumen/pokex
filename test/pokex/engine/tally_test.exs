defmodule Pokex.Engine.TallyTest do
  @moduledoc """
  O placar da NOITE, feito do rastro que o bot deixou em vez do mundo que ele
  não é dono.
  """
  use ExUnit.Case, async: true

  alias Pokex.Engine.Tally

  defp vitals(at, overrides \\ %{}) do
    Map.merge(
      %{"kind" => "vitals", "at" => at, "enemies" => 2, "ready" => 3, "out" => true},
      overrides
    )
  end

  defp decision(at, phase, overrides \\ %{}) do
    Map.merge(
      %{"kind" => "decision", "at" => at, "phase" => phase, "revive" => "hold"},
      overrides
    )
  end

  test "sem rastro não há placar — uma taxa sem janela é um chute" do
    assert Tally.card([]) == nil
    assert Tally.card([vitals(0)]) == nil
  end

  test "os mortos vêm do combate, que é o único que sabe" do
    card =
      Tally.card([
        vitals(0),
        %{"kind" => "kill", "at" => 30_000, "n" => 1},
        %{"kind" => "kill", "at" => 45_000, "n" => 2},
        vitals(60_000)
      ])

    assert card.kills == 2
    assert card.minutes == 1.0
    assert card.kills_per_min == 2.0
  end

  test "o tempo no chão é o pokémon fora de campo, não a vida baixa" do
    card =
      Tally.card([
        vitals(0),
        vitals(1_000, %{"out" => false, "enemies" => nil}),
        vitals(2_000, %{"out" => false, "enemies" => nil}),
        vitals(3_000)
      ])

    assert card.down_pct == 50.0
  end

  test "e o tempo sem cooldown é bicho na tela com zero teclas prontas" do
    card =
      Tally.card([
        vitals(0, %{"ready" => 0}),
        vitals(1_000, %{"ready" => 0, "enemies" => 0}),
        vitals(2_000, %{"ready" => 2}),
        vitals(3_000, %{"ready" => 0})
      ])

    assert card.stalled_pct == 50.0
  end

  # A VISÃO DE MUNDO que faltava: a régua dele discutida com o que o jogo
  # entrega, em vez de com o que eu imagino.
  test "as pilhas que ele encontrou de verdade" do
    card =
      Tally.card([
        vitals(0, %{"enemies" => 1}),
        vitals(1_000, %{"enemies" => 3}),
        vitals(2_000, %{"enemies" => 3}),
        vitals(3_000, %{"enemies" => 0}),
        vitals(4_000, %{"enemies" => nil})
      ])

    assert card.piles == %{1 => 1, 3 => 2}
  end

  test "onde foi o minuto: uma linha de decisão vale até a próxima" do
    card =
      Tally.card([
        decision(0, "travelling"),
        decision(10_000, "gathering"),
        decision(40_000, "engaged"),
        vitals(60_000)
      ])

    assert [
             %{phase: "gathering", ms: 30_000, pct: 50.0},
             %{phase: "engaged", ms: 20_000},
             %{phase: "travelling", ms: 10_000}
           ] = card.by_phase
  end

  test "e os revives contados por prensa, não por tique" do
    card =
      Tally.card([
        decision(0, "engaged"),
        decision(1_000, "emergency", %{"revive" => "now"}),
        decision(2_000, "recovering"),
        decision(3_000, "emergency", %{"revive" => "now"}),
        vitals(60_000)
      ])

    assert card.revives == 2
  end
end
