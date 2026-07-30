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

  test "a corpse observation throws ONE ball and awaits confirmation" do
    {logic, actions} = Logic.step(armed(), obs([{100, 200}], 10), 10)
    assert {:capture_sequence, {100, 200}} in actions
    assert logic.counters.throws == 1

    # a PRE-WINDOW frame (10 + 800 = 810 > 700) proves nothing: new corpses queue,
    # nothing else is thrown while one ball is in flight
    {logic, actions} = Logic.step(logic, obs([{100, 200}, {300, 300}], 700), 700)
    refute Enum.any?(actions, &match?({:capture_sequence, _}, &1))
    assert logic.queue == [{300, 300}]
  end

  test "the corpse vanishing after the flight window confirms and throws the next in one step" do
    {logic, _} = Logic.step(armed(), obs([{100, 200}], 10), 10)

    # past the window, {100,200} gone; {300,300} is new → confirm + admit + throw, same step
    {logic, actions} = Logic.step(logic, obs([{300, 300}], 900), 900)
    assert logic.counters.captures == 1
    assert {:capture_sequence, {300, 300}} in actions
  end

  test "an observation captured BEFORE the flight window never confirms nor retries" do
    {logic, _} = Logic.step(armed(), obs([{100, 200}], 10), 10)
    # captured_at 500 < throw at 10 + confirm_after 800 → too early, no verdict
    {logic, actions} = Logic.step(logic, obs([], 500), 500)
    assert logic.counters.captures == 0
    assert logic.throw != nil
    assert actions == []
  end

  test "a persisting blob gets one retry then joins the ignore list — even at the exact same spot" do
    {logic, _} = Logic.step(armed(), obs([{100, 200}], 10), 10)

    # still there after the window (position identical — a parked pet) → retry (ball 2)
    {logic, actions} = Logic.step(logic, obs([{100, 200}], 900), 900)
    assert {:capture_sequence, {100, 200}} in actions
    assert logic.throw.balls == 2

    # the retry got its own flight window (thrown at 900): still there past 1700 → ignored
    {logic, actions} = Logic.step(logic, obs([{100, 200}], 1_800), 1_800)
    refute Enum.any?(actions, &match?({:capture_sequence, _}, &1))
    assert logic.counters.ignored == 1
    assert logic.throw == nil

    # while ignored, never re-admitted
    {logic, actions} = Logic.step(logic, obs([{102, 198}], 2_400), 2_400)
    assert actions == []
    assert logic.queue == []

    # after the TTL (1_800 + 120_000) it is fair game again
    {_logic, actions} = Logic.step(logic, obs([{100, 200}], 130_000), 130_000)
    assert {:capture_sequence, {100, 200}} in actions
  end

  test "stale/nil observations do nothing" do
    assert {%Logic{}, []} = Logic.step(armed(), nil, 50)
  end

  test "a scanning?: false (warmup) observation is a no-op, even with a pending throw past its window" do
    {logic, _} = Logic.step(armed(), obs([{100, 200}], 10), 10)

    # 10_000 is well past the throw's flight window (10 + 800) — a real (scanning: true) obs
    # with an empty corpse list here would confirm the capture; a warmup frame must not
    warmup = %{scanning?: false, corpses: [], captured_at: 10_000}
    assert {^logic, []} = Logic.step(logic, warmup, 10_000)
  end

  test "frame dedup: the same captured_at never double-confirms" do
    {logic, _} = Logic.step(armed(), obs([{100, 200}], 10), 10)
    {logic, _} = Logic.step(logic, obs([], 900), 900)
    assert logic.counters.captures == 1

    # same frame again (event + wake race) → no second verdict, no crash
    {logic, actions} = Logic.step(logic, obs([], 900), 901)
    assert logic.counters.captures == 1
    assert actions == []
  end

  test "next_wake mira o PRAZO da confirmação com bola em voo; dorme quando vazio" do
    logic = armed()
    assert Logic.next_wake(logic, 0) == nil

    # bola arremessada em t=10, janela de 800 → acordar em t=810 (acordar antes
    # rende uma varredura que a confirmação descarta como "ainda voando")
    {logic, _} = Logic.step(logic, obs([{100, 200}], 10), 10)
    assert Logic.next_wake(logic, 10) == 800
    assert Logic.next_wake(logic, 700) == 110

    # prazo já passou (varredura sendo segurada) → cadência do feed, NUNCA 1ms
    # em loop (medido: ~15.000 acordadas numa luta de 15s)
    assert Logic.next_wake(logic, 2_000) == 400

    {logic, _} = Logic.step(logic, obs([], 900), 900)
    assert Logic.next_wake(logic, 900) == nil
  end

  describe "ciclo de vida (fatia 6)" do
    defp config_seca(teto), do: Map.put(config(), :dry_balls_alarm, teto)

    test "ball_flown move a janela pra ATUAÇÃO, não pra decisão" do
      {logic, _} = Logic.step(armed(), obs([{100, 200}], 10), 10)

      # a sequência do Body levou 250ms pra sair
      logic = Logic.ball_flown(logic, 260)

      # uma leitura que chegaria "depois da janela" contada da DECISÃO ainda
      # está dentro do voo contado da atuação — não confirma nada
      {logic, actions} = Logic.step(logic, obs([], 900), 900)
      assert actions == []
      assert logic.counters.captures == 0

      # da atuação em diante a janela vale normalmente
      {logic, _} = Logic.step(logic, obs([], 1_100), 1_100)
      assert logic.counters.captures == 1
    end

    test "AUSENTE tardio dentro do teto = capturado (tardio) — o campo provou" do
      # 2026-07-30: 27 de 80 bolas resolveram depois de 6× a janela (o
      # fight_timeout de 15s segura as varreduras) e as "inconclusivas" eram
      # capturas reais jogadas fora. Ausência ainda é prova até o teto duro.
      {logic, _} = Logic.step(armed(), obs([{100, 200}], 10), 10)

      tarde = 10 + 800 * 6 + 100
      {logic, actions} = Logic.step(logic, obs([], tarde), tarde)

      assert logic.counters.captures == 1
      assert logic.counters.tardias == 1
      assert Enum.any?(actions, &match?({:log, "capturado (tardio)" <> _}, &1))
    end

    test "além do TETO DURO (60s) nem a ausência prova nada: inconclusiva" do
      {logic, _} = Logic.step(armed(), obs([{100, 200}], 10), 10)

      tarde_demais = 10 + 60_000 + 100
      {logic, actions} = Logic.step(logic, obs([], tarde_demais), tarde_demais)

      assert logic.counters.captures == 0
      assert logic.throw == nil
      assert Enum.any?(actions, &match?({:log, "confirmação inconclusiva" <> _}, &1))
    end

    test "OUTRA espécie no ponto da bola = o original foi capturado; o novo entra na fila" do
      obs_kingler = %{
        scanning?: true,
        corpses: [{100, 200}],
        captured_at: 10,
        known: %{{100, 200} => %{name: "Kingler", score: 0.9}}
      }

      {logic, _} = Logic.step(armed(), obs_kingler, 10)
      assert logic.throw.nome == "Kingler"

      # na confirmação, um GYARADOS está exatamente ali: o Kingler sumiu
      obs_gyarados = %{
        scanning?: true,
        corpses: [{100, 200}],
        captured_at: 900,
        known: %{{100, 200} => %{name: "Gyarados", score: 0.9}}
      }

      {logic, actions} = Logic.step(logic, obs_gyarados, 900)

      assert logic.counters.captures == 1
      assert Enum.any?(actions, &match?({:log, "capturado" <> _}, &1))
      # e o Gyarados já ganhou a bola dele no MESMO passo
      assert Enum.any?(actions, &match?({:capture_sequence, {100, 200}}, &1))
      assert logic.throw.nome == "Gyarados"
    end

    test "N bolas sem captura confirmada tocam o alarme e recomeçam" do
      {logic, []} = Logic.start(Logic.new(config_seca(2)), 0)

      # bola 1 e 2 no ponto A: sobrevive às duas → "não é corpo" (seca 1)
      {logic, _} = Logic.step(logic, obs([{100, 200}], 10), 10)
      {logic, _} = Logic.step(logic, obs([{100, 200}], 900), 900)
      {logic, actions} = Logic.step(logic, obs([{100, 200}], 1_800), 1_800)
      assert Enum.any?(actions, &match?({:log, "não é corpo" <> _}, &1))
      refute Enum.any?(actions, &match?({:alarm, _}, &1))

      # ponto B, mesma história → seca 2 = alarme
      {logic, _} = Logic.step(logic, obs([{100, 200}, {400, 400}], 2_000), 2_000)
      {logic, _} = Logic.step(logic, obs([{100, 200}, {400, 400}], 2_900), 2_900)
      {logic, actions} = Logic.step(logic, obs([{100, 200}, {400, 400}], 3_800), 3_800)

      assert Enum.any?(actions, &match?({:alarm, "🥎" <> _}, &1))
      assert logic.dry_balls == 0

      # uma captura de verdade zera a contagem
      {logic, _} = Logic.step(logic, obs([{100, 200}, {400, 400}, {50, 50}], 4_000), 4_000)
      {logic, _} = Logic.step(logic, obs([{100, 200}, {400, 400}], 4_900), 4_900)
      assert logic.counters.captures == 1
      assert logic.dry_balls == 0
    end

    test "ignore é por IDENTIDADE: outro pokémon no mesmo tile não herda o veto" do
      {logic, _} = Logic.step(armed(), obs([{100, 200}], 10), 10)
      {logic, _} = Logic.step(logic, obs([{100, 200}], 900), 900)

      # sobreviveu a corpse_max_balls (2) → vetado, com o nome que a varredura via
      obs_pet = %{
        scanning?: true,
        corpses: [{100, 200}],
        captured_at: 1_800,
        known: %{{100, 200} => %{name: "Pet", score: 0.9}}
      }

      {logic, actions} = Logic.step(logic, obs_pet, 1_800)
      assert Enum.any?(actions, &match?({:log, "não é corpo" <> _}, &1))

      # o MESMO nome no mesmo ponto continua vetado
      {logic, actions} = Logic.step(logic, %{obs_pet | captured_at: 2_000}, 2_000)
      refute Enum.any?(actions, &match?({:capture_sequence, _}, &1))

      # um Kingler recém-caído no mesmo tile NÃO herda o veto do Pet
      obs_kingler = %{
        scanning?: true,
        corpses: [{100, 200}],
        captured_at: 2_200,
        known: %{{100, 200} => %{name: "Kingler", score: 0.95}}
      }

      {_logic, actions} = Logic.step(logic, obs_kingler, 2_200)
      assert Enum.any?(actions, &match?({:capture_sequence, {100, 200}}, &1))
    end

    test "sem identidade dos dois lados, o veto por ponto segue valendo" do
      {logic, _} = Logic.step(armed(), obs([{100, 200}], 10), 10)
      {logic, _} = Logic.step(logic, obs([{100, 200}], 900), 900)
      {logic, _} = Logic.step(logic, obs([{100, 200}], 1_800), 1_800)

      # leitura sem :known (fluxo antigo): conservador, não readmite
      {_logic, actions} = Logic.step(logic, obs([{100, 200}], 2_000), 2_000)
      refute Enum.any?(actions, &match?({:capture_sequence, _}, &1))
    end
  end
end
