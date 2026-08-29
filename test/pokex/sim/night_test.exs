defmodule Pokex.Sim.NightTest do
  @moduledoc """
  A NOITE, que é a unidade em que ele joga — e a duração que esta bancada nunca
  tinha medido.

  Toda medição feita aqui até 28/08 durou de um a cinco minutos. A caçada dele
  dura horas, e três defeitos deste simulador só apareciam depois dos vinte
  minutos: um deles derrubava a taxa de mortos em 83% e nenhum teste via.

  Os testes deste arquivo são longos de propósito. São segundos de CPU (a
  bancada é pura), e são a única forma de perguntar "isso aguenta a noite?".
  """
  use ExUnit.Case, async: true

  alias Pokex.Sim.{Bench, Scenario}

  @uma_hora 3_600_000

  defp por_minuto(report, minutos), do: report.outcome.killed / minutos

  describe "a caçada não pode definhar com o tempo" do
    # MEDIDO em 28/08, e este é o teste que faltava: com `nest_radius: 10`
    # contra `aggro_tiles: 8`, a caçada caía de 24,6 mortos/min em cinco
    # minutos para 4,1 em sessenta — 83%. Os monstros nasciam fora do alcance
    # em que qualquer coisa os acordaria, nunca morriam, nunca sumiam, e
    # OCUPAVAM a vaga deles no canto: o canto se dava por cheio e parava de
    # repor. A estrada esvaziava sozinha.
    test "um ninho mais largo que o aggro não seca a estrada" do
      cenario = Scenario.get("a-noite-medida")

      knobs = %{nest_radius: 10, aggro_tiles: 8, leash_tiles: 12}

      curta = Bench.run(%{cenario | seed: 1}, duration_ms: 300_000, knobs: knobs)
      longa = Bench.run(%{cenario | seed: 1}, duration_ms: @uma_hora, knobs: knobs)

      queda = 1 - por_minuto(longa, 60) / por_minuto(curta, 5)

      assert queda < 0.35,
             "a caçada definhou #{round(queda * 100)}% numa hora " <>
               "(#{Float.round(por_minuto(curta, 5), 1)}/min → #{Float.round(por_minuto(longa, 60), 1)}/min)"
    end

    test "e a hora inteira mata mais que os cinco minutos, em qualquer circuito" do
      for id <- ["a-noite-medida", "formigueiro", "enxame"] do
        cenario = Scenario.get(id)

        curta = Bench.run(%{cenario | seed: 3}, duration_ms: 300_000)
        longa = Bench.run(%{cenario | seed: 3}, duration_ms: @uma_hora)

        assert longa.outcome.killed > curta.outcome.killed * 3,
               "#{id}: 60 minutos mataram #{longa.outcome.killed} contra " <>
                 "#{curta.outcome.killed} em 5 — a caçada para no meio do caminho"
      end
    end
  end

  # O REVIVE É UM ITEM, e esta é a pergunta que a bancada não sabia fazer antes
  # de `revive_stock` existir: "esta configuração aguenta a noite com o bolso
  # que eu tenho?". A resposta medida com o bolso dele foi não — o estoque
  # esvazia em pouco mais de duas horas — e é dela que sai o freio abaixo.
  describe "o bolso de revives" do
    test "uma corrida com bolso pequeno o esvazia, e o cérebro PARA" do
      report =
        Bench.run(%{Scenario.get("formigueiro") | seed: 1},
          duration_ms: @uma_hora,
          knobs: %{revive_stock: 12, respawn_ms: 20_000}
        )

      aceitos = Enum.count(report.metrics.revives, & &1.accepted?)

      assert aceitos <= 12, "gastou #{aceitos} revives de um bolso de 12"

      assert Map.get(report.metrics.by_phase, :stranded, 0) > 0,
             "o bolso esvaziou e a caçada continuou como se nada fosse"
    end

    test "com o bolso infinito nada disso acontece" do
      report = Bench.run(%{Scenario.get("formigueiro") | seed: 1}, duration_ms: @uma_hora)

      assert Map.get(report.metrics.by_phase, :stranded, 0) == 0
    end
  end

  # POR ONDE ELE ANDOU — a métrica que faltava, e a única que enxerga a queixa
  # dele de 29/08: "ele vai para locais onde não tem muito monstro, porque ele
  # já matou, e vários locais do mapa ficam sem monstro sendo morto".
  #
  # Mortos por minuto não vê isso. Uma caçada presa oscilando dentro de um
  # bolso já limpo e uma caçada lenta que cobre o mapa inteiro dão o mesmo
  # número — e são coisas opostas.
  describe "o chão coberto" do
    test "uma caçada de uma hora dá voltas e visita todos os cantos" do
      report = Bench.run(%{Scenario.get("a-noite-medida") | seed: 1}, duration_ms: @uma_hora)

      cantos = length(Scenario.route(Scenario.get("a-noite-medida"), []).waypoints)

      assert report.metrics.legs == cantos,
             "visitou #{report.metrics.legs} de #{cantos} cantos — o resto do mapa não é caçado"

      assert report.metrics.laps > 1, "não fechou uma volta sequer em uma hora"
    end

    # A retirada era um circuito desfeito: ao chegar no canto anterior ela
    # REBOBINAVA o índice e encadeava pro anterior dele. No journal dele de
    # 29/08 são 771 waypoints andados de costas, um deles a volta inteira — 40
    # cantos em 92 segundos. Um recuo tático não pode desfazer a caçada.
    test "mesmo com a barra vivendo vazia, a caçada continua girando" do
      report =
        Bench.run(%{Scenario.get("enxame") | seed: 2},
          duration_ms: @uma_hora,
          config: %{reset_revive: false}
        )

      assert report.metrics.laps > 1,
             "com o reset desarmado a caçada parou de girar: #{report.metrics.laps} voltas"
    end
  end
end
