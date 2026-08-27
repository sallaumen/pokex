defmodule Pokex.Sim.ScoreTest do
  @moduledoc """
  The scorecard is the thing two brains are compared with, so the way it counts
  has to be arguable on its own — a rate per minute made of the wrong events is
  worse than no rate at all, because it looks like evidence.
  """
  use ExUnit.Case, async: true

  alias Pokex.Sim.Score
  alias Pokex.Sim.Scenario

  # A RAJADA DE GRAÇA por padrão, pelo mesmo motivo do arquivo da bancada: desde
  # #367 as teclas custam tempo e a semente é 300ms, e um placar que mede o
  # preço da rajada junto com o que ele afirma não prova nenhum dos dois.
  # …e o ALVO DO BOLO em 1 junto: desde 27/08 a janela só fecha com seis na
  # tela, e os cenários daqui são pilhas de um a quatro — sem isso nenhum deles
  # abriria fogo, e todo teste do arquivo mediria a régua nova em vez do que
  # afirma.
  #
  # …e a ESPERA DA R12 em zero pelo mesmo motivo: desde 27/08 a régua para dois
  # segundos antes de estourar a área, e num cenário de 60s isso entra na conta
  # de tudo que se meça aqui. Quem quer medir a espera a pede por `config` — o
  # bloco dela vive em `logic_test.exs`.
  defp card(id, opts \\ []) do
    config =
      opts
      |> Keyword.get(:config, %{})
      |> Map.put_new(:skill_gap_ms, 0)
      |> Map.put_new(:bunch_ms, 0)

    %{card: card} =
      Score.run(
        Scenario.get(id),
        opts |> Keyword.put(:config, config) |> Keyword.put_new(:duration_ms, 60_000)
      )

    card
  end

  describe "as taxas" do
    test "um minuto simulado é um minuto, e as taxas saem por ele" do
      card = card("pilha-que-fecha")

      assert card.ms >= 60_000
      assert_in_delta card.minutes, 1.0, 0.02
      assert card.kills_per_min == Float.round(card.kills / card.minutes, 2)
    end

    test "cinco minutos de caçada contam cinco minutos, não um" do
      %{card: card} = Score.hunt(Scenario.get("pilha-que-fecha"), minutes: 5)

      assert_in_delta card.minutes, 5.0, 0.02
    end

    # A map that empties once and stays empty makes every rate a rate per fight.
    test "a caçada repovoa o ninho, e por isso mata mais que o cenário parado" do
      %{card: parado} =
        Score.run(Scenario.get("pilha-que-fecha"),
          duration_ms: 300_000,
          config: %{engage_from: 1}
        )

      %{card: cacando} =
        Score.hunt(Scenario.get("pilha-que-fecha"),
          minutes: 5,
          config: %{engage_from: 1, reset_revive: false, crowd_from: 99}
        )

      assert cacando.kills > parado.kills
    end
  end

  describe "o tempo parado — o número por trás do F4" do
    test "conta os ticks com bicho na tela E a barra gasta" do
      card = card("pilha-que-fecha", config: %{engage_from: 1})

      assert card.stalled_pct > 0,
             "uma luta inteira sem nenhum tique sem cooldown é uma luta que não aconteceu"

      assert card.stalled_pct <= card.enemies_pct,
             "não dá pra estar sem cooldown na frente de mais bicho do que se viu"
    end

    test "e o tempo no chão é o pokémon fora de campo, não a vida baixa" do
      # `reset_revive: false` pelo mesmo motivo do teste irmão na bancada: com a
      # R3b ligada o prefixo de controle dorme a pilha e o pokémon não cai, e
      # este teste é sobre o TEMPO NO CHÃO — sem chão não há o que medir.
      # …e `crowd_from: 99` pelo mesmo motivo do `reset_revive: false`: desde
      # 27/08 o limiar do controle é UM, então a pilha dorme em qualquer
      # engajamento e o pokémon não cai. Este teste é sobre o TEMPO NO CHÃO —
      # sem chão não há o que medir.
      card = card("morte", config: %{engage_from: 1, reset_revive: false, crowd_from: 99})

      assert card.deaths == 1
      assert card.down_pct > 50, "o revive está quebrado neste cenário: ele não volta"
    end
  end

  describe "os revives, julgados em vez de contados" do
    test "uma ordem recusada não vira um revive que aconteceu" do
      card = card("morte", config: %{engage_from: 1})

      assert card.revives.ordered > 0
      assert card.revives.accepted == 0
      assert card.revives.refused == card.revives.ordered
    end

    test "o revive por vida entra como resgate" do
      # `prepare_revive: false` pelo mesmo motivo que o resto isola knob: desde
      # 27/08 existe um revive PROATIVO que não é a R3b — o de chegar preparado
      # no próximo grupo —, e ele sairia aqui com a tela limpa.
      # …e `reset_revive: false` porque é literalmente o que a asserção diz:
      # "sem a regra R3b". Ela vinha da semente (ligada) e o cenário só não
      # produzia proativo por sorte — com os bichos no passo lento de verdade
      # (27/08) a barra passa a esgotar aqui, e o teste virou vermelho dizendo
      # a verdade sobre si mesmo.
      card =
        card("vermelho",
          config: %{engage_from: 1, prepare_revive: false, reset_revive: false}
        )

      assert card.revives.rescue > 0
      assert card.revives.proactive == 0, "sem a regra R3b, nada é proativo"
    end

    # HIS definition: bar spent, pile still worth fighting.
    test "com a R3b ligada, o mesmo mundo passa a ter revives proativos" do
      # `crowd_from: 99` dos dois lados: a pergunta é sobre a barra vazia, não
      # sobre a pilha grande — a R10 tem o teste dela.
      # E O RENASCIMENTO FIXADO, porque a pergunta é sobre UMA pilha que fecha.
      # Este número era o padrão inventado do `hunt/2` (45s); agora que o padrão
      # é o do dono (`sim_respawn_ms`, 20s) o cenário vira um fluxo contínuo e a
      # pilha deixa de ser uma. Um teste que depende do mundo declara o mundo.
      # …e AS DE ALVO ÚNICO LIGADAS dos dois lados: desde 27/08 a caçada não as
      # usa por padrão (no jogo dele elas não machucam), mas neste MODELO elas
      # dão dano — e sem elas esta pilha passa a chegar no amarelo, o que troca
      # a pergunta do teste (o que a R3b compra) pela pergunta de quanto dano
      # cada tecla dá.
      mundo = [minutes: 5, respawn_ms: 45_000]

      %{card: sem} =
        Score.hunt(
          Scenario.get("pilha-que-fecha"),
          mundo ++
            [
              config: %{
                engage_from: 1,
                reset_revive: false,
                crowd_from: 99,
                skill_gap_ms: 0,
                single_target: true,
                bunch_ms: 0
              }
            ]
        )

      %{card: com} =
        Score.hunt(
          Scenario.get("pilha-que-fecha"),
          mundo ++
            [
              config: %{
                engage_from: 1,
                reset_revive: true,
                crowd_from: 99,
                skill_gap_ms: 0,
                single_target: true,
                bunch_ms: 0
              }
            ]
        )

      assert sem.revives.proactive == 0
      assert com.revives.proactive > 0
      # O QUE ELA ATACA é o tempo sem cooldown — e o que ela CONSEGUE é outra
      # coisa. O próprio `Bench` já mede a regra como chapada ("dead flat —
      # 30,65 → 30,45 mortos/min, e o tempo sem cooldown mal se move: 90,77% →
      # 90,51%"), e aqui são cinco minutos com UM revive proativo: a direção do
      # sinal é um evento, não uma tendência. Este teste afirmava `<` estrito e
      # passava por sorte deste cenário; afirmar de novo seria pedir que o ruído
      # aponte sempre pro mesmo lado.
      #
      # O que a regra faz de verdade e sempre está uma linha acima: revives
      # proativos existem com ela e não existem sem ela.
      #
      # E A DIREÇÃO VOLTOU A SUMIR quando o mundo ficou lento (27/08): 7,3%
      # contra 5,9%, do outro lado. Duas viradas em um dia, nas duas direções,
      # por mudanças que não são da regra — a folga volta, e com ela a leitura
      # certa: o que a R3b faz de verdade está uma linha acima (revives
      # proativos existem com ela e não existem sem ela); o tempo parado é uma
      # consequência que depende do mundo inteiro.
      assert_in_delta com.stalled_pct, sem.stalled_pct, 5.0

      # O QUE A REGRA CUSTA MUDOU DE NATUREZA, duas vezes, e o teste conta as
      # duas porque a segunda só existe por causa da primeira:
      #
      #   1. Com o piso de verdade entre dois revives (`rescue_cooldown_ms`, e
      #      não os 2s que este simulador inventou até 25/08), ela deixou de
      #      COMPRAR revives e passou a REALOCÁ-LOS: cada proativo saía de um
      #      resgate.
      #   2. Com a R7 — andar enquanto a barra recarrega — os RESGATES somem:
      #      o pokémon deixa de chegar no amarelo. Então não há mais o que
      #      realocar, e cada proativo é uma prensa a mais.
      #
      # Ou seja: a R3b ficou mais cara exatamente porque o resto ficou melhor.
      #
      # …e a rajada de graça (`skill_gap_ms: 0`), de propósito: desde 26/08 as
      # teclas custam tempo, e com o intervalo ligado esta pilha VOLTA a precisar
      # de resgate — o corpo ocupado é o que o pokémon paga. Isso é um achado, e
      # está dito no PR; este teste é sobre o que a R7 compra, e mistura as duas
      # coisas se pagar as duas.
      assert sem.revives.rescue == 0, "com a R7 no lugar, esta pilha não precisa de resgate"
      assert com.revives.accepted > sem.revives.accepted, "então cada proativo é um revive novo"
    end
  end

  describe "as pilhas" do
    test "uma pilha é medida do primeiro bicho na lista até a lista vazia" do
      card = card("pilha-que-fecha", config: %{engage_from: 1})

      assert card.piles_cleared > 0
      assert is_integer(card.pile_ms.median)
      assert card.pile_ms.worst >= card.pile_ms.median
    end
  end

  # O RENASCIMENTO TEM DONO. `hunt/2` inventava 45s de padrão enquanto
  # `sim_respawn_ms` — o número que o /sim mostra e que o `Sim.Runner` obedece —
  # é 20s. O placar é a coisa com que dois cérebros são comparados, e ele estava
  # comparando os dois num mundo mais vazio do que o simulado.
  test "a caçada do placar renasce no ritmo do dono do número, não num inventado" do
    # um cenário SEM `respawn_ms` próprio — dos doze, só três têm, e nos outros
    # nove o padrão inventado era o que valia
    cenario = Scenario.get("pilha-que-pinga")

    a = Score.hunt(cenario, minutes: 1)
    b = Score.hunt(cenario, minutes: 1, respawn_ms: Pokex.Sim.Knobs.respawn_ms(:seeds))

    assert a.card == b.card
  end
end
