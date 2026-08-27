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
  @config Config.merge()

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
      %{state: :walking, luring?: false, gathering?: false, wp_index: 12, waypoints: 70},
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

    test "resumes the route once the bar is back" do
      {logic, _} = step(world(%{situation: situation(%{own_hp: 18})}), 1_000)
      {logic, orders} = step(logic, world(%{situation: situation(%{own_hp: 95})}), 2_000)

      assert logic.state == :travelling
      assert orders.route == :go
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
    @reset Config.merge(%{reset_revive: true, engage_from: 3, crowd_from: 99})

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

    # Sem a R3b, a mesma barra vazia tem a resposta de graça: andar (R7).
    test "desligada, a mesma barra vazia anda em vez de pedir revive" do
      sem = Config.merge(%{reset_revive: false, crowd_from: 99})
      sem_step = fn logic, world, now -> Logic.step(logic, world, sem, now) end
      logic = engaged(sem_step)

      {_logic, orders} = sem_step.(logic, spent_fight(), 2_000)

      assert orders.revive == :hold
      assert orders.why =~ "andando até a barra voltar"
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
    test "e se a barra NÃO voltar, ela se desarma em vez de insistir" do
      logic = engaged(&reset_step/3)
      {logic, primeira} = com_controle(logic, spent_fight(), 2_000)
      assert primeira.revive == :now

      # muito depois do piso, com o pokémon em campo e a barra AINDA vazia
      passou = 2_000 + @reset.reset_revive_cooldown_ms + 10_000
      {logic, depois} = reset_step(logic, spent_fight(), passou)

      assert depois.revive == :hold
      assert logic.reset_broken?, "o reset foi cobrado e não veio — a regra sai de cena"

      {_logic, nunca_mais} = reset_step(logic, spent_fight(), passou + 600_000)
      assert nunca_mais.revive == :hold
    end

    test "mas uma barra que VOLTA mantém a regra armada" do
      logic = engaged(&reset_step/3)
      {logic, _} = com_controle(logic, spent_fight(), 2_000)

      cheia = spent_fight(%{spent?: false})
      passou = 2_000 + @reset.reset_revive_cooldown_ms + 10_000
      {logic, _} = reset_step(logic, cheia, passou)

      refute logic.reset_broken?

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
    @fuga Config.merge(%{crowd_from: 99, reset_revive: false})

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

    test "com a barra vazia ela anda" do
      {_logic, orders} = lutando_gasto(200)

      assert orders.phase == :engaged
      assert orders.route == :go
      assert orders.why =~ "andando até a barra voltar"
    end

    test "mas se não sair do lugar, ela desiste e volta a lutar parada" do
      {logic, _} = lutando_gasto(200)

      {_logic, orders} = fuga_step(logic, sem_cooldown(0), 5_000)

      assert orders.route == :hold, "andar contra uma parede não é fugir"
      assert orders.why =~ "matando o que já abriu"
    end

    test "e se sair, ela continua" do
      {logic, _} = lutando_gasto(200)

      {_logic, orders} = fuga_step(logic, sem_cooldown(4), 5_000)

      assert orders.route == :go
    end

    # A fuga pertence a UMA luta: a próxima não pode herdar o veredito da
    # anterior.
    test "e a próxima luta começa com a dúvida a favor dela de novo" do
      {logic, _} = lutando_gasto(200)
      {logic, _} = fuga_step(logic, sem_cooldown(0), 5_000)

      {logic, _} = fuga_step(logic, world(%{hunt: hunt(%{state: :walking})}), 6_000)
      {logic, _} = fuga_step(logic, sem_cooldown(0), 7_000)
      {_logic, orders} = fuga_step(logic, sem_cooldown(0), 7_200)

      assert orders.route == :go
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
    @solo Config.merge(%{gather_piles: false, engage_from: 1})

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
    @r10 Config.merge(%{reset_revive: true, crowd_from: 4, stun_window_ms: 5_000})

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
end
