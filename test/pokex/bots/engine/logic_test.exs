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

  # O TILE EM QUE ELE ESTÁ. Não é enfeite: é o quadro em que a cobertura do stun
  # é comparada (`Siege.covered?/3`), porque o olho mede a partir DELE e ele
  # anda. Um mundo sem coordenada não põe ninguém pra dormir.
  @here {100, 200, 7}

  # UM CONCEITO SÓ: `special?` é o shiny, acha-se por cor, por nome ou por grit.
  # Este arquivo usava `heavy?: true` pra dizer "o especial" e `special?: true` pra
  # dizer "o shiny da cor" — uma distinção que o jogo não tem (12/09).
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
        # a foto da barra EXISTE nestes quadros: `spent?`/`prepared?` acima
        # são leituras, e o reset é cobrado por imagem (01/09)
        bar_seen?: true,
        # a segunda metade da régua (R6): quantos passos já foram andados
        # puxando ESTA pilha, e o contador monotônico do qual ela sai
        walked: 0,
        walked_total: 0,
        pos: @here
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

  # A RÉGUA CORRE ANDANDO. Não existe mais "perna de mobada": o que decide se a
  # caçada anda ou para é a contagem do que está ao redor, e ela roda em todo
  # tique de estrada.
  describe "walking the route (green)" do
    test "nothing worth the area keeps the road moving, counting who arrives" do
      w = world(%{situation: situation(%{enemies: 1, worth_fighting?: false})})
      {logic, orders} = step(w, 1_000)

      assert logic.state in [:sizing, :gathering]
      assert orders.route == :go
      assert orders.fire == :hold
      assert orders.band == :green
    end

    test "a pile that is not full yet is gathered ON THE MOVE" do
      w = world()
      {logic, orders} = Logic.step(Logic.new(), w, gathering_config(), 1_000)

      assert logic.state == :gathering
      assert orders.route == :go
      assert orders.fire == :hold
      assert orders.why =~ "juntando"
    end

    test "a pile that IS full stops the road — no mark anywhere said so" do
      {_logic, orders} = step(world(), 1_000)

      assert orders.route == :hold
    end

    # "Ele ainda está parando em poucos monstros na tela, fora do que deveria
    # ser" (10/09, com `engage_from: 6` e `patience_tiles: 6` na tela dele).
    # `walked` conta tiles desde que a pilha APARECEU, e desde o #578 a régua
    # roda andando: seis passos de rota normal são ~1,9s, então a paciência
    # vencia antes de qualquer coisa e passava por cima do "para e luta a partir
    # de 6". Passo de paciência é passo de ARRASTO — e no Auto Combo, que não
    # junta pilha, não existe arrasto nenhum.
    test "patience does not fire on route steps when nothing is being dragged" do
      config = %{@config | patience_tiles: 6, engage_from: 6, gather_piles: false}

      w =
        world(%{
          situation:
            situation(%{enemies: 2, worth_fighting?: false, walked: 99, walked_total: 99})
        })

      {logic, orders} = Logic.step(Logic.new(), w, config, 1_000)

      assert orders.route == :go, "duas na tela com a régua em 6 não param a caçada"
      refute logic.state == :engaged
      refute orders.why =~ "paciência"
    end
  end

  # `gather_target` acima da contagem: a pilha ainda está enchendo, que é onde
  # a juntada vive. O `@config` do arquivo fecha a janela em 1 de propósito.
  defp gathering_config, do: %{@config | gather_target: 9, size_ceiling_ms: 60_000}

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

    # A paciência só vence sobre passo de ARRASTO, então o cérebro precisa ter
    # decidido arrastar esta pilha antes — é o que o primeiro tique faz.
    defp arrastando_e_cansado(w) do
      {logic, _} = Logic.step(Logic.new(), w, @config, 9_800)
      Logic.step(logic, w, @config, 10_000)
    end

    test "paciência esgotada num bicho bobo abre com UMA tecla" do
      {logic, orders} = arrastando_e_cansado(small_world(%{}))

      assert logic.state == :engaged
      assert orders.fire == :free
      assert orders.opening == ["3"]
    end

    test "a pilha que vale a área segue abrindo inteira" do
      {_logic, orders} =
        arrastando_e_cansado(
          small_world(%{enemies: 6, worth_fighting?: true, stable_for_ms: 9_999})
        )

      assert orders.opening == ~w(2 3 4)
    end

    test "sem mão pequena composta, o desconhecido abre inteiro (fail-open)" do
      w = small_world(%{})
      w = %{w | hands: Map.put(w.hands, :small, [])}
      {_logic, orders} = arrastando_e_cansado(w)

      assert orders.opening == ~w(2 3 4)
    end
  end

  # "Não deveria estar andando por aí se eu não tenho nenhum cooldown
  # disponível" (28/08, depois de o personagem morrer). Juntar seis bichos sem
  # barra pra matar nem revive pra comprá-la é escolher uma luta sem saída.
  describe "pilha só se abre com o que pagar" do
    test "barra gasta mas revive ao alcance: junta como sempre (R3b paga)" do
      w = world(%{situation: situation(%{spent?: true})})
      {logic, _orders} = Logic.step(Logic.new(), w, gathering_config(), 1_000)

      assert logic.state == :gathering
    end

    test "barra gasta e revive fora de alcance: não abre pilha, segue atirando" do
      w = world(%{situation: situation(%{spent?: true, revive_left: 0})})

      {logic, orders} = Logic.step(Logic.new(), w, gathering_config(), 1_000)

      assert logic.state == :skipping
      assert orders.route == :go
      assert orders.fire == :hold
      assert orders.why =~ "deixando essa pilha"
    end

    test "a barra esvaziando NO MEIO da régua larga a pilha, como o teto de tempo" do
      juntando = world()
      {logic, _orders} = Logic.step(Logic.new(), juntando, gathering_config(), 1_000)
      assert logic.state == :gathering

      esvaziou =
        world(%{
          situation:
            situation(%{enemies: 2, worth_fighting?: false, spent?: true, revive_left: 0})
        })

      {logic, orders} = Logic.step(logic, esvaziou, gathering_config(), 2_000)

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

    # O TETO NUMA PILHA QUE VALE ABRE. Até 02/09 pulava com "não vale a área"
    # — mentindo, porque valia — e era o que fazia subir a paciência ser
    # perigoso: passos a mais que estourassem o teto viravam pilha deixada.
    # Sem o piso de passos (02/09), quem segura a juntada é o alvo do bolo: a
    # pilha abaixo dele junta, e o teto é quem a abre.
    @juntando Config.merge(%{bunch_ms: 0, gather_target: 6})

    test "a pile worth fighting, past the ceiling, opens instead of being skipped" do
      worth =
        situation(%{
          enemies: 5,
          worth_fighting?: true,
          growing?: true,
          stable_for_ms: 0,
          walked: 2
        })

      w = world(%{situation: worth, hunt: hunt(%{state: :fighting})})

      {logic, _} = Logic.step(Logic.new(), w, @juntando, 1_000)
      {logic, orders} = Logic.step(logic, w, @juntando, 1_000 + @juntando.size_ceiling_ms)

      refute logic.state == :skipping
      assert orders.fire == :free
      assert orders.why =~ "teto"
    end

    test "a pile still walking in is gathered, not fired at" do
      arriving = situation(%{enemies: 4, growing?: true, stable_for_ms: 0, walked: 0})
      w = world(%{situation: arriving, hunt: hunt(%{state: :fighting})})

      {logic, orders} = Logic.step(Logic.new(), w, @juntando, 1_000)

      assert logic.state == :gathering
      assert orders.fire == :hold
      assert orders.why =~ "juntando"
    end

    test "a pile that stopped growing, but not for long enough, is still gathered" do
      settling = situation(%{stable_for_ms: 900, walked: 0})
      w = world(%{situation: settling, hunt: hunt(%{state: :fighting})})

      {logic, orders} = Logic.step(Logic.new(), w, @juntando, 1_000)

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
    # 47% de vida e a corrente recém-acabada: é o mundo do amarelo, e o sono
    # dela é o que deixa a rodada fechar com o revive (03/09).
    defp yellow(overrides \\ %{}) do
      world(%{
        situation: situation(Map.merge(%{own_hp: 47, combo_stun_age_ms: 500}, overrides)),
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

    # THE POCKET DOES NOT OPEN THE FIGHT. The reserve (single-target and control
    # keys the mode keeps out of the rotation) exists for the moment the area is
    # spent and the revive is held. Until 2026-09-07 it rode every "matando o que
    # já abriu" order, and that order is the one the hand reads one tick after
    # the fire edge: 7 of 28 openings that night went out as "6, 7, 8, 9, r".
    test "with the area whole, the hand after the opening is the opening alone" do
      pile =
        world(%{
          situation: situation(%{enemies: 2, combo_left_ms: 0, spent?: false, own_hp: 100}),
          hunt: hunt(%{state: :walking, luring?: true}),
          hands: %{opening: ["r"], single: ~w(7 8 9), crowd: [], reserve: ~w(7 8 9 1)}
        })

      {logic, opening} = until_fire(pile)
      {_logic, killing} = reset_step(logic, pile, 20_000)

      assert opening.opening == ["r"]
      assert killing.why =~ "matando o que já abriu"
      assert killing.opening == ["r"]
    end

    # Steps the brain on the same picture until the fire is released: the pile
    # is sized, gathered and blown on successive ticks.
    defp until_fire(pile) do
      Enum.reduce_while(1..10, {Logic.new(), nil}, fn i, {logic, _orders} ->
        case reset_step(logic, pile, 10_000 + i * 200) do
          {logic, %{fire: :free} = orders} -> {:halt, {logic, orders}}
          {logic, orders} -> {:cont, {logic, orders}}
        end
      end)
    end

    test "with the area spent and the revive held, the pocket opens" do
      spent =
        world(%{
          situation: situation(%{enemies: 2, combo_left_ms: 0, spent?: true, own_hp: 100}),
          hunt: hunt(%{state: :walking, luring?: true}),
          hands: %{opening: ["r"], single: ~w(7 8 9), crowd: [], reserve: ~w(7 8 9 1)}
        })

      {logic, _opening} = until_fire(spent)
      {_logic, holding} = reset_step(logic, spent, 20_000)

      assert holding.why =~ "segurando o revive"
      assert Enum.all?(~w(7 8 9 1), &(&1 in holding.opening))
    end

    # A CORRENTE DO JOGO SEGURA O REVIVE. No Auto Combo uma prensa encadeia as
    # skills, e o revive RECOLHE o pokémon: pedido no meio da corrente, ele
    # joga fora metade do dano que ela ia entregar — e a corrente termina em
    # controle, que é o sono que faz o revive valer a pena. "O mais cedo
    # possível logo DEPOIS do combo" (Lucas, 01/09).
    # Sem controle na mão o revive é a resposta direta — que é a mão do Auto
    # Combo: o stun é a última metade da corrente, não uma tecla nossa.
    defp sem_controle(overrides) do
      %{spent_fight(overrides) | hands: %{opening: ~w(3 4), single: [], crowd: []}}
    end

    # O primeiro tique ABRE a luta (a régua fecha a janela e estoura a área); o
    # revive é decisão do tique seguinte, já dentro do `:engaged`.
    defp lutando(mundo) do
      {logic, _abertura} = reset_step(Logic.new(), mundo, 10_000)
      {_logic, orders} = reset_step(logic, mundo, 10_500)
      orders
    end

    test "com a corrente saindo, o reset espera ela acabar" do
      assert lutando(sem_controle(%{combo_left_ms: 2_500, own_hp: 100})).revive == :hold
    end

    # …e agora sai no PRIMEIRO tique, antes da régua: é a regra dele escrita
    # como regra (`combo_reset_due?`), não a R3b caindo por acaso no segundo.
    test "acabada a corrente, o reset sai na hora" do
      mundo = sem_controle(%{combo_left_ms: 0, own_hp: 100})
      {logic, primeiro} = reset_step(Logic.new(), mundo, 10_000)
      {_logic, segundo} = reset_step(logic, mundo, 10_500)

      assert primeiro.revive == :now
      assert segundo.phase == :resetting
    end

    # O RESET É COBRADO POR IMAGEM (01/09): "temos que ter certeza de que os
    # cooldowns foram resetados antes de continuar a rota — se não tiver
    # recuperado, não podemos continuar". Depois do pedido, rota e fogo
    # seguram até a FOTO da barra dizer que ela voltou.
    # Dois tiques: o primeiro abre a luta, o segundo pede o revive.
    defp pedido(mundo) do
      {logic, _abertura} = reset_step(Logic.new(), mundo, 10_000)
      {logic, pedido} = reset_step(logic, mundo, 10_500)
      assert pedido.revive == :now
      logic
    end

    test "depois de pedir o revive, a rota e o fogo seguram até a barra voltar na tela" do
      logic = pedido(sem_controle(%{own_hp: 100}))

      ainda_gasta = sem_controle(%{own_hp: 100, spent?: true, bar_seen?: true})
      {_logic, espera} = reset_step(logic, ainda_gasta, 10_900)

      assert espera.phase == :resetting
      assert espera.route == :hold
      assert espera.fire == :hold
      # A frase diz O QUE ESTÁ FALTANDO: a foto chega (`bar_seen?`), os
      # cooldowns é que não voltaram. Dizer "a barra não voltou na tela" aqui
      # mandava recalibrar um leitor que está funcionando.
      assert espera.why =~ "a barra é lida, e os cooldowns ainda não voltaram nela"
      refute espera.why =~ "ilegível"
    end

    test "a barra de volta NA FOTO libera a rota no mesmo tique" do
      logic = pedido(sem_controle(%{own_hp: 100}))

      voltou = sem_controle(%{own_hp: 100, spent?: false, bar_seen?: true})
      {logic, livre} = reset_step(logic, voltou, 11_500)

      refute livre.phase == :resetting
      assert livre.fire == :free
      assert logic.reset_strikes == 0
      refute Map.has_key?(logic.since, :reset_pending)
    end

    # O relógio zerado diz "tudo pronto" pra quem não viu nada: sem foto, a
    # promessa fica em aberto — e a rota, segura.
    test "sem foto da barra, 'tudo pronto' pelo relógio NÃO cumpre a promessa" do
      logic = pedido(sem_controle(%{own_hp: 100}))

      cega = sem_controle(%{own_hp: 100, spent?: false, bar_seen?: false})
      {logic, espera} = reset_step(logic, cega, 11_500)

      assert espera.phase == :resetting
      assert espera.why =~ "ilegível"
      assert Map.has_key?(logic.since, :reset_pending)
    end

    # Cega até o prazo, a promessa fecha como INVERIFICÁVEL: nem cumprida
    # (não zera as quebras) nem quebrada (não conta strike por uma barra que
    # ninguém leu) — e a rota volta a andar.
    test "cega até o prazo, a promessa fecha sem strike e a rota volta" do
      logic = %{pedido(sem_controle(%{own_hp: 100})) | reset_strikes: 1}

      cega = sem_controle(%{own_hp: 100, spent?: false, bar_seen?: false})
      {logic, depois} = reset_step(logic, cega, 10_500 + 3_000 + 5_000 + 200)

      refute depois.phase == :resetting
      refute Map.has_key?(logic.since, :reset_pending)
      assert logic.reset_strikes == 1
    end

    # 18:37 de 02/09: a barra ilegível a caçada INTEIRA (o portão do leitor
    # recusava a barra recém-calibrada) e cada revive esperava os 8s do prazo
    # parado, por uma foto que nunca viria. Cega desde ANTES do pedido não há
    # o que esperar além do relógio: fecha em `revive_confirm_ms`, sem strike.
    test "cega desde antes do pedido, a promessa fecha em revive_confirm_ms — sem strike" do
      logic = %{pedido(sem_controle(%{own_hp: 100, bar_seen?: false})) | reset_strikes: 1}
      cega = sem_controle(%{own_hp: 100, spent?: false, bar_seen?: false})

      {logic, espera} = reset_step(logic, cega, 10_500 + 2_000)
      assert espera.phase == :resetting
      assert espera.why =~ "ilegível desde antes do pedido"

      {logic, depois} = reset_step(logic, cega, 10_500 + @reset.revive_confirm_ms + 200)
      refute depois.phase == :resetting
      refute Map.has_key?(logic.since, :reset_pending)
      assert logic.reset_strikes == 1
    end

    # Já a barra VISTA no pedido e sumida depois é o revive recolhendo o
    # pokémon (a janela muda de forma): aí sim se espera o prazo inteiro.
    test "a barra vista no pedido e sumida depois é o revive recolhendo: espera o prazo" do
      logic = pedido(sem_controle(%{own_hp: 100, bar_seen?: true}))
      sumiu = sem_controle(%{own_hp: 100, spent?: false, bar_seen?: false})

      {logic, espera} = reset_step(logic, sumiu, 10_500 + @reset.revive_confirm_ms + 200)
      assert espera.phase == :resetting
      assert espera.why =~ "sumiu depois do pedido"
      assert Map.has_key?(logic.since, :reset_pending)
    end

    # O CHEFE NÃO ESPERA: o ciclo dele (stun na emenda, F4 a cada 5s) é mais
    # curto que o prazo da promessa, e segurá-lo era acordar o especial com o
    # controle na mão.
    test "with the special on screen the promise holds nothing back" do
      logic = pedido(sem_controle(%{own_hp: 100}))

      especial = sem_controle(%{own_hp: 100, spent?: true, bar_seen?: true, special?: true})
      {_logic, ordens} = reset_step(logic, especial, 10_900)

      refute ordens.phase == :resetting
      assert ordens.fire == :free
    end

    # 19:15:51 e 19:12:36 de 11/09: o cérebro pediu o revive por UM tique e o
    # suporte, que lê a ordem no tique dele (120 ms, mais a foto), não a viu —
    # e o cérebro ficou "revive pedido há Ns" esperando um F4 que nunca saiu,
    # com o personagem dele a 14 %. A ordem é um NÍVEL até alguém a tomar.
    test "the revive order stays :now until the support notes the dispatch" do
      logic = pedido(sem_controle(%{own_hp: 100}))
      espera = sem_controle(%{own_hp: 100, spent?: true, bar_seen?: true})

      {logic, again} = reset_step(logic, espera, 10_700)
      assert again.revive == :now
      assert again.phase == :resetting
      assert again.route == :hold

      taken = sem_controle(%{own_hp: 100, spent?: true, bar_seen?: true, rescue_noted_at: 10_800})
      {logic, held} = reset_step(logic, taken, 10_900)
      assert held.revive == :hold
      assert held.phase == :resetting

      # …and never forever: past the window an untaken order is the promise's
      # problem, not a key held down against a support that refuses
      {_logic, gave_up} = reset_step(logic, espera, 10_500 + 1_600)
      assert gave_up.revive == :hold
      assert gave_up.phase == :resetting
    end

    # A REGRA DELE, como regra: "logo depois do combo estar finalizado, usar o
    # revive". O caso exato de 09:14:16 de 02/09 — a corrente matou o grupo, a
    # caçada já estava JUNTANDO o próximo, e nenhuma regra de revive era
    # consultada nessa fase.
    test "corrente acabada e barra gasta reviveM mesmo com a caçada juntando o próximo grupo" do
      juntando =
        world(%{
          situation:
            situation(%{
              enemies: 1,
              combo_left_ms: 0,
              combo_stun_age_ms: 500,
              spent?: true,
              own_hp: 100
            }),
          hunt: hunt(%{state: :walking, luring?: true}),
          hands: %{opening: ["r"], single: [], crowd: []}
        })

      {logic, primeiro} = reset_step(Logic.new(), juntando, 10_000)
      {logic, pedido} = reset_step(logic, juntando, 10_500)

      assert :now in [primeiro.revive, pedido.revive]
      assert Map.has_key?(logic.since, :reset_pending)
    end

    test "com a corrente ainda saindo, o revive espera a janela" do
      no_meio =
        world(%{
          situation: situation(%{enemies: 1, combo_left_ms: 1_500, spent?: true, own_hp: 100}),
          hunt: hunt(%{state: :walking, luring?: true}),
          hands: %{opening: ["r"], single: [], crowd: []}
        })

      {logic, a} = reset_step(Logic.new(), no_meio, 10_000)
      {_logic, b} = reset_step(logic, no_meio, 10_500)

      refute :now in [a.revive, b.revive]
    end

    # O contador de milissegundos na frase derrotava TODO dedup do caminho: o do
    # feed (`Narration.decision/3` compara `why` por igualdade) e o do diário
    # (`Engine.Worker.changed_mind?/2`, idem). Na noite de 09/09 isso deu 6787
    # registros em 2842 frases diferentes — 54,4% do diário inteiro — para 421
    # correntes. A frase é a mesma decisão os dois tiques; o quanto falta é do
    # relógio, não da razão.
    test "the chain's sentence is one sentence, not one per tick" do
      chain = fn left ->
        world(%{
          situation: situation(%{enemies: 1, combo_left_ms: left, spent?: true, own_hp: 100}),
          hunt: hunt(%{state: :walking}),
          hands: %{opening: ["r"], single: [], crowd: []}
        })
      end

      {logic, cedo} = reset_step(Logic.new(), chain.(2_400), 10_000)
      {_logic, tarde} = reset_step(logic, chain.(200), 10_500)

      assert cedo.why == tarde.why
      refute cedo.why =~ "ms"
    end

    # A CAPTURA NUNCA ACONTECIA NA CAÇADA. O Catcher é movido a evento, e o
    # evento que ele tinha (`{:kill}` do Combat) significa "a lista de batalha
    # ZEROU" — no Auto Combo a tela dele quase nunca zera: 5 desses no diário de
    # 09/09 inteiro, contra 299 aberturas de luta. Ele mesmo notou que
    # funcionava pescando, onde é um peixe por vez.
    #
    # A chamada é a BORDA em que a rodada fecha (a pilha morreu e o revive foi
    # confirmado), que é o instante que ele descreveu: "logo depois de matar e
    # usar o revive, a próxima ação vai ser capturar os pokémons ao redor".
    test "the round closing calls for the ball, once" do
      pedindo =
        world(%{
          situation:
            situation(%{
              enemies: 1,
              combo_left_ms: 0,
              combo_stun_age_ms: 500,
              spent?: true,
              own_hp: 100
            }),
          hunt: hunt(%{state: :walking}),
          hands: %{opening: ["r"], single: [], crowd: []}
        })

      {logic, pedido} = reset_step(Logic.new(), pedindo, 10_000)
      assert pedido.revive == :now
      assert pedido.capture == :none, "a bola não é chamada no PEDIDO do revive"
      assert Map.has_key?(logic.since, :reset_pending)

      # a barra volta cheia e o pokémon está em campo: o juiz encerra o caso
      # (…e há um Catcher armado pra jogar — sem ele a rota não espera ninguém)
      voltou =
        world(%{
          situation:
            situation(%{
              enemies: 0,
              combo_left_ms: 0,
              spent?: false,
              own_out?: true,
              own_hp: 100,
              catcher_armed?: true
            }),
          hunt: hunt(%{state: :walking}),
          hands: %{opening: ["r"], single: [], crowd: []}
        })

      {logic, fechou} = reset_step(logic, voltou, 10_600)
      assert fechou.capture == :now, "a rodada fechou: é a hora da bola"
      refute Map.has_key?(logic.since, :reset_pending)

      # …E A ESTRADA FICA PARADA PRA OLHAR. A chamada saía com `route: :go` no
      # mesmo tique (a espera do revive acabou), e o Catcher, que só varre com a
      # estrada segurada, achava a estrada andando: 390 das 398 chamadas de
      # 10/09 com a varredura fechada tinham o cérebro em 0 inimigos e rota :go.
      assert fechou.route == :hold, "a hora da bola precisa de um chão parado pra olhar"
      assert fechou.phase == :capturing
      assert fechou.why =~ "olhar o chão"

      {logic, depois} = reset_step(logic, voltou, 10_800)
      assert depois.capture == :none, "uma vez por rodada, não a cada tique"
      assert depois.route == :hold, "a janela de olhar dura mais que um tique"

      # sem nenhum corpo achado (o fato `:capture` nunca disse pendente), a
      # janela fecha sozinha e a rota volta a andar
      {_logic, soltou} = reset_step(logic, voltou, 12_800)
      assert soltou.route == :go
      refute soltou.phase == :capturing
    end

    # SEM NINGUÉM PRA JOGAR, parar pra olhar é só parar: a bancada não tem
    # Catcher, e as promessas dela (modo hard: ele não morre) não podem pagar
    # uma janela que no simulador nunca vira bola.
    test "with no catcher armed, the closing round calls the ball but walks" do
      pedindo =
        world(%{
          situation:
            situation(%{
              enemies: 1,
              combo_left_ms: 0,
              combo_stun_age_ms: 500,
              spent?: true,
              own_hp: 100
            }),
          hunt: hunt(%{state: :walking}),
          hands: %{opening: ["r"], single: [], crowd: []}
        })

      {logic, _pedido} = reset_step(Logic.new(), pedindo, 10_000)

      voltou =
        world(%{
          situation:
            situation(%{enemies: 0, combo_left_ms: 0, spent?: false, own_out?: true, own_hp: 100}),
          hunt: hunt(%{state: :walking}),
          hands: %{opening: ["r"], single: [], crowd: []}
        })

      {_logic, fechou} = reset_step(logic, voltou, 10_600)
      assert fechou.capture == :now
      assert fechou.route == :go
    end

    # Fora do Auto Combo `combo_left_ms` é nil, e nil não é "acabou agora".
    test "sem corrente nenhuma a regra não existe" do
      economico =
        world(%{
          situation: situation(%{enemies: 1, combo_left_ms: nil, spent?: true, own_hp: 100}),
          hunt: hunt(%{state: :walking, luring?: true}),
          hands: %{opening: ["3"], single: [], crowd: []}
        })

      {logic, a} = reset_step(Logic.new(), economico, 10_000)
      {_logic, b} = reset_step(logic, economico, 10_500)

      refute :now in [a.revive, b.revive]
    end

    test "o pedido segura a rota, e o tique seguinte espera a barra na tela" do
      juntando =
        world(%{
          situation:
            situation(%{
              enemies: 1,
              combo_left_ms: 0,
              combo_stun_age_ms: 500,
              spent?: true,
              own_hp: 100
            }),
          hunt: hunt(%{state: :walking, luring?: true}),
          hands: %{opening: ["r"], single: [], crowd: []}
        })

      {logic, pedido} = reset_step(Logic.new(), juntando, 10_000)
      assert pedido.revive == :now
      assert pedido.route == :hold

      {_logic, espera} = reset_step(logic, juntando, 10_400)
      assert espera.phase == :resetting
      assert espera.route == :hold
    end

    # PASSO 3-4 DO CICLO DELE: enquanto a corrente sai, o cérebro inteiro para.
    # "Ele não pode sair andando" — andar na janela chama bicho novo pra cima
    # de um revive que vem em segundos. Na noite de 02/09 o "pilha limpa —
    # seguindo a rota" saía DENTRO da janela, e o F4 caía já andando.
    test "com a corrente saindo, a rota para — mesmo com a caçada andando ou juntando" do
      for hunt <- [hunt(%{state: :walking}), hunt(%{state: :walking, luring?: true})] do
        mundo =
          world(%{
            situation: situation(%{enemies: 0, combo_left_ms: 2_500, spent?: true, own_hp: 100}),
            hunt: hunt,
            hands: %{opening: ["r"], single: [], crowd: []}
          })

        {logic, ordens} = reset_step(Logic.new(), mundo, 10_000)

        assert ordens.route == :hold
        assert ordens.fire == :free
        assert ordens.why =~ "corrente saindo"
        assert logic.state == :engaged
      end
    end

    # …abaixo do VERMELHO de propósito: o chão de segurança nunca espera a
    # corrente.
    test "vermelho no meio da corrente ainda revive" do
      mundo =
        world(%{
          situation: situation(%{enemies: 3, combo_left_ms: 2_500, spent?: true, own_hp: 20}),
          hunt: hunt(%{state: :fighting}),
          hands: %{opening: ["r"], single: [], crowd: []}
        })

      {_logic, ordens} = reset_step(Logic.new(), mundo, 10_000)

      assert ordens.revive == :now
      assert ordens.phase == :emergency
    end

    # O CICLO INTEIRO, como ele descreveu: corrente → parado → acabou → revive →
    # barra de volta na foto → sobrou bicho: corrente de novo; sobrou nada: anda.
    test "o ciclo fecha: corrente, revive, foto, e a corrente de novo se sobrou bicho" do
      mundo = fn overrides ->
        world(%{
          situation:
            situation(
              Map.merge(
                %{combo_left_ms: 0, combo_stun_age_ms: 500, spent?: true, own_hp: 100},
                overrides
              )
            ),
          hunt: hunt(%{state: :fighting}),
          hands: %{opening: ["r"], single: [], crowd: []}
        })
      end

      {logic, saindo} =
        reset_step(Logic.new(), mundo.(%{enemies: 5, combo_left_ms: 2_000}), 10_000)

      assert saindo.route == :hold

      {logic, pedido} = reset_step(logic, mundo.(%{enemies: 2}), 12_100)
      assert pedido.revive == :now

      {logic, espera} = reset_step(logic, mundo.(%{enemies: 2, bar_seen?: true}), 12_500)
      assert espera.phase == :resetting
      assert espera.route == :hold

      {logic, de_novo} =
        reset_step(logic, mundo.(%{enemies: 2, spent?: false, bar_seen?: true}), 13_500)

      assert de_novo.fire == :free
      assert de_novo.route == :hold
      assert "r" in de_novo.opening

      {_logic, andando} =
        reset_step(logic, mundo.(%{enemies: 0, spent?: false, bar_seen?: true}), 14_000)

      assert andando.route == :go
    end

    # Sem combo nenhum (todo modo que não é o Auto Combo) a regra não existe:
    # `nil` é ausência, não uma corrente de duração zero.
    test "sem corrente, nada muda" do
      assert lutando(sem_controle(%{combo_left_ms: nil, own_hp: 100})).revive == :now
    end

    # A BARRA GASTA É O MUNDO LOGO DEPOIS DA CORRENTE — é ela que gasta a barra,
    # e é ela que termina em controle. Por isso o mundo padrão daqui carrega o
    # sono fresco (`combo_stun_age_ms`): sem ele, desde 03/09, o revive de
    # conveniência não recolhe o pokémon com bicho acordado na tela.
    defp spent_fight(overrides \\ %{}) do
      world(%{
        situation:
          situation(
            Map.merge(
              %{enemies: 4, spent?: true, own_hp: 100, combo_stun_age_ms: 500},
              overrides
            )
          ),
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

    # A TRAVA QUE ELE PEDIU (26/08) mudou de gatilho em 29/08: UMA promessa
    # quebrada é quase sempre um F4 que o jogo engoliu, e a resposta é apertar
    # de novo (ver os testes de reincidência). O desarme continua existindo —
    # três sem efeito — e continua com prazo, não perpétuo.
    test "desarmada na terceira, a regra volta pro jogo depois do prazo" do
      logic = engaged(&reset_step/3)

      {logic, quando} =
        Enum.reduce(1..3, {logic, 2_000}, fn _n, {logic, at} ->
          {logic, _} = reset_step(logic, spent_fight(), at)
          {logic, _} = reset_step(logic, spent_fight(), at + 500)
          quebrou = at + 500 + @reset.reset_revive_cooldown_ms + 10_000
          {logic, _} = reset_step(logic, spent_fight(), quebrou)
          {logic, quebrou + 500}
        end)

      assert is_integer(logic.reset_broken_at)

      # passado o prazo do rearme, a regra volta pro jogo
      rearmado = quando + @reset.reset_rearm_ms + 1_000
      {logic, _} = reset_step(logic, spent_fight(%{spent?: false}), rearmado)
      assert logic.reset_broken_at == nil

      {_logic, de_novo} = com_controle(logic, spent_fight(), rearmado + 1_000)
      assert de_novo.revive == :now
    end

    # A REINCIDÊNCIA, na leitura DELE (29/08): "se usou revive e não recuperou
    # cooldown/vida, quer dizer que NÃO SAIU de verdade — pode só usar de novo
    # (…) para de correr!". O jogo engole ~9% dos F4 (28 de 319 na corrida de
    # 3h), e cada engolida desarmava a R3b por 600s: com a barra vazia e o
    # reset preso, o bot passava reto pela tela cheia — 77 pilhas puladas.
    # Fugir é o perigo ("numa hunt difícil chama mais bicho ainda"), então a
    # quebra REAPERTA: a regra fica armada e o F4 sai de novo. Só a TERCEIRA
    # seguida desarma — três revives sem efeito nenhum é estoque zerado, e aí
    # andar é a resposta certa.
    test "a quebra REAPERTA: o F4 sai de novo em vez de fugir" do
      logic = engaged(&reset_step/3)
      {logic, _} = com_controle(logic, spent_fight(), 2_000)

      quebrou = 2_000 + @reset.reset_revive_cooldown_ms + 10_000
      {logic, depois} = reset_step(logic, spent_fight(), quebrou)

      assert logic.reset_strikes == 1
      assert logic.reset_broken_at == nil, "uma engolida não desarma nada"
      refute depois.why =~ "recuando", "e ninguém sai correndo"

      # o tique seguinte já pede o revive de novo (controle primeiro ou direto)
      {logic, tick1} = reset_step(logic, spent_fight(), quebrou + 300)
      {_logic, tick2} = reset_step(logic, spent_fight(), quebrou + 800)
      assert :now in [tick1.revive, tick2.revive], "reapertou em vez de correr"
    end

    test "só a TERCEIRA quebra seguida desarma — e o porquê fala em estoque" do
      logic = engaged(&reset_step/3)

      # três promessas quebradas em sequência
      {logic, quando} =
        Enum.reduce(1..3, {logic, 2_000}, fn _n, {logic, at} ->
          {logic, tick1} = reset_step(logic, spent_fight(), at)
          {logic, tick2} = reset_step(logic, spent_fight(), at + 500)
          assert :now in [tick1.revive, tick2.revive]

          quebrou = at + 500 + @reset.reset_revive_cooldown_ms + 10_000
          {logic, _} = reset_step(logic, spent_fight(), quebrou)
          {logic, quebrou + 500}
        end)

      assert logic.reset_strikes == 3
      assert is_integer(logic.reset_broken_at), "três sem efeito = estoque, aí sim sai de cena"

      {logic, mudo} = reset_step(logic, spent_fight(), quando + 2_000)
      assert mudo.revive == :hold
      assert mudo.why =~ "ESTOQUE"

      # e só o prazo LONGO rearma
      {logic, _} = reset_step(logic, spent_fight(), quando + @reset.reset_rearm_ms + 2_000)
      assert logic.reset_broken_at == nil
    end

    test "uma promessa CUMPRIDA zera a reincidência" do
      logic = engaged(&reset_step/3)

      # quebra uma…
      {logic, _} = com_controle(logic, spent_fight(), 2_000)
      quebrou = 2_000 + @reset.reset_revive_cooldown_ms + 10_000
      {logic, _} = reset_step(logic, spent_fight(), quebrou)
      assert logic.reset_strikes == 1

      # …reaperta e desta vez a barra VOLTA
      {logic, _} = reset_step(logic, spent_fight(), quebrou + 300)
      {logic, _} = reset_step(logic, spent_fight(), quebrou + 800)
      {logic, _} = reset_step(logic, spent_fight(%{spent?: false}), quebrou + 2_500)
      assert logic.reset_strikes == 0
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
      # prefixo. Sem `crowd` nas mãos não há prefixo a esperar — e quem dá a
      # licença de recolher é o sono que a corrente acabou de deixar (03/09).
      sem_controle =
        world(%{
          situation: situation(%{enemies: 4, spent?: true, own_hp: 100, combo_stun_age_ms: 500}),
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

    # A barra volta; o shiny não. E o shiny É o especial deste jogo, então quem
    # cala a R7 é o mesmo `special?` — uma guarda, não duas.
    test "mas do ESPECIAL ela não recua — a barra volta, o shiny não" do
      com_especial =
        world(%{
          situation: situation(%{enemies: 3, spent?: true, walked_total: 0, special?: true}),
          hunt: hunt(%{state: :fighting})
        })

      {logic, _} = fuga_step(com_especial, 0)
      {_logic, orders} = fuga_step(logic, com_especial, 200)

      refute orders.why =~ "recuando", "recuou de um shiny: #{orders.why}"
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

      # a luta termina de verdade: tela limpa (o pisão do trecho de mob que
      # encerrava lutas vivas morreu com o flip — ver "a mobada FECHA")
      {logic, _} =
        fuga_step(
          logic,
          world(%{situation: situation(%{enemies: 0}), hunt: hunt(%{state: :walking})}),
          6_000
        )

      {logic, _} = fuga_step(logic, sem_cooldown(0), 7_000)
      {_logic, orders} = fuga_step(logic, sem_cooldown(0), 7_200)

      assert orders.route == :back
    end
  end

  # A SEGUNDA PROVA DE CAMPO VAZIO, e a que realmente dispara.
  #
  # `own_out? == false` exige a Pokebar ilegível por duas leituras seguidas, e
  # desde 09/09 isso não acontece: cinco dias, ZERO leituras `false`, e a fase
  # `downed` só existiu em 08/09. A janela de batalha responde a mesma pergunta
  # por outro fio e responde bem — 97,1% das decisões de 12/09 acham a linha do
  # pokémon dele pelo nome desenhado.
  describe "a linha dele saiu da janela de batalha" do
    defp na_lista(overrides \\ %{}) do
      world(%{
        situation:
          situation(Map.merge(%{own_row_seen?: :by_name, rows: 3, enemies: 2}, overrides)),
        hunt: hunt(%{state: :fighting})
      })
    end

    defp sumiu(overrides \\ %{}),
      do: na_lista(Map.merge(%{own_row_seen?: :absent, rows: 2, enemies: 2}, overrides))

    test "gone from the list with the pokemon standing turns the hunt downed" do
      {logic, _} = step(na_lista(), 1_000)
      {_logic, orders} = step(logic, sumiu(), 1_200)

      assert orders.phase == :downed
      assert orders.why =~ "sem pokémon em campo"
    end

    test "and the revive goes out when he does not come back" do
      {logic, _} = step(na_lista(), 1_000)
      {logic, primeiro} = step(logic, sumiu(), 1_200)
      {_logic, orders} = step(logic, sumiu(), 1_200 + @config.revive_confirm_ms)

      # a carência do `downed/1` continua valendo: o motivo ordinário de estar
      # fora é um revive em voo
      assert primeiro.revive == :hold
      assert orders.revive == :now
    end

    # SEM A TRAVA NÃO HÁ AFIRMAÇÃO. Um cliente que nunca listou a linha dele
    # (o mundo simulado, `own_row?: false`) diria `:absent` a corrida inteira, e
    # "nunca esteve" não é "saiu de campo".
    test "but not before this client has shown his row at least once" do
      {_logic, orders} = step(sumiu(), 1_000)

      refute orders.phase == :downed
    end

    # A tela vazia e a Pokebar ilegível continuam sem provar nada: as duas
    # devolvem `false`, não `:absent`.
    test "and an empty screen is not a pokemon off the field" do
      {logic, _} = step(na_lista(), 1_000)

      {_logic, orders} =
        step(logic, na_lista(%{own_row_seen?: false, rows: 0, enemies: 0}), 1_200)

      refute orders.phase == :downed
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
  # "Só 8 conseguem ficar ao redor do meu pokémon — os outros podem ficar longe
  # e fazer eu morrer durante o revive. Nesse caso não dá pra usar o auto-combo
  # e sair correndo, vai piorar a situação; o ideal é arriscar o quanto antes"
  # (02/09).
  describe "mais bicho do que cabe ao redor" do
    # Sem reset possível a barra vazia cai na retirada (R7) — que é o que este
    # bloco isola: `reset_revive: false` tira a R3b do caminho.
    @sem_reset Config.merge(%{reset_revive: false, engage_from: 2, bunch_ms: 0, gather_target: 1})

    defp pilha_com_barra(enemies, spent?) do
      world(%{
        situation: situation(%{enemies: enemies, spent?: spent?, worth_fighting?: true}),
        hunt: hunt(%{state: :fighting})
      })
    end

    # A luta ABRE com barra e só depois ela esvazia: uma pilha encontrada já sem
    # barra nem é aberta (a régua a deixa pra trás), e a retirada é regra de
    # luta aberta.
    defp luta_aberta_sem_barra(enemies, config) do
      {logic, _} = Logic.step(Logic.new(), pilha_com_barra(enemies, false), config, 1_000)
      {logic, _} = Logic.step(logic, pilha_com_barra(enemies, true), config, 1_200)
      Logic.step(logic, pilha_com_barra(enemies, true), config, 1_400)
    end

    test "com 4 em cima e a barra vazia, recua (R7 como sempre)" do
      {_logic, orders} = luta_aberta_sem_barra(4, @sem_reset)

      assert orders.route == :back
    end

    # Com 9 e um revive a dar, a resposta é o revive — antes de qualquer
    # retirada. Sem revive nenhum (reset desligado), a retirada é a única
    # saída, com 4 ou com 9: parado numa nuvem que não morre é a noite inteira
    # no mesmo canto.
    test "com 9 em cima e o reset possível, revive em vez de recuar" do
      com_reset = Config.merge(%{engage_from: 2, bunch_ms: 0, gather_target: 1})
      {_logic, orders} = luta_aberta_sem_barra(9, com_reset)

      refute orders.route == :back, orders.why
      assert orders.revive == :now, orders.why
    end

    test "sem revive nenhum a dar, com 9 recua como com 4 — é a única saída" do
      {_logic, orders} = luta_aberta_sem_barra(9, @sem_reset)

      assert orders.route == :back, orders.why
    end

    # O amarelo "esperando a pilha fechar" espera quem nunca vai fechar: os de
    # fora não cabem. Com 9+ a rodada não espera.
    test "no amarelo com 9 em cima não espera a pilha fechar" do
      amarelo =
        world(%{
          situation:
            situation(%{enemies: 9, own_hp: 45, stable_for_ms: 0, growing?: true, spent?: false}),
          hunt: hunt(%{state: :fighting})
        })

      {_logic, orders} = Logic.step(Logic.new(), amarelo, @sem_reset, 1_000)

      refute orders.why =~ "esperando a pilha fechar"
      assert orders.fire == :free
    end
  end

  # Dez minutos recuando é pior que arriscar: com o reset DESARMADO a barra
  # vazia luta parada com o que volta — o r solta as de alvo único também.
  describe "o reset desarmado" do
    test "não recua: luta parado, e diz por quê" do
      desarmado = %{Logic.new() | reset_broken_at: 500}
      config = Config.merge(%{engage_from: 2, bunch_ms: 0, gather_target: 1})

      com_barra =
        world(%{
          situation: situation(%{enemies: 4, spent?: false, worth_fighting?: true}),
          hunt: hunt(%{state: :fighting})
        })

      sem_barra = put_in(com_barra.situation.spent?, true)

      {logic, _} = Logic.step(desarmado, com_barra, config, 1_000)
      {logic, _} = Logic.step(logic, sem_barra, config, 1_200)
      {_logic, orders} = Logic.step(logic, sem_barra, config, 1_400)

      refute orders.route == :back
      assert orders.fire == :free
      assert orders.why =~ "DESARMADO"
      assert orders.why =~ "alvo único"
    end
  end

  # A VIDA DELE. "Esse período de menos de 1s que o revive me deixa exposto eu
  # já tomo um jato de água na cara e morro" — e quem está fora do alcance do
  # pokémon bate nele o tempo todo.
  #
  # A REGRA VIROU DE LADO EM 03/09, e a inversão tem data porque tem morte. Até
  # ali este bloco dizia "com a barra gasta, revive na hora, antes até de a
  # corrente acabar" — a aposta de 02/09, "arriscar o quanto antes". Ela nunca
  # rodou uma vez: o cérebro lia a vida do POKÉMON no lugar da dele. Quando o
  # campo certo chegou, a aposta se mostrou do lado errado — o revive RECOLHE o
  # pokémon, e o pokémon de pé é a única coisa entre ele e a mobada. "Um revive
  # desesperado faz ele morrer, se tá no meio de um monte de monstro" (03/09).
  describe "o personagem apanhando" do
    defp sangrando(player_hp, extra) do
      world(%{
        situation:
          situation(
            Map.merge(
              %{enemies: 9, spent?: true, own_out?: true, player_hp: player_hp, player_drop: 0},
              extra
            )
          ),
        hunt: hunt(%{state: :fighting})
      })
    end

    # NOVE BICHOS NA TELA: recolher o pokémon aqui é a morte de 12:32 outra vez.
    test "abaixo do piso e com a mobada em cima, o revive NÃO sai" do
      {_logic, orders} =
        Logic.step(
          Logic.new(),
          sangrando(40, %{player_drop: 3, combo_left_ms: 2_000}),
          @config,
          1_000
        )

      assert orders.revive == :hold, orders.why
    end

    # …e com a tela limpa a aposta dele continua inteira: não há de quem
    # apanhar durante a recolhida, então a barra cheia é pura vantagem.
    test "abaixo do piso com a tela limpa, revive agora como sempre" do
      {_logic, orders} =
        Logic.step(
          Logic.new(),
          sangrando(40, %{player_drop: 3, enemies: 0, combo_left_ms: 2_000}),
          @config,
          1_000
        )

      assert orders.revive == :now, orders.why
      assert orders.why =~ "VOCÊ está apanhando"
    end

    test "uma queda de dez pontos entre duas fotos também é sangrar" do
      {_logic, orders} =
        Logic.step(
          Logic.new(),
          sangrando(80, %{player_drop: 12, enemies: 0, combo_left_ms: 2_000}),
          @config,
          1_000
        )

      assert orders.revive == :now
    end

    test "com a vida dele inteira, a corrente segue sem revive" do
      {_logic, orders} =
        Logic.step(Logic.new(), sangrando(95, %{combo_left_ms: 2_000}), @config, 1_000)

      assert orders.revive == :hold
      assert orders.why =~ "corrente saindo"
    end

    test "sem leitura da vida dele, nada muda" do
      {_logic, orders} =
        Logic.step(Logic.new(), sangrando(nil, %{combo_left_ms: 2_000}), @config, 1_000)

      assert orders.revive == :hold
    end
  end

  # "Quando não consegue matar 1 pokémon com um combo, sobra 1, ele sai correndo
  # tentando mobar (…) quando tem 1 shiny ali é normal precisar do loop de 3~4
  # combos de revive até matar." Quem tomou a área inteira e ficou de pé vale a
  # luta, sem nome e sem cor.
  describe "o sobrevivente da corrente" do
    defp corrente(left_ms, enemies, extra \\ %{}) do
      world(%{
        situation:
          situation(
            Map.merge(
              %{
                enemies: enemies,
                worth_fighting?: false,
                combo_left_ms: left_ms,
                combo_stun_age_ms: if(left_ms > 0, do: 0, else: 500),
                spent?: false
              },
              extra
            )
          ),
        hunt: hunt(%{state: :fighting})
      })
    end

    # a corrente sai (2 tiques), acaba com 1 na tela, e o revive de reset volta a barra
    defp depois_da_corrente(logic \\ Logic.new(), enemies \\ 1) do
      {logic, _} = Logic.step(logic, corrente(3_000, 6), @config, 1_000)
      {logic, _} = Logic.step(logic, corrente(1_000, 6), @config, 1_200)
      {logic, fim} = Logic.step(logic, corrente(0, enemies, %{spent?: true}), @config, 1_400)
      {logic, fim}
    end

    test "sobrou um: o reset diz que é sobrevivente, e a luta continua em cima dele" do
      {logic, fim} = depois_da_corrente()
      assert fim.revive == :now
      assert fim.why =~ "sobrevivente da corrente (1 de 6)"

      # a barra voltou NA TELA: a promessa fecha e a luta segue, parada, batendo
      lido = corrente(0, 1, %{spent?: false, bar_seen?: true, own_out?: true})
      {_logic, orders} = Logic.step(logic, lido, @config, 5_000)

      assert orders.route == :hold, orders.why
      assert orders.fire == :free, orders.why
    end

    # A LISTA PISCA: a linha do sobrevivente some um tique e volta. Um tique
    # vazio fecha a rodada (a luta vira estrada), e no tique seguinte a régua
    # veria "só 1: não vale" — o latch é o que faz ela abrir de novo em cima.
    test "a lista piscando não solta o latch: no tique seguinte a régua abre de novo em cima" do
      {logic, _} = depois_da_corrente()
      lido = %{spent?: false, bar_seen?: true, own_out?: true}
      {logic, _} = Logic.step(logic, corrente(0, 1, lido), @config, 5_000)
      {logic, _} = Logic.step(logic, corrente(0, 0, lido), @config, 5_200)
      assert logic.survivors != nil

      {_logic, orders} = Logic.step(logic, corrente(0, 1, lido), @config, 5_400)

      assert orders.route == :hold, orders.why
      assert orders.fire == :free, orders.why
      assert orders.why =~ ~r/sobrevivente|estourando/, orders.why
    end

    test "a tela limpa por um segundo solta o latch" do
      {logic, _} = depois_da_corrente()

      logic =
        Enum.reduce(1..5, logic, fn i, acc ->
          {acc, _} = Logic.step(acc, corrente(0, 0), @config, 2_000 + i * 200)
          acc
        end)

      assert logic.survivors == nil
    end

    test "passadas seis correntes, deixa pra trás e pede nome ou cor" do
      logic = %{Logic.new() | survivors: %{since: 0, chains: 6}}
      {_logic, fim} = depois_da_corrente(logic)

      assert fim.why =~ "7 correntes e ainda sobrou"
      assert fim.why =~ "marque o nome ou a cor"
    end
  end

  # 17:06 de 02/09: a vida do pokémon não foi lida a caçada inteira, o reset
  # do fim da corrente foi recusado por isso e sobrou a retirada. "Ao fim do
  # combo é o momento PERFEITO pra usar o revive — os monstros ao redor já
  # ficam stunados."
  describe "o fim da corrente sem leitura da vida" do
    defp fim_da_corrente(own_out?, spent? \\ true) do
      world(%{
        situation:
          situation(%{
            enemies: 2,
            spent?: spent?,
            own_out?: own_out?,
            own_hp: nil,
            combo_left_ms: 0,
            # a corrente ACABOU de sair: é o sono dela que cobre a recolhida
            combo_stun_age_ms: 500,
            worth_fighting?: true
          }),
        hunt: hunt(%{state: :fighting})
      })
    end

    test "vida ilegível não bloqueia o revive: sai, parado, e diz por quê" do
      {_logic, orders} = Logic.step(Logic.new(), fim_da_corrente(:unknown), @config, 1_000)

      assert orders.revive == :now, orders.why
      assert orders.route == :hold
      assert orders.why =~ "sem leitura da vida"
      refute orders.route == :back
    end

    test "o chão PROVADO continua sendo o caído, não o reset" do
      {_logic, orders} = Logic.step(Logic.new(), fim_da_corrente(false), @config, 1_000)

      assert orders.phase == :downed
    end

    test "com a barra ainda cheia, nada de revive" do
      {_logic, orders} = Logic.step(Logic.new(), fim_da_corrente(:unknown, false), @config, 1_000)

      assert orders.revive == :hold
    end

    # "É legal ter aviso disso pra evitar de eu fazer merda por não saber que ele
    # não tá pegando dados corretos — não iniciar o cavebot e talz."
    test "oito segundos sem leitura da vida param a caçada, e a leitura de volta solta" do
      cego = fim_da_corrente(:unknown, false)

      {logic, cedo} = Logic.step(Logic.new(), cego, @config, 1_000)
      refute cedo.phase == :stranded

      {logic, parou} = Logic.step(logic, cego, @config, 9_500)
      assert parou.phase == :stranded
      assert parou.route == :hold
      assert parou.why =~ "recalibre"

      lido = put_in(cego.situation.own_hp, 90) |> put_in([:situation, :own_out?], true)
      {logic, voltou} = Logic.step(logic, lido, @config, 9_700)
      refute voltou.phase == :stranded
      assert logic.hp_blind_since == nil
    end

    test "o chão provado não conta como cegueira" do
      caido = fim_da_corrente(false, false)

      {logic, _} = Logic.step(Logic.new(), caido, @config, 1_000)
      {_logic, orders} = Logic.step(logic, caido, @config, 9_500)

      assert orders.phase == :downed
    end
  end

  describe "deixar a pilha pra trás" do
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

    # "Bater em quem vem junto" existiu como régua e foi medido como nada
    # (#489); saiu em 02/09. Passa de mãos baixas, sempre.
    test "passa de mãos baixas: a régua é dele" do
      {_logic, orders} = passando(@config)

      assert orders.phase == :skipping
      assert orders.route == :go
      assert orders.fire == :hold
    end

    # 02/09, 20:33: "checou que tinha dois inimigos, saiu correndo e do nada
    # tinha uns 10 ao meu redor". O "deixei pra trás" grudava: cinco waypoints
    # sem reler a lista. Quem vem atrás e enche a tela é régua de novo.
    test "a pilha deixada pra trás que ENCHE enquanto ando para e abre" do
      {logic, deixada} = passando(@config)
      assert deixada.phase == :skipping

      cheia =
        world(%{
          situation: situation(%{enemies: 6, worth_fighting?: true}),
          hunt: hunt(%{state: :walking})
        })

      {logic, orders} = Logic.step(logic, cheia, @config, @config.size_ceiling_ms + 400)

      refute logic.state == :skipping
      refute orders.phase == :skipping
      assert orders.route == :hold
      assert orders.fire == :free
    end

    # …e a tela vazia solta o estado: a PRÓXIMA pilha é contada do zero, em vez
    # de herdar o "não vale" da anterior.
    test "a tela vazia solta o 'deixei pra trás', e a próxima pilha é contada de novo" do
      {logic, _deixada} = passando(@config)

      vazia = world(%{situation: situation(%{enemies: 0}), hunt: hunt(%{state: :walking})})
      {logic, sozinho} = Logic.step(logic, vazia, @config, @config.size_ceiling_ms + 400)
      assert sozinho.phase == :travelling

      proxima =
        world(%{
          situation: situation(%{enemies: 2, worth_fighting?: false, growing?: true}),
          hunt: hunt(%{state: :fighting})
        })

      {logic, contando} = Logic.step(logic, proxima, @config, @config.size_ceiling_ms + 600)

      refute logic.state == :skipping
      refute contando.phase == :skipping
    end

    # Um ou dois que seguem atrás continuam sendo um ou dois: R1 não mudou.
    test "com a pilha ainda pequena, segue de mãos baixas" do
      {logic, _deixada} = passando(@config)

      ainda_pequena =
        world(%{
          situation: situation(%{enemies: 2, worth_fighting?: false}),
          hunt: hunt(%{state: :walking})
        })

      {_logic, orders} = Logic.step(logic, ainda_pequena, @config, @config.size_ceiling_ms + 400)

      assert orders.phase == :skipping
      assert orders.route == :go
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

    # "Ele vê 1 inimigo, fica parado uns segundos, diz que desistiu e volta a
    # andar; segundo sem ação, só parado, é ruim" (02/09). Abaixo do "encara"
    # a rota segue, contando; no tique em que enche, para e abre.
    test "below the ruler the route keeps going, counting — and stops the tick it fills" do
      contando =
        Config.merge(%{gather_piles: false, engage_from: 3, bunch_ms: 0, gather_target: 3})

      um =
        world(%{
          situation: situation(%{enemies: 1, worth_fighting?: false, growing?: true}),
          hunt: hunt(%{state: :fighting})
        })

      {logic, andando} = Logic.step(Logic.new(), um, contando, 1_000)
      assert andando.phase == :sizing
      assert andando.route == :go
      assert andando.fire == :hold
      assert andando.why =~ "seguindo a rota"

      tres =
        world(%{
          situation: situation(%{enemies: 3, worth_fighting?: true}),
          hunt: hunt(%{state: :fighting})
        })

      {_logic, parou} = Logic.step(logic, tres, contando, 1_400)
      assert parou.route == :hold
      assert parou.fire == :free
    end

    test "the same picture with gathering ON waits instead" do
      world =
        world(%{
          situation: situation(%{enemies: 1, growing?: true, stable_for_ms: 0}),
          hunt: hunt(%{state: :fighting})
        })

      {_logic, orders} = Logic.step(Logic.new(), world, Config.merge(%{bunch_ms: 0}), 1_000)

      refute orders.fire == :free
    end

    # Era "batendo enquanto ando": a rota seguia com a pilha atrás. Desde 02/09
    # ("não dar mais nenhum passo, deixar os bichos virem até mim") o trecho de
    # mobada sem juntada é régua como qualquer outro — e uma pilha que vale
    # abre PARADO.
    test "a stretch recorded for mobbing stops for a pile worth the area" do
      world =
        world(%{
          situation: situation(%{enemies: 6, worth_fighting?: true}),
          hunt: hunt(%{state: :walking, luring?: true})
        })

      {_logic, orders} = solo_step(world, 1_000)

      assert orders.route == :hold
      assert orders.fire == :free
      assert orders.why =~ "caindo em cima"
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

    # A RIGIDEZ DE 29/08: "temos é que ser mais rígidos para não ter fluxo
    # onde a skill de controle tá sendo usada sem querer". Com crowd_from: 1 o
    # controle saía na abertura de quase todo bolo (147 "controle e dano
    # juntos" na corrida de 3h) e o revive achava a tecla no chão (60
    # "controle em cooldown na hora do revive"). Com a R3b ligada, o controle
    # tem UM trabalho: prefixo do revive.
    test "numa pilha grande com a R3b ligada, o controle fica GUARDADO" do
      {_logic, orders} = Logic.step(aberta(pilha(5)), pilha(5), @r10, 200)

      refute "1" in orders.opening
      refute orders.why =~ "controle e dano juntos"
    end

    # …e a regra ofensiva de 26/08 ("tento ir usando o 1 pra quando tem muito
    # monstro") continua inteira pra quem caça SEM a R3b — aí não há revive
    # esperando pela tecla.
    test "sem a R3b, o controle ofensivo sai como sempre" do
      sem = %{@r10 | reset_revive: false}
      pequena = pilha(2)
      {logic, _} = Logic.step(Logic.new(), pequena, sem, 0)
      {logic, _} = Logic.step(logic, pequena, sem, 100)

      {_logic, orders} = Logic.step(logic, pilha(5), sem, 200)

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
      assert "1" in primeira.opening, primeira.why

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

    # COM A BARRA CHEIA NADA ACONTECE: nem controle (não há revive pra
    # prefixar), nem janela, nem revive. Antes de 29/08 o controle ofensivo
    # saía aqui e abria uma janela que a barra cheia então recusava — duas
    # regras se estranhando; agora a primeira nem dispara. "A gente tem que
    # usar todas as skills, para depois usar um ressurect" (27/08) segue
    # valendo pelo mesmo caminho de sempre: `spent?` na frente de tudo.
    test "com a barra cheia, nem controle nem revive — tudo guardado" do
      logic = aberta(pilha(5))
      {logic, primeira} = Logic.step(logic, pilha(5), @r10, 200)
      refute "1" in primeira.opening

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
    # …E A MORTE DE 03/09 ÀS 16:20 DESMENTIU A METADE DO "de longe". Foi
    # exatamente esta regra que matou: `travelling`, UM bicho na tela, pokémon a
    # 100%, corrente acabada havia sete segundos — "revive agora pra chegar
    # inteiro". O bicho chegou dentro da janela em que o pokémon estava na bola
    # e matou de um golpe; um segundo depois a vida DELE era 4%.
    #
    # O teto continua respondendo "isto ainda é entre grupos?"; quem responde
    # "posso recolher AGORA?" é a cerca do sono (`recall_safe?`). Com resto na
    # tela e sem sono fresco, o preparo espera — a tela limpa ou a corrente.
    test "na estrada, com resto na tela e sem sono, o preparo NÃO recolhe" do
      {_logic, orders} = Logic.step(Logic.new(), limpo(%{enemies: 2}), @preparo, 5_000)

      refute orders.revive == :prepare
    end

    test "na estrada, com a tela limpa o preparo sai como sempre" do
      {_logic, orders} = Logic.step(Logic.new(), limpo(%{enemies: 0}), @preparo, 5_000)

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

    # THE EYE ENDS THE WAIT (09/09): "encontrou dois ou três monstros, ele já
    # para e fica esperando um pouquinho — essa parada não é necessária". The
    # wait is for the pile to close on the pokémon; when the eye sees it
    # closed, the clock has nothing left to buy.
    defp eye_seeing(hostiles) do
      %{
        read?: true,
        at: 900,
        me: {0, 0},
        pet: %{point: {-36, 0}, dx: -1, dy: 0, tiles: 1, hp_pct: 100},
        hostiles: hostiles,
        listed: length(hostiles)
      }
    end

    defp seen(dx, dy, from_pet) do
      %{
        point: {dx * 36, dy * 36},
        dx: dx,
        dy: dy,
        from_me: max(abs(dx), abs(dy)),
        from_pet: from_pet,
        hp_pct: 100,
        skull?: false
      }
    end

    defp pilha_vista(n, hostiles) do
      world(%{
        situation:
          situation(%{
            enemies: n,
            worth_fighting?: true,
            stable_for_ms: 9_000,
            crowd: eye_seeing(hostiles)
          }),
        hunt: hunt(%{state: :fighting})
      })
    end

    test "with the eye seeing everyone on the pokemon, the wait ends at once" do
      closed = pilha_vista(3, [seen(-2, 0, 1), seen(-2, 1, 1), seen(-1, 1, 1)])

      {logic, _} = Logic.step(Logic.new(), pilha_pronta(), @espera, 1_000)
      {_logic, orders} = Logic.step(logic, closed, @espera, 1_300)

      assert orders.phase == :engaged
      assert orders.fire == :free
      assert orders.why =~ "o olho viu 3 colados"
    end

    test "with someone still loose, the wait goes on" do
      arriving = pilha_vista(3, [seen(-2, 0, 1), seen(-2, 1, 1), seen(4, 0, 5)])

      {logic, _} = Logic.step(Logic.new(), pilha_pronta(), @espera, 1_000)
      {_logic, orders} = Logic.step(logic, arriving, @espera, 1_300)

      assert orders.phase == :bunching
    end

    # "Sem caveira é brincadeira": in a skull area the chain's end is the stun
    # that keeps the pile asleep, and the whole wait stays until the eye has
    # proven itself there.
    test "with skulls on the pile the wait stays whole" do
      skulled =
        pilha_vista(3, [
          %{seen(-2, 0, 1) | skull?: true},
          %{seen(-2, 1, 1) | skull?: true},
          %{seen(-1, 1, 1) | skull?: true}
        ])

      {logic, _} = Logic.step(Logic.new(), pilha_pronta(), @espera, 1_000)
      {_logic, orders} = Logic.step(logic, skulled, @espera, 1_300)

      assert orders.phase == :bunching
    end

    test "bars hidden behind the ones on the pokemon are the pile stacked; more hidden than seen is not" do
      stacked = pilha_vista(4, [seen(-2, 0, 1), seen(-2, 1, 1)])
      walking_in = pilha_vista(5, [seen(-2, 0, 1)])

      {logic, _} = Logic.step(Logic.new(), pilha_pronta(), @espera, 1_000)
      {_logic, on_top} = Logic.step(logic, stacked, @espera, 1_300)
      assert on_top.phase == :engaged

      {logic, _} = Logic.step(Logic.new(), pilha_pronta(), @espera, 1_000)
      {_logic, still} = Logic.step(logic, walking_in, @espera, 1_300)
      assert still.phase == :bunching
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
    # DOIS TIQUES, e o primeiro é a decisão de arrastar: paciência conta passo
    # de arrasto, e o carimbo `:gathering` nasce no tique que decide.
    test "…ou quando a paciência acaba, com o bolo pela metade" do
      curta = Config.merge(%{@bolo | patience_tiles: 10})

      {logic, primeiro} = Logic.step(Logic.new(), juntando(3, 12), curta, 1_000)
      {_logic, orders} = Logic.step(logic, juntando(3, 12), curta, 1_200)

      assert primeiro.phase == :gathering
      assert orders.phase in [:bunching, :engaged]
    end

    # Até 02/09 a espera ANDAVA cinco passos antes de parar; desde "não dar
    # mais nenhum passo, deixar os bichos virem até mim" ela é parada do
    # primeiro tique, e o relógio termina o serviço.
    test "a espera é PARADA, de fogo segurado, e o relógio abre" do
      {logic, primeiro} = Logic.step(Logic.new(), juntando(6, 30), @bolo, 1_000)

      assert primeiro.phase == :bunching
      assert primeiro.route == :hold
      assert primeiro.fire == :hold

      {_logic, fogo} = Logic.step(logic, juntando(6, 30), @bolo, 8_000)
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
            control_back_in_ms: volta_em,
            # nil = nenhuma corrente saiu: é o mundo SEM sono
            combo_stun_age_ms: nil
          }),
        hunt: hunt(%{state: :fighting}),
        hands: %{opening: ~w(3 4), small: [], single: [], crowd: ["1"]}
      })
    end

    # "NÃO PERDE TEMPO FUGINDO, usa o que tem e usa o revive" (28/08) valia
    # enquanto o preço do recolhimento era desconhecido. Depois de 03/09 ele
    # tem preço medido: três mortes, a última com um bicho só. Sem controle e
    # sem sono da corrente, o revive espera; o que sai é o recuo com a reserva
    # na mão — que é o "usa o que tem" da mesma frase.
    test "sem controle e sem sono, o revive espera e a caçada recua" do
      {logic, _} = Logic.step(Logic.new(), barra_vazia_sem_controle(), @sem_stun, 1_000)
      {_logic, orders} = Logic.step(logic, barra_vazia_sem_controle(), @sem_stun, 2_000)

      assert orders.revive == :hold
      assert orders.why =~ "segurando o revive"
    end

    test "com o sono fresco da corrente, ele sai na hora" do
      mundo = put_in(barra_vazia_sem_controle().situation.combo_stun_age_ms, 500)
      {logic, _} = Logic.step(Logic.new(), mundo, @sem_stun, 1_000)
      {_logic, orders} = Logic.step(logic, mundo, @sem_stun, 2_000)

      assert orders.revive == :now
    end

    # O QUE NÃO MUDOU: a espera pelo CONTROLE continua proibida — não é o
    # relógio do controle que decide, é o sono. Com o sono na mesa, o quanto
    # falta pro controle voltar segue sendo irrelevante, perto ou longe.
    test "com o controle longe, o sono fresco basta" do
      longe = put_in(barra_vazia_sem_controle(38_000).situation.combo_stun_age_ms, 500)

      {logic, _} = Logic.step(Logic.new(), longe, @sem_stun, 1_000)
      {_logic, orders} = Logic.step(logic, longe, @sem_stun, 2_000)

      assert orders.revive == :now
    end

    test "sem relógio nenhum, idem" do
      sem_relogio = put_in(barra_vazia_sem_controle(nil).situation.combo_stun_age_ms, 500)

      {logic, _} = Logic.step(Logic.new(), sem_relogio, @sem_stun, 1_000)
      {_logic, orders} = Logic.step(logic, sem_relogio, @sem_stun, 2_000)

      assert orders.revive == :now
    end
  end

  # A POSTURA DE CHEFE, na forma final que ELE ditou (30/08): o stun dura 3s e
  # é o PREFIXO do revive — "tu só precisa do stun quando vai usar o revive,
  # não precisa usar antes" —, o F4 não tem cooldown no jogo (o piso de 5s é
  # segurança nossa), e quem dirige o ciclo é a BARRA GASTA: todas as skills,
  # stun, F4, de novo.
  describe "a postura do especial" do
    @especial Config.merge(%{
                reset_revive: true,
                boss_names: "especial",
                stun_hold_ms: 3_000,
                stun_reach_tiles: 3,
                rescue_floor_ms: 5_000,
                bunch_ms: 0,
                gather_target: 1
              })

    defp chefe_step(logic, world, now), do: Logic.step(logic, world, @especial, now)

    # A LUTA JÁ ABERTA, que é onde o ciclo do especial vive: o stun a cada
    # emenda é DURANTE a luta. Desde 12/09 ninguém fura a fila da juntada antes
    # de abrir — "Postura no shiny é juntar primeiro!" vale pros três caminhos
    # que acham o especial, porque é o mesmo bicho.
    defp em_luta, do: %{Logic.new() | state: :engaged, special_opened?: true}

    defp com_chefe(overrides \\ %{}) do
      world(%{
        situation:
          situation(
            Map.merge(
              %{
                enemies: 1,
                special?: true,
                worth_fighting?: true,
                special_tiles: 2,
                special_asleep_left_ms: 0,
                spent?: true,
                ready_keys: ["1"]
              },
              overrides
            )
          ),
        hunt: hunt(%{state: :fighting})
      })
    end

    test "a special on screen skips the ruler: it fights with ONE creature" do
      {logic, orders} = chefe_step(em_luta(), com_chefe(), 1_000)

      assert logic.state == :engaged
      assert orders.route == :hold
    end

    # O DEFEITO MEDIDO EM 01/09, e o mais caro deles: das 29,3s às 34,9s da
    # bancada o cérebro ficou em AMARELO — "gastando os cooldowns" — com um
    # shiny 5× colado e ACORDADO, o controle pronto na mão, e caiu de 58% a 26%
    # sem apertar o controle uma vez. As bandas de vida ficavam acima da
    # postura, e a banda revive pra CURAR: curar debaixo da mordida é encher
    # balde furado, porque o que PARA o dano é o stun. Corrigido: só a perna do
    # controle fura a fila; o revive continua sendo da banda.
    test "com o especial ACORDADO o controle fura a banda amarela" do
      ferido = com_chefe(%{own_hp: 45})

      {logic, orders} = chefe_step(em_luta(), ferido, 1_000)

      assert orders.band == :yellow, "a vida É amarela — o teste não vale se a banda mudou"
      assert "1" in orders.opening, "a banda engoliu o controle de novo: #{orders.why}"
      assert orders.why =~ "controle antes do sono acabar"
      assert logic.state == :engaged
    end

    # A banda continua dona do REVIVE: o stun gasta um tique e a cura vem no
    # seguinte ("controle primeiro, revive na sequência").
    test "e no tique seguinte a banda volta a mandar — com o bolo já dormindo" do
      ferido = com_chefe(%{own_hp: 45})
      {logic, _} = chefe_step(em_luta(), ferido, 1_000)

      dormindo = com_chefe(%{own_hp: 45, special_asleep_left_ms: 5_000, ready_keys: []})
      {_logic, orders} = chefe_step(logic, dormindo, 1_200)

      assert orders.band == :yellow
      refute orders.why =~ "controle antes do sono acabar"
    end

    test "barra gasta e especial no alcance: o stun sai como prefixo" do
      {_logic, orders} = chefe_step(em_luta(), com_chefe(), 1_000)

      assert "1" in orders.opening
      assert orders.why =~ "controle antes do sono acabar"
    end

    test "com a barra rendendo e o sono de sobra, nada de stun — só dano" do
      folgado = com_chefe(%{spent?: false, special_asleep_left_ms: 5_000})
      {_logic, orders} = chefe_step(em_luta(), folgado, 1_000)

      refute "1" in orders.opening
      refute orders.revive == :now
    end

    # especial ACORDADO é emenda vencida: o stun sai mesmo com a barra rendendo —
    # o sono protege o pokémon, a barra espera
    test "special awake: the stun goes out even with the bar still paying" do
      {_logic, orders} = chefe_step(em_luta(), com_chefe(%{spent?: false}), 1_000)

      assert "1" in orders.opening
    end

    test "a special FAR AWAY gets no stun: sleeping the wind is arriving awake" do
      {_logic, orders} = chefe_step(em_luta(), com_chefe(%{special_tiles: 6}), 1_000)

      refute "1" in orders.opening
    end

    test "o F4 vem atrás do stun, com o sono testemunhado" do
      {logic, _stun} = chefe_step(em_luta(), com_chefe(), 1_000)

      dormindo = com_chefe(%{special_asleep_left_ms: 2_500, ready_keys: []})
      {_logic, orders} = chefe_step(logic, dormindo, 1_400)

      assert orders.revive == :now
      assert orders.why =~ "revive agora"
    end

    test "sem sono testemunhado o F4 do ciclo espera — stun no vento não se paga" do
      {logic, _stun} = chefe_step(em_luta(), com_chefe(), 1_000)

      # controle pronto, senão a perna de emergência (que é outro teste)
      # responderia por este
      acordado = com_chefe(%{special_asleep_left_ms: 0, ready_keys: ["1"]})
      {_logic, orders} = chefe_step(logic, acordado, 1_400)

      refute orders.revive == :now
    end

    test "UM F4 por stun: o segundo pedido da mesma janela é negado" do
      {logic, _stun} = chefe_step(em_luta(), com_chefe(), 1_000)
      dormindo = com_chefe(%{special_asleep_left_ms: 2_500, ready_keys: []})
      {logic, primeiro} = chefe_step(logic, dormindo, 1_400)
      assert primeiro.revive == :now

      {_logic, segundo} =
        chefe_step(logic, com_chefe(%{special_asleep_left_ms: 2_000, ready_keys: []}), 1_900)

      refute segundo.revive == :now
    end

    # O piso de 5s é do F4, NUNCA do stun: o sono protege o pokémon e não
    # espera relógio de segurança (medido na bancada: esperar custava 2,2s de
    # especial mordendo com o controle pronto).
    test "o F4 respeita o piso de 5s — e o stun não espera por ele" do
      {logic, _stun} = chefe_step(em_luta(), com_chefe(), 1_000)
      dormindo = com_chefe(%{special_asleep_left_ms: 4_000, ready_keys: []})
      {logic, primeiro} = chefe_step(logic, dormindo, 1_400)
      assert primeiro.revive == :now

      # o especial acorda cedo: o STUN sai já, mesmo a menos de 5s do último F4…
      {logic, stun2} = chefe_step(logic, com_chefe(), 4_000)
      assert "1" in stun2.opening, "o sono esperou o piso do item"

      # …e o F4 desta janela espera o piso vencer
      {logic, cedo} =
        chefe_step(logic, com_chefe(%{special_asleep_left_ms: 6_000, ready_keys: []}), 4_400)

      refute cedo.revive == :now

      {_logic, ok} =
        chefe_step(logic, com_chefe(%{special_asleep_left_ms: 5_000, ready_keys: []}), 6_600)

      assert ok.revive == :now
    end

    test "special awake with the control down: F4 buys the control back" do
      {logic, _stun} = chefe_step(em_luta(), com_chefe(), 1_000)

      sem_controle = com_chefe(%{special_asleep_left_ms: 0, ready_keys: ~w(3 4)})
      {_logic, orders} = chefe_step(logic, sem_controle, 9_000)

      assert orders.revive == :now
      assert orders.why =~ "compra o controle"
    end

    test "you do not run from the special: the empty bar that would kite stays and fights" do
      {logic, _} = chefe_step(em_luta(), com_chefe(), 1_000)

      gasto = com_chefe(%{special_asleep_left_ms: 1_000, spent?: true, ready_keys: []})
      {_logic, orders} = chefe_step(logic, gasto, 3_000)

      refute orders.why =~ "recuando"
    end

    test "walking the route, the special interrupts: it becomes a fight on the same tick" do
      mundo = %{com_chefe() | hunt: hunt(%{state: :walking, luring?: false})}
      {logic, _orders} = chefe_step(em_luta(), mundo, 1_000)

      assert logic.state == :engaged
    end
  end

  # O CABO DE GUERRA DO TRECHO DE MOB (morte de 30/08, 13:21). O ramo do
  # luring re-setava o estado pra :gathering a cada tique, pisando no
  # :bunching que a régua abria: `bunch_from` renascia, "mais 2 passos"
  # recomeçava do zero, e o fogo nunca liberava — 43 passos de mobada com 6-9
  # bichos mastigando e nenhuma rajada. "Cheio de monstro atrás de mim e ele
  # não parou pra matar — é inaceitável."
  describe "a mobada FECHA no trecho de mob" do
    @mob Config.merge(%{
           gather_piles: true,
           gather_target: 4,
           bunch_ms: 3_000,
           engage_from: 3,
           crowd_from: 99,
           reset_revive: false
         })

    defp mob_step(logic, world, now), do: Logic.step(logic, world, @mob, now)

    defp trecho(walked, enemies) do
      world(%{
        situation:
          situation(%{
            enemies: enemies,
            worth_fighting?: true,
            spent?: false,
            walked: walked,
            walked_total: walked
          }),
        hunt: hunt(%{state: :walking, luring?: true})
      })
    end

    test "a régua fecha, a espera é parada e não reinicia, e o fogo sai" do
      # mobando: a pilha chega no alvo com 10 passos andados
      {logic, _} = mob_step(Logic.new(), trecho(9, 3), 1_000)
      {logic, abriu} = mob_step(logic, trecho(10, 4), 1_200)
      assert abriu.phase in [:bunching, :engaged], "a régua fechou e nada abriu"
      assert abriu.route == :hold

      # o tique seguinte NÃO reabre a juntada por cima da espera (o flip de 30/08)
      {logic, meio} = mob_step(logic, trecho(10, 4), 1_400)
      assert meio.phase == :bunching
      assert meio.route == :hold

      # vencida a espera do bolo, o fogo LIBERA — mesmo com o trecho de mob
      # ainda marcado na rota
      {_logic, fogo} = mob_step(logic, trecho(10, 4), 6_000)
      assert fogo.phase == :engaged
      assert fogo.fire == :free
    end

    test "sem pilha que valha, o trecho segue mobando como sempre" do
      {logic, _} = mob_step(Logic.new(), trecho(3, 1), 1_000)
      {_logic, orders} = mob_step(logic, trecho(4, 1), 1_200)

      assert orders.phase == :gathering
      assert orders.fire == :hold
    end
  end

  # A MORTE DE 03/09, 12:32, virada em regra.
  #
  # Doze revives em dois minutos, os últimos de seis em seis segundos, com 3 a 7
  # bichos na tela. Cada revive RECOLHE o pokémon, e nesses segundos o
  # personagem fica de peito aberto: às 12:31:56 a vida DELE era 4%, um segundo
  # depois de mais um revive de reset. Ele morreu dentro da janela — e o pokémon
  # nunca voltou porque não havia mais quem o chamasse.
  #
  # A regra: revive de CONVENIÊNCIA (resetar a barra) espera ele parar de
  # apanhar. O resgate não passa por aqui.
  # A REGRA DELE, escrita depois da TERCEIRA morte do dia (03/09, 16:20):
  #
  #   "não usar revive se tiver alguém perto a não ser que tenha [saído] o stun
  #    (…) quando usamos o R, depois dele é o momento seguro pra usar revive, ou
  #    se não tiver nenhum monstro inimigo mais na tela"
  #
  # A versão anterior desta cerca perguntava se ELE estava machucado, e não
  # alcançou o golpe que o matou: ele estava com a vida CHEIA, um bicho só na
  # tela, e morreu de um hit dentro da janela em que o revive recolheu o
  # pokémon. Agora recolher exige tela limpa OU sono fresco.
  describe "o revive de conveniência só recolhe com sono ou tela limpa" do
    @cerca Config.merge(%{
             reset_revive: false,
             prepare_revive: false,
             engage_from: 3,
             crowd_from: 99,
             bunch_ms: 0,
             gather_target: 1
           })

    defp cerca_step(logic, world, now), do: Logic.step(logic, world, @cerca, now)

    defp cerca_orders(world) do
      {_logic, orders} = cerca_step(Logic.new(), world, 10_000)
      orders
    end

    defp cerca_segundo(world) do
      {logic, _abertura} = cerca_step(Logic.new(), world, 10_000)
      {_logic, orders} = cerca_step(logic, world, 10_500)
      orders
    end

    # 4 bichos na tela e a corrente acabada há muito: sem sono.
    defp mobada(overrides) do
      world(%{
        situation:
          situation(
            Map.merge(
              %{
                enemies: 4,
                spent?: true,
                own_hp: 100,
                combo_left_ms: 0,
                combo_stun_age_ms: 30_000
              },
              overrides
            )
          ),
        hunt: hunt(%{state: :fighting}),
        hands: %{
          opening: ~w(3 4),
          single: ~w(7 8),
          # no Auto Combo a rotação não gasta o controle (`crowd: []`), mas a
          # tecla EXISTE (`stun`) e é ela que abre o revive
          crowd: [],
          reserve: ~w(7 8 2),
          stun: ["2"]
        }
      })
    end

    test "com bicho na tela e sem sono, o reset espera" do
      assert cerca_orders(mobada(%{})).revive == :hold
    end

    # E A LUTA NÃO CONGELA NEM RECUA: fica PARADA, matando com o que sobrou.
    # A bancada mostrou por que não pode recuar — no enxame a caçada parava de
    # fechar volta — e parar é a regra dele: "não dar mais nenhum passo, deixar
    # os bichos virem até mim" (02/09).
    test "segurado, o cérebro para de recuar e luta parado, dizendo por quê" do
      orders = cerca_segundo(mobada(%{}))

      assert orders.revive == :hold
      assert orders.route == :hold
      assert orders.why =~ "parado, matando o que dá"
      assert orders.why =~ "sem sono fresco"
    end

    # O BOLSO ABRE JUNTO: sem a área, o alvo único e o controle são o que
    # sobrou pra matar sem recolher ninguém.
    test "com o revive segurado, a reserva do modo entra na mão" do
      orders = cerca_segundo(mobada(%{}))

      assert "7" in orders.opening
      assert "2" in orders.opening
    end

    # A CORRENTE ACABOU DE SAIR: é o sono dela que cobre a recolhida, e o ciclo
    # dele segue igual.
    test "com o sono fresco da corrente, o reset sai como sempre" do
      orders = cerca_orders(mobada(%{combo_stun_age_ms: 500}))

      assert orders.revive == :now
      refute orders.why =~ "segurando"
    end

    test "com sono fresco a reserva fica guardada" do
      refute "7" in cerca_segundo(mobada(%{combo_stun_age_ms: 500})).opening
    end

    # Sem bicho na tela não há de quem apanhar: recolher é seguro mesmo sem sono.
    test "com a tela limpa, recolher é sempre seguro" do
      assert cerca_orders(mobada(%{enemies: 0})).revive == :now
    end

    # TELA ILEGÍVEL NÃO É TELA LIMPA. Sem saber quem está lá, o sono é a única
    # licença — o oposto da disciplina "cego aperta" do resto do módulo, e de
    # propósito: aqui o erro custa o personagem.
    test "sem leitura da lista, sem sono não recolhe" do
      assert cerca_orders(mobada(%{enemies: nil})).revive == :hold
    end

    # O CONTROLE ABRE A PORTA. "Sempre terei revives em mãos pra resetar os
    # cooldowns, só temos que ficar vivos tempo suficiente para usar a skill de
    # stun antes disso" (03/09). Sem isto a cerca do sono era uma porta sem
    # chave no Auto Combo: a corrente é quem dorme a pilha, e quando o sono dela
    # vence com bicho ainda na tela o cérebro não tinha como FAZER sono nenhum.
    test "segurado, o controle sai e abre o revive no tique seguinte" do
      mundo = mobada(%{})

      {logic, primeiro} = cerca_step(Logic.new(), mundo, 10_000)
      {logic, segundo} = cerca_step(logic, mundo, 10_500)

      assert primeiro.revive == :hold
      assert segundo.revive == :hold
      assert "2" in segundo.opening, "o controle do pokémon tem que sair"
      assert segundo.why =~ "controle na frente pra abrir o revive"

      # …e com o sono carimbado, o tique seguinte já pode recolher.
      {_logic, terceiro} = cerca_step(logic, mundo, 11_000)
      assert terceiro.revive == :now
    end

    # UMA TECLA FRIA NÃO É SONO: carimbar sem o controle pronto seria dar
    # licença falsa ao revive, que é o lado perigoso do desarme falso de 28/08.
    test "com o controle frio, nada é carimbado e o revive segue preso" do
      frio = mobada(%{ready_keys: ~w(3 4)})

      {logic, _} = cerca_step(Logic.new(), frio, 10_000)
      {logic, segundo} = cerca_step(logic, frio, 10_500)
      {_logic, terceiro} = cerca_step(logic, frio, 11_000)

      refute segundo.why =~ "controle na frente"
      assert terceiro.revive == :hold
    end

    # O RESGATE NÃO É CONVENIÊNCIA: com o pokémon caindo, quem está indo embora
    # é ele, e a decisão de arriscar cedo é dele (02/09).
    test "no vermelho o resgate sai mesmo sem sono" do
      orders = cerca_orders(mobada(%{own_hp: 10}))

      assert orders.revive == :now
      assert orders.band == :red
    end
  end

  # THE SIEGE EYE, IN SHADOW: the brain still decides by today's rules, but
  # writes beside every revive it gives or holds what the EYE would say — a
  # night of that shows where the two disagree before the eye is given the key.
  # The reading travels on the picture (`crowd`); without it nothing changes.
  describe "the siege eye (shadow)" do
    @tile 36

    defp creature(dx, dy, opts \\ []) do
      %{
        point: {dx * @tile, dy * @tile},
        dx: dx,
        dy: dy,
        from_me: max(abs(dx), abs(dy)),
        from_pet: Keyword.get(opts, :from_pet, max(abs(dx), abs(dy))),
        hp_pct: 100,
        skull?: Keyword.get(opts, :skull?, false)
      }
    end

    # his pokemon one tile to the left; the list counts what the picture saw
    defp eye(hostiles) do
      %{
        read?: true,
        at: 9_900,
        me: {0, 0},
        pet: %{point: {-@tile, 0}, dx: -1, dy: 0, tiles: 1, hp_pct: 100},
        hostiles: hostiles,
        listed: length(hostiles)
      }
    end

    # the fence's pile (4 listed, no sleep) with the eye seeing part of it — and
    # the control COLD, so nothing stamps a sleep and the revive stays held
    defp seen_pile(hostiles, overrides \\ %{}),
      do: mobada(Map.merge(%{crowd: eye(hostiles), ready_keys: ~w(3 4)}, overrides))

    test "without an eye the orders are what they were" do
      orders = cerca_segundo(mobada(%{ready_keys: ~w(3 4)}))

      assert orders.why =~ "segurando o revive"
      refute orders.why =~ "o olho diria"
      assert orders.siege == nil
    end

    test "with an eye, a held revive says what the eye would say, and files the numbers" do
      orders = cerca_segundo(seen_pile([creature(-2, 0, from_pet: 1), creature(3, 0)]))

      assert orders.revive == :hold
      assert orders.why =~ "segurando o revive"

      assert orders.why =~
               "o olho diria: olho: 1 colado acordado · 1 solto a 3 tiles · 2 sem ver → segurando"

      assert orders.siege == %{
               read: true,
               heavy: false,
               pinned: 1,
               covered: 0,
               loose: 1,
               unseen: 2,
               gap: false,
               seen: 2,
               pet: true
             }
    end

    # O DIÁRIO PRECISA VER A RÉGUA CONTANDO. O carimbo do olho só andava em
    # decisão de revive, e por isso os 12.485 registros de 09/09 não têm um
    # único tique de `:sizing`/`:bunching` com o bloco — cego justamente na fase
    # que decide o tamanho da pilha. A FRASE não muda: os números do olho mudam
    # a cada tique e os dois dedups do caminho comparam `why` por igualdade.
    test "the ruler's own phases file the eye without speaking of it" do
      contando =
        world(%{
          situation:
            situation(%{
              enemies: 1,
              worth_fighting?: false,
              crowd: eye([creature(3, 0)])
            })
        })

      {_logic, orders} = step(contando, 10_000)

      assert orders.phase in [:sizing, :gathering, :bunching]
      assert orders.route == :go
      refute orders.why =~ "o olho diria"
      assert orders.siege.seen == 1
      assert orders.siege.pet == true
    end

    test "an order without a revive does not speak of the eye" do
      {_logic, abertura} = cerca_step(Logic.new(), seen_pile([creature(3, 0)]), 10_000)

      assert abertura.revive == :hold
      refute abertura.why =~ "o olho diria"
      assert abertura.siege == nil
    end

    # THE CONTROL THAT GOES OUT TAKES THE COVER: whoever stood within the
    # stun's reach sleeps; whoever arrives later matches no point.
    test "the control stamps the sleep AND the cover; the next revive is safe by the eye too" do
      mundo =
        mobada(%{
          crowd:
            eye([
              creature(-2, 0, from_pet: 1),
              creature(-2, 1, from_pet: 1),
              creature(4, 0, from_pet: 5)
            ])
        })

      {logic, _abertura} = cerca_step(Logic.new(), mundo, 10_000)
      assert logic.stun_cover == nil

      {logic, segundo} = cerca_step(logic, mundo, 10_500)
      assert segundo.why =~ "controle na frente"

      assert logic.stun_cover ==
               %{at: 10_500, pet: {-1, 0}, pos: @here, points: [{-2, 0}, {-2, 1}]}

      {_logic, terceiro} = cerca_step(logic, mundo, 11_000)
      assert terceiro.revive == :now

      assert terceiro.why =~
               "o olho diria: olho: 2 colados dormindo · 1 solto a 4 tiles · 1 sem ver → revive seguro"

      assert terceiro.siege.gap == true
    end

    # …E O SONO SOBREVIVE AOS PASSOS DELE. A cobertura é escrita em tiles a
    # partir do personagem, e ele anda: dois passos para leste e os MESMOS
    # bichos parados aparecem dois tiles mais à esquerda na tela. Sem levar a
    # coordenada junto, a pilha adormecida "acordava" a cada passo — e um bicho
    # novo que pisasse no lugar dela era dado como dormindo.
    test "the sleep survives his own steps: the frame moves, the sleepers do not" do
      parado =
        mobada(%{
          crowd: eye([creature(-2, 0, from_pet: 1), creature(-2, 1, from_pet: 1)])
        })

      {logic, _abertura} = cerca_step(Logic.new(), parado, 10_000)
      {logic, _segundo} = cerca_step(logic, parado, 10_500)
      assert logic.stun_cover.pos == @here

      # dois passos para leste: os mesmos dois bichos, sem sair do lugar
      andou =
        mobada(%{
          crowd: eye([creature(-4, 0, from_pet: 1), creature(-4, 1, from_pet: 1)]),
          pos: {102, 200, 7}
        })

      {_logic, terceiro} = cerca_step(logic, andou, 11_000)

      assert terceiro.why =~ "2 colados dormindo"
      assert terceiro.siege.covered == 2
    end

    # IN AUTO COMBO THE STUN IS THE CHAIN'S FIRST SKILL: the edge where the
    # chain STARTS is the sleep, and the cover is taken there, from that very
    # tick's picture.
    #
    # It used to be taken at the chain's END, on the belief that "the chain
    # ends in the control". His combo does the opposite — "o stun é a primeira
    # coisa do auto-combo, pra já salvar o pokémon se ele tiver com baixa vida,
    # não a última coisa" (12/09) — so the picture retrated whoever stood close
    # when the chain was already OVER, and a creature that walked in during it
    # was filed as covered without ever having been put to sleep.
    test "the chain's start is the sleep: the cover is taken there" do
      eye = eye([creature(-2, 0, from_pet: 1), creature(-2, 1, from_pet: 1)])

      chain = fn overrides ->
        world(%{
          situation:
            situation(Map.merge(%{enemies: 2, spent?: true, own_hp: 100, crowd: eye}, overrides)),
          hunt: hunt(%{state: :fighting}),
          hands: %{opening: ~w(3 4), single: [], crowd: []}
        })
      end

      quieto = chain.(%{combo_left_ms: 0, combo_stun_age_ms: nil})
      saindo = chain.(%{combo_left_ms: 2_500, combo_stun_age_ms: 0})

      {logic, _} = Logic.step(Logic.new(), quieto, @sem_stun, 10_000)
      refute logic.chain_seen?
      assert logic.stun_cover == nil

      {logic, _} = Logic.step(logic, saindo, @sem_stun, 12_500)

      assert logic.chain_seen?

      assert logic.stun_cover ==
               %{at: 12_500, pet: {-1, 0}, pos: @here, points: [{-2, 0}, {-2, 1}]}

      # …e a corrente saindo não tira foto nova a cada tique: o sono é UM.
      {logic, _} =
        Logic.step(
          logic,
          chain.(%{combo_left_ms: 800, combo_stun_age_ms: 1_700}),
          @sem_stun,
          14_200
        )

      assert logic.stun_cover.at == 12_500
    end

    # THE PARK RIDES ON THE HOLD: whenever the road holds for a pile the eye
    # sees, the orders name the tile two toward it; walking orders name none.
    test "a held road with the eye on the pile names where the pokemon parks" do
      {_logic, orders} =
        cerca_step(Logic.new(), seen_pile([creature(4, 1), creature(3, -1)]), 10_000)

      assert orders.route == :hold
      assert orders.park == {2, 0}
    end

    test "without an eye, or with the pokemon in the ball, the hold names no spot" do
      {_logic, blind} = cerca_step(Logic.new(), mobada(%{ready_keys: ~w(3 4)}), 10_000)
      assert blind.route == :hold
      assert blind.park == nil

      recalled = seen_pile([creature(4, 1)], %{own_out?: false, own_hp: nil})
      {_logic, orders} = cerca_step(Logic.new(), recalled, 10_000)
      assert orders.park == nil
    end

    test "with the special on screen the pokemon stays at his side" do
      special = seen_pile([creature(4, 1), creature(3, -1)], %{special?: true})
      {_logic, orders} = cerca_step(Logic.new(), special, 10_000)

      assert orders.route == :hold
      assert orders.park == nil
    end

    test "a walking road parks nothing" do
      {_logic, orders} =
        cerca_step(
          Logic.new(),
          world(%{
            situation:
              situation(%{enemies: 1, worth_fighting?: false, crowd: eye([creature(4, 1)])})
          }),
          1_000
        )

      assert orders.route == :go
      assert orders.park == nil
    end

    # "Ou são todos com caveira ou nenhum": the skull is the area's, and an
    # effect over the pile hides it without changing the area.
    test "a skull latches the area heavy until the list empties" do
      skulled = seen_pile([creature(3, 0, skull?: true)])
      skull_less = seen_pile([creature(3, 0)])

      {logic, _} = cerca_step(Logic.new(), skulled, 10_000)
      assert logic.heavy_area?

      {logic, orders} = cerca_step(logic, skull_less, 10_500)

      assert orders.why =~
               "o olho diria: olho (caveira): ninguém colado · 1 solto a 3 tiles · 3 sem ver → segurando"

      {logic, _} = cerca_step(logic, seen_pile([], %{enemies: 0}), 11_000)
      refute logic.heavy_area?
    end
  end

  # THE SHINY ON THE GROUND HOLDS THE FEET (spec 2026-09-09-shiny-na-cacada):
  # while the Catcher aims at the corpse, a walking order stands — feet only,
  # for at most `capture_hold_ms` — and says why. Red never holds.
  describe "the shiny corpse holds the road" do
    @capture Config.merge(%{bunch_ms: 0, gather_target: 1, capture_hold_ms: 6_000})

    defp capture_step(logic, world, now), do: Logic.step(logic, world, @capture, now)

    defp walking(overrides \\ %{}) do
      world(%{
        situation: situation(Map.merge(%{enemies: 0, capturing?: true}, overrides)),
        hunt: hunt(%{state: :walking})
      })
    end

    test "a walking order becomes a stand with the why, until the ceiling" do
      {logic, held} = capture_step(Logic.new(), walking(), 10_000)

      assert held.phase == :capturing
      assert held.route == :hold
      assert held.why =~ "corpo no chão"

      {_logic, still} = capture_step(logic, walking(), 13_000)
      assert still.route == :hold
      assert still.why =~ "(3s)"

      {_logic, free} = capture_step(logic, walking(), 16_500)
      assert free.route == :go
      refute free.phase == :capturing
    end

    test "without the capture the road walks, and a new capture restarts the clock" do
      {logic, free} = capture_step(Logic.new(), walking(%{capturing?: false}), 10_000)
      refute free.phase == :capturing
      refute Map.has_key?(logic.since, :capture_hold)

      {logic, held} = capture_step(logic, walking(), 20_000)
      assert held.route == :hold
      {logic, _gone} = capture_step(logic, walking(%{capturing?: false}), 21_000)
      refute Map.has_key?(logic.since, :capture_hold)
      {_logic, again} = capture_step(logic, walking(), 40_000)
      assert again.why =~ "(0s)"
    end

    test "red never holds for a ball" do
      {_logic, red} = capture_step(Logic.new(), walking(%{own_hp: 10}), 10_000)
      refute red.phase == :capturing
    end

    # 19:16:48 de 11/09: a sessão de mira aberta 70 s por um avistamento
    # queimou o teto do segurar numa rodada anterior, e na hora da bola de
    # verdade a estrada andou ("nada aqui — seguindo a rota") com o corpo do
    # shiny no chão. O teto é POR RODADA: fechar a rodada devolve o orçamento.
    test "a round closing renews the hold's budget" do
      {logic, _held} = capture_step(Logic.new(), walking(), 10_000)
      {logic, free} = capture_step(logic, walking(), 16_500)
      assert free.route == :go

      # a revive promise opened earlier and, with the bar back whole, closes
      # on this tick: that is the round closing
      logic = %{logic | since: Map.put(logic.since, :reset_pending, 20_000)}
      {logic, renewed} = capture_step(logic, walking(), 20_100)

      refute Map.has_key?(logic.since, :reset_pending)
      assert renewed.route == :hold
      assert renewed.phase == :capturing
      assert renewed.why =~ "(0s)"
    end

    test "a fight order is not touched: the overlay only stands a walk" do
      fight =
        world(%{
          situation: situation(%{enemies: 4, capturing?: true}),
          hunt: hunt(%{state: :fighting})
        })

      {_logic, orders} = capture_step(Logic.new(), fight, 10_000)

      refute orders.phase == :capturing
      assert orders.route == :hold
    end

    test "the knob at zero turns the hold off" do
      off = Config.merge(%{bunch_ms: 0, gather_target: 1, capture_hold_ms: 0})
      {_logic, orders} = Logic.step(Logic.new(), walking(), off, 10_000)
      refute orders.phase == :capturing
    end
  end

  # "POSTURA NO SHINY É JUNTAR PRIMEIRO!" (11/09). Em 09:12:54 o vigia viu o
  # Shiny Golem com 3 na tela e o cérebro abriu fogo andando ("matando o que já
  # abriu"): o especial casava o ramo do especial, que fura a fila da juntada.
  describe "the special gathers first, whichever road found it" do
    @his_mode Config.merge(%{
                gather_piles: false,
                engage_from: 6,
                gather_target: 6,
                bunch_ms: 4_000
              })

    test "the shiny seen by colour with three on screen does not open fire on the spot" do
      shiny =
        world(%{
          situation:
            situation(%{
              enemies: 3,
              special?: true,
              worth_fighting?: true
            }),
          hunt: hunt(%{state: :walking})
        })

      {_logic, orders} = Logic.step(Logic.new(), shiny, @his_mode, 1_000)

      refute orders.phase == :engaged, "abriu fogo sem juntar: #{orders.why}"
      assert orders.why =~ "✨ especial na tela: juntando primeiro"
    end

    # E O ACHADO POR NOME OU POR GRIT JUNTA IGUAL: era "só o especial fura a fila",
    # sobre uma distinção que o jogo não tem — "essa coisa de especial não existe
    # (…) é tudo uma coisa só" (12/09). Na prática dele já era assim: a lista de
    # nomes está vazia, e o grit só existe com a luta aberta.
    test "the one found by name or grit gathers first too" do
      achado =
        world(%{
          situation: situation(%{enemies: 3, special?: true, worth_fighting?: true}),
          hunt: hunt(%{state: :walking})
        })

      {_logic, orders} = Logic.step(Logic.new(), achado, @his_mode, 1_000)

      refute orders.phase == :engaged, "furou a fila: #{orders.why}"
      assert orders.why =~ "✨ especial na tela: juntando primeiro"
    end

    # …ONCE THE FIGHT WITH THE SPECIAL HAS OPENED, IT IS THE BOSS until the pile
    # zeroes with it off screen: the bench left the sleeping shiny behind after
    # the first revive and went gathering ten steps ahead (0 kills in 3 min).
    test "after the first opening the special cuts the queue, until it is gone" do
      shiny = fn enemies, special? ->
        world(%{
          situation:
            situation(%{
              enemies: enemies,
              special?: special?,
              worth_fighting?: true,
              ready_keys: []
            }),
          hunt: hunt(%{state: :walking})
        })
      end

      # a fight already open with the special on screen
      opened = %{Logic.new() | state: :engaged, special_opened?: true}

      # the list blinks to zero with the shiny still on screen: the latch holds
      {logic, _} = Logic.step(opened, shiny.(0, true), @his_mode, 1_000)
      assert logic.special_opened?

      {_logic, orders} = Logic.step(logic, shiny.(1, true), @his_mode, 1_200)
      assert orders.phase == :engaged, "the survivor shiny was sent to gather: #{orders.why}"

      # the pile zeroes with the shiny gone: next sighting gathers first again
      {logic, _} = Logic.step(logic, shiny.(0, false), @his_mode, 5_000)
      refute logic.special_opened?

      {_logic, orders} = Logic.step(logic, shiny.(3, true), @his_mode, 5_200)
      refute orders.phase == :engaged
      assert orders.why =~ "juntando primeiro"
    end
  end
end
