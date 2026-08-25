defmodule Pokex.Sim.BenchTest do
  use ExUnit.Case, async: true

  alias Pokex.Sim.Bench
  alias Pokex.Sim.Scenario

  defp run(id, opts), do: Bench.run(Scenario.get(id), opts)

  test "a run answers with a timeline and an outcome" do
    result = run("pilha-que-fecha", duration_ms: 10_000)

    assert is_list(result.timeline)
    assert result.outcome.ran_for_ms >= 10_000
  end

  test "the same scenario twice gives the same answer" do
    a = run("pilha-que-fecha", duration_ms: 10_000)
    b = run("pilha-que-fecha", duration_ms: 10_000)

    assert a.outcome == b.outcome
    assert a.timeline == b.timeline
  end

  test "the timeline records decision changes, not ticks" do
    result = run("pilha-que-fecha", duration_ms: 20_000)

    assert length(result.timeline) < 20
  end

  test "every timeline line carries the reason in his own words" do
    result = run("pilha-que-fecha", duration_ms: 10_000)

    for line <- result.timeline do
      assert is_binary(line.why) and line.why != ""
    end
  end

  test "a pile above the ruler gets engaged and killed" do
    result = run("pilha-que-fecha", duration_ms: 30_000)

    assert :engaged in result.outcome.phases
    assert result.outcome.killed > 0
  end

  test "a pile under the ruler is walked away from instead of fought" do
    result = run("pilha-pequena", duration_ms: 30_000)

    assert :skipping in result.outcome.phases
    refute :engaged in result.outcome.phases, "a régua decidiu não abrir — e não abriu"
  end

  # O TETO MUDOU E ISTO MUDOU COM ELE (2026-08-25). Com 4s o par abandonado
  # sumia; com 8s ele alcança o pokémon parado, morde até o amarelo, e a banda
  # fecha a rodada matando os dois — pagando um revive por uma pilha que a régua
  # tinha recusado. O teto de 4s era "a maior mobada gravada dele (4806ms)
  # arredondada PRA BAIXO", uma frase que enuncia o próprio bug, e a caçada
  # inteira aprova a troca. Este cenário é onde ela cobra.
  test "greed makes the pile vanish rather than die" do
    result = run("ganancia", duration_ms: 40_000, config: %{size_ceiling_ms: 4_000})

    assert result.outcome.vanished > 0
  end

  test "a vanished mob is never counted as a killed one" do
    result = run("ganancia", duration_ms: 40_000)

    assert result.outcome.killed + result.outcome.vanished + result.outcome.left_alive == 2
  end

  # This assertion has now flipped THREE times, and the history is the lesson.
  #
  #   1. Originally `killed == 0`: the engine skipped a pile worth fighting and
  #      lost all five to the leash. Reported to him as a real finding.
  #   2. Then the movement fix (tile exclusivity + sidestep) made it `killed: 5,
  #      vanished: 0`, and I told him finding #1 had been an artifact.
  #   3. Then the screen fix — 15x11 instead of a 15x15 Chebyshev square —
  #      put it back to `killed: 0, vanished: 5`.
  #   4. Then the leash fix (2026-08-25) made it `killed: 3, vanished: 2`: the
  #      rope used to be spent on the walk TOWARDS the fight, so a mob that
  #      woke could evaporate before ever reaching the pokemon. It cannot now,
  #      and what is lost here is lost for the reason the scenario names — the
  #      hunt walked on and left them behind.
  #
  #   5. E o teto (2026-08-25): `size_ceiling_ms` era "a maior mobada gravada
  #      dele (4806ms) arredondada PRA BAIXO" — 4s, ou seja, um teto ABAIXO da
  #      pilha mais lenta que ele já registrou, que portanto corta essa pilha
  #      toda vez. Com 8s a pilha que pinga é esperada até o fim e morre
  #      inteira. Foi a única das cinco viradas que veio de um número dele em
  #      vez de um da física.
  #
  # Step 2 was the artifact. The engine only "collected them on the way back"
  # because it could see two extra tiles above and below what the game shows.
  # The finding is real, and the moral is that a conclusion drawn from a model
  # is worth exactly what the model's fidelity is worth.
  test "a dripping pile is skipped by a ceiling below his own slowest gather" do
    cortada =
      Bench.run(Scenario.get("pilha-que-pinga"),
        duration_ms: 30_000,
        config: %{size_ceiling_ms: 4_000}
      )

    assert :skipping in cortada.outcome.phases
    assert cortada.outcome.vanished > 0, "the pile has to be LOST, not merely skipped"

    inteira = run("pilha-que-pinga", duration_ms: 30_000)

    assert :engaged in inteira.outcome.phases
    assert inteira.outcome.vanished == 0
  end

  test "red health revives immediately instead of finishing the round" do
    result = run("vermelho", duration_ms: 20_000)

    assert is_integer(result.outcome.revived_at)
    assert result.outcome.revived_at < 6_000
  end

  test "the revive heals and the run ends above the red line" do
    result = run("vermelho", duration_ms: 20_000)

    assert result.outcome.hp_at_end > 30
  end

  test "a blind stretch makes the engine say it is not looking" do
    result = run("tela-ilegivel", duration_ms: 12_000)

    assert Enum.any?(result.timeline, &(&1.phase == :blind))
  end

  test "a blind stretch never reports zero enemies" do
    result = run("tela-ilegivel", duration_ms: 12_000)

    blind = Enum.filter(result.timeline, &(&1.phase == :blind))

    assert blind != []
    assert Enum.all?(blind, &(&1.enemies == nil))
  end

  test "a dead key leaves monsters standing that the other keys would have killed" do
    dead = run("tecla-morta", duration_ms: 40_000)
    healthy = Bench.run(%{Scenario.get("tecla-morta") | script: []}, duration_ms: 40_000)

    assert dead.outcome.killed <= healthy.outcome.killed
  end

  # THE CONTRACT THE PHYSICS OWES THE SCENARIOS (2026-08-25). Before the leash
  # fix, a mob spent its rope walking TOWARDS the fight and evaporated three
  # tiles short of the pokemon — so with his own ruler (engage from 1, nothing
  # is ever abandoned) piles still ended half "vanished", every health scenario
  # ended at 100% health, and "Ele cai" never produced a fall. A monster that
  # woke and was never walked away from has to be FOUGHT.
  describe "com a régua dele (engaja a partir de 1), o que acorda é lutado" do
    @his_ruler %{engage_from: 1}

    # Só os EXPERIMENTOS: uma pilha, uma pergunta, o mapa parado. Numa caçada
    # inteira passar por um canto enquanto se luta em outro é o que ela é, não
    # uma falha da física. E dois experimentos ficam de fora por motivos
    # opostos: "ganancia" mede a régua ABANDONANDO a pilha de propósito, e
    # "morte" tem o revive quebrado — sem pokémon em campo, ir embora é a
    # resposta certa.
    @walks_away ~w(ganancia morte)

    test "nenhum monstro some sem luta em cenário nenhum" do
      for scenario <- Scenario.all(),
          scenario.group in Scenario.experiment_groups(),
          scenario.id not in @walks_away do
        %{outcome: o} = Bench.run(scenario, duration_ms: 60_000, config: @his_ruler)

        assert o.vanished == 0,
               "#{scenario.id}: #{o.vanished} sumiram sem luta (mortos: #{o.killed})"
      end
    end

    test "a vida cai de verdade quando a mordida é forte" do
      %{timeline: t} = Bench.run(Scenario.get("vida-caindo"), config: @his_ruler)

      assert Enum.any?(t, &(is_integer(&1.hp) and &1.hp < 60)),
             "a barra nunca saiu do verde: a mordida não chegou a acontecer"
    end

    test "ele cai, e a queda leva a caçada pra recuperação" do
      %{outcome: o} = Bench.run(Scenario.get("morte"), config: @his_ruler)

      assert is_integer(o.died_at), "o cenário chamado 'Ele cai' tem que derrubar o pokémon"
      assert :recovering in o.phases
    end
  end

  # R2 belongs to the RULER, not to the rope: what is lost is lost because the
  # hunt decided the pile was not worth it and walked on.
  test "com a régua padrão a pilha pequena é abandonada — e some" do
    %{outcome: o} =
      Bench.run(Scenario.get("ganancia"), duration_ms: 40_000, config: %{size_ceiling_ms: 4_000})

    assert :skipping in o.phases
    assert o.killed == 0
    assert o.vanished > 0
  end

  test "com a régua dele os mesmos dois morrem — o preço da régua, medido" do
    %{outcome: o} =
      Bench.run(Scenario.get("ganancia"), duration_ms: 40_000, config: %{engage_from: 1})

    assert o.killed == 2
    assert o.vanished == 0
  end

  # The bench used to keep its own copy of the numbers and drifted two of them
  # away from the seeds (recover 20s vs 30s, closing 15s vs 8s), so every
  # verdict it gave was about a bot that does not exist.
  test "os botões da decisão são os do bot, não uma cópia" do
    config = Bench.default_config()
    seeds = Pokex.Settings.defaults()

    assert config.engage_from == seeds.engine_engage_from
    assert config.recover_timeout_ms == seeds.engine_recover_timeout_ms
    assert config.closing_timeout_ms == seeds.engine_closing_timeout_ms
    assert config.gather_piles == seeds.engine_gather_piles
  end

  test "a sweep answers once per value, tagged with the value it used" do
    results =
      Bench.sweep(Scenario.get("pilha-que-fecha"), :engage_from, [2, 3, 6], duration_ms: 20_000)

    assert length(results) == 3
    assert Enum.map(results, & &1.engage_from) == [2, 3, 6]
  end

  test "raising the ruler past the pile makes the bench walk away from it" do
    [low, high] =
      Bench.sweep(Scenario.get("pilha-que-fecha"), :engage_from, [3, 9],
        duration_ms: 30_000,
        config: %{size_ceiling_ms: 4_000}
      )

    assert low.killed > 0
    assert high.killed == 0
  end

  # There WAS a wall-clock assertion here ("a run is fast enough to be a test").
  # It went red on a laptop shared with four other suites, which is the one thing
  # a test must never do: measure the machine and blame the code. The speed is
  # real and visible in the suite's own runtime; it does not need an assertion
  # that fails for the wrong reason.
  test "a full minute of hunting is one call, and it returns" do
    result = run("pilha-que-fecha", duration_ms: 60_000)

    assert result.outcome.ran_for_ms >= 60_000
  end

  # A escada do suporte tem três degraus e este banco só modelava o terceiro.
  # `PlayerSupport.Logic` é pura, então quem decide é ela mesma — não uma cópia.
  describe "os dois degraus baratos da escada" do
    alias Pokex.Bots.Combat.Loadout

    @curador %Loadout{name: "Curador", aoe: ["3"], single: ["4"], heal: ["7"]}

    defp curando(loadout) do
      Bench.run(Scenario.get("vida-caindo"),
        duration_ms: 60_000,
        config: %{engage_from: 1},
        loadout: loadout
      )
    end

    test "a cura do pokémon sai no meio da luta: é o único degrau que funciona lutando" do
      %{metrics: com} = curando(@curador)
      %{metrics: sem} = curando(%{@curador | heal: []})

      assert com.min_hp > sem.min_hp
    end

    # A poção é um CANAL e a batalha cancela ela — o mesmo portão que o worker
    # guarda. A prova está nos dois números juntos: a vida mais baixa da corrida
    # é a MESMA com e sem poção (nenhuma foi bebida com a pilha viva) e só o
    # final muda, depois que a tela limpou.
    test "e a poção só depois, com a tela limpa" do
      drinking = %{
        engage_from: 1,
        potion_enabled: true,
        potion_pct: 95,
        potion_cooldown_ms: 3_000
      }

      com = Bench.run(Scenario.get("pilha-que-fecha"), duration_ms: 60_000, config: drinking)

      sem =
        Bench.run(Scenario.get("pilha-que-fecha"), duration_ms: 60_000, config: %{engage_from: 1})

      assert com.metrics.min_hp == sem.metrics.min_hp
      assert com.outcome.hp_at_end > sem.outcome.hp_at_end
    end
  end

  # A queixa dele, com número: "o cérebro PULA uma pilha de cinco que valia".
  # A pilha que PINGA nunca fica parada tempo bastante, o teto estoura, e a
  # régua desiste de uma pilha que ela mesma teria aberto.
  describe "a pilha que chega de um em um" do
    test "com o teto de 4s ela é abandonada; com 8s (o padrão) ela é morta inteira" do
      curto =
        Bench.run(Scenario.get("pilha-que-pinga"),
          duration_ms: 60_000,
          config: %{size_ceiling_ms: 4_000}
        )

      longo = Bench.run(Scenario.get("pilha-que-pinga"), duration_ms: 60_000)

      assert curto.outcome.vanished > 0
      assert longo.outcome.vanished == 0
      assert longo.outcome.killed > curto.outcome.killed
    end
  end
end
