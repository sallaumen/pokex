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
    closing_timeout_ms: 8_000
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
      %{situation: situation(), hunt: hunt(), hands: %{opening: ~w(3 4 5 6 7 8 9)}},
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
        situation: situation(Map.merge(%{enemies: 4, spent?: true}, overrides)),
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
