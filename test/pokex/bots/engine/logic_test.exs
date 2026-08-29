defmodule Pokex.Bots.Engine.LogicTest do
  @moduledoc """
  His decision tree, as a table.

  Every rule here is one he stated on 2026-08-17, and the test is written so
  that breaking the rule breaks the test — the whole point of moving the
  decision out of three workers into one function is that the reasoning becomes
  arguable in one place.
  """
  use ExUnit.Case, async: true

  alias Pokex.Bots.Engine.Config
  alias Pokex.Bots.Engine.Logic

  # AS SEMENTES, não uma cópia à mão. A cópia é a mesma armadilha que fez o
  # bench responder sobre um bot que não existe: um ajuste novo nascia com um
  # valor aqui e outro no `Settings`, e nenhum teste notava.
  # …com UMA exceção declarada: a espera da R12 (`bunch_ms`) fica em zero na
  # base. O assunto da maior parte deste arquivo é QUEM fecha a janela de mob e
  # POR QUÊ; a espera que vem depois de fechar é uma regra própria, com o bloco
  # próprio dela no fim do arquivo. É o mesmo isolamento que `crowd_from: 99` e
  # `reset_revive: false` já fazem aqui.
  # …e `gather_target: 1` junto, pelo mesmo motivo: desde 27/08 a janela só
  # fecha quando o bolo chega no alvo (seis), e a maior parte deste arquivo
  # pergunta OUTRA coisa sobre pilhas de dois a quatro. O alvo tem o bloco dele.
  @config Config.merge(%{bunch_ms: 0, gather_target: 1})

  defp situation(overrides \\ %{}) do
    Map.merge(
      %{
        enemies: 4,
        worth_fighting?: true,
        growing?: false,
        stable_for_ms: 2_000,
        own_hp: 90,
        own_out?: true,
        spent?: false,
        prepared?: true,
        blind?: false,
        ready_keys: nil,
        # a segunda metade da régua (R6): quantos passos já foram andados
        # puxando ESTA pilha, e o contador monotônico do qual ela sai
        walked: 0,
        walked_total: 0
      },
      overrides
    )
  end

  defp hunt(overrides \\ %{}) do
    Map.merge(
      %{state: :walking, luring?: false, wp_index: 12, waypoints: 70},
      overrides
    )
  end

  defp world(overrides \\ %{}) do
    Map.merge(
      %{
        situation: situation(),
        hunt: hunt(),
        hands: %{opening: ~w(3 4 5 6 7 8 9), single: ~w(7 8 9), crowd: ["1"]}
      },
      overrides
    )
  end

  defp step(logic \\ Logic.new(), world, now), do: Logic.step(logic, world, @config, now)

  describe "walking the route (green)" do
    test "a plain leg walks with the fire held" do
      {logic, orders} = step(world(), 1_000)

      assert logic.state == :travelling
      assert orders.route == :go
      assert orders.fire == :hold
      assert orders.band == :green
    end

    test "a gathering leg walks and says it is gathering" do
      {logic, orders} = step(world(%{hunt: hunt(%{luring?: true})}), 1_000)

      assert logic.state == :gathering
      assert orders.route == :go
      assert orders.fire == :hold
      assert orders.why =~ "mobando"
    end
  end

  # "Gastei minhas skills num bicho bobo" (28/08): a pilha que a régua já
  # chamou de "não vale a área" só está sendo limpa porque a paciência acabou —
  # ela merece a MÃO PEQUENA (uma tecla de dano), não a rajada inteira.
  describe "a rajada do tamanho da pilha" do
    defp small_world(overrides) do
      world(%{
        situation:
          situation(
            Map.merge(
              %{enemies: 1, worth_fighting?: false, walked: 99, walked_total: 99},
              overrides
            )
          ),
        hunt: hunt(%{state: :fighting}),
        hands: %{opening: ~w(2 3 4), small: ["3"], single: [], crowd: ["1"]}
      })
    end

    test "paciência esgotada num bicho bobo abre com UMA tecla" do
      {logic, orders} = step(small_world(%{}), 10_000)

      assert logic.state == :engaged
      assert orders.fire == :free
      assert orders.opening == ["3"]
    end

    test "a pilha que vale a área segue abrindo inteira" do
      {_logic, orders} =
        step(small_world(%{enemies: 6, worth_fighting?: true, stable_for_ms: 9_999}), 10_000)

      assert orders.opening == ~w(2 3 4)
    end

    test "sem mão pequena composta, o desconhecido abre inteiro (fail-open)" do
      w = small_world(%{})
      w = %{w | hands: Map.put(w.hands, :small, [])}
      {_logic, orders} = step(w, 10_000)

      assert orders.opening == ~w(2 3 4)
    end
  end

  # "Não deveria estar andando por aí se eu não tenho nenhum cooldown
  # disponível" (28/08, depois de o personagem morrer). Juntar seis bichos sem
  # barra pra matar nem revive pra comprá-la é escolher uma luta sem saída.
  describe "pilha só se abre com o que pagar" do
    test "barra gasta mas revive ao alcance: junta como sempre (R3b paga)" do
      w = world(%{situation: situation(%{spent?: true}), hunt: hunt(%{luring?: true})})
      {logic, _orders} = step(w, 1_000)

      assert logic.state == :gathering
    end

    test "barra gasta e revive fora de alcance: não abre pilha, segue atirando" do
      w =
        world(%{
          situation: situation(%{spent?: true, revive_left: 0}),
          hunt: hunt(%{luring?: true})
        })

      {logic, orders} = step(w, 1_000)

      assert logic.state == :travelling
      assert orders.route == :go
      assert orders.fire == :free
      assert orders.why =~ "não abro pilha"
    end

    test "a barra esvaziando NO MEIO da régua larga a pilha, como o teto de tempo" do
      juntando = world(%{hunt: hunt(%{luring?: true})})
      {logic, _orders} = step(juntando, 1_000)
      assert logic.state == :gathering

      esvaziou =
        world(%{
          situation:
            situation(%{enemies: 2, worth_fighting?: false, spent?: true, revive_left: 0}),
          hunt: hunt(%{luring?: true})
        })

      {logic, orders} = Logic.step(logic, esvaziou, @config, 2_000)

      assert logic.state == :skipping
      assert orders.why =~ "deixando essa pilha"
    end
  end

  describe "the ruler of three (R1)" do
    test "a settled pile of three or more opens fire, area first" do
      {logic, orders} = step(world(%{hunt: hunt(%{state: :fighting})}), 1_000)

      assert logic.state == :engaged
      assert orders.fire == :free
      assert orders.opening == ~w(3 4 5 6 7 8 9)
      assert orders.why =~ "4 inimigos"
    end

    # "Se tem 1 ou 2 monstros, eu às vezes até ignoro aquele mob e sigo a minha
    # vida" — e ESPERAR agora é ANDAR (R6). Uma pilha abaixo da régua é
    # carregada junto até a paciência acabar; o teto continua sendo o que
    # transforma a espera numa decisão em vez de um travamento.
    test "a pile under the ruler is carried along, not stood next to" do
      small = situation(%{enemies: 1, worth_fighting?: false})
      w = world(%{situation: small, hunt: hunt(%{state: :fighting})})

      {logic, orders} = step(w, 1_000)

      assert logic.state == :gathering
      assert orders.route == :go, "parar pra contar é o que ele nunca faz"
      assert orders.fire == :hold
      assert orders.why =~ "juntando"
    end

    test "and it is left behind once the ceiling runs out" do
      small = situation(%{enemies: 1, worth_fighting?: false})
      w = world(%{situation: small, hunt: hunt(%{state: :fighting})})

      {logic, _} = step(w, 1_000)
      {logic, orders} = step(logic, w, 1_000 + @config.size_ceiling_ms)

      assert logic.state == :skipping
      assert orders.route == :go
      assert orders.fire == :hold
      assert orders.why =~ "não vale"
    end

    test "a pile still walking in is gathered, not fired at" do
      arriving = situation(%{enemies: 4, growing?: true, stable_for_ms: 0, walked: 0})
      w = world(%{situation: arriving, hunt: hunt(%{state: :fighting})})

      {logic, orders} = step(w, 1_000)

      assert logic.state == :gathering
      assert orders.fire == :hold
      assert orders.why =~ "juntando"
    end

    # R6, a frase dele inteira: "andei dois passos e achei três inimigos, só que
    # eu só andei dois passos. Que que custa eu andar mais 5 passos?"
    test "and the steps are what close it, not the clock" do
      w = fn walked ->
        world(%{
          situation: situation(%{enemies: 3, growing?: true, stable_for_ms: 0, walked: walked}),
          hunt: hunt(%{state: :fighting})
        })
      end

      {logic, dois} = step(w.(2), 1_000)
      assert dois.phase == :gathering
      assert dois.why =~ "2 de #{@config.gather_tiles} passos"

      {_logic, seis} = step(logic, w.(@config.gather_tiles), 1_200)
      assert seis.phase == :engaged
      assert seis.why =~ "passos juntando"
    end

    test "a pile that stopped growing, but not for long enough, is still gathered" do
      settling = situation(%{stable_for_ms: 900, walked: 0})
      w = world(%{situation: settling, hunt: hunt(%{state: :fighting})})

      {logic, orders} = step(w, 1_000)

      assert logic.state == :gathering
      assert orders.fire == :hold
    end

    # Once the fight is on, the ruler stops being a question: killing what you
    # started is right even as the list shrinks past three.
    test "a fight already opened does not re-measure itself as it kills" do
      w = world(%{hunt: hunt(%{state: :fighting})})
      {logic, _} = step(w, 1_000)
      assert logic.state == :engaged

      dying = situation(%{enemies: 1, worth_fighting?: false})

      {logic, orders} =
        step(logic, world(%{situation: dying, hunt: hunt(%{state: :fighting})}), 2_000)

      assert logic.state == :engaged
      assert orders.fire == :free
    end
  end

  # "Terminar o que começou" é a regra pra uma lista que ENCOLHE, não pra uma
  # tela com ninguém nela: segurar a rota ali narra uma luta contra nada e
  # mantém a caçada parada num ponto que ela já limpou.
  describe "a pilha que acabou" do
    test "a lista vazia encerra a rodada em vez de virar luta contra ninguém" do
      pilha = world(%{hunt: hunt(%{state: :fighting})})
      {logic, orders} = step(pilha, 1_000)
      assert orders.phase == :engaged

      limpa =
        world(%{
          situation: situation(%{enemies: 0, worth_fighting?: false}),
          hunt: hunt(%{state: :fighting})
        })

      {_logic, orders} = step(logic, limpa, 2_000)

      assert orders.phase == :travelling
      assert orders.route == :go
      assert orders.fire == :hold
      assert orders.why =~ "pilha limpa"
    end
  end

  describe "the yellow band: fecha a rodada (R3)" do
    defp yellow(overrides \\ %{}) do
      world(%{
        situation: situation(Map.merge(%{own_hp: 47}, overrides)),
        hunt: hunt(%{state: :fighting, luring?: true})
      })
    end

    test "stops extending the gathering the moment it enters" do
      {logic, orders} = step(yellow(), 1_000)

      assert logic.state == :closing
      assert orders.band == :yellow
      assert orders.route == :hold
    end

    test "waits for the pile before spending anything" do
      {_logic, orders} = step(yellow(%{growing?: true, stable_for_ms: 0}), 1_000)

      assert orders.fire == :hold
      assert orders.why =~ "esperando"
    end

    # R3's spending half: PlayerSupport's OWN rescue combo already presses the
    # reserved control key, confirms it and settles before it recalls — see
    # Logic's moduledoc. This module only says WHEN that combo should fire, so
    # once the pile has settled the fight spends what it can right away.
    test "spends the cooldowns once the pile has settled" do
      {logic, orders} = step(yellow(), 1_000)

      assert logic.state == :closing
      assert orders.fire == :free
      assert orders.opening == ~w(3 4 5 6 7 8 9)
      assert orders.revive == :hold
    end

    # R3: the revive is worth both halves only after the cooldowns are gone.
    test "revives when the pile is dead and the cooldowns are spent" do
      {logic, _} = step(yellow(), 1_000)
      clear = yellow(%{enemies: 0, worth_fighting?: false, spent?: true})
      {logic, orders} = step(logic, clear, 1_400)

      assert orders.revive == :now
      assert logic.state == :recovering
      assert orders.why =~ "revive"
    end

    # A pile that never dies (a stalemate) must not hold the round forever —
    # the same ceiling that ends the wait for it to arrive also ends the wait
    # for it to die.
    test "gives up on a pile that will not die and revives anyway" do
      {logic, _} = step(yellow(), 1_000)
      still_up = yellow(%{enemies: 3})
      {logic, orders} = step(logic, still_up, 1_000 + 8_000 + 1)

      assert orders.revive == :now
      assert logic.state == :recovering
    end
  end

  describe "the red band: emergency" do
    test "revives immediately, mid-fight, without waiting for anything" do
      dying = world(%{situation: situation(%{own_hp: 18}), hunt: hunt(%{state: :fighting})})

      {logic, orders} = step(dying, 1_000)

      assert orders.band == :red
      assert orders.revive == :now
      assert orders.route == :hold
      assert logic.state == :recovering
    end

    test "the red band outranks a gathering that has not finished" do
      dying =
        world(%{
          situation: situation(%{own_hp: 18, growing?: true, stable_for_ms: 0}),
          hunt: hunt(%{luring?: true})
        })

      {_logic, orders} = step(dying, 1_000)

      assert orders.revive == :now
    end
  end

  describe "recovering" do
    test "holds the route until the pokémon is back above the resume line" do
      {logic, _} = step(world(%{situation: situation(%{own_hp: 18})}), 1_000)
      assert logic.state == :recovering

      {logic, orders} = step(logic, world(%{situation: situation(%{own_hp: 55})}), 2_000)

      assert logic.state == :recovering
      assert orders.route == :hold
      assert orders.revive == :hold
    end

    test "resumes the route once the bar is back — com a tela limpa" do
      {logic, _} = step(world(%{situation: situation(%{own_hp: 18})}), 1_000)

      {logic, orders} =
        step(logic, world(%{situation: situation(%{own_hp: 95, enemies: 0})}), 2_000)

      assert logic.state == :travelling
      assert orders.route == :go
    end

    # …E COM BICHO NA TELA, A LUTA CONTINUA. "Quando ele acaba de usar o combo e
    # não mata, ele anda um pouco antes de reusar o combo depois que ele revive
    # — não faz sentido: a gente está no meio de uma luta agressiva" (27/08). O
    # revive foi gasto pra o combo chegar CEDO; recomeçar a régua (juntar,
    # andar, esperar) é o combo chegando tarde.
    test "mas com bicho na frente ela volta pro fogo, sem recomeçar a régua" do
      {logic, _} = step(world(%{situation: situation(%{own_hp: 18})}), 1_000)

      {logic, orders} =
        step(logic, world(%{situation: situation(%{own_hp: 95, enemies: 4})}), 2_000)

      assert logic.state == :engaged
      assert orders.fire == :free
      assert orders.route == :hold
      assert orders.why =~ "a luta continua"
    end

    # Um revive que não sai não pode encerrar a noite parado — e a espera dura o
    # que um revive leva pra se mostrar (`revive_confirm_ms`), não o teto de
    # recuperação inteiro. Ver R5.
    test "gives up as soon as the revive fails to show itself" do
      {logic, _} = step(world(%{situation: situation(%{own_hp: 18})}), 1_000)

      {logic, orders} =
        step(
          logic,
          world(%{situation: situation(%{own_hp: 40})}),
          1_000 + @config.revive_confirm_ms
        )

      assert logic.state == :travelling
      assert orders.why =~ "o revive não saiu"
    end
  end

  describe "not knowing" do
    # The picture says nil when it cannot see. A decision built on that would be
    # a guess with a fresh timestamp — so the engine holds its own orders and
    # lets every worker fall back to what it does today.
    test "an unreadable screen orders nothing and says so" do
      blind =
        world(%{situation: situation(%{enemies: nil, blind?: true, worth_fighting?: false})})

      {_logic, orders} = step(blind, 1_000)

      assert orders.fire == :hold
      assert orders.revive == :hold
      assert orders.why =~ "não estou vendo"
    end

    test "an unknown health bar never triggers a band" do
      unknown = world(%{situation: situation(%{own_hp: nil})})

      {_logic, orders} = step(unknown, 1_000)

      assert orders.band == :green
      assert orders.revive == :hold
    end

    test "no hunt at all, full health, is not a decision to make" do
      {_logic, orders} = step(world(%{hunt: nil}), 1_000)

      assert orders.route == :go
      assert orders.fire == :hold
      assert orders.revive == :hold
      assert orders.why =~ "sem caçada"
    end
  end

  describe "no hunt does not mean no pokémon (fishing mode)" do
    # This worker ticks whether or not Cavebot is running — while fishing, a
    # fresh :orders fact saying revive: :hold would silently outrank
    # PlayerSupport's own HP ladder, the one thing that has always protected
    # fishing. See the moduledoc.
    test "yellow with no hunt still revives now" do
      hurting = world(%{hunt: nil, situation: situation(%{own_hp: 55})})

      {logic, orders} = step(hurting, 1_000)

      assert logic.state == :guarding
      assert orders.revive == :now
      assert orders.why =~ "55%"
    end

    test "red with no hunt still revives now" do
      hurting = world(%{hunt: nil, situation: situation(%{own_hp: 20})})

      {logic, orders} = step(hurting, 1_000)

      assert logic.state == :guarding
      assert orders.revive == :now
      assert orders.band == :red
    end

    test "an unreadable HP with no hunt still holds, not guesses" do
      unknown = world(%{hunt: nil, situation: situation(%{own_hp: nil})})

      {_logic, orders} = step(unknown, 1_000)

      assert orders.revive == :hold
      assert orders.band == :green
    end
  end

  # "caçar em pokémons mais fracos que não mobam. Eles nem atacam sozinho"
  # (Lucas, 2026-08-24). Gathering is what makes the sizing wait worth paying;
  # against creatures that wander in one at a time it only loses fights — his
  # own hunt skipped a pile of three, twice, right after two clean kills.
  # R3b: "0 cooldowns livres, muitos inimigos ainda na tela… vale a pena usar o
  # revive no F4 rapidinho pra luta seguir firme e forte" (Lucas, 2026-08-25).
  # The bench measured the hunt spending 12-23% of a run in exactly that state,
  # and the rule buying back +13% of the kills for zero extra deaths.
  describe "o revive como reset de cooldown (R3b)" do
    # `crowd_from: 99` mantém a R10 fora desta pergunta: aqui o assunto é a
    # barra vazia, não a pilha grande.
    # `bunch_ms: 0` pelo mesmo motivo que `crowd_from: 99` está aqui: desde 27/08
    # a régua PARA antes de estourar a área (R12), e a espera apareceria na
    # frente da pergunta deste bloco.
    @reset Config.merge(%{
             reset_revive: true,
             engage_from: 3,
             crowd_from: 99,
             bunch_ms: 0,
             gather_target: 1
           })

    defp reset_step(logic, world, now), do: Logic.step(logic, world, @reset, now)

    defp spent_fight(overrides \\ %{}) do
      world(%{
        situation: situation(Map.merge(%{enemies: 4, spent?: true, own_hp: 100}, overrides)),
        hunt: hunt(%{state: :fighting})
      })
    end

    # A SEQUÊNCIA DELE, em dois tiques: "SEMPRE usar o revive dentro da range de
    # 5 segundos no máximo depois de usar a skill de controle". A R3b furava a
    # janela — gastava o revive com a pilha acordada — e desde 26/08 ela manda o
    # controle primeiro quando ele está pronto. O revive vem no tique seguinte.
    defp com_controle(logic, world, now) do
      {logic, controle} = reset_step(logic, world, now)

      assert controle.revive == :hold, "o controle sai antes, sem revive junto"
      assert controle.why =~ "controle primeiro"

      reset_step(logic, world, now + 500)
    end

    defp engaged(step_fun) do
      {logic, _opening} = step_fun.(Logic.new(), spent_fight(%{spent?: false}), 1_000)
      logic
    end

    test "com a chave ligada, a barra vazia na frente da pilha pede o revive" do
      logic = engaged(&reset_step/3)

      {_logic, orders} = com_controle(logic, spent_fight(), 2_000)

      assert orders.revive == :now
      assert orders.fire == :free, "a luta continua enquanto o corpo volta"
      assert orders.why =~ "controle no chão"
    end

    test "e NÃO entra em recuperação: isto não é um resgate" do
      logic = engaged(&reset_step/3)

      {after_order, _orders} = reset_step(logic, spent_fight(), 2_000)
      {_logic, next} = reset_step(after_order, spent_fight(%{spent?: false}), 9_000)

      assert next.phase == :engaged
      assert next.route == :hold
    end

    # O ORÇAMENTO NO RESET: comprar a barra de volta é conveniência, e com a
    # conta na reserva os últimos revives ficam pra emergência e pro caído.
    test "com o estoque na reserva, o reset não gasta — a fuga responde" do
      logic = engaged(&reset_step/3)

      {_logic, orders} = reset_step(logic, spent_fight(%{revive_left: 5}), 2_000)

      assert orders.revive == :hold
      assert orders.why =~ "recuando pelo chão limpo"
    end

    test "com sobra na conta, o reset gasta como sempre" do
      logic = engaged(&reset_step/3)

      {_logic, orders} = com_controle(logic, spent_fight(%{revive_left: 6}), 2_000)

      assert orders.revive == :now
    end

    # Sem a R3b, a mesma barra vazia tem a resposta de graça: andar (R7).
    test "desligada, a mesma barra vazia anda em vez de pedir revive" do
      sem = Config.merge(%{reset_revive: false, crowd_from: 99, bunch_ms: 0, gather_target: 1})
      sem_step = fn logic, world, now -> Logic.step(logic, world, sem, now) end
      logic = engaged(sem_step)

      {_logic, orders} = sem_step.(logic, spent_fight(), 2_000)

      assert orders.revive == :hold
      assert orders.why =~ "recuando pelo chão limpo até a barra voltar"
    end

    test "não duas vezes dentro do piso: uma barra que segue vazia não vira tecla presa" do
      logic = engaged(&reset_step/3)

      {after_first, first} = com_controle(logic, spent_fight(), 2_000)
      assert first.revive == :now

      {_logic, second} = reset_step(after_first, spent_fight(), 4_000)
      assert second.revive == :hold, "ainda dentro do piso"
    end

    # A TRAVA QUE ELE PEDIU (26/08): "usei revive e diz que recuperou 5
    # cooldowns, mas não recuperou um". Uma regra que paga um revive e não
    # recebe a barra de volta vai pagar o próximo, e o próximo. Ela se DESARMA
    # na primeira vez que a promessa não é cumprida.
    test "e se a barra NÃO voltar, ela se desarma — com prazo, não perpétuo" do
      logic = engaged(&reset_step/3)
      {logic, primeira} = com_controle(logic, spent_fight(), 2_000)
      assert primeira.revive == :now

      # muito depois do piso, com o pokémon em campo e a barra AINDA vazia
      passou = 2_000 + @reset.reset_revive_cooldown_ms + 10_000
      {logic, depois} = reset_step(logic, spent_fight(), passou)

      assert depois.revive == :hold
      assert is_integer(logic.reset_broken_at), "o reset foi cobrado e não veio — sai de cena"

      # …e o recuo DIZ o desarme, em vez de parecer covardia
      {logic, mudo} = reset_step(logic, spent_fight(), passou + 5_000)
      assert mudo.revive == :hold
      assert mudo.why =~ "DESARMADO"

      # passado o prazo do rearme, a regra volta pro jogo
      rearmado = passou + @reset.reset_rearm_ms + 1_000
      {logic, _} = reset_step(logic, spent_fight(%{spent?: false}), rearmado)
      assert logic.reset_broken_at == nil

      {_logic, de_novo} = com_controle(logic, spent_fight(), rearmado + 1_000)
      assert de_novo.revive == :now
    end

    test "mas uma barra que VOLTA mantém a regra armada" do
      logic = engaged(&reset_step/3)
      {logic, _} = com_controle(logic, spent_fight(), 2_000)

      cheia = spent_fight(%{spent?: false})
      passou = 2_000 + @reset.reset_revive_cooldown_ms + 10_000
      {logic, _} = reset_step(logic, cheia, passou)

      assert logic.reset_broken_at == nil

      {_logic, de_novo} = com_controle(logic, spent_fight(), passou + 1_000)
      assert de_novo.revive == :now
    end

    # O FALSO CULPADO de 28/08: numa pilha grande a barra volta cheia e é
    # despejada DE NOVO dentro da janela de cobrança — o reset funcionando.
    # O juiz antigo só olhava no fim da janela, via `spent?` de novo, e
    # condenava: cinco resets perfeitos no minuto um, desarme no segundo, e 39
    # minutos de "recuando pelo chão limpo" com pilhas de nove na tela.
    test "a barra que volta e é GASTA dentro da janela é um reset cumprido" do
      logic = engaged(&reset_step/3)
      {logic, _} = com_controle(logic, spent_fight(), 2_000)

      # 1,5s depois: o corpo voltou, a barra está CHEIA — a promessa foi vista
      {logic, _} = reset_step(logic, spent_fight(%{spent?: false}), 3_500)

      # bem depois da janela de cobrança, com a barra gasta DE NOVO pela pilha:
      # o veredito tem que continuar sendo cumprimento, não quebra
      passou = 2_000 + @reset.reset_revive_cooldown_ms + 10_000
      {logic, _} = reset_step(logic, spent_fight(%{spent?: false}), passou)

      assert logic.reset_broken_at == nil, "a volta foi vista — o gasto seguinte é caçada"

      {_logic, de_novo} = com_controle(logic, spent_fight(), passou + 1_000)
      assert de_novo.revive == :now
    end

    # A JANELA DELE, provada nos dois sentidos.
    test "sem controle pronto, a R3b ainda dispara — atrasado vale mais que nunca" do
      # Esperar o cooldown do controle seria trocar a barra inteira por um
      # prefixo. Sem `crowd` nas mãos não há prefixo a esperar.
      sem_controle =
        world(%{
          situation: situation(%{enemies: 4, spent?: true, own_hp: 100}),
          hunt: hunt(%{state: :fighting}),
          hands: %{opening: ["3"], single: [], crowd: []}
        })

      logic =
        elem(
          reset_step(
            Logic.new(),
            %{sem_controle | situation: situation(%{enemies: 4, spent?: false, own_hp: 100})},
            1_000
          ),
          0
        )

      {_logic, orders} = reset_step(logic, sem_controle, 2_000)

      assert orders.revive == :now
      assert orders.why =~ "sem cooldown"
    end

    test "não com o pokémon já na bola — a ordem bateria numa porta fechada" do
      logic = engaged(&reset_step/3)

      {_logic, orders} = reset_step(logic, spent_fight(%{own_out?: false}), 2_000)

      assert orders.revive == :hold
    end

    # O piso entre dois revives é `rescue_cooldown_ms`: um MINUTO. Uma prensa
    # proativa com a barra pela metade é o resgate que essa luta vai precisar
    # daqui a quarenta segundos, gasto adiantado.
    test "não com a vida pela metade: isso é gastar o resgate adiantado" do
      logic = engaged(&reset_step/3)

      {_logic, orders} = reset_step(logic, spent_fight(%{own_hp: 70}), 2_000)

      assert orders.revive == :hold
    end

    test "não por uma pilha que a régua nem abriria" do
      logic = engaged(&reset_step/3)

      {_logic, orders} = reset_step(logic, spent_fight(%{enemies: 2}), 2_000)

      assert orders.revive == :hold
    end

    test "vermelho continua sendo vermelho: o resgate ganha do reset" do
      logic = engaged(&reset_step/3)

      {_logic, orders} = reset_step(logic, spent_fight(%{own_hp: 20}), 2_000)

      assert orders.phase == :emergency
      assert orders.revive == :now
    end
  end

  # Um `fire: :free` com `opening: []` é uma ordem que PARECE ação e não faz
  # nada. Foi assim que uma simulação inteira rodou sem uma tecla sair da barra,
  # e é a forma do "lutando como sem pokémon escolhido" do diário dele.
  describe "sem teclas de ataque" do
    defp sem_maos(world), do: Map.put(world, :hands, %{opening: []})

    test "não narra uma luta que não pode acontecer" do
      world = sem_maos(world(%{hunt: hunt(%{state: :fighting})}))

      {_logic, orders} = step(world, 1_000)

      assert orders.phase == :handless
      assert orders.fire == :hold
      assert orders.why =~ "sem teclas"
    end

    test "mas segue andando: falta de configuração não para a noite" do
      world = sem_maos(world(%{hunt: hunt(%{state: :fighting})}))

      {_logic, orders} = step(world, 1_000)

      assert orders.route == :go
    end

    # O revive não precisa de tecla de ataque nenhuma.
    test "e o vermelho ainda ganha: a vida manda antes das mãos" do
      world = sem_maos(world(%{situation: situation(%{own_hp: 20})}))

      {_logic, orders} = step(world, 1_000)

      assert orders.phase == :emergency
      assert orders.revive == :now
    end
  end

  # A ordem "estourando a área" com o pokémon no chão foi 93% de uma corrida
  # inteira do bench: a barra some, `own_hp` vira nil, nil não é banda nenhuma,
  # e a caçada volta a abrir pilhas com o campo vazio. O fato já estava na
  # foto — `own_out?` — e ninguém lia.
  # UMA FUGA QUE NÃO ANDA NÃO É FUGA. Cercado, o pé não sai do lugar: a caçada
  # nem escapa nem luta — e no jogo dele ela ainda tropeçou em `:stuck` no meio
  # de uma, quinze segundos depois de começar (26/08).
  describe "a fuga da barra vazia" do
    # `crowd_from: 99` pra isolar a R7, do mesmo jeito que os testes da R3b já
    # fazem: desde 27/08 o limiar do controle é UM, então a R10 sai antes da
    # fuga em qualquer pilha — que é a mudança certa e mede +12% de mortos, e
    # que aqui apagaria a pergunta. A pergunta é sobre a barra vazia, não sobre
    # quando o controle sai.
    # E `reset_revive: false` pelo MESMO motivo, desde 27/08: com o piso de vida
    # em 90 a R3b passa a estar disponível numa barra vazia, e reviver é melhor
    # que andar — zera a barra na hora em vez de esperar 45s. A fuga é a regra
    # de quando NÃO há revive; medi-la com revive à mão mediria a R3b.
    @fuga Config.merge(%{crowd_from: 99, reset_revive: false, bunch_ms: 0, gather_target: 1})

    defp fuga_step(logic \\ Logic.new(), world, now), do: Logic.step(logic, world, @fuga, now)

    defp sem_cooldown(walked_total) do
      world(%{
        situation: situation(%{enemies: 3, spent?: true, walked_total: walked_total}),
        hunt: hunt(%{state: :fighting})
      })
    end

    defp lutando_gasto(now) do
      {logic, _} = fuga_step(sem_cooldown(0), 0)
      {logic, orders} = fuga_step(logic, sem_cooldown(0), now)
      {logic, orders}
    end

    test "com a barra vazia ela anda — recuando, não colecionando spawn" do
      {_logic, orders} = lutando_gasto(200)

      assert orders.phase == :engaged
      assert orders.route == :back
      assert orders.why =~ "recuando pelo chão limpo até a barra voltar"
    end

    test "mas se não sair do lugar, ela desiste e volta a lutar parada" do
      {logic, _} = lutando_gasto(200)

      {_logic, orders} = fuga_step(logic, sem_cooldown(0), 5_000)

      assert orders.route == :hold, "andar contra uma parede não é fugir"
      assert orders.why =~ "matando o que já abriu"
    end

    test "e se sair, ela continua — agora PELO CHÃO LIMPO, de costas" do
      {logic, _} = lutando_gasto(200)

      {_logic, orders} = fuga_step(logic, sem_cooldown(4), 5_000)

      # R7 com cerca (28/08): andar pra FRENTE com a barra gasta atravessa
      # spawn novo e o trem cresce mais rápido que a barra volta. A fuga anda,
      # mas recua pela rota — chão que a caçada acabou de limpar.
      assert orders.route == :back
      assert orders.why =~ "recuando pelo chão limpo"
    end

    # O TETO. A retirada não termina sozinha: o fogo fica LIVRE durante ela,
    # então cada tecla que volta é gasta na hora e `spent?` nunca chega a ser
    # falso. Com o reset desarmado — sem revive pra comprar a barra — recuar
    # vira o estado permanente da caçada.
    #
    # MEDIDO na noite dele de 29/08 (9,8h): 2.836 tiques de "recuando", 13
    # desarmes de 10 em 10 minutos, e 771 waypoints andados PARA TRÁS — um
    # deles a volta inteira, 40 cantos em 92 segundos. "Ficou em loop indo pra
    # frente e pra trás."
    test "passado o teto ela para de recuar e briga parada" do
      {logic, _} = lutando_gasto(200)

      # ainda dentro do teto: recua
      {logic, dentro} = fuga_step(logic, sem_cooldown(4), 5_000)
      assert dentro.route == :back

      # passado o teto: para, e o fogo continua livre
      {_logic, fora} = fuga_step(logic, sem_cooldown(40), @config.kite_max_ms + 1_000)

      assert fora.route == :hold, "recuar a rota inteira não é uma retirada"
      assert fora.fire == :free, "parar de recuar não é parar de bater"
      assert fora.why =~ "matando o que já abriu"
    end

    test "com o teto desligado (0) o recuo antigo, sem fim, volta" do
      sem_teto = Map.put(@fuga, :kite_max_ms, 0)
      logic = Logic.new()

      {logic, _} = Logic.step(logic, sem_cooldown(0), sem_teto, 0)
      {logic, _} = Logic.step(logic, sem_cooldown(0), sem_teto, 200)
      {_logic, orders} = Logic.step(logic, sem_cooldown(400), sem_teto, 600_000)

      assert orders.route == :back
    end

    # A fuga pertence a UMA luta: a próxima não pode herdar o veredito da
    # anterior.
    test "e a próxima luta começa com a dúvida a favor dela de novo" do
      {logic, _} = lutando_gasto(200)
      {logic, _} = fuga_step(logic, sem_cooldown(0), 5_000)

      {logic, _} = fuga_step(logic, world(%{hunt: hunt(%{state: :walking})}), 6_000)
      {logic, _} = fuga_step(logic, sem_cooldown(0), 7_000)
      {_logic, orders} = fuga_step(logic, sem_cooldown(0), 7_200)

      assert orders.route == :back
    end
  end

  describe "sem pokémon em campo" do
    defp caido(overrides \\ %{}) do
      world(%{
        situation: situation(Map.merge(%{own_out?: false, own_hp: nil}, overrides)),
        hunt: hunt(%{state: :fighting})
      })
    end

    test "não abre luta nenhuma e diz por quê" do
      {_logic, orders} = step(caido(), 1_000)

      assert orders.phase == :downed
      assert orders.fire == :hold
      assert orders.opening == []
      assert orders.why =~ "sem pokémon em campo"
    end

    test "segue andando a rota: parar no meio da pilha é pior" do
      {_logic, orders} = step(caido(), 1_000)

      assert orders.route == :go
    end

    # O motivo comum pra estar fora de campo é um revive JÁ em voo. A carência é
    # o tempo que um leva pra se mostrar, não a cadência inteira.
    test "espera o corpo voltar antes de pedir outro revive" do
      {_logic, orders} = step(caido(), 1_000)

      assert orders.revive == :hold
    end

    test "e pede de novo quando ele não volta" do
      {logic, _} = step(caido(), 1_000)
      {_logic, orders} = step(logic, caido(), 1_000 + @config.revive_confirm_ms)

      assert orders.revive == :now
      assert orders.why =~ "não voltou"
    end

    # A cadência é o piso que a MÃO respeita entre dois revives de caído. Pedir
    # mais rápido do que ela responde é barulho no feed e nada no jogo.
    test "e depois na cadência da mão, não uma por tique" do
      {logic, _} = step(caido(), 1_000)
      {logic, first} = step(logic, caido(), 1_000 + @config.revive_confirm_ms)
      assert first.revive == :now

      {logic, second} = step(logic, caido(), 1_100 + @config.revive_confirm_ms)
      assert second.revive == :hold

      passou = 1_000 + @config.revive_confirm_ms + @config.fainted_revive_cooldown_ms
      {_logic, third} = step(logic, caido(), passou)
      assert third.revive == :now
    end

    test "uma queda nova recomeça o piso, sem herdar o relógio da anterior" do
      {logic, _} = step(caido(), 1_000)
      {logic, _} = step(logic, caido(), 1_000 + @config.revive_confirm_ms)
      {logic, _} = step(logic, world(), 60_000)

      {_logic, orders} = step(logic, caido(), 60_100)

      assert orders.revive == :hold
    end

    test "não sei se ele está em campo não é ele estar no chão" do
      unknown = caido(%{own_out?: :unknown, own_hp: 90})

      {_logic, orders} = step(unknown, 1_000)

      refute orders.phase == :downed
    end

    test "poucos pedidos bastam: depois disso ele insiste devagar" do
      {logic, _} = step(caido(), 0)

      {_logic, quando} =
        Enum.reduce(1..700, {logic, []}, fn tick, {logic, quando} ->
          {logic, orders} = step(logic, caido(), tick * 100)
          {logic, if(orders.revive == :now, do: [{tick * 100, orders} | quando], else: quando)}
        end)

      # A PROPRIEDADE, não um número: o que impede a tecla presa é a cadência
      # CAIR, e ela cai por `recover_timeout_ms`. O teste afirmava `<= 6`, que
      # era o piso do caído (15s) disfarçado de regra — com o piso em 3s o mesmo
      # comportamento correto dá 10 pedidos, e o número quebrou sem nada ter
      # piorado. Setecentos tiques com resposta seriam a tecla presa; dez não são.
      horas = quando |> Enum.map(&elem(&1, 0)) |> Enum.sort()

      intervalos = Enum.zip(tl(horas), horas) |> Enum.map(fn {b, a} -> b - a end)

      # A PROPRIEDADE, não um número: o que impede a tecla presa é a cadência
      # CAIR. Com o piso em 3s (26/08) ele pede a cada 3s por meio minuto e
      # depois espalha — medido: 3s, 6s… 27s, e o próximo só aos 57s.
      #
      # O teste afirmava `<= 6`, que era o piso do caído (15s) disfarçado de
      # regra: o número quebrou sem nada ter piorado. Setecentos tiques com
      # resposta seriam a tecla presa; dez não são.
      assert length(horas) < 20, "70s de chão não podem virar uma tecla presa"

      assert List.last(intervalos) >= 5 * Enum.min(intervalos),
             "a insistência tem que DESACELERAR, não seguir na mesma cadência"

      # `quando` é acumulado por prepend: a cabeça é o pedido MAIS RECENTE.
      assert quando |> hd() |> elem(1) |> Map.get(:why) =~ "não está saindo"
    end

    # O FREIO. Medido na noite de 27→28/08: o estoque de revives acabou às
    # 23:43 e o bot passou 4,9 horas apertando uma tecla vazia, andando a rota
    # com o pokémon no chão. Um punhado de pedidos sem resposta é um revive que
    # não vem; horas deles não podem ser uma noite.
    test "depois do prazo ele desiste: para de andar, para de pedir, e diz por quê" do
      {logic, _} = step(caido(), 0)
      {logic, antes} = step(logic, caido(), @config.downed_give_up_ms - 1_000)

      assert antes.phase == :downed
      assert antes.route == :go

      {logic, orders} = step(logic, caido(), @config.downed_give_up_ms + 1_000)

      assert logic.state == :stranded
      assert orders.phase == :stranded
      assert orders.route == :hold
      assert orders.revive == :hold
      assert orders.fire == :hold
      assert orders.why =~ "parando a caçada"
    end

    # O BOLSO VAZIO NÃO PRECISA DE PROVA — e o prazo de cinco minutos era
    # cinco minutos que ele não tem.
    #
    # MEDIDO na noite simulada de cinco horas com o estoque dele (28/08): o
    # bolso esvaziou em 2h19 e o PERSONAGEM MORREU 2,1 SEGUNDOS DEPOIS, com o
    # freio empírico só marcado pra disparar cinco minutos MAIS TARDE. O
    # caderninho já sabia a resposta no instante do último despacho.
    test "com o caderninho em zero ele para NA HORA, sem esperar o prazo" do
      {logic, orders} = step(caido(%{revive_left: 0}), 1_000)

      assert logic.state == :stranded
      assert orders.phase == :stranded
      assert orders.route == :hold
      assert orders.revive == :hold
      assert orders.why =~ "acabaram os revives"
    end

    test "…mas um bolso com revives segue tentando, como sempre" do
      {logic, orders} = step(caido(%{revive_left: 3}), 1_000)

      assert logic.state != :stranded
      assert orders.phase == :downed
    end

    # Orçamento desligado é DESCONHECIDO, não vazio: quem não contou o bolso não
    # pode ser parado por uma conta que ninguém fez.
    test "sem orçamento (nil) o atalho não dispara" do
      {logic, orders} = step(caido(%{revive_left: nil}), 1_000)

      assert logic.state != :stranded
      assert orders.phase == :downed
    end

    test "o freio desligado (0) deixa a insistência lenta de sempre" do
      sem_freio = Config.merge(%{bunch_ms: 0, gather_target: 1, downed_give_up_ms: 0})
      logic = Logic.new()

      {logic, _} = Logic.step(logic, caido(), sem_freio, 0)
      {_logic, orders} = Logic.step(logic, caido(), sem_freio, 3_600_000)

      assert orders.phase == :downed
    end

    # O freio não é um trilho sem volta no CÉREBRO: se o corpo voltar (ele
    # repôs o estoque e reviveu na mão), a régua volta a decidir como sempre.
    # Quem é terminal é o bloqueio da caçada, e o dono de soltar é ele.
    test "o corpo de volta depois do freio devolve a régua" do
      {logic, _} = step(caido(), 0)
      {logic, desistiu} = step(logic, caido(), @config.downed_give_up_ms + 1_000)
      assert desistiu.phase == :stranded

      {_logic, orders} =
        step(logic, world(%{hunt: hunt(%{state: :fighting})}), @config.downed_give_up_ms + 5_000)

      refute orders.phase in [:stranded, :downed]
    end

    test "o corpo de volta retoma a caçada" do
      {logic, _} = step(caido(), 1_000)
      {_logic, orders} = step(logic, world(%{hunt: hunt(%{state: :fighting})}), 2_000)

      assert orders.phase in [:sizing, :engaged]
      assert orders.route == :hold
    end
  end

  # 47,5% de uma caçada inteira do bench foi gasta em `:recovering`, parada em
  # blocos de trinta segundos, com a barra caindo o tempo todo e `:engaged` com
  # 0,1%. O piso entre dois revives é um MINUTO: esperar por um que não pode vir
  # não cura nada.
  describe "o revive que não pode vir (R5)" do
    defp ferido(hp),
      do: world(%{situation: situation(%{own_hp: hp}), hunt: hunt(%{state: :fighting})})

    defp ordena_e_espera(hp) do
      {logic, orders} = step(ferido(hp), 1_000)
      assert orders.revive == :now
      logic
    end

    test "a espera acaba assim que a vida não sobe" do
      logic = ordena_e_espera(20)

      {_logic, orders} = step(logic, ferido(20), 1_000 + @config.revive_confirm_ms)

      assert orders.route == :go
      assert orders.why =~ "o revive não saiu"
    end

    # A prova de que o revive SAIU é a barra cheia: ele devolve o pokémon com
    # 100%, e o caminho de volta (corpo fora de campo) é do `:downed`. Uma vida
    # que subiu um pouco é uma poção, não um revive — esperar por ele aí é
    # esperar por algo que já foi recusado.
    test "e a barra de volta acima da linha retoma a caçada" do
      logic = ordena_e_espera(20)

      {_logic, orders} =
        step(logic, ferido(@config.resume_pct + 5), 1_000 + @config.revive_confirm_ms)

      refute orders.phase == :recovering
      assert orders.route == :hold, "voltou pra caçada: a pilha ainda está lá"
    end

    test "recusado, a banda para de segurar a rota até o piso passar" do
      logic = ordena_e_espera(20)
      {logic, _} = step(logic, ferido(20), 1_000 + @config.revive_confirm_ms)

      # DENTRO do piso, e escrito em função dele: com o piso em 10s este teste
      # perguntava aos 10_000ms e pegava a banda ainda segurando por sorte da
      # aritmética. Com o piso em 3s (26/08) os 10s já passaram, e o que ele
      # afirma — "até o piso passar" — pede um instante que esteja dentro dele.
      dentro = 1_000 + @config.revive_confirm_ms + div(@config.rescue_cooldown_ms, 2)
      {_logic, orders} = step(logic, ferido(45), dentro)

      assert orders.phase == :unaided
      assert orders.route == :go, "parar não levanta barra de vida nenhuma"
      assert orders.fire == :free, "o que já está mordendo tem que ser respondido"
      assert orders.why =~ "andando sem abrir pilha"
    end

    test "e não pede o que não pode ser dado" do
      logic = ordena_e_espera(20)
      {logic, _} = step(logic, ferido(20), 1_000 + @config.revive_confirm_ms)

      {_logic, orders} = step(logic, ferido(45), 10_000)

      assert orders.revive == :hold
    end

    test "passado o piso, a banda volta a mandar" do
      logic = ordena_e_espera(20)
      {logic, _} = step(logic, ferido(20), 1_000 + @config.revive_confirm_ms)

      passou = 1_000 + @config.revive_confirm_ms + @config.rescue_cooldown_ms + 1
      {_logic, orders} = step(logic, ferido(20), passou)

      assert orders.phase == :emergency
      assert orders.revive == :now
    end
  end

  # R1 manda ignorar um ou dois e seguir a vida. Só que quem vem atrás morde o
  # caminho inteiro, e a fase que anda BATENDO mata mais por minuto no bench.
  # A chave existe pra ele decidir, com o número na frente.
  describe "bater em quem vem junto ao deixar a pilha" do
    @batendo Config.merge(%{skip_fire: true})

    defp passando(config) do
      pequena =
        world(%{
          situation: situation(%{enemies: 1, worth_fighting?: false}),
          hunt: hunt(%{state: :fighting})
        })

      [0, @config.size_ceiling_ms + 1, @config.size_ceiling_ms + 100]
      |> Enum.reduce({Logic.new(), nil}, fn at, {logic, _} ->
        Logic.step(logic, pequena, config, at)
      end)
    end

    test "por padrão passa de mãos baixas: a régua é dele" do
      {_logic, orders} = passando(@config)

      assert orders.phase == :skipping
      assert orders.fire == :hold
    end

    test "ligada, bate — e só com as teclas de alvo único" do
      {_logic, orders} = passando(@batendo)

      assert orders.phase == :skipping
      assert orders.route == :go
      assert orders.fire == :free
      assert orders.opening == ~w(7 8 9), "a área é o que a régua está guardando"
    end
  end

  describe "hunting without gathering a pile" do
    @solo Config.merge(%{gather_piles: false, engage_from: 1, bunch_ms: 0, gather_target: 1})

    defp solo_step(logic \\ Logic.new(), world, now),
      do: Logic.step(logic, world, @solo, now)

    test "one creature is engaged at once, with no wait for a pile to settle" do
      world =
        world(%{
          situation: situation(%{enemies: 1, growing?: true, stable_for_ms: 0}),
          hunt: hunt(%{state: :fighting})
        })

      {_logic, orders} = solo_step(world, 1_000)

      assert orders.phase == :engaged
      assert orders.fire == :free
      assert orders.route == :hold
      assert orders.why =~ "sem esperar juntar"
    end

    test "the same picture with gathering ON waits instead" do
      world =
        world(%{
          situation: situation(%{enemies: 1, growing?: true, stable_for_ms: 0}),
          hunt: hunt(%{state: :fighting})
        })

      {_logic, orders} = step(world, 1_000)

      refute orders.fire == :free
    end

    test "a stretch recorded for mobbing is walked with the fire free" do
      world = world(%{hunt: hunt(%{state: :walking, luring?: true})})

      {_logic, orders} = solo_step(world, 1_000)

      assert orders.route == :go
      assert orders.fire == :free
      assert orders.why =~ "sem juntar pilha"
    end

    test "the ruler still rules: below it, nothing is engaged" do
      world =
        world(%{
          situation: situation(%{enemies: 1, worth_fighting?: false, growing?: true}),
          hunt: hunt(%{state: :fighting})
        })

      {_logic, orders} = solo_step(world, 1_000)

      refute orders.phase == :engaged
    end
  end

  # R10 — O CONTROLE É UMA SKILL, NÃO UM AMULETO, e a regra é dele inteira
  # (26/08, vendo a própria caçada): "tento ir usando o 1 pra quando tem muito
  # monstro, pra eu não morrer, porque se eu ficar guardando o 1 nessas hunts
  # mais sérias não dá certo... mas SEMPRE usar o revive dentro da range de 5
  # segundos no máximo depois de usar a skill de controle".
  describe "o controle e a janela de cinco segundos" do
    # `bunch_ms: 0` pelo mesmo motivo que `crowd_from: 99` está aqui: desde 27/08
    # a régua PARA antes de estourar a área (R12), e a espera apareceria na
    # frente da pergunta deste bloco.
    # A RÉGUA DECLARADA: este bloco mede a janela do controle, não quando uma
    # pilha vale a luta. Com a régua semeada em 6 (29/08) as pilhas de 3 a 5
    # daqui deixariam de valer, e o teste passaria a medir a régua.
    @r10 Config.merge(%{
           reset_revive: true,
           crowd_from: 4,
           stun_window_ms: 5_000,
           bunch_ms: 0,
           gather_target: 1,
           engage_from: 2
         })

    defp pilha(n, overrides \\ %{}) do
      world(%{
        situation: situation(Map.merge(%{enemies: n, ready_keys: ~w(1 3 4 5 6)}, overrides)),
        hunt: hunt(%{state: :fighting})
      })
    end

    # Abre a luta numa pilha PEQUENA: assim o `:engaged` já existe e o controle
    # ainda não foi gasto quando a pilha cresce.
    defp aberta(_mundo) do
      pequena = pilha(2)
      {logic, _} = Logic.step(Logic.new(), pequena, @r10, 0)
      {logic, _} = Logic.step(logic, pequena, @r10, 100)
      logic
    end

    test "numa pilha grande o controle sai junto com o dano" do
      {_logic, orders} = Logic.step(aberta(pilha(5)), pilha(5), @r10, 200)

      assert "1" in orders.opening
      assert orders.why =~ "controle e dano juntos"
    end

    test "numa pilha pequena ele não sai — continua guardado" do
      {_logic, orders} = Logic.step(aberta(pilha(2)), pilha(2), @r10, 200)

      refute "1" in orders.opening
    end

    test "e com a tecla em cooldown ele não é prometido" do
      esfriando = pilha(5, %{ready_keys: ~w(3 4 5 6)})

      {_logic, orders} = Logic.step(aberta(esfriando), esfriando, @r10, 200)

      refute "1" in orders.opening
    end

    # A JANELA: com a pilha dormindo o campo vazio não custa nada, e o revive
    # devolve o controle junto com o resto da barra.
    test "e o revive sai dentro da janela, logo depois do controle" do
      gasta = pilha(5, %{spent?: true})
      logic = aberta(gasta)
      {logic, primeira} = Logic.step(logic, gasta, @r10, 200)
      assert "1" in primeira.opening

      {_logic, orders} = Logic.step(logic, gasta, @r10, 1_200)

      assert orders.revive == :now
      assert orders.why =~ "dentro da janela"
    end

    test "mas não depois que ela fecha" do
      gasta = pilha(5, %{spent?: true})
      logic = aberta(gasta)
      {logic, _} = Logic.step(logic, gasta, @r10, 200)

      {_logic, orders} = Logic.step(logic, gasta, @r10, 200 + @r10.stun_window_ms + 1)

      refute orders.why =~ "dentro da janela"
    end

    # O CONTROLE OFENSIVO NÃO É LICENÇA PRA REVIVER. Até 27/08 a janela não
    # olhava a barra: com `crowd_from` baixo, qualquer bolo fazia o controle
    # sair, a janela abria, e o revive saía com a barra INTEIRA na mão. Medido
    # nas 6 sementes: 19 dos 137 revives do anel saíam com cinco teclas prontas.
    #
    # "A gente tem que usar todas as skills, para depois usar um ressurect,
    # porque ele tem um certo custo que não é de graça" (27/08).
    test "com a barra cheia, o controle abre a janela mas o revive NÃO sai" do
      logic = aberta(pilha(5))
      {logic, primeira} = Logic.step(logic, pilha(5), @r10, 200)
      assert "1" in primeira.opening, "o controle sai — a pilha é grande"

      {_logic, orders} = Logic.step(logic, pilha(5), @r10, 1_200)

      assert orders.revive == :hold
      refute orders.why =~ "dentro da janela"
    end
  end

  # R11 — CHEGAR PREPARADO NO PRÓXIMO GRUPO (27/08):
  #
  #   "é raro quando uso todas minhas skills realmente esperar cooldown, eu
  #   sempre uso um revive antes de matar o próximo grupo de monstros,
  #   normalmente dá bem certinho depois de matar um grupo usar um revive, mesmo
  #   que nem tenha acabado todos os cooldowns, pra já deixar preparado pro
  #   próximo grupo que logo vai aparecer na tela conforme andarmos"
  #
  # As outras regras de revive perguntam "acabou a barra?". Esta pergunta "a
  # barra está inteira?" — e entre as duas cabe a barra pela metade.
  describe "chegar preparado no próximo grupo" do
    @preparo Config.merge(%{
               prepare_revive: true,
               reset_revive_cooldown_ms: 3_000,
               gather_target: 1,
               bunch_ms: 0
             })

    defp limpo(overrides \\ %{}) do
      world(%{
        situation:
          situation(Map.merge(%{enemies: 0, prepared?: false, spent?: false}, overrides)),
        hunt: hunt(%{state: :walking})
      })
    end

    test "com a pilha limpa e a barra pela metade, ele revive andando" do
      {_logic, orders} = Logic.step(Logic.new(), limpo(), @preparo, 5_000)

      assert orders.revive == :prepare
      assert orders.route == :go, "o revive é de preparo: ele não para a rota pra isso"
      assert orders.why =~ "chegar inteiro"
    end

    # Ela se limita sozinha: o revive devolve a barra inteira, e a condição é
    # justamente a barra não estar inteira.
    test "com a barra inteira ele não gasta nada" do
      {_logic, orders} = Logic.step(Logic.new(), limpo(%{prepared?: true}), @preparo, 5_000)

      assert orders.revive == :hold
    end

    # A REGRA MUDOU EM 28/08, com a medição da noite: a tela dessa rota NUNCA
    # limpa (trem de 6-9 o tempo todo), e com o teto em zero o preparo disparou
    # 18 vezes contra 171 revives no meio do bolo. Na ESTRADA, um ou dois restos
    # perseguindo de longe são a tela limpa que existe — o teto é
    # `prepare_max_enemies`. Acima dele a regra volta a ser a do controle.
    test "na estrada, até dois restos na tela ainda é 'entre grupos'" do
      {_logic, orders} = Logic.step(Logic.new(), limpo(%{enemies: 2}), @preparo, 5_000)

      assert orders.revive == :prepare
      assert orders.why =~ "chegar inteiro"
    end

    test "três já é um grupo chegando — aí não vale" do
      {_logic, orders} = Logic.step(Logic.new(), limpo(%{enemies: 3}), @preparo, 5_000)

      refute orders.why =~ "chegar inteiro"
    end

    # No `engaged` o teto segue ZERO: os bichos dali estão EM CIMA do pokémon,
    # e recolher ele na frente deles é o oposto de chegar preparado.
    test "com a pilha em cima, um resto que seja já cala a regra" do
      mundo =
        world(%{
          situation: situation(%{enemies: 1, prepared?: false, spent?: false}),
          hunt: hunt(%{state: :fighting})
        })

      {_logic, orders} = Logic.step(Logic.new(), mundo, @preparo, 5_000)

      refute orders.why =~ "chegar inteiro"
    end

    # O ORÇAMENTO: com a conta na reserva, o preparo — que é conveniência —
    # para de gastar. Os últimos revives pertencem à emergência e ao caído.
    test "com o estoque na reserva, o preparo não gasta" do
      {_logic, orders} =
        Logic.step(Logic.new(), limpo(%{revive_left: 5}), @preparo, 5_000)

      assert orders.revive == :hold
    end

    test "com estoque sobrando (ou sem conta nenhuma), gasta como sempre" do
      {_logic, com_sobra} =
        Logic.step(Logic.new(), limpo(%{revive_left: 6}), @preparo, 5_000)

      assert com_sobra.revive == :prepare
    end

    test "sem leitura da barra ela não inventa: desconhecido não é 'gasta'" do
      {_logic, orders} = Logic.step(Logic.new(), limpo(%{prepared?: nil}), @preparo, 5_000)

      assert orders.revive == :hold
    end

    test "e o piso entre dois revives continua valendo" do
      {logic, primeira} = Logic.step(Logic.new(), limpo(), @preparo, 5_000)
      assert primeira.revive == :prepare

      {_logic, orders} = Logic.step(logic, limpo(), @preparo, 6_000)

      assert orders.revive == :hold, "1s depois do último revive, ainda não"
    end

    test "desligada, a caçada volta a só andar" do
      config = Config.merge(%{prepare_revive: false})

      {_logic, orders} = Logic.step(Logic.new(), limpo(), config, 5_000)

      assert orders.revive == :hold
    end
  end

  # R12 — A JANELA FECHOU; AGORA DEIXA ELES CHEGAREM (27/08):
  #
  #   "Notei três bichos, ele entra na janela de 'já tenho mob decente'. Se eu
  #   continuar andando mais um segundo, não aparecia mais um bicho, eu fecho
  #   essa janela de mob e mato eles com tudo que eu tiver. Só que, quando fecho
  #   uma janela de mob, eu tenho que aguardar, por exemplo, cinco segundos, pros
  #   bichos se aproximarem do meu pokémon."
  #
  # A régua sabia QUANDO parar de juntar e disparava no mesmo tique. Três bichos
  # recém-chegados à lista estão longe do pokémon, não em cima dele: a área pega
  # um e gasta o cooldown dos três.
  describe "a espera antes de estourar a área" do
    @espera Config.merge(%{
              bunch_ms: 2_000,
              bunch_walk_tiles: 0,
              gather_target: 1,
              gather_piles: false,
              engage_from: 2
            })

    defp pilha_pronta(n \\ 3) do
      world(%{
        situation: situation(%{enemies: n, worth_fighting?: true, stable_for_ms: 9_000}),
        hunt: hunt(%{state: :fighting})
      })
    end

    test "ao fechar a janela ele PARA e não atira" do
      {logic, orders} = Logic.step(Logic.new(), pilha_pronta(), @espera, 1_000)

      assert orders.phase == :bunching
      assert orders.fire == :hold
      assert orders.route == :hold, "parar é o que faz eles virem"
      assert logic.state == :bunching
      assert orders.why =~ "esperando eles fecharem em cima do pokémon"
    end

    test "passada a espera, aí sim estoura a área" do
      {logic, _} = Logic.step(Logic.new(), pilha_pronta(), @espera, 1_000)
      {logic, meio} = Logic.step(logic, pilha_pronta(), @espera, 2_500)

      assert meio.phase == :bunching, "1,5s ainda é dentro da janela"

      {_logic, depois} = Logic.step(logic, pilha_pronta(), @espera, 3_100)

      assert depois.phase == :engaged
      assert depois.fire == :free
      assert depois.opening != []
    end

    # Esperar por uma pilha que não existe mais é ficar parado de graça.
    test "se eles somem no meio da espera, ela acaba na hora" do
      {logic, _} = Logic.step(Logic.new(), pilha_pronta(), @espera, 1_000)

      {_logic, orders} = Logic.step(logic, pilha_pronta(0), @espera, 1_500)

      assert orders.phase == :travelling
      assert orders.why =~ "sumiram"
    end

    test "em zero ela não existe: abre disparando, como antes" do
      config = Config.merge(%{bunch_ms: 0, gather_piles: false, engage_from: 2})

      {_logic, orders} = Logic.step(Logic.new(), pilha_pronta(), config, 1_000)

      assert orders.phase == :engaged
      assert orders.fire == :free
    end
  end

  # O ALVO DO BOLO e OS PASSOS DA ESPERA — as duas metades do que ele descreveu
  # em 27/08 depois de rodar o bot:
  #
  #   "Quando encontra dois monstros, pode andar bastante até ter seis monstros.
  #   Se tiver cinco monstros na tela, pode andar um pouquinho e depois parar.
  #   Ele não precisa parar na hora que identificou isso: pode andar mais uns 5
  #   passos, porque aí os monstros que ele encontrou lá na frente já vão ter se
  #   enfiado um pouco mais no meio deles."
  describe "o bolo que vale parar" do
    @bolo Config.merge(%{
            gather_target: 6,
            gather_piles: true,
            engage_from: 2,
            bunch_walk_tiles: 5,
            bunch_ms: 6_000,
            patience_tiles: 50
          })

    defp juntando(quantos, andou) do
      world(%{
        situation:
          situation(%{
            enemies: quantos,
            worth_fighting?: true,
            walked: andou,
            stable_for_ms: 9_000
          }),
        hunt: hunt(%{state: :fighting})
      })
    end

    test "com dois na tela ele SEGUE andando, mesmo com os passos cumpridos" do
      {_logic, orders} = Logic.step(Logic.new(), juntando(2, 30), @bolo, 1_000)

      assert orders.phase == :gathering
      assert orders.route == :go
      assert orders.fire == :hold
    end

    test "chegando no alvo, a janela fecha" do
      {_logic, orders} = Logic.step(Logic.new(), juntando(6, 30), @bolo, 1_000)

      assert orders.phase == :bunching
    end

    # A paciência segue sendo o teto: um bolo que nunca enche não segura a
    # caçada pra sempre.
    test "…ou quando a paciência acaba, com o bolo pela metade" do
      curta = Config.merge(%{@bolo | patience_tiles: 10})

      {_logic, orders} = Logic.step(Logic.new(), juntando(3, 12), curta, 1_000)

      assert orders.phase in [:bunching, :engaged]
    end

    # "Estranhamente, ele está parando de andar": parar no instante em que a
    # janela fecha era o defeito.
    test "a espera ANDA os primeiros passos, de fogo segurado" do
      {logic, primeiro} = Logic.step(Logic.new(), juntando(6, 30), @bolo, 1_000)

      assert primeiro.route == :go, "ainda tem passo pra arrastar o bolo"
      assert primeiro.fire == :hold
      assert primeiro.why =~ "passo(s) pra puxar eles"

      # cinco passos depois, ela para
      {logic, parado} = Logic.step(logic, juntando(6, 35), @bolo, 2_000)
      assert parado.route == :hold
      assert parado.fire == :hold

      # e o relógio termina o serviço
      {_logic, fogo} = Logic.step(logic, juntando(6, 35), @bolo, 8_000)
      assert fogo.phase == :engaged
      assert fogo.fire == :free
    end
  end

  # A PORTA DO REVIVE SEM STUN, fechada em 27/08: "ele quase morreu porque não
  # tinha o stun de controle disponível para poder usar o revive de forma
  # segura, então ele usou o revive de forma insegura".
  # "Se não tiver livre, usar o que tem de cooldown e usa o revive, não perde
  # tempo fugindo (…) e NÃO recuar, continuar em frente batalhando!!!!" (28/08,
  # depois de 39 minutos de kite). A espera pelo controle morreu: a proteção
  # mora no executor desde #429 — com o controle frio ele escala o que sobrou,
  # com settle, e nunca recolhe nu.
  describe "o revive sem controle na frente" do
    # Régua declarada pelo mesmo motivo do bloco da R10: a pergunta aqui é o
    # revive sem controle, e uma pilha de quatro tem que VALER a luta pra ela
    # ser feita.
    @sem_stun Config.merge(%{
                reset_revive: true,
                crowd_from: 99,
                gather_target: 1,
                bunch_ms: 0,
                engage_from: 2
              })

    defp barra_vazia_sem_controle(volta_em \\ 2_000) do
      world(%{
        situation:
          situation(%{
            enemies: 4,
            spent?: true,
            prepared?: false,
            ready_keys: [],
            own_hp: 95,
            control_back_in_ms: volta_em
          }),
        hunt: hunt(%{state: :fighting}),
        hands: %{opening: ~w(3 4), small: [], single: [], crowd: ["1"]}
      })
    end

    test "com o controle voltando logo, o revive NÃO espera — sai já" do
      {logic, _} = Logic.step(Logic.new(), barra_vazia_sem_controle(), @sem_stun, 1_000)
      {_logic, orders} = Logic.step(logic, barra_vazia_sem_controle(), @sem_stun, 2_000)

      assert orders.revive == :now
      assert orders.route == :hold
    end

    test "com o controle longe, idem — parado esperando é o que ele proibiu" do
      longe = barra_vazia_sem_controle(38_000)

      {logic, _} = Logic.step(Logic.new(), longe, @sem_stun, 1_000)
      {_logic, orders} = Logic.step(logic, longe, @sem_stun, 2_000)

      assert orders.revive == :now
    end

    test "sem relógio nenhum, idem" do
      sem_relogio = barra_vazia_sem_controle(nil)

      {logic, _} = Logic.step(Logic.new(), sem_relogio, @sem_stun, 1_000)
      {_logic, orders} = Logic.step(logic, sem_relogio, @sem_stun, 2_000)

      assert orders.revive == :now
    end
  end
end
