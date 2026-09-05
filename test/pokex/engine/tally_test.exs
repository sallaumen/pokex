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

  test "without a trail there is no tally: a rate without a window is a guess" do
    assert Tally.card([]) == nil
    assert Tally.card([vitals(0)]) == nil
  end

  test "the kills come from combat, the only one that knows" do
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

  test "floor time is the pokemon off the field, not low HP" do
    card =
      Tally.card([
        vitals(0),
        vitals(1_000, %{"out" => false, "enemies" => nil}),
        vitals(2_000, %{"out" => false, "enemies" => nil}),
        vitals(3_000)
      ])

    assert card.down_pct == 50.0
  end

  test "and no-cooldown time is mobs on screen with zero keys ready" do
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
  test "the piles he really found" do
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

  test "where the minute went: a decision line lasts until the next" do
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

  test "and the revives counted per press, not per tick" do
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

  # "QUANTO TEMPO ENTRE DUAS TECLAS O JOGO ACEITA" é uma pergunta sobre o jogo, e
  # ele já responde: uma tecla que saiu deixa de estar pronta. Duas noites com
  # intervalos diferentes respondem juntas o que nenhuma discussão responde.
  describe "as teclas que realmente saíram" do
    defp receipt(gap, fired, missed, unknown \\ []) do
      %{
        "kind" => "receipt",
        "at" => 0,
        "gap_ms" => gap,
        "fired" => fired,
        "missed" => missed,
        "unknown" => unknown
      }
    end

    test "grouped by the interval in force, with each one's rate" do
      %{keys: keys} =
        Tally.card([
          vitals(0),
          receipt(500, ~w(3 4), []),
          receipt(500, ~w(5), ~w(6)),
          receipt(120, ~w(3), ~w(4 5)),
          vitals(60_000)
        ])

      assert %{rajadas: 2, sairam: 3, falharam: 1, taxa: 75.0} = keys[500]
      assert %{rajadas: 1, sairam: 1, falharam: 2, taxa: 33.3} = keys[120]
    end

    # Uma tecla que já estava esfriando não prova nada sobre o intervalo, e
    # contá-la como falha inventaria uma culpa.
    test "and what was already cooling stays out of the count" do
      %{keys: keys} =
        Tally.card([vitals(0), receipt(35, [], [], ~w(7 8 9)), vitals(60_000)])

      assert %{sem_veredito: 3, taxa: nil} = keys[35]
    end
  end
end
