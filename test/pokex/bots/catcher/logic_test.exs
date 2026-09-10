defmodule Pokex.Bots.Catcher.LogicTest do
  use ExUnit.Case, async: true

  alias Pokex.Bots.Catcher.Logic

  defp config do
    %{
      corpse_match_tolerance_px: 32,
      corpse_max_balls: 2,
      corpse_ignore_ttl_ms: 120_000,
      corpse_confirm_after_ms: 800,
      feed_corpses_ms: 400
    }
  end

  defp armed do
    {logic, []} = Logic.start(Logic.new(config()), 0)
    logic
  end

  defp obs(corpses, at), do: %{scanning?: true, corpses: corpses, captured_at: at}

  defp obs(corpses, at, source),
    do: %{scanning?: true, source: source, corpses: corpses, captured_at: at}

  # CADA LENTE JULGA A SUA BOLA. A varredura de corpos não conhece o corpo do
  # shiny (é a razão de a mira por cor existir), então a ausência dele numa
  # leitura da varredura não é prova de captura nenhuma — e vice-versa.
  test "a reading from the other detector proves nothing about this ball" do
    {logic, acoes} = Logic.step(armed(), obs([{100, 200}], 10, :shiny_aim), 10)
    assert Enum.any?(acoes, &match?({:capture_sequence, {100, 200}, _}, &1))

    {logic, acoes} = Logic.step(logic, obs([], 900), 900)
    assert acoes == []
    assert logic.counters.captures == 0

    {logic, acoes} = Logic.step(logic, obs([], 1_000, :shiny_aim), 1_000)
    assert Enum.any?(acoes, &match?({:log, _}, &1))
    assert logic.counters.captures == 1
  end

  # E A VÁLVULA: uma bola cuja lente calou não pode ficar presa pra sempre. O
  # teto duro tem que vir ANTES da conferência de lente.
  test "past the hard ceiling any reading releases the ball" do
    {logic, _} = Logic.step(armed(), obs([{100, 200}], 10, :shiny_aim), 10)

    {logic, acoes} = Logic.step(logic, obs([], 70_000), 70_000)

    assert Enum.any?(acoes, &match?({:log, _}, &1))
    assert logic.throw == nil
  end

  test "a corpse observation throws ONE ball and awaits confirmation" do
    {logic, actions} = Logic.step(armed(), obs([{100, 200}], 10), 10)
    assert Enum.any?(actions, &match?({:capture_sequence, {100, 200}, _}, &1))
    assert logic.counters.throws == 1

    {logic, actions} = Logic.step(logic, obs([{100, 200}, {300, 300}], 700), 700)
    refute Enum.any?(actions, &match?({:capture_sequence, _, _}, &1))
    assert logic.queue == [{300, 300}]
  end

  test "the corpse vanishing after the flight window confirms and throws the next in one step" do
    {logic, _} = Logic.step(armed(), obs([{100, 200}], 10), 10)

    {logic, actions} = Logic.step(logic, obs([{300, 300}], 900), 900)
    assert logic.counters.captures == 1
    assert Enum.any?(actions, &match?({:capture_sequence, {300, 300}, _}, &1))
  end

  test "an observation captured BEFORE the flight window never confirms nor retries" do
    {logic, _} = Logic.step(armed(), obs([{100, 200}], 10), 10)
    {logic, actions} = Logic.step(logic, obs([], 500), 500)
    assert logic.counters.captures == 0
    assert logic.throw != nil
    assert actions == []
  end

  test "a persisting blob gets one retry then joins the ignore list — even at the exact same spot" do
    {logic, _} = Logic.step(armed(), obs([{100, 200}], 10), 10)

    {logic, actions} = Logic.step(logic, obs([{100, 200}], 900), 900)
    assert Enum.any?(actions, &match?({:capture_sequence, {100, 200}, _}, &1))
    assert logic.throw.balls == 2

    {logic, actions} = Logic.step(logic, obs([{100, 200}], 1_800), 1_800)
    refute Enum.any?(actions, &match?({:capture_sequence, _, _}, &1))
    assert logic.counters.ignored == 1
    assert logic.throw == nil

    {logic, actions} = Logic.step(logic, obs([{102, 198}], 2_400), 2_400)
    assert actions == []
    assert logic.queue == []

    {_logic, actions} = Logic.step(logic, obs([{100, 200}], 130_000), 130_000)
    assert Enum.any?(actions, &match?({:capture_sequence, {100, 200}, _}, &1))
  end

  test "stale/nil observations do nothing" do
    assert {%Logic{}, []} = Logic.step(armed(), nil, 50)
  end

  test "a scanning?: false (warmup) observation is a no-op, even with a pending throw past its window" do
    {logic, _} = Logic.step(armed(), obs([{100, 200}], 10), 10)

    warmup = %{scanning?: false, corpses: [], captured_at: 10_000}
    assert {^logic, []} = Logic.step(logic, warmup, 10_000)
  end

  test "frame dedup: the same captured_at never double-confirms" do
    {logic, _} = Logic.step(armed(), obs([{100, 200}], 10), 10)
    {logic, _} = Logic.step(logic, obs([], 900), 900)
    assert logic.counters.captures == 1

    {logic, actions} = Logic.step(logic, obs([], 900), 901)
    assert logic.counters.captures == 1
    assert actions == []
  end

  # Measured: waking every 1ms while the deadline is overdue meant ~15,000 wakes in a 15s
  # fight — an overdue deadline falls back to the feed cadence instead.
  test "next_wake targets the confirmation deadline with a ball in flight; sleeps when empty" do
    logic = armed()
    assert Logic.next_wake(logic, 0) == nil

    {logic, _} = Logic.step(logic, obs([{100, 200}], 10), 10)
    assert Logic.next_wake(logic, 10) == 800
    assert Logic.next_wake(logic, 700) == 110

    assert Logic.next_wake(logic, 2_000) == 400

    {logic, _} = Logic.step(logic, obs([], 900), 900)
    assert Logic.next_wake(logic, 900) == nil
  end

  # A ÂNCORA DA CONFIRMAÇÃO É A TELA, e a tela anda com ele.
  #
  # `confirm/3` decide "capturado" perguntando se o corpo sumiu do PONTO DE TELA
  # onde a bola caiu. Isso é prova enquanto o personagem não anda — o que o modo
  # Parado garantia de graça. Abrindo a captura pra caçada (#590), um passo
  # desloca a tela inteira e o corpo "some" sem ninguém ter capturado nada: o
  # diário de 11/09 tem 89 "capturado" com os corpos ainda no chão.
  describe "a confirmação com o personagem andando" do
    defp with_pos(corpses, at, pos),
      do: %{scanning?: true, corpses: corpses, captured_at: at, pos: pos}

    test "he walked: an empty point proves nothing" do
      {logic, _} = Logic.step(armed(), with_pos([{100, 200}], 10, {10, 10, 7}), 10)

      # a bola voou, o corpo sumiu do ponto — mas ele deu um passo
      {logic, actions} = Logic.step(logic, with_pos([], 900, {11, 10, 7}), 900)

      assert actions == [], "andar não pode virar captura"
      assert logic.throw != nil, "a bola continua pendente até ele parar"
    end

    test "he stood still: an empty point IS the capture" do
      {logic, _} = Logic.step(armed(), with_pos([{100, 200}], 10, {10, 10, 7}), 10)

      {_logic, actions} = Logic.step(logic, with_pos([], 900, {10, 10, 7}), 900)

      assert Enum.any?(actions, &match?({:log, "capturado" <> _}, &1))
    end

    # Não saber onde ele está nunca pode virar "andou": sem as duas leituras o
    # juiz volta a ser o de antes, que é o comportamento que já rodava.
    test "with no position read at all, the old judgement stands" do
      {logic, _} = Logic.step(armed(), obs([{100, 200}], 10), 10)

      {_logic, actions} = Logic.step(logic, obs([], 900), 900)

      assert Enum.any?(actions, &match?({:log, "capturado" <> _}, &1))
    end
  end

  describe "throw lifecycle" do
    defp dry_config(cap), do: Map.put(config(), :dry_balls_alarm, cap)

    test "ball_flown moves the flight window to the actuation time, not the decision time" do
      {logic, _} = Logic.step(armed(), obs([{100, 200}], 10), 10)

      logic = Logic.ball_flown(logic, 260)

      {logic, actions} = Logic.step(logic, obs([], 900), 900)
      assert actions == []
      assert logic.counters.captures == 0

      {logic, _} = Logic.step(logic, obs([], 1_100), 1_100)
      assert logic.counters.captures == 1
    end

    # Field 2026-07-30: 27 of 80 balls resolved after 6x the window (the 15s fight_timeout
    # holds scans) and those "inconclusive" were real captures thrown away.
    test "late absence within the hard cap counts as captured (late)" do
      {logic, _} = Logic.step(armed(), obs([{100, 200}], 10), 10)

      tarde = 10 + 800 * 6 + 100
      {logic, actions} = Logic.step(logic, obs([], tarde), tarde)

      assert logic.counters.captures == 1
      assert logic.counters.tardias == 1
      assert Enum.any?(actions, &match?({:log, "capturado (tardio)" <> _}, &1))
    end

    test "beyond the 60s hard cap even absence proves nothing: inconclusive" do
      {logic, _} = Logic.step(armed(), obs([{100, 200}], 10), 10)

      tarde_demais = 10 + 60_000 + 100
      {logic, actions} = Logic.step(logic, obs([], tarde_demais), tarde_demais)

      assert logic.counters.captures == 0
      assert logic.throw == nil
      assert Enum.any?(actions, &match?({:log, "confirmação inconclusiva" <> _}, &1))
    end

    test "a different species at the ball's spot means the original was captured; the new one queues" do
      obs_kingler = %{
        scanning?: true,
        corpses: [{100, 200}],
        captured_at: 10,
        known: %{{100, 200} => %{name: "Kingler", score: 0.9}}
      }

      {logic, _} = Logic.step(armed(), obs_kingler, 10)
      assert logic.throw.name == "Kingler"

      obs_gyarados = %{
        scanning?: true,
        corpses: [{100, 200}],
        captured_at: 900,
        known: %{{100, 200} => %{name: "Gyarados", score: 0.9}}
      }

      {logic, actions} = Logic.step(logic, obs_gyarados, 900)

      assert logic.counters.captures == 1
      assert Enum.any?(actions, &match?({:log, "capturado" <> _}, &1))
      assert Enum.any?(actions, &match?({:capture_sequence, {100, 200}, _}, &1))
      assert logic.throw.name == "Gyarados"
    end

    test "N balls without a confirmed capture ring the alarm and restart the count" do
      {logic, []} = Logic.start(Logic.new(dry_config(2)), 0)

      {logic, _} = Logic.step(logic, obs([{100, 200}], 10), 10)
      {logic, _} = Logic.step(logic, obs([{100, 200}], 900), 900)
      {logic, actions} = Logic.step(logic, obs([{100, 200}], 1_800), 1_800)
      assert Enum.any?(actions, &match?({:log, "não é corpo" <> _}, &1))
      refute Enum.any?(actions, &match?({:alarm, _}, &1))

      {logic, _} = Logic.step(logic, obs([{100, 200}, {400, 400}], 2_000), 2_000)
      {logic, _} = Logic.step(logic, obs([{100, 200}, {400, 400}], 2_900), 2_900)
      {logic, actions} = Logic.step(logic, obs([{100, 200}, {400, 400}], 3_800), 3_800)

      assert Enum.any?(actions, &match?({:alarm, "🥎" <> _}, &1))
      assert logic.dry_balls == 0

      {logic, _} = Logic.step(logic, obs([{100, 200}, {400, 400}, {50, 50}], 4_000), 4_000)
      {logic, _} = Logic.step(logic, obs([{100, 200}, {400, 400}], 4_900), 4_900)
      assert logic.counters.captures == 1
      assert logic.dry_balls == 0
    end

    test "ignore is by identity: another pokemon on the same tile does not inherit the veto" do
      {logic, _} = Logic.step(armed(), obs([{100, 200}], 10), 10)
      {logic, _} = Logic.step(logic, obs([{100, 200}], 900), 900)

      obs_pet = %{
        scanning?: true,
        corpses: [{100, 200}],
        captured_at: 1_800,
        known: %{{100, 200} => %{name: "Pet", score: 0.9}}
      }

      {logic, actions} = Logic.step(logic, obs_pet, 1_800)
      assert Enum.any?(actions, &match?({:log, "não é corpo" <> _}, &1))

      {logic, actions} = Logic.step(logic, %{obs_pet | captured_at: 2_000}, 2_000)
      refute Enum.any?(actions, &match?({:capture_sequence, _, _}, &1))

      obs_kingler = %{
        scanning?: true,
        corpses: [{100, 200}],
        captured_at: 2_200,
        known: %{{100, 200} => %{name: "Kingler", score: 0.95}}
      }

      {_logic, actions} = Logic.step(logic, obs_kingler, 2_200)
      assert Enum.any?(actions, &match?({:capture_sequence, {100, 200}, _}, &1))
    end

    test "without identity on either side, the per-point veto still applies" do
      {logic, _} = Logic.step(armed(), obs([{100, 200}], 10), 10)
      {logic, _} = Logic.step(logic, obs([{100, 200}], 900), 900)
      {logic, _} = Logic.step(logic, obs([{100, 200}], 1_800), 1_800)

      {_logic, actions} = Logic.step(logic, obs([{100, 200}], 2_000), 2_000)
      refute Enum.any?(actions, &match?({:capture_sequence, _, _}, &1))
    end
  end
end
