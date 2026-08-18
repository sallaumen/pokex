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
    assert result.outcome.killed == 0
  end

  test "greed makes the pile vanish rather than die" do
    result = run("ganancia", duration_ms: 40_000)

    assert result.outcome.vanished > 0
  end

  test "a vanished mob is never counted as a killed one" do
    result = run("ganancia", duration_ms: 40_000)

    assert result.outcome.killed + result.outcome.vanished + result.outcome.left_alive == 6
  end

  # This test used to assert `killed == 0`, and that assertion was recording a
  # BUG rather than a behaviour. Under the old movement a monster walking a
  # straight line into the character's square had no way around it, parked
  # there, and was eventually dragged past its leash — so a dripping pile
  # "proved" the engine threw five monsters away. With tile exclusivity and a
  # sidestep, the same run skips the pile while it is still small and picks it
  # up whole on the next lap. The finding was mine and it was wrong; this is
  # what the scenario actually shows.
  test "a dripping pile is skipped while small and collected whole on the way back" do
    result = run("pilha-que-pinga", duration_ms: 30_000)

    assert :skipping in result.outcome.phases
    assert :engaged in result.outcome.phases
    assert result.outcome.killed > 0
    assert result.outcome.vanished == 0
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

  test "a sweep answers once per value, tagged with the value it used" do
    results =
      Bench.sweep(Scenario.get("pilha-que-fecha"), :engage_from, [2, 3, 6], duration_ms: 20_000)

    assert length(results) == 3
    assert Enum.map(results, & &1.engage_from) == [2, 3, 6]
  end

  test "raising the ruler past the pile makes the bench walk away from it" do
    [low, high] =
      Bench.sweep(Scenario.get("pilha-que-fecha"), :engage_from, [3, 9], duration_ms: 30_000)

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
end
