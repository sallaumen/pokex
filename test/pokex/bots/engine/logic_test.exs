defmodule Pokex.Bots.Engine.LogicTest do
  @moduledoc """
  His decision tree, as a table.

  Every rule here is one he stated on 2026-08-17, and the test is written so
  that breaking the rule breaks the test — the whole point of moving the
  decision out of three workers into one function is that the reasoning becomes
  arguable in one place.
  """
  use ExUnit.Case, async: true

  alias Pokex.Bots.Engine.Logic

  @config %{
    engage_from: 3,
    pile_settle_ms: 1_500,
    size_ceiling_ms: 4_000,
    band_yellow_pct: 60,
    band_red_pct: 30,
    resume_pct: 80,
    recover_timeout_ms: 30_000,
    closing_timeout_ms: 8_000,
    downed_retry_ms: 4_000,
    revive_confirm_ms: 3_000,
    rescue_cooldown_ms: 60_000
  }

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
        blind?: false
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
        hands: %{opening: ~w(3 4 5 6 7 8 9), single: ~w(7 8 9)}
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

    # "se tem 1 ou 2 monstros, eu às vezes até ignoro aquele mob e sigo a minha
    # vida, deixo eles sumirem mesmo" — the ceiling is what turns waiting into
    # a decision instead of a hang.
    test "a pile that never reaches three is left behind once the ceiling runs out" do
      small = situation(%{enemies: 2, worth_fighting?: false})
      w = world(%{situation: small, hunt: hunt(%{state: :fighting})})

      {logic, orders} = step(w, 1_000)
      assert logic.state == :sizing
      assert orders.fire == :hold

      {logic, orders} = step(logic, w, 1_000 + 4_000)
      assert logic.state == :skipping
      assert orders.route == :go
      assert orders.fire == :hold
      assert orders.why =~ "não vale"
    end

    test "a pile still walking in is waited for, not fired at" do
      arriving = situation(%{enemies: 4, growing?: true, stable_for_ms: 0})
      w = world(%{situation: arriving, hunt: hunt(%{state: :fighting})})

      {logic, orders} = step(w, 1_000)

      assert logic.state == :sizing
      assert orders.fire == :hold
      assert orders.why =~ "chegando"
    end

    test "a pile that stopped growing, but not for long enough, is still waited for" do
      settling = situation(%{stable_for_ms: 900})
      w = world(%{situation: settling, hunt: hunt(%{state: :fighting})})

      {logic, orders} = step(w, 1_000)

      assert logic.state == :sizing
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

    # A revive that never lands must not end the night standing still.
    test "gives up recovering after the ceiling and walks again" do
      {logic, _} = step(world(%{situation: situation(%{own_hp: 18})}), 1_000)
      {logic, orders} = step(logic, world(%{situation: situation(%{own_hp: 40})}), 1_000 + 30_000)

      assert logic.state == :travelling
      assert orders.why =~ "desisti de esperar"
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
    @reset Map.merge(@config, %{reset_revive: true, engage_from: 3})

    defp reset_step(logic, world, now), do: Logic.step(logic, world, @reset, now)

    defp spent_fight(overrides \\ %{}) do
      world(%{
        situation: situation(Map.merge(%{enemies: 4, spent?: true, own_hp: 100}, overrides)),
        hunt: hunt(%{state: :fighting})
      })
    end

    defp engaged(step_fun) do
      {logic, _opening} = step_fun.(Logic.new(), spent_fight(%{spent?: false}), 1_000)
      logic
    end

    test "com a chave ligada, a barra vazia na frente da pilha pede o revive" do
      logic = engaged(&reset_step/3)

      {_logic, orders} = reset_step(logic, spent_fight(), 2_000)

      assert orders.revive == :now
      assert orders.fire == :free, "a luta continua enquanto o corpo volta"
      assert orders.why =~ "sem cooldown"
    end

    test "e NÃO entra em recuperação: isto não é um resgate" do
      logic = engaged(&reset_step/3)

      {after_order, _orders} = reset_step(logic, spent_fight(), 2_000)
      {_logic, next} = reset_step(after_order, spent_fight(%{spent?: false}), 9_000)

      assert next.phase == :engaged
      assert next.route == :hold
    end

    test "desligada (o padrão), a mesma barra vazia não pede nada" do
      logic = engaged(&step/3)

      {_logic, orders} = step(logic, spent_fight(), 2_000)

      assert orders.revive == :hold
      assert orders.why =~ "matando o que já abriu"
    end

    test "não duas vezes dentro do piso: uma barra que segue vazia não vira tecla presa" do
      logic = engaged(&reset_step/3)

      {after_first, first} = reset_step(logic, spent_fight(), 2_000)
      assert first.revive == :now

      {after_second, second} = reset_step(after_first, spent_fight(), 4_000)
      assert second.revive == :hold, "4s depois ainda está dentro do piso de 6s"

      {_logic, third} = reset_step(after_second, spent_fight(), 9_000)
      assert third.revive == :now
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

    test "espera o corpo voltar antes de pedir outro revive" do
      {_logic, orders} = step(caido(), 1_000)

      assert orders.revive == :hold
    end

    test "e pede de novo quando ele não volta" do
      {logic, _} = step(caido(), 1_000)
      {_logic, orders} = step(logic, caido(), 1_000 + @config.downed_retry_ms)

      assert orders.revive == :now
      assert orders.why =~ "não voltou"
    end

    test "uma vez por piso, não uma por tique" do
      {logic, _} = step(caido(), 1_000)
      {logic, first} = step(logic, caido(), 1_000 + @config.downed_retry_ms)
      assert first.revive == :now

      {logic, second} = step(logic, caido(), 1_100 + @config.downed_retry_ms)
      assert second.revive == :hold

      {_logic, third} = step(logic, caido(), 1_000 + 2 * @config.downed_retry_ms)
      assert third.revive == :now
    end

    test "uma queda nova recomeça o piso, sem herdar o relógio da anterior" do
      {logic, _} = step(caido(), 1_000)
      {logic, _} = step(logic, caido(), 1_000 + @config.downed_retry_ms)
      {logic, _} = step(logic, world(), 60_000)

      {_logic, orders} = step(logic, caido(), 60_100)

      assert orders.revive == :hold
    end

    test "não sei se ele está em campo não é ele estar no chão" do
      unknown = caido(%{own_out?: :unknown, own_hp: 90})

      {_logic, orders} = step(unknown, 1_000)

      refute orders.phase == :downed
    end

    test "sete pedidos sem resposta bastam: depois disso ele insiste devagar" do
      {logic, _} = step(caido(), 0)

      {_logic, asks} =
        Enum.reduce(1..700, {logic, []}, fn tick, {logic, asks} ->
          {logic, orders} = step(logic, caido(), tick * 100)
          {logic, if(orders.revive == :now, do: [orders | asks], else: asks)}
        end)

      assert length(asks) <= 9, "70s de chão não podem virar uma tecla presa"
      assert hd(asks).why =~ "não está saindo"
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

    test "mas uma vida que subiu é um revive que saiu: aí ela espera mesmo" do
      logic = ordena_e_espera(20)

      {_logic, orders} = step(logic, ferido(45), 1_000 + @config.revive_confirm_ms)

      assert orders.phase == :recovering
      assert orders.route == :hold
    end

    test "recusado, a banda para de segurar a rota até o piso passar" do
      logic = ordena_e_espera(20)
      {logic, _} = step(logic, ferido(20), 1_000 + @config.revive_confirm_ms)

      {_logic, orders} = step(logic, ferido(45), 10_000)

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
    @batendo Map.put(@config, :skip_fire, true)

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
    @solo Map.merge(@config, %{gather_piles: false, engage_from: 1})

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
end
